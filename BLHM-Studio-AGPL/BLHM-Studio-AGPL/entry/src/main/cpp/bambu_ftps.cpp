#include "bambu_ftps.hpp"

#include "libslic3r/nlohmann/json.hpp"

#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

namespace BambuFtps {

namespace {

const int FTPS_PORT = 990;       // Bambu 隐式 FTPS
const int IO_TIMEOUT_SEC = 15;   // 单次收发超时（不设全局上限，交给 OS 超时）
const size_t CHUNK = 64 * 1024;
// STOR 完成确认（226）的**短等**上限。只做 2 秒等待，理由两头都要顾：
//   · 该等（Bambuddy #645）：数据通道传完 ≠ 文件已落盘，别在服务器确认前就发打印命令；
//     本实现是「数据口 close 之后才返回」，已经把写完这件事排到了前面。
//   · 不能久等（官方口径，A1 mini 逐行验证）：STOR 之后那个 226 **有可能根本不来**，
//     久等只会让每次打印白卡几十秒。故 2 秒拿不到就按「数据已传完 + 数据口正常关闭」放行。
const int64_t STOR_CONFIRM_TIMEOUT_MS = 2000;
// 短等期间控制口单次读超时（把 SO_RCVTIMEO 临时降到 1s 用于轮询总预算；用完恢复 15s）
const int CONFIRM_POLL_TIMEOUT_SEC = 1;

// 日志收集（返回给 ArkTS 便于留证）
std::vector<std::string> g_log;

void logf(const std::string& s) { g_log.push_back(s); }

// 全模块共享的熵源/DRBG（mbedtls 要求 RNG；一次初始化，进程内复用）
mbedtls_entropy_context g_entropy;
mbedtls_ctr_drbg_context g_ctrDrbg;
std::once_flag g_rngOnce;

void ensureRng() {
    std::call_once(g_rngOnce, []() {
        mbedtls_entropy_init(&g_entropy);
        mbedtls_ctr_drbg_init(&g_ctrDrbg);
        mbedtls_ctr_drbg_seed(&g_ctrDrbg, mbedtls_entropy_func, &g_entropy, nullptr, 0);
    });
}

// 一条 TLS 连接（控制通道或数据通道各一份，互不影响证书策略）
struct TlsConn {
    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    // 控制口的 TLS 会话（供数据口复用）。Bambu 的 vsftpd 打开 require_ssl_reuse=YES，
    // 数据连接必须复用控制口会话，否则服务器拒绝/挂起。
    mbedtls_ssl_session session;
    bool hasSession = false;
    bool inited = false;
    bool open = false;

    TlsConn() {
        mbedtls_net_init(&net);
        mbedtls_ssl_init(&ssl);
        mbedtls_ssl_config_init(&conf);
        mbedtls_ssl_session_init(&session);
        inited = true;
    }
    ~TlsConn() { close_(); }

    void close_() {
        if (!inited) return;
        if (open) {
            mbedtls_ssl_close_notify(&ssl);
            open = false;
        }
        mbedtls_ssl_free(&ssl);
        mbedtls_ssl_config_free(&conf);
        mbedtls_ssl_session_free(&session);
        mbedtls_net_free(&net);
        inited = false;
    }

    // 关闭后可重新初始化：数据口的「变体阶梯」要对同一个对象反复重试（见 connectData）。
    // 不能直接赋值/移动 TlsConn——内含 mbedtls 上下文且有析构 free，移动会造成双重释放。
    void reinit() {
        if (inited) return;
        mbedtls_net_init(&net);
        mbedtls_ssl_init(&ssl);
        mbedtls_ssl_config_init(&conf);
        mbedtls_ssl_session_init(&session);
        hasSession = false;
        open = false;
        inited = true;
    }
};

// 建立到 ip:port 的 TCP 连接（带收发超时，避免不可达时长时间挂起）
int connectTcp(const std::string& ip, int port, std::string& err, int timeoutSec = IO_TIMEOUT_SEC) {
    int sock = ::socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) { err = "socket() 失败"; return -1; }
    timeval tv;
    tv.tv_sec = timeoutSec;
    tv.tv_usec = 0;
    ::setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (::inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) != 1) {
        ::close(sock);
        err = "IP 解析失败: " + ip;
        return -1;
    }
    if (::connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(sock);
        err = "TCP 连接失败 " + ip + ":" + std::to_string(port);
        return -1;
    }
    return sock;
}

// TCP + TLS 握手。**接受任意证书**：authmode=VERIFY_NONE（打印机自签，且此设置只属于本连接）。
// reuse 非空时复用控制口的 TLS 会话（Bambu vsftpd require_ssl_reuse=YES 要求）。
// forceTls12：只把版本上限钉到 TLS1.2（数据口变体用；控制口不传）。
// timeoutSec：本连接 socket 收发超时（数据口短超时，避免变体阶梯把时间耗光）。
bool tlsConnect(TlsConn& c, const std::string& ip, int port, std::string& err,
                const mbedtls_ssl_session* reuse = nullptr,
                bool forceTls12 = false, int timeoutSec = IO_TIMEOUT_SEC) {
    ensureRng();
    int sock = connectTcp(ip, port, err, timeoutSec);
    if (sock < 0) return false;
    c.net.fd = sock;

    mbedtls_ssl_config_defaults(&c.conf, MBEDTLS_SSL_IS_CLIENT,
                                MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    mbedtls_ssl_conf_rng(&c.conf, mbedtls_ctr_drbg_random, &g_ctrDrbg);
    // 自签证书：接受任意证书。仅用于该连接（conf 是本连接私有的）。
    mbedtls_ssl_conf_authmode(&c.conf, MBEDTLS_SSL_VERIFY_NONE);
    if (forceTls12) {
        // 版本上限钉到 TLS1.2：数据口变体之一（见 kDataVariants）。
        mbedtls_ssl_conf_min_tls_version(&c.conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&c.conf, MBEDTLS_SSL_VERSION_TLS1_2);
    }
    mbedtls_ssl_setup(&c.ssl, &c.conf);
    if (reuse != nullptr) {
        // 会话复用失败不致命：记一条日志后继续做完整握手（服务器会给出真实应答）
        int sret = mbedtls_ssl_set_session(&c.ssl, reuse);
        if (sret != 0) logf("(数据口会话复用设置失败，回退全握手)");
    }
    // SNI 用 IP（打印机不校验主机名，但保持与其他模块一致）
    mbedtls_ssl_set_hostname(&c.ssl, ip.c_str());
    mbedtls_ssl_set_bio(&c.ssl, &c.net, mbedtls_net_send, mbedtls_net_recv, nullptr);

    int ret = 0;
    while ((ret = mbedtls_ssl_handshake(&c.ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            char buf[64];
            snprintf(buf, sizeof(buf), "TLS 握手失败 -0x%04X", static_cast<unsigned>(-ret));
            err = buf;
            return false;
        }
    }
    // 协商结果落日志：排查机型差异（如 H2D）时首先要看的就是「控制口/数据口各自谈到了什么版本」
    logf(std::string("TLS 握手成功 协议=") + mbedtls_ssl_get_version(&c.ssl)
        + " 套件=" + mbedtls_ssl_get_ciphersuite(&c.ssl)
        + (reuse != nullptr ? " 复用会话=已请求" : " 复用会话=无"));
    c.open = true;
    return true;
}

// ---------------------------------------------------------------------------
// 数据口 TLS 握手「变体阶梯」
//   现象（H2D / vsftpd 3.0.5 实测）：控制口一切正常（220/230/PBSZ/PROT/TYPE/EPSV 全 2xx、STOR 已写），
//   但数据口 TCP 连上后 **15 秒收不到任何字节** → `数据通道 TLS 握手失败 -0x004C`
//   （-0x4C = mbedtls NET_RECV_FAILED = 读超时）。同一套代码在 X1C(vsftpd 3.0.3)/A1 上能正常上传，
//   所以差异只在数据口这一侧的 TLS 协商（会话复用 / 版本），而单靠读代码分不出是哪一项。
//   于是按「最可能可用」的顺序逐个试，谁先成功就用谁；变体 1 = 既有行为（不影响已跑通的机型）。
//   每次尝试用短超时，避免 3 个变体各干等 15 秒。
struct DataVariant {
    bool reuse;
    bool forceTls12;
    const char* name;
};
const DataVariant kDataVariants[] = {
    { true,  false, "复用控制口会话+默认版本（既有行为）" },
    { false, false, "全握手+默认版本" },
    // 不再往下试第 3 个变体：被动口不是无限次的——H2D 实测第 3 次 TCP 连接直接被拒
    // （50089/50002/50005 三次都是「TCP 连接失败」），再试只会把真实原因盖掉。
};
const int DATA_TLS_ATTEMPT_TIMEOUT_SEC = 6;

// 连接数据口：按变体阶梯依次尝试。成功则 data 处于已握手状态并返回 true；失败返回最后一次的原因。
bool connectData(TlsConn& data, const std::string& ip, int port, const TlsConn& ctrl, std::string& err)
{
    for (const DataVariant& v : kDataVariants) {
        logf(std::string("数据口尝试：") + v.name);
        const mbedtls_ssl_session* reuse = (v.reuse && ctrl.hasSession) ? &ctrl.session : nullptr;
        if (tlsConnect(data, ip, port, err, reuse, v.forceTls12, DATA_TLS_ATTEMPT_TIMEOUT_SEC)) {
            logf(std::string("数据口握手成功（") + v.name + "）");
            return true;
        }
        logf(std::string("数据口握手失败（") + v.name + "）：" + err);
        data.close_();
        data.reinit();
    }
    return false;
}

int tlsWrite(TlsConn& c, const void* data, size_t len) {
    const unsigned char* p = static_cast<const unsigned char*>(data);
    size_t off = 0;
    while (off < len) {
        int n = mbedtls_ssl_write(&c.ssl, p + off, len - off);
        if (n <= 0) {
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            return n;
        }
        off += static_cast<size_t>(n);
    }
    return static_cast<int>(off);
}

// 读一行（到 \r\n 结束）。返回 false = 连接断/读错误。
bool tlsReadLine(TlsConn& c, std::string& line) {
    line.clear();
    char ch = 0;
    while (true) {
        int n = mbedtls_ssl_read(&c.ssl, reinterpret_cast<unsigned char*>(&ch), 1);
        if (n <= 0) {
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            return false;
        }
        line.push_back(ch);
        size_t s = line.size();
        if (s >= 2 && line[s - 2] == '\r' && line[s - 1] == '\n') {
            line.resize(s - 2);   // 去掉 CRLF
            return true;
        }
        if (s > 4096) {           // 防御：异常长行
            return false;
        }
    }
}

// 读一行的「带状态」版本：用于需要总超时的等待（如等待 STOR 的 226）。
//   返回 1 = 读到完整行（line 已去掉 CRLF，可重新使用）
//   返回 0 = 本轮读超时（WANT_READ，暂无数据；line 保留已读到的部分，下次调用继续追加）
//   返回 -1 = 连接断开 / 读错误 / 异常长行
// 注意：完全不做任何会永久阻塞的动作（只写该 fd 的读，超时由 SO_RCVTIMEO 兜底）。
int tlsReadLineStatus(TlsConn& c, std::string& line) {
    char ch = 0;
    while (true) {
        int n = mbedtls_ssl_read(&c.ssl, reinterpret_cast<unsigned char*>(&ch), 1);
        if (n > 0) {
            line.push_back(ch);
            size_t s = line.size();
            if (s >= 2 && line[s - 2] == '\r' && line[s - 1] == '\n') {
                line.resize(s - 2);   // 去掉 CRLF
                return 1;
            }
            if (s > 4096) {           // 防御：异常长行
                return -1;
            }
            continue;
        }
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) {
            return 0;                 // 本轮无数据（socket 读超时）
        }
        return -1;                    // 对端关闭 / 读错误
    }
}

// 只发命令、不读回复（用于 STOR：数据口握手要先于读 150 进行，见 upload 注释）
bool cmdSend(TlsConn& c, const std::string& command) {
    std::string wire = command + "\r\n";
    logf("> " + command);
    return tlsWrite(c, wire.data(), wire.size()) > 0;
}

// 发命令并读完整（多行）回复。返回首行 3 位应答码；reply 首行内容。
int cmd(TlsConn& c, const std::string& command, std::string& reply) {
    std::string wire = command + "\r\n";
    if (tlsWrite(c, wire.data(), wire.size()) <= 0) { reply = "写入失败"; return -1; }
    std::string line;
    if (!tlsReadLine(c, line)) { reply = "读取回复失败"; return -1; }
    reply = line;
    logf("> " + command);
    logf("< " + line);
    if (line.size() < 4) return -1;
    int code = (line[0] - '0') * 100 + (line[1] - '0') * 10 + (line[2] - '0');
    // 多行回复：第 4 个字符是 '-' 时，继续读到 "code " 单行结束
    if (line[3] == '-') {
        std::string first = line;
        while (true) {
            if (!tlsReadLine(c, line)) break;
            logf("< " + line);
            if (line.size() >= 4 && line.compare(0, 3, first, 0, 3) == 0 && line[3] == ' ') break;
        }
    }
    return code;
}

// 解析 EPSV 回复里的端口：229 ... (|||port|)
int parseEpsvPort(const std::string& reply, int& outPort) {
    size_t pos = reply.find("(|||");
    if (pos == std::string::npos) return -1;
    pos += 4;
    int port = 0;
    bool any = false;
    while (pos < reply.size() && reply[pos] >= '0' && reply[pos] <= '9') {
        port = port * 10 + (reply[pos] - '0');
        pos++;
        any = true;
    }
    if (!any) return -1;
    outPort = port;
    return 0;
}

// 解析 PASV 回复：227 ... (h1,h2,h3,h4,p1,p2)
int parsePasv(const std::string& reply, std::string& outIp, int& outPort) {
    size_t l = reply.find('(');
    size_t r = reply.find(')', l == std::string::npos ? 0 : l);
    if (l == std::string::npos || r == std::string::npos) return -1;
    std::string inner = reply.substr(l + 1, r - l - 1);
    int v[6] = { 0, 0, 0, 0, 0, 0 };
    int idx = 0;
    std::string num;
    for (size_t i = 0; i <= inner.size(); i++) {
        if (i == inner.size() || inner[i] == ',') {
            if (idx >= 6) return -1;
            v[idx++] = num.empty() ? 0 : atoi(num.c_str());
            num.clear();
        } else {
            num.push_back(inner[i]);
        }
    }
    if (idx != 6) return -1;
    char ipbuf[32];
    snprintf(ipbuf, sizeof(ipbuf), "%d.%d.%d.%d", v[0], v[1], v[2], v[3]);
    outIp = ipbuf;
    outPort = v[4] * 256 + v[5];
    return 0;
}

// 从 TLS 数据连接读**全部**内容（LIST 的目录数据）。对端关闭连接即收工。
// 只读不写；用有限次「读超时（WANT_READ）」兜底，避免对端不关连接时挂死。
bool tlsReadAll(TlsConn& c, std::string& out) {
    unsigned char buf[4096];
    int idle = 0;
    const int maxIdle = 2;   // 单次读超时 15s；连续两次无数据即认为目录数据结束
    while (true) {
        int n = mbedtls_ssl_read(&c.ssl, buf, sizeof(buf));
        if (n > 0) {
            out.append(reinterpret_cast<char*>(buf), static_cast<size_t>(n));
            idle = 0;
            continue;
        }
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (++idle > maxIdle) return false;
            continue;
        }
        if (n == 0 || n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return true;  // 正常收尾
        return false;
    }
}

} // namespace

std::string upload(const std::string& ip,
                   const std::string& user,
                   const std::string& password,
                   const std::string& local_path,
                   const std::string& remote_path)
{
    g_log.clear();
    nlohmann::json out;
    out["ok"] = false;
    out["code"] = "ERR";

    // 源文件必须先确认存在/可读，避免连上后才失败
    {
        std::ifstream probe(local_path, std::ios::binary);
        if (!probe) {
            out["message"] = "本地文件打不开: " + local_path;
            out["log"] = g_log;
            return out.dump();
        }
    }

    // remote_path 规整成以 / 开头的绝对路径（如 "cache/x.3mf" → "/cache/x.3mf"）
    std::string rp = remote_path;
    if (rp.empty() || rp[0] != '/') rp = "/" + rp;

    TlsConn ctrl;
    std::string err;
    if (!tlsConnect(ctrl, ip, FTPS_PORT, err)) {
        out["message"] = "控制通道 " + err;
        out["log"] = g_log;
        return out.dump();
    }

    std::string reply;
    int code = -2;
    // 220 问候（隐式 FTPS：TCP 后立刻 TLS，问候包发生在 TLS 之内）
    if (!tlsReadLine(ctrl, reply)) {
        out["message"] = "读取 220 问候失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);
    if (reply.size() < 3) {
        out["message"] = "问候格式异常: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    // 保存控制口 TLS 会话：数据口必须复用（Bambu vsftpd require_ssl_reuse=YES）。
    if (mbedtls_ssl_get_session(&ctrl.ssl, &ctrl.session) == 0) {
        ctrl.hasSession = true;
    } else {
        logf("(控制口会话获取失败，数据口改全握手)");
    }

    code = cmd(ctrl, "USER " + user, reply);
    if (code / 100 == 3) code = cmd(ctrl, "PASS " + password, reply);   // 3xx = 需要密码
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "登录失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    // PBSZ/PROT：隐式 FTPS 下可能返回 5xx，按非致命处理（记录但不阻断）
    std::string r2;
    int c2 = cmd(ctrl, "PBSZ 0", r2);
    if (c2 / 100 != 2) logf("(PBSZ 非 2xx，忽略)");
    c2 = cmd(ctrl, "PROT P", r2);
    if (c2 / 100 != 2) logf("(PROT P 非 2xx，忽略)");

    code = cmd(ctrl, "TYPE I", reply);
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "TYPE I 失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    // 被动模式取数据口：先 EPSV，失败回退 PASV
    int dataPort = -1;
    std::string dataIp = ip;
    code = cmd(ctrl, "EPSV", reply);
    if (code == 229 && parseEpsvPort(reply, dataPort) == 0) {
        // EPSV：数据口与当前服务器同 IP
    } else {
        code = cmd(ctrl, "PASV", reply);
        if (code != 227 || parsePasv(reply, dataIp, dataPort) != 0) {
            out["code"] = std::to_string(code);
            out["message"] = "被动模式失败: " + reply;
            out["log"] = g_log;
            return out.dump();
        }
    }
    if (dataPort <= 0) {
        out["message"] = "数据端口解析失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("data port = " + std::to_string(dataPort));

    // STOR **只写不读**。依据（本轮实测三角定位）：
    //   · 旧实现「发 STOR → 等 150 → 再连数据口」：控制口读超时（服务器要先有数据连接才回 150）；
    //   · 变体「先连数据口并握手 → 再发 STOR」：数据口 TLS 握手超时 -0x004C（服务器未 accept）；
    //   结论：服务器收到 STOR 后才 accept 数据连接并启动 TLS。故顺序必须是
    //   写 STOR → 数据口 TCP+TLS 握手（复用控制口会话）→ 读 150/125 → 传数据。
    if (!cmdSend(ctrl, "STOR " + rp)) {
        out["message"] = "STOR 写入失败";
        out["log"] = g_log;
        return out.dump();
    }

    TlsConn data;
    std::string derr;
    if (!connectData(data, dataIp, dataPort, ctrl, derr)) {
        // 【补读控制口】数据口全变体都失败时，服务器很可能在 **STOR 那一步就已经答复了**
        // （4xx/5xx 之类），而我们发完 STOR 直接去连数据口、从没读过那一行 —— 于是它一直躺在
        // 控制口缓冲区里，现象就变成「数据口 TLS 毫无回音」。这里把它捞出来写进原因。
        // 只在这一步读（不放在正常路径上），避免给已经跑通的机型加等待。
        {
            timeval tv;
            tv.tv_sec = 1;
            tv.tv_usec = 0;
            ::setsockopt(ctrl.net.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            std::string late;
            bool got = tlsReadLine(ctrl, late);
            tv.tv_sec = IO_TIMEOUT_SEC;
            ::setsockopt(ctrl.net.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            if (got) {
                logf("< " + late + "（数据口失败后补读控制口）");
                derr += "；控制口应答=" + late;
            } else {
                logf("(数据口失败后补读控制口：无内容)");
                derr += "；控制口应答=(无)";
            }
        }
        out["message"] = "数据通道 " + derr;
        out["log"] = g_log;
        return out.dump();
    }
    // 数据口握手完成后读 STOR 的 150/125 应答
    if (!tlsReadLine(ctrl, reply)) {
        out["message"] = "读取 STOR 应答失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);
    code = reply.size() >= 3
        ? (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0') : -1;
    if (code != 150 && code != 125) {
        out["code"] = std::to_string(code);
        out["message"] = "STOR 被拒: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    // 流式传输
    std::ifstream ifs(local_path, std::ios::binary);
    std::vector<char> buf(CHUNK);
    size_t sent = 0;
    while (ifs) {
        ifs.read(buf.data(), static_cast<std::streamsize>(buf.size()));
        std::streamsize got = ifs.gcount();
        if (got <= 0) break;
        int n = tlsWrite(data, buf.data(), static_cast<size_t>(got));
        if (n <= 0) {
            out["message"] = "数据写入失败";
            out["sentBytes"] = static_cast<double>(sent);
            out["log"] = g_log;
            return out.dump();
        }
        sent += static_cast<size_t>(n);
    }
    // 关闭数据连接（触发服务器写盘）
    data.close_();
    logf("data sent bytes = " + std::to_string(sent));

    // 读 STOR 的最终应答（正常为 226；服务器在数据连接关闭后推送）。
    // 短等 STOR_CONFIRM_TIMEOUT_MS（2s）：把接收超时临时降到 1s 轮询，避免用默认 15s 干等。
    code = -3;
    {
        // 【必须清空】tlsReadLineStatus 是「续读」语义：它会往传入字符串后面追加。
        // reply 里此刻还留着上一步读到的 150（"< 150"），不清就会拼成 "150 226" →
        // code 取到前三位 = 150 → 明明 226 已到却被判成失败（A1 mini 实测：
        // `FTPS| < 150 226` 却报 `返回码=150 STOR 收尾失败`）。
        reply.clear();
        timeval tv;
        tv.tv_sec = CONFIRM_POLL_TIMEOUT_SEC;
        tv.tv_usec = 0;
        ::setsockopt(ctrl.net.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        const auto deadline = std::chrono::steady_clock::now()
            + std::chrono::milliseconds(STOR_CONFIRM_TIMEOUT_MS);
        while (std::chrono::steady_clock::now() < deadline) {
            int st = tlsReadLineStatus(ctrl, reply);
            if (st == 1) {
                logf("< " + reply);
                int c3 = reply.size() >= 3
                    ? (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0') : -1;
                code = c3;
                // 拿到 2xx 就是成功；拿到别的（如 125/150 这类中间应答）先记下、继续等，
                // 别因为「第一个完整行不是 226」就把已经落盘的文件判失败。
                if (c3 / 100 == 2) { break; }
                reply.clear();
                continue;
            }
            if (st < 0) { break; } // 控制口断了：同样落到下面的「超时放行」
        }
        // 恢复默认收发超时（后续 QUIT 等阶段仍用 15s）
        tv.tv_sec = IO_TIMEOUT_SEC;
        ::setsockopt(ctrl.net.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }

    out["sentBytes"] = static_cast<unsigned long long>(sent);
    out["remotePath"] = rp;
    if (code / 100 == 2) {
        out["ok"] = true;
        out["code"] = std::to_string(code);
        out["message"] = "上传成功: " + reply;
        out["log"] = g_log;
        cmd(ctrl, "QUIT", reply);
        return out.dump();
    }
    if (code / 100 == 4 || code / 100 == 5) {
        // 只有服务器**明确拒绝**（4xx/5xx）才算上传失败。
        out["code"] = std::to_string(code);
        out["message"] = "STOR 被拒: " + reply;
        out["log"] = g_log;
        return out.dump();
    }
    // 其余情况一律放行（数据已全部写入 + 数据口已正常关闭）：
    //   · code == -3：2s 内没等到任何应答（A1 系实测 226 有时就是不来）；
    //   · 1xx / 3xx：只等到了中间应答，没等到最终 226。
    // 这两种都不该把已经落盘的文件判成失败、进而阻断打印。
    out["ok"] = true;
    out["code"] = (code == -3) ? std::string("226_TIMEOUT_PASS") : ("NO_226_PASS_" + std::to_string(code));
    out["message"] = (code == -3)
        ? std::string("上传成功（2s 内未等到 226，已按数据口正常关闭放行）")
        : ("上传成功（只等到中间应答 " + std::to_string(code) + "，已按数据口正常关闭放行）");
    out["log"] = g_log;
    cmd(ctrl, "QUIT", reply);
    return out.dump();
}

// 列目录（隐式 FTPS 990，只读）。协议与 upload 同一条登录/被动模式链路，仅把 STOR 换成 LIST：
//   TCP:990 → TLS → 220 → USER bblp / PASS <code> → 230 → PBSZ/PROT → TYPE A → EPSV(回退 PASV)
//   → LIST <dir> → 数据口 TCP+TLS（复用控制口会话）→ 150 → 收目录数据 → 226。
// 说明：LIST 的命令/数据口顺序刻意与 upload 一致（服务器接受数据连接后才回 150）。
std::string list(const std::string& ip,
                 const std::string& user,
                 const std::string& password,
                 const std::string& remote_dir)
{
    g_log.clear();
    nlohmann::json out;
    out["ok"] = false;
    out["code"] = "ERR";

    std::string dir = remote_dir;
    if (dir.empty()) dir = "/";
    if (dir[0] != '/') dir = "/" + dir;

    TlsConn ctrl;
    std::string err;
    if (!tlsConnect(ctrl, ip, FTPS_PORT, err)) {
        out["message"] = "控制通道 " + err;
        out["log"] = g_log;
        return out.dump();
    }

    std::string reply;
    if (!tlsReadLine(ctrl, reply)) {
        out["message"] = "读取 220 问候失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);

    // 控制口 TLS 会话：数据口必须复用（Bambu vsftpd require_ssl_reuse=YES）。
    if (mbedtls_ssl_get_session(&ctrl.ssl, &ctrl.session) == 0) {
        ctrl.hasSession = true;
    } else {
        logf("(控制口会话获取失败，数据口改全握手)");
    }

    int code = cmd(ctrl, "USER " + user, reply);
    if (code / 100 == 3) code = cmd(ctrl, "PASS " + password, reply);
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "登录失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    std::string r2;
    int c2 = cmd(ctrl, "PBSZ 0", r2);
    if (c2 / 100 != 2) logf("(PBSZ 非 2xx，忽略)");
    c2 = cmd(ctrl, "PROT P", r2);
    if (c2 / 100 != 2) logf("(PROT P 非 2xx，忽略)");

    // LIST 用 ASCII 模式（目录数据是文本）
    code = cmd(ctrl, "TYPE A", reply);
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "TYPE A 失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    int dataPort = -1;
    std::string dataIp = ip;
    code = cmd(ctrl, "EPSV", reply);
    if (code == 229 && parseEpsvPort(reply, dataPort) == 0) {
        // EPSV：数据口与当前服务器同 IP
    } else {
        code = cmd(ctrl, "PASV", reply);
        if (code != 227 || parsePasv(reply, dataIp, dataPort) != 0) {
            out["code"] = std::to_string(code);
            out["message"] = "被动模式失败: " + reply;
            out["log"] = g_log;
            return out.dump();
        }
    }
    if (dataPort <= 0) {
        out["message"] = "数据端口解析失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("data port = " + std::to_string(dataPort));

    if (!cmdSend(ctrl, "LIST " + dir)) {
        out["message"] = "LIST 写入失败";
        out["log"] = g_log;
        return out.dump();
    }

    TlsConn data;
    std::string derr;
    if (!connectData(data, dataIp, dataPort, ctrl, derr)) {
        out["message"] = "数据通道 " + derr;
        out["log"] = g_log;
        return out.dump();
    }

    if (!tlsReadLine(ctrl, reply)) {
        out["message"] = "读取 LIST 应答失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);
    code = reply.size() >= 3
        ? (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0') : -1;
    if (code != 150 && code != 125) {
        out["code"] = std::to_string(code);
        out["message"] = "LIST 被拒: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    std::string stream;
    bool readOk = tlsReadAll(data, stream);
    data.close_();
    logf("data read bytes = " + std::to_string(stream.size()));

    code = -3;
    if (tlsReadLine(ctrl, reply)) {
        logf("< " + reply);
        if (reply.size() >= 3)
            code = (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0');
    }

    // 拆行（CRLF / LF 都认），逐行收集
    nlohmann::json entries = nlohmann::json::array();
    std::string cur;
    for (size_t i = 0; i < stream.size(); i++) {
        if (stream[i] == '\n') {
            if (!cur.empty() && cur[cur.size() - 1] == '\r') cur.resize(cur.size() - 1);
            if (!cur.empty()) entries.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(stream[i]);
        }
    }
    if (!cur.empty()) {
        if (cur[cur.size() - 1] == '\r') cur.resize(cur.size() - 1);
        if (!cur.empty()) entries.push_back(cur);
    }

    out["dir"] = dir;
    out["entries"] = entries;
    if (code / 100 == 2 && readOk) {
        out["ok"] = true;
        out["code"] = std::to_string(code);
        out["message"] = "LIST 成功: " + reply;
        out["log"] = g_log;
        cmd(ctrl, "QUIT", reply);
        return out.dump();
    }
    out["code"] = std::to_string(code);
    out["message"] = "LIST 收尾失败: " + reply;
    out["log"] = g_log;
    return out.dump();
}

// 删除打印机上的一个文件（DELE）。
// 注意：DELE 是**控制口命令**，不需要数据通道 → 不做 PBSZ/PROT、不建数据连接。
// 目录不能删（服务器回 550），UI 侧也只对"非目录"给删除按钮。
std::string removeFile(const std::string& ip,
                       const std::string& user,
                       const std::string& password,
                       const std::string& remote_path)
{
    g_log.clear();
    nlohmann::json out;
    out["ok"] = false;
    out["code"] = "ERR";

    if (remote_path.empty()) {
        out["message"] = "远端路径为空";
        out["log"] = g_log;
        return out.dump();
    }
    std::string path = remote_path;
    if (path[0] != '/') path = "/" + path;

    TlsConn ctrl;
    std::string err;
    if (!tlsConnect(ctrl, ip, FTPS_PORT, err)) {
        out["message"] = "控制通道 " + err;
        out["log"] = g_log;
        return out.dump();
    }
    std::string reply;
    if (!tlsReadLine(ctrl, reply)) {
        out["message"] = "读取 220 问候失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);

    int code = cmd(ctrl, "USER " + user, reply);
    if (code / 100 == 3) code = cmd(ctrl, "PASS " + password, reply);
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "登录失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    code = cmd(ctrl, "DELE " + path, reply);
    out["code"] = std::to_string(code);
    out["remotePath"] = path;
    if (code / 100 == 2) {
        out["ok"] = true;
        out["message"] = "已删除: " + reply;
        out["log"] = g_log;
        cmd(ctrl, "QUIT", reply);
        return out.dump();
    }
    out["message"] = "删除被拒: " + reply;
    out["log"] = g_log;
    return out.dump();
}

// 下载打印机上的一个文件（RETR + TYPE I，边读边落盘）。
// 为什么不在内存里攒完再写：打印机上的 .gcode.3mf 常见几十 MB，攒内存既费堆又可能被 OOM 杀掉；
// 这里直接写文件，并给一个字节上限（超过就中止 + 删掉半截文件）。
std::string download(const std::string& ip,
                     const std::string& user,
                     const std::string& password,
                     const std::string& remote_path,
                     const std::string& local_path,
                     long long max_bytes)
{
    g_log.clear();
    nlohmann::json out;
    out["ok"] = false;
    out["code"] = "ERR";
    out["bytes"] = 0;

    if (remote_path.empty() || local_path.empty()) {
        out["message"] = "远端/本地路径为空";
        out["log"] = g_log;
        return out.dump();
    }
    std::string path = remote_path;
    if (path[0] != '/') path = "/" + path;

    TlsConn ctrl;
    std::string err;
    if (!tlsConnect(ctrl, ip, FTPS_PORT, err)) {
        out["message"] = "控制通道 " + err;
        out["log"] = g_log;
        return out.dump();
    }
    std::string reply;
    if (!tlsReadLine(ctrl, reply)) {
        out["message"] = "读取 220 问候失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);

    // 数据口复用控制口会话（Bambu 服务器 require_ssl_reuse）
    if (mbedtls_ssl_get_session(&ctrl.ssl, &ctrl.session) == 0) {
        ctrl.hasSession = true;
    }

    int code = cmd(ctrl, "USER " + user, reply);
    if (code / 100 == 3) code = cmd(ctrl, "PASS " + password, reply);
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "登录失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    std::string r2;
    int c2 = cmd(ctrl, "PBSZ 0", r2);
    if (c2 / 100 != 2) logf("(PBSZ 非 2xx，忽略)");
    c2 = cmd(ctrl, "PROT P", r2);
    if (c2 / 100 != 2) logf("(PROT P 非 2xx，忽略)");

    // 二进制
    code = cmd(ctrl, "TYPE I", reply);
    if (code / 100 != 2) {
        out["code"] = std::to_string(code);
        out["message"] = "TYPE I 失败: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    int dataPort = -1;
    std::string dataIp = ip;
    code = cmd(ctrl, "EPSV", reply);
    if (code == 229 && parseEpsvPort(reply, dataPort) == 0) {
        // EPSV：数据口与服务器同 IP
    } else {
        code = cmd(ctrl, "PASV", reply);
        if (code != 227 || parsePasv(reply, dataIp, dataPort) != 0) {
            out["code"] = std::to_string(code);
            out["message"] = "被动模式失败: " + reply;
            out["log"] = g_log;
            return out.dump();
        }
    }
    if (dataPort <= 0) {
        out["message"] = "数据端口解析失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("data port = " + std::to_string(dataPort));

    if (!cmdSend(ctrl, "RETR " + path)) {
        out["message"] = "RETR 写入失败";
        out["log"] = g_log;
        return out.dump();
    }

    TlsConn data;
    std::string derr;
    if (!connectData(data, dataIp, dataPort, ctrl, derr)) {
        out["message"] = "数据通道 " + derr;
        out["log"] = g_log;
        return out.dump();
    }

    if (!tlsReadLine(ctrl, reply)) {
        data.close_();
        out["message"] = "读取 RETR 应答失败";
        out["log"] = g_log;
        return out.dump();
    }
    logf("< " + reply);
    code = reply.size() >= 3
        ? (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0') : -1;
    if (code != 150 && code != 125) {
        data.close_();
        out["code"] = std::to_string(code);
        out["message"] = "RETR 被拒: " + reply;
        out["log"] = g_log;
        return out.dump();
    }

    // 边读边写
    FILE* f = fopen(local_path.c_str(), "wb");
    if (f == nullptr) {
        data.close_();
        out["message"] = "本地文件打开失败: " + local_path;
        out["log"] = g_log;
        return out.dump();
    }
    long long written = 0;
    bool readOk = true;
    bool tooBig = false;
    {
        unsigned char buf[8192];
        int idle = 0;
        while (true) {
            int n = mbedtls_ssl_read(&data.ssl, buf, sizeof(buf));
            if (n > 0) {
                if (max_bytes > 0 && written + n > max_bytes) {
                    tooBig = true;
                    break;
                }
                if (fwrite(buf, 1, static_cast<size_t>(n), f) != static_cast<size_t>(n)) {
                    readOk = false;
                    break;
                }
                written += n;
                idle = 0;
                continue;
            }
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) {
                if (++idle > 2) {
                    readOk = false;
                    break;
                }
                continue;
            }
            if (n == 0 || n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
                break;      // 正常收尾
            }
            readOk = false;
            break;
        }
    }
    fclose(f);
    data.close_();
    logf("data written bytes = " + std::to_string(written));

    // 收尾码（226）同样短等：服务器可能已经回完了
    code = -3;
    if (tlsReadLine(ctrl, reply)) {
        logf("< " + reply);
        if (reply.size() >= 3)
            code = (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0');
    }

    out["remotePath"] = path;
    out["localPath"] = local_path;
    out["bytes"] = written;

    if (tooBig) {
        std::remove(local_path.c_str());     // 半截文件不留
        out["code"] = "TOOBIG";
        out["message"] = "文件超过下载上限，已中止（" + std::to_string(written) + " 字节）";
        out["log"] = g_log;
        return out.dump();
    }
    if (readOk && code / 100 == 2) {
        out["ok"] = true;
        out["code"] = std::to_string(code);
        out["message"] = "下载成功: " + reply;
        out["log"] = g_log;
        cmd(ctrl, "QUIT", reply);
        return out.dump();
    }
    out["code"] = std::to_string(code);
    out["message"] = "下载收尾失败: " + reply;
    out["log"] = g_log;
    return out.dump();
}

} // namespace BambuFtps
