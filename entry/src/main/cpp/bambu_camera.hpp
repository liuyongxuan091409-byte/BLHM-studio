#ifndef BAMBU_CAMERA_HPP
#define BAMBU_CAMERA_HPP

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// Bambu 打印机摄像头取流模块
//   · X1 / X1C / X1E / H2D / H2D Pro / H2C / H2S / X2D / P2S：RTSPS 322（H.264，FFmpeg 解码 → RGBA）
//   · A1 / A1 mini / P1P / P1S / A2L：TCP+TLS 6000 私有 "chamber image" 协议（完整 JPEG，C++ 不解码，
//     原样交给 ArkTS 用系统 @ohos.multimedia.image 解码 —— 不依赖 FFmpeg 的 mjpeg 解码器）
// 两条路径最终都产出同一份最新帧（g_latestFrame），复用既有的 NAPI 单次拷贝直出 + PixelMap 链路。
namespace BambuCamera {

// 一帧图像。
//   · isJpeg=false：data 为 width*height*4 字节 RGBA（322 RTSPS/H.264 路径）。
//   · isJpeg=true ：data 为完整 JPEG（SOI...EOI）字节（6000 chamber image 路径）——
//     C++ 侧不做 JPEG 解码，直接交付给 ArkTS 用系统 @ohos.multimedia.image 解码。
struct Frame {
    int width = 0;
    int height = 0;
    uint64_t seq = 0;             // 帧序号（全局递增，ArkTS 用来去重）
    bool isJpeg = false;          // true = data 为完整 JPEG；false = data 为 RGBA
    std::vector<uint8_t> data;    // RGBA 或 JPEG 数据
};

// 强制协议（用于测试注入 / 覆盖自动选择）：
//   0 = 自动（按机型选择，失败再回退另一端口）；1 = 强制 322 RTSPS；2 = 强制 6000 chamber image
enum ForceProto { FORCE_AUTO = 0, FORCE_RTSP322 = 1, FORCE_CHAMBER6000 = 2 };

// 启动摄像头拉流（rtspUrl 形如 rtsps://ip:322/streaming/live/1）——仅 322 路径，保留兼容
bool start(const std::string& rtspUrl);

// 按机型启动取流：model 为 SSDP 友好机型名（可空），serial 用于机型兜底推断。
// 内部按机型决定端口顺序并在“连接失败”时回退另一端口；forceProto 可强制端口（测试用）。
bool startForDevice(const std::string& ip, const std::string& accessCode,
                    const std::string& model, const std::string& serial, int forceProto);

// 纯函数：解析机型/序列号 → 端口候选顺序描述（如 "6000,322"）。用于日志与可注入验证。
std::string resolveProtocol(const std::string& model, const std::string& serial);

// 停止拉流
void stop();

// 是否已启动
bool isRunning();

// 获取最新帧（无新帧时 width==0）
Frame getFrame();

// 帧元信息（NAPI 用来预探测与去重）
struct FrameInfo {
    int width = 0;
    int height = 0;
    uint64_t seq = 0;
    size_t size = 0;
    bool isJpeg = false;   // true = 帧数据为完整 JPEG（ArkTS 侧用 image 模块解码）
};

// 预探测最新帧元信息（无帧时返回 false）
bool peekFrame(FrameInfo& info);

// 若有比 lastSeq 更新的帧，则拷贝到 dst（单次拷贝直出，消除中间 Frame 拷贝）
bool copyFrameIfNew(uint64_t lastSeq, void* dst, size_t cap, FrameInfo& info);

} // namespace BambuCamera

#endif // BAMBU_CAMERA_HPP
