// OHOS 裁剪桩：为从构建中移除的 TU 提供链接期符号。
//
// 1) assimp：Model.cpp 会调用 load_assimp_textured_model 尝试用 assimp 导入额外 CAD 格式；
//    assimp 未交叉编译，这里返回失败（该格式在 HAM 版不可用）。
// 2) LogSink：LogSink.cpp（加密日志后端）依赖 slic3r/Utils/{BBLUtil,Http}，Http 又走 libcurl。
//    它只负责把日志加密写盘并在需要时从服务器取 AES key，与切片结果无关；这里给最小桩，
//    日志仍由 boost::log 走默认路径输出，只是不做加密。
// 其余被移除的 TU（纹理上色 / ObjColorUtils / TextureToColor / SLA-Hollowing）在非 GUI 的
// libslic3r 内核里没有调用者，无需桩。

#include "Format/AssimpImport.hpp"
#include "LogSink.hpp"

namespace Slic3r {

bool load_assimp_textured_model(const std::string& path, TexturedMesh& out, std::string* error_message)
{
    (void)path;
    (void)out;
    if (error_message != nullptr) {
        *error_message = "assimp import is not available in this build";
    }
    return false;
}

LogSinkBackend::LogSinkBackend(const std::string& base_path, const LogEncOptions& options)
    : m_log_enc_options(options)
{
    (void)base_path;
}

bool LogSinkBackend::update_enc_option(const std::string& base_path, const LogEncOptions& options)
{
    (void)base_path;
    (void)options;
    return false;
}

void LogSinkBackend::consume(const boost::log::record_view& rec, const std::string& formatted_message)
{
    // 不做加密，直接丢给 boost::log 的文件后端写盘。
    boost::log::sinks::text_file_backend::consume(rec, formatted_message);
}

} // namespace Slic3r
