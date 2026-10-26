# =============================================================================
#  BambuStudio 切片内核（裁剪版）—— 顶层构建脚本
#  用途：编译纯切片核心静态库 libslic3r 及其 in-tree 依赖。
#  已移除：wxWidgets GUI、BambuStudio 桌面可执行文件、imgui/imguizmo/hidapi。
#
#  最小可切片管线（当前目标）：
#    STL/3MF 导入 -> 网格 -> 切片 -> Gcode 输出
#
#  布尔运算策略：使用 MCUT（SLIC3R_ALLOW_MCUT_BOOLEAN=ON），不依赖 OpenMeshCraft。
#
#  ⚠ 外部依赖（需预先为 OpenHarmony 交叉编译，并放入 CMAKE_PREFIX_PATH）：
#    硬依赖（最小管线仍需）：
#      Boost(>=1.83, 组件 system/filesystem/thread/log/locale/regex/chrono/atomic/date_time/iostreams)
#      TBB           —— 并行
#      CGAL + GMP + MPFR —— Voronoi/布尔/三角剖分
#      libnoise      —— 结构模糊皮肤
#    待裁剪项（最小管线先跳过，后续按需补回）：
#      OCCT(STEP)  OpenCV(纹理)  assimp(额外格式)  OpenVDB  NLopt
# =============================================================================
cmake_minimum_required(VERSION 3.13)
project(bambu_slicer_core)

# ---- 版本标识：必须与对照用的桌面版 Bambu Studio 完全一致 ----
#   SLIC3R_APP_NAME → G-code 首行 "; BambuStudio"（Config.cpp 靠它识别自家头）
#   SLIC3R_APP_KEY  → 3MF 元数据 "BambuStudio-02.08.02.61"
#   SLIC3R_VERSION  → 4 段零填充（Bambu 给 semver 打了补丁支持 AA.BB.CC.DD）
set(SLIC3R_APP_NAME "BambuStudio")
set(SLIC3R_APP_KEY  "BambuStudio")
set(SLIC3R_VERSION  "02.08.02.61")
set(SLIC3R_BUILD_ID "BambuStudio-02.08.02.61")
# 源码树无 .git，跳过 git rev-parse，避免 configure 报错
set(BBL_RELEASE_TO_PUBLIC 1)

# BambuStudio 的 cmake/PrecompiledHeader.cmake 没随 libslic3r vendored。
# 我们自带一个等价实现：把 add_precompiled_header() 实现为 -include pchheader.hpp。
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---- 裁剪开关：关闭 GUI 与 OpenMeshCraft，启用 MCUT 布尔 ----
set(SLIC3R_GUI OFF CACHE BOOL "" FORCE)
set(SLIC3R_ENABLE_OPENMESHCRAFT_BOOLEAN OFF CACHE BOOL "" FORCE)
set(SLIC3R_ALLOW_MCUT_BOOLEAN ON CACHE BOOL "" FORCE)
set(SLIC3R_HAS_OPENMESHCRAFT_BOOLEAN FALSE CACHE INTERNAL "" FORCE)
# 开启"预编译头"开关，让 libslic3r 的 add_precompiled_header() 真正生效。
# 见 cmake/PrecompiledHeader.cmake：我们把它实现为 -include pchheader.hpp。
# 这不是可选项 —— 上游大量 TU 依赖 pchheader.hpp 的传递包含才能编译通过。
set(SLIC3R_PCH ON CACHE BOOL "" FORCE)
set(SLIC3R_SYNTAXONLY OFF CACHE BOOL "" FORCE)

# ---- 语言标准与位置无关代码（静态库最终打进 .so 需要 -fPIC）----
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# aarch64 的 char 默认是 unsigned，会让 BuildVolume.hpp 的 `enum class Type : char { Invalid = -1 }` 编译失败，
# 也会让所有依赖 char 符号性的逻辑与 x86 参考实现不一致（BambuStudio 官方同样这么做）。
add_compile_options(-fsigned-char)

# ---- 外部依赖查找（缺失时 find_package 会明确报错，提示交叉编译项）----
# 对齐 BambuStudio 根 CMakeLists.txt 里定义的 LIBDIR / LIBDIR_BIN：
# qhull / libigl 的 CMakeLists 都用 ${LIBDIR} 拼 include 路径，必须在此定义，
# 否则会退化成 "/qhull/src" 这种非法路径。
set(LIBDIR     ${CMAKE_CURRENT_SOURCE_DIR})
set(LIBDIR_BIN ${CMAKE_CURRENT_BINARY_DIR})

# ---- Boost：头文件直接用 1.86 源码根（完整头树）；已编组件库用 prefix/boost/lib ----
# 不走 find_package(Boost)（我们没有产出 BoostConfig），而是建两个 interface 目标，
# 名称与 BambuStudio 原顶层 CMake 保持一致：boost_headeronly / boost_libs
set(BOOST_OHOS_SRC    "C:/HMBambulabStudio/slic3r-deps/src/boost_1_86_0")
set(BOOST_OHOS_PREFIX "C:/HMBambulabStudio/slic3r-deps/prefix/boost")
add_library(boost_headeronly INTERFACE)
target_include_directories(boost_headeronly INTERFACE "${BOOST_OHOS_SRC}" "${BOOST_OHOS_PREFIX}/include")
# libnest2d 直接 link Boost::boost（FindBoost 的头文件接口目标），补一个别名
add_library(Boost::boost ALIAS boost_headeronly)

add_library(boost_libs INTERFACE)
target_include_directories(boost_libs INTERFACE "${BOOST_OHOS_SRC}" "${BOOST_OHOS_PREFIX}/include")
file(GLOB _boost_static_libs "${BOOST_OHOS_PREFIX}/lib/libboost_*.a")
target_link_libraries(boost_libs INTERFACE ${_boost_static_libs})

find_package(TBB REQUIRED)
find_package(libnoise REQUIRED)
# libnest2d 无条件 link NLopt::nlopt（Arrangement 用），须在 add_subdirectory(libnest2d) 之前找到
find_package(NLopt REQUIRED)

# ---- ZLIB：自建 ZLIB::ZLIB，故意不挂 include 目录 ----
# FindZLIB 会把自己找到的 ZLIB_INCLUDE_DIR（= OHOS sysroot 的 /usr/include）作为
# INTERFACE_INCLUDE_DIRECTORIES 下发给所有链接者，CMake 会把它渲染成显式 "-isystem
# <sysroot>/usr/include"。显式 -isystem 的搜索优先级高于 clang 资源目录，于是 sysroot 里
# musl 的 stddef.h / math.h 会盖掉 clang 自带的 C++ 头，libcxx 全线报
# "nullptr_t 未定义 / __promote 未定义 / hypot 歧义"。所以这里只给库路径，不给 include。
if(NOT TARGET ZLIB::ZLIB)
    find_library(OHOS_ZLIB_LIBRARY NAMES z zlib)
    if(NOT OHOS_ZLIB_LIBRARY)
        message(FATAL_ERROR "OHOS: zlib not found (expect <sysroot>/usr/lib/aarch64-linux-ohos/libz.so)")
    endif()
    add_library(ZLIB::ZLIB UNKNOWN IMPORTED)
    set_target_properties(ZLIB::ZLIB PROPERTIES IMPORTED_LOCATION "${OHOS_ZLIB_LIBRARY}")
endif()
find_package(ZLIB REQUIRED)
# 必须走 CONFIG 模式：CMake 自带的 FindPNG.cmake 在交叉编译下找不到我们的交叉编译版 libpng
find_package(PNG REQUIRED CONFIG)
# expat：3MF/AMF 解析用（Format/3mf.cpp 等 #include <expat.h>）
find_package(EXPAT REQUIRED)

# ---- Cereal（序列化，头文件-only）：对齐 BambuStudio deps/Cereal v1.3.0 ----
# libslic3r 源码里直接 #include <cereal/cereal.hpp>，需要一个名为 cereal 的接口目标
set(CEREAL_OHOS_SRC "C:/HMBambulabStudio/slic3r-deps/src/cereal-1.3.0")
add_library(cereal INTERFACE)
target_include_directories(cereal INTERFACE "${CEREAL_OHOS_SRC}/include")

# ---- 全局 include 目录：对齐 BambuStudio 根 CMakeLists.txt（LIBDIR / eigen / libigl）----
# 源码里大量使用 #include <libslic3r/...>、<agg/...>、<boost/nowide/...>、<Eigen/...>，
# 都依赖这里的源码根目录作为 include 根。
include_directories(${CMAKE_CURRENT_SOURCE_DIR})
include_directories(BEFORE SYSTEM ${CMAKE_CURRENT_SOURCE_DIR}/eigen)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/libigl)
# Boost 头文件也要全局可见：libslic3r_cgal / qhull 等目标没有 link boost_headeronly，
# 但它们的头（如 Semver.hpp）会间接 #include <boost/optional.hpp>。
# 注意顺序：源码根在前，保证 <boost/nowide/...> 优先命中 in-tree 的 nowide。
include_directories(${BOOST_OHOS_PREFIX}/include)
include_directories(${BOOST_OHOS_SRC})
# Cereal 头文件全局可见（libslic3r_cgal 等目标没有 link cereal）
include_directories(${CEREAL_OHOS_SRC}/include)
# expat 头文件全局可见（libslic3r_cgal / 其它目标间接包含 Format 头时会用到 expat.h）
include_directories(${EXPAT_INCLUDE_DIRS})
# OpenSSL 头文件全局可见（Utils.hpp <openssl/md5.h>、LogSink.cpp <openssl/aes.h>）。
# 对齐 BambuStudio：libslic3r 只用到符号，OpenSSL 库是最后由可执行/GUI 链接的，
# 所以静态库阶段只需要 include，不需要把 libcrypto 链进 libslic3r。
set(OSSL_OHOS_PREFIX "C:/HMBambulabStudio/slic3r-deps/prefix/openssl")
include_directories(${OSSL_OHOS_PREFIX}/include)
# TBB 头文件全局可见：libslic3r_cgal（CutSurface.cpp）等目标没有 link TBB::tbb，
# 但会直接 #include <tbb/parallel_for.h>。
include_directories("C:/HMBambulabStudio/slic3r-deps/prefix/tbb/include")

# ---- 引入 in-tree 子模块（纯 C++ 切片核心，无 GUI）----
add_subdirectory(build-utils)
add_subdirectory(admesh)
add_subdirectory(boost)
add_subdirectory(clipper)
add_subdirectory(clipper2)
add_subdirectory(miniz)
add_subdirectory(minilzo)
add_subdirectory(glu-libtess)
add_subdirectory(qhull)
add_subdirectory(Shiny)
add_subdirectory(semver)
add_subdirectory(libigl)
add_subdirectory(hints)
add_subdirectory(mcut)
add_subdirectory(libnest2d)

# ---- 切片核心静态库 ----
add_subdirectory(libslic3r)
