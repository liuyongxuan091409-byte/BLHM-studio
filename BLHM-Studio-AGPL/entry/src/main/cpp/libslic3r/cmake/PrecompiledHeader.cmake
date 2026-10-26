# OHOS 实现：BambuStudio 的 cmake/PrecompiledHeader.cmake 未随 libslic3r 一起 vendored。
#
# 这里不用真·PCH（clang 的 -include-pch 需要与主编译完全一致的 flags，接起来脆弱），
# 而是实现它的等价语义：用 -include 把 pchheader.hpp 强制包含进目标的每个 TU。
#
# 注意这不仅是"编译加速"——上游源码大量依赖 pchheader.hpp 的传递包含：
#   * Point.hpp          → Vec3i / Vec3f / Points ...（例如 MeshDiagnostics.hpp 只 include <admesh/stl.h>）
#   * ClipperUtils.hpp   → 完整的 ExPolygon 定义（例如 ClipperZUtils.hpp 的模板体）
#   * tbb/parallel_for.h、Eigen/Dense、libslic3r.h ...
# 少了它会有大量 TU 报"未定义类型 / 不完整类型"。
#
# 调用形式：add_precompiled_header(<target> <header> [FORCEINCLUDE])
function(add_precompiled_header target header)
    # header 是相对调用处 CMakeLists 的路径（函数体不改变 CMAKE_CURRENT_SOURCE_DIR）
    get_filename_component(_ohos_pch_abs "${header}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${_ohos_pch_abs}")
        message(FATAL_ERROR "OHOS: precompiled header not found: ${_ohos_pch_abs}")
    endif()
    target_compile_options(${target} PRIVATE "-include" "${_ohos_pch_abs}")
    message(STATUS "OHOS: force-include ${_ohos_pch_abs} into ${target} (stand-in for PCH)")
endfunction()
