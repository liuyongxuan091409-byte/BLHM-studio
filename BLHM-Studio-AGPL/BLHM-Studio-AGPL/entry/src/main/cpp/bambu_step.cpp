#include "bambu_step.hpp"
#include "bambu_mqtt.hpp"

#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TDF_Label.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>

#include <cmath>

// =============================================================================
// STEP 解析：STEPCAFControl_Reader（含颜色/装配体）→ BRepMesh 三角化 → MeshArrays
// 与桌面版 Bambu Studio 同一套 OCCT 内核（其 TK*.dll 即 OCCT 工具库）
// =============================================================================
namespace BambuStep {

namespace {

void pushTri(BambuMesh::MeshArrays& m,
             double ax, double ay, double az, double bx, double by, double bz,
             double cx, double cy, double cz)
{
    double ux = bx - ax, uy = by - ay, uz = bz - az;
    double vx = cx - ax, vy = cy - ay, vz = cz - az;
    double nx = uy * vz - uz * vy;
    double ny = uz * vx - ux * vz;
    double nz = ux * vy - uy * vx;
    double l = std::sqrt(nx * nx + ny * ny + nz * nz);
    if (l > 1e-12) { nx /= l; ny /= l; nz /= l; } else { nx = 0; ny = 0; nz = 1; }
    const float p[9] = { (float)ax, (float)ay, (float)az,
                         (float)bx, (float)by, (float)bz,
                         (float)cx, (float)cy, (float)cz };
    const float n[9] = { (float)nx, (float)ny, (float)nz,
                         (float)nx, (float)ny, (float)nz,
                         (float)nx, (float)ny, (float)nz };
    m.positions.insert(m.positions.end(), p, p + 9);
    m.normals.insert(m.normals.end(), n, n + 9);
}

} // namespace

bool parseStep(const std::string& path, BambuMesh::MeshArrays& out)
{
    try {
        Handle(XCAFApp_Application) app = XCAFApp_Application::GetApplication();
        Handle(TDocStd_Document) doc = new TDocStd_Document("MDTV-XCAF");
        app->NewDocument("MDTV-XCAF", doc);

        STEPCAFControl_Reader reader;
        reader.SetColorMode(true);
        reader.SetNameMode(true);
        if (reader.ReadFile(path.c_str()) != IFSelect_RetDone) {
            out.ok = false;
            out.error = "STEP 文件读取失败";
            return false;
        }
        if (!reader.Transfer(doc)) {
            out.ok = false;
            out.error = "STEP 转换失败";
            return false;
        }

        Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());

        TDF_LabelSequence roots;
        shapeTool->GetFreeShapes(roots);
        if (roots.Length() == 0) {
            out.ok = false;
            out.error = "STEP 内无实体";
            return false;
        }
        BambuMqtt::addLog("step: " + std::to_string(roots.Length()) + " root shape(s)");

        for (int r = 1; r <= roots.Length(); r++) {
            const TDF_Label& rootLabel = roots.Value(r);
            TopoDS_Shape shape = shapeTool->GetShape(rootLabel);
            if (shape.IsNull()) { continue; }

            // 按包围盒对角线定网格精度（约 0.1%）
            Bnd_Box box;
            BRepBndLib::Add(shape, box, false);
            if (box.IsVoid()) { continue; }
            double xmin, ymin, zmin, xmax, ymax, zmax;
            box.Get(xmin, ymin, zmin, xmax, ymax, zmax);
            double dx = xmax - xmin, dy = ymax - ymin, dz = zmax - zmin;
            double diag = std::sqrt(dx * dx + dy * dy + dz * dz);
            double defl = std::max(diag * 0.001, 0.01);
            BRepMesh_IncrementalMesh mesher(shape, defl, Standard_False, 0.4);
            (void)mesher;

            // 导出所有面的三角网格（位置变换由 TopLoc_Location 处理）
            int faceCount = 0;
            for (TopExp_Explorer exp(shape, TopAbs_FACE); exp.More(); exp.Next()) {
                TopoDS_Face face = TopoDS::Face(exp.Current());
                TopLoc_Location loc;
                Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
                if (tri.IsNull()) { continue; }
                const gp_Trsf& tf = loc.Transformation();
                int nt = tri->NbTriangles();
                for (int i = 1; i <= nt; i++) {
                    Poly_Triangle t = tri->Triangle(i);
                    gp_Pnt p1 = tri->Node(t.Value(1)).Transformed(tf);
                    gp_Pnt p2 = tri->Node(t.Value(2)).Transformed(tf);
                    gp_Pnt p3 = tri->Node(t.Value(3)).Transformed(tf);
                    pushTri(out, p1.X(), p1.Y(), p1.Z(),
                            p2.X(), p2.Y(), p2.Z(),
                            p3.X(), p3.Y(), p3.Z());
                }
                faceCount++;
            }
            BambuMqtt::addLog("step: root " + std::to_string(r) + " faces=" + std::to_string(faceCount));
        }

        if (out.positions.empty()) {
            out.ok = false;
            out.error = "STEP 三角化失败";
            return false;
        }

        // 归一化（XY 居中、贴板）与尺寸统计
        size_t n = out.positions.size() / 3;
        float lo[3] = { 1e30f, 1e30f, 1e30f };
        float hi[3] = { -1e30f, -1e30f, -1e30f };
        for (size_t i = 0; i < n; i++) {
            for (int d = 0; d < 3; d++) {
                float v = out.positions[i * 3 + d];
                lo[d] = std::min(lo[d], v);
                hi[d] = std::max(hi[d], v);
            }
        }
        float cx = (lo[0] + hi[0]) * 0.5f;
        float cy = (lo[1] + hi[1]) * 0.5f;
        for (size_t i = 0; i < n; i++) {
            out.positions[i * 3 + 0] -= cx;
            out.positions[i * 3 + 1] -= cy;
            out.positions[i * 3 + 2] -= lo[2];
        }
        out.size[0] = hi[0] - lo[0];
        out.size[1] = hi[1] - lo[1];
        out.size[2] = hi[2] - lo[2];
        out.triangles = static_cast<int>(n / 3);
        out.ok = true;

        BambuMqtt::addLog("step: parsed " + std::to_string(out.triangles) + " triangles");
        return true;
    } catch (const Standard_Failure& e) {
        out.ok = false;
        out.error = std::string("OCCT 异常: ") + e.GetMessageString();
        BambuMqtt::addLog("step: exception " + out.error);
        return false;
    } catch (...) {
        out.ok = false;
        out.error = "STEP 解析未知异常";
        BambuMqtt::addLog("step: unknown exception");
        return false;
    }
}

} // namespace BambuStep
