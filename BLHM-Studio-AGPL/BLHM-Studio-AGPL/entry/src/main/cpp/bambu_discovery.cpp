#include "bambu_discovery.hpp"
#include "bambu_mqtt.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <hilog/log.h>

#include <cctype>
#include <cerrno>
#include <cstring>
#include <string>
#include <vector>

namespace BambuDiscovery {

namespace {

const char* SEARCH_TARGET = "urn:bambulab-com:device:3dprinter:1";
const char* MULTICAST = "239.255.255.250";

// SSDP 原始报文截断长度：完整打印会刷爆日志，截断后仍能看到 ST/USN/Location/Server 等关键头
const size_t SSDP_RAW_MAX = 512;

// 把原始报文中的 CR/LF 转成可见的 "\\r\\n"，避免日志被换行拆散、便于 grep
std::string flatten(const char* buf, size_t n)
{
    std::string s;
    s.reserve(n < SSDP_RAW_MAX ? n : SSDP_RAW_MAX);
    size_t limit = n < SSDP_RAW_MAX ? n : SSDP_RAW_MAX;
    for (size_t i = 0; i < limit; i++) {
        char c = buf[i];
        if (c == '\r') { s += "\\r"; }
        else if (c == '\n') { s += "\\n"; }
        else { s += c; }
    }
    if (n > limit) { s += "...(truncated)"; }
    return s;
}

// 从 SSDP 响应提取序列号（兼容 USN: <serial> 与 USN: uuid:<serial>::... 两种格式）
std::string extractSerial(const std::string& response)
{
    size_t pos = response.find("USN:");
    if (pos == std::string::npos) {
        pos = response.find("usn:");
    }
    if (pos == std::string::npos) {
        return "";
    }
    size_t start = pos + 4;
    while (start < response.size() && (response[start] == ' ' || response[start] == '\t')) {
        start++;
    }
    size_t end = response.find("\r\n", start);
    if (end == std::string::npos) {
        end = response.size();
    }
    std::string v = response.substr(start, end - start);

    size_t upos = v.find("uuid:");
    if (upos != std::string::npos) {
        v = v.substr(upos + 5);
        size_t sep = v.find("::");
        if (sep != std::string::npos) {
            v = v.substr(0, sep);
        }
    }
    while (!v.empty() && (v.back() == ' ' || v.back() == '\r' || v.back() == '\n')) {
        v.pop_back();
    }
    return v;
}

// 从 SSDP 响应取指定 header 的值（头名大小写不敏感；值取到行尾）。
// 实测原始报文里机型头形如 "DevModel.bambu.com: N2S"（见报告来源），故头名比较做小写化。
std::string extractHeader(const std::string& response, const std::string& key)
{
    std::string lower = response;
    for (auto& c : lower) { c = static_cast<char>(tolower(static_cast<unsigned char>(c))); }
    std::string lkey = key;
    for (auto& c : lkey) { c = static_cast<char>(tolower(static_cast<unsigned char>(c))); }
    size_t pos = lower.find(lkey);
    if (pos == std::string::npos) {
        return "";
    }
    size_t start = pos + lkey.size();
    while (start < response.size() && (response[start] == ' ' || response[start] == '\t' || response[start] == ':')) {
        start++;
    }
    size_t end = response.find("\r\n", start);
    if (end == std::string::npos) {
        end = response.size();
    }
    std::string v = response.substr(start, end - start);
    while (!v.empty() && (v.back() == ' ' || v.back() == '\r' || v.back() == '\n')) {
        v.pop_back();
    }
    return v;
}

// DevModel.bambu.com 是官方机型代码（非友好名）。按社区实测映射表转成友好名；
// 未收录的代码原样返回（宁可不美化，也不编造）。
// 来源：beambam 兼容表 —— N2S=A1, N1=A1 mini, C11=P1P, C12=P1S, N7=P2S,
//       O1D=H2D, O1E=H2D Pro, BL-P001=X1, BL-P002=X1C, C13=X1E。
std::string friendlyModel(const std::string& code)
{
    if (code == "N2S") { return "A1"; }
    if (code == "N1") { return "A1 mini"; }
    if (code == "C11") { return "P1P"; }
    if (code == "C12") { return "P1S"; }
    if (code == "N7") { return "P2S"; }
    if (code == "O1D") { return "H2D"; }
    if (code == "O1E") { return "H2D Pro"; }
    if (code == "BL-P001") { return "X1"; }
    if (code == "BL-P002") { return "X1C"; }
    if (code == "C13") { return "X1E"; }
    return code;
}

// 仅接受 Bambu 打印机响应（排除自己发出的 M-SEARCH 回环，NT/ST 头必须含 Bambu 设备类型）
bool isBambuResponse(const std::string& response)
{
    if (response.find("M-SEARCH") == 0) {
        return false;
    }
    return response.find(SEARCH_TARGET) != std::string::npos;
}

std::vector<Printer> discoverOnPort(int port)
{
    std::vector<Printer> result;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        BambuMqtt::addLogTagged("Ssdp", "port=" + std::to_string(port) + " socket() 失败，跳过");
        return result;
    }
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        BambuMqtt::addLogTagged("Ssdp", "port=" + std::to_string(port) + " bind 失败(errno=" + std::to_string(errno) + ")，跳过");
        close(sock);
        return result;
    }

    ip_mreq mreq{};
    mreq.imr_multiaddr.s_addr = inet_addr(MULTICAST);
    mreq.imr_interface.s_addr = INADDR_ANY;
    setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq));

    std::string msearch = "M-SEARCH * HTTP/1.1\r\n";
    msearch += "HOST: 239.255.255.250:";
    msearch += std::to_string(port);
    msearch += "\r\n";
    msearch += "MAN: \"ssdp:discover\"\r\n";
    msearch += "MX: 2\r\n";
    msearch += "ST: ";
    msearch += SEARCH_TARGET;
    msearch += "\r\n\r\n";

    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(port);

    // 单次 recvfrom 超时 1 秒，便于多轮重发
    timeval tv{};
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buffer[4096];
    // 多轮重发 M-SEARCH（最多 5 轮）。UDP 不可靠，重发提高首次发现成功率；发现后提前结束
    BambuMqtt::addLogTagged("Ssdp", "port=" + std::to_string(port) + " send M-SEARCH target=" + SEARCH_TARGET);
    for (int round = 0; round < 5; round++) {
        dest.sin_addr.s_addr = inet_addr(MULTICAST);
        sendto(sock, msearch.c_str(), msearch.size(), 0, reinterpret_cast<sockaddr*>(&dest), sizeof(dest));
        dest.sin_addr.s_addr = inet_addr("255.255.255.255");
        sendto(sock, msearch.c_str(), msearch.size(), 0, reinterpret_cast<sockaddr*>(&dest), sizeof(dest));

        while (true) {
            sockaddr_in from{};
            socklen_t fromLen = sizeof(from);
            ssize_t n = recvfrom(sock, buffer, sizeof(buffer) - 1, 0, reinterpret_cast<sockaddr*>(&from), &fromLen);
            if (n <= 0) {
                break; // 本轮 1 秒超时，进入下一轮重发
            }
            buffer[n] = '\0';
            std::string response(buffer, n);
            // 【Ssdp】把每一份收到的原始报文（含非 Bambu 回包）落日志，便于下次抓 A1 真实响应。
            // tag=Ssdp，含来源 IP + 原始 header/文本（截断）。这是判断 A1 为何发现不到的
            // 唯一确证手段：看它到底有没有回、回了什么 ST/USN/Server。
            std::string fromIp = inet_ntoa(from.sin_addr);
            BambuMqtt::addLogTagged("Ssdp",
                "port=" + std::to_string(port) + " recv from=" + fromIp + " len=" + std::to_string(n)
                + " raw=" + flatten(buffer, static_cast<size_t>(n)));
            if (!isBambuResponse(response)) {
                continue;
            }
            Printer p;
            p.ip = fromIp;
            p.serial = extractSerial(response);
            // 机型：取官方 SSDP 头 DevModel.bambu.com（实测格式见报告来源），转友好名后仅用于
            // UI 展示与诊断，不参与任何连接/订阅逻辑。
            p.model = friendlyModel(extractHeader(response, "devmodel.bambu.com"));
            OH_LOG_INFO(LOG_APP, "SSDP[%{public}d] ip=%{public}s serial=%{public}s model=%{public}s", port, p.ip.c_str(), p.serial.c_str(), p.model.c_str());
            BambuMqtt::addLogTagged("Ssdp",
                "port=" + std::to_string(port) + " BAMBU ip=" + p.ip + " serial=" + p.serial + " model=" + p.model);
            if (p.ip.empty()) {
                continue;
            }
            bool dup = false;
            for (const auto& e : result) {
                if (e.ip == p.ip) { dup = true; break; }
            }
            if (!dup) {
                result.push_back(p);
            }
        }

        // 已发现打印机则提前结束
        if (!result.empty()) {
            break;
        }
    }

    close(sock);
    return result;
}

} // namespace

std::vector<Printer> discover()
{
    std::vector<Printer> all;
    int ports[] = { 1900, 1990, 2021 };
    BambuMqtt::addLogTagged("Ssdp", "discover begin ports=1900,1990,2021 target=" + std::string(SEARCH_TARGET));
    for (int port : ports) {
        std::vector<Printer> r = discoverOnPort(port);
        for (const auto& p : r) {
            bool dup = false;
            for (const auto& e : all) {
                if (e.ip == p.ip) { dup = true; break; }
            }
            if (!dup) {
                all.push_back(p);
            }
        }
    }
    OH_LOG_INFO(LOG_APP, "SSDP discover total=%{public}zu", all.size());
    BambuMqtt::addLogTagged("Ssdp", "discover end total=" + std::to_string(all.size()));
    return all;
}

std::string toJson(const std::vector<Printer>& printers)
{
    std::string out = "[";
    for (size_t i = 0; i < printers.size(); i++) {
        if (i > 0) {
            out += ",";
        }
        out += "{\"ip\":\"" + printers[i].ip + "\"";
        out += ",\"serial\":\"" + printers[i].serial + "\"";
        out += ",\"model\":\"" + printers[i].model + "\"}";
    }
    out += "]";
    return out;
}

} // namespace BambuDiscovery
