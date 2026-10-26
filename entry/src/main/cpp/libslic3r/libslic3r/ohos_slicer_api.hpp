#ifndef slic3r_ohos_slicer_api_hpp_
#define slic3r_ohos_slicer_api_hpp_

#include <functional>
#include <string>
#include <vector>

// =============================================================================
//  OpenHarmony(HarmonyOS) 切片内核对外 API
//
//  这是给 NAPI 桥接层（entry/src/main/cpp/napi_init.cpp）调用的最小接口。
//  刻意只依赖 <string>，这样 ArkTS 侧的 C++ 文件可以直接 include 本头，
//  而不用把 libslic3r 的一整套头文件依赖（Boost/CGAL/Eigen/OCCT...）拖进来。
//
//  实现位于 libslic3r/libslic3r/ohos_slicer_api.cpp，编进 liblibslic3r.a。
// =============================================================================

namespace Slic3r {
namespace ohos {

// 切片内核版本（= SLIC3R_VERSION，例如 "02.08.02.61"）。
// 用于和桌面版 Bambu Studio 对齐校验：3MF 元数据/G-code 头里的版本号必须是这个值。
std::string slicer_version();

// =============================================================================
//  导入阶段 trace（诊断用）
//
//  3MF 导入跑在 worker 线程上，崩溃时 hilog 什么都留不下。这里提供一个「阶段落盘」通道：
//  set_import_trace_base(路径) 之后，内核加载器每完成一个阶段就往 <路径>.trace 追加一行
//  （每次 append 立即 flush，崩溃后也能看到最后完成的阶段）。
//  未设置 base 时所有调用都是空操作，零成本。
// =============================================================================
void set_import_trace_base(const std::string& base);
void import_trace_stage(const std::string& stage);

// =============================================================================
//  「多色按 part 拆成多个对象」时的首层豁免
//
//  我们的数据模型是「对象 = 一个耗材/显示色」，所以多色工程里同一件的多个 part 会各自成为
//  一个独立对象（上层 part 的起始 z > 0，压在底层 part 上）。内核 GCode.cpp 有一条检查：
//  「对象第 0 层没有挤出 → 视为浮空件 → 抛 empty initial layer」。上层 part 必然触发它，
//  但这并不是浮空：它下面有另一个 part 支撑。
//
//  切片入口在多耗材请求（槽位数 > 1）时打开这个开关，让 GCode.cpp 跳过该抛错
//  （同时不把「首层到首个挤出层之间的空层」记为 CRITICAL 警告）。
//  复位由入口自己负责：每次切片开始时先清、导出完成后清。
// =============================================================================
void set_allow_empty_initial_layer(bool on);
bool allow_empty_initial_layer();

// 执行一次完整切片。
//
//   input_path  : 输入模型路径，支持 .stl / .3mf / .obj / .step / .stp
//   params_json : 覆盖默认配置的扁平 JSON，例
//                   {"layer_height":0.2,"wall_loops":2,"sparse_infill_density":15,"enable_support":false}
//                 * key 必须是内核已知的配置项（见 PrintConfig 的选项表），未知 key 会被忽略并上报
//                 * 枚举类选项传整数下标（与 ArkTS 动态表单的 value 一致）
//                 * 布尔传 true/false，数值传 number，字符串选项传 string
//                 3MF 内嵌的工程配置会先覆盖默认值，params_json 最后叠加（UI 优先）。
//   output_path : 输出 .gcode 路径（父目录必须已存在）
//
// 返回一个 JSON 对象字符串（成功）：
//   {"ok":true,"status":"done","output":"<实际写入路径>",
//    "layers":123,"timeSeconds":12.3,
//    "filamentUsedMm":1234.5,"filamentUsedG":3.7,
//    "estimatedPrintTime":"1h 2m 3s",
//    "skippedParams":["foo(未知)"]}
// 失败：
//   {"ok":false,"status":"error","message":"..."}
std::string slicer_slice(const std::string& input_path,
                         const std::string& params_json,
                         const std::string& output_path);

// 切片进度回调：在切片 worker 线程上被调用。
//   stage : 阶段下标 0=装载模型 1=贴板居中 2=合并配置 3=分层与路径 4=导出 G-code
//           （5=生成预览由 ArkTS 侧驱动，内核不报）
//   pct   : 该阶段内百分比 0..100（全局百分比由 ArkTS 侧按阶段权重合成，与导入弹窗同一套）
//   msg   : 这一条进度的可读文案（真实数据，不编造）
using SliceProgressFn = std::function<void(int stage, int pct, const std::string& msg)>;

// 带进度的切片：语义与 slicer_slice 完全一致（同一份实现），只是额外上报进度。
// progress 为空时等价于 slicer_slice（不注册任何内核回调）。
//
// 进度来源全部是 libslic3r 里真实存在的钩子：
//   * 阶段 0/1/2 无细粒度钩子 -> 只报进入/完成，并把真实数字写进消息
//     （对象数、三角面、包围盒、板尺寸、层高、层数…）；
//   * 阶段 3（print.process()）与阶段 4（print.export_gcode()）复用内核自带的
//     PrintBase::set_status_callback —— process 期间是子步骤级（percent + 文案），
//     export 期间是按层的 "Generating G-code: layer N"，可给出真实层号。
std::string slicer_slice_with_progress(const std::string& input_path,
                                       const std::string& params_json,
                                       const std::string& output_path,
                                       const SliceProgressFn& progress);

// =============================================================================
//  预设（BambuStudio 官方 PresetBundle 路径）
//
//  预设文件是 rawfile 里的 bambu_res.zip（BBL 官方 profile 全量：machine 162 /
//  process 278 / filament 2056，外加 info/、flush/、filament_mixing/），
//  App 侧用 @ohos.zlib 解压到 <files_dir>/bambu_res，再把 files_dir 传进来。
//
//  走 preset 而不是 DynamicPrintConfig::full_print_config()，是因为只有官方预设
//  才带对了机型/喷嘴/耗材/工艺参数——这是切片结果能对齐桌面版的前提。
// =============================================================================

// 初始化预设库（App 启动或首次切片前调一次）。
//
//   files_dir      : App 的 filesDir（解压目录 <files_dir>/bambu_res 与 data_dir 都在这里）
//   preset_zip     : rawfile 里 bambu_res.zip 的字节；传 nullptr 表示已经解压好了，直接加载
//   preset_zip_size: 上面那份数据的大小
//
// 首次调用会把 zip 解到 <files_dir>/bambu_res（用 miniz，纯内存 → 文件，不落 zip 到磁盘），
// 之后靠 <files_dir>/bambu_res/.zip_size 标记跳过重复解压；重复调用只会重新加载预设。
//
// 返回：{"ok":true,"selected":{"printer":..,"process":..,"filament":..},
//        "printers":[..],"processes":[..],"filaments":[..]}
// 失败：{"ok":false,"message":"..."}
std::string slicer_init_presets(const std::string& files_dir,
                                const void*        preset_zip,
                                size_t             preset_zip_size);

// 切换预设。空字符串 = 保持当前选择（**不调用内核**，见下）。
//
// 关键语义（与"界面 == 内核"直接相关）：
//   * 空请求名一律跳过：C++ 层对空串**不调用内核**。因为内核 select_preset_by_name 在名字
//     不可用时会静默退回"第一个可见预设"（print 里是 "0.06mm Fine @BBL A1 0.2 nozzle"，
//     层高 0.06），透传空串会引发一次无请求的乱换。
//   * 非空的请求名必须在内核里"存在且可见"（与内核 select_preset_by_name 的可用性口径一致），
//     否则**整体不改动**并返回 ok:false。
//   * 下发后立即**回读比对**：任一非空请求与内核回读的 selected 不一致（工艺/耗材/机型都算），
//     说明内核没真正认下它（已退回第一个可见预设）。此时**回滚到切换前的预设**（内核侧按名字
//     选回，保证内核绝不滞留在 0.06 那种被回退后的状态），返回 ok:false 且 rolledBack:true。
//   * 返回里如实给出 requested（请求名）/ selected（内核当前真实选中）/ rolledBackTo（回滚目标，
//     未回滚时为切换前快照）/ layerHeight（回读的层高），ArkTS 用它们打对照日志。
//
// 返回：{"ok":true,"requested":{...},"selected":{"printer":..,"process":..,"filament":..},
//        "rolledBack":false,"rolledBackTo":{...},"layerHeight":0.2}
// 失败：{"ok":false,"message":"...","requested":{...},"selected":{...},
//        "rolledBack":true|false,"rolledBackTo":{...},"notFound":["..."],"layerHeight":0.06}
std::string slicer_select_presets(const std::string& printer,
                                  const std::string& process,
                                  const std::string& filament);

// 枚举"可被选中"的预设候选表 —— 界面下拉必须原样用这份列表，选择时回传其中的下标。
//
//   kind: 0=printer / 1=process / 2=filament
//
// 为什么要有这个接口（根治"界面名字 ↔ 内核名字对不上 → 内核静默回退 → 层高变成 0.18/0.28/0.3"
// 这一类反复出现的问题）：
//   * 返回的是**内核自己认为可选中的那一组**：printer 是全部可见机型；process/filament 是
//     当前选中打印机下、由内核 is_compatible_with_printer 判定兼容的子集（与
//     slicer_presets_for_printer 同一套口径）。
//   * **机型一律取内核"当前选中"的那一台，不接受任何外部传入的名字**，所以候选列表和内核当前
//     机型永远同源，不可能出现"拿上一台机器的列表去下发"。
//   * 列表顺序 = 内核集合顺序，界面不得重排 —— 界面回传的下标就是这里的下标。
//   * 每条含展示用的只读信息（layer_height / nozzle）。
//
// 返回：{"ok":true,"kind":1,"printer":"<当前机型>","items":[{"name":"...","layerHeight":0.2,"nozzle":0.4},...],
//        "selectedIndex":3,"selectedName":"...","notes":"..."}
// 失败：{"ok":false,"message":"..."}
std::string slicer_preset_options(int kind);

// 按索引选择预设（kind 同上）。索引的语义 = slicer_preset_options(kind) 返回的 items 下标。
//
// 语义（与 slicer_select_presets 的"预检 + 回读 + 回滚"完全一致，只是输入从名字换成下标）：
//   * 先把 index 用内核自己的候选表解析成名字（唯一权威的 index->name 映射）；
//   * index 越界 / kind 非法 / 候选表不可用 -> 一律 **no-op**（不碰内核），如实回报当前选中项；
//   * 下发后立即**回读比对**：回读与"请求索引对应的项"不一致，说明内核没真正认下它，
//     此时**回滚到切换前的打印机/工艺/耗材三个预设**，返回 ok:false 且 rolledBack:true。
//
// 返回：{"ok":true,"kind":1,"index":3,"requestedName":"...","requested":{...},
//        "selected":{"printer":..,"process":..,"filament":..},"rolledBack":false,
//        "rolledBackTo":{...},"layerHeight":0.2}
// 失败：{"ok":false,"message":"...","selected":{...},"rolledBack":true|false,"rolledBackTo":{...},
//        "layerHeight":...}
std::string slicer_select_preset_by_index(int kind, int index);

// 当前打印机预设的真实打印板。
//
// 为什么需要：打印板尺寸必须来自**当前选中的打印机预设**。之前 ArkTS 侧用一份硬编码
// 机型表兜底（A1 mini/H2D/H2S 之外一律 256×256），A2L 不在表里 -> 换到 A2L 后打印板
// 仍是 A1/X1C 的 256×256。这里直接从打印机预设的 printable_area / printable_height 取真值。
//
// 兼容两种 printable_area 写法：桌面旧数据的 "x0xy0 x1xy1 ..." 字符串数组、新数据的
// [[x,y],...]（内核统一解析成 ConfigOptionPoints，这里直接读点列表，两种形态通吃）。
//
// 返回：{"ok":true,"printer":"...","area":[[x0,y0],[x1,y1],...],"height":250.0,
//        "bbox":[minX,minY,maxX,maxY]}
// 失败：{"ok":false,"message":"..."}
std::string slicer_printer_bed();

// 查询「某台打印机」真正兼容的工艺 / 耗材预设名。
//
//   printer_preset_name: 打印机预设全名（如 "Bambu Lab X1 Carbon 0.4 nozzle"）；
//                        传空串或名字不存在时退回「当前选中的打印机」。
//
// 之所以要有这个接口：UI 侧原来按预设名的 " @BBL <code>" 后缀猜兼容性 —— 那是命名约定，
// 不是内核真正的判断，且猜不到时会退回旧列表（换机型后下拉尾部仍是上一台机器的预设）。
// 这里直接用内核元数据判断：预设自带 compatible_printers（精确机型名列表）与
// compatible_printers_condition（布尔表达式），内核函数 is_compatible_with_printer()
// 会优先按列表精确匹配、否则用 PlaceholderParser 求值表达式（求值器在 libslic3r 内，
// 不依赖 GUI），所以结果就是内核权威的兼容集合。
//
// 返回 JSON：
//   {"ok":true,"printer":"<归一化后的机型名>",
//    "processes":[...],"filaments":[...],"notes":"<判断依据说明>"}
// 失败：{"ok":false,"message":"..."}（列表为空是合法结果，表示该机型确实没有兼容预设）
std::string slicer_presets_for_printer(const std::string& printer_preset_name);

// 当前预设合成出的配置快照，供动态表单取初值。
// {"layer_height":0.2,"wall_loops":2,"enable_support":false,"seam_position":0, ...}
// 数值/布尔/字符串按真实类型给；枚举给内核下标；向量型选项不返回。
// 预设未初始化时返回空对象。
std::string slicer_config_snapshot();

// 当前**被编辑的耗材预设**的键值快照 —— 耗材编辑弹窗取初值用。
//
// 与 slicer_config_snapshot 的唯一区别：**向量型选项按数组原样返回**。
// 耗材的打印板温度（hot_plate_temp / hot_plate_temp_initial_layer …）、喷嘴温度、
// 风扇、回抽等关键项在内核里都是数组（按耗材/喷嘴分档），压成第一档会丢档，
// 编辑器无法按拓竹的口径如实显示与回写。
//
// 返回：{"ok":true,"name":"<耗材预设名>","printer":"<机型预设名>",
//        "values":{"filament_type":"PLA","filament_density":1.26,"hot_plate_temp":[65], ...}}
// 失败：{"ok":false,"message":"..."}
std::string slicer_filament_snapshot();

// 枚举型选项的内核权威取值表（顺序 = 内核 enum 下标顺序）。
// {"seam_position":["nearest","aligned","rear","random"], ...}
// 动态表单的枚举下拉必须用这份顺序，下标才能和内核对上。
std::string slicer_enum_values();

// 全部配置项的**定义元信息**导出（直接来自内核 PrintConfigDef）。
// {"layer_height":{"type":1,"vector":false,"label":"Layer height","tooltip":"...",
//                  "unit":"mm","category":"Quality","mode":0,"readonly":false,
//                  "min":0.0,"max":100.0,"enum_values":[...],"enum_labels":[...]}, ...}
//
// 用途：本地手写的中文元信息表只手写了 244 项，而内核实际有 700+ 项；缺的部分过去
// 在 BuildSchemaJson 里被直接丢弃（快照有、表里没有 → continue），于是「内核有、界面没有」
// 的参数既看不见也改不了。这里把内核自己的定义原样导出，由 BuildSchemaJson 做
// 「手写中文优先、内核定义兜底」的合并 —— 内核升级后自动跟上，不需要维护一份会过期的生成文件。
//   * type 已剥掉 coVectorType 位（1=Float 2=Int 3=String 4=Percent 5=FloatOrPercent
//     6=Point 7=Point3 8=Bool 9=Enum 10=PointsGroups 11=IntsGroups），vector 单列一个布尔；
//   * min/max 只在**内核显式声明过**时出现（否则缺省是 ±DBL_MAX，视为「未声明范围」）；
//   * mode: 0=comSimple 1=comAdvanced 2=comDevelop。
std::string slicer_config_defs();

// 导出「项目 3MF」（含完整切片设置，拓竹原生工程格式）。
//
//   input_path  : 待导出模型路径（.stl/.3mf/.obj/.step），通常是我们「通用 3MF」先落盘的临时工程
//   params_json : 与切片同一份扁平参数 JSON（UI 当前动态表单值），最后叠加到预设配置之上
//   output_path : 输出 .3mf 路径（父目录必须已存在）
//
// 写文件的是内核自带的拓竹原生 3MF 导出器（Format/bbs_3mf.cpp 的 store_bbs_3mf），
// 所以产出与 Bambu Studio 的「保存项目」一致：Metadata/project_settings.config（机型/工艺/
// 耗材预设 + 全部切片参数 + 打印板）、Metadata/model_settings.config（对象/摆放/盘）、
// Metadata/slice_info.config、[Content_Types].xml、_rels/.rels 等一应俱全，可被拓竹与我们完整还原。
//
// 返回（成功）：
//   {"ok":true,"path":"<实际写入路径>","objects":N,"facets":M,
//    "bbox":[minX,minY,minZ,maxX,maxY,maxZ],
//    "roundTrip":{"ok":true,"objects":n,"facets":m,"bbox":[...]}}
//   roundTrip 是导出后立刻用内核 load_bbs_3mf 读回的实测数据（对象数/面数/包围盒），
//   用于自证「写出去的文件能被原样读回」。若读回抛异常，roundTrip.ok=false 并给出 message，
//   但导出本身仍算成功（roundTrip 只是自证，不阻断）。
// 失败：{"ok":false,"message":"..."}
std::string slicer_export_project_3mf(const std::string& input_path,
                                      const std::string& params_json,
                                      const std::string& output_path);

// 导出「含 gcode 的 .gcode.3mf」—— 与 slicer_export_project_3mf 同一条 store_bbs_3mf 链路，
// 额外把 gcode_path 指定的文件作为 Metadata/plate_1.gcode（含内核算出的 .md5）打进包，
// 产出一份打印机可直接打印的工程包（真打印前提：包内必须有 Metadata/plate_1.gcode）。
//
//   gcode_path : 已切好的 .gcode 文件绝对路径（如 filesDir/output.gcode）。必须存在。
// 字段依据：SaveStrategy::WithGcode（bbs_3mf.hpp:168）+ plate_data->gcode_file / is_sliced_valid
// （bbs_3mf.cpp:6777 / 8894）。带 gcode 时内部会去掉 SkipStatic —— 否则 gcode 会被内核跳过。
//
// 返回：在 slicer_export_project_3mf 的返回基础上增加
//   "withGcode":true、"gcode":"<源路径>"、"gcodeMd5":"<内核算出的 md5, 大写>"。
// 失败：{"ok":false,"message":"..."}（含 gcode 文件不存在的情况）。
std::string slicer_export_gcode_3mf(const std::string& input_path,
                                    const std::string& params_json,
                                    const std::string& output_path,
                                    const std::string& gcode_path);

// 导入 3MF（几何 + 设置 + 盘，一次拿全）—— 复用内核自带的 BBL 3MF 加载器
// （load_model_file() -> Model::read_from_file -> load_bbs_3mf），**不自己解析 XML**。
//
//   path          : 待导入的 .3mf 文件路径
//   out_positions : 输出 —— 每个对象的三角面顶点，Float32 **三角汤（非索引）**，Z 轴向上，
//                   依次拼接（对象 i 占 [objects[i].vertOffset, +objects[i].vertCount)）。
//
// 为什么几何用二进制数组而不是塞进 JSON：大模型顶点是几十万～上千万个 float，拼成 JSON 字符串
// 会把 JS 堆撑爆（任务明确要求不得用巨量 JSON 传顶点）。JSON 里只放元数据（名字/面数/摆放/包围盒/
// 顶点区间/盘归属），顶点走 ArrayBuffer。
//
// 返回 JSON：
//   {"ok":true,"hasModel":true|false,"message":"",
//    "presets":{"printer":"..","process":"..","filament":"..","bed":"Cool Plate"},
//    "layerHeight":0.24,"wallLoops":6,"initialLayerSpeed":75,
//    "settingKeys":["layer_height",...],"settingValues":[0.24,...],
//        // project_settings.config 的全量扁平化：枚举发内核下标、布尔发 true/false、向量发首档；
//        // 拆成两个平行数组是为了 ArkTS 侧能静态类型解析（不用 Record / any）
//    "bed":{"minX":0,"minY":0,"w":256,"h":256},   // 仅有 printable_area 时给出
//    "objects":[{"name":"零件001","triangles":2112,"offset":[x,y,z],
//                "bbox":[minX,minY,minZ,maxX,maxY,maxZ],"size":[sx,sy,sz],
//                "vertOffset":0,"vertCount":19008,"plate":1}],
//    "plates":[{"id":1,"name":"","bed":"Cool Plate","objects":[0]}]}
// 失败：{"ok":false,"hasModel":false,"message":"..."}
//
// 健壮性：包内没有网格的 3MF（如切片产出的 .gcode.3mf）→ objects 为空、hasModel=false，
// 但设置（presets/settingKeys）照常返回，UI 据此提示「该文件不含模型，仅读取设置」。
std::string slicer_import_3mf(const std::string& path, std::vector<float>& out_positions);

// 对象级布尔：A 与 B 都是索引网格（顶点 XYZ 扁平 + 三角形索引）。
//   op: "union" | "difference" | "intersection"
// 成功：{"ok":true,"triangles":N,"parts":M,"message":""}，结果几何写入 out_positions / out_indices。
// 失败：{"ok":false,"message":"..."}（空结果也按失败处理，避免把对象变成空壳）。
std::string slicer_mesh_boolean(const std::vector<float>& a_positions,
                                const std::vector<uint32_t>& a_indices,
                                const std::vector<float>& b_positions,
                                const std::vector<uint32_t>& b_indices,
                                const std::string& op,
                                std::vector<float>& out_positions,
                                std::vector<uint32_t>& out_indices);

} // namespace ohos
} // namespace Slic3r

#endif // slic3r_ohos_slicer_api_hpp_
