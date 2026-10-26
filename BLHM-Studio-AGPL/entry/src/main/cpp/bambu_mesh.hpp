#ifndef BAMBU_MESH_HPP
#define BAMBU_MESH_HPP

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// 纯网格解析模块（无渲染依赖）：STL / OBJ / STEP(OCCT)
// 输出平面浮点数组：positions[3N] / normals[3N] / indices[3T]
// positions / normals 语义为「唯一顶点」（焊接后，索引化）；indices 每 3 个 = 一个三角面。
// 面汤形态（indices 为空）仍是合法输入/输出：三者一致指向同一网格。
// 约定：Z 轴向上、单位 mm、已归一化（XY 居中、底面贴板 z=0）
namespace BambuMesh {

// 载入阶段：与 ArkTS 载入弹窗的阶段链一一对应（见 view/LoadingDialog.ets 的 LOAD_STAGES）
enum MeshStage {
    STAGE_PARSE   = 0,  // 读文件 + STL/OBJ/STEP 解析
    STAGE_WELD    = 1,  // 顶点焊接（容差去重）
    STAGE_NORMALS = 2,  // 折痕角拆平滑组 + 法线重建
    STAGE_UPLOAD  = 3,  // 上传几何（NAPI 返回 + ArkTS 侧建顶点）
    STAGE_THUMB   = 4,  // 生成缩略图（ArkTS 侧）
};

// 载入进度回调：stage 取 MeshStage；percentInStage 0..100；message 人类可读（数字均为真实计数）。
// 可选参数 —— 不传时行为与以前完全一致。
// 注意：回调运行在 NAPI 的 worker 线程上，绝不能在回调里直接调 JS。
using MeshProgressFn = std::function<void(int stage, int percentInStage, const char* message)>;

struct MeshArrays {
    bool ok = false;
    std::string error;
    // triangles / size / positions / normals / indices 表示"最终交给预览"的那份（可能已被抽稀）
    // triangles = 三角面数；positions/normals 为唯一顶点；indices 每 3 个 = 一个三角面
    int triangles = 0;
    float size[3] = { 0, 0, 0 }; // 包围盒尺寸（X/Y/Z）
    // 原始信息：抽稀前的真实面数与真实包围盒尺寸，供 UI 显示（切片始终用原始文件）
    int origTriangles = 0;
    float origSize[3] = { 0, 0, 0 };
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;   // 每 3 个 = 一个三角面，索引到 positions（空 = 无索引面汤）

    // 单位识别：解析出「最大尺寸 < 1mm」的模型判定为**以米建模**（CAD 常见），
    // positions/size 已按 ×1000 换算成毫米；调用方据此提示用户，并把切片用的文件重写成毫米。
    // 正常模型恒为 1。
    float unitScale = 1.0f;

    // 载入统计（供进度日志显示真实数字，由 weldVertices 填写）
    int weldInVerts = 0;             // 焊接前顶点数（面汤顶点数）
    int uniqueVerts = 0;             // 焊接后唯一顶点数（折痕角拆分之前）
    int creaseSplit = 0;             // 折痕角拆分新增的顶点数
    int outVerts = 0;                // 最终输出顶点数（= positions.size() / 3）

    // ---- 需求 4：悬空（朝下）面统计（解析时算一次，属【启发式】，不是切片器级别的精确悬空分析）----
    // 口径：法线指向下方且与「竖直向下」夹角小于阈值的三角面 = 朝下悬空面（排除贴板底面）；
    //       面积占比超过阈值 → 建议加支撑。三个数字都是真实统计值，供 UI 与日志直接使用。
    float overhangRatioPct = 0.0f;          // 朝下悬空面面积 / 全部三角面面积 × 100
    float overhangAngleDeg = 0.0f;          // 判定用到的夹角阈值（度）
    float overhangAreaPctThreshold = 0.0f;  // 面积占比判定阈值（%）
    bool  needsSupport = false;             // 启发式结论：需要支撑
};

// STL（二进制/ASCII）与 OBJ 解析（parseStep 由 bambu_step 提供）
bool parseStlObj(const std::string& path, MeshArrays& out, const MeshProgressFn& progress = {});

// 按扩展名统一入口（.stp/.step → BambuStep(OCCT)，其余 → STL/OBJ）
bool parseFile(const std::string& path, MeshArrays& out, const MeshProgressFn& progress = {});

// 内置开源托盘模型（bbl-3dp-X1.stl）：Z 轴向上、X/Y 已居中、打印面 z=0
MeshArrays buildBedMesh();

// 按机型的打印板模型名返回对应的开源板网格（名称取自各机型 BBL 预设的 bed_model 字段，
// 如 "bbl-3dp-H2D.stl"；也接受简写 "H2D"）。X/Y 已按该板自身包围盒居中、打印面 z=0。
// 找到返回 true 并填 out；未知名称返回 false（调用方应退回默认板，不要编造）。
bool buildBedMeshFor(const std::string& bedModel, MeshArrays& out);

// 板模型自身的包围盒尺寸（mm，STL 原始 X/Y 尺寸）。渲染侧用它把板缩放到机型盘面尺寸。
bool bedModelSize(const std::string& bedModel, float& width, float& height);

// 板模型在【绝对床坐标】里的包围盒（mm）：minX/minY 即该板网格自身的原点（居中前）。
// 渲染侧据此把绝对床坐标（printable_area / extruder_printable_area 真值）映射到
// 与板模型完全相同的坐标系（同一套「先减板模型中心、再按 盘面/板模型 尺寸缩放」映射）。
bool bedModelBBox(const std::string& bedModel, float& minX, float& minY, float& maxX, float& maxY);

// 内置开源 logo（bbl-3dp-logo.svg）：light=浅灰主体，dark=深灰笔画（Z 轴向上、X/Y 已居中）
void buildLogoMesh(MeshArrays& light, MeshArrays& dark);

} // namespace BambuMesh

#endif // BAMBU_MESH_HPP
