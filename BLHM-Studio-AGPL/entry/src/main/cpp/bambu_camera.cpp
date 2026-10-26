#include "bambu_camera.hpp"
#include "bambu_mqtt.hpp"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
}

// 6000 私有协议走 mbedtls TLS（与 FTPS 同一份静态库；自签证书不校验）
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>

#include <hilog/log.h>

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace BambuCamera {

namespace {

// 独立 hilog tag（新增，便于 hdc 过滤 6000 路径日志；不改既有 tag 语义）
const char* CAM6000_TAG = "Cam6000";

std::atomic<bool> g_running{false};
std::thread g_thread;
std::atomic<uint64_t> g_frameSeq{0};
std::atomic<int64_t> g_lastDataMs{0};
bool g_jpegLogged = false; // 6000 通道首帧 JPEG 交付日志只打一次（仅 6000 线程访问）

// 最新帧缓冲（线程安全）
std::mutex g_frameMutex;
Frame g_latestFrame;

int64_t nowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

// FFmpeg 中断回调：stop 请求、或 10 秒无数据（流卡死）时中断所有阻塞的网络操作。
// 没有它 av_read_frame 在断流时会永久阻塞，导致 stop() 的 join 卡死 UI（ANR）。
int interruptCb(void*)
{
    if (!g_running.load()) {
        return 1;
    }
    if (nowMs() - g_lastDataMs.load() > 10000) {
        BambuMqtt::addLog("camera: stall 10s, abort");
        return 1;
    }
    return 0;
}

// FFmpeg 日志回调：转发到日志页
void ffmpegLogCallback(void* ptr, int level, const char* fmt, va_list vl)
{
    if (level > AV_LOG_INFO) {
        return;
    }
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    BambuMqtt::addLog(std::string("ffmpeg: ") + buf);
}

// ---------------------------------------------------------------------------
//  机型 → 摄像头端口 选择
//  官方/社区多来源（见交付报告）：
//    · X1/X1C/X1E · H2D/H2D Pro/H2C/H2S · X2D · P2S → RTSPS 322
//    · A1/A1 mini · P1P/P1S · A2L                 → TCP+TLS 6000（chamber image / JPEG）
//  P2S 存在口径冲突（bambuddy↔beambam），故按“322 优先，失败回退 6000”处理。
// ---------------------------------------------------------------------------

// 去空白并大写化（机型串比较用）
std::string normModel(const std::string& s)
{
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t')) b++;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t')) e--;
    std::string out = s.substr(b, e - b);
    for (auto& c : out) c = static_cast<char>(toupper(static_cast<unsigned char>(c)));
    return out;
}

// 是否属于 322 家族（RTSPS/H.264）
bool isRtspFamily(const std::string& m)
{
    // 友好名
    if (m.find("X1") != std::string::npos) return true;   // X1 / X1C / X1E
    if (m.find("H2") != std::string::npos) return true;   // H2D / H2D Pro / H2C / H2S
    if (m.find("X2") != std::string::npos) return true;   // X2D
    if (m.find("P2S") != std::string::npos) return true;  // P2S（口径冲突，见上）
    // 官方机型码（SSDP DevModel.bambu.com 原始值兜底）
    if (m == "BL-P001" || m == "BL-P002" || m == "C13") return true; // X1/X1C/X1E
    if (m == "O1D" || m == "O1E") return true;                       // H2D/H2D Pro
    return false;
}

// 是否属于 6000 家族（chamber image / JPEG）
bool isChamberFamily(const std::string& m)
{
    if (m.find("A1") != std::string::npos) return true;   // A1 / A1 mini
    if (m.find("A2") != std::string::npos) return true;   // A2L
    if (m.find("P1") != std::string::npos) return true;   // P1P / P1S
    // 官方机型码兜底
    if (m == "N2S" || m == "N1" || m == "N9") return true; // A1 / A1 mini / A2L
    if (m == "C11" || m == "C12") return true;             // P1P / P1S
    return false;
}

// 序列号前缀 → 家族（官方 SN 规则，见交付报告来源）：
//   00M=X1C 03W=X1E 20P=X2D 22E=P2S 094/239/093/31B=H2x  01P=P1S 01S=P1P 039=A1 030=A1 mini 26A=A2L
// 返回：0=未知 1=偏 322 2=偏 6000
int familyBySerial(const std::string& serial)
{
    if (serial.size() < 3) return 0;
    std::string p = serial.substr(0, 3);
    for (auto& c : p) c = static_cast<char>(toupper(static_cast<unsigned char>(c)));
    if (p == "00M" || p == "03W" || p == "20P" || p == "22E"
        || p == "094" || p == "239" || p == "093" || p == "31B") {
        return 1; // 偏 322
    }
    if (p == "01P" || p == "01S" || p == "039" || p == "030" || p == "26A") {
        return 2; // 偏 6000
    }
    return 0;
}

// 计算端口候选顺序（返回端口数字列表，2 项以内）。forceProto：1→仅 322，2→仅 6000。
std::vector<int> candidates(const std::string& model, const std::string& serial, int forceProto)
{
    if (forceProto == 1) return { 322 };
    if (forceProto == 2) return { 6000 };
    std::string m = normModel(model);
    if (isRtspFamily(m)) return { 322, 6000 };
    if (isChamberFamily(m)) return { 6000, 322 };
    int fam = familyBySerial(serial);
    if (fam == 1) return { 322, 6000 };
    if (fam == 2) return { 6000, 322 };
    // 无法判定机型：先试 322，失败再试 6000（X1 系占比更高），并打日志说明
    return { 322, 6000 };
}

std::string joinPorts(const std::vector<int>& v)
{
    std::string s;
    for (size_t i = 0; i < v.size(); i++) {
        if (i) s += ",";
        s += std::to_string(v[i]);
    }
    return s;
}

std::string buildRtspUrl(const std::string& ip, const std::string& code)
{
    // live555 服务器：scheme 必须 rtsps（TLS+TCP），URL 不带 query；认证由 FFmpeg Digest 自动完成
    return "rtsps://bblp:" + code + "@" + ip + ":322/streaming/live/1";
}

// ---------------------------------------------------------------------------
//  322 路径（RTSPS/H.264）——逻辑与既有实现保持一致，仅改为返回“是否成功连上”
//  返回值：true = 已成功建立视频流（含解码上下文）；false = 未能连上（可回退 6000）
// ---------------------------------------------------------------------------
bool runRtspReader(const std::string& url)
{
    AVFormatContext* fmtCtx = nullptr;
    AVCodecContext* codecCtx = nullptr;
    SwsContext* swsCtx = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* rgbFrame = nullptr;
    AVPacket* pkt = nullptr;
    uint8_t* rgbBuffer = nullptr;
    int videoStream = -1;

    g_lastDataMs = nowMs();
    av_log_set_callback(ffmpegLogCallback);
    avformat_network_init();

    // 预分配 context 并挂中断回调（覆盖 open/read 全阶段）
    fmtCtx = avformat_alloc_context();
    fmtCtx->interrupt_callback.callback = interruptCb;
    fmtCtx->interrupt_callback.opaque = nullptr;

    AVDictionary* openOpts = nullptr;
    av_dict_set(&openOpts, "rtsp_transport", "tcp", 0);
    int openRet = avformat_open_input(&fmtCtx, url.c_str(), nullptr, &openOpts);
    av_dict_free(&openOpts);
    if (openRet < 0) {
        char errBuf[128];
        av_strerror(openRet, errBuf, sizeof(errBuf));
        BambuMqtt::addLog(std::string("camera: [322] open input failed: ") + errBuf);
        avformat_network_deinit();
        return false;
    }

    if (avformat_find_stream_info(fmtCtx, nullptr) < 0) {
        BambuMqtt::addLog("camera: [322] find stream info failed");
        avformat_close_input(&fmtCtx);
        avformat_network_deinit();
        return false;
    }

    for (unsigned int i = 0; i < fmtCtx->nb_streams; i++) {
        if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            videoStream = static_cast<int>(i);
            break;
        }
    }
    if (videoStream < 0) {
        BambuMqtt::addLog("camera: [322] no video stream");
        avformat_close_input(&fmtCtx);
        avformat_network_deinit();
        return false;
    }

    const AVCodec* codec = avcodec_find_decoder(fmtCtx->streams[videoStream]->codecpar->codec_id);
    if (!codec) {
        BambuMqtt::addLog("camera: [322] no decoder");
        avformat_close_input(&fmtCtx);
        avformat_network_deinit();
        return false;
    }

    codecCtx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(codecCtx, fmtCtx->streams[videoStream]->codecpar);
    if (avcodec_open2(codecCtx, codec, nullptr) < 0) {
        BambuMqtt::addLog("camera: [322] open codec failed");
        avcodec_free_context(&codecCtx);
        avformat_close_input(&fmtCtx);
        avformat_network_deinit();
        return false;
    }

    int width = codecCtx->width;
    int height = codecCtx->height;
    // 显示区远小于 1080p：缩小到 720p 输出。RGBA 体积 8.3MB→3.7MB，
    // 后续 NAPI 拷贝/PixelMap 分配/纹理上传/GC 开销全部降 ~2.25 倍
    int outW = width;
    int outH = height;
    if (width > 1280) {
        outW = 1280;
        outH = static_cast<int>(static_cast<int64_t>(outW) * height / width);
        outH -= outH % 2; // 偶数对齐
    }
    BambuMqtt::addLog("camera: [322] stream " + std::to_string(width) + "x" + std::to_string(height)
        + " -> " + std::to_string(outW) + "x" + std::to_string(outH));

    frame = av_frame_alloc();
    rgbFrame = av_frame_alloc();
    pkt = av_packet_alloc();

    int rgbSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA, outW, outH, 1);
    rgbBuffer = static_cast<uint8_t*>(av_malloc(rgbSize));
    av_image_fill_arrays(rgbFrame->data, rgbFrame->linesize, rgbBuffer, AV_PIX_FMT_RGBA, outW, outH, 1);

    swsCtx = sws_getContext(width, height, codecCtx->pix_fmt, outW, outH, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!swsCtx) {
        BambuMqtt::addLog("camera: [322] sws_getContext failed");
        av_free(rgbBuffer);
        av_frame_free(&rgbFrame);
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&codecCtx);
        avformat_close_input(&fmtCtx);
        avformat_network_deinit();
        return false;
    }

    BambuMqtt::addLog("camera: [322] reader loop start");

    int errCount = 0;
    while (g_running) {
        int ret = av_read_frame(fmtCtx, pkt);
        if (ret < 0) {
            av_packet_unref(pkt);
            if (ret == AVERROR_EOF || ret == AVERROR_EXIT) {
                break;
            }
            // 连续 3 次读错误 → 连接已死，退出（由 ArkTS 看门狗重连）
            if (++errCount >= 3) {
                BambuMqtt::addLog("camera: [322] read errors, exit");
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        errCount = 0;
        g_lastDataMs = nowMs();

        if (pkt->stream_index != videoStream) {
            av_packet_unref(pkt);
            continue;
        }

        ret = avcodec_send_packet(codecCtx, pkt);
        av_packet_unref(pkt);
        if (ret < 0) {
            continue;
        }
        while (ret >= 0) {
            ret = avcodec_receive_frame(codecCtx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                break;
            }
            if (ret < 0) {
                break;
            }

            sws_scale(swsCtx, frame->data, frame->linesize, 0, height, rgbFrame->data, rgbFrame->linesize);

            {
                std::lock_guard<std::mutex> lock(g_frameMutex);
                g_latestFrame.width = outW;
                g_latestFrame.height = outH;
                g_latestFrame.seq = g_frameSeq.fetch_add(1) + 1;
                g_latestFrame.data.assign(rgbBuffer, rgbBuffer + rgbSize);
            }
            av_frame_unref(frame);
        }
    }

    BambuMqtt::addLog("camera: [322] reader loop exit");

    sws_freeContext(swsCtx);
    av_free(rgbBuffer);
    av_frame_free(&rgbFrame);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&codecCtx);
    avformat_close_input(&fmtCtx);
    avformat_network_deinit();
    return true;
}

// ---------------------------------------------------------------------------
//  6000 路径（TCP+TLS 私有 "chamber image" 协议，JPEG/MJPEG）
//
//  协议（多来源交叉，见交付报告；来源 synman/bambu-go2rtc camera-stream.py，
//  与 ha-bambulab / bambuddy 一致）：
//   1) TLS 建连到 ip:6000（自签证书不校验）
//   2) 发送 80 字节认证头（小端）：
//        [0:4]=0x40  [4:8]=0x3000  [8:12]=0  [12:16]=0
//        [16:48]=用户名 "bblp" ASCII，右侧 0x00 填充到 32 字节
//        [48:80]=访问码    ASCII，右侧 0x00 填充到 32 字节
//   3) 收帧：每张图先来 16 字节头（单独一次到达）：
//        [0:4]=payload_size（小端，JPEG 字节数，不含这 16 字节头）
//        [4:8]=0  [8:12]=1  [12:16]=0
//      随后 payload_size 字节即为完整 JPEG（以 FF D8 FF E0 开头、FF D9 结尾）。
//   4) 访问码错误时服务器直接关连接（读到 0 字节）。
//   5) 帧率低：每 1~2 秒一帧；无新帧期间读会超时/无数据。
//  返回值：true = 认证通过并至少收到过帧头（说明端口/协议正确）；false = 未能连上
// ---------------------------------------------------------------------------
const int CHAMBER_PORT = 6000;
const int SOCK_TIMEOUT_SEC = 2;      // 单次收发超时（让读循环能周期性检查 g_running）
const int CONNECT_TIMEOUT_MS = 5000; // TCP 连接超时
const int STALL_MS = 15000;          // 连续无数据视为断流
const size_t MAX_JPEG = 16u * 1024u * 1024u;

// 共享 RNG（mbedtls 要求；一次初始化，进程内复用）
mbedtls_entropy_context g_entropy;
mbedtls_ctr_drbg_context g_ctrDrbg;
std::once_flag g_rngOnce;

void ensureRng()
{
    std::call_once(g_rngOnce, []() {
        mbedtls_entropy_init(&g_entropy);
        mbedtls_ctr_drbg_init(&g_ctrDrbg);
        mbedtls_ctr_drbg_seed(&g_ctrDrbg, mbedtls_entropy_func, &g_entropy, nullptr, 0);
    });
}

// 带超时的 TCP 建连（非阻塞 connect + select），避免不可达时长时间挂起
int connectTcpTimeout(const std::string& ip, int port, std::string& err)
{
    int sock = ::socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) { err = "socket() 失败"; return -1; }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (::inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) != 1) {
        ::close(sock);
        err = "IP 解析失败: " + ip;
        return -1;
    }
    // 非阻塞 connect
    int flags = ::fcntl(sock, F_GETFL, 0);
    ::fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    int rc = ::connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    if (rc != 0 && errno != EINPROGRESS) {
        ::close(sock);
        err = "TCP 连接失败 " + ip + ":" + std::to_string(port);
        return -1;
    }
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(sock, &wfds);
    timeval tv;
    tv.tv_sec = CONNECT_TIMEOUT_MS / 1000;
    tv.tv_usec = (CONNECT_TIMEOUT_MS % 1000) * 1000;
    rc = ::select(sock + 1, nullptr, &wfds, nullptr, &tv);
    if (rc <= 0) {
        ::close(sock);
        err = "TCP 连接超时 " + ip + ":" + std::to_string(port);
        return -1;
    }
    int soErr = 0;
    socklen_t len = sizeof(soErr);
    ::getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &len);
    if (soErr != 0) {
        ::close(sock);
        err = "TCP 连接失败(errno=" + std::to_string(soErr) + ") " + ip + ":" + std::to_string(port);
        return -1;
    }
    // 恢复阻塞并设置收发超时
    ::fcntl(sock, F_SETFL, flags);
    timeval iotv;
    iotv.tv_sec = SOCK_TIMEOUT_SEC;
    iotv.tv_usec = 0;
    ::setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &iotv, sizeof(iotv));
    ::setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &iotv, sizeof(iotv));
    return sock;
}

// 一条 6000 TLS 连接
struct ChamberTls {
    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    bool inited = false;
    bool open = false;

    ChamberTls()
    {
        mbedtls_net_init(&net);
        mbedtls_ssl_init(&ssl);
        mbedtls_ssl_config_init(&conf);
        inited = true;
    }
    ~ChamberTls() { close_(); }

    void close_()
    {
        if (!inited) return;
        if (open) {
            mbedtls_ssl_close_notify(&ssl);
            open = false;
        }
        mbedtls_ssl_free(&ssl);
        mbedtls_ssl_config_free(&conf);
        mbedtls_net_free(&net);
        inited = false;
    }
};

bool chamberTlsConnect(ChamberTls& c, const std::string& ip, std::string& err)
{
    ensureRng();
    int sock = connectTcpTimeout(ip, CHAMBER_PORT, err);
    if (sock < 0) return false;
    c.net.fd = sock;

    mbedtls_ssl_config_defaults(&c.conf, MBEDTLS_SSL_IS_CLIENT,
                                MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    mbedtls_ssl_conf_rng(&c.conf, mbedtls_ctr_drbg_random, &g_ctrDrbg);
    // 自签证书：接受任意证书
    mbedtls_ssl_conf_authmode(&c.conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_setup(&c.ssl, &c.conf);
    mbedtls_ssl_set_hostname(&c.ssl, ip.c_str());
    mbedtls_ssl_set_bio(&c.ssl, &c.net, mbedtls_net_send, mbedtls_net_recv, nullptr);

    int64_t deadline = nowMs() + 8000;
    int ret = 0;
    while ((ret = mbedtls_ssl_handshake(&c.ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            char buf[64];
            snprintf(buf, sizeof(buf), "TLS 握手失败 -0x%04X", static_cast<unsigned>(-ret));
            err = buf;
            return false;
        }
        if (!g_running.load() || nowMs() > deadline) {
            err = "TLS 握手超时/已停止";
            return false;
        }
    }
    c.open = true;
    return true;
}

// 读：>0 字节数；0 = 暂无数据（超时/空闲，非致命）；<0 = 连接断开/致命
int chamberRead(ChamberTls& c, uint8_t* buf, size_t len)
{
    int n = mbedtls_ssl_read(&c.ssl, buf, len);
    if (n > 0) return n;
    if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) {
        return 0;
    }
    return -1;
}

bool chamberWriteAll(ChamberTls& c, const uint8_t* data, size_t len)
{
    size_t off = 0;
    while (off < len) {
        int n = mbedtls_ssl_write(&c.ssl, data + off, len - off);
        if (n <= 0) {
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            return false;
        }
        off += static_cast<size_t>(n);
    }
    return true;
}

// 构造 80 字节认证头
std::vector<uint8_t> buildAuthHeader(const std::string& user, const std::string& code)
{
    std::vector<uint8_t> h(80, 0);
    auto putU32 = [&](size_t off, uint32_t v) {
        h[off + 0] = static_cast<uint8_t>(v & 0xFF);
        h[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        h[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFF);
        h[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFF);
    };
    putU32(0, 0x40);
    putU32(4, 0x3000);
    putU32(8, 0);
    putU32(12, 0);
    for (size_t i = 0; i < user.size() && i < 32; i++) h[16 + i] = static_cast<uint8_t>(user[i]);
    for (size_t i = 0; i < code.size() && i < 32; i++) h[48 + i] = static_cast<uint8_t>(code[i]);
    return h;
}

uint32_t leU32(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
        | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

// 从完整 JPEG 字节流解析宽高（扫描 SOF0/1/2/… 段）。仅用于日志/元信息，失败不影响交付。
bool parseJpegSize(const std::vector<uint8_t>& j, int& w, int& h)
{
    size_t i = 2; // 跳过 SOI（FF D8）
    while (i + 9 < j.size()) {
        if (j[i] != 0xFF) { i++; continue; }
        uint8_t marker = j[i + 1];
        // 无长度字段的标记：跳过
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) { i += 2; continue; }
        if (marker == 0xD9) { break; } // EOI
        size_t segLen = (static_cast<size_t>(j[i + 2]) << 8) | j[i + 3];
        // SOFn（排除 DHT=C4/DAC=CC/RSTn）：[len2][precision1][height2][width2]
        if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
            h = (static_cast<int>(j[i + 5]) << 8) | j[i + 6];
            w = (static_cast<int>(j[i + 7]) << 8) | j[i + 8];
            return w > 0 && h > 0;
        }
        i += 2 + segLen;
    }
    return false;
}

// 6000 读帧主循环。connected 通过引用返回“是否认证通过”。
bool runChamberReader(const std::string& ip, const std::string& accessCode, bool& connected)
{
    connected = false;
    std::string err;
    ChamberTls tls;
    if (!chamberTlsConnect(tls, ip, err)) {
        BambuMqtt::addLogTagged(CAM6000_TAG, "TLS 连接失败: " + err);
        return false;
    }
    BambuMqtt::addLogTagged(CAM6000_TAG, "TLS 已连 " + ip + ":" + std::to_string(CHAMBER_PORT));

    // 发送 80 字节认证头
    std::vector<uint8_t> auth = buildAuthHeader("bblp", accessCode);
    if (!chamberWriteAll(tls, auth.data(), auth.size())) {
        BambuMqtt::addLogTagged(CAM6000_TAG, "认证头写入失败");
        return false;
    }

    // 说明：6000 通道的 payload 本身就是完整 JPEG，C++ 侧**不做解码**，
    // 直接交付给 ArkTS 用系统 @ohos.multimedia.image 解码。
    // 原因：本工程交叉编译的 FFmpeg 用 --disable-everything --enable-decoder=h264 配置，
    //       **未编入 mjpeg 解码器**（avcodec_find_decoder(AV_CODEC_ID_MJPEG) 返回 nullptr，
    //       libavcodec.a 内无 ff_mjpeg_decoder/mjpegdec.o）。因此不能依赖 FFmpeg 解 JPEG。

    std::vector<uint8_t> jpeg;
    jpeg.reserve(256 * 1024);
    uint8_t hdr[16];
    size_t hdrGot = 0;
    size_t payloadSize = 0;
    uint8_t readBuf[8192];
    int64_t lastData = nowMs();

    BambuMqtt::addLogTagged(CAM6000_TAG, "chamber reader loop start");

    bool fatal = false;
    while (g_running.load() && !fatal) {
        if (payloadSize == 0) {
            // 收 16 字节帧头
            while (hdrGot < 16 && g_running.load()) {
                int n = chamberRead(tls, hdr + hdrGot, 16 - hdrGot);
                if (n > 0) {
                    hdrGot += static_cast<size_t>(n);
                    lastData = nowMs();
                } else if (n == 0) {
                    if (nowMs() - lastData > STALL_MS) {
                        BambuMqtt::addLogTagged(CAM6000_TAG, "等待帧头超时（无数据）");
                        fatal = true;
                        break;
                    }
                    continue; // 空闲/超时：回到循环再检查 g_running
                } else {
                    // 连接被关（访问码错误 → 立刻 0 字节关闭）
                    BambuMqtt::addLogTagged(CAM6000_TAG, "等待帧头时连接断开（访问码错误或端口不对？）");
                    fatal = true;
                    break;
                }
            }
            if (fatal) break;
            if (hdrGot < 16) break; // g_running 变 false

            payloadSize = leU32(hdr);
            if (payloadSize == 0 || payloadSize > MAX_JPEG) {
                BambuMqtt::addLogTagged(CAM6000_TAG, "非法帧长度: " + std::to_string(payloadSize));
                fatal = true;
                break;
            }
            connected = true; // 认证通过（收到合法帧头）
            jpeg.clear();
            continue;
        }

        // 收一帧 JPEG（可能分多次到达；read 最大 8192）
        size_t remain = payloadSize - jpeg.size();
        size_t want = remain < sizeof(readBuf) ? remain : sizeof(readBuf);
        int n = chamberRead(tls, readBuf, want);
        if (n > 0) {
            jpeg.insert(jpeg.end(), readBuf, readBuf + n);
            lastData = nowMs();
        } else if (n == 0) {
            if (nowMs() - lastData > STALL_MS) {
                BambuMqtt::addLogTagged(CAM6000_TAG, "接收图像超时（无数据）");
                fatal = true;
            }
            continue;
        } else {
            BambuMqtt::addLogTagged(CAM6000_TAG, "接收图像时连接断开");
            fatal = true;
            break;
        }

        if (jpeg.size() == payloadSize) {
            // 校验 JPEG 起止magic（不匹配则丢弃该帧，不致命）
            if (payloadSize > 6 && jpeg[0] == 0xFF && jpeg[1] == 0xD8
                && jpeg[payloadSize - 2] == 0xFF && jpeg[payloadSize - 1] == 0xD9) {
                // C++ 不解码：整帧 JPEG 原样交付，ArkTS 用系统 image 模块解码。
                // 这里仅解析 SOF 拿宽高（日志/元信息用），失败也不影响交付。
                int jw = 0, jh = 0;
                bool haveSize = parseJpegSize(jpeg, jw, jh);
                {
                    std::lock_guard<std::mutex> lock(g_frameMutex);
                    g_latestFrame.width = haveSize ? jw : 0;
                    g_latestFrame.height = haveSize ? jh : 0;
                    g_latestFrame.isJpeg = true;
                    g_latestFrame.seq = g_frameSeq.fetch_add(1) + 1;
                    g_latestFrame.data = jpeg; // 完整 JPEG（SOI…EOI）
                }
                if (!g_jpegLogged) {
                    g_jpegLogged = true;
                    BambuMqtt::addLogTagged(CAM6000_TAG, "首帧 JPEG 交付 ArkTS 解码 size="
                        + std::to_string(jw) + "x" + std::to_string(jh)
                        + " bytes=" + std::to_string(payloadSize));
                }
            } else {
                BambuMqtt::addLogTagged(CAM6000_TAG, "JPEG magic 不匹配，丢弃该帧");
            }
            // 准备下一帧
            hdrGot = 0;
            payloadSize = 0;
        }
    }

    BambuMqtt::addLogTagged(CAM6000_TAG, "chamber reader loop exit connected="
        + std::string(connected ? "true" : "false"));

    tls.close_();
    return connected;
}

// ---------------------------------------------------------------------------
//  调度线程：按端口候选顺序取流；某端口“连上”即在其上持续拉流，连不上则回退下一个
// ---------------------------------------------------------------------------
void deviceLoop(const std::string& ip, const std::string& accessCode,
                const std::string& model, const std::string& serial, int forceProto)
{
    std::vector<int> cands = candidates(model, serial, forceProto);
    BambuMqtt::addLog("camera: 机型 model='" + model + "' serial='" + serial
        + "' force=" + std::to_string(forceProto) + " → 端口候选 " + joinPorts(cands));

    for (size_t i = 0; i < cands.size() && g_running.load(); i++) {
        int port = cands[i];
        bool connected = false;
        if (port == 322) {
            connected = runRtspReader(buildRtspUrl(ip, accessCode));
        } else {
            runChamberReader(ip, accessCode, connected);
            // 注意 runChamberReader 也在 g_running 变 false 时返回；
            // 此时不要把“被停止”误判为“连不上”而回退
            if (!g_running.load()) break;
        }
        if (connected) {
            BambuMqtt::addLog("camera: 端口 " + std::to_string(port) + " 取流结束（已连接）");
            break;
        }
        BambuMqtt::addLog("camera: 端口 " + std::to_string(port) + " 连接失败，尝试下一候选");
    }

    g_running = false;
}

} // namespace

bool start(const std::string& rtspUrl)
{
    // 先回收旧线程：线程对象若仍 joinable（上次异常退出未 join），
    // 直接赋值新线程会触发 std::terminate 崩溃
    stop();
    BambuMqtt::addLog("camera: start url=" + rtspUrl);
    g_running = true;
    g_thread = std::thread([rtspUrl]() {
        g_lastDataMs = nowMs();
        runRtspReader(rtspUrl);
        g_running = false;
    });
    return true;
}

bool startForDevice(const std::string& ip, const std::string& accessCode,
                    const std::string& model, const std::string& serial, int forceProto)
{
    stop();
    if (ip.empty() || accessCode.empty()) {
        BambuMqtt::addLog("camera: startForDevice 参数不足（ip/访问码为空）");
        return false;
    }
    BambuMqtt::addLog("camera: startForDevice ip=" + ip + " model=" + model + " serial=" + serial
        + " forceProto=" + std::to_string(forceProto));
    g_running = true;
    g_thread = std::thread(deviceLoop, ip, accessCode, model, serial, forceProto);
    return true;
}

std::string resolveProtocol(const std::string& model, const std::string& serial)
{
    std::vector<int> cands = candidates(model, serial, 0);
    std::string m = normModel(model);
    std::string reason;
    if (isRtspFamily(m)) reason = "机型属 322 家族";
    else if (isChamberFamily(m)) reason = "机型属 6000 家族";
    else {
        int fam = familyBySerial(serial);
        if (fam == 1) reason = "序列号前缀属 322 家族";
        else if (fam == 2) reason = "序列号前缀属 6000 家族";
        else reason = "机型未知，先试 322 再试 6000";
    }
    return joinPorts(cands) + " (" + reason + ")";
}

void stop()
{
    g_running = false;
    // 中断回调会让阻塞中的 av_read_frame/avformat_open_input 立刻返回；
    // 6000 路径靠 socket 收发超时（2s）周期性检查 g_running，join 不会卡死
    if (g_thread.joinable()) {
        g_thread.join();
    }
}

bool isRunning()
{
    return g_running;
}

Frame getFrame()
{
    std::lock_guard<std::mutex> lock(g_frameMutex);
    return g_latestFrame;
}

bool peekFrame(FrameInfo& info)
{
    std::lock_guard<std::mutex> lock(g_frameMutex);
    info.width = g_latestFrame.width;
    info.height = g_latestFrame.height;
    info.seq = g_latestFrame.seq;
    info.size = g_latestFrame.data.size();
    info.isJpeg = g_latestFrame.isJpeg;
    // JPEG 帧宽高可能解析失败（width=0），但只要拿到字节就算有效（ArkTS 用 image 模块解出真实尺寸）
    return info.size > 0 && (info.width > 0 || info.isJpeg);
}

bool copyFrameIfNew(uint64_t lastSeq, void* dst, size_t cap, FrameInfo& info)
{
    std::lock_guard<std::mutex> lock(g_frameMutex);
    const Frame& f = g_latestFrame;
    if (f.data.empty() || f.seq == 0 || f.seq == lastSeq) {
        return false;
    }
    if (!f.isJpeg && f.width <= 0) {
        return false;
    }
    if (f.data.size() > cap) {
        return false;
    }
    memcpy(dst, f.data.data(), f.data.size());
    info.width = f.width;
    info.height = f.height;
    info.seq = f.seq;
    info.size = f.data.size();
    info.isJpeg = f.isJpeg;
    return true;
}

} // namespace BambuCamera
