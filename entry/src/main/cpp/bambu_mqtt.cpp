#include "bambu_mqtt.hpp"

#include "bambu_state_merge.hpp" // 增量字段合并（纯逻辑，applyReport）与解析辅助

#include "libslic3r/nlohmann/json.hpp"

#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/error.h" // mbedtls_strerror：TLS 握手失败时打印可读错误串

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <hilog/log.h>

#include <atomic>
#include <cerrno> // errno / EAGAIN：明文 socket 读超时判定
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace BambuMqtt {

// 前置声明（定义在本文件后部、匿名命名空间外，供线程函数调用）
bool openSession();
void teardown();

namespace {

// 前置声明：连接生命周期函数相互引用
void readerLoop();
void keepaliveLoop();
void reconnectLoop();
void onSerialLearned(const std::string& sn);

mbedtls_net_context g_serverFd;
mbedtls_ssl_context g_ssl;
mbedtls_ssl_config g_conf;
mbedtls_entropy_context g_entropy;
mbedtls_ctr_drbg_context g_ctrDrbg;

std::mutex g_stateMutex;
PrinterState g_state;
std::string g_serial;
std::string g_ip;
bool g_npEnabled = false; // 新协议(NP)：由 report 的 cfg/fun/aux/stat 检测

// ---- 连接链路诊断（本次任务新增）----
// 当前会话传输是否加密：8883=TLS，1883=明文。所有读写经 connSend/connRecv 分派。
bool g_useTls = true;
int g_activePort = 8883;    // 当前会话实际使用的端口
int g_preferredPort = 8883; // 上次成功的端口；下次直连优先尝试（端口回退「记住成功组合」）
std::string g_clientId;     // 本次会话的 MQTT clientId（每次连接唯一；用于日志自证「不是自己撞自己」）
// 最近一次连接失败的原因码 / 中文可行动原因（供 UI 展示；原始错误码同时写在 MqttConn 日志里）
std::string g_lastErrorCode;
std::string g_lastErrorMessage;

std::atomic<bool> g_connected{false}; // TCP/TLS 会话是否存活（reader 死亡时置 false，触发自愈）
bool g_running = false;               // 用户会话是否激活（false = 用户断开，停止一切含重连）
std::string g_accessCode;             // 保存访问码供断线自动重连
std::thread g_readerThread;
std::thread g_keepaliveThread;
std::thread g_reconnectThread;
std::atomic<bool> g_reconnecting{false};
std::atomic<bool> g_reconnectAbort{false};
std::atomic<bool> g_establishing{false}; // 建立会话阶段（含 SUBACK 等待）：readPacket 据此决定是否用 g_connected 判定断开
std::atomic<bool> g_subscribed{false};   // 订阅是否已确认生效（收到 SUBACK 成功 或 收到任一 PUBLISH）
int64_t g_lastSubRetryMs = 0;            // 上次背景重发订阅的时刻（keepalive 用）
std::mutex g_writeMutex; // 保护写操作（keepalive 与命令发送并发）

// 内存日志缓冲（供日志界面显示，最多保留 200 条）
std::mutex g_logMutex;
std::vector<std::string> g_logs;
// 校准（设备侧 K 值表）相关原始报文留存：协议形状未定案，先存原文再解析。
// 为什么不在 C++ 里直接解析成结构体：请求体字段与应答外层结构都还没有原文样例
// （第三方实现只给了 set 的 ack，没有 get 的应答），先留原文，解析放在 ArkTS 侧
// （可写夹具单测、不需要真机），等抓齐样例再决定是否下沉。
std::mutex g_caliMutex;
std::vector<std::string> g_caliRaw;
constexpr size_t CALI_RAW_MAX = 12;      // 最多留存 12 条（够覆盖一次请求/应答往返）
constexpr size_t CALI_RAW_ITEM_MAX = 24576; // 单条上限 24KB，防超长 push_status 占内存
bool g_dumped = false; // 是否已打印过字段诊断日志（每次连接重置）

// ---- 诊断计数（用于判断"连上但收不到数据"）----
std::atomic<int> g_pushStatusCount{0};   // 本次会话收到的 push_status 报文条数
std::atomic<bool> g_countLogged{false};  // 连接后 N 秒的计数是否已记录（只记一次）
int64_t g_connStartMs = 0;               // 本次会话建立时刻（steady_clock 毫秒）
bool g_resubscribed = false;             // 学到 SN 后是否已重订阅（避免重复重订阅/重复 pushall）

// ---- pushall（只读查询：请打印机全量推一次当前状态）----
std::atomic<bool> g_pushallPending{false}; // 已发送 pushall、等待"收到全量 report"
int64_t g_pushallSentMs = 0;               // pushall 发送时刻（用于超时判定）

// xcam（机器侧 AI 检测开关）原文是否已留存过：只记一次 —— 目的是给"为什么机器没弹提醒"留现场，
// 键名随固件可能微调，首帧原文能一眼看出实际有哪些键（不刷屏）。
std::atomic<bool> g_xcamLogged{false};

int64_t nowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ---- MQTT 3.1.1 编码辅助 ----
int encodeRemainingLength(int len, unsigned char* out)
{
    int i = 0;
    do {
        unsigned char d = len % 128;
        len /= 128;
        if (len > 0) { d |= 0x80; }
        out[i++] = d;
    } while (len > 0);
    return i;
}

void appendStr(std::string& s, const std::string& v)
{
    s += static_cast<char>(0x00);
    s += static_cast<char>(v.size());
    s += v;
}

// 底层收发分派：TLS(8883) 走 mbedtls_ssl_*，明文(1883) 走裸 socket send/recv。
// 端口回退需要同一套 MQTT 报文逻辑在两种传输上都能跑，故统一在此分派。
int connSend(const unsigned char* buf, size_t len)
{
    if (g_useTls) {
        return mbedtls_ssl_write(&g_ssl, buf, len);
    }
    ssize_t n = send(g_serverFd.fd, buf, len, 0);
    return n < 0 ? -1 : static_cast<int>(n);
}

int connRecv(unsigned char* buf, size_t len)
{
    if (g_useTls) {
        return mbedtls_ssl_read(&g_ssl, buf, len);
    }
    ssize_t n = recv(g_serverFd.fd, buf, len, 0);
    return n < 0 ? -1 : static_cast<int>(n);
}

// 前置声明：writeAll 要靠它区分「可重试的写失败」与「真断线」（定义见下）
bool isWouldBlock(int n);

bool writeAll(const unsigned char* buf, size_t len)
{
    std::lock_guard<std::mutex> lock(g_writeMutex);
    size_t off = 0;
    while (off < len) {
        int n = connSend(buf + off, len - off);
        if (n > 0) {
            off += static_cast<size_t>(n);
            continue;
        }
        // 【假断线修复】把「可重试的写失败」和「真断线」分开：
        //   · TLS：mbedtls_ssl_write 返回 WANT_WRITE/WANT_READ 属于正常重试信号
        //     （mbedtls_net_send 把 send() 的 EINTR 映射成 WANT_WRITE；写大报文时也可能需要先读）；
        //   · 明文：EAGAIN/EWOULDBLOCK/EINTR（isWouldBlock 已覆盖）。
        // 之前一律 return false → keepalive 发完 PINGREQ 就把 g_connected 置 false，
        // 把一条**仍在正常收包**的连接判死并触发整轮重连。
        // 日志实证：keepalive ping fail 之后同一连接仍继续收到 PUBLISH，写失败是假的。
        if (isWouldBlock(n) || n == MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (!g_running) { return false; }
            continue;
        }
        return false;
    }
    return true;
}

bool readAll(unsigned char* buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        int n = connRecv(buf + off, len - off);
        if (n <= 0) { return false; }
        off += static_cast<size_t>(n);
    }
    return true;
}

// 底层读返回 n 是否属于“可重试”（非致命，连接仍存活）。
// TLS 用 mbedtls 的 TIMEOUT/WANT_READ/WANT_WRITE；明文 socket 超时/被信号打断表现为
// errno=EAGAIN/EWOULDBLOCK/EINTR（EINTR 若不重试会被误判成断线）。
//
// 【关键修复·假断线】必须接受 MBEDTLS_ERR_NET_RECV_FAILED：
//   我们给 MQTT socket 设了 SO_RCVTIMEO，而 mbedtls_net_recv 把 recv() 超时的 EAGAIN
//   映射成 **NET_RECV_FAILED**（不是 WANT_READ、也不是 SSL_TIMEOUT）。之前这里不接受它，
//   于是打印机只要安静超过超时时间，就被我们判成“连接已关闭”，触发整轮重连——
//   日志实证：`reader break: connection closed rc=-76(0xFFFFFFB4)`（-76 = -0x4C =
//   NET_RECV_FAILED），且会话存活 23~75 秒，说明是「静默超时」而不是打印机断线。
//   真死活由 keepalive 的 PINGRESP 看门狗判定（见 keepaliveLoop）。
bool isWouldBlock(int n)
{
    if (n > 0) { return false; }
    if (g_useTls) {
        return n == MBEDTLS_ERR_SSL_TIMEOUT || n == MBEDTLS_ERR_SSL_WANT_READ
            || n == MBEDTLS_ERR_NET_RECV_FAILED;
    }
    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
}

// 最近一次 readPacket 终止时的「读返回码」——把「对端正常关闭」和「网络错误」分开，
// 因为两者都只会得到 -1，光看 "connection closed" 分不出是谁的锅：
//   0             = 对端发了 FIN / close_notify（**打印机主动、有序地断开**）
//   -0x4E / -0x51 = mbedtls 网络层错误（ECONNRESET / 接收失败）
//   -0x3080       = 收到 close_notify（同样是打印机有序关闭）
//   0x7F01        = 不是读错误：退出是因为 g_connected/g_running 已被别处置 false（keepalive 判定等）
//   0x7F00        = MQTT 报文剩余长度字段非法
int g_lastRecvRc = 0;
const int kRcNoConn = 0x7F01;
const int kRcBadLength = 0x7F00;

// keepalive 看门狗：发出 PINGREQ 后 kPingRespTimeoutMs 内没收到 PINGRESP → 判定连接真的死了。
// 为什么必须补这个：读超时（NET_RECV_FAILED）不再算断线之后，就少了一个「顺带发现对端消失」的信号；
// 用 PINGRESP 应答超时来替代，才是 MQTT 正规的死活判据。
std::atomic<int64_t> g_pingSentMs{0};
std::atomic<bool> g_pingPending{false};
const int64_t kPingRespTimeoutMs = 20000;   // 比发送间隔 15s 大、比服务端 keepalive 20s×1.5=30s 小

// 读取一个完整 MQTT 报文（固定报头 1 字节 + 可变长度 + body），不丢弃任何报文类型。
// 相比原 readAllRetry/固定长度 readAll：先解析报文头拿到“类型 + 真实长度”，
// 再按需收 body，因此 SUBACK/PUBLISH/PINGRESP 混合到达时不会错位或丢包。
// deadlineMs：绝对截止时刻（steady_clock 毫秒）；>0 时超时返回 0（调用方决定重试/放弃）；
//             <=0 时不设截止，仅在连接死亡/用户断开时返回 -1（readerLoop 长期读用）。
// 返回：1=成功（hdr/body 已填充；outTotalLen=整包字节数）；0=超过截止时刻；-1=连接断开/用户停止。
// 说明：建立会话阶段（g_establishing=true）不依据 g_connected 判定断开——此时 g_connected 尚未置位。
int readPacket(unsigned char& hdr, std::string& body, int64_t deadlineMs, int* outTotalLen = nullptr)
{
    body.clear();
    if (outTotalLen) { *outTotalLen = 0; }

    // ---- 固定报头首字节 ----
    unsigned char first = 0;
    while (g_running) {
        int n = connRecv(&first, 1);
        if (n == 1) { break; }
        if (isWouldBlock(n)) {
            if (!g_running) { g_lastRecvRc = kRcNoConn; return -1; }
            if (!g_establishing && !g_connected) { g_lastRecvRc = kRcNoConn; return -1; }
            if (deadlineMs > 0 && nowMs() >= deadlineMs) { return 0; }
            // 读超时（当前窗口内没有数据）不是断线：小睡一下接着等。
            // 加这个 sleep 是为了防止 socket 立即报错时（非超时路径）变成热转。
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        g_lastRecvRc = n;   // 致命读返回码：0=对端有序关闭，负=mbedtls/网络错误
        return -1;
    }
    if (!g_running) { g_lastRecvRc = kRcNoConn; return -1; }
    hdr = first;

    // ---- 剩余长度（可变长度编码，最多 4 字节）----
    int remLen = 0;
    int multiplier = 1;
    int rlBytes = 0;
    bool rlDone = false;
    for (int i = 0; i < 4 && !rlDone; i++) {
        unsigned char b = 0;
        for (;;) {
            int n = connRecv(&b, 1);
            if (n == 1) { break; }
            if (isWouldBlock(n)) {
                if (!g_running) { g_lastRecvRc = kRcNoConn; return -1; }
                if (!g_establishing && !g_connected) { g_lastRecvRc = kRcNoConn; return -1; }
                if (deadlineMs > 0 && nowMs() >= deadlineMs) { return 0; }
                continue;
            }
            g_lastRecvRc = n;
            return -1;
        }
        remLen += (b & 0x7F) * multiplier;
        multiplier *= 128;
        rlBytes++;
        if ((b & 0x80) == 0) { rlDone = true; }
    }
    if (!rlDone) { g_lastRecvRc = kRcBadLength; return -1; } // 非法剩余长度
    if (outTotalLen) { *outTotalLen = 1 + rlBytes + remLen; }

    // ---- 报文体 ----
    if (remLen > 0) {
        body.resize(static_cast<size_t>(remLen));
        size_t off = 0;
        while (off < body.size()) {
            int n = connRecv(reinterpret_cast<unsigned char*>(&body[0]) + off, body.size() - off);
            if (n > 0) {
                off += static_cast<size_t>(n);
                continue;
            }
            if (isWouldBlock(n)) {
                if (!g_running) { g_lastRecvRc = kRcNoConn; return -1; }
                if (!g_establishing && !g_connected) { g_lastRecvRc = kRcNoConn; return -1; }
                if (deadlineMs > 0 && nowMs() >= deadlineMs) { return 0; }
                continue;
            }
            g_lastRecvRc = n;
            return -1;
        }
    }
    return 1;
}

// MQTT 3.1.1 CONNACK 返回码 → 中文说明（按规范）
std::string connackMeaning(int code)
{
    switch (code) {
    case 0: return "连接已接受";
    case 1: return "不支持的协议版本";
    case 2: return "客户端标识符无效";
    case 3: return "服务端不可用";
    case 4: return "用户名或访问码错误";
    case 5: return "未授权（可能未开启局域网模式/开发者模式）";
    default: return "未知返回码";
    }
}

bool mqttConnect(const std::string& username, const std::string& password)
{
    // 客户端标识：**每次会话唯一**（bambu_hm_<8位十六进制>）。
    // 之前写死常量 "bambu_hm" 会撞 ID：Broker 按 MQTT 规范「同 ID 新连接进来就把旧连接踢掉」，
    // 于是只要同网段还有另一条同 ID 连接（自己的旧会话、上一次断线没清干净的连接、
    // 或另一台装了同款 app 的设备），就会互相踢 → 表现成「好好的突然断、随后温度读数消失」。
    // 长度 17 字符，符合 MQTT 3.1.1 对 clientId 1~23 字符的建议上限。
    static std::atomic<unsigned int> s_clientSeq{0};
    unsigned int seq = s_clientSeq.fetch_add(1, std::memory_order_relaxed) + 1;
    unsigned int mix = static_cast<unsigned int>(nowMs()) ^ (seq * 2654435761u);
    char suffix[9];
    std::snprintf(suffix, sizeof(suffix), "%08x", mix);
    std::string clientId = std::string("bambu_hm_") + suffix;
    g_clientId = clientId; // 供步骤4 日志自证（每次连接唯一）

    std::string vh;
    vh += static_cast<char>(0x00);
    vh += static_cast<char>(0x04);
    vh += "MQTT";                 // 协议名
    vh += static_cast<char>(0x04); // 版本 3.1.1
    vh += static_cast<char>(0xC2); // username + password + clean session
    vh += static_cast<char>(0x00);
    vh += static_cast<char>(0x14); // keepalive 20s

    std::string payload;
    appendStr(payload, clientId);
    appendStr(payload, username);
    appendStr(payload, password);

    int total = static_cast<int>(vh.size() + payload.size());
    unsigned char rl[4];
    int rlLen = encodeRemainingLength(total, rl);

    std::string packet;
    packet += static_cast<char>(0x10); // CONNECT
    packet.append(reinterpret_cast<char*>(rl), rlLen);
    packet += vh;
    packet += payload;
    return writeAll(reinterpret_cast<const unsigned char*>(packet.c_str()), packet.size());
}

bool mqttSubscribe(const std::string& topic)
{
    unsigned char packetId[2] = { 0x00, 0x01 };
    std::string payload;
    appendStr(payload, topic);
    payload += static_cast<char>(0x00); // QoS 0

    int total = 2 + static_cast<int>(payload.size());
    unsigned char rl[4];
    int rlLen = encodeRemainingLength(total, rl);

    std::string packet;
    packet += static_cast<char>(0x82); // SUBSCRIBE
    packet.append(reinterpret_cast<char*>(rl), rlLen);
    packet.append(reinterpret_cast<char*>(packetId), 2);
    packet += payload;
    return writeAll(reinterpret_cast<const unsigned char*>(packet.c_str()), packet.size());
}

bool mqttPublish(const std::string& topic, const std::string& payload)
{
    // 会话已死或用户已断开时拒绝写入（写进死 socket 只会假成功）
    if (!g_running || !g_connected) { return false; }
    // 递增 packet id（QoS 1 需要）
    static unsigned short g_packetId = 0;
    g_packetId++;

    int total = 2 + static_cast<int>(topic.size()) + 2 + static_cast<int>(payload.size());
    unsigned char rl[4];
    int rlLen = encodeRemainingLength(total, rl);

    std::string packet;
    packet += static_cast<char>(0x32); // PUBLISH QoS 1（打印机会忽略 QoS 0）
    packet.append(reinterpret_cast<char*>(rl), rlLen);
    appendStr(packet, topic);
    packet += static_cast<char>((g_packetId >> 8) & 0xFF);
    packet += static_cast<char>(g_packetId & 0xFF);
    packet += payload;
    return writeAll(reinterpret_cast<const unsigned char*>(packet.c_str()), packet.size());
}

// 发送只读 pushall：请求打印机把"当前状态全量推一次"。
// 注意：这只是信息查询，不驱动任何硬件（不打印/不调平/不移轴/不设温）。
// 为什么必需：A1/P1 系是增量上报（只发相对上帧变化过的字段），必须靠 pushall 拉一次全量基线；
// X1 系本就是全量上报，发之无害，统一发送。
void sendPushAll(const std::string& sn)
{
    std::string reqTopic = "device/" + sn + "/request";
    std::string cmd = "{\"pushing\":{\"sequence_id\":\"1\",\"command\":\"pushall\",\"version\":1,\"push_target\":1}}";
    bool sent = mqttPublish(reqTopic, cmd);
    if (sent) {
        g_pushallPending.store(true, std::memory_order_relaxed);
        g_pushallSentMs = nowMs();
    }
    addLogTagged("MqttSn", "pushall 已发送 topic=" + reqTopic + " 发送结果=" + (sent ? "成功" : "失败"));
}

// 学到真实序列号后：重订阅精确 topic + 发只读 pushall（请求全量状态）。
// 仅在 readerLoop 内、g_serial 首次由空变非空时调用一次（由 g_resubscribed 守卫）。
void onSerialLearned(const std::string& sn)
{
    g_resubscribed = true;
    std::string reportTopic = "device/" + sn + "/report";
    bool subOk = mqttSubscribe(reportTopic);
    addLogTagged("MqttSn", "重订阅 topic=" + reportTopic + " 结果=" + (subOk ? "已发送" : "发送失败"));
    sendPushAll(sn);
}

// 留存一条"与设备侧校准相关"的原始报文（环形缓冲，最多 CALI_RAW_MAX 条）。
// 判据是关键字命中而非 JSON 结构：协议形状未定案，宁可多存也不漏。
void cacheCaliRaw(const std::string& payload)
{
    std::string item = payload;
    if (item.size() > CALI_RAW_ITEM_MAX) {
        item = item.substr(0, CALI_RAW_ITEM_MAX) + "...(truncated)";
    }
    {
        std::lock_guard<std::mutex> lock(g_caliMutex);
        if (g_caliRaw.size() >= CALI_RAW_MAX) {
            g_caliRaw.erase(g_caliRaw.begin());
        }
        g_caliRaw.push_back(item);
    }
    addLogTagged("MqttCali", "留存校准报文 len=" + std::to_string(payload.size()) +
        " 预览=" + item.substr(0, 160));
}

// 解析 printer report JSON，更新状态
// 注意：Bambu report 的状态字段全部嵌套在 "print" 对象内（温度/风扇/AMS 均如此）
void handleMessage(const std::string& payload)
{
    // 设备侧校准（K 值）相关报文原样留存：请求体/应答结构都还没有原文样例，
    // 先存原文 + 打一行日志，等有真机时一次性核对（不需要改代码）。
    if (payload.find("extrusion_cali") != std::string::npos ||
        payload.find("k_value") != std::string::npos ||
        payload.find("cali_idx") != std::string::npos ||
        payload.find("kprofile") != std::string::npos) {
        cacheCaliRaw(payload);
    }
    try {
        nlohmann::json j = nlohmann::json::parse(payload);
        if (!j.contains("print") || !j["print"].is_object()) {
            // 打印 system 命令响应结果（result/reason），用于调试
            if (j.contains("system") && j["system"].is_object()) {
                std::string extra;
                if (j["system"].contains("result") && j["system"]["result"].is_string()) {
                    extra += " result=" + j["system"]["result"].get<std::string>();
                }
                if (j["system"].contains("reason") && j["system"]["reason"].is_string()) {
                    extra += " reason=" + j["system"]["reason"].get<std::string>();
                }
                if (!extra.empty()) {
                    addLog("system-ack" + extra);
                }
            }
            return; // 非完整状态报文（如 hello/pushall 等），忽略
        }
        const nlohmann::json& p = j["print"];

        // 只处理真正的状态推送（push_status 或无 command），忽略命令回显
        // （Bambu 会把命令字段回显在 ack 里，那不是打印机状态）
        if (p.contains("command") && p["command"].is_string() && p["command"].get<std::string>() != "push_status") {
            std::string extra = " cmd=" + p["command"].get<std::string>();
            if (p.contains("result") && p["result"].is_string()) {
                extra += " result=" + p["result"].get<std::string>();
            }
            if (p.contains("reason") && p["reason"].is_string()) {
                extra += " reason=" + p["reason"].get<std::string>();
            }
            addLog("print-ack" + extra);
            return;
        }

        // 新协议(NP)检测（官方 check_enable_np 逻辑：cfg/fun/aux/stat 四字段齐全）
        // NP 打印机 AMS 槽位刷新走 ams_get_rfid JSON，旧协议走 M620 R gcode
        g_npEnabled = p.contains("cfg") && p.contains("fun") && p.contains("aux") && p.contains("stat");

        // 一次性调试：打印 print 对象全部字段名，确认 chamber/ams 真实结构
        if (!g_dumped) {
            g_dumped = true;
            std::string keys;
            for (auto it = p.begin(); it != p.end(); ++it) {
                if (!keys.empty()) keys += ",";
                keys += it.key();
            }
            addLog("print keys=" + keys.substr(0, 600));
            // 搜索所有温度/腔体相关字段名
            std::string tempFields;
            for (auto it = p.begin(); it != p.end(); ++it) {
                std::string k = it.key();
                if (k.find("temp") != std::string::npos || k.find("chamber") != std::string::npos || k.find("ctc") != std::string::npos) {
                    if (!tempFields.empty()) tempFields += ",";
                    tempFields += k;
                }
            }
            addLog("temp-related fields=" + tempFields);
            // 打印风扇字段原始值（确认刻度与字段映射）
            nlohmann::json fanObj = nlohmann::json::object();
            if (p.contains("cooling_fan_speed")) fanObj["cooling_fan_speed"] = p["cooling_fan_speed"];
            if (p.contains("aux")) fanObj["aux"] = p["aux"];
            if (p.contains("aux_part_fan")) fanObj["aux_part_fan"] = p["aux_part_fan"];
            if (p.contains("big_fan1_speed")) fanObj["big_fan1_speed"] = p["big_fan1_speed"];
            if (p.contains("big_fan2_speed")) fanObj["big_fan2_speed"] = p["big_fan2_speed"];
            if (p.contains("heatbreak_fan_speed")) fanObj["heatbreak_fan_speed"] = p["heatbreak_fan_speed"];
            if (p.contains("fan_gear")) fanObj["fan_gear"] = p["fan_gear"];
            addLog("fan raw=" + fanObj.dump());
            // 打印 ipcam 字段原始值（确认 rtsp_url 和类型）
            if (p.contains("ipcam")) {
                addLog("ipcam raw=" + p["ipcam"].dump());
            }
            // 打印 print.info 对象结构（腔体温度可能藏在这里）
            if (p.contains("info") && p["info"].is_object()) {
                std::string infoKeys;
                for (auto it = p["info"].begin(); it != p["info"].end(); ++it) {
                    if (!infoKeys.empty()) infoKeys += ",";
                    infoKeys += it.key();
                }
                addLog("print.info keys=" + infoKeys.substr(0, 400));
            } else {
                addLog("NO print.info");
            }
            if (p.contains("ams")) {
                const auto& ams = p["ams"];
                std::string amsKeys;
                for (auto it = ams.begin(); it != ams.end(); ++it) {
                    if (!amsKeys.empty()) amsKeys += ",";
                    amsKeys += it.key();
                }
                addLog("ams keys=" + amsKeys.substr(0, 400));
                if (ams.contains("ams") && ams["ams"].is_array() && !ams["ams"].empty()) {
                    addLog("ams.ams is_array=true size=" + std::to_string(ams["ams"].size()));
                    const auto& unit0 = ams["ams"][0];
                    std::string unitKeys;
                    for (auto it = unit0.begin(); it != unit0.end(); ++it) {
                        if (!unitKeys.empty()) unitKeys += ",";
                        unitKeys += it.key();
                    }
                    addLog("ams[0] keys=" + unitKeys.substr(0, 300));
                    if (unit0.contains("tray") && unit0["tray"].is_array() && !unit0["tray"].empty()) {
                        const auto& tray0 = unit0["tray"][0];
                        std::string trayKeys;
                        for (auto it = tray0.begin(); it != tray0.end(); ++it) {
                            if (!trayKeys.empty()) trayKeys += ",";
                            trayKeys += it.key();
                        }
                        addLog("ams[0].tray[0] keys=" + trayKeys.substr(0, 300));
                    } else {
                        addLog("NO ams[0].tray or empty");
                    }
                    addLog("parseAms result=" + parseAms(ams).substr(0, 200));
                } else {
                    addLog("NO ams.ams or empty");
                }
            } else {
                addLog("NO ams field");
            }
            // 一次性打印 NP 检测结果（AMS 刷新协议选择依据）
            addLog(std::string("np mode=") + (g_npEnabled ? "true (ams_get_rfid)" : "false (M620 R)"));
        }

        // 增量字段合并：以上次已知状态为基线，只覆盖本帧 JSON 里出现的字段。
        // （P1/A1 系只发相对上帧变化过的字段；若每帧 new 一个默认全 0 的 PrinterState，
        //  未上报的温度/进度会被清零 → 客户实测"A1 热床显示错误 / 喷嘴读不到"。）
        PrinterState st;
        {
            std::lock_guard<std::mutex> lock(g_stateMutex);
            st = g_state; // 沿用上次已知值（合并基线）
        }
        st.connected = true;
        st.serial = g_serial;
        st.ip = g_ip;
        st.npEnabled = g_npEnabled;

        // 计数：仅统计真正的状态推送（push_status 或无 command），用于"连上但收不到数据"诊断
        g_pushStatusCount.fetch_add(1, std::memory_order_relaxed);

        // 只覆盖本帧出现的字段；未出现的字段沿用 st 中的上次值（绝不用 0 / -1 / 空 覆盖）
        std::string frameFields;
        std::string inheritedFields;
        int frameCount = 0;
        applyReport(p, st, frameFields, inheritedFields, frameCount);

        // 每帧打印"本帧携带的字段列表 + 沿用上次值的字段列表"，便于后续核对增量上报行为
        addLog("本帧字段: " + (frameFields.empty() ? std::string("(无)") : frameFields)
            + "（共" + std::to_string(frameCount) + "项）；沿用上次值: "
            + (inheritedFields.empty() ? std::string("(无)") : inheritedFields));

        // HMS 原文留存：真出现故障时把设备上报的 {attr,code} 原样打进日志（含 hilog 与日志页）。
        // 为什么值得单独记：HMS 是低频事件（健康时是空数组），而排查"码表查不到文案"时必须知道
        // 设备到底报的是哪两个整数 —— 这条日志是唯一能事后取证的现场，且只在非空时才写（不刷屏）。
        if (!st.hmsJson.empty() && st.hmsJson != "[]") {
            addLogTagged("HmsRaw", "HMS 上报原文: " + st.hmsJson);
        }
        // xcam 原文（机器侧 AI 检测开关）：只在首次出现时留一份，供核对键名
        if (!st.xcamJson.empty() && !g_xcamLogged.exchange(true)) {
            addLogTagged("XcamRaw", "AI 检测开关原文: " + st.xcamJson);
        }

        // 一帧里没有任何已支持字段 → 把原文打出来（截断）。这类帧以前只记「(无)」，等于把线索丢掉；
        // 打印机在关连接前反复发的那种 ~119 字节帧就属于这一类，很可能就是它要说的话。
        if (frameCount == 0) {
            addLog("未识别帧原文: " + payload.substr(0, 400));
        }

        st.rawJson = payload;
        // 本会话状态推送计数（供 UI 区分“已连接”与“已连接但未收到状态数据”）
        st.pushStatusCount = g_pushStatusCount.load(std::memory_order_relaxed);

        char buf[200];
        snprintf(buf, sizeof(buf), "state=%s nozzle=%.1f(%s) bed=%.1f(%s) chamber=%.1f(%s) fan=%d/%d/%d",
            st.gcodeState.c_str(),
            st.nozzleTemp, st.hasNozzleTemp ? "known" : "unknown",
            st.bedTemp, st.hasBedTemp ? "known" : "unknown",
            st.chamberTemp, st.hasChamberTemp ? "known" : "unknown",
            st.partFan, st.auxFan, st.chamberFan);
        addLog(buf);

        // pushall 回执：本会话发出的 pushall 收到第一条状态即视为"收到全量"
        if (g_pushallPending.exchange(false, std::memory_order_relaxed)) {
            addLogTagged("MqttSn", "pushall 已发送 结果=收到全量（首条 report 本帧字段"
                + std::to_string(frameCount) + "项）");
        }

        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_state = st;
        g_connected = true;
    } catch (const std::exception& e) {
        addLog(std::string("parse-fail ") + e.what() + " payload=" + payload.substr(0, 200));
    } catch (...) {
        addLog("parse-fail payload=" + payload.substr(0, 200));
    }
}

// MQTT 报文类型名（原始日志用，便于 hdc 日志区分 SUBACK/PUBLISH…）
const char* mqttTypeName(unsigned char type)
{
    switch (type) {
    case 1: return "CONNECT";
    case 2: return "CONNACK";
    case 3: return "PUBLISH";
    case 4: return "PUBACK";
    case 5: return "PUBREC";
    case 6: return "PUBREL";
    case 7: return "PUBCOMP";
    case 8: return "SUBSCRIBE";
    case 9: return "SUBACK";
    case 10: return "UNSUBSCRIBE";
    case 11: return "UNSUBACK";
    case 12: return "PINGREQ";
    case 13: return "PINGRESP";
    case 14: return "DISCONNECT";
    default: return "RESERVED";
    }
}

// 原始报文日志：把每个收到的 MQTT 报文类型/长度打出来（SUBACK 附返回码）。
// 目的：区分 SUBACK 到底有没有读到（超时 / 被先到的 PUBLISH 顶掉 / 编码被 broker 拒）。
void logPacket(unsigned char hdr, const std::string& body, int totalLen)
{
    unsigned char type = hdr >> 4;
    char buf[160];
    if (type == 9) {
        int rc = body.size() >= 3 ? static_cast<unsigned char>(body[2]) : -1;
        snprintf(buf, sizeof(buf), "recv type=9(SUBACK) len=%d returncode=%d", totalLen, rc);
        addLog(buf);
    } else if (type == 3 && body.size() >= 2) {
        int topicLen = (static_cast<unsigned char>(body[0]) << 8) | static_cast<unsigned char>(body[1]);
        unsigned char qos = (hdr >> 1) & 0x03;
        std::string topic = body.substr(2, static_cast<size_t>(topicLen));
        snprintf(buf, sizeof(buf), "recv type=3(PUBLISH) qos=%d len=%d topic=%s",
            qos, totalLen, topic.c_str());
        addLog(buf);
    } else {
        snprintf(buf, sizeof(buf), "recv type=%d(%s) len=%d", type, mqttTypeName(type), totalLen);
        addLog(buf);
    }
}

// 解析 SUBACK 返回码（body = packetId 2B + 每 topic 1B 返回码）。0x80 = 该订阅被 broker 拒绝。
void parseSuback(const std::string& body, std::string& rcList, bool& rejected)
{
    rejected = false;
    rcList.clear();
    size_t start = body.size() >= 2 ? 2 : 0;
    for (size_t i = start; i < body.size(); i++) {
        unsigned int rc = static_cast<unsigned char>(body[i]);
        if (!rcList.empty()) { rcList += ","; }
        rcList += std::to_string(rc);
        if ((rc & 0x80) != 0) { rejected = true; }
    }
    if (rcList.empty()) { rcList = "(空)"; }
}

// 处理一条 PUBLISH：解析 topic/payload；SN 为空时从 topic 学出序列号；再交给 handleMessage 更新状态。
// readerLoop 与建立阶段的 SUBACK 等待循环共用，保证"等 SUBACK 期间先到的状态推送"也会被处理，绝不丢弃。
void handlePublishPacket(unsigned char hdr, const std::string& body)
{
    if (body.size() < 2) { return; }
    int topicLen = (static_cast<unsigned char>(body[0]) << 8) | static_cast<unsigned char>(body[1]);
    unsigned char qos = (hdr >> 1) & 0x03;
    int payloadOffset = 2 + topicLen + (qos > 0 ? 2 : 0); // QoS1/2 带 packet id
    std::string topic = body.substr(2, static_cast<size_t>(topicLen));
    std::string payload = (payloadOffset >= 0 && payloadOffset <= static_cast<int>(body.size()))
        ? body.substr(static_cast<size_t>(payloadOffset)) : std::string();

    // 收到任何 PUBLISH ⇒ 订阅确实生效（即便 SUBACK 丢失/被顶掉），停止背景重复订阅
    g_subscribed = true;

    // 手动连接（SN 为空）：从 device/{serial}/report 里学出序列号。
    // 这是"通配订阅 device/+/report 收到报文 → 从 topic 反解 SN"的自愈路径。
    if (g_serial.empty()) {
        const std::string prefix = "device/";
        const std::string suffix = "/report";
        if (topic.size() > prefix.size() + suffix.size() &&
            topic.compare(0, prefix.size(), prefix) == 0 &&
            topic.compare(topic.size() - suffix.size(), suffix.size(), suffix) == 0) {
            std::string sn = topic.substr(prefix.size(), topic.size() - prefix.size() - suffix.size());
            if (!sn.empty()) {
                g_serial = sn;
                {
                    std::lock_guard<std::mutex> lock(g_stateMutex);
                    g_state.serial = sn;
                }
                addLog("learned serial from topic=" + sn);
                addLogTagged("MqttSn", "SN 来源=通配订阅 值=" + sn + " 订阅结果=成功");
                // 学到 SN 后重订阅精确 topic 并发只读 pushall（只需一次）
                if (!g_resubscribed) {
                    onSerialLearned(sn);
                }
            }
        }
    }

    handleMessage(payload);
}

void readerLoop()
{
    addLog("readerLoop start");
    while (g_running) {
        unsigned char hdr = 0;
        std::string body;
        int totalLen = 0;
        int pr = readPacket(hdr, body, 0, &totalLen);
        if (pr == 0) {
            continue; // deadline<=0 时不返回 0；保险起见按超时继续
        }
        if (pr < 0) {
            // 把「谁关的连接」写清楚：rc=0 是打印机有序关闭（FIN/close_notify），负值是 mbedtls
            // 网络错误，0x7F01 是别处已把 g_connected 置 false（keepalive 判定等）。会话存活时长
            // 用于判断是否固定周期（例如正好 ~20s/keepalive 相关）。
            char b[176];
            std::snprintf(b, sizeof(b), "reader break: connection closed rc=%d(0x%X) 会话存活=%lldms",
                g_lastRecvRc, static_cast<unsigned>(g_lastRecvRc),
                static_cast<long long>(nowMs() - g_connStartMs));
            addLog(b);
            break;
        }
        unsigned char type = hdr >> 4;

        // 原始报文类型/长度日志（本次修复新增）：每条都打，用于区分 SUBACK 是否被读到
        logPacket(hdr, body, totalLen);

        if (type == 3) { // PUBLISH
            handlePublishPacket(hdr, body);
        } else if (type == 13) { // PINGRESP：keepalive 看门狗的应答，表明连接确实活着
            g_pingPending.store(false, std::memory_order_relaxed);
        } else if (type == 9) { // SUBACK
            std::string rcList;
            bool rejected = false;
            parseSuback(body, rcList, rejected);
            if (rejected) {
                g_subscribed = false;
                addLogTagged("MqttConn", "订阅被拒 SUBACK returncode=" + rcList + " → 标记未订阅，将继续重试");
            } else {
                g_subscribed = true;
                addLogTagged("MqttConn", "订阅确认 SUBACK 成功 returncode=" + rcList);
            }
        }
        // 其它包（CONNACK/PINGRESP/PUBACK…）已由 logPacket 记录，无需额外处理
    }
    addLog("readerLoop exit");
    // 非用户断开的连接死亡 → 自动重连（打印机网络闪断后 app 自愈，无需手动重连）
    if (g_running) {
        g_connected = false;
        {
            std::lock_guard<std::mutex> lock(g_stateMutex);
            g_state.connected = false;
        }
        if (!g_reconnecting.exchange(true)) {
            if (g_reconnectThread.joinable()) { g_reconnectThread.join(); }
            g_reconnectThread = std::thread(reconnectLoop);
        }
    }
}

// 定期发送 PINGREQ 保持 MQTT 连接存活（keepalive=20s，客户端必须主动发送）
void keepaliveLoop()
{
    auto lastPing = std::chrono::steady_clock::now();
    while (g_running) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        if (!g_running || !g_connected) { break; } // 连接已死 → 退出，交由重连线程处理
        // 【MqttSn】连接后 8 秒统计一次 push_status 条数：用于判断"连上但收不到数据"
        // （若为 0，说明订阅 topic 与该打印机实际上报 topic 不匹配，或 SN 未学到）。
        // 只统计一次，不是超时控制，不改变任何连接/重连行为。
        if (!g_countLogged.load(std::memory_order_relaxed) &&
            nowMs() - g_connStartMs >= 8000) {
            g_countLogged.store(true, std::memory_order_relaxed);
            std::string snValue = g_serial.empty() ? "(空)" : g_serial;
            addLogTagged("MqttSn", "连接后8s内收到状态(push_status)="
                + std::to_string(g_pushStatusCount.load(std::memory_order_relaxed))
                + "条 当前SN=" + snValue);
        }
        // 【pushall 回执超时】发出 pushall 后 4s 内未收到任何 report → 记录"结果=超时"
        if (g_pushallPending.load(std::memory_order_relaxed) && nowMs() - g_pushallSentMs >= 4000) {
            g_pushallPending.store(false, std::memory_order_relaxed);
            addLogTagged("MqttSn", "pushall 已发送 结果=超时（4s 内未收到全量 report）");
        }
        // 【订阅自愈】订阅尚未确认（未收到 SUBACK / 未收到任何状态推送）时，每 5 秒重发一次订阅，
        // 直到生效（收到 SUBACK 或任一 PUBLISH）。修复"SUBACK 丢失即彻底收不到数据"的问题。
        if (!g_subscribed.load(std::memory_order_relaxed) && nowMs() - g_lastSubRetryMs >= 5000) {
            g_lastSubRetryMs = nowMs();
            std::string t = g_serial.empty() ? std::string("device/+/report")
                                             : ("device/" + g_serial + "/report");
            bool sent = mqttSubscribe(t);
            addLogTagged("MqttConn", "订阅未确认→重发订阅 topic=" + t + " 结果=" + (sent ? "已发送" : "发送失败")
                + " 已收状态=" + std::to_string(g_pushStatusCount.load(std::memory_order_relaxed)) + "条");
        }
        // 【真死活看门狗】上一个 PINGREQ 在规定时间内没等到 PINGRESP → 连接确实死了。
        // 读超时不再算断线之后，必须靠这里把「对端悄悄消失」判出来，否则会一直假装在线。
        if (g_pingPending.load(std::memory_order_relaxed) &&
            nowMs() - g_pingSentMs.load(std::memory_order_relaxed) > kPingRespTimeoutMs) {
            addLogTagged("MqttConn", "keepalive PINGRESP 超时（"
                + std::to_string(kPingRespTimeoutMs / 1000) + "s 未收到）→ 判定连接已死，触发重连");
            g_connected = false; // 通知 readerLoop 退出并触发重连
            break;
        }
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - lastPing).count() >= 15) {
            lastPing = now;
            unsigned char ping[2] = { 0xC0, 0x00 }; // MQTT PINGREQ
            if (!writeAll(ping, 2)) {
                addLog("keepalive ping fail");
                g_connected = false; // 通知 readerLoop 退出并触发重连
                break;
            }
            g_pingSentMs.store(nowMs(), std::memory_order_relaxed);
            g_pingPending.store(true, std::memory_order_relaxed);
        }
    }
}

// 断线自动重连：每 3 秒尝试一次，直到成功或用户断开
void reconnectLoop()
{
    addLog("mqtt reconnect: start");
    int attempt = 0;
    while (g_running && !g_reconnectAbort) {
        // 3 秒退避（100ms 步进，随时可被用户断开/新连接中断）
        for (int i = 0; i < 30; i++) {
            if (!g_running || g_reconnectAbort) { break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!g_running || g_reconnectAbort) { break; }
        attempt++;
        addLog("mqtt reconnect: attempt " + std::to_string(attempt));
        if (openSession()) {
            addLog("mqtt reconnect: success");
            break;
        }
    }
    g_reconnecting = false;
}

// 停止重连线程（用户主动断开或发起新连接时调用）
void stopReconnect()
{
    g_reconnectAbort = true;
    if (g_reconnectThread.joinable()) {
        g_reconnectThread.join();
    }
    g_reconnectAbort = false;
    g_reconnecting = false;
}

// 单次连接尝试的结果（用于逐步诊断 + 端口回退）
struct Attempt {
    bool ok = false;
    std::string step;      // 失败发生在哪一步（TCP connect / TLS 握手 / CONNACK / SUBACK …）
    std::string detail;    // 原始错误码/字符串（errno / mbedtls rc / CONNACK code …）
    std::string uiCode;    // UI 用原因码
    std::string uiMessage; // UI 用中文可行动原因
};

// 用指定端口/传输方式尝试建立一次完整会话（socket → [TLS] → MQTT → 订阅 → 启线程）。
// 每步都写 MqttConn 日志（hilog + 应用日志页）；失败路径自行清理并返回带原因的 Attempt。
Attempt establishOnce(int port, bool tls)
{
    Attempt r;
    r.step = "初始化";
    g_useTls = tls;
    g_activePort = port;

    teardown();

    // 建立会话阶段标志：等待 SUBACK 时 readPacket 不依据 g_connected（此时尚未置位）判定断开
    struct EstablishGuard {
        EstablishGuard() { g_establishing = true; }
        ~EstablishGuard() { g_establishing = false; }
    } establishGuard;

    g_dumped = false;
    // 会话级诊断计数复位（每次尝试）
    g_connStartMs = nowMs();
    g_pushStatusCount.store(0, std::memory_order_relaxed);
    g_countLogged.store(false, std::memory_order_relaxed);
    g_resubscribed = false;
    g_subscribed.store(false, std::memory_order_relaxed);
    g_lastSubRetryMs = 0;
    g_pushallPending.store(false, std::memory_order_relaxed);
    g_pushallSentMs = 0;
    // keepalive 看门狗状态也复位：否则上一条会话残留的 PINGREQ 计时会立刻把新会话判死
    g_pingPending.store(false, std::memory_order_relaxed);
    g_pingSentMs = 0;

    addLog("connect ip=" + g_ip + " serial=" + g_serial); // 兼容旧日志行
    addLogTagged("MqttConn", "开始连接 ip=" + g_ip + " serial=" + (g_serial.empty() ? "(空)" : g_serial));

    mbedtls_net_init(&g_serverFd);
    mbedtls_ssl_init(&g_ssl);
    mbedtls_ssl_config_init(&g_conf);
    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_ctrDrbg);
    mbedtls_ctr_drbg_seed(&g_ctrDrbg, mbedtls_entropy_func, &g_entropy, nullptr, 0);

    // 1) DNS/直连：本实现只用 IP 直连、不做域名解析，仍显式打一条便于客户核对
    addLogTagged("MqttConn", "步骤1 DNS/直连：目标 " + g_ip + ":" + std::to_string(port)
        + "（IP 直连，无 DNS 解析）");

    // 2) TCP connect
    r.step = "TCP connect";
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        r.detail = "socket() 失败 errno=" + std::to_string(errno) + " (" + strerror(errno) + ")";
        r.uiCode = "SOCKET";
        r.uiMessage = "本机无法创建网络套接字（errno=" + std::to_string(errno) + "）";
        addLogTagged("MqttConn", "步骤2 TCP：socket 创建失败 " + r.detail);
        teardown();
        return r;
    }
    timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, g_ip.c_str(), &addr.sin_addr) != 1) {
        r.detail = "IP 地址非法：" + g_ip;
        r.uiCode = "BAD_IP";
        r.uiMessage = "IP 地址非法（" + g_ip + "）—— 请填写打印机在局域网中的 IPv4 地址";
        addLogTagged("MqttConn", "步骤2 TCP：IP 非法 " + g_ip);
        close(sock);
        teardown();
        return r;
    }
    int64_t tcpT0 = nowMs();
    int crc = ::connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    int64_t tcpMs = nowMs() - tcpT0;
    if (crc != 0) {
        int e = errno;
        r.detail = "errno=" + std::to_string(e) + " (" + strerror(e) + ") 耗时=" + std::to_string(tcpMs) + "ms";
        r.uiCode = "TCP_UNREACHABLE";
        r.uiMessage = "TCP 不可达（" + g_ip + ":" + std::to_string(port)
            + "）—— 请确认打印机已开启局域网模式、与手机处于同一网段";
        addLogTagged("MqttConn", "步骤2 TCP connect 失败 ip=" + g_ip + ":" + std::to_string(port) + " " + r.detail);
        close(sock);
        teardown();
        return r;
    }
    g_serverFd.fd = sock;
    addLogTagged("MqttConn", "步骤2 TCP connect 成功 ip=" + g_ip + ":" + std::to_string(port)
        + " 耗时=" + std::to_string(tcpMs) + "ms");

    // 3) TLS 握手（仅 8883）
    if (tls) {
        r.step = "TLS 握手";
        mbedtls_ssl_config_defaults(&g_conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
        mbedtls_ssl_conf_rng(&g_conf, mbedtls_ctr_drbg_random, &g_ctrDrbg);
        // 打印机 LAN 用自签名证书、无域名 → 不做证书链校验（VERIFY_NONE）。
        mbedtls_ssl_conf_authmode(&g_conf, MBEDTLS_SSL_VERIFY_NONE);
        // 【TLS 兼容性放宽】显式把版本范围设为 TLS1.2 ~ TLS1.3：
        //   - 为什么放宽：老固件（如 A1 mini 01.03.x）TLS 能力可能偏弱，锁定单一高版本会握手失败；
        //     把下限设为 TLS1.2 而非 TLS1.3，让老固件能用它支持的 TLS1.2 协商（mbedtls 3.6 最低即 TLS1.2，
        //     已不再支持 TLS1.0/1.1，故无法进一步下调）；上限 TLS1.3 保持新固件可走新版本。
        //   - 不设置 MBEDTLS_SSL_CIPHERSUITES，套件交给 mbedtls 默认全集（含 ECDHE_RSA/ECDHE_ECDSA/RSA 等），
        //     最大化与老固件的交集。
        //   - 安全影响：下限降到 TLS1.2 对现代设备无实质影响（TLS1.0/1.1 本就不支持）；
        //     因是局域网自签名直连、且已验证登录凭据（访问码）由 MQTT CONNACK 把关，未引入额外风险。
        mbedtls_ssl_conf_min_tls_version(&g_conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&g_conf, MBEDTLS_SSL_VERSION_TLS1_3);
        mbedtls_ssl_setup(&g_ssl, &g_conf);
        mbedtls_ssl_set_hostname(&g_ssl, g_ip.c_str());
        mbedtls_ssl_set_bio(&g_ssl, &g_serverFd, mbedtls_net_send, mbedtls_net_recv, nullptr);

        addLogTagged("MqttConn", "步骤3 TLS 握手开始（启用 TLS，版本范围 TLS1.2~TLS1.3，不校验证书）");
        int64_t hsT0 = nowMs();
        int hrc = mbedtls_ssl_handshake(&g_ssl);
        int64_t hsMs = nowMs() - hsT0;
        if (hrc != 0) {
            char eb[160] = { 0 };
            mbedtls_strerror(hrc, eb, sizeof(eb));
            r.detail = "mbedtls rc=" + std::to_string(hrc) + " (" + eb + ") 耗时=" + std::to_string(hsMs) + "ms";
            r.uiCode = "TLS_HANDSHAKE";
            r.uiMessage = "TLS 握手失败（版本/套件不兼容）—— 已尝试 8883(TLS)/1883(明文)";
            addLogTagged("MqttConn", "步骤3 TLS 握手失败 " + r.detail);
            teardown();
            return r;
        }
        addLogTagged("MqttConn", std::string("步骤3 TLS 握手成功 协议=") + mbedtls_ssl_get_version(&g_ssl)
            + " 套件=" + mbedtls_ssl_get_ciphersuite(&g_ssl) + " 耗时=" + std::to_string(hsMs) + "ms");
    } else {
        addLogTagged("MqttConn", "步骤3 明文模式：跳过 TLS（端口 " + std::to_string(port) + "，无加密）");
    }

    // 4) MQTT CONNECT / CONNACK
    r.step = "MQTT CONNECT";
    if (!mqttConnect("bblp", g_accessCode)) {
        r.detail = "CONNECT 报文写入失败（对端已关闭或写超时）";
        r.uiCode = "MQTT_WRITE";
        r.uiMessage = "MQTT 连接报文发送失败 —— 连接可能被打印机主动关闭";
        addLogTagged("MqttConn", "步骤4 MQTT CONNECT 发送失败：" + r.detail);
        teardown();
        return r;
    }
    addLogTagged("MqttConn", "步骤4 MQTT CONNECT 已发送 用户名=bblp clientId=" + g_clientId
        + " clean=1 keepalive=20s，等待 CONNACK");

    r.step = "CONNACK";
    unsigned char connack[4] = { 0, 0, 0, 0 };
    if (!readAll(connack, 4)) {
        r.detail = "等待 CONNACK 超时/读失败（5s）";
        r.uiCode = "CONNACK_TIMEOUT";
        r.uiMessage = "等待 MQTT 连接确认（CONNACK）超时 —— 打印机未响应，可能访问码校验未通过或端口被占用";
        addLogTagged("MqttConn", "步骤4 CONNACK 读取失败：" + r.detail);
        teardown();
        return r;
    }
    {
        int rc2 = connack[3];
        addLogTagged("MqttConn", "步骤4 CONNACK 返回码=" + std::to_string(rc2) + "（" + connackMeaning(rc2) + "）");
        if (connack[0] != 0x20 || connack[1] != 0x02 || rc2 != 0) {
            r.detail = "CONNACK return code=" + std::to_string(rc2) + " " + connackMeaning(rc2);
            r.uiCode = "CONNACK_" + std::to_string(rc2);
            if (rc2 == 4) {
                r.uiMessage = "MQTT 拒绝：用户名或访问码错误（CONNACK=4）—— 请核对访问码";
            } else if (rc2 == 5) {
                r.uiMessage = "MQTT 拒绝：未授权（CONNACK=5）—— 请确认已开启局域网模式（LAN Only）";
            } else {
                r.uiMessage = "MQTT 连接被拒（CONNACK=" + std::to_string(rc2) + "：" + connackMeaning(rc2) + "）";
            }
            addLogTagged("MqttConn", "步骤4 CONNACK 非 0：" + r.detail);
            teardown();
            return r;
        }
    }

    // 新会话开始：清空状态缓存（增量合并基线）。
    // 若不清理，会沿用上一会话/上一台打印机的残留值（如旧 gcode_state / 旧温度）当作"上次已知值"，
    // 造成增量合并结果错误。重置后各字段为"未知"，收到数据再逐帧填。
    //
    // 【D 修复·最小】断线自动重连到**同一台打印机**时，保留上次已知的温度（含"已知"标记）。
    //   原因：A1/P1 系为增量上报（只发相对上帧变化过的字段）。若重连时把基线整体清零，温度会被
    //   判为"未知" → UI 温度读数显示 "--"，直到打印机下次恰好上报该字段才恢复（客户现象：
    //   "温度读数突然没了，过一会又回来"）。仅当连接目标（序列号/IP）与上一条基线一致（=重连同机）
    //   才保留温度；换机（目标不同）仍整体重置，避免把上一台机的残留值当成本机基线。
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        const bool sameTarget = !g_state.serial.empty()
            && g_state.serial == g_serial && g_state.ip == g_ip;
        PrinterState kept;
        if (sameTarget) {
            kept.nozzleTemp    = g_state.nozzleTemp;
            kept.bedTemp       = g_state.bedTemp;
            kept.chamberTemp   = g_state.chamberTemp;
            kept.nozzleTargetTemp  = g_state.nozzleTargetTemp;
            kept.bedTargetTemp     = g_state.bedTargetTemp;
            kept.chamberTargetTemp = g_state.chamberTargetTemp;
            kept.hasNozzleTemp  = g_state.hasNozzleTemp;
            kept.hasBedTemp     = g_state.hasBedTemp;
            kept.hasChamberTemp = g_state.hasChamberTemp;
            kept.hasChamberHeater = g_state.hasChamberHeater;
        }
        g_state = PrinterState();
        g_state.serial = g_serial;
        g_state.ip = g_ip;
        if (sameTarget) {
            g_state.nozzleTemp    = kept.nozzleTemp;
            g_state.bedTemp       = kept.bedTemp;
            g_state.chamberTemp   = kept.chamberTemp;
            g_state.nozzleTargetTemp  = kept.nozzleTargetTemp;
            g_state.bedTargetTemp     = kept.bedTargetTemp;
            g_state.chamberTargetTemp = kept.chamberTargetTemp;
            g_state.hasNozzleTemp  = kept.hasNozzleTemp;
            g_state.hasBedTemp     = kept.hasBedTemp;
            g_state.hasChamberTemp = kept.hasChamberTemp;
            g_state.hasChamberHeater = kept.hasChamberHeater;
        }
        addLogTagged("MqttConn", std::string("新会话基线与上一条相同目标=")
            + (sameTarget ? "true（保留上次温度，避免读数闪断）" : "false（换机/首连→整体重置）"));
    }

    // 5) SUBSCRIBE / SUBACK。手动连接（未提供序列号）时用通配符订阅，
    //    收到首条 report 后从 topic 里学出真实序列号，后续命令/重连都用它。
    //    订阅确认放宽：等待 6s × 最多 3 次重发；等待期间任何先到的 PUBLISH 立即处理（不丢弃），
    //    因此不会因"先等 SUBACK"而丢掉后续状态推送。全部失败则标记为"未订阅"，会话保留并后台继续重试。
    r.step = "SUBSCRIBE";
    std::string topic = g_serial.empty() ? std::string("device/+/report") : ("device/" + g_serial + "/report");
    std::string subResult = "失败(未订阅)";
    bool subscribed = false;
    bool rejected = false;
    const int kSubMaxAttempts = 3;
    const int64_t kSubWaitMs = 6000;
    for (int attempt = 1; attempt <= kSubMaxAttempts && g_running && !subscribed; ++attempt) {
        addLogTagged("MqttConn", "步骤5 订阅 topic=" + topic + " 第" + std::to_string(attempt)
            + "/" + std::to_string(kSubMaxAttempts) + "次，等待 SUBACK " + std::to_string(kSubWaitMs / 1000) + "s");
        if (!mqttSubscribe(topic)) {
            r.detail = "SUBSCRIBE 报文写入失败";
            r.uiCode = "SUBSCRIBE_WRITE";
            r.uiMessage = "订阅报文发送失败 —— 连接可能已断开";
            addLogTagged("MqttConn", "步骤5 SUBSCRIBE 发送失败：" + r.detail);
            teardown();
            return r;
        }
        int64_t deadline = nowMs() + kSubWaitMs;
        while (g_running && !subscribed && !rejected) {
            unsigned char phdr = 0;
            std::string pbody;
            int ptot = 0;
            int pr = readPacket(phdr, pbody, deadline, &ptot);
            if (pr == 0) {
                addLogTagged("MqttConn", "步骤5 SUBACK 等待超时（" + std::to_string(kSubWaitMs / 1000)
                    + "s，第" + std::to_string(attempt) + "次）");
                break; // 重发订阅
            }
            if (pr < 0) {
                r.detail = "等待 SUBACK 期间连接断开";
                r.uiCode = "SUBSCRIBE_WRITE";
                r.uiMessage = "订阅等待中连接断开 —— 请重试";
                addLogTagged("MqttConn", "步骤5 等待 SUBACK 时连接断开");
                teardown();
                return r;
            }
            unsigned char ptype = phdr >> 4;
            logPacket(phdr, pbody, ptot); // 原始报文类型/长度日志
            if (ptype == 3) {
                // 订阅确认前先到的状态推送：立即处理（学 SN / 更新状态），绝不丢弃
                handlePublishPacket(phdr, pbody);
                if (g_subscribed.load(std::memory_order_relaxed)) {
                    subscribed = true;
                    subResult = "成功(收到推送)";
                    break;
                }
            } else if (ptype == 9) {
                std::string rcList;
                parseSuback(pbody, rcList, rejected);
                if (rejected) {
                    subResult = "失败(broker 拒绝 returncode=" + rcList + ")";
                    r.step = "SUBACK";
                    r.detail = "SUBACK returncode=" + rcList + " 被拒";
                    r.uiCode = "SUBACK_REJECT";
                    r.uiMessage = "订阅被拒（SUBACK=" + rcList + "）—— 请确认已开启局域网模式（LAN Only）与开发者模式";
                    addLogTagged("MqttConn", "步骤5 订阅被拒 returncode=" + rcList);
                } else {
                    subscribed = true;
                    subResult = "成功";
                    g_subscribed.store(true, std::memory_order_relaxed);
                    addLogTagged("MqttConn", "步骤5 SUBACK 成功 returncode=" + rcList);
                }
                break;
            } else {
                // 其它报文（如 PINGRESP）：忽略，继续等 SUBACK（原始日志已记录）
                addLogTagged("MqttConn", "步骤5 等待 SUBACK 时收到 type=" + std::to_string(ptype)
                    + "(" + mqttTypeName(ptype) + ")");
            }
        }
    }
    if (rejected) {
        addLogTagged("MqttConn", "步骤5 订阅被 broker 拒绝，放弃本端口");
        teardown();
        return r;
    }
    if (!subscribed) {
        // 未收到 SUBACK：明确标记为"未订阅"，但会话保留（reader 线程继续收包，
        // keepalive 会周期性重发订阅；一旦收到 SUBACK/推送即转为已订阅）。
        subResult = "失败(未订阅,将继续重试)";
        addLogTagged("MqttConn", "步骤5 未收到 SUBACK：标记为未订阅，会话保留并后台继续重试");
    }

    // 6) 成功：先标记连接存活，再启动收发线程（避免 reader 首读超时误判为断线）
    g_connected = true;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_state.connected = true;
        g_state.serial = g_serial;
        g_state.ip = g_ip;
    }
    {
        std::string snSource = g_serial.empty() ? "手动" : "发现";
        std::string snValue = g_serial.empty() ? "(空)" : g_serial;
        addLogTagged("MqttSn", "SN 来源=" + snSource + " 值=" + snValue + " 订阅结果=" + subResult);
    }
    g_readerThread = std::thread(readerLoop);
    g_keepaliveThread = std::thread(keepaliveLoop);

    // 连接（含订阅）成功：立即发一次只读 pushall 拉全量基线。
    // P1/A1 系为增量上报，必须靠 pushall 拿到一次全量；X1 系全量上报，发之无害。
    // 若 SN 是在等待 SUBACK 期间从 topic 学到的，onSerialLearned 已发送过，这里不重复。
    if (!g_resubscribed && !g_serial.empty()) {
        sendPushAll(g_serial);
    }

    addLogTagged("MqttConn", "连接成功 端口=" + std::to_string(port) + (tls ? " (TLS)" : " (明文)")
        + " 订阅结果=" + subResult + " —— 本会话复用该组合");
    r.ok = true;
    return r;
}

} // namespace

// 完整建立一次会话：按 8883(TLS) → 1883(明文) 顺序尝试（上次成功的端口优先），
// 失败路径自行清理并返回 false，不改 g_running 语义（重连线程靠它继续重试）。
bool openSession()
{
    g_lastErrorCode.clear();
    g_lastErrorMessage.clear();

    // 端口回退顺序：优先上次成功端口，再试另一个（固定 8883(TLS) → 1883(明文)）
    int ports[2];
    ports[0] = g_preferredPort;
    ports[1] = (g_preferredPort == 8883) ? 1883 : 8883;

    addLogTagged("MqttConn", "==== 连接开始 ip=" + g_ip + " 序列号=" + (g_serial.empty() ? "(空)" : g_serial)
        + " 端口顺序=" + std::to_string(ports[0]) + "→" + std::to_string(ports[1]) + " ====");

    Attempt last;
    last.step = "未尝试";
    last.detail = "未发起任何连接尝试";
    for (int i = 0; i < 2; i++) {
        int port = ports[i];
        bool tls = (port == 8883);
        addLogTagged("MqttConn", "尝试端口 " + std::to_string(port) + (tls ? "（TLS 加密）" : "（明文）"));
        Attempt r = establishOnce(port, tls);
        if (r.ok) {
            g_preferredPort = port; // 记住成功组合：下次直连优先复用
            return true;
        }
        addLogTagged("MqttConn", "端口 " + std::to_string(port) + " 失败：断在「" + r.step + "」原因=" + r.detail);
        last = r;
    }

    // 全部组合失败：一行失败摘要 + 记录 UI 原因（手动连接失败不做自动重试，见 connect()）
    g_lastErrorCode = last.uiCode.empty() ? "UNKNOWN" : last.uiCode;
    g_lastErrorMessage = last.uiMessage.empty() ? "连接失败（原因未识别）" : last.uiMessage;
    // TCP 不可达时，UI 文案点名"已尝试 8883/1883 两个端口"，避免只显示回退端口造成误导
    if (g_lastErrorCode == "TCP_UNREACHABLE") {
        g_lastErrorMessage = "TCP 不可达（" + g_ip + "）—— 已尝试端口 8883(TLS)/1883(明文)，"
            "请确认打印机已开启局域网模式、与手机处于同一网段";
    }
    addLogTagged("MqttConn", "★连接失败摘要：断在「" + last.step + "」原因=" + last.detail
        + "；已尝试端口 8883(TLS)/1883(明文) 均失败");
    return false;
}


// 线程与 SSL 资源回收（不改 g_running，可安全用于重连前的清理）
void teardown()
{
    mbedtls_net_free(&g_serverFd);
    if (g_readerThread.joinable()) {
        g_readerThread.join();
    }
    if (g_keepaliveThread.joinable()) {
        g_keepaliveThread.join();
    }
    {
        // 持写锁释放 SSL：防止 sendCommand 工作线程还在 mbedtls_ssl_write 时
        // 释放上下文导致 use-after-free 崩溃
        std::lock_guard<std::mutex> lock(g_writeMutex);
        mbedtls_ssl_close_notify(&g_ssl);
        mbedtls_ssl_free(&g_ssl);
        mbedtls_ssl_config_free(&g_conf);
        mbedtls_ctr_drbg_free(&g_ctrDrbg);
        mbedtls_entropy_free(&g_entropy);
    }
    g_connected = false;

    std::lock_guard<std::mutex> lock(g_stateMutex);
    g_state.connected = false;
}

bool connect(const std::string& ip, const std::string& accessCode, const std::string& serial)
{
    stopReconnect(); // 若有旧的重连线程先停掉
    g_serial = serial;
    g_ip = ip;
    g_accessCode = accessCode; // 保存供断线自动重连
    g_running = true;
    if (openSession()) {
        return true;
    }
    // 用户发起的连接失败：不自动重试（可能 IP/访问码有误，重试只会刷屏）
    g_running = false;
    teardown();
    return false;
}

void disconnect()
{
    g_running = false; // 先置 false：重连线程/keepalive 会在步进检查点自行退出
    stopReconnect();
    teardown();
}

bool isConnected()
{
    std::lock_guard<std::mutex> lock(g_stateMutex);
    return g_connected;
}

std::string lastErrorCode()
{
    std::lock_guard<std::mutex> lock(g_stateMutex);
    return g_lastErrorCode;
}

std::string lastErrorMessage()
{
    std::lock_guard<std::mutex> lock(g_stateMutex);
    return g_lastErrorMessage;
}

PrinterState getState()
{
    std::lock_guard<std::mutex> lock(g_stateMutex);
    return g_state;
}

// 供 FTPS 上传复用当前会话（ip/密码），password 不回传到 JS 层。
bool currentSession(std::string& ip, std::string& accessCode, std::string& serial)
{
    if (!g_connected || g_ip.empty() || g_accessCode.empty()) {
        return false;
    }
    ip = g_ip;
    accessCode = g_accessCode;
    serial = g_serial;
    return true;
}

bool sendCommand(const std::string& commandJson)
{
    // 手动连接时序列号要等第一条 report 才学到，这之前发不了命令
    if (g_serial.empty()) {
        addLog("send skipped: serial unknown (wait first report)");
        return false;
    }
    std::string topic = "device/" + g_serial + "/request";
    addLog("send topic=" + topic + " payload=" + commandJson);
    return mqttPublish(topic, commandJson);
}

// 请求设备侧 K 值表（只读）。刻意不做任何写入：写回要等"set 后 get 读回比对"这条
// 判据在真机上验证过（第三方实现的 set ack 会回 result:fail 但实际已生效）。
bool requestKProfiles()
{
    if (g_serial.empty()) {
        addLogTagged("MqttCali", "请求 K 值表跳过：序列号未知（等首条 report 学到 SN）");
        return false;
    }
    // 第三方口径：拓竹常忽略首个请求（"printers often ignore first request"），
    // 所以连发两次（不同 sequence_id），第二次通常才拿到应答。
    const long long ms = static_cast<long long>(nowMs());
    bool ok = false;
    for (int i = 0; i < 2; ++i) {
        const std::string seq = std::to_string(ms) + std::to_string(i);
        const std::string cmd =
            "{\"print\":{\"sequence_id\":\"" + seq + "\",\"command\":\"extrusion_cali_get\"}}";
        ok = sendCommand(cmd) || ok;
    }
    addLogTagged("MqttCali", std::string("extrusion_cali_get 已发送 次数=2 结果=") + (ok ? "成功" : "失败"));
    return ok;
}

std::string getCaliRaw()
{
    std::lock_guard<std::mutex> lock(g_caliMutex);
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& s : g_caliRaw) {
        arr.push_back(s);
    }
    return arr.dump();
}

// 记录日志：同时写入 hilog 与内存缓冲（供日志界面读取）
void addLog(const std::string& msg)
{
    OH_LOG_INFO(LOG_APP, "BambuMqtt %{public}s", msg.c_str());
    std::lock_guard<std::mutex> lock(g_logMutex);
    g_logs.push_back(msg);
    if (g_logs.size() > 200) {
        g_logs.erase(g_logs.begin());
    }
}

// 带独立 hilog tag 的日志：hilog 前缀用 tag（便于 `hdc shell hilog | grep MqttSn` 之类过滤），
// 内存日志以 "[tag] msg" 形式写入，日志页可一并看到。新增 tag（不改既有 BambuMqtt/Camera 等 tag）。
void addLogTagged(const std::string& tag, const std::string& msg)
{
    OH_LOG_INFO(LOG_APP, "%{public}s %{public}s", tag.c_str(), msg.c_str());
    std::lock_guard<std::mutex> lock(g_logMutex);
    g_logs.push_back("[" + tag + "] " + msg);
    if (g_logs.size() > 200) {
        g_logs.erase(g_logs.begin());
    }
}

// 返回内存日志缓冲（JSON 字符串数组，供日志界面显示）
std::string getLogs()
{
    std::lock_guard<std::mutex> lock(g_logMutex);
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& s : g_logs) {
        arr.push_back(s);
    }
    return arr.dump();
}

} // namespace BambuMqtt
