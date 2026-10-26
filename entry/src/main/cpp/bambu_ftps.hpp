#ifndef BAMBU_FTPS_HPP
#define BAMBU_FTPS_HPP

#include <string>

// Bambu 打印机内置存储上传（隐式 FTPS）。
//
// 复用工程**已有的网络能力**：mbedtls（与 MQTT 8883 同一条 TLS 栈，见 bambu_mqtt.cpp:
// mbedtls_ssl_conf_authmode(MBEDTLS_SSL_VERIFY_NONE)）—— 打印机用自签证书，这条策略只作用于
// 这一个连接：每个 TlsConn 的 conf/authmode 都是独立的，不动任何全局/系统信任设置。
//
// 协议（服务器：Bambu 打印机 990 端口，隐式 FTPS）：
//   TCP:990 → 立即 TLS 握手 → 220 问候 → USER bblp / PASS <access code> → 230
//   → PBSZ 0 / PROT P / TYPE I → EPSV(回退 PASV) → 第二个连接（数据口，同样 TLS）
//   → STOR /cache/<name> → 传输 → 226。
// **只上传、不发送任何打印命令**（任务红线：不触发打印）。
namespace BambuFtps {

// 把 local_path 上传为打印机 ftps 根下的 remote_path（如 "cache/xxx.3mf"）。
// 返回 JSON：{"ok":true,"code":"226","message":"..","remotePath":"..","sentBytes":N,"log":[...]}
// 失败：{"ok":false,"code":"<最后一步返回码或 ERR>","message":"..","log":[...]}
std::string upload(const std::string& ip,
                   const std::string& user,
                   const std::string& password,
                   const std::string& local_path,
                   const std::string& remote_path);

// 列打印机某目录（隐式 FTPS 990）。只读，不上传、不打印。
// remote_dir 如 "/cache"（空 → "/"）。
// 返回 JSON：{"ok":true,"code":"226","message":"..","dir":"/cache","entries":["<原始目录行>",...],"log":[...]}
// 失败：{"ok":false,"code":"<最后一步返回码或 ERR>","message":"..","entries":[...],"log":[...]}
std::string list(const std::string& ip,
                 const std::string& user,
                 const std::string& password,
                 const std::string& remote_dir);

// 删除打印机上的一个文件（DELE）。只删文件、不删目录（目录服务器会回 550）。
// remote_path 允许 "cache/x.3mf" 或 "/cache/x.3mf"。
// 返回 JSON：{"ok":true,"code":"250","message":"..","remotePath":"..","log":[...]}
std::string removeFile(const std::string& ip,
                       const std::string& user,
                       const std::string& password,
                       const std::string& remote_path);

// 下载打印机上的一个文件到 local_path（RETR，二进制模式）。
// max_bytes > 0 时超过即中止（避免把超大 gcode 全读进内存/撑爆沙箱），返回 ok=false。
// 返回 JSON：{"ok":true,"code":"226","message":"..","remotePath":"..","localPath":"..","bytes":N,"log":[...]}
std::string download(const std::string& ip,
                     const std::string& user,
                     const std::string& password,
                     const std::string& remote_path,
                     const std::string& local_path,
                     long long max_bytes);

} // namespace BambuFtps

#endif // BAMBU_FTPS_HPP
