# Bambu Studio HM 原生库构建：NAPI 桥接 + MbedTLS(TLS) + Bambu MQTT/发现模块 + libslic3r 切片内核
cmake_minimum_required(VERSION 3.5.0)
project(entry)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MbedTLS 静态库（TLS 传输，自签名证书不校验）
add_subdirectory(mbedtls)

# FFmpeg 静态库（RTSP 拉流 + H.264 解码 + RGB 转换，交叉编译产物）
set(FFMPEG_DIR C:/HMBambulabStudio/ffmpeg-6.1.2)

# OCCT 7.6 静态库（STEP CAD 读取 + 三角化，交叉编译产物，与桌面版同源）
set(OCCT_BUILD C:/HMBambulabStudio/occt-build)
file(GLOB OCCT_LIBS ${OCCT_BUILD}/lin64/clang/lib/*.a)

add_library(entry SHARED napi_init.cpp bambu_mqtt.cpp bambu_discovery.cpp bambu_camera.cpp
    bambu_renderer.cpp bambu_mesh.cpp bambu_step.cpp bambu_ftps.cpp)
target_include_directories(entry PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/libslic3r
    # 切片内核对外 API 头（ohos_slicer_api.hpp，只依赖 <string>）：
    # 故意不让 app 侧看到 libslic3r 的一整套内部头，避免 Boost/CGAL/Eigen/OCCT 的头路径污染
    ${CMAKE_CURRENT_SOURCE_DIR}/libslic3r/libslic3r
    ${FFMPEG_DIR}
    ${OCCT_BUILD}/include/opencascade)
target_link_directories(entry PRIVATE
    ${FFMPEG_DIR}/libavformat
    ${FFMPEG_DIR}/libavcodec
    ${FFMPEG_DIR}/libswscale
    ${FFMPEG_DIR}/libswresample
    ${FFMPEG_DIR}/libavutil)

# =============================================================================
#  切片内核 libslic3r（OpenHarmony aarch64 交叉编译产物）
#
#  产物由 slic3r-deps/build_libslic3r.ps1 生成，与桌面版 Bambu Studio 2.8.2.61 同源同版本。
#  这里按"预编译静态库"方式接入（和本文件里的 FFmpeg/OCCT 一个套路），
#  好处是 hvigor 每次构建不用重编 200+ 个重 TU，也不会被 libslic3r 的
#  头文件依赖（Boost/CGAL/Eigen/OCCT/expat/cereal...）拖进 app 的编译单元。
#  需要改内核时：跑一遍 build_libslic3r.ps1 + ninja，再重新构建 HAP。
# =============================================================================
set(SLIC3R_DEPS   C:/HMBambulabStudio/slic3r-deps)
set(SLIC3R_BUILD  ${SLIC3R_DEPS}/build/libslic3r)
set(SLIC3R_PREFIX ${SLIC3R_DEPS}/prefix)

# in-tree 子模块（按 CMake 里的链接顺序）
set(SLIC3R_INTERNAL_LIBS
    ${SLIC3R_BUILD}/libslic3r/liblibslic3r.a
    ${SLIC3R_BUILD}/libslic3r/liblibslic3r_cgal.a
    ${SLIC3R_BUILD}/libnest2d/liblibnest2d.a
    ${SLIC3R_BUILD}/admesh/libadmesh.a
    ${SLIC3R_BUILD}/boost/libnowide.a
    ${SLIC3R_BUILD}/clipper/libclipper.a
    ${SLIC3R_BUILD}/clipper2/libClipper2.a
    ${SLIC3R_BUILD}/miniz/libminiz_static.a
    ${SLIC3R_BUILD}/minilzo/libminilzo_static.a
    ${SLIC3R_BUILD}/glu-libtess/libglu-libtess.a
    ${SLIC3R_BUILD}/qhull/libqhullstatic.a
    ${SLIC3R_BUILD}/Shiny/libShiny.a
    ${SLIC3R_BUILD}/semver/libsemver.a
    ${SLIC3R_BUILD}/mcut/libmcut.a)

# 预编译的第三方依赖
file(GLOB SLIC3R_BOOST_LIBS ${SLIC3R_PREFIX}/boost/lib/libboost_*.a)
set(SLIC3R_DEP_LIBS
    ${SLIC3R_BOOST_LIBS}
    ${SLIC3R_PREFIX}/tbb/lib/libtbb.a
    ${SLIC3R_PREFIX}/tbb/lib/libtbbmalloc.a
    ${SLIC3R_PREFIX}/gmp/lib/libgmpxx.a
    ${SLIC3R_PREFIX}/gmp/lib/libgmp.a
    ${SLIC3R_PREFIX}/mpfr/lib/libmpfr.a
    ${SLIC3R_PREFIX}/nlopt/lib/libnlopt.a
    ${SLIC3R_PREFIX}/expat/lib/libexpat.a
    ${SLIC3R_PREFIX}/libpng/lib/libpng.a
    ${SLIC3R_PREFIX}/libnoise/lib/libnoise.a
    ${SLIC3R_PREFIX}/openssl/lib/libssl.a
    ${SLIC3R_PREFIX}/openssl/lib/libcrypto.a)

foreach(_p ${SLIC3R_INTERNAL_LIBS} ${SLIC3R_DEP_LIBS})
    if(NOT EXISTS ${_p})
        message(FATAL_ERROR "切片内核依赖缺失: ${_p}\n请先运行 slic3r-deps/build_libslic3r.ps1 并 ninja 编译。")
    endif()
endforeach()

target_link_libraries(entry PUBLIC
    libace_napi.z.so libace_ndk.z.so libhilog_ndk.z.so librawfile.z.so
    EGL GLESv3
    avformat avcodec swscale swresample avutil
    mbedtls-static
    # libslic3r 与 libnest2d 互相引用，依赖链也有环，用 --start-group 让 ld 反复扫描
    "-Wl,--start-group"
      ${SLIC3R_INTERNAL_LIBS}
      ${SLIC3R_DEP_LIBS}
      ${OCCT_LIBS}
    "-Wl,--end-group"
    z dl)
