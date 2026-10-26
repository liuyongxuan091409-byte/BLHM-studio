#ifndef BAMBU_MQTT_HPP
#define BAMBU_MQTT_HPP

#include <string>
#include <map>

// Bambu 打印机局域网 MQTT 通信（协议参考 beambam，C++ 重写）
// 端口 8883(TLS) / 1883，用户名 bblp，密码 = LAN Access Code
// 订阅 device/{serial}/report，发布 device/{serial}/request

namespace BambuMqtt {

// 打印机实时状态
struct PrinterState {
    bool connected = false;
    std::string serial;
    std::string model;
    std::string ip;
    std::string gcodeState;   // IDLE/RUNNING/PAUSE/FAILED/FINISH
    int progress = 0;         // mc_percent 0-100
    int layer = 0;
    int totalLayers = 0;
    int remainingMinutes = 0;
    double nozzleTemp = 0.0;
    double bedTemp = 0.0;
    double chamberTemp = 0.0;
    // 三个温度是否"已知"：增量上报（P1/A1 系只发变化过的字段）下，未上报的温度必须保持
    // 上次已知值并标记为未知（UI 显示 "--"），严禁被默认 0 覆盖（客户"A1 热床/喷嘴读不到"的根因）。
    bool hasNozzleTemp = false;
    bool hasBedTemp = false;
    bool hasChamberTemp = false;
    double nozzleTargetTemp = 0.0;
    double bedTargetTemp = 0.0;
    double chamberTargetTemp = 0.0;
    bool hasChamberHeater = false; // 是否有主动腔体加热（无则腔体目标温度不可设置）
    int partFan = 0;       // 部件风扇 0-100
    int auxFan = 0;        // 辅助风扇 0-100
    int chamberFan = 0;    // 机箱风扇 0-100
    std::string amsJson;   // AMS 详情（材料/颜色/温度/湿度/剩余，序列化 JSON）
    // 外挂料盘（external spool）详情：{type,color,remain}；取不到/为空时为 ""（界面据此不显示该项）。
    std::string externalSpoolJson;
    // 「表驱动」扩展状态字段：显示名 → 显示值（都是字符串，UI 直接渲染）。
    // 为什么这么做：以前每加一个上报字段都要改 5 处（表、结构体、合并、JSON、ETS 类型）；
    // 现在只需在 kExtReportFields 里加一行（见 bambu_state_merge.hpp），ETS 侧一个字都不用改。
    std::map<std::string, std::string> ext;
    // HMS 故障数组（print.hms）**原样透传**，形如 [{"attr":..,"code":..}]。
    // 文案查表刻意不放在这里：码表是 rawfile 资源（可随包更新、可换语言），
    // 且 16 位/8 位两套键的组合规则在 ETS 侧更好调试（见 service/HmsTable.ets）。
    // 空串 = 本帧没上报（沿用上次）；"[]" = 已恢复无故障。
    std::string hmsJson;
    // 机器侧 AI 检测开关（print.xcam）**原样透传**：形如
    //   {"buildplate_marker_detector":true,"spaghetti_detector":true,"first_layer_inspector":true,...}
    // 为什么不在 C++ 里逐键取：这些是"机器侧设置"而不是状态，键名随固件微调；
    // 原样交给 ETS 渲染（未知键也能显示原始名），改文案不用重编原生库。
    std::string xcamJson;
    std::string rawJson;   // 最新完整 report JSON
    bool npEnabled = false; // 新协议(NP)：cfg/fun/aux/stat 齐全（决定 AMS 刷新走 JSON 还是 gcode）
    int pushStatusCount = 0; // 本会话收到的状态推送(push_status)条数（0 = 连上但未收到任何状态数据）
};

// 连接打印机（ip + LAN AccessCode + 序列号）
bool connect(const std::string& ip, const std::string& accessCode, const std::string& serial);

// 最近一次 connect 失败的原因码（如 TCP_UNREACHABLE / TLS_HANDSHAKE / CONNACK_4 / SUBACK_REJECT），
// 供 UI 展示可行动提示。连接成功或未连接时为空串。原始错误码/字符串仍写在 MqttConn 日志里。
std::string lastErrorCode();

// 最近一次 connect 失败的中文可行动原因（如「TCP 不可达（ip:port）——请确认打印机已开启局域网模式…」）。
// 连接成功或未连接时为空串。
std::string lastErrorMessage();

// 断开连接
void disconnect();

// 是否已连接
bool isConnected();

// 获取最新状态（线程安全）
PrinterState getState();

// 获取内存运行日志（JSON 字符串数组）
std::string getLogs();

// 追加运行日志（供摄像头等其他模块写日志到日志页）
void addLog(const std::string& msg);

// 追加带独立 hilog tag 的日志：hilog 用 tag 作为前缀（便于 hdc 过滤），
// 同时以 "[tag] msg" 形式写入内存日志（供日志页展示）。新增 tag 用（不改既有 tag）。
void addLogTagged(const std::string& tag, const std::string& msg);

// 下发打印命令（JSON），发布到 device/{serial}/request
bool sendCommand(const std::string& commandJson);

// 请求设备侧 K 值表（只读）：发 extrusion_cali_get。**只查询，不写任何设备数据**。
// 协议形状尚未定案（请求体字段、应答外层结构都没有原文样例），因此这里刻意只做两件事：
//   1) 按第三方实现口径发一次请求（并立即重发一次做"热身"——拓竹首请求常被忽略）；
//   2) 把收到的任何含 calibration/k_value 关键字的原始报文留存，供有真机时一次性核对。
// 返回 {"ok":bool,"sent":int,"note":"..."}。
bool requestKProfiles();

// 取已留存的校准相关原始报文（JSON 字符串数组，最多 CALI_RAW_MAX 条，按时间升序）。
std::string getCaliRaw();

// 取当前会话的 ip / access code / serial（供 FTPS 上传复用，避免 access code 回到 JS 层）。
// 未连接时返回 false。access code 只在本进程内流转。
bool currentSession(std::string& ip, std::string& accessCode, std::string& serial);

} // namespace BambuMqtt

#endif // BAMBU_MQTT_HPP
