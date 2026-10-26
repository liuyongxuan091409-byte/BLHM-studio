#include "bambu_renderer.hpp"
#include "bambu_mqtt.hpp"
#include "bambu_mesh.hpp"

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <vector>

// =============================================================================
// 3D 渲染器：EGL + GLES3，事件驱动重绘（无渲染线程，静态场景省电）
// 约定：世界坐标 Z 轴向上（与切片软件一致），单位 mm，X1C 构建板 256x256
// =============================================================================
namespace BambuRenderer {

namespace {

// ---- EGL 上下文 ----
EGLDisplay g_display = EGL_NO_DISPLAY;
EGLContext g_context = EGL_NO_CONTEXT;
EGLSurface g_surface = EGL_NO_SURFACE;
EGLConfig g_config = nullptr;
uint32_t g_width = 1;
uint32_t g_height = 1;
bool g_glReady = false;

// ---- GL 对象 ----
GLuint g_prog = 0;
GLint g_locMVP = -1, g_locModel = -1, g_locColor = -1, g_locMode = -1;
GLuint g_vaoGrid = 0, g_vboGrid = 0;
int g_gridVerts = 0;
GLuint g_vaoModel = 0, g_vboModel = 0;
int g_modelVerts = 0;
float g_modelCenter[3] = { 0, 0, 0 }; // 模型包围盒中心（绘制时平移到原点）

// ---- G-code 路径 ----
GLuint g_vaoGcode = 0, g_vboGcode = 0;
int g_gcodeVerts = 0;
std::vector<int> g_gcodeBatches;   // 三元组 {slot, first, count}
bool g_gcodeMode = false;

// 调色板：下标 0 = 下层鬼影，1..10 与 ArkTS 端 ROLE_COLOR 一一对应
const float kGcodePalette[][3] = {
    { 0.35f, 0.41f, 0.47f }, // 0 鬼影
    { 1.00f, 0.70f, 0.00f }, // 1 外壁  #FFB300
    { 1.00f, 0.44f, 0.26f }, // 2 内壁  #FF7043
    { 0.31f, 0.76f, 0.97f }, // 3 稀疏填充 #4FC3F7
    { 0.15f, 0.65f, 0.60f }, // 4 实心填充 #26A69A
    { 0.94f, 0.33f, 0.31f }, // 5 顶面  #EF5350
    { 0.67f, 0.28f, 0.74f }, // 6 底面  #AB47BC
    { 0.40f, 0.73f, 0.42f }, // 7 桥接  #66BB6A
    { 0.55f, 0.43f, 0.39f }, // 8 支撑  #8D6E63
    { 0.47f, 0.56f, 0.61f }, // 9 间隙填充 #78909C
    { 0.74f, 0.74f, 0.74f }  // 10 其他 #BDBDBD
};
const int kGcodePaletteSize = static_cast<int>(sizeof(kGcodePalette) / sizeof(kGcodePalette[0]));

// ---- 相机（轨道）----
float g_yaw = 0.75f;      // 方位角（弧度）
float g_pitch = 0.52f;    // 仰角
float g_dist = 420.0f;    // 到目标距离
float g_target[3] = { 0, 0, 40 };

// ---- 模型暂存（worker 线程解析 → GL 线程上传）----
struct StagedMesh {
    std::vector<float> vertices; // pos3 + normal3 交错
    int triangles = 0;
    float size[3] = { 0, 0, 0 };
    float center[3] = { 0, 0, 0 };
    bool valid = false;
};
StagedMesh g_staged;
std::mutex g_stagedMutex;

// G-code 顶点暂存：JS 线程写入 → GL 线程上传。
// 与模型不同，这里 upload 后**不清 valid**：表面重建（切页/窗口变化）时要能重新上传。
struct StagedGcode {
    std::vector<float> verts;
    std::vector<int>   batches;
    bool valid = false;
};
StagedGcode g_stagedGcode;
std::mutex g_stagedGcodeMutex;

// ---------------------------------------------------------------------------
// 极简列主序 4x4 矩阵
// ---------------------------------------------------------------------------
struct Mat4 { float m[16]; };

Mat4 matIdentity()
{
    Mat4 r;
    memset(r.m, 0, sizeof(r.m));
    r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f;
    return r;
}

Mat4 matMul(const Mat4& a, const Mat4& b)
{
    Mat4 r;
    for (int c = 0; c < 4; c++) {
        for (int row = 0; row < 4; row++) {
            float s = 0;
            for (int k = 0; k < 4; k++) {
                s += a.m[k * 4 + row] * b.m[c * 4 + k];
            }
            r.m[c * 4 + row] = s;
        }
    }
    return r;
}

Mat4 matTranslate(float x, float y, float z)
{
    Mat4 r = matIdentity();
    r.m[12] = x; r.m[13] = y; r.m[14] = z;
    return r;
}

Mat4 matPerspective(float fovyRad, float aspect, float znear, float zfar)
{
    Mat4 r;
    memset(r.m, 0, sizeof(r.m));
    float f = 1.0f / std::tan(fovyRad * 0.5f);
    r.m[0] = f / aspect;
    r.m[5] = f;
    r.m[10] = (zfar + znear) / (znear - zfar);
    r.m[11] = -1.0f;
    r.m[14] = 2.0f * zfar * znear / (znear - zfar);
    return r;
}

Mat4 matLookAt(float ex, float ey, float ez, float cx, float cy, float cz,
               float ux, float uy, float uz)
{
    // f = normalize(center - eye)
    float fx = cx - ex, fy = cy - ey, fz = cz - ez;
    float fl = std::sqrt(fx * fx + fy * fy + fz * fz);
    fx /= fl; fy /= fl; fz /= fl;
    // s = normalize(cross(f, up))
    float sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
    float sl = std::sqrt(sx * sx + sy * sy + sz * sz);
    sx /= sl; sy /= sl; sz /= sl;
    // u = cross(s, f)
    float tx = sy * fz - sz * fy, ty = sz * fx - sx * fz, tz = sx * fy - sy * fx;
    Mat4 r;
    r.m[0] = sx; r.m[4] = sy; r.m[8] = sz;  r.m[12] = -(sx * ex + sy * ey + sz * ez);
    r.m[1] = tx; r.m[5] = ty; r.m[9] = tz;  r.m[13] = -(tx * ex + ty * ey + tz * ez);
    r.m[2] = -fx; r.m[6] = -fy; r.m[10] = -fz; r.m[14] = (fx * ex + fy * ey + fz * ez);
    r.m[3] = 0; r.m[7] = 0; r.m[11] = 0; r.m[15] = 1.0f;
    return r;
}

// ---------------------------------------------------------------------------
// 着色器
// ---------------------------------------------------------------------------
const char* kVertSrc = R"(#version 300 es
layout(location=0) in vec3 aPos;
layout(location=1) in vec3 aNormal;
uniform mat4 uMVP;
uniform mat4 uModel;
out vec3 vNormal;
void main() {
    vNormal = mat3(uModel) * aNormal;
    gl_Position = uMVP * vec4(aPos, 1.0);
})";

const char* kFragSrc = R"(#version 300 es
precision mediump float;
in vec3 vNormal;
uniform vec3 uColor;
uniform int uMode; // 0=模型(光照) 1=网格(平色)
out vec4 oColor;
void main() {
    if (uMode == 1) { oColor = vec4(uColor, 1.0); return; }
    vec3 n = normalize(vNormal);
    float d1 = max(dot(n, normalize(vec3(0.5, 0.4, 0.8))), 0.0);
    float d2 = max(dot(n, normalize(vec3(-0.5, -0.3, 0.4))), 0.0);
    vec3 c = uColor * (0.35 + d1 * 0.65 + d2 * 0.25);
    oColor = vec4(c, 1.0);
})";

GLuint compileShader(GLenum type, const char* src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        BambuMqtt::addLog(std::string("renderer: shader fail ") + log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

bool buildProgram()
{
    GLuint vs = compileShader(GL_VERTEX_SHADER, kVertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, kFragSrc);
    if (vs == 0 || fs == 0) { return false; }
    g_prog = glCreateProgram();
    glAttachShader(g_prog, vs);
    glAttachShader(g_prog, fs);
    glLinkProgram(g_prog);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(g_prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        BambuMqtt::addLog("renderer: link fail");
        return false;
    }
    g_locMVP = glGetUniformLocation(g_prog, "uMVP");
    g_locModel = glGetUniformLocation(g_prog, "uModel");
    g_locColor = glGetUniformLocation(g_prog, "uColor");
    g_locMode = glGetUniformLocation(g_prog, "uMode");
    return true;
}

// 构建板网格：256x256，32mm 一格 + 边框（位置 + 单位法线）
void buildGrid()
{
    const float S = 256.0f;  // X1C 平台边长
    const float STEP = 32.0f;
    std::vector<float> v;
    auto addLine = [&](float x0, float y0, float x1, float y1) {
        v.insert(v.end(), { x0, y0, 0, 0, 0, 1 });
        v.insert(v.end(), { x1, y1, 0, 0, 0, 1 });
    };
    for (float p = 0; p <= S + 0.01f; p += STEP) {
        addLine(p, 0, p, S);
        addLine(0, p, S, p);
    }
    g_gridVerts = static_cast<int>(v.size() / 6);

    if (g_vaoGrid == 0) { glGenVertexArrays(1, &g_vaoGrid); }
    if (g_vboGrid == 0) { glGenBuffers(1, &g_vboGrid); }
    glBindVertexArray(g_vaoGrid);
    glBindBuffer(GL_ARRAY_BUFFER, g_vboGrid);
    glBufferData(GL_ARRAY_BUFFER, v.size() * sizeof(float), v.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (void*)12);
    glBindVertexArray(0);
}

// ---------------------------------------------------------------------------
// 绘制
// ---------------------------------------------------------------------------
// G-code 顶点上传（顶点布局只有位置，12 字节；uMode=1 不看 normal）
void uploadStagedGcode()
{
    std::lock_guard<std::mutex> lock(g_stagedGcodeMutex);
    if (!g_stagedGcode.valid || g_stagedGcode.verts.empty()) {
        g_gcodeVerts = 0;
        return;
    }
    if (g_vaoGcode == 0) { glGenVertexArrays(1, &g_vaoGcode); }
    if (g_vboGcode == 0) { glGenBuffers(1, &g_vboGcode); }
    glBindVertexArray(g_vaoGcode);
    glBindBuffer(GL_ARRAY_BUFFER, g_vboGcode);
    glBufferData(GL_ARRAY_BUFFER, g_stagedGcode.verts.size() * sizeof(float),
                 g_stagedGcode.verts.data(), GL_DYNAMIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, (void*)0);
    // 顶点只有位置：必须禁用 normal 属性，否则会按默认步长读到越界内存
    glDisableVertexAttribArray(1);
    glBindVertexArray(0);
    g_gcodeVerts = static_cast<int>(g_stagedGcode.verts.size() / 3);
    g_gcodeBatches = g_stagedGcode.batches;
}

void drawGcode(const Mat4& pv)
{
    if (g_gcodeVerts <= 0 || g_gcodeBatches.empty()) { return; }
    Mat4 gm = matTranslate(-128.0f, -128.0f, 0);   // 与构建板网格同一坐标系
    Mat4 mvp = matMul(pv, gm);
    glUniformMatrix4fv(g_locMVP, 1, GL_FALSE, mvp.m);
    glUniformMatrix4fv(g_locModel, 1, GL_FALSE, gm.m);
    glUniform1i(g_locMode, 1);
    glBindVertexArray(g_vaoGcode);
    for (size_t i = 0; i + 2 < g_gcodeBatches.size(); i += 3) {
        int slot  = g_gcodeBatches[i];
        int first = g_gcodeBatches[i + 1];
        int count = g_gcodeBatches[i + 2];
        if (slot < 0 || slot >= kGcodePaletteSize) { continue; }
        if (first < 0 || count <= 0 || first + count > g_gcodeVerts) { continue; }
        glUniform3f(g_locColor, kGcodePalette[slot][0], kGcodePalette[slot][1], kGcodePalette[slot][2]);
        glDrawArrays(GL_LINES, first, count);
    }
}

void draw()
{
    if (!g_glReady || g_surface == EGL_NO_SURFACE || g_prog == 0) {
        return;
    }
    glViewport(0, 0, g_width, g_height);
    glClearColor(0.055f, 0.055f, 0.071f, 1.0f); // #0E0E12
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);

    float aspect = static_cast<float>(g_width) / static_cast<float>(g_height);
    Mat4 proj = matPerspective(40.0f * 3.14159265f / 180.0f, aspect, 5.0f, 8000.0f);
    float eyeX = g_target[0] + g_dist * std::cos(g_pitch) * std::cos(g_yaw);
    float eyeY = g_target[1] + g_dist * std::cos(g_pitch) * std::sin(g_yaw);
    float eyeZ = g_target[2] + g_dist * std::sin(g_pitch);
    Mat4 view = matLookAt(eyeX, eyeY, eyeZ, g_target[0], g_target[1], g_target[2], 0, 0, 1);
    Mat4 pv = matMul(proj, view);

    glUseProgram(g_prog);

    // 网格（平台以中心为原点：平移 -128）
    if (g_gridVerts > 0) {
        Mat4 gridModel = matTranslate(-128.0f, -128.0f, 0);
        Mat4 mvp = matMul(pv, gridModel);
        glUniformMatrix4fv(g_locMVP, 1, GL_FALSE, mvp.m);
        glUniformMatrix4fv(g_locModel, 1, GL_FALSE, gridModel.m);
        glUniform3f(g_locColor, 0.16f, 0.17f, 0.20f);
        glUniform1i(g_locMode, 1);
        glBindVertexArray(g_vaoGrid);
        glDrawArrays(GL_LINES, 0, g_gridVerts);
    }

    // 切片预览模式：只画路径（模型实体留着会遮挡路径）
    if (g_gcodeMode) {
        drawGcode(pv);
    } else if (g_modelVerts > 0) {
        Mat4 model = matTranslate(-g_modelCenter[0], -g_modelCenter[1], -g_modelCenter[2]);
        Mat4 mvp = matMul(pv, model);
        glUniformMatrix4fv(g_locMVP, 1, GL_FALSE, mvp.m);
        glUniformMatrix4fv(g_locModel, 1, GL_FALSE, model.m);
        glUniform3f(g_locColor, 0.95f, 0.45f, 0.13f); // Bambu 橙
        glUniform1i(g_locMode, 0);
        glBindVertexArray(g_vaoModel);
        glDrawArrays(GL_TRIANGLES, 0, g_modelVerts);
    }
    glBindVertexArray(0);
    eglSwapBuffers(g_display, g_surface);
}

void autoFit()
{
    // 按模型尺寸自动取景
    std::lock_guard<std::mutex> lock(g_stagedMutex);
    if (!g_staged.valid) { return; }
    float maxDim = std::max(g_staged.size[0], std::max(g_staged.size[1], g_staged.size[2]));
    if (maxDim < 1) { maxDim = 100; }
    g_dist = maxDim * 1.9f + 40.0f;
    g_target[0] = 0;
    g_target[1] = 0;
    g_target[2] = g_staged.size[2] * 0.35f;
    g_yaw = 0.75f;
    g_pitch = 0.52f;
}

} // namespace

// ---------------------------------------------------------------------------
// 表面生命周期
// ---------------------------------------------------------------------------
void onSurfaceCreated(void* window)
{
    onSurfaceDestroyed(); // 上下文可能残留，先清场

    g_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_display == EGL_NO_DISPLAY) { BambuMqtt::addLog("renderer: no egl display"); return; }
    if (!eglInitialize(g_display, nullptr, nullptr)) { BambuMqtt::addLog("renderer: egl init fail"); return; }

    EGLint cfgAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    EGLint num = 0;
    if (!eglChooseConfig(g_display, cfgAttribs, &g_config, 1, &num) || num < 1) {
        BambuMqtt::addLog("renderer: no egl config");
        return;
    }
    EGLint ctxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g_context = eglCreateContext(g_display, g_config, EGL_NO_CONTEXT, ctxAttribs);
    if (g_context == EGL_NO_CONTEXT) { BambuMqtt::addLog("renderer: ctx fail"); return; }

    g_surface = eglCreateWindowSurface(g_display, g_config,
        reinterpret_cast<EGLNativeWindowType>(reinterpret_cast<uintptr_t>(window)), nullptr);
    if (g_surface == EGL_NO_SURFACE) { BambuMqtt::addLog("renderer: surface fail"); return; }
    if (!eglMakeCurrent(g_display, g_surface, g_surface, g_context)) {
        BambuMqtt::addLog("renderer: makecurrent fail");
        return;
    }

    g_vaoGrid = g_vboGrid = g_vaoModel = g_vboModel = g_prog = 0; // 新上下文从零开始
    g_vaoGcode = g_vboGcode = 0;
    g_modelVerts = 0;
    g_gcodeVerts = 0;
    if (!buildProgram()) { return; }
    buildGrid();
    g_glReady = true;
    BambuMqtt::addLog("renderer: gl ready");
    uploadStagedModel(); // 若模型先于表面加载
    uploadStagedGcode(); // 若切片路径先于表面加载（切页/切换模式回来时）
    resetView();         // 自动取景 + 首绘
}

void onSurfaceChanged(void* window, int width, int height)
{
    (void)window;
    if (width > 0) { g_width = static_cast<uint32_t>(width); }
    if (height > 0) { g_height = static_cast<uint32_t>(height); }
    draw();
}

void onSurfaceDestroyed()
{
    g_glReady = false;
    if (g_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_surface != EGL_NO_SURFACE) { eglDestroySurface(g_display, g_surface); }
        if (g_context != EGL_NO_CONTEXT) { eglDestroyContext(g_display, g_context); }
        eglTerminate(g_display);
    }
    g_surface = EGL_NO_SURFACE;
    g_context = EGL_NO_CONTEXT;
    g_display = EGL_NO_DISPLAY;
}

// ---------------------------------------------------------------------------
// 相机控制
// ---------------------------------------------------------------------------
void rotate(float dx, float dy)
{
    g_yaw += dx * 0.008f;
    g_pitch = std::max(0.05f, std::min(1.45f, g_pitch + dy * 0.008f));
    draw();
}

void zoom(float factor)
{
    if (factor <= 0.01f || factor > 100.0f) { return; }
    g_dist = std::max(15.0f, std::min(5000.0f, g_dist / factor));
    draw();
}

void pan(float dx, float dy)
{
    // 沿相机坐标系平移：right=(-sinYaw, cosYaw, 0)，up=right×forward
    float rx = -std::sin(g_yaw), ry = std::cos(g_yaw);
    // forward = normalize(target-eye)（指向屏幕内）
    float f0 = -std::cos(g_pitch) * std::cos(g_yaw);
    float f1 = -std::cos(g_pitch) * std::sin(g_yaw);
    float f2 = -std::sin(g_pitch);
    // up = cross(right, forward)
    float ux = ry * f2 - 0 * f1;
    float uy = 0 * f0 - rx * f2;
    float uz = rx * f1 - ry * f0;
    float k = g_dist * 0.0016f; // 屏幕像素 → 世界距离比例
    g_target[0] -= (rx * dx - ux * dy) * k;
    g_target[1] -= (ry * dx - uy * dy) * k;
    g_target[2] -= (uz * dy) * -k;
    draw();
}

void resetView()
{
    autoFit();
    draw();
}

// ---------------------------------------------------------------------------
// G-code 路径（3D 切片预览）：按颜色分组的线段，直接 push 给渲染器
// ---------------------------------------------------------------------------
void stageGcodeLines(const std::vector<float>& verts, const std::vector<int>& batches)
{
    {
        std::lock_guard<std::mutex> lock(g_stagedGcodeMutex);
        g_stagedGcode.verts = verts;
        g_stagedGcode.batches = batches;
        g_stagedGcode.valid = !verts.empty();
    }
    if (g_glReady) {
        uploadStagedGcode();
        draw();
    }
}

void setGcodeMode(bool on)
{
    g_gcodeMode = on;
    draw();
}

void clearGcodeLines()
{
    {
        std::lock_guard<std::mutex> lock(g_stagedGcodeMutex);
        g_stagedGcode.verts.clear();
        g_stagedGcode.batches.clear();
        g_stagedGcode.valid = false;
    }
    g_gcodeVerts = 0;
    g_gcodeBatches.clear();
    draw();
}

// ---------------------------------------------------------------------------
// 模型解析入口：委托 BambuMesh 纯解析模块（STL/OBJ/STEP 共用），交错排列后入暂存区
// ---------------------------------------------------------------------------
bool parseModelFile(const std::string& path, ModelInfo& info)
{
    BambuMesh::MeshArrays arr;
    if (!BambuMesh::parseFile(path, arr)) {
        info.ok = false;
        info.error = arr.error.empty() ? "解析失败" : arr.error;
        return false;
    }
    // 平面数组 → 交错数组（pos3+normal3），供 GPU 上传
    std::vector<float> interleaved;
    interleaved.reserve(arr.positions.size() * 2);
    size_t n = arr.positions.size() / 3;
    for (size_t i = 0; i < n; i++) {
        interleaved.push_back(arr.positions[i * 3 + 0]);
        interleaved.push_back(arr.positions[i * 3 + 1]);
        interleaved.push_back(arr.positions[i * 3 + 2]);
        interleaved.push_back(arr.normals[i * 3 + 0]);
        interleaved.push_back(arr.normals[i * 3 + 1]);
        interleaved.push_back(arr.normals[i * 3 + 2]);
    }
    stageMesh(std::move(interleaved), arr.triangles, info);
    return info.ok;
}

bool uploadStagedModel()
{
    if (!g_glReady) { return false; }
    std::lock_guard<std::mutex> lock(g_stagedMutex);
    if (!g_staged.valid || g_staged.vertices.empty()) { return false; }

    if (g_vaoModel == 0) { glGenVertexArrays(1, &g_vaoModel); }
    if (g_vboModel == 0) { glGenBuffers(1, &g_vboModel); }
    glBindVertexArray(g_vaoModel);
    glBindBuffer(GL_ARRAY_BUFFER, g_vboModel);
    glBufferData(GL_ARRAY_BUFFER, g_staged.vertices.size() * sizeof(float),
                 g_staged.vertices.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (void*)12);
    glBindVertexArray(0);
    g_modelVerts = static_cast<int>(g_staged.vertices.size() / 6);
    g_modelCenter[0] = g_staged.center[0];
    g_modelCenter[1] = g_staged.center[1];
    g_modelCenter[2] = g_staged.center[2];

    char buf[96];
    snprintf(buf, sizeof(buf), "renderer: model %d tris, %.1f x %.1f x %.1f mm",
             g_staged.triangles, g_staged.size[0], g_staged.size[1], g_staged.size[2]);
    BambuMqtt::addLog(buf);
    return true;
}

void stageMesh(std::vector<float> vertices, int triCount, ModelInfo& info)
{
    if (vertices.empty()) {
        info.ok = false;
        info.error = "空网格";
        return;
    }
    // 归一化：包围盒统计 → XY 居中、底面贴板（z 最小=0）
    float lo[3] = { 1e30f, 1e30f, 1e30f };
    float hi[3] = { -1e30f, -1e30f, -1e30f };
    size_t n = vertices.size() / 6;
    for (size_t i = 0; i < n; i++) {
        for (int d = 0; d < 3; d++) {
            float v = vertices[i * 6 + d];
            lo[d] = std::min(lo[d], v);
            hi[d] = std::max(hi[d], v);
        }
    }
    float cx = (lo[0] + hi[0]) * 0.5f;
    float cy = (lo[1] + hi[1]) * 0.5f;
    for (size_t i = 0; i < n; i++) {
        vertices[i * 6 + 0] -= cx;
        vertices[i * 6 + 1] -= cy;
        vertices[i * 6 + 2] -= lo[2];
    }

    StagedMesh m;
    m.vertices = std::move(vertices);
    m.triangles = triCount;   // 解析层已焊接索引化：面数由调用方传入，不再用顶点数 n/3 反推
    m.size[0] = hi[0] - lo[0];
    m.size[1] = hi[1] - lo[1];
    m.size[2] = hi[2] - lo[2];
    m.valid = true;

    {
        std::lock_guard<std::mutex> lock(g_stagedMutex);
        g_staged = std::move(m);
    }

    info.ok = true;
    info.triangles = triCount;
    info.sizeX = hi[0] - lo[0];
    info.sizeY = hi[1] - lo[1];
    info.sizeZ = hi[2] - lo[2];
}

} // namespace BambuRenderer
