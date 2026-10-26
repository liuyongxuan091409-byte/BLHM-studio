#ifndef BAMBU_DISCOVERY_HPP
#define BAMBU_DISCOVERY_HPP

#include <string>
#include <vector>

// Bambu 打印机局域网发现（SSDP/UPnP）
// 目标设备类型 urn:bambulab-com:device:3dprinter:1

namespace BambuDiscovery {

struct Printer {
    std::string ip;
    std::string serial;
    std::string model;
};

// 通过 SSDP M-SEARCH 发现同网段 Bambu 打印机，返回列表（JSON）
std::vector<Printer> discover();

// 将列表序列化为 JSON 字符串
std::string toJson(const std::vector<Printer>& printers);

} // namespace BambuDiscovery

#endif // BAMBU_DISCOVERY_HPP
