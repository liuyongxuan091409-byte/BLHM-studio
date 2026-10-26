# 第三方组件与许可证（NOTICE）

本仓库自身代码以 **AGPL-3.0** 发布（见 `LICENSE`）。仓库内还分发下列第三方源码/资产，
它们的权利归各自作者，且**优先适用各自的许可证**。许可证全文放在 `LICENSES/`，
或随组件源码放在其目录内。

## 一、随本仓库分发的组件

| 组件 | 版本 / 标识 | 许可证 | 位置 |
| --- | --- | --- | --- |
| Bambu Studio（切片内核 libslic3r 及衍生源码） | `SLIC3R_BUILD_ID = BambuStudio-02.08.02.61` | **AGPL-3.0**（`LICENSES/AGPL-3.0.txt`） | `entry/src/main/cpp/libslic3r/` |
| PrusaSlicer 衍生部分（含于 libslic3r 源码） | — | AGPL-3.0（上游同源） | 同上 |
| Mbed TLS | 3.6.2 | **Apache-2.0**（`LICENSES/Apache-2.0.txt`） | `entry/src/main/cpp/mbedtls/` |
| Eclipse Paho MQTT C | 1.3.13 | **EPL-2.0 或 EDL-1.0（双许可）**（`LICENSES/EPL-2.0.txt`、`LICENSES/EDL-1.0.txt`） | `entry/src/main/cpp/paho/` |
| Boost（header-only 部分） | 见目录内文件 | BSL-1.0（`LICENSES/BSL-1.0.txt`） | `libslic3r/boost/` |
| Eigen | 见目录内 `COPYING.*` | MPL-2.0 为主（`LICENSES/MPL-2.0.txt`） | `libslic3r/eigen/` |
| Clipper / Clipper2 | 见目录内文件 | BSL-1.0 | `libslic3r/clipper/`、`libslic3r/clipper2/` |
| libnest2d | 见 `LICENSE.txt` | LGPL-3.0（`LICENSES/LGPL-3.0.txt`） | `libslic3r/libnest2d/` |
| mcut | 见 `LICENSE.txt`、`LICENSE.GPL.txt` | GPL-3.0 或商业双许可（`LICENSES/GPL-3.0.txt`） | `libslic3r/mcut/` |
| Qhull | 2015 | Qhull 自有许可（见 `COPYING.txt`） | `libslic3r/qhull/` |
| nlohmann/json | 见 `json.hpp` 头部 | MIT（`LICENSES/MIT.txt`） | `libslic3r/nlohmann/` |
| miniz | — | MIT | `libslic3r/miniz/` |
| nanosvg | — | zlib（`LICENSES/zlib.txt`） | `libslic3r/nanosvg/` |
| earcut | 2015 Mapbox | ISC（`LICENSES/ISC.txt`） | `libslic3r/earcut/` |
| libigl | 见 `README.md` | MPL-2.0 | `libslic3r/libigl/` |
| minilzo | — | GPL-2.0（`LICENSES/GPL-2.0.txt`） | `libslic3r/minilzo/` |
| AGG（Anti-Grain Geometry） | 见 `copying` | 以 `libslic3r/agg/copying` 为准 | `libslic3r/agg/` |
| 其余 vendored 小型库（ankerl、fast_float、semver、stb_dxt、tinybvh、glu-libtess、imgui 等） | — | 以各目录内许可文件为准 | `libslic3r/<目录>/` |

> 说明：上表中「以目录内文件为准」的条目，我核对了许可文件是否存在，但未逐字核对每个版本号；
> 若你对外发布，建议按目录内文件逐条复核。ADMesh 代码在 `libslic3r/admesh/`，其许可证文本未随目录保留，
> 上游 ADMesh 为 GPL-2.0，请自行补入。

## 二、构建时链接、但**未**随本仓库分发

以下依赖以预编译静态库形式参与构建（体积大、且多为本地交叉编译产物），仓库不含其源码。
**分发可安装包（.hap）时**，你需要自行满足它们的许可证义务：

| 组件 | 版本 | 许可证 | 用途 |
| --- | --- | --- | --- |
| FFmpeg | 6.1.2 | LGPL-2.1+ / GPL-2.0+（取决于编译选项） | RTSP 拉流、H.264 解码 |
| OpenCASCADE (OCCT) | 7.6 | LGPL-2.1 + 例外条款 | STEP/CAD 读取与三角化 |
| oneTBB | 2021.13 | Apache-2.0 | 内核并行 |
| CGAL | — | LGPL-3.0 / GPL-3.0（按组件） | 几何算法 |
| GMP / MPFR | 6.3.0 / 4.2.1 | LGPL-3.0 | 大数/浮点 |
| nlopt | 2.7.1 | LGPL-2.1+（部分 MIT） | 数值优化 |
| Expat | — | MIT | XML |
| OpenSSL | 1.1.1k | OpenSSL / SSLeay 许可（3.x 起为 Apache-2.0） | 备用的 TLS 实现 |

## 三、商标与名称

Bambu、Bambu Lab、Bambu Studio 及其标识是其权利人的商标/注册标识。
本项目的代码中保留 `SLIC3R_APP_NAME=「BambuStudio」`、`SLIC3R_BUILD_ID=「BambuStudio-02.08.02.61」`，
**目的是让切片内核生成的 G-code 头与 3MF 元数据与上游格式保持一致、可被同一批工具链识别**，
不代表本作品由 Bambu Lab 制作、认可或授权。本仓库不是 Bambu Lab 官方产品。

应用图标等视觉素材沿用了拓竹标识的风格（见 `README.md` 第四节），公开分发前请自行替换。

## 四、资产文件

`entry/src/main/resources/rawfile/` 下的校准试块（`calib/*.3mf`）、HMS 故障码表（`hms_*.json`）、
工艺预设（`fdm_process_common.json`、`slice_preset.json`）来自 Bambu Studio 项目资源，
随 AGPL 源码一并分发；若上游对其另有条款，以你自行判断与上游条款为准。
