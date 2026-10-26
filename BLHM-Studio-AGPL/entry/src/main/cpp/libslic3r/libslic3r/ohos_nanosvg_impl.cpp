// nanosvg / nanosvgrast 是"单头文件"库：需要在且仅在一个 TU 里定义
// NANOSVG_IMPLEMENTATION / NANOSVGRAST_IMPLEMENTATION 才会生成实现体。
//
// 桌面版把这两个宏放在 GUI 侧的 src/slic3r/GUI/BitmapCache.cpp 里，
// libslic3r 自身不提供实现（靠 libslic3r_gui 提供符号）。我们的 OHOS 版没有 GUI，
// 所以在这里补一个实现 TU，让 libslic3r/NSVGUtils.cpp 的 SVG 解析真正可用
// （而不是打桩——SVG 会被 Emboss/形状导入用到）。
#define NANOSVG_IMPLEMENTATION
#define NANOSVGRAST_IMPLEMENTATION

#include "nanosvg/nanosvg.h"
#include "nanosvg/nanosvgrast.h"
