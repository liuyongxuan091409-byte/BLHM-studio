// OpenHarmony 切片内核实现：走 libslic3r 官方管线
//   Model 载入 -> DynamicPrintConfig -> Print::apply -> Print::process -> Print::export_gcode
// 与桌面版 BambuStudio 的 CLI（src/slic3r/Utils/... / slic3r.cpp）走的是同一套 API。

#include "ohos_slicer_api.hpp"

#include "libslic3r.h"
#include "Config.hpp"
#include "Model.hpp"
#include "MeshBoolean.hpp"
#include "Preset.hpp"
#include "PresetBundle.hpp"
#include "Print.hpp"
#include "PrintConfig.hpp"
#include "Exception.hpp"
#include "Utils.hpp"

#include "Format/OBJ.hpp"
#include "Format/STL.hpp"
#include "Format/STEP.hpp"
#include "Format/3mf.hpp"
// 拓竹原生 3MF 读写（store_bbs_3mf / load_bbs_3mf）：项目 3MF 导出与往返自测都用它
#include "Format/bbs_3mf.hpp"
#include "Semver.hpp"

#include "libslic3r_version.h"

#include "miniz/miniz.h"
#include "nlohmann/json.hpp"

#include <set>

#include <boost/filesystem.hpp>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <exception>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

// 阶段标记要用到 fsync / sysconf（拿 RSS）
#include <unistd.h>

namespace Slic3r {
namespace ohos {

namespace {

std::string lower_extension(const std::string& path)
{
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos)
        return std::string();
    std::string ext = path.substr(dot);
    for (char& c : ext)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return ext;
}

// 把内核的临时目录指到应用自己的可写目录。必须在任何模型加载之前调用。
//
// 为什么必须改：BBL 的 3MF 加载器（Model::read_from_file -> load_bbs_3mf）以及 STEP
// 三角化（Format/STEP.cpp）都会把中间产物解到 <temporary_dir>/bamboo_model/... 下
// （Model::get_backup_path()：parent_path = temporary_dir()，再拼 "/bamboo_model/..."）。
// 库默认没有设置过这个目录，temporary_dir() 是系统临时目录；在 OHOS 沙箱里它会落到根目录
// "/"，应用无权在根下建目录，于是加载直接抛：
//   boost::filesystem::create_directories: Permission denied ... "/bamboo_model/..."
// 所以这里取 output_path（形如 <filesDir>/output.gcode）的父目录，在其下建 slice_tmp 作为
// 临时目录 —— 它一定在应用私有、可写、空间也不受系统 tmpfs 限制的位置。
//
// 幂等：同一次进程里可能多次切片，只要目标目录没变就直接返回，不重复建目录/重复 set。
// 返回 false 表示临时目录建不出来，此时必须中止（否则只会在加载器里以更难懂的方式失败）。
bool ensure_temporary_dir(const std::string& output_path, std::string& err)
{
    namespace fs = boost::filesystem;

    fs::path parent = fs::path(output_path).parent_path();
    if (parent.empty())
        parent = "."; // 只给了文件名，退回当前目录

    const fs::path tmp_dir = parent / "slice_tmp";

    static std::mutex  tmp_mutex;
    static std::string current_tmp_dir;

    std::lock_guard<std::mutex> lock(tmp_mutex);
    if (current_tmp_dir == tmp_dir.string())
        return true;

    boost::system::error_code ec;
    fs::create_directories(tmp_dir, ec);
    if (ec && !fs::is_directory(tmp_dir)) {
        err = "无法创建切片临时目录: " + tmp_dir.string() + " (" + ec.message() + ")";
        return false;
    }

    set_temporary_dir(tmp_dir.string());
    current_tmp_dir = tmp_dir.string();
    return true;
}

// 按扩展名分发到 libslic3r 的各个 Format loader。
// 3MF 会把文件里内嵌的工程配置写进 config（其余格式只填 model）。
//
// out_plates（可选）：仅 .3mf 用 —— 传入非 null 时把内核加载器的**打印盘列表**一并带出
// （Metadata/model_settings.config 里的 <plate>，含每盘的 object/instance 归属与非切片盘设置）。
// 导入 UI 需要它来展示「有几个盘、每盘有哪些对象」；切片路径不需要，所以默认传 nullptr。
//
// tolerate_empty_model（可选）：仅导入用 —— 切片产出的 .gcode.3mf（包内只有 gcode、没有网格）
// 会让 Model::read_from_file 在 "model.objects.empty()" 处抛「file couldn't be read because
// it's empty」，但此刻 project_settings.config 已经读进 config、盘数据也已经拿到。导入 UI
// 需要「几何为 0 但设置仍要返回」，所以这里把这种情况视为「加载成功但无网格」。切片/导出不传。
bool load_model_file(const std::string& path, Model& model, DynamicPrintConfig& config, std::string& err,
                     PlateDataPtrs* out_plates = nullptr, bool tolerate_empty_model = false)
{
    const std::string ext = lower_extension(path);
    ConfigSubstitutionContext csc{ForwardCompatibilitySubstitutionRule::Disable};

    if (ext == ".stl") {
        if (!load_stl(path.c_str(), &model)) {
            err = "STL 解析失败";
            return false;
        }
        return true;
    }

    if (ext == ".3mf") {
        // 必须走 BBL 专用加载器，而不是通用 load_3mf()：
        //   * 通用 load_3mf 会把每个 <item>(instance) 拆成独立 ModelObject 并深拷贝整份网格
        //     （Format/3mf.cpp:809-853，以及 :937-947 里注释写着 "BBS: copy object isteadof instance"），
        //     多盘 3MF = 多个 <item> = 多个 instance -> 网格被复制 N 份，这是多盘 3MF 崩的根因；
        //   * 通用 load_3mf 也不认 Metadata/model_settings.config，多盘的盘信息全丢
        //     （盘序号/盘内 gcode 都在这个文件里）。
        // Model::read_from_file 是官方入口：内部先做 Prusa 3mf 检测，非 Prusa 才走 load_bbs_3mf
        // （Model.cpp:487-497，其中 :496 就是 load_bbs_3mf 的调用点），与桌面版导入路径一致。
        // plate_id 传 0：BBL 加载器只在 plate_id > 0 时才按盘过滤、只装那一个盘
        // （bbs_3mf.cpp:2179 `if ((plate_id > 0) && (plate_id <= m_plater_data.size()))`，
        //   另一处同样语义在 :2496），所以 0 = 加载全部盘，正是"整份工程都要切"时想要的。
        try {
            // ⚠️ project_presets 必须传**真实容器**，不能传 nullptr：
            // 工程里若带 Metadata/filament_settings_N.config（MakerWorld/桌面版导出的工程很常见），
            // 加载器会 `project_presets.push_back(...)` 把解析出的 Preset* 放进去；
            // 传 nullptr 会在这里把引用绑到空地址 → worker 线程 SIGSEGV（实测「打开工程」闪退）。
            // 这里只借它「不崩」：加载完立即释放（我们不使用工程内嵌预设）。
            std::vector<Preset*> project_presets;
            Model loaded = Model::read_from_file(
                path, &config, &csc,
                LoadStrategy::LoadModel | LoadStrategy::LoadConfig | LoadStrategy::AddDefaultInstances,
                out_plates,        // plate_data（导入需要盘列表；切片/导出传 nullptr）
                &project_presets,  // ⚠️ 不能是 nullptr（见上）
                nullptr,  // is_xxx（是否 BBL 3mf，这里不需要）
                nullptr,  // file_version
                nullptr,  // proFn
                nullptr,  // stlFn
                nullptr,  // project
                /*plate_id=*/0);
            for (Preset* p : project_presets) {
                if (p != nullptr) {
                    delete p->loading_substitutions;
                    p->loading_substitutions = nullptr;
                    delete p;
                }
            }
            project_presets.clear();
            model = std::move(loaded);
        } catch (const std::exception& e) {
            // 无网格的 3MF（切片盘 .gcode.3mf）：内核因 "model.objects.empty()" 抛异常，
            // 但 config（project_settings.config）与盘数据已经读到手 —— 导入需要它们。
            if (tolerate_empty_model && model.objects.empty() && !config.keys().empty()) {
                err.clear();
                return true;
            }
            err = std::string("3MF 解析失败: ") + e.what();
            return false;
        }
        return true;
    }

    if (ext == ".obj") {
        ObjInfo info;
        std::string msg;
        if (!load_obj(path.c_str(), &model, info, msg)) {
            err = "OBJ 解析失败: " + msg;
            return false;
        }
        return true;
    }

    if (ext == ".step" || ext == ".stp") {
        // 注意：STEP.hpp 里的 load_step() 只有声明、没有定义（桌面版已废弃，实现被注释掉了），
        // 现在统一走 Step 类：load() 读文件 + mesh() 三角化。
        Step step(path);
        if (step.load() != Step::Step_Status::LOAD_SUCCESS) {
            err = "STEP 读取失败: " + path;
            return false;
        }
        bool cancel = false;
        if (step.mesh(&model, cancel, false, 0.003, 0.5) != Step::Step_Status::MESH_SUCCESS) {
            err = cancel ? "STEP 三角化被取消" : ("STEP 三角化失败: " + path);
            return false;
        }
        return true;
    }

    err = "不支持的模型格式: " + (ext.empty() ? std::string("<无扩展名>") : ext);
    return false;
}

// 热床（printable_area 多边形）的包围盒。
// 注意 BBL 机型的 printable_area 左下角是 (0,0)（例如 X1C 是 0x0,256x0,256x256,0x256），
// 世界原点并不在板中央，所以贴板居中与"打印板取景"都必须显式用这个包围盒，不能假设原点在中心。
//
// 同时兼容两种预设写法：旧的 "x0xy0 x1xy1 ..." 字符串数组、新的 [[x,y],...]——内核在加载预设时
// 都把 printable_area 解析成 ConfigOptionPoints，所以这里直接读点列表，两种形态通吃。
bool bed_bbox_from_config(const DynamicPrintConfig& config,
                          double& min_x, double& min_y, double& max_x, double& max_y)
{
    const ConfigOptionPoints* area = config.option<ConfigOptionPoints>("printable_area");
    if (area == nullptr || area->values.size() < 2)
        area = config.option<ConfigOptionPoints>("bed_shape");
    if (area == nullptr || area->values.size() < 2)
        return false;

    const std::vector<Vec2d>& pts = area->values;
    min_x = max_x = pts.front().x();
    min_y = max_y = pts.front().y();
    for (const Vec2d& p : pts) {
        min_x = std::min(min_x, p.x());
        max_x = std::max(max_x, p.x());
        min_y = std::min(min_y, p.y());
        max_y = std::max(max_y, p.y());
    }
    return true;
}

bool bed_center_from_config(const DynamicPrintConfig& config, Vec2d& out)
{
    double min_x = 0.0, min_y = 0.0, max_x = 0.0, max_y = 0.0;
    if (!bed_bbox_from_config(config, min_x, min_y, max_x, max_y))
        return false;
    out = Vec2d(0.5 * (min_x + max_x), 0.5 * (min_y + max_y));
    return true;
}

// 把载入的模型摆成"可切片"的状态。
//
// libslic3r 的 Format loader（load_stl / load_obj / Step::mesh ...）只往 Model 里塞
// object + volume —— 既不建 ModelInstance，也不把对象摆到热床上。这两件事是桌面版
// Plater 那一层干的活，我们直接调内核就漏掉了。后果非常隐蔽：
//   没有 instance → print_objects_from_model_object() 遍历 0 次 → Print::apply() 建出
//   0 个 PrintObject → Print::process() 在开头 `if (m_objects.empty()) return;` 静默空转
//   → 最后 export_gcode() 抛出那句迷惑人的 "No object can be printed. Maybe too small"。
// 另外 add_volume() 会把网格几何挪到"包围盒中心 = 原点"，所以对象默认是一半埋在板下的，
// 必须贴板（min z → 0）再居中。
//
// 自带摆位信息的格式（3MF 的 build 段）不进这个分支：只补缺失的 instance，位置原样保留，
// 否则会和桌面版看到的位置不一致。
void normalize_loaded_model(Model& model, const DynamicPrintConfig& config)
{
    bool any_instance = false;
    for (const ModelObject* mo : model.objects)
        if (mo != nullptr && !mo->instances.empty())
            any_instance = true;

    for (ModelObject* mo : model.objects)
        if (mo != nullptr && mo->instances.empty())
            mo->add_instance();

    if (any_instance)
        return;

    // 裸网格格式（stl / obj / step）：贴板 + 居中到热床
    for (ModelObject* mo : model.objects)
        if (mo != nullptr)
            mo->ensure_on_bed();

    Vec2d bed_center;
    if (bed_center_from_config(config, bed_center))
        model.center_instances_around_point(bed_center);
}

// =============================================================================
//  枚举项「内核枚举值 ↔ 表单下标」的唯一权威映射（全工程只此一处，禁止再分叉）
//
//  为什么必须有它（curr_bed_type 打印板整体偏一格的根因）：
//    * ConfigOptionDef::enum_values 是"表单可选项列表"的顺序 —— 它同时是
//      slicer_enum_values() 发给界面的顺序、也是 kSchema options 中文标签的顺序、
//      更是 apply_params() 把下标还原成枚举名时用的那一条；
//    * 而 ConfigOption::getInt() 返回的是**底层 C++ 枚举值**。多数枚举里两者恰好相等，
//      但 BedType 不是：enum BedType { btDefault=0, btPC=1, btEP=2, btPEI=3, btPTE=4, btSuperTack=5 }，
//      而 curr_bed_type 的 enum_values 只有 5 项、以 "Cool Plate" 打头（没有 "Default Plate"），
//      于是 btPC 的 getInt()==1 却对应 enum_values[0] —— 快照按"下标"发出去就整体偏一格，
//      表现就是「导入后正确，但任何一次 loadSchema 回填都把板型挪一格」。
//  这里以「内核枚举名」为中介统一口径（serialize() 走 enum_keys_map，是"枚举值 → 权威名字"）：
//      enum_value_to_index() : 枚举值 getInt()  → enum_values 下标（回填/显示用）
//      enum_name_from_index() : enum_values 下标 → 内核枚举名（下发/赋值用）
//  两者都直接对照同一条 enum_values，天然自洽；名字对不上时退回原值（不比现状更差）。
// =============================================================================
int enum_value_to_index(const std::string& key, const ConfigOption& opt)
{
    const int raw = opt.getInt();
    const ConfigOptionDef* od = print_config_def.get(key);
    if (od == nullptr || od->enum_values.empty())
        return raw;
    const std::string name = opt.serialize();
    for (size_t i = 0; i < od->enum_values.size(); ++i) {
        if (od->enum_values[i] == name)
            return static_cast<int>(i);
    }
    return raw;
}

const std::string* enum_name_from_index(const std::string& key, int index)
{
    const ConfigOptionDef* od = print_config_def.get(key);
    if (od == nullptr || index < 0 || static_cast<size_t>(index) >= od->enum_values.size())
        return nullptr;
    return &od->enum_values[static_cast<size_t>(index)];
}

// 是否是「打印板温度」键：cool/eng/hot/textured/supertack 的 *_plate_temp 与 *_plate_temp_initial_layer。
// 它们在 PrintConfig 里都是 coInts（数组），但同一台机的所有耗材档位共用同一个床温 —— 表单给标量成立。
bool is_plate_temp_key(const std::string& key)
{
    static const char* kSuffixInit = "_plate_temp_initial_layer";
    static const char* kSuffixTail = "_plate_temp";
    const size_t n_init = std::strlen(kSuffixInit);
    const size_t n_tail = std::strlen(kSuffixTail);
    if (key.size() >= n_init && key.compare(key.size() - n_init, n_init, kSuffixInit) == 0)
        return true;
    return key.size() >= n_tail && key.compare(key.size() - n_tail, n_tail, kSuffixTail) == 0;
}

// =============================================================================
//  审计块（方案 B）：切片完成后，把「界面下发的值 ↔ 内核最终生效值 ↔ gcode 实证」
//  追加写进 <切片输出目录>/diag/gcode_diag.txt。
//
//  为什么需要：UI 上改了值、日志也标了橙，并不等于内核真的用上了 —— apply_params
//  对「向量型」选项一直是跳过的，就出现过"改了不管用、成品和参数对不上"。这里让内核
//  自己把生效值写出来，并给出 gcode 里的实证（线宽标注 / 温度·风扇指令），一次对齐三者。
// =============================================================================

// 内核 config 里某键的「首档」文本（向量型取第一档 —— 与动态表单 / 预览同一口径）
std::string audit_opt_text(const DynamicPrintConfig& cfg, const char* key)
{
    const ConfigOption* o = cfg.option(key);
    if (o == nullptr)
        return "<内核无此项>";
    const std::string s = o->serialize();
    const size_t p = s.find(',');
    return p == std::string::npos ? s : s.substr(0, p);
}

// 界面下发的值（从 params_json 取同名键；数组取首元素）—— 未下发返回空串
std::string audit_sent_text(const nlohmann::json& j, const char* key)
{
    if (j.is_discarded() || !j.is_object())
        return "";
    const auto it = j.find(key);
    if (it == j.end())
        return "";
    const nlohmann::json& v = *it;
    if (v.is_array())
        return v.empty() ? std::string() : v.front().dump();
    if (v.is_string())
        return v.get<std::string>();
    return v.dump();
}

// 扫 gcode 取证：线宽标注的条数 / 极值 / 首几条原文 + 首个喷嘴·热床·风扇指令。
// 为什么改成"首样本 + 极值"：上一版只给去重集合，12.4 万个值里按字典序排在最前的
// 那几个（0.045…）先被打印，反而看不出真实带宽分布。有首几条原文和最大/最小值，
// 才能判定"预览把线画得特别细"到底是标注本身如此、还是预览取错了标注。
void audit_scan_gcode(const std::string& path, std::vector<std::string>& samples,
                      double& wmin, double& wmax, long& marks,
                      std::vector<std::string>& temps)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return;
    bool got_n = false, got_b = false, got_f = false;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty())
            continue;
        if (line[0] == ';') {
            if (line.rfind("; LINE_WIDTH:", 0) == 0) {
                ++marks;
                std::string v = line.substr(13);
                const size_t a = v.find_first_not_of(" \t");
                const size_t b = v.find_last_not_of(" \t\r");
                if (a == std::string::npos)
                    continue;
                v = (b == std::string::npos) ? v.substr(a) : v.substr(a, b - a + 1);
                if (samples.size() < 6)
                    samples.push_back(v);
                char* endp = nullptr;
                const double d = std::strtod(v.c_str(), &endp);
                if (endp != nullptr && endp != v.c_str()) {
                    if (d < wmin) { wmin = d; }
                    if (d > wmax) { wmax = d; }
                }
            }
            continue;
        }
        const bool is_n = line.rfind("M104", 0) == 0 || line.rfind("M109", 0) == 0;
        const bool is_b = line.rfind("M140", 0) == 0 || line.rfind("M190", 0) == 0;
        const bool is_f = line.rfind("M106", 0) == 0;
        if (is_n && !got_n)      { temps.push_back("gcode 首个喷嘴温度: " + line); got_n = true; }
        else if (is_b && !got_b) { temps.push_back("gcode 首个热床温度: " + line); got_b = true; }
        else if (is_f && !got_f) { temps.push_back("gcode 首个风扇: " + line);     got_f = true; }
    }
}

// 判定：**按配置项类型**比较，避免百分比/布尔/枚举的文本口径差异造成假不一致
// （旧版把 15 vs "15%"、false vs "0"、枚举下标 0 vs "Cool Plate" 全判成"不一致"）。
std::string audit_verdict(const DynamicPrintConfig& cfg, const char* key,
                          const std::string& sent, const std::string& eff)
{
    if (sent.empty())
        return "界面未下发(用预设值)";
    const ConfigOption* o = cfg.option(key);
    if (o == nullptr)
        return "内核无此项(键名可能写错)";

    auto strip_pct = [](std::string s) -> std::string {
        if (!s.empty() && s.back() == '%') { s.pop_back(); }
        return s;
    };
    auto as_double = [&](const std::string& s, double& d) -> bool {
        const std::string t = strip_pct(s);
        char* endp = nullptr;
        d = std::strtod(t.c_str(), &endp);
        return endp != nullptr && endp != t.c_str() && *endp == '\0';
    };
    auto as_bool = [](const std::string& s, bool& v) -> bool {
        if (s == "true" || s == "1")  { v = true;  return true; }
        if (s == "false" || s == "0") { v = false; return true; }
        return false;
    };

    double a = 0.0, b = 0.0;
    if (as_double(sent, a) && as_double(eff, b))
        return ((a > b ? a - b : b - a) < 1e-6) ? "一致" : "不一致";

    bool ba = false, bb = false;
    if (as_bool(sent, ba) && as_bool(eff, bb))
        return (ba == bb) ? "一致" : "不一致";

    // 枚举：界面给的是下标，内核序列化成名字 → 用本文件自己的权威映射表（enum_name_from_index，
    // 也是 apply_params 赋值时用的同一张表）还原名字后比较。
    if (as_double(sent, a)) {
        const int idx = static_cast<int>(std::lround(a));
        const std::string* ename = enum_name_from_index(key, idx);
        if (ename != nullptr)
            return (*ename == eff) ? "一致" : "不一致";
    }
    return (sent == eff) ? "一致" : "不一致";
}

// 需要核对的键（界面可见、且直接决定成品）
const char* const k_audit_keys[] = {
    "layer_height",
    "initial_layer_line_width", "line_width", "outer_wall_line_width",
    "inner_wall_line_width", "top_surface_line_width", "sparse_infill_line_width",
    "wall_loops", "sparse_infill_density",
    "enable_support", "support_threshold_angle",
    "nozzle_temperature_initial_layer", "nozzle_temperature",
    "hot_plate_temp_initial_layer", "hot_plate_temp",
    "textured_plate_temp_initial_layer", "textured_plate_temp",
    "curr_bed_type", "filament_max_volumetric_speed",
};

void audit_write_block(const DynamicPrintConfig& cfg, const std::string& output_path,
                       const std::string& params_json, const std::vector<std::string>& skipped)
{
    namespace fs = boost::filesystem;
    boost::system::error_code ec;
    const fs::path out(output_path);
    const fs::path diag = out.parent_path() / "diag";
    fs::create_directories(diag, ec);
    std::ofstream f((diag / "gcode_diag.txt").string(), std::ios::app);
    if (!f)
        return;

    char ts[64] = { 0 };
    const std::time_t now = std::time(nullptr);
    std::tm tmv;
    std::memset(&tmv, 0, sizeof(tmv));
#if defined(_WIN32)
    localtime_s(&tmv, &now);
#else
    localtime_r(&now, &tmv);
#endif
    std::strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);

    const nlohmann::json sent = nlohmann::json::parse(params_json, nullptr, false);

    f << "\n===== [Audit] 切片参数核对 " << ts << " =====\n";
    f << "[Audit] 输出=" << output_path << "\n";
    for (const char* k : k_audit_keys) {
        const std::string s = audit_sent_text(sent, k);
        const std::string e = audit_opt_text(cfg, k);
        const std::string verdict = audit_verdict(cfg, k, s, e);
        f << "[Audit] " << k << " | 下发=" << (s.empty() ? std::string("<未下发>") : s)
          << " | 内核生效=" << e << " | " << verdict << "\n";
    }
    f << "[Audit] 被跳过的参数(" << skipped.size() << ")：";
    for (size_t i = 0; i < skipped.size() && i < 20; ++i)
        f << (i ? " , " : "") << skipped[i];
    if (skipped.size() > 20)
        f << " ...(其余省略)";
    f << "\n";

    std::vector<std::string> samples, temps;
    double wmin = 1e30, wmax = 0.0;
    long marks = 0;
    audit_scan_gcode(output_path, samples, wmin, wmax, marks, temps);
    f << "[Audit] gcode 线宽标注条数=" << marks
      << "（0 = 没有逐段线宽标注，预览会走 0.42mm 硬回退）\n";
    f << "[Audit] gcode 线宽极值: min=";
    if (wmin > 1e29) { f << "<无>"; } else { f << wmin; }
    f << " max=" << wmax << "\n";
    f << "[Audit] gcode 线宽首个样本(" << samples.size() << ")：";
    for (size_t i = 0; i < samples.size(); ++i)
        f << (i ? " , " : "") << samples[i];
    f << "\n";
    for (const std::string& t : temps)
        f << "[Audit] " << t << "\n";
    f << "[Audit] ===== 结束 =====\n";
    f.flush();
}

// 把 ArkTS 动态表单传来的扁平 JSON 叠加到 config 上。
//
// ArkTS 侧（SliceParamStore::collectParamsJson）把所有值都用 toFixed(4) 序列化成数字，
// 所以不能按 JSON 类型直接 config.set(key, number)，得按"目标选项的实际类型"转换
// （比如 enable_support 是 coBool，收到的是 0.0000/1.0000）：
//   * 枚举(coEnum)：ArkTS 传的是 enum_values 下标 -> 用 enum_name_from_index() 还原成内核名，
//     再 set_deserialize（内核用 enum_keys_map 把名字转回底层枚举值），下标语义与
//     enum_value_to_index() 收发同源
//   * 其余：转成字符串走各选项自己的 deserialize()，它能正确处理
//     bool("1"/"0")、coPercent/coFloatOrPercent、以及逗号分隔的向量
// 只接受内核已经存在的 key；类型不匹配或无法赋值的 key 记进 skipped 一并回报，
// 方便定位"界面上改了但切片没用上"的问题。

// protected_keys：**打印机预设项**（printable_*/nozzle_height/auxiliary_fan/scan_first_layer/
// machine_max_*/extruder_clearance_* 等）。这些值的权威来源是「当前选中的打印机预设」和
// 3MF 工程内嵌的 project_settings，UI 参数表里同名项只是 schema 兜底默认值（往往来自通用
// 默认配置，比如 X1 的 printable_height=250 / nozzle_height=4.2）。一旦被 UI 覆盖到 A1 mini
// 这种小机器上，喷头高度、限位、辅助风扇、首层扫描全都会错 —— 真机表现就是撞工具头盖、
// 动态流量校准堆料。传入非空集合时，命中项静默跳过（不进 skipped，避免刷屏）。
void apply_params(DynamicPrintConfig& config, const std::string& params_json, std::vector<std::string>& skipped,
                  const std::set<std::string>* protected_keys = nullptr)
{
    if (params_json.empty())
        return;

    const nlohmann::json j = nlohmann::json::parse(params_json, nullptr, false);
    if (j.is_discarded() || !j.is_object()) {
        skipped.emplace_back("<params_json 不是合法 JSON 对象>");
        return;
    }

    for (auto it = j.begin(); it != j.end(); ++it) {
        const std::string& key = it.key();

        // 「对象颜色 → 耗材槽位」请求（__bbs_ 前缀）不是内核配置项，由切片/导出流程单独消费
        // （见 parse_filament_request / apply_multicolor_request），这里静默跳过，
        // 不记进 skipped（否则会被误报成"未知配置项"）。
        if (key.rfind("__bbs_", 0) == 0)
            continue;

        // 打印机预设项一律以「预设 / 3MF 工程」为准，见函数头注释。
        // 例外：curr_bed_type 由界面（盘级床型 / 全局打印板）主动管理，故意不放进保护集。
        if (protected_keys != nullptr && protected_keys->find(key) != protected_keys->end())
            continue;

        ConfigOption* opt = config.option(key);
        if (opt == nullptr) {
            skipped.push_back(key + "(未知配置项)");
            continue;
        }
        if (opt->is_vector()) {
            // (1) 数组形态：调用方（耗材编辑）给出**完整向量** → 原样整段写入。
            //     与下面的「标量广播」严格区分：只有明确给了数组才整体覆盖，避免误伤
            //     按喷嘴分档的速度项（bridge_speed 等 coFloats，表单给标量会覆盖坏预设）。
            if (it.value().is_array()) {
                std::string text;
                // 单值数组：耗材编辑的覆盖值来自「当前耗材预设」的快照（单耗材机通常只有 1 档），
                // 而目标配置可能已按多耗材展开成 N 档。此时按档位数广播 —— 否则会把向量截成
                // 1 档（后续按槽位取值的代码会越界）。语义与下面的「标量广播」一致。
                int slots = 1;
                const std::string cur = opt->serialize();
                for (char c : cur) { if (c == ',') { ++slots; } }
                if (it.value().size() == 1 && slots > 1) {
                    const nlohmann::json& e0 = it.value()[0];
                    const std::string one = e0.is_string() ? e0.get<std::string>() : e0.dump();
                    for (int k = 0; k < slots; ++k) {
                        if (!text.empty()) { text += ","; }
                        text += one;
                    }
                } else {
                    for (const auto& e : it.value()) {
                        if (!text.empty()) { text += ","; }
                        // 字符串元素原样；数值/布尔用 JSON 的最短往返表示（1.75 / 0.98 / 1）
                        text += e.is_string() ? e.get<std::string>() : e.dump();
                    }
                }
                ConfigSubstitutionContext csc_vec{ForwardCompatibilitySubstitutionRule::Disable};
                config.set_deserialize(key, text, csc_vec, false);
                continue;
            }
            // (2) 标量 + 打印板温度：板温虽是数组，但一台机所有耗材档位共用一个床温，
            //     表单给标量语义成立 → 广播到数组现有各档位（保留数组长度）。
            if (it.value().is_number() && is_plate_temp_key(key)) {
                if (ConfigOptionInts* vi = dynamic_cast<ConfigOptionInts*>(opt)) {
                    if (!vi->values.empty()) {
                        const int t = static_cast<int>(std::lround(it.value().get<double>()));
                        for (int& x : vi->values) { x = t; }
                        continue;
                    }
                }
            }
            // (3) 标量 + 其它数值/布尔型数组：表单只给一个值（单喷嘴/单耗材机的常见情形），
            //     语义成立 → 广播到数组现有各档（长度不变）。这与拓竹原厂行为一致：
            //     Tab.cpp 改速度/风扇时也是把同一个值按挤出机档位数重复写入。
            //     实现上不依赖具体类型（不经 dynamic_cast）：按现有档位数拼出等长文本，
            //     再交给 set_deserialize 按配置项自身类型解析 —— 浮点/整数/百分比/布尔通吃。
            //     字符串型数组（起止 G-code、耗材名等）绝不在此列。
            {
                std::string item;
                const nlohmann::json& vv = it.value();
                if (vv.is_boolean()) {
                    item = vv.get<bool>() ? "1" : "0";
                } else if (vv.is_number()) {
                    item = vv.dump();
                } else if (vv.is_string()) {
                    const std::string s = vv.get<std::string>();
                    if (s == "true") { item = "1"; }
                    else if (s == "false") { item = "0"; }
                    else {
                        char* endp = nullptr;
                        std::strtod(s.c_str(), &endp);
                        if (endp != nullptr && endp != s.c_str() && *endp == '\0') { item = s; }
                    }
                }
                const std::string cur = opt->serialize();
                if (!item.empty() && !cur.empty()) {
                    int slots = 1;
                    for (char c : cur) { if (c == ',') { ++slots; } }
                    std::string text;
                    for (int k = 0; k < slots; ++k) {
                        if (k > 0) { text += ","; }
                        text += item;
                    }
                    ConfigSubstitutionContext csc_cast{ForwardCompatibilitySubstitutionRule::Disable};
                    // 注意：本内核版本的 set_deserialize 返回 void（不可用返回值判成败）→
                    // 用异常兜底：解析失败就往下面的 skipped 记录走，绝不影响已生效的其它参数。
                    try {
                        config.set_deserialize(key, text, csc_cast, false);
                        continue;
                    } catch (...) {
                    }
                }
            }
            skipped.push_back(key + "(向量型选项，保留预设值)");
            continue;
        }

        const nlohmann::json& v = it.value();
        try {
            if (opt->type() == coEnum) {
                int idx = 0;
                if (v.is_number())
                    idx = static_cast<int>(std::lround(v.get<double>()));
                else if (v.is_boolean())
                    idx = v.get<bool>() ? 1 : 0;
                else {
                    skipped.push_back(key + "(枚举需要数值下标)");
                    continue;
                }
                // 下标 -> 内核枚举名 -> 按名字赋值（唯一权威映射，见 enum_name_from_index）。
                // 不用 setInt(idx)：ConfigOptionEnum<T> 里存的枚举值不保证等于 enum_values 的下标
                // （BedType 的 enum_values 就漏了 btDefault，getInt()==1 对应下标 0）。
                // 这份名字表就是 slicer_enum_values() 发给表单的同一份，所以
                // "表单选第 idx 项" ≡ "这里取第 idx 个名字"，两边天然一致。
                const std::string* ename = enum_name_from_index(key, idx);
                if (ename == nullptr) {
                    skipped.push_back(key + "(枚举下标越界)");
                    continue;
                }
                ConfigSubstitutionContext csc_enum{ForwardCompatibilitySubstitutionRule::Disable};
                config.set_deserialize(key, *ename, csc_enum, false);
                continue;
            }

            std::string text;
            if (v.is_string())
                text = v.get<std::string>();
            else if (v.is_boolean())
                text = v.get<bool>() ? "1" : "0";
            else if (v.is_number_integer())
                text = std::to_string(v.get<long long>());
            else if (v.is_number_float()) {
                std::ostringstream oss;
                oss << v.get<double>(); // 不能用 std::to_string，它只有 6 位小数
                text = oss.str();
            } else {
                skipped.push_back(key + "(类型不支持)");
                continue;
            }

            ConfigSubstitutionContext csc{ForwardCompatibilitySubstitutionRule::Disable};
            config.set_deserialize(key, text, csc, false);
        } catch (const std::exception&) {
            // 例如把标量塞给数组型选项（filament_diameter 之类），忽略即可。
            skipped.push_back(key + "(赋值失败)");
        }
    }
}

} // namespace

// =============================================================================
//  预设（PresetBundle）
// =============================================================================

namespace {

// App 里可能同时有切片 worker 在跑，预设读写都加锁。
std::mutex                            g_preset_mutex;
std::unique_ptr<PresetBundle>         g_preset_bundle;
std::string                           g_resources_dir;

// 默认组合：对应 BambuStudio 新装后的默认选择（X1C 0.4 + 0.20mm Standard + Bambu PLA Basic）
const char* kDefaultPrinter  = "Bambu Lab X1 Carbon 0.4 nozzle";
const char* kDefaultProcess  = "0.20mm Standard @BBL X1C";
const char* kDefaultFilament = "Bambu PLA Basic @BBL X1C";

// 按名字选中，返回最终选中的名字。**空名字 = 不改动内核**（直接返回当前选中的名字）。
//
// 为什么空名字绝不能落到内核：PresetCollection::select_preset_by_name(force=false, select_invisible=false)
// 在名字找不到/不可见时会**静默退回"第一个可见预设"**（Preset.cpp:3233-3241 的 else 分支，从
// m_default_suppressed ? m_num_default_presets : 0 起扫 is_visible）。而 print 集合的非 default 预设
// 按名字 ASCII 升序排（Preset.cpp:1532/1744/2146 + Preset::operator<，Preset.hpp:349），
// 排在最前的可见预设是 "0.06mm Fine @BBL A1 0.2 nozzle"（层高 0.06）。
// 切机器时我们只传机型、工艺/耗材用空串表示"不要动"；一旦把空串透传下去，内核就会被这条
// 0.06 预设覆盖 —— 这正是"没请求工艺、层高却变 0.06"的独立成因。所以空名字在此直接 no-op。
//
// 非空名字走公共的 select_preset_by_name（它的 else 分支本身就是"退到第一个可见预设"；
// select_preset_by_name_strict 是 protected 的，外部用不了），用于 init 时的默认兜底。
template<class Coll>
std::string select_preset_if_given(Coll& coll, const std::string& name)
{
    if (!name.empty())
        coll.select_preset_by_name(name, /*force=*/false, /*select_invisible=*/false);
    return coll.get_selected_preset_name();
}

template<class Coll>
std::vector<std::string> visible_preset_names(const Coll& coll)
{
    std::vector<std::string> out;
    for (size_t i = 0; i < coll.size(); ++i) {
        const Preset& p = coll.preset(i);
        if (p.is_visible)
            out.push_back(p.name);
    }
    return out;
}

// 该名字是否"内核可选中"：存在且可见。
//
// 口径与内核 PresetCollection::select_preset_by_name(name, force=false, select_invisible=false)
// 完全一致 —— 内核的判断就两步（Preset.cpp:3217-3241）：
//   ① find_preset_internal(name) 命中且 name 完全相等；
//   ② is_visible 为真（select_invisible=false 时不再放宽）。
// 其中 is_visible 在载入时就等于 JSON 的 instantiation != "false"（Preset.cpp:1440），
// 也就是"模板预设"隐藏 —— 已包含在 is_visible 里，无需单独判断。
// 内核在这里**不检查 is_compatible**（兼容性只影响 update_compatible 的 is_compatible 标记，
// 不影响能否选中），所以本函数也不检查，避免出现"校验比内核更严/更松"的错配。
// 空串是合法输入（= 保持当前选择），直接放行。
template<class Coll>
bool preset_selectable(const Coll& coll, const std::string& name)
{
    if (name.empty())
        return true;
    const Preset* p = coll.find_preset(Preset::remove_suffix_modified(name), /*first_visible_if_not_found=*/false);
    return p != nullptr && p->is_visible;
}

// 用内核兼容性元数据筛出「对 active_printer 兼容」的预设名。
//
// 判断走 is_compatible_with_printer(preset, active_printer)：
//   * 预设带 compatible_printers 列表时 -> 按打印机预设全名精确匹配（不是后缀/模糊匹配）；
//   * 只有 compatible_printers_condition 表达式时 -> 内核用 PlaceholderParser 求值
//     （求值器在 libslic3r 内，本工程不需要 GUI 侧求值器）；
//   * 两者都没有 -> 内核语义视为"对任何打印机都兼容"。
// 跳过 default 预设与不可见预设，与 PresetCollection::update_compatible 的遍历口径一致。
template<class Coll>
std::vector<std::string> compatible_preset_names(const Coll& coll,
                                                 const PresetWithVendorProfile& active_printer)
{
    std::vector<std::string> out;
    for (size_t i = 0; i < coll.size(); ++i) {
        const Preset& p = coll.preset(i);
        if (p.is_default || !p.is_visible)
            continue;
        const PresetWithVendorProfile preset_with_vendor = coll.get_preset_with_vendor_profile(p);
        if (is_compatible_with_printer(preset_with_vendor, active_printer))
            out.push_back(p.name);
    }
    return out;
}

// 取预设里某个数值选项的"首个值"（向量型取首档，兼容 coFloats）；选项不存在返回 false。
// 只用于把候选列表连同 layer_height / nozzle 一起交给界面展示（只读展示信息，不参与选择）。
bool preset_first_number(const Preset& p, const char* key, double& out)
{
    const ConfigOption* o = p.config.option(key);
    if (o == nullptr)
        return false;
    if (o->is_vector()) {
        const std::string s = o->serialize();
        out = std::strtod(s.c_str(), nullptr);
        return true;
    }
    out = o->getFloat();
    return true;
}

nlohmann::json preset_option_item(const Preset& p)
{
    nlohmann::json item = nlohmann::json::object();
    item["name"] = p.name;
    double v = 0.0;
    if (preset_first_number(p, "layer_height", v))
        item["layerHeight"] = v;
    if (preset_first_number(p, "nozzle_diameter", v))
        item["nozzle"] = v;
    return item;
}

// 构造"可被选中"的权威候选表（调用方必须已持有 g_preset_mutex）。
//
// kind: 0=printer（全部可见机型）/ 1=process / 2=filament（后两者 = 当前选中的打印机下，
// 内核判定兼容的子集）。**列表顺序 = 内核集合顺序**：界面必须原样使用，界面回传的下标
// 就是这里的下标 —— 这就是"按索引选"能彻底消除"界面名字 ↔ 内核名字对不上"的原因。
//
// 关键：机型一律取内核自己"当前选中"的那一台，**不接收任何外部传入的名字**；
// 于是候选列表和内核当前机型永远同源，不存在"拿上一台机器的列表去下发"的可能。
nlohmann::json build_preset_options_locked(int kind)
{
    nlohmann::json out;
    out["ok"]   = false;
    out["kind"] = kind;

    if (!g_preset_bundle) {
        out["message"] = "预设未初始化";
        return out;
    }
    if (kind < 0 || kind > 2) {
        out["message"] = "kind 非法（应为 0=printer / 1=process / 2=filament）";
        return out;
    }

    nlohmann::json items = nlohmann::json::array();
    const std::string printer_name = g_preset_bundle->printers.get_selected_preset_name();
    std::string sel_name;

    if (kind == 0) {
        const PresetCollection& coll = g_preset_bundle->printers;
        for (size_t i = 0; i < coll.size(); ++i) {
            const Preset& p = coll.preset(i);
            if (!p.is_visible)
                continue;
            items.push_back(preset_option_item(p));
        }
        sel_name = printer_name;
    } else {
        // 目标机 = 内核当前选中的打印机（get_selected_preset 取编辑副本即可，兼容性元数据不受影响）
        const PresetWithVendorProfile active_printer =
            g_preset_bundle->printers.get_preset_with_vendor_profile(
                g_preset_bundle->printers.get_selected_preset());
        const PresetCollection& coll =
            (kind == 1) ? g_preset_bundle->prints : g_preset_bundle->filaments;
        for (size_t i = 0; i < coll.size(); ++i) {
            const Preset& p = coll.preset(i);
            if (p.is_default || !p.is_visible)
                continue;
            if (!is_compatible_with_printer(coll.get_preset_with_vendor_profile(p), active_printer))
                continue;
            items.push_back(preset_option_item(p));
        }
        sel_name = (kind == 1) ? g_preset_bundle->prints.get_selected_preset_name()
                               : g_preset_bundle->filaments.get_selected_preset_name();
    }

    int selected_index = -1;
    for (size_t i = 0; i < items.size(); ++i) {
        if (items[i]["name"].get<std::string>() == sel_name) {
            selected_index = static_cast<int>(i);
            break;
        }
    }

    out["ok"]            = true;
    out["printer"]       = printer_name;
    out["items"]         = items;
    out["selectedIndex"] = selected_index;
    out["selectedName"]  = sel_name;
    out["notes"]         = "候选 = 内核集合顺序（kind 1/2 已按 is_compatible_with_printer 过滤）；"
                           "界面直接用下标选择，不回传名字";
    return out;
}

// 当前预设合成出的完整配置（未初始化预设时退到内核默认值）。
DynamicPrintConfig current_full_config()
{
    if (!g_preset_bundle)
        return DynamicPrintConfig::full_print_config();

    DynamicPrintConfig cfg = g_preset_bundle->full_config();

    // 修 filament_settings_id：BBS 里这个字段是从「按槽位的 filament_presets[]」数组来的，
    // 而那套数组由 GUI（Plater/AMS）维护 —— 我们直接调内核没有它，所以它一直是
    // "Default Filament"。耗材的参数值本身取自 edited 预设（本来就是对的，配置块里
    // filament_density/filament_type 等与桌面版一致），这里只把名字补齐，使配置块一致。
    if (ConfigOptionStrings* ids = cfg.option<ConfigOptionStrings>("filament_settings_id")) {
        const std::string name = g_preset_bundle->filaments.get_selected_preset_name();
        if (!name.empty()) {
            for (std::string& v : ids->values)
                v = name;
        }
    }
    return cfg;
}

// =============================================================================
//  「对象颜色 → 耗材槽位」请求（多耗材切片）
//
//  请求随切片/导出参数一起由 ArkTS 侧下发（键名固定 __bbs_ 前缀，不受内核配置项表约束）：
//    __bbs_filament_count  : 耗材槽位数 N（>=1）
//    __bbs_filaments       : [{"colour":"#RRGGBB","type":"PLA"}, ...]（长度 N，按槽位顺序）
//    __bbs_object_filament : [slot0, slot1, ...]（与输入文件里的对象加载顺序一一对应，0 基）
//
//  语义：把「两个同类型不同颜色的对象」变成「两个耗材槽位」，让内核按对象分挤出机，
//  切出多耗材 gcode（产物里 ; filament 会列出两个槽位）。
// =============================================================================
struct FilamentReq {
    bool                     present = false;
    int                      count = 0;
    std::vector<std::string> colour;
    std::vector<std::string> type;
    std::vector<int>         obj_slot;
    // 组合件分组（与对象加载顺序一一对应；>=0 同号 = 同一件的不同 part，切片前合并成一个对象）。
    // 空 = 不做合并（原始文件自带多 part 对象、或对象之间本就没有组合关系）。
    std::vector<int>         assembly;
};

FilamentReq parse_filament_request(const std::string& params_json)
{
    FilamentReq r;
    if (params_json.empty())
        return r;
    const nlohmann::json j = nlohmann::json::parse(params_json, nullptr, false);
    if (j.is_discarded() || !j.is_object())
        return r;

    const auto itc = j.find("__bbs_filament_count");
    const auto itf = j.find("__bbs_filaments");
    const auto ito = j.find("__bbs_object_filament");
    if (itc == j.end() && itf == j.end() && ito == j.end())
        return r;

    if (itf != j.end() && itf->is_array()) {
        for (const auto& e : *itf) {
            std::string c, t;
            if (e.is_object()) {
                const auto ic = e.find("colour");
                if (ic != e.end() && ic->is_string()) c = ic->get<std::string>();
                const auto itp = e.find("type");
                if (itp != e.end() && itp->is_string()) t = itp->get<std::string>();
            }
            r.colour.push_back(c);
            r.type.push_back(t);
        }
    }
    r.count = static_cast<int>(r.colour.size());
    if (itc != j.end() && itc->is_number()) {
        const int n = static_cast<int>(std::lround(itc->get<double>()));
        if (n > r.count) r.count = n;
    }
    if (ito != j.end() && ito->is_array()) {
        for (const auto& e : *ito) {
            int s = 0;
            if (e.is_number_integer()) s = e.get<int>();
            else if (e.is_number())     s = static_cast<int>(std::lround(e.get<double>()));
            r.obj_slot.push_back(s);
        }
    }
    // 组合件分组：与对象顺序一一对应（不参与 present 判定 —— 它只影响「是否合并」）
    const auto ita = j.find("__bbs_assembly");
    if (ita != j.end() && ita->is_array()) {
        for (const auto& e : *ita) {
            int g = -1;
            if (e.is_number_integer()) g = e.get<int>();
            else if (e.is_number())     g = static_cast<int>(std::lround(e.get<double>()));
            r.assembly.push_back(g);
        }
    }
    r.present = (r.count > 0) && (r.count > 1 || !r.obj_slot.empty());
    return r;
}

// 借内核自身的「多耗材预设展开」路径重建配置：PresetBundle::set_num_filaments + full_config()。
// 为什么不用 DynamicPrintConfig::set_num_filaments：它只覆盖 filament_option_keys 那一小撮键，
// filament_type / 温度 / flush_* 等按耗材数变化的向量不在其中；而 full_fff_config 的多耗材分支
// 会把每个耗材预设的所有向量项逐一拼接，天然把整套配置展开到 N 档。展开后立刻把预设恢复成
// 原来的档数，避免污染界面用的 config 快照。
DynamicPrintConfig build_config_with_filaments(int n)
{
    if (!g_preset_bundle || n <= 1)
        return current_full_config();

    const size_t old_n = g_preset_bundle->filament_presets.size();
    if (old_n < 1)
        return current_full_config();

    // 防御：PresetBundle::set_num_filaments / update_multi_material_filament_presets 会直接解引用
    // project_config 上的一批向量项。官方 GUI 流程里它们一定存在，但我们走的是裁剪过的加载路径，
    // 不能假设齐全 —— 缺的先用内核默认值补出来，再展开；这样绝不空指针，也保证展开真正发生。
    {
        static const char* const k_need[] = {
            "filament_colour", "filament_multi_colour", "filament_colour_type",
            "filament_map", "filament_nozzle_map", "filament_volume_map",
            "flush_volumes_matrix", "flush_volumes_vector",
            "flush_multiplier", "flush_multiplier_fast",
            "filament_is_mixed", "filament_mixed_components", "filament_mixed_sublayer_ratios",
            "filament_mixed_gradient", "filament_mixed_gradient_range",
            "filament_mixed_gradient_curve", "filament_mixed_gradient_per_part",
        };
        const DynamicPrintConfig defaults = DynamicPrintConfig::full_print_config();
        for (const char* k : k_need) {
            if (g_preset_bundle->project_config.option(k) == nullptr) {
                const ConfigOption* d = defaults.option(k);
                if (d != nullptr)
                    g_preset_bundle->project_config.set_key_value(k, d->clone());
            }
        }
    }

    g_preset_bundle->set_num_filaments(static_cast<unsigned>(n));
    DynamicPrintConfig cfg = current_full_config();
    g_preset_bundle->set_num_filaments(static_cast<unsigned>(old_n));
    return cfg;
}

// 兜底：确保「按耗材数变化」的向量在最终配置里长度自洽（N 档 / N*N 冲刷矩阵 / 1 档 per-head）。
// 即便预设展开路径有缺失，也能让内核的 flush 矩阵校验
// （GCode.cpp:500 `filament_count^2 * heads == flush_volumes_matrix.size()`）通过。
void ensure_multicolor_consistency(DynamicPrintConfig& cfg, int n)
{
    if (n <= 1)
        return;
    int heads = 1;
    if (const ConfigOptionFloats* nd = cfg.option<ConfigOptionFloats>("nozzle_diameter"))
        heads = static_cast<int>(nd->values.empty() ? 1 : nd->values.size());

    const size_t want_matrix = static_cast<size_t>(n) * static_cast<size_t>(n) * static_cast<size_t>(heads);
    if (ConfigOption* o = cfg.option("flush_volumes_matrix", false)) {
        if (o->is_vector()) {
            ConfigOptionVectorBase* vb = static_cast<ConfigOptionVectorBase*>(o);
            if (vb->size() != want_matrix)
                vb->resize(want_matrix, nullptr);   // 复制首档填满（对角线非 0 仅影响冲刷量，不影响正确性）
        }
    }
    if (ConfigOption* o = cfg.option("flush_volumes_vector", false)) {
        if (o->is_vector()) {
            ConfigOptionVectorBase* vb = static_cast<ConfigOptionVectorBase*>(o);
            const size_t want = static_cast<size_t>(2) * static_cast<size_t>(n);
            if (vb->size() != want)
                vb->resize(want, nullptr);
        }
    }
    for (const char* k : { "flush_multiplier", "flush_multiplier_fast" }) {
        if (ConfigOption* o = cfg.option(k, false)) {
            if (o->is_vector()) {
                ConfigOptionVectorBase* vb = static_cast<ConfigOptionVectorBase*>(o);
                if (vb->size() != static_cast<size_t>(heads))
                    vb->resize(static_cast<size_t>(heads), nullptr);
            }
        }
    }
    // 映射类：长度 = 耗材槽位数
    struct MapDef { const char* key; int def; };
    const MapDef maps[] = {
        { "filament_map", 1 }, { "filament_map_2", 1 }, { "filament_nozzle_map", 0 },
        { "filament_volume_map", 0 }, { "filament_self_index", 1 },
    };
    for (const MapDef& md : maps) {
        if (ConfigOption* o = cfg.option(md.key, false)) {
            if (o->is_vector()) {
                ConfigOptionVectorBase* vb = static_cast<ConfigOptionVectorBase*>(o);
                if (vb->size() != static_cast<size_t>(n))
                    vb->resize(static_cast<size_t>(n), nullptr);
            }
        }
    }
}

// 多耗材现场诊断落盘（<输出目录>/diag/gcode_diag.txt），供真机 hdc 取证。
void multicolor_diag(const std::string& output_path, const DynamicPrintConfig& cfg,
                     const DynamicPrintConfig& cfgN, const FilamentReq& r)
{
    namespace fs = boost::filesystem;
    boost::system::error_code ec;
    const fs::path diag = fs::path(output_path).parent_path() / "diag";
    fs::create_directories(diag, ec);
    std::ofstream f((diag / "gcode_diag.txt").string(), std::ios::app);
    if (!f)
        return;
    auto vecsize = [](const DynamicPrintConfig& c, const char* k) -> long long {
        const ConfigOption* o = c.option(k);
        if (o == nullptr) return -1;
        if (!o->is_vector()) return -2;
        return static_cast<long long>(static_cast<const ConfigOptionVectorBase*>(o)->size());
    };
    f << "\n[MultiColor] 请求 槽位=" << r.count << " 对象数=" << r.obj_slot.size() << "\n";
    f << "[MultiColor] cfgN(展开基准) filament_colour=" << vecsize(cfgN, "filament_colour")
      << " filament_type=" << vecsize(cfgN, "filament_type")
      << " flush_volumes_matrix=" << vecsize(cfgN, "flush_volumes_matrix")
      << " flush_multiplier=" << vecsize(cfgN, "flush_multiplier") << "\n";
    f << "[MultiColor] cfg(最终) filament_colour=" << vecsize(cfg, "filament_colour")
      << " filament_type=" << vecsize(cfg, "filament_type")
      << " filament_density=" << vecsize(cfg, "filament_density")
      << " flush_volumes_matrix=" << vecsize(cfg, "flush_volumes_matrix")
      << " flush_volumes_vector=" << vecsize(cfg, "flush_volumes_vector")
      << " flush_multiplier=" << vecsize(cfg, "flush_multiplier")
      << " filament_map=" << vecsize(cfg, "filament_map") << "\n";
    f.flush();
}

// 把请求里的颜色/类型写进配置的 filament_colour / filament_type（按槽位顺序）。
void apply_filament_colours(DynamicPrintConfig& cfg, const FilamentReq& r)
{
    if (!r.present || r.count <= 0)
        return;
    const int n = r.count;
    if (ConfigOptionStrings* fc = cfg.option<ConfigOptionStrings>("filament_colour")) {
        while (static_cast<int>(fc->values.size()) < n)
            fc->values.push_back(fc->values.empty() ? std::string("#F2F2F0") : fc->values.front());
        for (int i = 0; i < n && i < static_cast<int>(r.colour.size()); ++i)
            if (!r.colour[i].empty()) fc->values[i] = r.colour[i];
    }
    if (ConfigOptionStrings* ft = cfg.option<ConfigOptionStrings>("filament_type")) {
        while (static_cast<int>(ft->values.size()) < n)
            ft->values.push_back(ft->values.empty() ? std::string("PLA") : ft->values.front());
        for (int i = 0; i < n && i < static_cast<int>(r.type.size()); ++i)
            if (!r.type[i].empty()) ft->values[i] = r.type[i];
    }
}

// 颜色归一：大小写/空白不敏感（"#ffffff" 与 "#FFFFFF" 视为同一色）
static std::string norm_colour(std::string s)
{
    for (char& c : s)
        c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t'))
        s.pop_back();
    return s;
}

// 把「每个对象 → 耗材槽位」写到模型对象/体的 extruder 上（1 基，与 filament_map 口径一致）。
// 对象顺序 = 输入文件里的加载顺序（ArkTS 侧按同一顺序下发 slot 列表）。
// file_palette = 输入文件自带的调色板（project_settings.config 的 filament_colour，改写前取）。
void apply_object_filaments(Model& model, const FilamentReq& r,
                            const std::vector<std::string>& file_palette)
{
    if (!r.present || r.obj_slot.empty())
        return;
    const int n = r.count > 0 ? r.count : 1;

    // ---- 情形 A：输入文件的对象数与请求一一对应（裸网格 / 我们自建工程）----
    if (model.objects.size() == r.obj_slot.size()) {
        for (size_t i = 0; i < model.objects.size(); ++i) {
            int id = r.obj_slot[i] + 1;
            if (id < 1) id = 1;
            if (id > n) id = n;
            ModelObject* mo = model.objects[i];
            if (mo == nullptr)
                continue;
            mo->config.set_key_value("extruder", new ConfigOptionInt(id));
            for (ModelVolume* mv : mo->volumes)
                if (mv != nullptr)
                    mv->config.set_key_value("extruder", new ConfigOptionInt(id));
        }
        return;
    }

    // ---- 情形 B：对象数不一致 ----
    // 典型：工程 3MF 把「一个对象 + 多个 part」交给内核（part 级 extruder 指向文件调色板），
    // 而我们的预览模型是按「显示色/耗材」拆成多条 entry 的（对象数 = 色块数 ≠ 文件对象数）。
    // 这时若仍按对象下标硬套，会把**所有 part** 都改成 1 号槽：多色退化成单色，
    // 擦料塔也随之消失（实测华为徽章：filament_colour 有两档，gcode 头却是 `; filament: 1`）。
    // 正确做法：part 的原 extruder → 文件调色板颜色 → 请求槽位颜色 重映射；匹配不到就保持原值。
    std::map<std::string, int> slot_of_colour;
    for (int i = 0; i < n && i < static_cast<int>(r.colour.size()); ++i) {
        if (!r.colour[i].empty())
            slot_of_colour[norm_colour(r.colour[i])] = i + 1;
    }
    if (slot_of_colour.empty() || file_palette.empty())
        return;
    for (ModelObject* mo : model.objects) {
        if (mo == nullptr)
            continue;
        for (ModelVolume* mv : mo->volumes) {
            if (mv == nullptr)
                continue;
            int old_ext = 1;
            if (const ConfigOptionInt* e = dynamic_cast<const ConfigOptionInt*>(mv->config.option("extruder")))
                old_ext = e->getInt();
            if (old_ext < 1 || old_ext > static_cast<int>(file_palette.size()))
                continue;
            const auto it = slot_of_colour.find(norm_colour(file_palette[old_ext - 1]));
            if (it == slot_of_colour.end() || it->second == old_ext)
                continue;
            mv->config.set_key_value("extruder", new ConfigOptionInt(it->second));
        }
    }
}

// 「按耗材槽位数变化」的配置键集合：耗材预设里出现过的所有键，外加 multi_filament 场景下
// full_fff_config / set_num_filaments 额外显式维护的项目级向量（flush 矩阵、filament_map 等）。
// 用预设自带的键表而不是手写清单，是为了不漏掉温度/风扇/收缩率这些也在耗材预设里的向量项。
std::set<std::string> filament_multicount_keys()
{
    std::set<std::string> keys;
    if (g_preset_bundle) {
        const t_config_option_keys& pk = g_preset_bundle->filaments.default_preset().config.keys();
        for (const std::string& k : pk)
            keys.insert(k);
    }
    static const char* const extra[] = {
        "filament_map", "filament_map_2", "filament_nozzle_map", "filament_volume_map",
        "filament_self_index", "filament_settings_id", "filament_ids", "filament_multi_colour",
        "filament_colour_type", "filament_is_mixed", "filament_is_support",
        "filament_mixed_components", "filament_mixed_sublayer_ratios", "filament_mixed_gradient",
        "filament_mixed_gradient_range", "filament_mixed_gradient_curve",
        "filament_mixed_gradient_per_part", "flush_volumes_matrix", "flush_volumes_vector",
    };
    for (const char* k : extra)
        keys.insert(k);
    return keys;
}

// 把 dst 里「按耗材槽位数变化」的向量项替换成 srcN（已按 N 档展开）的对应值。
void expand_filament_vectors(DynamicPrintConfig& dst, const DynamicPrintConfig& srcN)
{
    const std::set<std::string> keys = filament_multicount_keys();
    for (const std::string& key : keys) {
        const ConfigOption* a = srcN.option(key);
        if (a == nullptr || !a->is_vector())
            continue;
        const ConfigOptionVectorBase* av = static_cast<const ConfigOptionVectorBase*>(a);
        ConfigOption* b = dst.option(key, false);
        ConfigOptionVectorBase* bv = (b != nullptr && b->is_vector())
            ? static_cast<ConfigOptionVectorBase*>(b) : nullptr;
        if (bv != nullptr && bv->size() == av->size()) {
            b->set(a);
        } else {
            dst.set_key_value(key, a->clone());
        }
    }
}

// 切片/导出统一的「多耗材请求」落地：把配置展开到 N 档 + 写入颜色/类型 + 给对象分配挤出机。
// 必须在 load_model_file 与 apply_params 之后调用（加载器可能把耗材向量压回 1 档）。
// output_path 非空时把现场诊断写进 <输出目录>/diag/gcode_diag.txt（真机取证用）。
void apply_multicolor_request(Model& model, DynamicPrintConfig& cfg, const FilamentReq& r,
                              const std::string& output_path)
{
    if (!r.present || r.count <= 1)
        return;
    // N 档基准配置（来自内核自身的多耗材预设展开），全程持预设锁，避免与界面侧的 config 查询竞争。
    DynamicPrintConfig cfgN;
    {
        std::lock_guard<std::mutex> lock(g_preset_mutex);
        cfgN = build_config_with_filaments(r.count);
    }
    // 输入文件自带的调色板必须在**改写前**取：它就是 part 级 extruder 的「颜色语义」参照。
    std::vector<std::string> file_palette;
    if (const ConfigOptionStrings* fc0 = cfg.option<ConfigOptionStrings>("filament_colour"))
        file_palette = fc0->values;
    expand_filament_vectors(cfg, cfgN);
    ensure_multicolor_consistency(cfg, r.count);
    apply_filament_colours(cfg, r);
    apply_object_filaments(model, r, file_palette);
    if (!output_path.empty())
        multicolor_diag(output_path, cfg, cfgN, r);
}

// 把 rawfile 里取出的 bambu_res.zip（内存）解到 <files_dir>/bambu_res。
// 用 <res_dir>/.zip_size 做标记：大小一致说明是同一份 zip，跳过重复解压
// （2500+ 个文件，每次启动都解会很慢）。
bool extract_presets(const std::string& res_dir, const void* zip_data, size_t zip_size, std::string& err)
{
    namespace fs = boost::filesystem;
    const std::string marker = res_dir + "/.zip_size";

    if (fs::exists(res_dir + "/profiles/BBL.json") && fs::exists(marker)) {
        std::ifstream in(marker);
        size_t recorded = 0;
        if ((in >> recorded) && recorded == zip_size)
            return true;
    }

    mz_zip_archive zip;
    std::memset(&zip, 0, sizeof(zip));
    if (!mz_zip_reader_init_mem(&zip, zip_data, zip_size, 0)) {
        err = "bambu_res.zip 打开失败（rawfile 里的预设包可能损坏）";
        return false;
    }

    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    for (mz_uint i = 0; i < count; ++i) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&zip, i, &st))
            continue;
        const std::string name = st.m_filename;
        if (name.empty() || name.back() == '/')
            continue; // 目录项，靠下面 create_directories 隐式建出来

        const std::string out_path = res_dir + "/" + name;
        boost::system::error_code ec;
        fs::create_directories(fs::path(out_path).parent_path(), ec);
        if (!mz_zip_reader_extract_to_file(&zip, i, out_path.c_str(), 0)) {
            err = "预设解压失败: " + name;
            mz_zip_reader_end(&zip);
            return false;
        }
    }
    mz_zip_reader_end(&zip);

    std::ofstream out(marker, std::ios::trunc);
    out << zip_size;
    return true;
}

} // namespace

std::string slicer_init_presets(const std::string& files_dir,
                                const void*        preset_zip,
                                size_t             preset_zip_size)
{
    nlohmann::json out;
    out["ok"] = false;

    if (files_dir.empty()) {
        out["message"] = "未指定 files_dir";
        return out.dump();
    }

    const std::string res_dir = files_dir + "/bambu_res";

    std::lock_guard<std::mutex> lock(g_preset_mutex);
    try {
        // 1) 首次运行把 rawfile 里的预设包解开（纯内存 miniz → 文件）
        if (preset_zip != nullptr && preset_zip_size > 0) {
            std::string err;
            if (!extract_presets(res_dir, preset_zip, preset_zip_size, err)) {
                out["message"] = err;
                return out.dump();
            }
        }

        // 2) 让内核的资源查找（info/filament_info.json、flush/*.txt 等）指向解压出来的目录，
        //    data_dir 指到 App 私有目录（预设派生/日志等只写这里）。
        set_resources_dir(res_dir);
        set_data_dir(files_dir);
        g_resources_dir = res_dir;

        auto bundle = std::make_unique<PresetBundle>();
        // 只加载 BBL（我们只打包了 BBL.json）：LoadSystem 会先 reset 再填充 printers/prints/filaments
        bundle->load_vendor_configs_from_json(res_dir + "/profiles", "BBL",
                                              PresetBundle::LoadSystem,
                                              ForwardCompatibilitySubstitutionRule::EnableSilent);

        const std::string sel_printer  = select_preset_if_given(bundle->printers,  kDefaultPrinter);
        const std::string sel_process  = select_preset_if_given(bundle->prints,    kDefaultProcess);
        const std::string sel_filament = select_preset_if_given(bundle->filaments, kDefaultFilament);

        out["ok"]        = true;
        out["selected"]  = { {"printer", sel_printer}, {"process", sel_process}, {"filament", sel_filament} };
        out["printers"]  = visible_preset_names(bundle->printers);
        out["processes"] = visible_preset_names(bundle->prints);
        out["filaments"] = visible_preset_names(bundle->filaments);

        g_preset_bundle = std::move(bundle);
        return out.dump();
    } catch (const std::exception& e) {
        g_preset_bundle.reset();
        out["message"] = std::string("预设加载失败(") + res_dir + "): " + e.what();
        return out.dump();
    }
}

std::string slicer_select_presets(const std::string& printer, const std::string& process, const std::string& filament)
{
    nlohmann::json out;
    out["ok"] = false;

    std::lock_guard<std::mutex> lock(g_preset_mutex);
    if (!g_preset_bundle) {
        out["message"] = "预设未初始化";
        return out.dump();
    }

    try {
        out["requested"] = { {"printer", printer}, {"process", process}, {"filament", filament} };

        // 切换前的快照：失败回滚要恢复到这三个名字。空串请求不会改动内核，回滚时同样保持原值。
        const std::string prev_printer  = g_preset_bundle->printers.get_selected_preset_name();
        const std::string prev_process  = g_preset_bundle->prints.get_selected_preset_name();
        const std::string prev_filament = g_preset_bundle->filaments.get_selected_preset_name();

        // 先校验再改：只要有一个非空请求名内核不可选中，就整体不动。
        // 不这么做的话，内核会退到"第一个可见预设"，而 ArkTS 仍把下拉停在用户点的那一行 ——
        // 于是"界面显示 A、参数值来自 B"，层高错值正是这种错位。
        const bool ok_printer  = preset_selectable(g_preset_bundle->printers,  printer);
        const bool ok_process  = preset_selectable(g_preset_bundle->prints,    process);
        const bool ok_filament = preset_selectable(g_preset_bundle->filaments, filament);

        if (!ok_printer || !ok_process || !ok_filament) {
            nlohmann::json nf = nlohmann::json::array();
            if (!ok_printer)  nf.push_back(std::string("打印机预设 \"") + printer  + "\" 内核不可选中");
            if (!ok_process)  nf.push_back(std::string("工艺预设 \"")   + process  + "\" 内核不可选中");
            if (!ok_filament) nf.push_back(std::string("耗材预设 \"")   + filament + "\" 内核不可选中");
            out["notFound"]   = nf;
            out["message"]    = nf.front().get<std::string>();
            out["rolledBack"] = false;
            // 校验未过就没有下发，内核仍在 prev_*，如实回报让界面维持"显示 == 内核"。
            out["selected"]     = { {"printer", prev_printer}, {"process", prev_process}, {"filament", prev_filament} };
            out["rolledBackTo"] = out["selected"];
            if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
                out["layerHeight"] = lh->value;
            return out.dump();
        }

        // 真正下发（空串跳过，不调用内核）。
        const std::string sel_printer  = select_preset_if_given(g_preset_bundle->printers,  printer);
        const std::string sel_process  = select_preset_if_given(g_preset_bundle->prints,    process);
        const std::string sel_filament = select_preset_if_given(g_preset_bundle->filaments, filament);

        // 回读比对：任一**非空**请求与内核回读值不一致，说明内核没真正认下它
        //（它内部已退到第一个可见预设，如 0.06mm 那条）。此时必须回滚 —— 否则内核会滞留在
        // 被回退后的状态，界面再怎么刷新也都是错的层高。耗材/工艺/机型一并比对。
        const bool mismatch =
            (!printer.empty()  && sel_printer  != printer)  ||
            (!process.empty()  && sel_process  != process)  ||
            (!filament.empty() && sel_filament != filament);

        if (mismatch) {
            // 恢复到切换前的快照。prev_* 是切换前真正选中的名字（存在且可见），用同一套
            // select_preset_by_name 一定能选回；回读后即等于 prev_* —— 这就是"内核绝不会停在 0.06"的保证。
            select_preset_if_given(g_preset_bundle->printers,  prev_printer);
            select_preset_if_given(g_preset_bundle->prints,    prev_process);
            select_preset_if_given(g_preset_bundle->filaments, prev_filament);

            nlohmann::json nf = nlohmann::json::array();
            if (!printer.empty()  && sel_printer  != printer)  nf.push_back(std::string("打印机预设 \"") + printer  + "\" 内核回读为 \"" + sel_printer  + "\"");
            if (!process.empty()  && sel_process  != process)  nf.push_back(std::string("工艺预设 \"")   + process  + "\" 内核回读为 \"" + sel_process  + "\"");
            if (!filament.empty() && sel_filament != filament) nf.push_back(std::string("耗材预设 \"")   + filament + "\" 内核回读为 \"" + sel_filament + "\"");

            const nlohmann::json restored = {
                {"printer",  g_preset_bundle->printers.get_selected_preset_name()},
                {"process",  g_preset_bundle->prints.get_selected_preset_name()},
                {"filament", g_preset_bundle->filaments.get_selected_preset_name()},
            };
            out["ok"]           = false;
            out["rolledBack"]   = true;
            out["notFound"]     = nf;
            out["message"]      = std::string("该预设不适用于当前机型，已回滚到切换前的预设（") + nf.front().get<std::string>() + "）";
            out["selected"]     = restored;
            out["rolledBackTo"] = restored;
            if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
                out["layerHeight"] = lh->value;
            return out.dump();
        }

        out["ok"]           = true;
        out["rolledBack"]   = false;
        out["selected"]     = { {"printer", sel_printer}, {"process", sel_process}, {"filament", sel_filament} };
        out["rolledBackTo"] = { {"printer", prev_printer}, {"process", prev_process}, {"filament", prev_filament} };

        // 回读当前合成的层高：这就是界面"层高"该显示的值。ArkTS 把
        //「请求名 / 内核选中名 / 回读层高 / 结果」一起打日志，错值来源一眼可见。
        if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
            out["layerHeight"] = lh->value;
        return out.dump();
    } catch (const std::exception& e) {
        out["message"] = std::string("切换预设失败: ") + e.what();
        return out.dump();
    }
}

std::string slicer_preset_options(int kind)
{
    std::lock_guard<std::mutex> lock(g_preset_mutex);
    try {
        return build_preset_options_locked(kind).dump();
    } catch (const std::exception& e) {
        nlohmann::json out;
        out["ok"]     = false;
        out["kind"]   = kind;
        out["message"] = std::string("预设候选读取失败: ") + e.what();
        return out.dump();
    }
}

std::string slicer_select_preset_by_index(int kind, int index)
{
    nlohmann::json out;
    out["ok"]    = false;
    out["kind"]  = kind;
    out["index"] = index;

    std::lock_guard<std::mutex> lock(g_preset_mutex);
    if (!g_preset_bundle) {
        out["message"] = "预设未初始化";
        return out.dump();
    }
    if (kind < 0 || kind > 2) {
        out["message"] = "kind 非法（应为 0=printer / 1=process / 2=filament）";
        return out.dump();
    }

    try {
        // 切换前的快照：任何失败路径都回滚到这里，保证内核绝不滞留在"被静默回退"的状态。
        const std::string prev_printer  = g_preset_bundle->printers.get_selected_preset_name();
        const std::string prev_process  = g_preset_bundle->prints.get_selected_preset_name();
        const std::string prev_filament = g_preset_bundle->filaments.get_selected_preset_name();
        const nlohmann::json snapshot   = { {"printer",  prev_printer},
                                            {"process",  prev_process},
                                            {"filament", prev_filament} };

        // 用「内核自己的候选表」把 index 解析成名字：这是唯一的 index->name 映射。
        // 界面永远不回传名字，因此不存在"界面名字 ↔ 内核名字对不上"。
        const nlohmann::json opts = build_preset_options_locked(kind);
        if (opts.value("ok", false) != true) {
            out["message"]      = opts.value("message", std::string("候选表不可用"));
            out["rolledBack"]   = false;
            out["selected"]     = snapshot;
            out["rolledBackTo"] = snapshot;
            if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
                out["layerHeight"] = lh->value;
            return out.dump();
        }

        const nlohmann::json& items = opts["items"];
        if (index < 0 || static_cast<size_t>(index) >= items.size()) {
            // 越界/无效输入一律 no-op（不碰内核），如实回报当前选中项
            out["message"]      = std::string("索引越界：候选共 ") + std::to_string(items.size())
                                  + " 项，收到 " + std::to_string(index);
            out["rolledBack"]   = false;
            out["selected"]     = snapshot;
            out["rolledBackTo"] = snapshot;
            if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
                out["layerHeight"] = lh->value;
            return out.dump();
        }

        const std::string target = items[static_cast<size_t>(index)].value("name", std::string());
        out["requestedName"] = target;
        out["requested"]     = { {"printer",  kind == 0 ? target : prev_printer},
                                 {"process",  kind == 1 ? target : prev_process},
                                 {"filament", kind == 2 ? target : prev_filament} };

        std::string sel_printer  = prev_printer;
        std::string sel_process  = prev_process;
        std::string sel_filament = prev_filament;
        if (kind == 0) sel_printer  = select_preset_if_given(g_preset_bundle->printers,  target);
        if (kind == 1) sel_process  = select_preset_if_given(g_preset_bundle->prints,    target);
        if (kind == 2) sel_filament = select_preset_if_given(g_preset_bundle->filaments, target);

        const std::string& readback = (kind == 0) ? sel_printer
                                    : ((kind == 1) ? sel_process : sel_filament);

        if (readback != target) {
            // 回读与"请求索引对应的项"不一致 -> 内核没真正认下它（可能已静默回退）。
            // 回滚到切换前的三个预设，内核+界面一起回到一致状态。
            select_preset_if_given(g_preset_bundle->printers,  prev_printer);
            select_preset_if_given(g_preset_bundle->prints,    prev_process);
            select_preset_if_given(g_preset_bundle->filaments, prev_filament);
            const nlohmann::json restored = {
                {"printer",  g_preset_bundle->printers.get_selected_preset_name()},
                {"process",  g_preset_bundle->prints.get_selected_preset_name()},
                {"filament", g_preset_bundle->filaments.get_selected_preset_name()},
            };
            out["ok"]           = false;
            out["rolledBack"]   = true;
            out["message"]      = std::string("索引 ") + std::to_string(index) + " 对应的预设 \""
                                  + target + "\" 未能生效（内核回读为 \"" + readback
                                  + "\"），已回滚到切换前状态";
            out["selected"]     = restored;
            out["rolledBackTo"] = restored;
            if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
                out["layerHeight"] = lh->value;
            return out.dump();
        }

        out["ok"]           = true;
        out["rolledBack"]   = false;
        out["selected"]     = { {"printer",  sel_printer},
                                {"process",  sel_process},
                                {"filament", sel_filament} };
        out["rolledBackTo"] = snapshot;
        if (const ConfigOptionFloat* lh = current_full_config().option<ConfigOptionFloat>("layer_height"))
            out["layerHeight"] = lh->value;
        return out.dump();
    } catch (const std::exception& e) {
        out["message"] = std::string("按索引切换预设失败: ") + e.what();
        return out.dump();
    }
}

std::string slicer_printer_bed()
{
    nlohmann::json out;
    out["ok"] = false;

    std::lock_guard<std::mutex> lock(g_preset_mutex);
    if (!g_preset_bundle) {
        out["message"] = "预设未初始化";
        return out.dump();
    }

    try {
        // 打印机预设（edited = 当前生效的那份）里的 printable_area / printable_height 才是权威值，
        // 与 full_config()（贴板居中用它）用的是同一份数据，保证"模型摆放"和"画出来的板"同坐标系。
        const Preset&             printer = g_preset_bundle->printers.get_edited_preset();
        const DynamicPrintConfig& cfg     = printer.config;

        const ConfigOptionPoints* area = cfg.option<ConfigOptionPoints>("printable_area");
        if (area == nullptr || area->values.size() < 2)
            area = cfg.option<ConfigOptionPoints>("bed_shape");
        if (area == nullptr || area->values.size() < 2) {
            out["message"] = std::string("打印机预设 \"") + printer.name + "\" 缺少 printable_area/bed_shape";
            return out.dump();
        }

        nlohmann::json pts = nlohmann::json::array();
        double min_x = 0.0, min_y = 0.0, max_x = 0.0, max_y = 0.0;
        if (!bed_bbox_from_config(cfg, min_x, min_y, max_x, max_y)) {
            out["message"] = std::string("打印机预设 \"") + printer.name + "\" 的打印板点列表异常";
            return out.dump();
        }
        for (const Vec2d& p : area->values)
            pts.push_back({ p.x(), p.y() });

        // printable_height 内核里是 coFloat；这里同时容忍向量型（按挤出机分档时取首档）。
        double height = 0.0;
        if (const ConfigOption* hp = cfg.option("printable_height")) {
            if (hp->is_vector()) {
                const std::string s = hp->serialize();
                height = std::strtod(s.c_str(), nullptr);
            } else {
                height = hp->getFloat();
            }
        }

        out["ok"]      = true;
        out["printer"] = printer.name;
        out["area"]    = pts;                                    // 完整多边形点列表，不是首元素
        out["height"]  = height;
        out["bbox"]    = { min_x, min_y, max_x, max_y };

        // 机型标识 + 打印板模型名（来自该机型的 BBL 预设 bed_model 字段，如 "bbl-3dp-H2D.stl"）。
        // 渲染侧据此选对应的开源板模型；缺字段时为空串，渲染侧退回默认板。
        // 逐跳自证：把「vendor 是否挂上 / 厂商模型表条数 / 命中的模型 id / bed_model」一并带出，
        // 便于日志端核对「哪一跳丢了值」，绝不拿兜底板掩盖。
        std::string printer_model;
        if (const ConfigOptionString* pm = cfg.option<ConfigOptionString>("printer_model"))
            printer_model = pm->value;
        out["printerModel"] = printer_model;

        const bool vendor_ok = (printer.vendor != nullptr);
        out["bedVendorId"]    = vendor_ok ? printer.vendor->id : std::string();
        out["bedModelsCount"] = vendor_ok ? static_cast<int>(printer.vendor->models.size()) : -1;
        std::string bed_model_name, bed_model_id, bed_model_src = "none";
        if (const VendorProfile::PrinterModel* pmv = PresetUtils::system_printer_model(printer)) {
            bed_model_name = pmv->bed_model;
            bed_model_id   = pmv->id;
            bed_model_src  = "preset.vendor";
        } else if (!printer_model.empty()) {
            // preset.vendor 直接为空时（预设本体没挂厂商）再沿父预设链找一次厂商定义 —— 这是内核
            // 专门提供的正规 API（见 PresetWithVendorProfile 注释），不是自造兜底；两跳都用 printer_model 精确匹配。
            const PresetWithVendorProfile pv = g_preset_bundle->printers.get_preset_with_vendor_profile(printer);
            if (pv.vendor != nullptr) {
                for (const VendorProfile::PrinterModel& pm : pv.vendor->models) {
                    if (pm.id == printer_model) {
                        bed_model_name = pm.bed_model;
                        bed_model_id   = pm.id;
                        bed_model_src  = "parentVendor";
                        out["bedVendorId"]    = pv.vendor->id;
                        out["bedModelsCount"] = static_cast<int>(pv.vendor->models.size());
                        break;
                    }
                }
            }
        }
        out["bedModel"]    = bed_model_name;
        out["bedModelId"]  = bed_model_id;
        out["bedModelSrc"] = bed_model_src;

        // 多挤出机机型的「每个喷嘴可达打印区」（extruder_printable_area，官方预设真值）。
        // 单喷嘴机型该键为空 → 渲染侧据此判定「无双喷嘴专属区」，不显示任何专属带。
        nlohmann::json ext_areas = nlohmann::json::array();
        if (const ConfigOptionPointsGroups* ea = cfg.option<ConfigOptionPointsGroups>("extruder_printable_area")) {
            for (const std::vector<Vec2d>& poly : ea->values) {
                nlohmann::json pj = nlohmann::json::array();
                for (const Vec2d& p : poly)
                    pj.push_back({ p.x(), p.y() });
                ext_areas.push_back(pj);
            }
        }
        out["extruderAreas"]     = ext_areas;
        out["extruderAreaCount"] = static_cast<int>(ext_areas.size());

        nlohmann::json ext_heights = nlohmann::json::array();
        // extruder_printable_height 在 PrintConfig 里注册为 coFloats（非 nullable），这里必须用对应类型取，
        // 否则 dynamic_cast 落空 → 永远取不到值。
        if (const ConfigOptionFloats* eh = cfg.option<ConfigOptionFloats>("extruder_printable_height")) {
            for (float v : eh->values)
                ext_heights.push_back(v);
        }
        out["extruderHeights"] = ext_heights;
        return out.dump();
    } catch (const std::exception& e) {
        out["message"] = std::string("读取打印板失败: ") + e.what();
        return out.dump();
    }
}

std::string slicer_presets_for_printer(const std::string& printer_preset_name)
{
    nlohmann::json out;
    out["ok"] = false;

    std::lock_guard<std::mutex> lock(g_preset_mutex);
    if (!g_preset_bundle) {
        out["message"] = "预设未初始化";
        return out.dump();
    }

    try {
        // 目标打印机：按名字在内核 printers 集合里查对应的 Preset，再把它交给内核的
        // is_compatible_with_printer 判断 —— compatible_printers 精确机型名 / inherits /
        // compatible_printers_condition 全由内核处理，这里不拼任何名字后缀。
        // real=true 取的是预设本体而非"编辑副本"，保证 compatible_printers 等元数据不被用户改动污染。
        const Preset* printer = nullptr;
        if (!printer_preset_name.empty())
            printer = g_preset_bundle->printers.find_preset(
                printer_preset_name, /*first_visible_if_not_found=*/false, /*real=*/true);
        if (printer == nullptr) {
            if (printer_preset_name.empty())
                printer = &g_preset_bundle->printers.get_selected_preset();
            else {
                // 绝不静默退回"当前选中机型"：那会把另一台机器的兼容列表冒充成本次查询结果，
                // 正是"换了机型下拉却不换"的隐患来源。如实报错，让上层用内核回读的名字重试。
                out["message"] = std::string("打印机预设 \"") + printer_preset_name + "\" 不存在";
                return out.dump();
            }
        }

        const PresetWithVendorProfile active_printer =
            g_preset_bundle->printers.get_preset_with_vendor_profile(*printer);

        out["ok"]        = true;
        out["printer"]   = printer->name;
        out["processes"] = compatible_preset_names(g_preset_bundle->prints,    active_printer);
        out["filaments"] = compatible_preset_names(g_preset_bundle->filaments, active_printer);
        out["notes"]     = "compatible_printers 精确机型名匹配 / compatible_printers_condition "
                           "由内核 is_compatible_with_printer 判断";
        return out.dump();
    } catch (const std::exception& e) {
        out["message"] = std::string("兼容预设查询失败: ") + e.what();
        return out.dump();
    }
}

// 把一份 DynamicPrintConfig 扁平化成「动态表单可直接吃的」JSON：
//   * 数值/布尔按真实类型；**枚举一律给 enum_values 下标**（不是底层枚举值 getInt()）——
//     表单 options / apply_params / slicer_enum_values 三者都以下标为准，必须从源头同源。
//     转换走唯一权威映射 enum_value_to_index()（BedType 这类 getInt()≠下标的枚举靠它纠偏）
//   * 向量型选项给第一档（表单只有一个标量控件；写回时 apply_params 会跳过向量项）
// 抽成公共函数是为了让「当前预设快照」(slicer_config_snapshot) 与「3MF 内嵌工程配置」
// (slicer_import_3mf) 用同一套口径 —— 两边键值语义必须一致，否则导入写回会错位。
nlohmann::json config_flat_json(const DynamicPrintConfig& cfg)
{
    nlohmann::json out = nlohmann::json::object();
    for (const std::string& key : cfg.keys()) {
        const ConfigOption* opt = cfg.option(key);
        if (opt == nullptr)
            continue;
        if (opt->is_vector()) {
            const std::string text = opt->serialize();
            const std::string first = text.substr(0, text.find(','));
            if (first.empty())
                continue;
            char* end = nullptr;
            const double v = std::strtod(first.c_str(), &end);
            if (end != nullptr && *end == '\0')
                out[key] = v;
            continue;
        }
        switch (opt->type()) {
            case coFloat: case coPercent: case coFloatOrPercent:
                out[key] = opt->getFloat(); break;
            case coInt:
                out[key] = opt->getInt(); break;
            case coEnum:
                out[key] = enum_value_to_index(key, *opt); break;
            case coBool:
                out[key] = opt->getBool(); break;
            case coString:
                out[key] = opt->serialize(); break;
            default:
                break;
        }
    }
    return out;
}

std::string slicer_config_snapshot()
{
    std::lock_guard<std::mutex> lock(g_preset_mutex);
    return config_flat_json(current_full_config()).dump();
}

// 向量型选项 → JSON 数组（按 serialize() 的 "," 逐段还原）：
//   全部段都能解析成数字 → 数字数组；否则 → 字符串数组（如 filament_colour / nozzle_temperature_range）。
nlohmann::json opt_vector_json(const ConfigOption& opt)
{
    const std::string text = opt.serialize();
    std::vector<std::string> parts;
    std::string cur;
    for (char c : text) {
        if (c == ',') { parts.push_back(cur); cur.clear(); }
        else         { cur.push_back(c); }
    }
    parts.push_back(cur);

    nlohmann::json arr = nlohmann::json::array();
    bool all_num = true;
    std::vector<double> nums;
    nums.reserve(parts.size());
    for (const std::string& s : parts) {
        if (s.empty()) { all_num = false; break; }
        char* end = nullptr;
        const double v = std::strtod(s.c_str(), &end);
        if (end == nullptr || *end != '\0') { all_num = false; break; }
        nums.push_back(v);
    }
    if (all_num)
        for (double v : nums) arr.push_back(v);
    else
        for (const std::string& s : parts) arr.push_back(s);
    return arr;
}

// 「耗材编辑」读取口：当前**被编辑的耗材预设**的全部键值，向量型按数组原样返回。
//
// 为什么不复用 slicer_config_snapshot：那个走 config_flat_json，刻意把向量型压成第一档
// （见其实现注释），而耗材的板温 / 喷嘴温度 / 风扇 / 回抽等关键项恰恰都是向量型（按耗材分档）——
// 编辑器必须拿到整条数组才能如实显示、并按数组回写。
//
// 写入侧不单独开接口：编辑器把改动并进 params_json，由 apply_params 的
// 「数组 → 整段写入」分支落到 config（与动态表单同一条通道）。
std::string slicer_filament_snapshot()
{
    std::lock_guard<std::mutex> lock(g_preset_mutex);
    nlohmann::json out = nlohmann::json::object();
    if (!g_preset_bundle) {
        out["ok"]      = false;
        out["message"] = "预设未初始化";
        return out.dump();
    }
    const Preset& fp = g_preset_bundle->filaments.get_edited_preset();
    const DynamicPrintConfig& cfg = fp.config;

    nlohmann::json values = nlohmann::json::object();
    for (const std::string& key : cfg.keys()) {
        const ConfigOption* opt = cfg.option(key);
        if (opt == nullptr)
            continue;
        if (opt->is_vector()) {
            values[key] = opt_vector_json(*opt);
            continue;
        }
        switch (opt->type()) {
            case coFloat: case coPercent: case coFloatOrPercent:
                values[key] = opt->getFloat(); break;
            case coInt:
                values[key] = opt->getInt(); break;
            case coEnum:
                values[key] = enum_value_to_index(key, *opt); break;
            case coBool:
                values[key] = opt->getBool(); break;
            case coString:
                values[key] = opt->serialize(); break;
            default:
                break;
        }
    }
    out["ok"]      = true;
    out["name"]    = fp.name;
    out["printer"] = g_preset_bundle->printers.get_edited_preset().name;
    out["values"]  = values;
    return out.dump();
}

std::string slicer_enum_values()
{
    nlohmann::json out = nlohmann::json::object();

    // 直接来自 PrintConfigDef：这是内核解析枚举名字用的权威表，
    // 与 apply_params() 里"下标 -> 名字"用的是同一份，保证表单下标不会错位。
    for (const auto& kv : print_config_def.options) {
        const ConfigOptionDef& od = kv.second;
        if (od.type == coEnum && !od.enum_values.empty())
            out[kv.first] = od.enum_values;
    }
    return out.dump();
}

std::string slicer_config_defs()
{
    nlohmann::json out = nlohmann::json::object();
    const int vec_bit = static_cast<int>(coVectorType);

    for (const auto& kv : print_config_def.options) {
        const ConfigOptionDef& od = kv.second;
        const int raw  = static_cast<int>(od.type);
        const int base = raw & ~vec_bit;   // 剥掉 coVectorType 位，只留标量基类型

        nlohmann::json d;
        d["type"]     = base;
        d["vector"]   = (raw & vec_bit) != 0;
        d["label"]    = od.label;
        d["tooltip"]  = od.tooltip;
        d["unit"]     = od.sidetext;
        d["category"] = od.category;
        d["mode"]     = static_cast<int>(od.mode);
        d["readonly"] = od.readonly;
        // min/max 只在**显式声明过**时才输出：内核缺省是 ±DBL_MAX，输出它等于没有范围，
        // 反而会让界面以为「范围就是这么大」。缺省即「未声明范围」，由界面按 0/0 处理（不夹取）。
        if (od.min > ConfigOptionDef::min_default)
            d["min"] = od.min;
        if (od.max < ConfigOptionDef::max_default)
            d["max"] = od.max;
        if (!od.enum_values.empty())
            d["enum_values"] = od.enum_values;
        if (!od.enum_labels.empty())
            d["enum_labels"] = od.enum_labels;
        out[kv.first] = std::move(d);
    }
    return out.dump();
}

std::string slicer_version()
{
    return std::string(SLIC3R_VERSION);
}

// =============================================================================
//  切片失败的现场诊断
//
//  切片跑在设备上，没有调试器；内核抛出来的话（比如 GCode.cpp 的
//  "No object can be printed. Maybe too small"）只说结论不说原因。这里把
//  模型 / 配置 / 打印对象三方面的关键状态抓下来，写到 <output>.debug.json，
//  同时把一段紧凑摘要拼进 message，只看 toast 也能判断个大概。
// =============================================================================

namespace {

const char* pvs_name(ModelInstanceEPrintVolumeState s)
{
    switch (s) {
    case ModelInstancePVS_Inside:         return "inside";
    case ModelInstancePVS_Limited:        return "limited";
    case ModelInstancePVS_Partly_Outside: return "partly-outside";
    case ModelInstancePVS_Fully_Outside:  return "fully-outside";
    default:                              return "unknown";
    }
}

template<typename V>
nlohmann::json to_json3(const V& v) { return nlohmann::json::array({ v.x(), v.y(), v.z() }); }

// ConfigOption::serialize() 对向量可能非常长（全量预设里 filament_type 有 200+ 项），截断
std::string brief(const ConfigOption* o, size_t max_len = 400)
{
    if (o == nullptr)
        return "<missing>";
    std::string s = o->serialize();
    if (s.size() > max_len)
        s = s.substr(0, max_len) + "...";
    return s;
}

// 规模闸门阈值。依据：
//   * 面数：常规单个模型（含高精度 STL）实测多在 300 万面以内，36 盘满铺的多盘工程也多在
//     一两百万面。切片峰值内存随面数近似线性：TriangleMesh 本体约 30B/面（顶点+索引+法线），
//     层片/ExPolygon/GCode 中间量再放大 3~5 倍，800 万面已是移动端单进程可用的内存预算
//     （1GB 量级）的上沿，再高就只是在赌 native malloc 不失败（失败即 SIGSEGV/SIGABRT，
//     进不了 catch）。
//   * 对象数：500 远超常见"盘数 × 每盘零件数"的规模，只用来拦脚本生成的病态 3MF。
constexpr size_t k_max_facets  = 8000000;
constexpr size_t k_max_objects = 500;

nlohmann::json dump_model(const Model& model)
{
    nlohmann::json objs = nlohmann::json::array();
    for (const ModelObject* mo : model.objects) {
        if (mo == nullptr) {
            objs.push_back(nullptr);
            continue;
        }
        nlohmann::json o;
        o["name"]      = mo->name;
        o["printable"] = mo->printable;
        o["volumes"]   = mo->volumes.size();
        o["instances"] = mo->instances.size();

        nlohmann::json vols = nlohmann::json::array();
        size_t facets = 0;
        for (const ModelVolume* mv : mo->volumes) {
            if (mv == nullptr) {
                vols.push_back(nullptr);
                continue;
            }
            facets += mv->mesh().facets_count();
            const BoundingBoxf3 vb = mv->mesh().bounding_box();
            vols.push_back({
                { "name",       mv->name },
                { "modelPart",  mv->is_model_part() },
                { "extruderId", mv->extruder_id() },
                { "facets",     mv->mesh().facets_count() },
                { "bboxMin",    to_json3(vb.min) },
                { "bboxMax",    to_json3(vb.max) },
            });
        }
        o["volumeDetails"] = vols;

        nlohmann::json insts = nlohmann::json::array();
        size_t printable_inst = 0;
        for (const ModelInstance* mi : mo->instances) {
            if (mi == nullptr) {
                insts.push_back(nullptr);
                continue;
            }
            if (mi->is_printable())
                ++printable_inst;
            insts.push_back({
                { "printable", mi->printable },
                { "pvs",       pvs_name(mi->print_volume_state) },
                { "offset",    to_json3(mi->get_offset()) },
            });
        }
        o["facets"]             = facets;
        o["printableInstances"] = printable_inst;
        o["instanceDetails"]    = insts;

        const BoundingBoxf3 bb = mo->raw_mesh_bounding_box();
        o["bboxMin"]  = to_json3(bb.min);
        o["bboxMax"]  = to_json3(bb.max);
        o["sizeMm"]   = to_json3(bb.size());
        o["heightMm"] = bb.max.z() - bb.min.z();
        objs.push_back(std::move(o));
    }

    nlohmann::json j;
    j["objectCount"]    = model.objects.size();
    j["currPlateIndex"] = model.curr_plate_index;
    j["objects"]        = objs;
    return j;
}

nlohmann::json dump_config(const DynamicPrintConfig& cfg)
{
    // 与切片成败最相关的项：层高/打印顺序/热床与可打印高度/多材料映射/预设身份。
    // 后半段（flush_into_* / 各 filament 槽位 / 预设 id）专门用来定位
    // "每个实体都被判成可改写 → 一个挤出机都收不到" 那条路径：
    // is_overriddable() 只要 object.config().flush_into_objects 为真就对所有实体返回 true。
    const char* keys[] = {
        "layer_height", "initial_layer_print_height", "first_layer_height",
        "printable_height", "extruder_printable_height", "print_sequence",
        "enable_support", "support_type", "support_filament", "support_interface_filament",
        "brim_type", "spiral_mode", "wall_loops",
        "sparse_infill_density", "curr_bed_type", "printer_technology",
        "enable_prime_tower", "wipe_tower_type", "filament_shrink",
        "nozzle_diameter", "filament_diameter", "filament_map", "filament_map_mode",
        "filament_volume_map", "filament_nozzle_map", "printable_area",
        "bed_shape", "extruder_printable_area", "extruder",
        "filament_type", "printer_model", "printer_settings_id",
        "print_settings_id", "filament_settings_id", "filament_is_mixed",
        // ---- 定位 "挤出机收不到" 用的 ----
        "flush_into_objects", "flush_into_infill", "flush_into_support",
        "filament_soluble", "filament_is_support",
        "wall_filament", "sparse_infill_filament", "solid_infill_filament",
        "enable_wrapping_detection", "raft_layers", "first_layer_print_sequence"
    };
    nlohmann::json j;
    for (const char* k : keys)
        j[k] = brief(cfg.option(k));
    return j;
}

nlohmann::json dump_print(const Print& print)
{
    nlohmann::json objs = nlohmann::json::array();
    size_t n_layers = 0;
    for (const PrintObject* po : print.objects()) {
        if (po == nullptr) {
            objs.push_back(nullptr);
            continue;
        }
        const size_t layers = po->layer_count();
        n_layers += layers;
        objs.push_back({
            { "layers",        layers },
            { "supportLayers", po->support_layer_count() },
            { "heightMm",      unscale<double>(po->height()) },
        });
    }

    nlohmann::json j;
    j["printObjects"]          = print.objects().size();
    j["totalLayers"]           = n_layers;
    j["detail"]                = objs;
    j["sequential"]            = print.is_sequential_print();
    j["hasWipeTower"]          = print.has_wipe_tower();
    j["objectExtruders"]       = print.object_extruders();
    j["printExtruders"]        = print.extruders();
    j["toolOrderingExtruders"] = print.tool_ordering().all_extruders();
    const PrintStatistics& st = print.print_statistics();
    j["filamentMm"] = st.total_used_filament;
    j["weightG"]    = st.total_weight;
    return j;
}

std::string compact_hint(const nlohmann::json& dm, const nlohmann::json& dc, const nlohmann::json& dp)
{
    auto str_of = [](const nlohmann::json& j, const char* k) -> std::string {
        auto it = j.find(k);
        if (it == j.end() || !it->is_string())
            return "?";
        return it->get<std::string>();
    };
    auto count_of = [](const nlohmann::json& j, const char* k) -> std::string {
        auto it = j.find(k);
        if (it == j.end() || !it->is_array())
            return "?";
        return std::to_string(it->size());
    };

    // 模型总三角面数 + 首个对象尺寸是最省事的分诊依据：
    //   面数=0 → 内核根本没读进网格（加载器问题），跟切片参数无关；
    //   面数正常但总层数=0 → 是配置/摆放把切片打死了。
    size_t facets = 0;
    std::string first_size = "?";
    auto objs = dm.find("objects");
    if (objs != dm.end() && objs->is_array()) {
        for (const auto& o : *objs) {
            if (!o.is_object())
                continue;
            auto f = o.find("facets");
            if (f != o.end() && f->is_number())
                facets += f->get<size_t>();
        }
        if (!objs->empty() && objs->front().is_object()) {
            auto s = objs->front().find("sizeMm");
            if (s != objs->front().end() && s->is_array() && s->size() == 3) {
                char buf[64];
                std::snprintf(buf, sizeof(buf), "%.1fx%.1fx%.1f",
                              (*s)[0].get<double>(), (*s)[1].get<double>(), (*s)[2].get<double>());
                first_size = std::string(buf);
            }
        }
    }

    return "[模型面数=" + std::to_string(facets)
         + " 尺寸=" + first_size + "mm"
         + " 模型对象=" + std::to_string(dm.value("objectCount", (size_t)0))
         + " 打印对象=" + std::to_string(dp.value("printObjects", (size_t)0))
         + " 总层数=" + std::to_string(dp.value("totalLayers", (size_t)0))
         + " 对象挤出机=" + count_of(dp, "objectExtruders")
         + " 工具序挤出机=" + count_of(dp, "toolOrderingExtruders")
         + " 塔=" + (dp.value("hasWipeTower", false) ? std::string("有") : std::string("无"))
         + " 层高=" + str_of(dc, "layer_height")
         + " 可打印高度=" + str_of(dc, "printable_height")
         + " 热床=" + str_of(dc, "printable_area")
         + "]";
}

// 用 POSIX I/O 而不是 std::ofstream：C++ 文件流在这套静态库 + OHOS 组合里没能落盘
// （诊断文件一直不出现），fopen 走的是同一套 syscall，libslic3r 导出 gcode 也这么写。
bool write_debug_file(const std::string& path, const nlohmann::json& j)
{
    const std::string text = j.dump(2);
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (fp == nullptr)
        return false;
    const size_t written = std::fwrite(text.data(), 1, text.size(), fp);
    std::fclose(fp);
    return written == text.size();
}

// 切片失败时的统一结果组装：把「内核原始错误文本 what_text」放在最前面（toast 由系统按尾部截断，
// 关键原因必须在开头），后面接现场诊断摘要；同时把原始文本与诊断写进 <output>.debug.json。
// what_text 由调用方按异常类型取实（SlicingErrors 取各条 message，而不是它泛型的 "Errors"）。
std::string slice_failure_json(const std::string& input_path, const std::string& output_path,
                               const Model& model, const DynamicPrintConfig& config, const Print& print,
                               const std::string& what_text)
{
    nlohmann::json out;
    out["ok"]     = false;
    out["status"] = "error";
    std::string hint;
    try {
        const nlohmann::json dm = dump_model(model);
        const nlohmann::json dc = dump_config(config);
        const nlohmann::json dp = dump_print(print);
        hint = compact_hint(dm, dc, dp);

        nlohmann::json dbg;
        dbg["error"]  = what_text;
        dbg["hint"]   = hint;
        dbg["input"]  = input_path;
        dbg["model"]  = dm;
        dbg["config"] = dc;
        dbg["print"]  = dp;
        const std::string debug_path = output_path + ".debug.json";
        if (write_debug_file(debug_path, dbg))
            out["debug"] = debug_path;
        else
            hint += " [debug文件写入失败]";
    } catch (const std::exception& de) {
        hint = std::string("[诊断失败: ") + de.what() + "]";
    } catch (...) {
        hint = "[诊断失败: 未知]";
    }
    out["message"] = hint + " 切片异常: " + what_text;
    return out.dump();
}

// 硬崩（SIGSEGV / SIGABRT）不会被 catch 捕获，faultlog 也未必拿得到。所以每进入一个
// 阶段就往 <output>.stage 追加一行，形如 "5-process t=18342ms rss=412.7MB"。
// 追加（而不是覆盖）的原因：一次 run 的完整轨迹都留在文件里，不仅能看到"最后进入哪一步"，
// 还能看出每一步花了多久、内存涨了多少 —— 定位 OOM 尤其靠后者。
// 当前这次 run 的输出路径放在全局里，好让内核内部（GCode 导出流程）也能打点。
std::string g_stage_output_path;

// 当前进程 RSS（KB）。读 /proc/self/statm：格式 "size resident shared text lib data dt"，
// 第 2 个字段是 resident pages，乘页大小即 RSS。
// 沙箱下取不到就返回 0，调用方退化成只写阶段名 + 计数。
long current_rss_kb()
{
    FILE* fp = std::fopen("/proc/self/statm", "rb");
    if (fp == nullptr)
        return 0;
    long total_pages = 0;
    long resident_pages = 0;
    const int n = std::fscanf(fp, "%ld %ld", &total_pages, &resident_pages);
    std::fclose(fp);
    if (n < 2 || resident_pages <= 0)
        return 0;
    const long page_kb = static_cast<long>(::sysconf(_SC_PAGESIZE)) / 1024;
    return resident_pages * (page_kb > 0 ? page_kb : 4);
}

void set_stage(const char* stage)
{
    if (g_stage_output_path.empty())
        return;
    // "ab" 追加写：每次调用追加一行，覆盖写会把上一阶段的证据抹掉
    FILE* fp = std::fopen((g_stage_output_path + ".stage").c_str(), "ab");
    if (fp == nullptr)
        return;
    // steady_clock 单调，只用于步与步之间的相对耗时，不受系统时间调整影响
    const double ms = std::chrono::duration<double, std::milli>(
                          std::chrono::steady_clock::now().time_since_epoch()).count();
    const long rss_kb = current_rss_kb();
    if (rss_kb > 0)
        std::fprintf(fp, "%s t=%.0fms rss=%.1fMB\n", stage, ms, static_cast<double>(rss_kb) / 1024.0);
    else
        std::fprintf(fp, "%s t=%.0fms rss=?\n", stage, ms);
    // fflush 只把 libc 缓冲推进内核；再 fsync 才真正落到存储。
    // 少任何一步，硬崩时这一行都会跟着丢 —— 这正是之前"看不到 .stage 文件"的原因之一。
    std::fflush(fp);
    const int fd = ::fileno(fp);
    if (fd >= 0)
        ::fsync(fd);
    std::fclose(fp);
}

} // namespace

// 给内核内部（GCode.cpp 的导出流程）用的阶段钩子：纯诊断，不改变任何行为。
void set_slice_stage(const char* stage)
{
    set_stage(stage);
}

// 「多色分 part 的首层豁免」的生存期守卫。
// 必须覆盖 process() **和** export_gcode()：GCode::collect_layers_to_print 里那条
// 「第 0 层无挤出 → 浮空件」的检查是在**导出阶段**（GCode::do_export → gcode()）才跑的，
// 只在 process() 前后置位等于没生效 —— 真机日志里就是「开始导出 G-code」之后才抛错。
// 用 RAII 保证异常路径（SlicingErrors / 其它异常）也能复位，不会污染下一次切片。
namespace {
struct EmptyInitialLayerGuard {
    explicit EmptyInitialLayerGuard(bool on) { set_allow_empty_initial_layer(on); }
    ~EmptyInitialLayerGuard() { set_allow_empty_initial_layer(false); }
};
} // namespace

// =============================================================================
//  切片前的网格焊接（面汤 → 共享顶点的索引网格）
//
//  现场：把工程导出成 3MF 再拿它切片，结果只剩零星碎片 / 首层为空 / 擦料塔只有几层。
//  根因：3MF 里每个三角形各带 3 个独立顶点（实测 8636 面 → 25908 顶点，每条边都是边界边），
//  而内核的 3MF 加载器**不做顶点焊接**（只有 STL 路径会 weld）。分层时轮廓靠顶点/边邻接
//  串成闭环，面汤串不起来 → 每块三角面各自成一个小岛，挤出路径退化成几十条 0.2mm 短线。
//
//  为什么不能只在导出侧修：用户从外部拿到的 3MF 本身就可能是面汤（BambuStudio 的工程导出
//  就是这种形态），所以统一在**切片入口**按坐标焊接一次，与 STL 导入同一口径。
//  只在真正发生合并时才打 stage 证据，正常索引网格零成本（一次遍历 + 哈希）。
// =============================================================================
static size_t weld_model_meshes(Model& model)
{
    size_t welded_volumes = 0;
    size_t saved_vertices = 0;
    for (ModelObject* obj : model.objects) {
        if (obj == nullptr)
            continue;
        for (ModelVolume* vol : obj->volumes) {
            if (vol == nullptr)
                continue;
            // ModelVolume 只暴露 const mesh()；这里改的是本次切片私有的 Model 副本，
            // 与 Model.cpp 里 translate/scale 的 const_cast 是同一用法。
            TriangleMesh& mesh = const_cast<TriangleMesh&>(vol->mesh());
            if (mesh.its.indices.empty())
                continue;
            const size_t before = mesh.its.vertices.size();
            its_merge_vertices(mesh.its, true);
            its_compactify_vertices(mesh.its, true);
            if (mesh.its.vertices.size() < before) {
                welded_volumes++;
                saved_vertices += before - mesh.its.vertices.size();
            }
        }
    }
    if (welded_volumes > 0) {
        char buf[128];
        std::snprintf(buf, sizeof(buf), "1a-weld vols=%d verts_saved=%d",
                      static_cast<int>(welded_volumes), static_cast<int>(saved_vertices));
        set_stage(buf);
    }
    return welded_volumes;
}

// =============================================================================
//  把「同一组合件的多个对象」合并回一个多 part 对象
//
//  背景：我们的显示模型是「对象 = 一个耗材/显示色」，导入多色工程时会把同一件的不同 part
//  拆成多个对象（见 slicer_import_3mf 的分组注释）。但内核是**按对象**独立分层的：
//  两个对象的分层结果不会互相裁剪（clip_multipart_objects 只作用于同一对象内的 part），
//  于是白底与红 logo 在重叠区域各打一遍 —— 预览/打印上就是「红白交错」。
//  合并回一个多 volume 对象后，内核按 part 顺序裁剪重叠（后面的 part 覆盖前面的），
//  与 Bambu Studio 一致：先打白底，红 logo 只占自己的区域。
//
//  group_of_object：与 model.objects 同序的分组号（>=0 同号 = 同一组合件；-1 = 不合并）。
//  网格：每个 part 的「体积矩阵 + 实例矩阵」全部烘进顶点（世界坐标），合并对象只留恒等实例。
//  注意 part 顺序必须保持输入顺序 —— 内核的裁剪规则是「后面的 part 覆盖前面的」。
// =============================================================================
static size_t merge_assembly_objects(Model& model, const std::vector<int>& group_of_object)
{
    char buf[160];
    if (group_of_object.empty()) {
        set_stage("1b-assembly skip req=0");
        return 0;
    }
    if (group_of_object.size() != model.objects.size()) {
        std::snprintf(buf, sizeof(buf), "1b-assembly skip req=%d objects=%d",
                      static_cast<int>(group_of_object.size()),
                      static_cast<int>(model.objects.size()));
        set_stage(buf);
        return 0;
    }

    std::map<int, std::vector<ModelObject*>> groups;
    for (size_t i = 0; i < model.objects.size(); ++i) {
        if (group_of_object[i] >= 0 && model.objects[i] != nullptr)
            groups[group_of_object[i]].push_back(model.objects[i]);
    }

    size_t merged_groups = 0;
    std::vector<ModelObject*> to_delete;
    for (auto& kv : groups) {
        if (kv.second.size() < 2)
            continue;
        ModelObject* base = kv.second.front();
        if (base->instances.empty())
            base->add_instance();
        const Transform3d base_inst = base->instances.front()->get_matrix();
        const Transform3d base_inv  = base_inst.inverse();
        // 去掉导入时加的「 · 耗材N」后缀，恢复组合件原名
        {
            const size_t sep = base->name.rfind(" · 耗材");
            if (sep != std::string::npos)
                base->name = base->name.substr(0, sep);
        }

        for (size_t k = 1; k < kv.second.size(); ++k) {
            ModelObject* src = kv.second[k];
            if (src->instances.empty())
                src->add_instance();
            const Transform3d src_inst = src->instances.front()->get_matrix();
            // 其他 part 相对 base 实例的变换（base 的实例保持不动，体积仍在对象本地坐标系）
            const Transform3d rel = base_inv * src_inst;
            for (ModelVolume* mv : src->volumes) {
                if (mv == nullptr || !mv->is_model_part())
                    continue;
                TriangleMesh vm(mv->mesh());
                vm.transform(mv->get_matrix());
                vm.transform(rel);
                // modify_to_center_geometry = false：坐标已按 base 口径摆好，不能再被重新居中
                ModelVolume* nv = base->add_volume(std::move(vm), ModelVolumeType::MODEL_PART, false);
                if (nv == nullptr)
                    continue;
                if (const ConfigOptionInt* e =
                        dynamic_cast<const ConfigOptionInt*>(mv->config.option("extruder")))
                    nv->config.set_key_value("extruder", new ConfigOptionInt(e->getInt()));
            }
            to_delete.push_back(src);
        }
        base->invalidate_bounding_box();
        merged_groups++;
    }

    // 删旧对象放在最后：分组里存的是指针，边删边处理会让后面的分组拿到失效对象
    for (ModelObject* o : to_delete)
        model.delete_object(o);

    if (merged_groups > 0) {
        std::snprintf(buf, sizeof(buf), "1b-assembly merged=%d objects_left=%d",
                      static_cast<int>(merged_groups), static_cast<int>(model.objects.size()));
        set_stage(buf);
    } else {
        std::snprintf(buf, sizeof(buf), "1b-assembly none req=%d objects=%d",
                      static_cast<int>(group_of_object.size()),
                      static_cast<int>(model.objects.size()));
        set_stage(buf);
    }
    return merged_groups;
}

std::string slicer_slice_with_progress(const std::string& input_path,
                                       const std::string& params_json,
                                       const std::string& output_path,
                                       const SliceProgressFn& progress)
{
    nlohmann::json out;
    out["ok"]     = false;
    out["status"] = "error";

    if (input_path.empty()) {
        out["message"] = "未指定输入模型";
        return out.dump();
    }
    if (output_path.empty()) {
        out["message"] = "未指定输出路径";
        return out.dump();
    }

    const auto t_begin = std::chrono::steady_clock::now();

    // ---- 进度上报 -------------------------------------------------------------
    // 只在切片 worker 线程上被调用；progress 为空时所有 emit 都是 no-op（退化成原来的静默切片）。
    // 限流：普通进度最快 40ms 一条（与网格载入同口径），关键项（阶段切换 / 100%）立即发。
    // 这保证「日志流」不会被按层的高频回调淹没，同时阶段边界一定落在日志里。
    //
    // 注意并发：内核的 process() 走 tbb 并行管线，set_status 可能从多个工作线程并发触发，
    // 所以两处节流状态（限流闸 / 让出闸）各用一把小锁保护，避免数据竞争（UB）。
    // progress 本身（→ napi_threadsafe_function）是线程安全的，无需额外加锁。
    std::mutex emit_mutex;
    std::mutex yield_mutex;
    auto emit_last = std::chrono::steady_clock::now();
    int  emit_last_stage = -2;
    auto emit = [&](int stage, int pct, const std::string& msg) {
        if (!progress) { return; }
        if (pct < 0) { pct = 0; } else if (pct > 100) { pct = 100; }
        {
            std::lock_guard<std::mutex> lk(emit_mutex);
            const bool key = (stage != emit_last_stage) || pct >= 100;
            const auto now = std::chrono::steady_clock::now();
            if (!key && (now - emit_last) < std::chrono::milliseconds(40)) { return; }
            emit_last = now;
            emit_last_stage = stage;
        }
        progress(stage, pct, msg);
    };
    // 让出 CPU 的节流闸：与 bambu_mesh 的 CpuYielder 同一套（约 20ms 一次）。
    // 导出 G-code 的按层回调可能上千次，长时间占满一个核会把 UI 线程饿住。
    auto yield_last = std::chrono::steady_clock::now();
    auto yield_gate = [&]() {
        std::lock_guard<std::mutex> lk(yield_mutex);
        const auto now = std::chrono::steady_clock::now();
        if (now - yield_last >= std::chrono::milliseconds(20)) {
            yield_last = now;
            std::this_thread::yield();
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    };

    // 现场诊断：状态提到 try 外，异常时 catch 里才拿得到。
    Model             model;
    DynamicPrintConfig config;
    Print             print;

    // 阶段 3/4 共用内核状态回调：in_export 区分「process 子步骤」与「export 按层」；
    // total_layers 是 process 之后拿到的真实层数，作为「第 N / M 层」的 M。
    bool   in_export    = false;
    size_t total_layers = 0;

    // 阶段标记从进入函数的第一刻就落地（这一段只有赋值，不会抛）。有了它才能区分
    // "回调根本没进切片" 与 "进了切片但停在第 0 步"：之前"找不到 .stage"就是因为
    // 最早的进度点要等进了 try、准备完参数才写，硬崩在前面的情况完全没有痕迹。
    g_stage_output_path = output_path;
    set_stage("0-enter");

    // 「对象颜色 → 耗材槽位」请求（无请求时 present=false，全程退化成原来的单耗材切片）。
    // 注意：展开动作必须在 load_model_file 之后做 —— 加载器会把 3MF 内嵌的 project_settings.config
    // 叠加到 config 上（可能把耗材向量压回 1 档），所以只在 apply_params 之后再统一展开成 N 档。
    const FilamentReq fil_req = parse_filament_request(params_json);

    try {
        // 配置基线：优先用官方预设（PresetBundle 合成结果），预设未初始化时退到内核默认值。
        // 3MF 内嵌的工程配置会覆盖它，UI 参数最后叠加。
        {
            std::lock_guard<std::mutex> lock(g_preset_mutex);
            config = current_full_config();
        }

        // 临时目录必须在任何模型加载之前指好：3MF/STEP 加载器都要用它（详见 ensure_temporary_dir）。
        // 放在这里（配置基线之后、load_model_file 之前）就是为了覆盖后面所有格式的加载路径。
        std::string err;
        if (!ensure_temporary_dir(output_path, err)) {
            out["message"] = err;
            return out.dump();
        }

        // ---- 阶段 0：装载模型（内核无细粒度钩子 -> 只报进入/完成，带真实规模）----
        emit(0, 3, "开始装载模型");
        set_stage("1-load");
        if (!load_model_file(input_path, model, config, err)) {
            out["message"] = err;
            return out.dump();
        }
        if (model.objects.empty()) {
            out["message"] = "模型里没有可切片对象";
            return out.dump();
        }

        // 3MF 面汤会让分层退化成「每块三角面各自成岛」：切片前按坐标焊接一次。
        weld_model_meshes(model);
        // 同一组合件的多个 part（我们的显示模型里是多个对象）合并回一个对象：
        // 内核只对「同一对象内的 part」裁剪重叠，不合并会让两种料在同一区域各打一遍（红白交错）。
        merge_assembly_objects(model, fil_req.assembly);

        // 规模闸门：native OOM 是 SIGSEGV/SIGABRT，进不了下面的 catch，所以必须在
        // print.apply()（以及之后的层片化）之前先按规模拦一刀，宁可给一句可读错误。
        // 复用 dump_model()：它已经把每个 object 的面数统计好了（dump_model 的 "facets"）。
        size_t object_count = 0;
        size_t facet_count  = 0;
        {
            const nlohmann::json dm = dump_model(model);
            const auto objs = dm.find("objects");
            if (objs != dm.end() && objs->is_array()) {
                object_count = objs->size();
                for (const auto& o : *objs) {
                    if (o.is_object())
                        facet_count += o.value("facets", static_cast<size_t>(0));
                }
            }
            if (object_count > k_max_objects || facet_count > k_max_facets) {
                char buf[192];
                std::snprintf(buf, sizeof(buf),
                              "模型过大：对象数=%zu 三角面=%zu，超过本机可切片上限"
                              "（对象数≤%zu 三角面≤%zu）",
                              object_count, facet_count, k_max_objects, k_max_facets);
                out["message"] = buf;
                return out.dump();
            }
        }
        // 真实规模（对象数 / 三角面）写进消息，不编造
        emit(0, 100, "模型装载完成 · " + std::to_string(object_count) + " 个对象 · " +
                     std::to_string(facet_count) + " 三角面");

        std::vector<std::string> skipped;
        // 打印机预设项保护集：这些键只认「当前打印机预设 + 3MF 工程内嵌配置」，
        // 不允许 UI 参数表里的兜底默认值覆盖（见 apply_params 头注释）。
        // curr_bed_type 故意排除：它由界面（全局打印板 / 盘级床型）主动管理。
        std::set<std::string> hw_keys;
        {
            std::lock_guard<std::mutex> lock(g_preset_mutex);
            if (g_preset_bundle) {
                const DynamicPrintConfig& pc = g_preset_bundle->printers.get_selected_preset().config;
                for (const std::string& k : pc.keys())
                    if (k != "curr_bed_type")
                        hw_keys.insert(k);
            }
        }
        // 顺序很重要：先把「对象颜色 → 耗材槽位」展开到 N 档，再叠加 UI 参数。
        // 反过来的话 expand_filament_vectors 会把用户改过的耗材级向量（喷嘴/板温、风扇等）
        // 整段替换回预设出厂值 —— 实测审计日志「下发=220 / 内核生效=200」正是这个顺序造成的。
        apply_multicolor_request(model, config, fil_req, output_path);
        apply_params(config, params_json, skipped, &hw_keys);
        if (!hw_keys.empty()) {
            char buf[80];
            std::snprintf(buf, sizeof(buf), "3a-hw-protect=%d", static_cast<int>(hw_keys.size()));
            set_stage(buf);
        }
        if (!skipped.empty())
            out["skippedParams"] = skipped;
        if (fil_req.present) {
            out["filamentCount"] = fil_req.count;
            out["objectFilament"] = fil_req.obj_slot;
            out["filamentColours"] = fil_req.colour;
        }

        // 参数自洽性检查：不通过时直接给出可读原因，而不是等 process() 里崩。
        config.validate();

        // ---- 阶段 1：贴板居中（无细粒度钩子 -> 只报进入/完成，带真实包围盒/板尺寸）----
        emit(1, 5, "贴板居中");
        // 摆位要放在参数之后：热床尺寸取自最终配置。
        set_stage("2-normalize");
        normalize_loaded_model(model, config);
        {
            const BoundingBoxf3 bb = model.bounding_box();
            char buf[192];
            std::snprintf(buf, sizeof(buf), "贴板居中完成 · 包围盒 %.1f × %.1f × %.1f mm",
                          bb.max.x() - bb.min.x(), bb.max.y() - bb.min.y(), bb.max.z() - bb.min.z());
            std::string msg = buf;
            double bx0 = 0.0, by0 = 0.0, bx1 = 0.0, by1 = 0.0;
            if (bed_bbox_from_config(config, bx0, by0, bx1, by1)) {
                std::snprintf(buf, sizeof(buf), " · 板 %.0f × %.0f mm", bx1 - bx0, by1 - by0);
                msg += buf;
            }
            emit(1, 100, msg);
        }

        // ---- 阶段 2：合并配置（无细粒度钩子 -> 只报进入/完成，带真实层高/墙数）----
        emit(2, 5, "合并配置");
        set_stage("3-apply");
        print.apply(model, config);

        // 兜底：内核在"0 个 PrintObject"时会静默空转，最后报一句完全对不上的
        // "No object can be printed. Maybe too small"。这里直接把真因说出来。
        if (print.objects().empty()) {
            out["message"] = "模型没有生成任何可打印对象（PrintObject=0）："
                             "对象的 instances / printable 标志异常，见 .debug.json";
            return out.dump();
        }

        // 打印板状态必须显式给：Print() = default，而 m_origin 是裸 Vec3d（没有类内初值），
        // 桌面版由 Plater 调 set_plate_origin() 填，我们直接调内核就得自己来。
        // 不填的话它是未初始化的栈垃圾，会被当成 G-code 坐标偏移用
        // （Print::export_gcode -> GCode::set_gcode_offset），坐标瞬间变成天文数字，
        // 后面的 Clipper 布尔运算就会崩。
        print.set_plate_index(0);
        print.set_plate_origin(Vec3d::Zero());

        // BBL 打印机标志：GCode 导出里有 37 处按 is_BBL_Printer() 分支 ——
        // M981 开关 spaghetti detector、M1003、jerk/加速度的写法、
        // 以及 process_layer 里的回抽/Z-hop 策略（这里差一步就会多出上百条移动）。
        // Print 里它默认 false（Print.hpp: m_isBBLPrinter = false），桌面版由 Plater
        // 依据所选打印机预设设置，我们直接调内核必须自己设，否则导出的是"通用打印机"的 G-code。
        {
            std::string printer_model;
            if (const ConfigOptionString* pm = config.option<ConfigOptionString>("printer_model"))
                printer_model = pm->value;
            const bool is_bbl = printer_model.rfind("Bambu Lab", 0) == 0;
            print.set_BBL_Printer(is_bbl);
        }

        // Print::validate() 负责"对象超出热床/互相碰撞/切片厚度不合理"这类业务校验。
        set_stage("4-validate");
        StringObjectException warning;
        const StringObjectException validation = print.validate(&warning);
        if (!validation.string.empty()) {
            out["message"] = validation.string;
            return out.dump();
        }
        // 【OpenHarmony 移植】validate 的「非阻断警告」（目前只有板型/耗材温度不匹配，见
        // Print.cpp 的 STRING_EXCEPT_FILAMENT_NOT_MATCH_BED_TYPE）回传给界面提示，但不中止切片。
        if (!warning.string.empty()) {
            out["warning"] = warning.string;
        }
        {
            // 合并配置完成：层高 / 墙层数都是最终 config 里的真实值
            const double lh = config.opt_float("layer_height");
            const int    walls = config.opt_int("wall_loops");
            char buf[128];
            std::snprintf(buf, sizeof(buf), "配置校验通过 · 层高 %.2f mm · %d 层墙", lh, walls);
            emit(2, 100, buf);
        }

        // ---- 阶段 3/4 的内核进度钩子 -----------------------------------------
        // 复用 libslic3r 自带的 PrintBase::set_status_callback（PrintBase.hpp:481，
        // typedef std::function<void(const SlicingStatus&)>, PrintBase.hpp:475）。
        // 内核在 process() 与 export_gcode() 内部通过 set_status(percent, msg) 触发它
        // （Print.cpp/PrintObject.cpp/PrintObjectSlice.cpp/GCode.cpp），是真实进度，不是我们插桩。
        //   * process()      : 子步骤级（percent + 文案），如 "Slicing mesh"(5)、
        //                      "Generating walls"(15)、"Generating infill regions"(25)…(PrintObject.cpp)；
        //   * export_gcode() : 按层，percent 固定 80，文案 "Generating G-code: layer N"
        //                      （GCode.cpp:3627 / :3768）—— 这里能拿到真实层号 N。
        if (progress) {
            print.set_status_callback(
                [&emit, &yield_gate, &in_export, &total_layers](const PrintBase::SlicingStatus& st) {
                    yield_gate();
                    if (st.percent < 0) { return; }   // 警告类回调（percent 默认 -1），不是进度
                    if (!in_export) {
                        emit(3, st.percent, st.text);
                        return;
                    }
                    static const std::string kLayerTag = "Generating G-code: layer ";
                    if (st.text.rfind(kLayerTag, 0) == 0) {
                        long long n = 0;
                        try { n = std::stoll(st.text.substr(kLayerTag.size())); } catch (...) { n = 0; }
                        if (n > 0 && total_layers > 0) {
                            const int p = static_cast<int>(100.0 * static_cast<double>(n) /
                                                           static_cast<double>(total_layers));
                            emit(4, p, "导出 G-code · 第 " + std::to_string(n) + " / " +
                                       std::to_string(total_layers) + " 层");
                            return;
                        }
                    }
                    // 导出阶段里非按层的状态（如 85/90 的收尾提示）：按内核百分比给个粗略区间
                    emit(4, st.percent >= 90 ? 99 : (st.percent >= 85 ? 95 : st.percent), st.text);
                });
        }

        emit(3, 0, "开始分层与路径");
        set_stage("5-process");
        // 多色分 part 成多个对象时，上层 part 的起始 z > 0（压在底层 part 上）——
        // 它自己的第 0 层必然空，内核会误判成浮空件并抛 empty initial layer。这里只在
        // 「槽位数 > 1」的请求下豁免这一次检查（单色仍保留内核的浮空提示）。
        // 守卫必须活到导出结束：那条检查实际在 export_gcode 里才跑（见 EmptyInitialLayerGuard）。
        EmptyInitialLayerGuard empty_layer_guard(fil_req.count > 1);
        print.process();

        // 真实层数（各对象最大层数），同时作为导出阶段「第 N / M 层」的 M
        for (const PrintObject* obj : print.objects()) {
            if (obj != nullptr)
                total_layers = std::max(total_layers, obj->layers().size());
        }
        emit(3, 100, "分层与路径完成 · " + std::to_string(total_layers) + " 层");

        // ---- 阶段 4：导出 G-code ---------------------------------------------
        in_export = true;
        emit(4, 0, "开始导出 G-code · " + std::to_string(total_layers) + " 层");
        set_stage("6-export");
        // 必须传一个真实的 GCodeProcessorResult：GCode::do_export 收尾处
        //   result->label_object_enabled = ...
        //   result->support_material_on_wipe_tower = ...
        // 是无条件解引用（在 `if (result != nullptr)` 保护块之外）。上游只被桌面版调用，
        // 而桌面版永远传 PreviewData，所以这个 bug 一直没暴露；我们传 nullptr 就会在那两行 SIGSEGV。
        GCodeProcessorResult export_result;
        const std::string written = print.export_gcode(output_path, &export_result, nullptr);
        set_stage("7-done");
        {
            std::string msg = "G-code 已写入 · " + std::to_string(total_layers) + " 层";
            boost::system::error_code ec;
            const boost::uintmax_t bytes = boost::filesystem::file_size(written, ec);
            if (!ec) {
                char buf[64];
                std::snprintf(buf, sizeof(buf), " · %.1f MB",
                              static_cast<double>(bytes) / (1024.0 * 1024.0));
                msg += buf;
            }
            emit(4, 100, msg);
        }

        const PrintStatistics& stats = print.print_statistics();

        size_t layers = 0;
        for (const PrintObject* obj : print.objects()) {
            if (obj != nullptr)
                layers = std::max(layers, obj->layers().size());
        }

        const auto t_end = std::chrono::steady_clock::now();
        const double seconds = std::chrono::duration<double>(t_end - t_begin).count();

        out["ok"]                 = true;
        out["status"]             = "done";
        out["output"]             = written;
        out["layers"]             = layers;
        out["timeSeconds"]        = seconds;
        out["filamentUsedMm"]     = stats.total_used_filament;
        out["filamentUsedG"]      = stats.total_weight;
        out["estimatedPrintTime"] = stats.estimated_normal_print_time;
        // 审计块（方案 B）：把「界面下发 ↔ 内核生效 ↔ gcode 实证」写进 <输出目录>/diag/gcode_diag.txt。
        // 审计本身失败绝不影响切片结果。
        try {
            audit_write_block(config, written, params_json, skipped);
        } catch (...) {
        }
        return out.dump();
    } catch (const Slic3r::SlicingErrors& se) {
        // 「首层豁免」由 EmptyInitialLayerGuard 在栈展开时自动复位，这里不再重复处理。
        // 内核把多条 SlicingError 聚合在本异常里；它的 what() 只有泛型名 "Errors"，
        // 真正原因存在 errors_ 里 —— 必须逐条取出来，否则界面只剩无法行动的 "Errors"。
        std::string text;
        for (size_t i = 0; i < se.errors_.size(); ++i) {
            if (i) { text += " ｜ "; }
            const Slic3r::SlicingError& one = se.errors_[i];
            if (one.objectId() > 0)
                text += "对象#" + std::to_string(one.objectId()) + ": ";
            text += one.what();
        }
        if (text.empty())
            text = "Errors(内核未提供文本)";
        return slice_failure_json(input_path, output_path, model, config, print, text);
    } catch (const Slic3r::SlicingError& se) {
        // 单条 SlicingError：what() 就是真实文本，objectId 补在前面便于定位是哪个对象。
        std::string text = se.what();
        if (se.objectId() > 0)
            text = "对象#" + std::to_string(se.objectId()) + ": " + text;
        return slice_failure_json(input_path, output_path, model, config, print, text);
    } catch (const std::exception& e) {
        // 其它异常：先保住 e.what()，再把能抓到的状态拼到前面。
        return slice_failure_json(input_path, output_path, model, config, print, e.what());
    } catch (...) {
        out["message"] = "切片异常: 未知错误";
        return out.dump();
    }
}

// 无进度的切片：与带进度版本共用同一份实现（progress 为空 = 不注册任何内核回调），行为不变。
std::string slicer_slice(const std::string& input_path,
                         const std::string& params_json,
                         const std::string& output_path)
{
    return slicer_slice_with_progress(input_path, params_json, output_path, SliceProgressFn());
}

// =============================================================================
//  项目 3MF 导出（拓竹原生工程格式，方案 1：由内核写文件）
//
//  写文件的不是我们自己拼 zip，而是内核自带的 store_bbs_3mf（Format/bbs_3mf.cpp）——
//  与桌面版 Bambu Studio「保存项目」同一条代码路径，所以产出天然是一份可被拓竹与
//  我们完整还原的工程 3MF：Metadata/project_settings.config（机型/工艺/耗材预设名 +
//  全部切片参数）、Metadata/model_settings.config（对象/摆放/盘/对象级设置）、
//  Metadata/slice_info.config、[Content_Types].xml、_rels/.rels 等。
//
//  不修改 libslic3r 上游逻辑：这里只是把「当前生效配置 + 已载入模型 + 一块盘」按
//  StoreParams 的标准用法喂给它。SkipStatic 跳过缩略图/辅助目录（我们本就没有），
//  Silence 让内核不往 backup 目录写 origin.txt。
// =============================================================================
// 公共实现（项目 3MF 与含 gcode 的 .gcode.3mf 共用这一份，避免两套口径分叉）：
//   gcode_path 为空 → 仅项目 3MF（与既有行为**逐字节等价**：仍是 Zip64|SkipStatic|Silence）；
//   gcode_path 非空 → 额外把该 gcode 作为 Metadata/plate_1.gcode（含 .md5）打进包，
//                     产出一份可被打印机直接打印的 .gcode.3mf。
static std::string export_project_3mf_impl(const std::string& input_path,
                                           const std::string& params_json,
                                           const std::string& output_path,
                                           const std::string& gcode_path)
{
    nlohmann::json out;
    out["ok"] = false;

    if (input_path.empty()) {
        out["message"] = "未指定输入模型";
        return out.dump();
    }
    if (output_path.empty()) {
        out["message"] = "未指定输出路径";
        return out.dump();
    }

    // 带 gcode 模式：源 gcode 必须存在。不存在时内核 _add_gcode_file_to_archive 会返回 false
    // （bbs_3mf.cpp:8915 判 exists），把失败原因直接归给内核不好定位，这里提前给出明确原因。
    const bool with_gcode = !gcode_path.empty();
    if (with_gcode) {
        boost::system::error_code gec;
        if (!boost::filesystem::exists(gcode_path, gec) || boost::filesystem::is_directory(gcode_path, gec)) {
            // ④ 把内核侧能拿到的原因一次带全（源 gcode 状态 / withGcode / SkipStatic / 目标路径）。
            out["message"] = "指定的 G-code 文件不存在: " + gcode_path
                + "；源gcode存在=否"
                + "；withGcode=1 SkipStatic=0（带 gcode 模式去掉 SkipStatic）"
                + "；目标=" + output_path;
            return out.dump();
        }
    }

    // 现场诊断：状态提到 try 外，异常时 catch 里才拿得到。
    Model             model;
    DynamicPrintConfig config;
    PlateDataPtrs     plate_list;
    // 输入 3MF 自带的盘结构（含每盘床型/盘内对象）。空 = 裸网格或单盘文件 → 走旧的单盘兜底。
    PlateDataPtrs     loaded_plates;
    // loaded_plates 可能在多个提前 return 的路径上，用析构保证释放。
    struct LoadedPlatesReleaser {
        PlateDataPtrs& list;
        ~LoadedPlatesReleaser() { release_PlateData_list(list); }
    } loaded_releaser{ loaded_plates };

    try {
        // 配置基线：官方预设合成结果（机型 + 工艺 + 耗材 + 全部切片参数）。
        // 写进 3MF 的就是这份配置 —— 这就是「含完整切片设置」的来源。
        {
            std::lock_guard<std::mutex> lock(g_preset_mutex);
            config = current_full_config();
        }

        // 临时目录必须在任何模型加载/导出之前指好：3MF 加载器与导出器都要用它
        // （Model::get_backup_path() 会往 temporary_dir() 下解/写中间文件）。
        std::string err;
        if (!ensure_temporary_dir(output_path, err)) {
            out["message"] = err;
            return out.dump();
        }

        // 连同盘结构一起加载：多盘工程保存时必须沿用输入里的 <plate>（盘号/盘名/盘级床型/盘内对象）
        if (!load_model_file(input_path, model, config, err, &loaded_plates)) {
            out["message"] = err;
            return out.dump();
        }
        if (model.objects.empty()) {
            out["message"] = "模型里没有可保存对象";
            return out.dump();
        }

        // 导出前把面汤焊成索引网格：否则存出来的 3MF 每个三角形各带 3 个顶点
        // （体积翻数倍），下次打开再切片时分层会退化成碎片（见 weld_model_meshes 的说明）。
        weld_model_meshes(model);

        // 「对象颜色 → 耗材槽位」：导出前同样把配置展开到 N 档 + 给对象分配挤出机，
        // 这样内核 store_bbs_3mf 写出的 model_settings.config 里每个对象带 extruder，
        // project_settings.config 里带 N 档 filament 颜色/类型 —— 存盘后再打开颜色仍在。
        // 顺序与切片一致：先展开多耗材，再叠加 UI 参数（否则耗材级用户改动会被展开覆盖）。
        const FilamentReq fil_req = parse_filament_request(params_json);
        apply_multicolor_request(model, config, fil_req, output_path);
        // UI 当前动态表单参数最后叠加（与切片完全同一套口径：界面优先；
        // 但打印机预设项同样保护 —— 否则存出来的工程会把 A1 mini 的高度/喷头参数写成通用默认值，
        // 下次切片即使不再下发 UI 参数也已经被污染）。
        std::vector<std::string> skipped;
        std::set<std::string> hw_keys;
        {
            std::lock_guard<std::mutex> lock(g_preset_mutex);
            if (g_preset_bundle) {
                const DynamicPrintConfig& pc = g_preset_bundle->printers.get_selected_preset().config;
                for (const std::string& k : pc.keys())
                    if (k != "curr_bed_type")
                        hw_keys.insert(k);
            }
        }
        apply_params(config, params_json, skipped, &hw_keys);
        if (!skipped.empty())
            out["skippedParams"] = skipped;
        out["filamentCount"] = fil_req.present ? fil_req.count : 0;
        config.validate();

        // 自带摆位（3MF 的 build 段 → 已有 instance）时原样保留；裸网格（stl/obj/step）
        // 才贴板居中 —— 与切片时同一套口径，避免导出的摆放和界面看到的不一致。
        normalize_loaded_model(model, config);

        // 单盘兜底 / 统计：全部对象/实例
        std::set<std::pair<int, int>> obj_to_inst;
        size_t facet_total = 0;
        for (size_t oi = 0; oi < model.objects.size(); ++oi) {
            const ModelObject* mo = model.objects[oi];
            if (mo == nullptr)
                continue;
            for (size_t ii = 0; ii < mo->instances.size(); ++ii)
                obj_to_inst.insert({ static_cast<int>(oi), static_cast<int>(ii) });
            facet_total += mo->facets_count();
        }
        if (obj_to_inst.empty() || facet_total == 0) {
            out["message"] = "模型里没有可保存对象";
            return out.dump();
        }

        // ---- 盘结构 ----
        // 输入 3MF 带 <plate> 时**原样保留**（盘号/盘名/盘级床型/盘内对象）；
        // 否则（裸网格或单盘输入）沿用「全部对象挂 1 号盘」的旧行为。
        // 不保留的话：多盘工程一保存就被并成单盘，盘级床型也随之丢失。
        PlateData* primary_plate = nullptr;
        if (!loaded_plates.empty()) {
            // 加载路径只填 PlateData::obj_inst_map（文件 object_id → (instance_id, identify_id)），
            // 用 identify_id（= ModelInstance::loaded_id）反查导出用的 (对象下标, 实例下标)。
            std::map<size_t, std::pair<int, int>> ident_to_objinst;
            for (size_t oi = 0; oi < model.objects.size(); ++oi) {
                ModelObject* mo = model.objects[oi];
                if (mo == nullptr)
                    continue;
                for (size_t ii = 0; ii < mo->instances.size(); ++ii) {
                    if (mo->instances[ii] != nullptr)
                        ident_to_objinst[mo->instances[ii]->loaded_id] =
                            std::make_pair(static_cast<int>(oi), static_cast<int>(ii));
                }
            }
            for (PlateData* pd : loaded_plates) {
                if (pd == nullptr || pd->plate_index < 0)
                    continue;
                std::set<std::pair<int, int>> members;
                for (const auto& kv : pd->obj_inst_map) {
                    const auto it = ident_to_objinst.find(static_cast<size_t>(kv.second.second));
                    if (it != ident_to_objinst.end())
                        members.insert(it->second);
                }
                if (members.empty())
                    continue;
                PlateData* np = new PlateData(pd->plate_index, members, pd->locked);
                np->plate_name = pd->plate_name;
                // 盘级床型：盘自己的优先（本次要做的事），没有则回落全局配置
                if (const ConfigOption* o = pd->config.option("curr_bed_type"))
                    np->config.set_key_value("curr_bed_type", o->clone());
                else if (const ConfigOption* g = config.option("curr_bed_type"))
                    np->config.set_key_value("curr_bed_type", g->clone());
                // 其余盘级项仍以界面当前配置为准（用户刚改的打印顺序等要生效）
                const char* plate_keys[] = { "print_sequence", "first_layer_print_sequence",
                                             "other_layers_print_sequence" };
                for (const char* key : plate_keys) {
                    if (const ConfigOption* g = config.option(key))
                        np->config.set_key_value(key, g->clone());
                }
                plate_list.push_back(np);
                if (primary_plate == nullptr)
                    primary_plate = np;
            }
        }
        if (plate_list.empty()) {
            // 单盘兜底（与改造前逐字节一致）
            PlateData* plate = new PlateData(0, obj_to_inst, /*lock_state=*/false);
            const char* plate_keys[] = { "curr_bed_type", "print_sequence",
                                         "first_layer_print_sequence", "other_layers_print_sequence" };
            for (const char* key : plate_keys) {
                if (const ConfigOption* o = config.option(key))
                    plate->config.set_key_value(key, o->clone());
            }
            plate_list.push_back(plate);
            primary_plate = plate;
        }
        if (primary_plate == nullptr)
            primary_plate = plate_list.front();
        // 带 gcode 模式：内核只对「有 gcode 文件 + 标记为已切片」的盘写 Metadata/plate_N.gcode
        // 与其 .md5（bbs_3mf.cpp:6777 与 8894 的判据均为
        // !gcode_file.empty() && is_sliced_valid && boost::filesystem::exists(gcode_file)）。
        // 带 gcode 的输入按盘构建（单盘输入），盘结构与 gcode 一定落在同一块盘上。
        if (with_gcode) {
            primary_plate->gcode_file = gcode_path;
            primary_plate->is_sliced_valid = true;
        }

        StoreParams sp;
        sp.path = output_path.c_str();
        sp.model = &model;
        sp.plate_data_list = plate_list;
        sp.export_plate_idx = -1;
        sp.config = &config;
        // WithGcode 的字段依据：bbs_3mf.hpp:168 `WithGcode = 1 << 4`；
        // bbs_3mf.cpp:6336 `m_save_gcode = store_params.strategy & SaveStrategy::WithGcode`。
        // 带 gcode 时**必须去掉 SkipStatic**：gcode 的 .md5 与 _add_gcode_file_to_archive 都被
        // `!m_skip_static` 守着（bbs_3mf.cpp:6777 / 6812），SkipStatic 会把 gcode 一起跳过。
        // 不带 gcode 时保持原样（Zip64|SkipStatic|Silence），既有两条导出行为不变。
        sp.strategy = with_gcode
            ? (SaveStrategy::Zip64 | SaveStrategy::Silence | SaveStrategy::WithGcode)
            : (SaveStrategy::Zip64 | SaveStrategy::SkipStatic | SaveStrategy::Silence);

        if (!store_bbs_3mf(sp)) {
            // ④ store_bbs_3mf 只返回 bool，失败原因全在内核内部被吞掉。这里在内核侧把「能拿到的全部
            //    现场」组装进返回 JSON 的 message：目标路径 / 目标可用空间 / 写失败 errno / 源 gcode
            //    是否存在与大小 / withGcode 是否生效 / SkipStatic 状态 —— 上层据此能直接定位，不再
            //    只有一句泛化的「导出失败」。不改切片逻辑，只增强失败原因的输出。
            const int saved_errno = errno;
            boost::system::error_code sec;
            const boost::filesystem::space_info sinfo =
                boost::filesystem::space(boost::filesystem::path(output_path), sec);
            std::string space_txt;
            if (sec) {
                space_txt = std::string("未知(") + sec.message() + ")";
            } else {
                space_txt = std::to_string(static_cast<unsigned long long>(sinfo.available)) +
                            " bytes 可用/" + std::to_string(static_cast<unsigned long long>(sinfo.capacity)) + " 总";
            }
            std::string gcode_state;
            if (with_gcode) {
                boost::system::error_code gec2;
                const bool gex = boost::filesystem::exists(gcode_path, gec2);
                boost::uintmax_t gsz = 0;
                if (gex) { gsz = boost::filesystem::file_size(gcode_path, gec2); }
                gcode_state = "源gcode存在=" + std::string(gex ? "是" : "否") +
                              " 源gcode大小=" + std::to_string(static_cast<unsigned long long>(gsz)) +
                              " 源gcode=" + gcode_path;
            } else {
                gcode_state = "源gcode=未指定（纯项目 3MF）";
            }
            const bool skip_static = (sp.strategy & SaveStrategy::SkipStatic) != 0;
            const bool with_gcode_flag = (sp.strategy & SaveStrategy::WithGcode) != 0;
            std::string msg = "内核 3MF 导出失败（store_bbs_3mf 返回 false）";
            msg += "；目标=" + output_path;
            msg += "；目标可用空间=" + space_txt;
            msg += "；写失败 errno=" + std::to_string(saved_errno) +
                   "(" + std::strerror(saved_errno) + ")";
            msg += "；" + gcode_state;
            msg += "；strategy: withGcode=" + std::string(with_gcode_flag ? "1" : "0") +
                   "(请求withGcode=" + std::string(with_gcode ? "1" : "0") + ")";
            msg += " SkipStatic=" + std::string(skip_static ? "1" : "0");
            out["message"] = msg;
            return out.dump();
        }

        // 导出前实测规模（写进返回，供 ArkTS 打日志/提示；数字全部来自内核真实数据）
        const BoundingBoxf3 bb = model.bounding_box();
        out["ok"]     = true;
        out["path"]   = output_path;
        out["objects"] = model.objects.size();
        out["facets"]  = facet_total;
        out["bbox"]    = nlohmann::json::array({ bb.min.x(), bb.min.y(), bb.min.z(),
                                                 bb.max.x(), bb.max.y(), bb.max.z() });

        // 把「写进去的设置」关键项一并回报，便于日志核对确实带了设置
        auto first_string = [&config](const char* key) -> std::string {
            if (const ConfigOptionStrings* s = config.option<ConfigOptionStrings>(key))
                return s->values.empty() ? std::string() : s->values.front();
            if (const ConfigOptionString* s1 = config.option<ConfigOptionString>(key))
                return s1->value;
            return std::string();
        };
        out["printer"]   = first_string("printer_settings_id");
        out["process"]   = first_string("print_settings_id");
        out["filament"]  = first_string("filament_settings_id");
        out["printerModel"] = first_string("printer_model");
        if (config.option("layer_height") != nullptr)
            out["layerHeight"] = config.opt_float("layer_height");

        // 带 gcode 时回报写入的 gcode 及其 md5（md5 由内核在写包时算出并落到 plate->gcode_file_md5，
        // 与包内 Metadata/plate_1.gcode.md5 内容一致），供 ArkTS 日志核对。
        out["withGcode"] = with_gcode;
        if (with_gcode) {
            out["gcode"]    = gcode_path;
            out["gcodeMd5"] = primary_plate->gcode_file_md5;
        }

        // ---- 往返自测：导出后立刻用内核自己的 BBL 3MF 加载器读回，核对对象数/面数/包围盒 ----
        // 只在 LoadModel 策略下读，不碰配置/盘/预设，读出的数据直接作为自证证据。
        try {
            Model                   rt_model;
            DynamicPrintConfig      rt_config;
            ConfigSubstitutionContext rt_csc{ForwardCompatibilitySubstitutionRule::Disable};
            PlateDataPtrs           rt_plates;
            std::vector<Preset*>    rt_presets;
            bool                    rt_is_bbl = false;
            Semver                  rt_ver;
            const bool rt_ok = load_bbs_3mf(output_path.c_str(), &rt_config, &rt_csc, &rt_model,
                                            &rt_plates, &rt_presets, &rt_is_bbl, &rt_ver,
                                            nullptr, LoadStrategy::LoadModel);
            size_t rt_facets = 0;
            for (const ModelObject* mo : rt_model.objects)
                if (mo != nullptr)
                    rt_facets += mo->facets_count();
            const BoundingBoxf3 rt_bb = rt_model.bounding_box();
            nlohmann::json jrt;
            jrt["ok"]          = rt_ok;
            jrt["objects"]     = rt_model.objects.size();
            jrt["facets"]      = rt_facets;
            jrt["bbox"]        = nlohmann::json::array({ rt_bb.min.x(), rt_bb.min.y(), rt_bb.min.z(),
                                                         rt_bb.max.x(), rt_bb.max.y(), rt_bb.max.z() });
            jrt["isBbl3mf"]    = rt_is_bbl;
            jrt["fileVersion"] = rt_ver.to_string();
            out["roundTrip"]   = jrt;
            release_PlateData_list(rt_plates);
        } catch (const std::exception& re) {
            nlohmann::json jrt;
            jrt["ok"]      = false;
            jrt["message"] = std::string("读回异常: ") + re.what();
            out["roundTrip"] = jrt;
        }

        release_PlateData_list(plate_list);
        return out.dump();
    } catch (const std::exception& e) {
        release_PlateData_list(plate_list);
        out["message"] = std::string("3MF 导出异常: ") + e.what();
        return out.dump();
    } catch (...) {
        release_PlateData_list(plate_list);
        out["message"] = "3MF 导出异常: 未知错误";
        return out.dump();
    }
}

// 项目 3MF（含完整切片设置，不含 gcode）—— 既有行为，签名保持不变。
std::string slicer_export_project_3mf(const std::string& input_path,
                                      const std::string& params_json,
                                      const std::string& output_path)
{
    return export_project_3mf_impl(input_path, params_json, output_path, std::string());
}

// 含 gcode 的 .gcode.3mf：同一份实现，额外把 gcode_path 作为 Metadata/plate_1.gcode 打进包。
std::string slicer_export_gcode_3mf(const std::string& input_path,
                                    const std::string& params_json,
                                    const std::string& output_path,
                                    const std::string& gcode_path)
{
    return export_project_3mf_impl(input_path, params_json, output_path, gcode_path);
}

// =============================================================================
//  3MF 导入（几何 + 设置 + 盘）
//
//  与切片/导出共用同一个内核加载器（load_model_file -> Model::read_from_file -> load_bbs_3mf），
//  所以「切片用的文件」「UI 看到的文件」是同一份解析结果，不会出现两套解析口径不一致。
//
//  几何不走 JSON：顶点以 Float32 三角汤（非索引）经 out_positions 交给 ArkTS，
//  JSON 里只放元数据（名字/面数/摆放/包围盒/顶点区间/盘归属），避免大模型把 JS 堆撑爆。
// =============================================================================

namespace {

// 取字符串选项的首个值（printer_settings_id / print_settings_id / filament_settings_id 都是数组）
std::string first_string_of(const DynamicPrintConfig& cfg, const char* key)
{
    if (const ConfigOptionStrings* s = cfg.option<ConfigOptionStrings>(key))
        return s->values.empty() ? std::string() : s->values.front();
    if (const ConfigOptionString* s1 = cfg.option<ConfigOptionString>(key))
        return s1->value;
    return std::string();
}

// 枚举选项的「内核名字」（用于界面对照，如 curr_bed_type -> "Cool Plate"）。
// **必须用 serialize()**：它走内核的 enum_keys_map（枚举值 → 名字），
// 而 enum_values 只是"表单可选项列表"，两者的下标语义并不保证一致
// （例：curr_bed_type 的 C++ 枚举是 btDefault=0,btPC=1,... 而 enum_values[0] 是 "Cool Plate"，
//   用 enum_values[getInt()] 会整体错位一格 —— 这也是 apply_params() 里拒绝 setInt 的同一条坑）。
std::string enum_name_of(const DynamicPrintConfig& cfg, const char* key)
{
    const ConfigOption* o = cfg.option(key);
    if (o == nullptr)
        return std::string();
    if (o->type() == coEnum) {
        const std::string name = o->serialize();
        if (!name.empty())
            return name;
        const ConfigOptionDef* od = print_config_def.get(key);
        if (od != nullptr) {
            const int idx = o->getInt();
            if (idx >= 0 && static_cast<size_t>(idx) < od->enum_values.size())
                return od->enum_values[static_cast<size_t>(idx)];
        }
    }
    return o->serialize();
}

} // namespace

// 导入阶段 trace：写到 <3mf>.trace。
// 为什么需要它：3MF 加载在 worker 线程上，真机本机 C++ hilog 不进缓冲（且崩溃后什么都来不及打），
// 只有「每步 append + 立即 close」才能让崩溃前最后完成的阶段落盘。
// 仅导入路径使用，写完一个小文件（几十字节），成本可忽略。
static std::string g_import_trace_base;

// 「多色按 part 拆成多个对象」时的首层豁免（见头文件说明）。
// 用模块级开关而不是配置项：它只影响本次切片的内核检查，且必须在 process() 之前置位。
static bool g_allow_empty_initial_layer = false;

void set_allow_empty_initial_layer(bool on) { g_allow_empty_initial_layer = on; }
bool allow_empty_initial_layer() { return g_allow_empty_initial_layer; }

void set_import_trace_base(const std::string& base)
{
    g_import_trace_base = base;
}

void import_trace_stage(const std::string& stage)
{
    if (g_import_trace_base.empty()) { return; }
    std::ofstream f(g_import_trace_base + ".trace", std::ios::out | std::ios::app);
    if (!f) { return; }
    f << stage << "\n";
    f.flush();
}

static void import_trace(const std::string& base, const std::string& stage, bool reset = false)
{
    std::ofstream f(base + ".trace", reset ? (std::ios::out | std::ios::trunc) : (std::ios::out | std::ios::app));
    if (!f) { return; }
    f << stage << "\n";
    f.flush();
}

std::string slicer_import_3mf(const std::string& path, std::vector<float>& out_positions)
{
    nlohmann::json out;
    out["ok"]       = false;
    out["hasModel"] = false;
    out_positions.clear();

    if (path.empty()) {
        out["message"] = "未指定 3MF 文件";
        return out.dump();
    }

    Model             model;
    DynamicPrintConfig config;
    PlateDataPtrs     plate_list;

    import_trace(path, "enter", true);
    set_import_trace_base(path);
    try {
        std::string err;
        // 临时目录：3MF 加载器会往 temporary_dir()/bamboo_model/... 解中间产物
        // （path 是应用私有目录下的副本，slice_tmp 会建在它旁边，一定可写）
        if (!ensure_temporary_dir(path, err)) {
            out["message"] = err;
            import_trace(path, "tmpdir_fail " + err);
            return out.dump();
        }
        import_trace(path, "tmpdir_ok");
        import_trace(path, "load_start");

        if (!load_model_file(path, model, config, err, &plate_list, /*tolerate_empty_model=*/true)) {
            release_PlateData_list(plate_list);
            out["message"] = err;
            import_trace(path, "load_fail " + err);
            return out.dump();
        }
        import_trace(path, "load_ok objects=" + std::to_string(model.objects.size()) +
                           " plates=" + std::to_string(plate_list.size()));

        // ---- 设置：project_settings.config 的全量扁平化（与 slicer_config_snapshot 同一套口径）----
        // 拆成 keys/values 两个平行数组而不是对象：ArkTS 侧要静态类型解析（不用 Record / any）。
        const nlohmann::json flat = config_flat_json(config);
        nlohmann::json jkeys = nlohmann::json::array();
        nlohmann::json jvals = nlohmann::json::array();
        for (auto it = flat.begin(); it != flat.end(); ++it) {
            jkeys.push_back(it.key());
            jvals.push_back(it.value());
        }
        out["settingKeys"]   = jkeys;
        out["settingValues"] = jvals;

        auto num_of = [&flat](const char* k, double& v) -> bool {
            const auto it = flat.find(k);
            if (it == flat.end() || !it->is_number())
                return false;
            v = it->get<double>();
            return true;
        };

        nlohmann::json presets;
        presets["printer"]  = first_string_of(config, "printer_settings_id");
        presets["process"]  = first_string_of(config, "print_settings_id");
        presets["filament"] = first_string_of(config, "filament_settings_id");
        presets["bed"]      = enum_name_of(config, "curr_bed_type");
        out["presets"] = presets;

        // 耗材颜色/槽位列表（project_settings.config 的 filament_colour）：
        // 与每个对象的 extruder 序号配合，ArkTS 侧还原对象的显示色（多色工程往返）。
        if (const ConfigOptionStrings* fc = config.option<ConfigOptionStrings>("filament_colour")) {
            out["filamentColours"] = fc->values;
            out["filamentCount"]   = static_cast<int>(fc->values.size());
        }

        // 关键项单独给出：日志/截图直接对照用（值都来自内核真实读到的配置）
        double lh = 0.0, wl = 0.0, ils = 0.0;
        if (num_of("layer_height", lh))
            out["layerHeight"] = lh;
        if (num_of("wall_loops", wl))
            out["wallLoops"] = wl;
        if (num_of("initial_layer_speed", ils))
            out["initialLayerSpeed"] = ils;

        // ---- 热床尺寸（有 printable_area 才给）----
        double bx0 = 0.0, by0 = 0.0, bx1 = 0.0, by1 = 0.0;
        if (bed_bbox_from_config(config, bx0, by0, bx1, by1)) {
            nlohmann::json bed;
            bed["minX"] = bx0;
            bed["minY"] = by0;
            bed["w"]    = bx1 - bx0;
            bed["h"]    = by1 - by0;
            out["bed"]  = bed;
        }

        // ---- 几何：每个 (object, instance) 一条 entry，顶点追加进 out_positions ----
        nlohmann::json objects = nlohmann::json::array();
        std::vector<int> entry_obj;
        std::vector<int> entry_inst;

        for (size_t oi = 0; oi < model.objects.size(); ++oi) {
            ModelObject* mo = model.objects[oi];
            if (mo == nullptr)
                continue;
            if (mo->instances.empty())
                mo->add_instance(); // 兜底（LoadStrategy::AddDefaultInstances 正常已补）

            // 对象本地网格（各 volume 变换已烘进去，**不含** instance 平移）——
            // 摆放交给 instance 单独回报，UI 侧按盘公共中心摆位。
            import_trace(path, "obj_start oi=" + std::to_string(oi) +
                               " vols=" + std::to_string(mo->volumes.size()) +
                               " insts=" + std::to_string(mo->instances.size()));
            // ⚠️ 不要用 `raw_indexed_triangle_set()`：它对**多 volume 对象**是坏的 ——
            // 顶点按 volume 依次追加，但 indices 是**原样拼接、没有加顶点偏移**，
            // 于是第 2..N 个 volume 的三角形全部引用第 1 个 volume 的顶点。
            // 真机表现：15 个组件的华为徽章只显示一片花瓣（42780 个面全叠在第一片上）。
            // 下面按「耗材」分组后用 TriangleMesh::merge 合并（内部会正确偏移索引）。
            //
            // 为什么按耗材分组而不是整体合并：多色工程的「白底 + 红logo」是同一个对象的
            // 不同 part（各带 extruder），我们的数据模型是「对象 = 一个显示色/耗材槽位」，
            // 整体合并会把白底也染成红色。分组后每个耗材一个 entry，ETS 按 extruder 取色，
            // 视觉与切片请求（多耗材）都能对上。
            int obj_ext = 1;
            if (const ConfigOptionInt* eo =
                    dynamic_cast<const ConfigOptionInt*>(mo->config.option("extruder"))) {
                obj_ext = eo->getInt();
            }
            if (obj_ext < 1) { obj_ext = 1; }

            auto vol_ext_of = [&](size_t vi) -> int {
                ModelVolume* v = mo->volumes[vi];
                if (v != nullptr) {
                    if (const ConfigOptionInt* ve =
                            dynamic_cast<const ConfigOptionInt*>(v->config.option("extruder"))) {
                        const int e = ve->getInt();
                        if (e >= 1) { return e; }
                    }
                }
                return obj_ext;
            };

            std::map<int, std::vector<size_t>> ext_groups;
            for (size_t vi = 0; vi < mo->volumes.size(); ++vi) {
                ModelVolume* v = mo->volumes[vi];
                if (v == nullptr || !v->is_model_part()) { continue; }
                ext_groups[vol_ext_of(vi)].push_back(vi);
            }
            if (ext_groups.empty()) {
                continue; // 无有效网格（如切片盘 .gcode.3mf）
            }
            const bool multi_ext = ext_groups.size() > 1;

            for (size_t ii = 0; ii < mo->instances.size(); ++ii) {
                const ModelInstance* inst = mo->instances[ii];
                if (inst == nullptr)
                    continue;

                // 旋转/缩放参与几何；平移（摆放）不参与 —— 与 UI 的「归一化 + position 摆位」一致
                const Transform3d& m = inst->get_transformation().get_matrix(/*dont_translate=*/true);

                for (const auto& group : ext_groups) {
                    const int ext = group.first;
                    // 合并该耗材组的所有 volume（含各自的 volume 变换）
                    TriangleMesh part;
                    for (size_t vi : group.second) {
                        TriangleMesh vm(mo->volumes[vi]->mesh());
                        vm.transform(mo->volumes[vi]->get_matrix());
                        part.merge(vm);
                    }
                    const indexed_triangle_set& its = part.its;
                    const size_t ntri = its.indices.size();
                    if (ntri == 0) { continue; }
                    import_trace(path, "part oi=" + std::to_string(oi) + " ext=" + std::to_string(ext) +
                                       " vols=" + std::to_string(group.second.size()) +
                                       " tris=" + std::to_string(ntri) + " verts=" +
                                       std::to_string(its.vertices.size()));

                    const long long vert_off = static_cast<long long>(out_positions.size());
                    double lo0 = 1e30, lo1 = 1e30, lo2 = 1e30;
                    double hi0 = -1e30, hi1 = -1e30, hi2 = -1e30;
                    for (size_t f = 0; f < ntri; ++f) {
                        for (int k = 0; k < 3; ++k) {
                            const int vi = its.indices[f][k];
                            if (vi < 0 || static_cast<size_t>(vi) >= its.vertices.size())
                                continue;
                            const Vec3d w = m * its.vertices[static_cast<size_t>(vi)].cast<double>();
                            out_positions.push_back(static_cast<float>(w.x()));
                            out_positions.push_back(static_cast<float>(w.y()));
                            out_positions.push_back(static_cast<float>(w.z()));
                            lo0 = std::min(lo0, w.x()); hi0 = std::max(hi0, w.x());
                            lo1 = std::min(lo1, w.y()); hi1 = std::max(hi1, w.y());
                            lo2 = std::min(lo2, w.z()); hi2 = std::max(hi2, w.z());
                        }
                    }
                    if (out_positions.size() == static_cast<size_t>(vert_off)) {
                        continue;
                    }
                    import_trace(path, "entry ext=" + std::to_string(ext) +
                                       " bbox=" + std::to_string(lo0) + "," + std::to_string(lo1) + "," +
                                       std::to_string(lo2) + ".." + std::to_string(hi0) + "," +
                                       std::to_string(hi1) + "," + std::to_string(hi2) +
                                       " size=" + std::to_string(hi0 - lo0) + "x" +
                                       std::to_string(hi1 - lo1) + "x" + std::to_string(hi2 - lo2));

                    const Vec3d off = inst->get_offset();
                    nlohmann::json e;
                    e["name"]      = multi_ext ? (mo->name + " · 耗材" + std::to_string(ext)) : mo->name;
                    e["triangles"] = static_cast<long long>(ntri);
                    e["offset"]    = nlohmann::json::array({ off.x(), off.y(), off.z() });
                    e["bbox"]      = nlohmann::json::array({ lo0, lo1, lo2, hi0, hi1, hi2 });
                    e["size"]      = nlohmann::json::array({ hi0 - lo0, hi1 - lo1, hi2 - lo2 });
                    e["vertOffset"] = vert_off;
                    e["vertCount"]  = static_cast<long long>(out_positions.size()) - vert_off;
                    e["plate"]      = 0;
                    // 「对象颜色 → 耗材槽位」回读：对象用的耗材/挤出机序号（1 基）。
                    // 写盘时我们把每个对象的 extruder 写进 model_settings.config，这里原样读回，
                    // ArkTS 侧据「序号 → filament_colour」还原对象显示色（多色工程存盘再打开颜色还在）。
                    e["extruder"] = ext;
                    objects.push_back(e);
                    entry_obj.push_back(static_cast<int>(oi));
                    entry_inst.push_back(static_cast<int>(ii));
                }
            }
        }

        // ---- 盘：来自内核加载器的 PlateData（Metadata/model_settings.config 的 <plate>）----
        //
        // 关键：加载路径上内核只填了 PlateData::obj_inst_map（文件 object_id → (实例下标, identify_id)），
        // 而 objects_and_instances 是空的（它只在切片/导出构造 PlateData 时才有值）。
        // 内核同时把 identify_id 写进了对应 ModelInstance::loaded_id，所以这里先用 loaded_id
        // 反查「(对象下标, 实例下标)」，再与导出的 entry 对齐。
        std::map<size_t, std::pair<int, int>> ident_to_objinst;
        for (size_t oi = 0; oi < model.objects.size(); ++oi) {
            ModelObject* mo2 = model.objects[oi];
            if (mo2 == nullptr)
                continue;
            for (size_t ii = 0; ii < mo2->instances.size(); ++ii) {
                if (mo2->instances[ii] != nullptr)
                    ident_to_objinst[mo2->instances[ii]->loaded_id] =
                        std::make_pair(static_cast<int>(oi), static_cast<int>(ii));
            }
        }

        nlohmann::json plates = nlohmann::json::array();
        import_trace(path, "plates_start n=" + std::to_string(plate_list.size()));
        for (PlateData* pd : plate_list) {
            if (pd == nullptr)
                continue;
            nlohmann::json p;
            p["id"]   = pd->plate_index + 1;
            p["name"] = pd->plate_name;
            std::string bed = enum_name_of(pd->config, "curr_bed_type");
            if (bed.empty())
                bed = enum_name_of(config, "curr_bed_type");
            p["bed"] = bed;

            nlohmann::json objs = nlohmann::json::array();
            for (const auto& kv : pd->obj_inst_map) {
                const auto it2 = ident_to_objinst.find(static_cast<size_t>(kv.second.second));
                if (it2 == ident_to_objinst.end())
                    continue;
                const int oi = it2->second.first;
                const int ii = it2->second.second;
                for (size_t e = 0; e < entry_obj.size(); ++e) {
                    if (entry_obj[e] == oi && entry_inst[e] == ii) {
                        objs.push_back(static_cast<long long>(e));
                        break;
                    }
                }
            }
            p["objects"] = objs;
            plates.push_back(p);
        }
        // 无盘信息但有网格：合成单盘，保证 UI 至少能显示「1 个盘」
        if (plates.empty() && !objects.empty()) {
            nlohmann::json p;
            p["id"]   = 1;
            p["name"] = "";
            p["bed"]  = enum_name_of(config, "curr_bed_type");
            nlohmann::json objs = nlohmann::json::array();
            for (size_t e = 0; e < objects.size(); ++e)
                objs.push_back(static_cast<long long>(e));
            p["objects"] = objs;
            plates.push_back(p);
        }
        // 把盘归属写回每个对象 entry（UI 单盘也能正确分组/过滤）
        for (const nlohmann::json& p : plates) {
            const int pid = p.value("id", 0);
            for (const nlohmann::json& e : p["objects"]) {
                const size_t idx = static_cast<size_t>(e.get<long long>());
                if (idx < objects.size())
                    objects[idx]["plate"] = pid;
            }
        }
        // 兜底：工程里没有 identify_id 时（obj_inst_map 的 identify 全为 0）映射可能整体落空，
        // 此时把全部对象归到第一个盘，保证「有几个盘、盘里有东西」这条信息不丢。
        {
            bool any_placed = false;
            for (const nlohmann::json& e : objects)
                if (e.value("plate", 0) > 0)
                    any_placed = true;
            if (!any_placed && !objects.empty() && !plates.empty()) {
                const int pid = plates[0].value("id", 1);
                for (nlohmann::json& e : objects)
                    e["plate"] = pid;
                nlohmann::json objs = nlohmann::json::array();
                for (size_t e = 0; e < objects.size(); ++e)
                    objs.push_back(static_cast<long long>(e));
                plates[0]["objects"] = objs;
                out["plateMapFallback"] = true;
            }
        }

        out["objects"]  = objects;
        out["plates"]   = plates;
        out["hasModel"] = !objects.empty();
        out["ok"]       = true;
        out["message"]  = objects.empty() ? "文件不含模型（无网格），仅读取到设置" : "";

        release_PlateData_list(plate_list);
        import_trace(path, "done objects=" + std::to_string(objects.size()) +
                           " plates=" + std::to_string(plates.size()) +
                           " floats=" + std::to_string(out_positions.size()));
        return out.dump();
    } catch (const std::exception& e) {
        release_PlateData_list(plate_list);
        import_trace(path, std::string("exception ") + e.what());
        out["ok"]      = false;
        out["message"] = std::string("3MF 导入异常: ") + e.what();
        return out.dump();
    } catch (...) {
        release_PlateData_list(plate_list);
        import_trace(path, "exception unknown");
        out["ok"]      = false;
        out["message"] = "3MF 导入异常: 未知错误";
        return out.dump();
    }
}

std::string slicer_mesh_boolean(const std::vector<float>& a_positions,
                                const std::vector<uint32_t>& a_indices,
                                const std::vector<float>& b_positions,
                                const std::vector<uint32_t>& b_indices,
                                const std::string& op,
                                std::vector<float>& out_positions,
                                std::vector<uint32_t>& out_indices)
{
    nlohmann::json out;
    out["ok"]        = false;
    out["triangles"] = 0;
    out["parts"]     = 0;
    out["message"]   = "";
    out_positions.clear();
    out_indices.clear();

    auto build_mesh = [](const std::vector<float>& pos, const std::vector<uint32_t>& idx,
                         TriangleMesh& mesh) -> bool {
        if (pos.size() < 9 || idx.size() < 3 || (pos.size() % 3) != 0 || (idx.size() % 3) != 0)
            return false;
        const size_t vcount = pos.size() / 3;
        indexed_triangle_set its;
        its.vertices.reserve(vcount);
        for (size_t i = 0; i < vcount; ++i)
            its.vertices.emplace_back(pos[3 * i], pos[3 * i + 1], pos[3 * i + 2]);
        its.indices.reserve(idx.size() / 3);
        for (size_t i = 0; i < idx.size(); i += 3) {
            if (idx[i] >= vcount || idx[i + 1] >= vcount || idx[i + 2] >= vcount)
                return false;
            its.indices.emplace_back(static_cast<int>(idx[i]), static_cast<int>(idx[i + 1]),
                                     static_cast<int>(idx[i + 2]));
        }
        mesh.its = std::move(its);
        // 关键：3MF 导入的网格常是「每个三角形各带 3 个独立顶点」的面汤形态，
        // 未焊接时 MCUT 的拓扑构建会退化（实测真机卡死 17s+ 不返回）。
        // 先按坐标合并重复顶点，再做布尔。
        its_merge_vertices(mesh.its, true);
        its_compactify_vertices(mesh.its, true);
        return !mesh.its.indices.empty();
    };

    try {
        TriangleMesh a, b;
        const bool ok_a = build_mesh(a_positions, a_indices, a);
        const bool ok_b = build_mesh(b_positions, b_indices, b);
        if (!ok_a || !ok_b) {
            char buf[256];
            snprintf(buf, sizeof(buf),
                     "布尔运算的输入网格无效 a(ok=%d pos=%d idx=%d) b(ok=%d pos=%d idx=%d)",
                     ok_a ? 1 : 0, static_cast<int>(a_positions.size()),
                     static_cast<int>(a_indices.size()),
                     ok_b ? 1 : 0, static_cast<int>(b_positions.size()),
                     static_cast<int>(b_indices.size()));
            out["message"] = std::string(buf);
            return out.dump();
        }
        // 走 CGAL 布尔（cgal::plus/minus/intersect）而不是 ModelObject::make_boolean(mcut)：
        // mcut 是为「切割」写的，对「两实体仅相切/轻微相交」或输入未完美焊接时容易退化成
        // 合并兜底（结果=两份原网格拼接，面数 = A+B），实测还会产生巨大退化三角形
        //（真机表现为模型只剩一条碎片 + 包围盒超界 119mm）。
        //
        // 注意必须用「CGALMeshPtr triangle_mesh_to_cgal(const TriangleMesh&)」那一版转换：
        // 它内部做 orient_polygon_soup + orient_to_bound_a_volume（修绕序/统一朝外），
        // 而 TriangleMesh& 版只是原样塞顶点，绕序不一致时 CGAL 会**静默**产出碎渣
        //（实测：两个 2112 面的盒体并集 → 碎成 13 块、只剩 515/289/32… 面）。
        MeshBoolean::cgal::CGALMeshPtr ma = MeshBoolean::cgal::triangle_mesh_to_cgal(a);
        MeshBoolean::cgal::CGALMeshPtr mb = MeshBoolean::cgal::triangle_mesh_to_cgal(b);
        if (op == "union") {
            MeshBoolean::cgal::plus(*ma, *mb);
        } else if (op == "intersection") {
            MeshBoolean::cgal::intersect(*ma, *mb);
        } else {
            MeshBoolean::cgal::minus(*ma, *mb);
        }
        TriangleMesh res = MeshBoolean::cgal::cgal_to_triangle_mesh(*ma);
        if (res.its.indices.empty()) {
            out["message"] = op == "intersection"
                ? "布尔结果为空（两个对象可能没有相交）"
                : "布尔运算失败（结果网格为空，网格可能非流形）";
            return out.dump();
        }
        its_merge_vertices(res.its, true);
        its_compactify_vertices(res.its, true);
        // 统计部件数（分离壳体）：结果可能由多块组成（如差集把对象切断）
        int parts = static_cast<int>(res.split().size());
        for (const stl_vertex& p : res.its.vertices) {
            out_positions.push_back(p.x());
            out_positions.push_back(p.y());
            out_positions.push_back(p.z());
        }
        for (const stl_triangle_vertex_indices& t : res.its.indices) {
            out_indices.push_back(static_cast<uint32_t>(t(0)));
            out_indices.push_back(static_cast<uint32_t>(t(1)));
            out_indices.push_back(static_cast<uint32_t>(t(2)));
        }
        out["ok"]        = true;
        out["triangles"] = static_cast<long long>(out_indices.size() / 3);
        out["vertices"]  = static_cast<long long>(out_positions.size() / 3);
        out["parts"]     = parts;
        return out.dump();
    } catch (const std::exception& e) {
        out["message"] = std::string("布尔运算异常: ") + e.what();
        return out.dump();
    } catch (...) {
        out["message"] = "布尔运算异常: 未知错误";
        return out.dump();
    }
}

} // namespace ohos
} // namespace Slic3r
