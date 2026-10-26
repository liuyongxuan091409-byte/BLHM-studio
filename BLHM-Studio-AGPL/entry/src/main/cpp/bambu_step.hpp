#ifndef BAMBU_STEP_HPP
#define BAMBU_STEP_HPP

#include <string>
#include "bambu_mesh.hpp"

// STEP(.stp/.step) CAD 文件解析（基于 OCCT 7.6，与桌面版 Bambu Studio 同源）
// 读取 B-rep → 三角化 → 输出平面网格数组（无渲染依赖）
namespace BambuStep {

bool parseStep(const std::string& path, BambuMesh::MeshArrays& out);

} // namespace BambuStep

#endif // BAMBU_STEP_HPP
