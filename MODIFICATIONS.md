# 相对上游的修改说明（AGPL-3.0 §5(a)）

AGPL-3.0 第 5 条 (a) 要求：分发修改版时，必须以显著方式说明**你修改了什么**并**给出相应日期**。
本文件即该声明。修改集中在「把 Bambu Studio 的切片内核移植到 HarmonyOS 并裁掉 GUI」，
**推理算法与 G-code 生成逻辑的主体未改写**。

- 上游：Bambu Studio（`libslic3r` 及 vendored 依赖），内核标识 `SLIC3R_BUILD_ID = BambuStudio-02.08.02.61`
- 修改日期：**2026 年 10 月**（本文件随代码变更同步更新）
- 修改者：本仓库的贡献者（见提交历史）

---

## 一、新增文件（上游不存在）

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/cpp/libslic3r/libslic3r/ohos_slicer_api.hpp` / `.cpp` | HarmonyOS 侧对内核的最小 C++ 接口：预设枚举/选择、切片（带进度回调）、导出、以及导入阶段的 trace 钩子与「多色分 part 首层豁免」开关。刻意只依赖 `<string>`，避免把 Boost/CGAL/Eigen/OCCT 头暴露给 NAPI 层。 |
| `entry/src/main/cpp/libslic3r/libslic3r/ohos_nanosvg_impl.cpp` | nanosvg 的实现 TU。桌面版把这个实现放在 GUI 侧 `src/slic3r/GUI/BitmapCache.cpp`，本项目不含 GUI，故单独补一个 TU，使 SVG 解析（Emboss/形状导入）可用。 |
| `entry/src/main/cpp/libslic3r/libslic3r/ohos_trim_stubs.cpp` | 裁剪桩：① `load_assimp_textured_model` 返回失败（assimp 未交叉编译，相关 CAD 格式在本版不可用）；② `LogSink` 最小桩（加密日志后端依赖 libcurl，与切片无关，日志仍走 boost::log 默认路径）。 |
| `entry/src/main/cpp/libslic3r/CMakeLists.txt` | 裁剪版构建脚本：从构建中移除 wxWidgets GUI、桌面可执行文件、imgui/imguizmo/hidapi；设定 `SLIC3R_APP_NAME`/`SLIC3R_APP_KEY`/`SLIC3R_BUILD_ID` 与上游一致。 |
| `entry/src/main/cpp/libslic3r/cmake/PrecompiledHeader.cmake` | 上游该 CMake 模块未随 libslic3r 一起 vendored，按其行为补写一份。 |
| `entry/src/main/cpp/napi_init.cpp`、`bambu_*.cpp`、`entry/src/main/ets/**` | 应用层：NAPI 桥接、MQTT/FTPS/发现/摄像头/渲染与 ArkTS 界面。**非上游代码**，属原创。 |

## 二、修改的上游文件

| 文件 | 修改内容 |
| --- | --- |
| `libslic3r/Format/bbs_3mf.cpp` | 引入 `ohos_slicer_api.hpp`，在 3MF 导入关键路径插入 `import_trace_stage(...)` 诊断钩子（定位导入崩溃用）。 |
| `libslic3r/Model.cpp` | 同上：引入 trace 钩子。 |
| `libslic3r/GCode.cpp` | 引入 trace 钩子；接入「多色分 part 首层豁免」开关（`allow_empty_initial_layer`）。 |
| `libslic3r/Print.cpp` | **行为变更**：板型/耗材温度不匹配由「阻断切片」改为「只警告」。原因是移动端机型预设与耗材组合更杂，阻断会让用户拿不到任何结果；该差异已在此声明。 |
| `libslic3r/PrintBase.cpp` | 适配 Boost 1.86：不再使用已移除的 `boost::filesystem::change_extension`。 |
| `libslic3r/Shape/TextShape.cpp` | 增加 `HarmonyOS Sans SC` 字体名与字体文件映射。 |
| `libslic3r/slic3r/Utils/ColorSpaceConvert.cpp` | 裁剪 GUI 依赖：移除文件顶部 `#include <wx/colordlg.h>` 及文件末尾依赖 wx 的实现。 |

## 三、明确**未**修改

- 切片几何算法（`Arrange`、`SupportMaterial`、`Fill`、`PerimeterGenerator`、`ClipperUtils` 等）按上游原样编译。
- G-code 生成器的输出结构、`; BambuStudio` 头部与 3MF 元数据键值沿用上游，目的是与同一批工具链/固件保持兼容。

## 四、关于保留上游版本标识

`SLIC3R_APP_NAME = "BambuStudio"`、`SLIC3R_BUILD_ID = "BambuStudio-02.08.02.61"`、`SLIC3R_APP_KEY = "BambuStudio"`
保留原值，原因见 `NOTICE.md` 第三节：内核靠这些字符串产出被固件/切片工具识别的 G-code 头与 3MF 元数据。
这是**兼容性取舍**，不是声称本作品为官方发行版。

## 五、维护方式

后续对上游文件的任何改动，都应在本文件新增一行（文件 / 改动 / 日期），并保持"新增文件"与"修改文件"两张表可追溯。
