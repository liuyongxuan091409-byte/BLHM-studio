#ifndef BAMBU_RENDERER_HPP
#define BAMBU_RENDERER_HPP

#include <string>
#include <vector>

// 3D 模型渲染器：XComponent + EGL/GLES3
// 准备页平台视图：STL/OBJ/STEP 模型加载、轨道相机（旋转/缩放/平移）、构建板网格
namespace BambuRenderer {

// 模型加载结果（返回给 ArkTS 显示）
struct ModelInfo {
    bool ok = false;
    std::string error;
    int triangles = 0;
    float sizeX = 0;
    float sizeY = 0;
    float sizeZ = 0;
};

// ---- XComponent 表面生命周期（native 回调转发）----
void onSurfaceCreated(void* window);
void onSurfaceChanged(void* window, int width, int height);
void onSurfaceDestroyed();

// ---- 模型加载（两段式：worker 线程解析 → GL 线程上传）----
// 解析文件到暂存区（可在任意线程调用）
bool parseModelFile(const std::string& path, ModelInfo& info);
// 把暂存区网格上传 GPU 并重置视角（必须在 GL 线程调用）
bool uploadStagedModel();

// 网格归一化并入暂存区（XY 居中、底面贴板），并填 ModelInfo。
// 供 STL/OBJ 与 STEP(OCCT) 两条解析路径共用，可在任意线程调用。
// triCount 为三角面数（解析层已焊接索引化，顶点数 != triCount*3，不能再用 n/3 反推）
void stageMesh(std::vector<float> vertices, int triCount, ModelInfo& info);

// ---- 相机控制（每次调用后自动重绘）----
void rotate(float dx, float dy);
void zoom(float factor);   // factor>1 放大
void pan(float dx, float dy);
void resetView();

// ---- G-code 路径（3D 切片预览）----
// verts  : [x,y,z] 顶点序列，世界坐标 mm（床角为原点；绘制时整体平移 -128,-128，
//          与构建板网格同一坐标系）→ 与 STL 切片时的坐标完全对应
// batches: 三元组 {调色板下标, first, count}。顶点按颜色分组连续排布，
//          绘制时每批一次 glDrawArrays(GL_LINES, first, count)，无需改 shader。
//          调色板下标：0 = 下层鬼影灰；1..10 = 与 ArkTS 端 ROLE_COLOR 一一对应
void stageGcodeLines(const std::vector<float>& verts, const std::vector<int>& batches);
void setGcodeMode(bool on);        // true：只画网格 + 路径（隐藏模型实体）
void clearGcodeLines();

} // namespace BambuRenderer

#endif // BAMBU_RENDERER_HPP
