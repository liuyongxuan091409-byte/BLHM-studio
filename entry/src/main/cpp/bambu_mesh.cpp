#include "bambu_mesh.hpp"
#include "bambu_mqtt.hpp"
#include "bambu_step.hpp"
#include "bambu_bed_data.hpp"
#include "bambu_bed_models.hpp"
#include "bambu_logo_data.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <unordered_map>

#include <hilog/log.h>

// =============================================================================
// 逐跳插桩（诊断「载入卡在法线完成」）：把「法线循环结束 → parseFile 返回」这段
// 每一跳各打一条 hilog（tag 固定为 LoadDlg，前缀 hopN，带进程内单调毫秒 t=）。
// steady_clock 的时间戳在进程内跨线程 / 跨 TU 一致，可直接用来比顺序与时间差。
static long long LoadDlgNowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

// 统一日志前缀：「hopN <label> t=<ms>」，后半段由调用方用 %{public}s 拼接
static std::string LoadDlgStamp(const char* hop, const char* label)
{
    return std::string("hop") + hop + " " + label + " t=" + std::to_string(LoadDlgNowMs());
}

// =============================================================================
// 纯网格解析：STL(二进制/ASCII) + OBJ。
// 从渲染模块剥离出来 —— 3D 预览页(ArkGraphics3D)与准备页(XComponent 渲染)共用。
// 解析完成后统一归一化：XY 居中、底面贴板（Z 轴向上约定）。
// =============================================================================

// 预览三角面预算（仅用于 3D 预览的兜底抽稀，与切片无关；切片永远使用原始文件）。
// 焊接索引化后内存占用约为面汤的 1/6，预算因此大幅提高；只有超大模型才走聚类简化（质量损失大）。
static const int kPreviewMaxTriangles = 5000000;

// 折痕角：相邻面夹角超过它就必须保留硬边（不参与彼此的法线平均）。
// 倒角/平面的硬转折通常 30°~90°，取 30° 可保住倒角；光滑曲面相邻面通常 <10°，仍会平滑。
static const float kCreaseAngleCos = 0.866f;   // cos(30°)

// ---- 需求 4：悬空/支撑启发式判定的两个阈值常量（改这里即可调节）---------------------------
// 判定为「朝下悬空面」的条件：面法线指向下方，且与「竖直向下」的夹角 <= kOverhangAngleDeg。
// 等价写法：nz <= -cos(kOverhangAngleDeg)（nz 为面法线的 Z 分量，世界系 Z 向上）。
// 取 60°：放宽以「提高可触发率」（角阈值越大，越多朝下但略斜的面被计入悬空）。
// 60° 相当于 nz <= -0.5；桌上常见 45°~60° 悬垂阈值里偏宽松的一档。
// 【如实说明】这是启发式统计，不是切片器级别的逐层悬空分析：不看桥接、不看逐层支撑、
// 不做自交/薄壁判断，只用来「提醒用户检查」，不能替代切片结果。
static const float kOverhangAngleDeg = 60.0f;
// 朝下悬空面面积占比超过该百分比 → 判定「需要支撑」（单位 %）。
// 由 8% 放宽到 3%：原阈值下多数模型的朝下面占比都在 8% 以下，告警几乎不触发（=用户反馈的「没效果」）。
static const float kOverhangAreaRatioPct = 3.0f;
// 贴板底面阈值（mm）：三个顶点都低于该高度的朝下面视为「贴在板上的底面」，不计入悬空。
// 为什么必须排除：平底模型的底面朝下但不需要支撑，不排除会让几乎每个模型都提示需支撑。
static const float kBedContactZ = 0.2f;

namespace BambuMesh {

namespace {

// ---- 进度上报小工具（消息里的数字全部来自真实计数，不编造） --------------------

// 千分位：3000000 -> "3,000,000"
std::string fmtCount(long long v)
{
    bool neg = v < 0;
    unsigned long long u = neg ? static_cast<unsigned long long>(-v) : static_cast<unsigned long long>(v);
    std::string s = std::to_string(u);
    for (int i = static_cast<int>(s.size()) - 3; i > 0; i -= 3) { s.insert(static_cast<size_t>(i), ","); }
    return neg ? ("-" + s) : s;
}

// 字节数 -> "83.9 MB" / "812 KB"
std::string fmtSize(long long bytes)
{
    char buf[48];
    if (bytes >= 1024ll * 1024ll) {
        snprintf(buf, sizeof(buf), "%.1f MB", static_cast<double>(bytes) / (1024.0 * 1024.0));
    } else {
        snprintf(buf, sizeof(buf), "%.0f KB", static_cast<double>(bytes) / 1024.0);
    }
    return std::string(buf);
}

// 一位小数的百分比："83.5"
std::string fmtPct1(double v)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%.1f", v);
    return std::string(buf);
}

// 统一出口：progress 为空时什么都不做（保证不传回调的旧调用路径行为完全一致）
inline void report(const MeshProgressFn& p, int stage, int pct, const std::string& msg)
{
    if (p) { p(stage, pct, msg.c_str()); }
}

// 进度限流器：按「时间」而不是「计数」限制上报频率。
// 为什么不用计数限流：同一份代码在不同模型 / 机器上循环体耗时相差几个数量级，按计数
// 无法预估消息条数；而所有这些消息最终都要回到 JS 主线程逐条执行（解析 JSON + 更新状态 +
// 日志追加），发得太密会把主线程占满、界面冻结。按时间限流则无论循环多快，都固定压到
// 约 25 条/秒（40ms 一条），作为给主线程留的安全上限 —— 但不再像之前 120ms（约 8 条/秒）
// 那样把日志密度压得过稀（焊接阶段 2.6s 曾只剩 ~21 条，看起来不像终端流水）。
// 放宽的依据：「进度回调泛滥导致主线程冻结」已被实测证伪（每阶段本来只有约 40 条，不是
// 百万级），真正保护主线程的是 ArkTS 侧的合并机制（scheduleProgress：同一轮事件循环只渲染
// 最新一条，阶段切换 / 完成 / 终态不合并）。既然 JS 侧会自然节流，这里就可以放心放宽。
//
// 首条保证：该限流器第一次 emit 一定发出（此时还没有「上次发送时间」可比）。
// 末条保证：每个阶段的「阶段完成」那一条走的是不受限流的 report(...)，不会被吞。
class ProgressThrottle {
public:
    ProgressThrottle(const MeshProgressFn& fn, int stage) : fn_(fn), stage_(stage) {}

    void emit(int pct, const std::string& msg)
    {
        if (!fn_) { return; }
        const std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
        if (hasSent_ && now - last_ < std::chrono::milliseconds(40)) { return; }
        last_ = now;
        hasSent_ = true;
        fn_(stage_, pct, msg.c_str());
    }

private:
    const MeshProgressFn& fn_;
    int stage_;
    bool hasSent_ = false;
    std::chrono::steady_clock::time_point last_{};
};

// 长循环的「定期让出 CPU」闸门。
// 背景：二进制/ASCII STL、OBJ 解析、顶点焊接、法线折痕分组都是长循环 + 重内存访问，在核数
// 有限的设备上会把 UI/JS 线程挤到长时间抢不到时间片。实测（loaddlg2.log）：C++ 投递的进度
// 消息被 JS 主线程「成批」排空 —— 同一批内十几条落在同一毫秒、批与批之间相隔约 680ms；
// 「已用」这个 100ms 定时器也跟着变成每 0.5~1s 才跳一次。即「投递很快、渲染很慢」，根因就是
// 原生 worker 把 CPU 占满、UI 线程被饿住。
// 处理：按「时间」而不是「计数」判定 —— 距上次让出超过 20ms 就 yield()，让调度器把时间片
// 交给 UI 线程；再叠一次 1ms 的 sleep_for 兜底（纯忙等场景下 yield 可能立刻又把本线程选中，
// 1ms 的睡眠能真正腾出窗口）。判定本身只是一次 steady_clock 读，对单次迭代耗时的影响可忽略；
// 让出频率被限制在每 20ms 至多一次，累计让出时间远小于总耗时（总量级不变）。
// 纯让出：不改变任何计算结果，也没有副作用。
class CpuYielder {
public:
    void tick()
    {
        const std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
        if (now - last_ < std::chrono::milliseconds(20)) { return; }
        last_ = now;
        std::this_thread::yield();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

private:
    std::chrono::steady_clock::time_point last_{ std::chrono::steady_clock::now() };
};

// 追加一个三角形（自动计算面法线）到平面数组
void pushTri(MeshArrays& m,
             double ax, double ay, double az, double bx, double by, double bz,
             double cx, double cy, double cz)
{
    double ux = bx - ax, uy = by - ay, uz = bz - az;
    double vx = cx - ax, vy = cy - ay, vz = cz - az;
    double nx = uy * vz - uz * vy;
    double ny = uz * vx - ux * vz;
    double nz = ux * vy - uy * vx;
    double l = std::sqrt(nx * nx + ny * ny + nz * nz);
    if (l > 1e-12) { nx /= l; ny /= l; nz /= l; } else { nx = 0; ny = 0; nz = 1; }
    const float p[9] = { (float)ax, (float)ay, (float)az,
                         (float)bx, (float)by, (float)bz,
                         (float)cx, (float)cy, (float)cz };
    const float n[9] = { (float)nx, (float)ny, (float)nz,
                         (float)nx, (float)ny, (float)nz,
                         (float)nx, (float)ny, (float)nz };
    m.positions.insert(m.positions.end(), p, p + 9);
    m.normals.insert(m.normals.end(), n, n + 9);
}

bool parseStlBinary(const std::vector<char>& buf, MeshArrays& m, const MeshProgressFn& prog)
{
    if (buf.size() < 84) { return false; }
    uint32_t n;
    memcpy(&n, buf.data() + 80, 4);
    if (n == 0 || 84ull + 50ull * n != buf.size()) { return false; }
    report(prog, STAGE_PARSE, 12, "格式 · 二进制 STL · " + fmtCount(static_cast<long long>(n)) + " 三角面");
    // 长循环里每 1/120 迭代触发一次上报（约 100~120 条/阶段），是否真正发出仍由限流器按时间决定（约 25 条/秒）
    const uint32_t step = (n / 120u) > 0u ? (n / 120u) : 1u;
    ProgressThrottle parseThrottle(prog, STAGE_PARSE);
    CpuYielder yieldGate;   // 二进制 STL 主循环：周期性让出 CPU，避免把 UI 线程饿住
    const char* p = buf.data() + 84;
    for (uint32_t i = 0; i < n; i++) {
        yieldGate.tick();
        float v[12];
        memcpy(v, p, 48);
        p += 50; // 12 float + 2 字节属性
        pushTri(m, v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11]);
        if (i % step == 0u) {
            parseThrottle.emit(12 + static_cast<int>(70.0 * i / static_cast<double>(n)),
                   "解析三角面 · " + fmtCount(static_cast<long long>(i)) + " / " +
                   fmtCount(static_cast<long long>(n)));
        }
    }
    return true;
}

bool parseStlAscii(const std::vector<char>& buf, MeshArrays& m, const MeshProgressFn& prog)
{
    report(prog, STAGE_PARSE, 12, "格式 · ASCII STL");
    std::string text(buf.begin(), buf.end());
    ProgressThrottle parseThrottle(prog, STAGE_PARSE);
    CpuYielder yieldGate;   // ASCII STL 逐行循环：周期性让出 CPU
    float vs[3][3];
    int vi = 0;
    size_t pos = 0;
    int lastAsciiBucket = -1;   // 上一次上报所处的「已读字节」分段，用于把发送间隔提到约 1/120
    std::string line;
    auto nextLine = [&]() -> bool {
        if (pos >= text.size()) { return false; }
        size_t e = text.find('\n', pos);
        if (e == std::string::npos) { e = text.size(); }
        line = text.substr(pos, e - pos);
        pos = e + 1;
        return true;
    };
    while (nextLine()) {
        yieldGate.tick();   // ASCII STL 逐行解析：周期性让出 CPU
        float a, b, c;
        if (sscanf(line.c_str(), " vertex %f %f %f", &a, &b, &c) == 3) {
            if (vi < 3) { vs[vi][0] = a; vs[vi][1] = b; vs[vi][2] = c; vi++; }
            if (vi == 3) {
                pushTri(m, vs[0][0], vs[0][1], vs[0][2],
                        vs[1][0], vs[1][1], vs[1][2], vs[2][0], vs[2][1], vs[2][2]);
                vi = 0;
                m.triangles++;   // 真实完成的三角面计数（供进度消息显示）
                // ASCII 无法预知总面数，改用「已读字节 pos / 文件大小」分 120 段触发上报
                // （约 1/120，与其它阶段密度一致）；是否真正发出仍由时间限流器决定。
                // 百分比与面数都来自循环里真实可得的量，不编造。
                const int asciiBucket = static_cast<int>(120.0 * pos / static_cast<double>(text.size()));
                if (asciiBucket != lastAsciiBucket) {
                    lastAsciiBucket = asciiBucket;
                    parseThrottle.emit(12 + static_cast<int>(70.0 * pos / static_cast<double>(text.size())),
                           "解析三角面 · 已完成 " + fmtCount(static_cast<long long>(m.triangles)) +
                           " 个 · 已读 " + fmtPct1(100.0 * pos / static_cast<double>(text.size())) + "%");
                }
            }
        }
    }
    return m.positions.size() > 0;
}

bool parseObj(const std::vector<char>& buf, MeshArrays& m, const MeshProgressFn& prog)
{
    report(prog, STAGE_PARSE, 12, "格式 · OBJ 文本");
    std::string text(buf.begin(), buf.end());
    ProgressThrottle parseThrottle(prog, STAGE_PARSE);
    CpuYielder yieldGate;   // OBJ 逐行循环：周期性让出 CPU
    std::vector<float> pts;
    size_t pos = 0;
    int lastObjBucket = -1;   // 上一次上报所处的「已读字节」分段，用于把发送间隔提到约 1/120
    std::string line;
    auto nextLine = [&]() -> bool {
        if (pos >= text.size()) { return false; }
        size_t e = text.find('\n', pos);
        if (e == std::string::npos) { e = text.size(); }
        line = text.substr(pos, e - pos);
        pos = e + 1;
        return true;
    };
    while (nextLine()) {
        yieldGate.tick();   // OBJ 逐行解析：周期性让出 CPU
        float x, y, z;
        if (sscanf(line.c_str(), "v %f %f %f", &x, &y, &z) == 3) {
            pts.insert(pts.end(), { x, y, z });
        } else if (line.compare(0, 2, "f ") == 0) {
            int idx[8];
            int cnt = 0;
            const char* p = line.c_str() + 2;
            while (*p && cnt < 8) {
                while (*p == ' ' || *p == '\t' || *p == '\r') { p++; }
                if (!*p) { break; }
                int id = (int)strtol(p, const_cast<char**>(&p), 10);
                if (*p == '/') {
                    strtol(p + 1, const_cast<char**>(&p), 10);
                    if (*p == '/') { strtol(p + 1, const_cast<char**>(&p), 10); }
                }
                idx[cnt++] = id;
            }
            for (int i = 1; i + 1 < cnt; i++) {
                auto fix = [&](int id) -> int {
                    if (id < 0) { id = (int)pts.size() / 3 + id; } else { id -= 1; }
                    return id;
                };
                int a = fix(idx[0]), b = fix(idx[i]), c = fix(idx[i + 1]);
                if (a < 0 || b < 0 || c < 0) { continue; }
                size_t nv = pts.size() / 3;
                if ((size_t)a >= nv || (size_t)b >= nv || (size_t)c >= nv) { continue; }
                pushTri(m,
                        pts[a * 3], pts[a * 3 + 1], pts[a * 3 + 2],
                        pts[b * 3], pts[b * 3 + 1], pts[b * 3 + 2],
                        pts[c * 3], pts[c * 3 + 1], pts[c * 3 + 2]);
                m.triangles++;
            }
            // OBJ 同样无法预知总面数，用「已读字节 pos / 文件大小」分 120 段触发上报
            // （约 1/120）；面数与百分比都来自真实计数 / 位置，是否真正发出由限流器决定。
            const int objBucket = static_cast<int>(120.0 * pos / static_cast<double>(text.size()));
            if (objBucket != lastObjBucket) {
                lastObjBucket = objBucket;
                parseThrottle.emit(12 + static_cast<int>(70.0 * pos / static_cast<double>(text.size())),
                       "解析三角面 · 已完成 " + fmtCount(static_cast<long long>(m.triangles)) +
                       " 个 · 已读 " + fmtPct1(100.0 * pos / static_cast<double>(text.size())) + "%");
            }
        }
    }
    return m.positions.size() > 0;
}

// 归一化：XY 居中、底面贴板，并统计包围盒尺寸
void normalize(MeshArrays& m)
{
    size_t n = m.positions.size() / 3;
    float lo[3] = { 1e30f, 1e30f, 1e30f };
    float hi[3] = { -1e30f, -1e30f, -1e30f };
    for (size_t i = 0; i < n; i++) {
        for (int d = 0; d < 3; d++) {
            float v = m.positions[i * 3 + d];
            lo[d] = std::min(lo[d], v);
            hi[d] = std::max(hi[d], v);
        }
    }

    // 单位识别：最大尺寸 < 1mm 的模型基本不可能是「真的要打 1mm 以下」，
    // 而是 CAD 按**米**导出（实测：吸尘器.stl 包围盒 0.141×0.060×0.047）。
    // 按毫米解释会变成 0.1mm 的小点：预览看不见，切片也切不动。
    // 这里统一换算成毫米（×1000），normals 不受影响；unitScale 供调用方提示与重写切片文件。
    const float maxDim0 = std::max(hi[0] - lo[0], std::max(hi[1] - lo[1], hi[2] - lo[2]));
    if (maxDim0 > 0.0f && maxDim0 < 1.0f) {
        const float k = 1000.0f;
        for (size_t i = 0; i < n * 3; i++) {
            m.positions[i] *= k;
        }
        for (int d = 0; d < 3; d++) {
            lo[d] *= k;
            hi[d] *= k;
        }
        m.unitScale = k;
    }

    float cx = (lo[0] + hi[0]) * 0.5f;
    float cy = (lo[1] + hi[1]) * 0.5f;
    for (size_t i = 0; i < n; i++) {
        m.positions[i * 3 + 0] -= cx;
        m.positions[i * 3 + 1] -= cy;
        m.positions[i * 3 + 2] -= lo[2];
    }
    m.size[0] = hi[0] - lo[0];
    m.size[1] = hi[1] - lo[1];
    m.size[2] = hi[2] - lo[2];
    m.triangles = static_cast<int>(n / 3);
    m.ok = true;
}

// 预览抽稀（兜底）：聚类简化（顶点吸附到网格单元）。
// 输入/输出均为无索引三角面汤（positions.size() == triangles*9），质量损失大，
// 仅在三角面数超出预算的超大模型上调用；随后统一由 weldVertices 做焊接索引化。
// 原始真实面数与包围盒尺寸会先写入 origTriangles / origSize，供 UI 显示。
// 注意：未超预算直接返回的分支同样会填好 origTriangles / origSize。
void decimatePreview(MeshArrays& m, int maxTriangles, const MeshProgressFn& prog)
{
    const size_t n = m.positions.size() / 3; // 顶点数（每 3 个 float 一个顶点）
    if (n == 0) { return; }

    // 1) 裁剪前先统计原始包围盒与真实面数
    float lo[3] = { 1e30f, 1e30f, 1e30f };
    float hi[3] = { -1e30f, -1e30f, -1e30f };
    for (size_t i = 0; i < n; i++) {
        for (int d = 0; d < 3; d++) {
            float v = m.positions[i * 3 + d];
            if (v < lo[d]) { lo[d] = v; }
            if (v > hi[d]) { hi[d] = v; }
        }
    }
    m.origTriangles = m.triangles;
    m.origSize[0] = hi[0] - lo[0];
    m.origSize[1] = hi[1] - lo[1];
    m.origSize[2] = hi[2] - lo[2];

    // 2) 未超预算：小模型原样保留，零损失
    if (m.triangles <= maxTriangles) { return; }

    // 只有超大模型才会走到这里，进度归到「解析文件」阶段的尾部（抽稀本身就是解析兜底的一部分）
    report(prog, STAGE_PARSE, 90,
           "预览抽稀（超大模型兜底）· 原始 " + fmtCount(static_cast<long long>(m.triangles)) + " 三角面");

    const int triCount = m.triangles;
    float maxDim = m.origSize[0];
    if (m.origSize[1] > maxDim) { maxDim = m.origSize[1]; }
    if (m.origSize[2] > maxDim) { maxDim = m.origSize[2]; }
    if (maxDim <= 0.0f) { maxDim = 1.0f; }

    // 单元 key：三轴各取 21 位打包进 uint64_t（每轴 ±2^20 个单元，足够覆盖量化范围）
    auto makeKey = [](int64_t ix, int64_t iy, int64_t iz) -> uint64_t {
        const int64_t mask = (1ll << 21) - 1;
        return ((uint64_t)(ix & mask) << 42) | ((uint64_t)(iy & mask) << 21) |
               (uint64_t)(iz & mask);
    };
    // 复用一个 lambda 计算顶点所属单元中心（先量化取整，再回算中心）
    auto cellOf = [&](const float* p, float curCell, int64_t out[3]) {
        out[0] = (int64_t)std::floor((p[0] - lo[0]) / curCell);
        out[1] = (int64_t)std::floor((p[1] - lo[1]) / curCell);
        out[2] = (int64_t)std::floor((p[2] - lo[2]) / curCell);
    };

    // 3) 自适应格边长：初始 maxDim/256，最多迭代 12 次，未达预算则格边长翻倍
    float cell = maxDim / 256.0f;
    if (cell <= 1e-9f) { cell = maxDim; }

    std::unordered_map<uint64_t, int> cellId; // 单元 key -> 紧凑 id
    std::vector<float> centers;               // 每个单元中心坐标（x,y,z 连续存放）
    centers.reserve(1024);

    bool converged = false;
    for (int iter = 0; iter < 12; iter++) {
        cellId.clear();
        centers.clear();
        int nextId = 0;
        // 统计单元：为省内存/时间，超过预算就立即停止本轮
        for (size_t i = 0; i < n; i++) {
            int64_t c[3];
            cellOf(&m.positions[i * 3], cell, c);
            uint64_t key = makeKey(c[0], c[1], c[2]);
            if (cellId.emplace(key, nextId).second) {
                if (nextId > maxTriangles) { break; } // 超出预算，本轮失败
                centers.push_back((float)(lo[0] + ((double)c[0] + 0.5) * cell));
                centers.push_back((float)(lo[1] + ((double)c[1] + 0.5) * cell));
                centers.push_back((float)(lo[2] + ((double)c[2] + 0.5) * cell));
                nextId++;
            }
        }
        if (nextId <= maxTriangles) { converged = true; break; } // 达到预算，收敛
        cell *= 2.0f;
    }
    // 12 次仍未收敛（超大模型）：在最终格边长上做一次完整扫描，保证顶点->单元映射完整
    if (!converged) {
        cellId.clear();
        centers.clear();
        int nextId = 0;
        for (size_t i = 0; i < n; i++) {
            int64_t c[3];
            cellOf(&m.positions[i * 3], cell, c);
            uint64_t key = makeKey(c[0], c[1], c[2]);
            if (cellId.emplace(key, nextId).second) {
                centers.push_back((float)(lo[0] + ((double)c[0] + 0.5) * cell));
                centers.push_back((float)(lo[1] + ((double)c[1] + 0.5) * cell));
                centers.push_back((float)(lo[2] + ((double)c[2] + 0.5) * cell));
                nextId++;
            }
        }
    }

    // 4) 重建：每个原始三角面映射到三个单元中心；任两顶点同单元则丢弃（退化成线/点）
    std::vector<float> newPos;
    std::vector<float> newNor;
    newPos.reserve((size_t)cellId.size() * 9);
    newNor.reserve((size_t)cellId.size() * 9);
    const int rebuildStep = (triCount / 120) > 0 ? (triCount / 120) : 1;
    ProgressThrottle decimateThrottle(prog, STAGE_PARSE);
    for (int t = 0; t < triCount; t++) {
        if (t % rebuildStep == 0) {
            decimateThrottle.emit(90 + static_cast<int>(8.0 * t / static_cast<double>(triCount)),
                   "预览抽稀中 · " + fmtCount(static_cast<long long>(t)) + " / " +
                   fmtCount(static_cast<long long>(triCount)) + " 三角面");
        }
        int64_t id[3];
        for (int k = 0; k < 3; k++) {
            const float* vp = &m.positions[((size_t)t * 3 + k) * 3];
            int64_t c[3];
            cellOf(vp, cell, c);
            auto it = cellId.find(makeKey(c[0], c[1], c[2]));
            id[k] = (it == cellId.end()) ? -1 : it->second;
        }
        if (id[0] < 0 || id[1] < 0 || id[2] < 0) { continue; }
        if (id[0] == id[1] || id[1] == id[2] || id[0] == id[2]) { continue; }

        const float* c0 = &centers[(size_t)id[0] * 3];
        const float* c1 = &centers[(size_t)id[1] * 3];
        const float* c2 = &centers[(size_t)id[2] * 3];
        // 用新顶点算面法线（叉积归一化），三个顶点共用同一法线
        double ux = (double)c1[0] - c0[0], uy = (double)c1[1] - c0[1], uz = (double)c1[2] - c0[2];
        double vx = (double)c2[0] - c0[0], vy = (double)c2[1] - c0[1], vz = (double)c2[2] - c0[2];
        double nx = uy * vz - uz * vy;
        double ny = uz * vx - ux * vz;
        double nz = ux * vy - uy * vx;
        double l = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (l > 1e-12) { nx /= l; ny /= l; nz /= l; } else { nx = 0; ny = 0; nz = 1; }
        const float p[9] = { c0[0], c0[1], c0[2], c1[0], c1[1], c1[2], c2[0], c2[1], c2[2] };
        const float vn[9] = { (float)nx, (float)ny, (float)nz,
                              (float)nx, (float)ny, (float)nz,
                              (float)nx, (float)ny, (float)nz };
        newPos.insert(newPos.end(), p, p + 9);
        newNor.insert(newNor.end(), vn, vn + 9);
    }

    int newTris = (int)(newPos.size() / 9);
    if (newTris <= 0) {
        // 极端情况：抽稀后无有效面，保留原数据不动并给出说明
        m.error = "预览抽稀失败：简化后无有效三角面，已保留原始网格";
        return;
    }

    // 5) 覆盖：positions/normals/triangles 表示抽稀后交给预览的那份
    m.positions.swap(newPos);
    m.normals.swap(newNor);
    m.triangles = newTris;

    // 6) 打日志（沿用在别处相同的 addLog 用法）
    BambuMqtt::addLog("renderer: preview mesh " + std::to_string(m.origTriangles) +
                      " -> " + std::to_string(m.triangles) + " tris");
    report(prog, STAGE_PARSE, 99,
           "预览抽稀完成 · " + fmtCount(static_cast<long long>(m.triangles)) + " 三角面");
}

// 顶点焊接 + 索引化：把无索引三角面汤（positions.size() == triangles*9）压成唯一顶点 + 索引。
// 去重按容差量化（步长 = 包围盒对角线 × 1e-6）比较，写入的坐标仍是原始值 —— 不改变几何形状，
// 只消除 STL 里被重复存储的顶点。注意不能按 float 逐位比较：同一空间点在不同三角面里
// 常常不是逐位相同，那样会一个都合并不了，法线退化成面法线，曲面就会凹凸不平。
//
// 法线按"平滑组"生成，而不是把顶点上所有面法线无条件平均掉：顶点上法线夹角超过折痕角
// （kCreaseAngleCos）的面会被拆进不同的平滑组，每个 (顶点, 组) 各生成一个输出顶点
// （坐标相同、法线不同）。这样倒角/平面之间的硬转折能保留清晰的明暗分界（不再被平均成
// 光滑圆角），而光滑曲面（相邻面夹角 < 阈值）仍照常平滑。组内累加时做符号对齐，抵消
// STL 里常见的绕序不一致导致的正反法线互相抵消。
//
// 输出：positions/normals 为唯一顶点（每个平滑组一个），
//       indices 每 3 个 = 一个三角面，triangles = indices.size()/3。
// 不改变 origTriangles / origSize / size（焊接不改变面数与尺寸，真实值仍由 decimatePreview 填写）。
void weldVertices(MeshArrays& m, const MeshProgressFn& prog)
{
    const size_t vertCount = m.positions.size() / 3;   // 焊接前顶点数（面汤：每 3 个 float 一个顶点）
    if (vertCount < 3) { return; }
    const int triCount = static_cast<int>(vertCount / 3);
    m.weldInVerts = static_cast<int>(vertCount);

    report(prog, STAGE_WELD, 2, "检测到无索引面汤 · 启动顶点焊接");

    // 容差去重 key：量化后的整数格号（逐分量相等才算同一顶点；hash 冲突由 operator== 兜底）
    struct WeldKey {
        int32_t x, y, z;
        bool operator==(const WeldKey& o) const { return x == o.x && y == o.y && z == o.z; }
    };
    struct WeldKeyHash {
        size_t operator()(const WeldKey& k) const {
            // FNV-1a 混合三个分量
            size_t h = 2166136261u;
            h = (h ^ static_cast<size_t>(k.x)) * 16777619u;
            h = (h ^ static_cast<size_t>(k.y)) * 16777619u;
            h = (h ^ static_cast<size_t>(k.z)) * 16777619u;
            return h;
        }
    };

    std::unordered_map<WeldKey, uint32_t, WeldKeyHash> weldMap;
    weldMap.reserve(vertCount);

    // 量化基准与步长：包围盒对角线 × 1e-6（对 200mm 的件约 3e-4 mm，远小于任何可见误差）。
    // 只用于"判断两个顶点是不是同一个点"，写进 outPos 的仍是第一次出现的原始坐标。
    float bbMin[3] = { m.positions[0], m.positions[1], m.positions[2] };
    float bbMax[3] = { bbMin[0], bbMin[1], bbMin[2] };
    for (size_t i = 0; i + 2 < m.positions.size(); i += 3) {
        for (int d = 0; d < 3; d++) {
            const float v = m.positions[i + d];
            if (v < bbMin[d]) { bbMin[d] = v; }
            if (v > bbMax[d]) { bbMax[d] = v; }
        }
    }
    const double dx = (double)bbMax[0] - bbMin[0];
    const double dy = (double)bbMax[1] - bbMin[1];
    const double dz = (double)bbMax[2] - bbMin[2];
    const double diag = std::sqrt(dx * dx + dy * dy + dz * dz);
    const double tol = (diag * 1e-6) > 1e-9 ? (diag * 1e-6) : 1e-9;

    std::vector<float> outPos;                              // 唯一顶点坐标
    std::vector<uint32_t> outIdx;                           // 索引（3 个一组）
    std::vector<float> faceNor(static_cast<size_t>(triCount) * 3, 0.0f); // 每个三角面的面法线
    outPos.reserve(vertCount * 3);
    outIdx.reserve(static_cast<size_t>(triCount) * 3);

    // 1) 顶点焊接（逐位精确去重），同时按当前绕序算面法线与有符号体积
    // 这一段是整个载入里最耗时的循环：每 1/120 迭代触发一次上报，是否真正发出由限流器按时间决定
    const int weldStep = (triCount / 120) > 0 ? (triCount / 120) : 1;
    ProgressThrottle weldThrottle(prog, STAGE_WELD);
    CpuYielder yieldGate;   // 焊接去重循环：整段载入最重的循环，周期性让出 CPU
    double signedVol = 0.0;
    for (int t = 0; t < triCount; t++) {
        yieldGate.tick();
        if (t % weldStep == 0) {
            // 消息里的三个数全部来自循环里真实可得的计数：
            //   已处理顶点 = t*3；总顶点 = vertCount；当前已去重顶点 = outPos.size()/3。
            // 下降比例与「焊接完成」同口径（1 - 唯一顶点 / 焊接前总顶点），不编造。
            const long long processedVerts = static_cast<long long>(t) * 3;
            const long long uniqueSoFar = static_cast<long long>(outPos.size() / 3);
            const double dropNow = vertCount > 0
                                 ? (1.0 - static_cast<double>(uniqueSoFar) / static_cast<double>(vertCount)) * 100.0
                                 : 0.0;
            weldThrottle.emit(5 + static_cast<int>(85.0 * t / static_cast<double>(triCount)),
                   "焊接中 · " + fmtCount(processedVerts) + " / " +
                   fmtCount(static_cast<long long>(vertCount)) + " · 去重后 " +
                   fmtCount(uniqueSoFar) + "（↓ " + fmtPct1(dropNow) + "%）");
        }
        const float* p = &m.positions[static_cast<size_t>(t) * 9];
        uint32_t id[3];
        for (int k = 0; k < 3; k++) {
            // 按容差量化后再比较：STL 里同一个空间点在不同三角面里常常不是逐位相同的
            // float（导出/修复工具重算过坐标），逐位比较会导致一个顶点都合并不了 ——
            // 那样每个顶点只属于一个面，法线退化成面法线，曲面就会渲染成凹凸不平。
            WeldKey key;
            key.x = (int32_t)std::lround(((double)p[k * 3 + 0] - bbMin[0]) / tol);
            key.y = (int32_t)std::lround(((double)p[k * 3 + 1] - bbMin[1]) / tol);
            key.z = (int32_t)std::lround(((double)p[k * 3 + 2] - bbMin[2]) / tol);
            auto it = weldMap.find(key);
            if (it == weldMap.end()) {
                uint32_t vid = static_cast<uint32_t>(outPos.size() / 3);
                weldMap.emplace(key, vid);
                outPos.push_back(p[k * 3 + 0]);
                outPos.push_back(p[k * 3 + 1]);
                outPos.push_back(p[k * 3 + 2]);
                id[k] = vid;
            } else {
                id[k] = it->second;
            }
        }
        outIdx.push_back(id[0]);
        outIdx.push_back(id[1]);
        outIdx.push_back(id[2]);

        const float* a = &outPos[static_cast<size_t>(id[0]) * 3];
        const float* b = &outPos[static_cast<size_t>(id[1]) * 3];
        const float* c = &outPos[static_cast<size_t>(id[2]) * 3];
        // 面法线 = (b-a) × (c-a)，归一化
        double ux = (double)b[0] - a[0], uy = (double)b[1] - a[1], uz = (double)b[2] - a[2];
        double vx = (double)c[0] - a[0], vy = (double)c[1] - a[1], vz = (double)c[2] - a[2];
        double nx = uy * vz - uz * vy;
        double ny = uz * vx - ux * vz;
        double nz = ux * vy - uy * vx;
        double l = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (l > 1e-12) { nx /= l; ny /= l; nz /= l; } else { nx = 0; ny = 0; nz = 1; }
        faceNor[static_cast<size_t>(t) * 3 + 0] = (float)nx;
        faceNor[static_cast<size_t>(t) * 3 + 1] = (float)ny;
        faceNor[static_cast<size_t>(t) * 3 + 2] = (float)nz;

        // 有符号体积贡献（散度定理）：a · (b × c)
        double bcx = (double)b[1] * c[2] - (double)b[2] * c[1];
        double bcy = (double)b[2] * c[0] - (double)b[0] * c[2];
        double bcz = (double)b[0] * c[1] - (double)b[1] * c[0];
        signedVol += (double)a[0] * bcx + (double)a[1] * bcy + (double)a[2] * bcz;
    }

    // 2) 朝向一致性修正：整体体积为负说明绕序朝内，把所有面法线取反（等价于翻转绕序的效果）
    if (signedVol < 0.0) {
        for (size_t i = 0; i < faceNor.size(); i++) { faceNor[i] = -faceNor[i]; }
    }

    // 2.5) 需求 4：悬空（朝下）面启发式统计 —— 在原生侧一次线性扫描，尽量快。
    // 用「已修好朝向」的面法线 faceNor + 唯一顶点 outPos + 面索引 outIdx。
    //   · 朝下悬空面：nz <= -cos(kOverhangAngleDeg)（法线指向下方，且与竖直向下夹角不超过阈值）；
    //   · 排除贴板底面：三顶点 z 都 < kBedContactZ 的朝下面 = 贴在板上的底面，不需要支撑；
    //   · 占比 = 朝下面面积 / 全部三角面面积；超过 kOverhangAreaRatioPct → 建议加支撑。
    // 如实标注：这是启发式（用预览副本、不看桥接/逐层/自交），只用于提醒，不是切片器结论。
    {
        const double cosThr = std::cos(static_cast<double>(kOverhangAngleDeg) * 3.14159265358979323846 / 180.0);
        double totalArea = 0.0;
        double downArea = 0.0;
        for (int t = 0; t < triCount; t++) {
            const float* a = &outPos[static_cast<size_t>(outIdx[static_cast<size_t>(t) * 3 + 0]) * 3];
            const float* b = &outPos[static_cast<size_t>(outIdx[static_cast<size_t>(t) * 3 + 1]) * 3];
            const float* c = &outPos[static_cast<size_t>(outIdx[static_cast<size_t>(t) * 3 + 2]) * 3];
            const double ux = (double)b[0] - a[0], uy = (double)b[1] - a[1], uz = (double)b[2] - a[2];
            const double vx = (double)c[0] - a[0], vy = (double)c[1] - a[1], vz = (double)c[2] - a[2];
            const double cx = uy * vz - uz * vy;
            const double cy = uz * vx - ux * vz;
            const double cz = ux * vy - uy * vx;
            const double area = 0.5 * std::sqrt(cx * cx + cy * cy + cz * cz);
            totalArea += area;
            const float nz = faceNor[static_cast<size_t>(t) * 3 + 2];
            if ((double)nz > -cosThr) { continue; }          // 不是「朝下且足够陡」的面
            const float zmin = std::min(a[2], std::min(b[2], c[2]));
            if (zmin < kBedContactZ) { continue; }           // 贴板底面，不算悬空
            downArea += area;
        }
        m.overhangAngleDeg = kOverhangAngleDeg;
        m.overhangAreaPctThreshold = kOverhangAreaRatioPct;
        m.overhangRatioPct = totalArea > 0.0 ? static_cast<float>(downArea / totalArea * 100.0) : 0.0f;
        m.needsSupport = m.overhangRatioPct > kOverhangAreaRatioPct;
        OH_LOG_INFO(LOG_APP,
                    "FlowSupport 悬空检测 朝下面占比=%{public}s%% 阈值=%{public}s%% 角度阈值=%{public}s° "
                    "判定=%{public}s tris=%{public}d",
                    fmtPct1(static_cast<double>(m.overhangRatioPct)).c_str(),
                    fmtPct1(static_cast<double>(kOverhangAreaRatioPct)).c_str(),
                    fmtPct1(static_cast<double>(kOverhangAngleDeg)).c_str(),
                    m.needsSupport ? "需支撑" : "无需支撑", triCount);
    }

    // 焊接完成后，原始面汤(positions/normals)与去重表都不再被使用，提前释放。
    // 它们是大模型里最大的两块内存（面汤 positions 约为输出顶点坐标的 3 倍以上），
    // 若不释放会与下面的分组结构叠加，把导入峰值内存抬高一倍。
    std::vector<float>().swap(m.positions);
    std::vector<float>().swap(m.normals);
    weldMap = decltype(weldMap)();   // 释放哈希桶（大模型里去重表可达几百 MB）

    const size_t uniqueVerts = outPos.size() / 3;
    m.uniqueVerts = static_cast<int>(uniqueVerts);
    {
        // 下降比例用真实计数算：1 - 唯一顶点 / 焊接前顶点
        const double drop = vertCount > 0
                          ? (1.0 - static_cast<double>(uniqueVerts) / static_cast<double>(vertCount)) * 100.0
                          : 0.0;
        report(prog, STAGE_WELD, 100,
               "焊接完成 · 唯一顶点 " + fmtCount(static_cast<long long>(uniqueVerts)) +
               "（↓ " + fmtPct1(drop) + "%）");
    }

    // 3) 顶点 -> 角（corner = 面号*3 + 角号）的 CSR 关联。
    // 用 CSR（先统计度数、前缀和、再填一次）而不是 vector<vector<>>，
    // 避免大模型上千万次小分配带来的内存碎片与开销。
    std::vector<uint32_t> vertCorners(outIdx.size());       // 平铺的角列表
    std::vector<uint32_t> vertBegin(uniqueVerts + 1, 0);    // 每个顶点的角区间起始下标
    for (size_t i = 0; i < outIdx.size(); i++) { vertBegin[outIdx[i] + 1]++; }
    for (size_t v = 0; v < uniqueVerts; v++) { vertBegin[v + 1] += vertBegin[v]; }
    {
        std::vector<uint32_t> cursor(vertBegin.begin(), vertBegin.end() - 1);
        for (int t = 0; t < triCount; t++) {
            for (int k = 0; k < 3; k++) {
                const uint32_t v = outIdx[static_cast<size_t>(t) * 3 + k];
                vertCorners[cursor[v]++] = static_cast<uint32_t>(t) * 3 + k;
            }
        }
    }

    // 4) 逐顶点按折痕角聚类（贪心 first-fit），每个 (顶点, 平滑组) 生成一个输出顶点。
    // first-fit 只会过度拆分（保守）—— 绝不会把硬边错误地合并进同一组，这正是要的安全性。
    std::vector<uint32_t> cornerGroup(outIdx.size(), 0);    // 每个角所属的组号（相对它的顶点）
    std::vector<uint32_t> groupBase(uniqueVerts + 1, 0);    // 每个顶点第 0 组对应的输出顶点 id
    std::vector<float> groupNor;                            // 每个组的累加法线（3 float/组）
    groupNor.reserve(uniqueVerts * 3);

    uint32_t nextOutVert = 0;                 // 已生成的输出顶点数（= 总组数）
    std::vector<uint32_t> localGroup;         // 复用缓冲：当前顶点各角的组号，避免逐顶点分配
    report(prog, STAGE_NORMALS, 2, "法线重建 · 折痕角 30° 拆平滑组");
    const uint32_t groupStep = (uniqueVerts / 120) > 0 ? static_cast<uint32_t>(uniqueVerts / 120) : 1u;
    ProgressThrottle normalThrottle(prog, STAGE_NORMALS);
    CpuYielder normalYield;   // 法线折痕分组循环：逐顶点 + 逐角的重活，周期性让出 CPU
    for (uint32_t v = 0; v < uniqueVerts; v++) {
        normalYield.tick();
        if (v % groupStep == 0u) {
            // 「硬边顶点」= 已生成输出顶点 - 已处理顶点（每个顶点至少 1 组，多出来的就是折痕拆分的），
            // 与收尾那条「法线完成 · 硬边顶点 +N」同口径，都是循环里真实累加出来的计数。
            const long long creaseSoFar = static_cast<long long>(nextOutVert) - static_cast<long long>(v);
            normalThrottle.emit(5 + static_cast<int>(85.0 * v / static_cast<double>(uniqueVerts)),
                   "法线重建中 · " + fmtCount(static_cast<long long>(v)) + " / " +
                   fmtCount(static_cast<long long>(uniqueVerts)) + " · 硬边顶点 +" +
                   fmtCount(creaseSoFar));
        }
        groupBase[v] = nextOutVert;
        const uint32_t b = vertBegin[v], e = vertBegin[v + 1];
        const uint32_t deg = e - b;
        if (deg == 0) { continue; }           // 防御：孤立顶点（正常不会出现）
        localGroup.assign(deg, UINT32_MAX);   // UINT32_MAX = 尚未分组
        uint32_t ng = 0;                      // 本顶点的组数
        for (uint32_t i = 0; i < deg; i++) {
            if (localGroup[i] != UINT32_MAX) { continue; }
            // 取一个未分组的面作种子，新建一组
            const uint32_t seedFace = vertCorners[b + i] / 3;
            const float* sn = &faceNor[static_cast<size_t>(seedFace) * 3];
            const uint32_t g = ng++;
            localGroup[i] = g;
            cornerGroup[vertCorners[b + i]] = g;
            // 累加方向以种子法线为参考；同组后续面加入前先做符号对齐
            float ax = sn[0], ay = sn[1], az = sn[2];
            for (uint32_t j = i + 1; j < deg; j++) {
                if (localGroup[j] != UINT32_MAX) { continue; }
                const uint32_t fj = vertCorners[b + j] / 3;
                const float* fn = &faceNor[static_cast<size_t>(fj) * 3];
                // 与种子法线夹角 < 折痕阈值才并入。夹角大 = 硬边（或绕序不一致 ≈180°），
                // 拆开更安全，宁可多拆也不要把硬边平滑掉。
                if (fn[0] * sn[0] + fn[1] * sn[1] + fn[2] * sn[2] < kCreaseAngleCos) { continue; }
                // 符号对齐：与已累加方向相反（STL 绕序不一致常见）就先取反，避免互相抵消
                if (fn[0] * ax + fn[1] * ay + fn[2] * az < 0.0f) {
                    ax -= fn[0]; ay -= fn[1]; az -= fn[2];
                } else {
                    ax += fn[0]; ay += fn[1]; az += fn[2];
                }
                localGroup[j] = g;
                cornerGroup[vertCorners[b + j]] = g;
            }
            groupNor.push_back(ax);
            groupNor.push_back(ay);
            groupNor.push_back(az);
        }
        nextOutVert += ng;
    }
    groupBase[uniqueVerts] = nextOutVert;

    // 组内累加方向归一化，直接作为该组的输出法线
    for (size_t i = 0; i + 2 < groupNor.size(); i += 3) {
        double nx = groupNor[i], ny = groupNor[i + 1], nz = groupNor[i + 2];
        double l = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (l > 1e-12) {
            groupNor[i] = (float)(nx / l);
            groupNor[i + 1] = (float)(ny / l);
            groupNor[i + 2] = (float)(nz / l);
        } else {
            groupNor[i] = 0.0f; groupNor[i + 1] = 1.0f; groupNor[i + 2] = 0.0f;
        }
    }

    // 5) 位置：同一个顶点的所有平滑组共用同一坐标（只是法线不同）
    if (nextOutVert == uniqueVerts) {
        // 完全光滑、没有任何折痕拆分：位置可直接复用，省一次拷贝
        m.positions.swap(outPos);
    } else {
        std::vector<float> newPos;
        newPos.reserve(static_cast<size_t>(nextOutVert) * 3);
        for (uint32_t v = 0; v < uniqueVerts; v++) {
            const float* p = &outPos[static_cast<size_t>(v) * 3];
            for (uint32_t gid = groupBase[v]; gid < groupBase[v + 1]; gid++) {
                newPos.push_back(p[0]);
                newPos.push_back(p[1]);
                newPos.push_back(p[2]);
            }
        }
        m.positions.swap(newPos);   // 原 outPos 在此作用域结束后释放
    }

    // 6) 重建索引：每个角指向"(该顶点, 该角所属组)"的输出顶点
    // 直接原地改写 outIdx（每个角独立，且先读后写，不会互相污染）
    for (size_t c = 0; c < outIdx.size(); c++) {
        outIdx[c] = groupBase[outIdx[c]] + cornerGroup[c];
    }

    // 折痕拆出的额外顶点数（正常情况 nextOutVert >= uniqueVerts；防御性判断避免回绕）
    const size_t creaseSplit = (nextOutVert > uniqueVerts)
                             ? static_cast<size_t>(nextOutVert) - uniqueVerts : 0;
    m.creaseSplit = static_cast<int>(creaseSplit);

    // 7) 覆盖：positions/normals 变为唯一顶点，indices 为面索引，triangles = 面数
    m.normals.swap(groupNor);
    m.indices.swap(outIdx);
    m.triangles = static_cast<int>(m.indices.size() / 3);
    m.outVerts = static_cast<int>(m.positions.size() / 3);

    report(prog, STAGE_NORMALS, 100,
           "法线完成 · 硬边顶点 +" + fmtCount(static_cast<long long>(creaseSplit)));

    // hop1：法线循环已结束（「法线完成」这条进度也已上报），weldVertices 即将 return。
    // 这里放在 addLog 之前 —— 若真机只看到 hop1 而没有 hop2，则卡点就在 addLog / return。
    {
        const std::string stamp = LoadDlgStamp("1", "weld-end");
        OH_LOG_INFO(LOG_APP,
                    "LoadDlg %{public}s uniqueVerts=%{public}d creaseSplit=%{public}d "
                    "outVerts=%{public}d indices=%{public}d tris=%{public}d",
                    stamp.c_str(), static_cast<int>(uniqueVerts), static_cast<int>(creaseSplit),
                    m.outVerts, static_cast<int>(m.indices.size()), m.triangles);
    }

    BambuMqtt::addLog("renderer: preview weld " + std::to_string(vertCount) +
                      " -> " + std::to_string(nextOutVert) + " verts (crease split +" +
                      std::to_string(creaseSplit) + "), " +
                      std::to_string(m.triangles) + " tris");
}

} // namespace

bool parseStlObj(const std::string& path, MeshArrays& out, const MeshProgressFn& progress)
{
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        out.ok = false;
        out.error = "无法打开文件";
        return false;
    }
    std::vector<char> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (buf.empty()) {
        out.ok = false;
        out.error = "文件为空";
        return false;
    }
    // 「已读取字节数」来自真实文件大小
    report(progress, STAGE_PARSE, 8, "读取 " + fmtSize(static_cast<long long>(buf.size())));

    bool ok = false;
    bool isObj = path.size() > 4 && path.compare(path.size() - 4, 4, ".obj") == 0;
    if (isObj) {
        ok = parseObj(buf, out, progress);
    } else {
        ok = parseStlBinary(buf, out, progress);
        if (!ok) { ok = parseStlAscii(buf, out, progress); }
    }
    if (!ok || out.positions.empty()) {
        out.ok = false;
        out.error = "解析失败（仅支持 STL/OBJ）";
        return false;
    }
    normalize(out);
    // 「三角面 / 顶点」均为解析出来的真实计数（顶点此处为面汤顶点数）
    report(progress, STAGE_PARSE, 96,
           "三角面 " + fmtCount(static_cast<long long>(out.triangles)) +
           " · 顶点 " + fmtCount(static_cast<long long>(out.positions.size() / 3)));
    return true;
}

// 把网格按**当前（毫米）坐标**重写成二进制 STL。
// 用途：单位识别把「米建模」的模型 ×1000 后，必须让**切片用的那份文件**也变成毫米 ——
// 预览几何走 NAPI 回传，而内核切片是直接读文件的，两处不一致就会出现「预览正常、切片还是 0.1mm」。
// 只对 .stl 调用（其他格式不能改写成 STL，扩展名与内容不符会让内核按原格式解析直接失败）。
static bool writeBinaryStlMm(const std::string& path, const MeshArrays& m)
{
    const size_t tri = m.indices.empty() ? (m.positions.size() / 9) : (m.indices.size() / 3);
    if (tri == 0) {
        return false;
    }
    const size_t vCount = m.positions.size() / 3;
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) {
        return false;
    }
    char header[80] = { 0 };
    std::memcpy(header, "BLHM studio: coordinates normalized to mm", 42);
    f.write(header, sizeof(header));
    const uint32_t n = static_cast<uint32_t>(tri);
    f.write(reinterpret_cast<const char*>(&n), sizeof(n));
    for (size_t t = 0; t < tri; t++) {
        float v[9];
        for (int k = 0; k < 3; k++) {
            size_t vi = m.indices.empty() ? (t * 3 + static_cast<size_t>(k))
                                          : static_cast<size_t>(m.indices[t * 3 + static_cast<size_t>(k)]);
            if (vi >= vCount) {
                return false;
            }
            v[k * 3 + 0] = m.positions[vi * 3 + 0];
            v[k * 3 + 1] = m.positions[vi * 3 + 1];
            v[k * 3 + 2] = m.positions[vi * 3 + 2];
        }
        const float ux = v[3] - v[0], uy = v[4] - v[1], uz = v[5] - v[2];
        const float wx = v[6] - v[0], wy = v[7] - v[1], wz = v[8] - v[2];
        float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
        const float l = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (l > 1e-12f) { nx /= l; ny /= l; nz /= l; } else { nx = 0.0f; ny = 1.0f; nz = 0.0f; }
        const float rec[12] = { nx, ny, nz, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] };
        f.write(reinterpret_cast<const char*>(rec), sizeof(rec));
        const uint16_t attr = 0;
        f.write(reinterpret_cast<const char*>(&attr), sizeof(attr));
    }
    return static_cast<bool>(f);
}

bool parseFile(const std::string& path, MeshArrays& out, const MeshProgressFn& progress)
{
    std::string lower(path);
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    bool isStep = (lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".stp") == 0) ||
                  (lower.size() > 5 && lower.compare(lower.size() - 5, 5, ".step") == 0);
    if (isStep) {
        // STEP 的解析在 OCCT 内部（BRepMesh 三角化），无法逐三角面回调，只报起止
        report(progress, STAGE_PARSE, 8, "STEP 解析（OCCT BRepMesh）· 请稍候");
    }
    // 统一入口：STEP 走 OCCT 模块，其余走 STL/OBJ，两者都产出同样的无索引面汤
    bool ok = isStep ? BambuStep::parseStep(path, out) : parseStlObj(path, out, progress);
    if (ok) {
        if (isStep) {
            report(progress, STAGE_PARSE, 96,
                   "三角面 " + fmtCount(static_cast<long long>(out.triangles)) +
                   " · 顶点 " + fmtCount(static_cast<long long>(out.positions.size() / 3)));
        }
        // 1) 超预算才做聚类简化（兜底，质量损失大，只对超大模型生效）
        decimatePreview(out, kPreviewMaxTriangles, progress);
        // 2) 焊接 + 索引化（不改变几何形状，只消除 STL 的重复顶点，内存占用降到约 1/6）
        weldVertices(out, progress);
        // 3) 单位识别命中（米 → 毫米）：把切片/打印用的那份 .stl 也重写成毫米坐标。
        //    预览走 NAPI 回传（已是毫米），内核切片直接读文件 —— 不重写就会「预览正常、切片 0.1mm」。
        if (out.unitScale != 1.0f) {
            const bool isStl = (lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".stl") == 0);
            bool rewritten = false;
            if (isStl) {
                rewritten = writeBinaryStlMm(path, out);
            }
            BambuMqtt::addLog("renderer: unit scale x" + std::to_string(static_cast<int>(out.unitScale)) +
                              (rewritten ? " (stl rewritten to mm)" : " (file not rewritten)"));
        }
    }
    // hop2：weldVertices 已返回，parseFile 即将 return（成功 / 失败都在这里汇合）
    {
        const std::string stamp = LoadDlgStamp("2", "parseFile-end");
        OH_LOG_INFO(LOG_APP,
                    "LoadDlg %{public}s ok=%{public}d tris=%{public}d positions=%{public}d indices=%{public}d",
                    stamp.c_str(), ok ? 1 : 0, out.triangles,
                    static_cast<int>(out.positions.size()), static_cast<int>(out.indices.size()));
    }
    return ok;
}

MeshArrays buildBedMesh()
{
    MeshArrays m;
    int vertexCount = BedData::kBedTriangles * 3;
    m.positions.assign(BedData::kBedPositions, BedData::kBedPositions + vertexCount * 3);
    m.normals.assign(BedData::kBedNormals, BedData::kBedNormals + vertexCount * 3);
    m.triangles = BedData::kBedTriangles;
    m.ok = true;
    return m;
}

// 从 bed_model 文件名（"bbl-3dp-H2D.stl"）或简写（"H2D"）里取出板模型短键，
// 再用它到 BambuMesh::BedModels::kBedModels 里找开源板网格。找不到返回 nullptr。
static const BambuMesh::BedModels::BedModel* findBedModel(const std::string& bedModel)
{
    std::string key = bedModel;
    // 去目录 + 去扩展名
    const size_t slash = key.find_last_of("/\\");
    if (slash != std::string::npos)
        key = key.substr(slash + 1);
    const size_t dot = key.find_last_of('.');
    if (dot != std::string::npos)
        key = key.substr(0, dot);
    // 去 "bbl-3dp-" 前缀
    const std::string prefix = "bbl-3dp-";
    if (key.compare(0, prefix.size(), prefix) == 0)
        key = key.substr(prefix.size());
    if (key.empty())
        return nullptr;

    for (int i = 0; i < BambuMesh::BedModels::kBedModelCount; i++) {
        const BambuMesh::BedModels::BedModel& bm = BambuMesh::BedModels::kBedModels[i];
        if (key == bm.key)
            return &bm;
    }
    return nullptr;
}

bool buildBedMeshFor(const std::string& bedModel, MeshArrays& out)
{
    const BambuMesh::BedModels::BedModel* bm = findBedModel(bedModel);
    if (bm == nullptr)
        return false;
    const int vertexCount = bm->triangles * 3;
    out.positions.assign(bm->positions, bm->positions + static_cast<size_t>(vertexCount) * 3);
    out.normals.assign(bm->normals, bm->normals + static_cast<size_t>(vertexCount) * 3);
    out.triangles = bm->triangles;
    out.size[0] = bm->width;
    out.size[1] = bm->height;
    out.ok = true;
    return true;
}

bool bedModelSize(const std::string& bedModel, float& width, float& height)
{
    const BambuMesh::BedModels::BedModel* bm = findBedModel(bedModel);
    if (bm == nullptr)
        return false;
    width = bm->width;
    height = bm->height;
    return true;
}

bool bedModelBBox(const std::string& bedModel, float& minX, float& minY, float& maxX, float& maxY)
{
    const BambuMesh::BedModels::BedModel* bm = findBedModel(bedModel);
    if (bm == nullptr)
        return false;
    minX = bm->bboxMinX;
    minY = bm->bboxMinY;
    maxX = bm->bboxMinX + bm->width;
    maxY = bm->bboxMinY + bm->height;
    return true;
}

void buildLogoMesh(MeshArrays& light, MeshArrays& dark)
{
    // logo 是平面（贴托盘），法线统一朝 +Z
    auto fillNormals = [](MeshArrays& m, int triCount) {
        m.normals.assign(static_cast<size_t>(triCount) * 9, 0.0f);
        for (int i = 0; i < triCount * 3; i++) {
            m.normals[i * 3 + 2] = 1.0f;
        }
    };

    int lightVerts = LogoData::kLogoLightTris * 3;
    light.positions.assign(LogoData::kLogoLightPositions, LogoData::kLogoLightPositions + lightVerts * 3);
    light.triangles = LogoData::kLogoLightTris;
    light.ok = true;
    fillNormals(light, LogoData::kLogoLightTris);

    int darkVerts = LogoData::kLogoDarkTris * 3;
    dark.positions.assign(LogoData::kLogoDarkPositions, LogoData::kLogoDarkPositions + darkVerts * 3);
    dark.triangles = LogoData::kLogoDarkTris;
    dark.ok = true;
    fillNormals(dark, LogoData::kLogoDarkTris);
}

} // namespace BambuMesh
