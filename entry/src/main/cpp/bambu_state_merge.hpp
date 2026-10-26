#ifndef BAMBU_STATE_MERGE_HPP
#define BAMBU_STATE_MERGE_HPP

// 打印机状态"增量字段合并"（纯逻辑，仅依赖 nlohmann/json + PrinterState）。
//
// 背景（OpenBambuAPI mqtt.md 的 pushing.pushall 原文）：
//   X1 系每帧都发完整对象；**P1/A1 系只发相对于上一帧"变化过的字段"**（增量上报）。
// 因此绝不能每帧 new 一个 PrinterState（那样未上报字段会被默认 0 覆盖 →
// 客户实测"A1 热床温度显示错误 / 喷嘴读不到"）。正确做法：
//   以"上次已知状态"为基线，只覆盖本帧 JSON 里出现的字段，未出现的沿用基线值。

#include "bambu_mqtt.hpp"

#include "libslic3r/nlohmann/json.hpp"

#include <string>

namespace BambuMqtt {

// Bambu report 里数值字段可能是 number 也可能是 string，统一安全转换
inline double asDouble(const nlohmann::json& j)
{
    if (j.is_array()) {
        return j.empty() ? 0.0 : asDouble(j[0]);
    }
    if (j.is_number()) { return j.get<double>(); }
    if (j.is_string()) {
        try { return std::stod(j.get<std::string>()); }
        catch (...) { return 0.0; }
    }
    return 0.0;
}

inline int asInt(const nlohmann::json& j)
{
    if (j.is_number()) { return j.get<int>(); }
    if (j.is_string()) {
        try { return std::stoi(j.get<std::string>()); }
        catch (...) { return 0; }
    }
    return 0;
}

// 将 Bambu 十六进制颜色（如 FF0000FF）转为 #RRGGBB
inline std::string colorToHex(const std::string& raw)
{
    if (raw.size() >= 6) {
        return "#" + raw.substr(0, 6);
    }
    return raw.empty() ? "#808080" : raw;
}

// 解析 AMS，提取材料/颜色/温度/湿度/剩余，返回简化 JSON 数组
inline std::string parseAms(const nlohmann::json& ams)
{
    nlohmann::json out = nlohmann::json::array();
    if (!ams.contains("ams") || !ams["ams"].is_array()) {
        return "[]";
    }
    for (const auto& unit : ams["ams"]) {
        nlohmann::json u;
        u["id"] = unit.contains("id") ? unit["id"].get<std::string>() : "";
        if (unit.contains("humidity")) {
            try { u["humidity"] = std::stoi(unit["humidity"].get<std::string>()); }
            catch (...) { u["humidity"] = 0; }
        }
        if (unit.contains("temp")) {
            try { u["temp"] = std::stod(unit["temp"].get<std::string>()); }
            catch (...) { u["temp"] = 0.0; }
        }
        nlohmann::json trays = nlohmann::json::array();
        if (unit.contains("tray") && unit["tray"].is_array()) {
            for (const auto& tray : unit["tray"]) {
                nlohmann::json t;
                t["type"] = tray.contains("tray_type") ? tray["tray_type"].get<std::string>() : "";
                std::string rawColor = tray.contains("tray_color") ? tray["tray_color"].get<std::string>() : "";
                t["color"] = colorToHex(rawColor);
                t["remain"] = tray.contains("remain") ? asInt(tray["remain"]) : -1;
                trays.push_back(t);
            }
        }
        u["trays"] = trays;
        out.push_back(u);
    }
    return out.dump();
}

// 解析外挂料盘（Bambu report 的 print.vt_tray）：返回 {type,color,remain} 或 ""（无/空槽）。
// 取不到就不返回任何数据（界面据此不显示该项，绝不编造）。
inline std::string parseExternalSpool(const nlohmann::json& vt)
{
    if (!vt.is_object()) {
        return "";
    }
    std::string type = vt.contains("tray_type") && vt["tray_type"].is_string()
        ? vt["tray_type"].get<std::string>() : "";
    std::string rawColor = vt.contains("tray_color") && vt["tray_color"].is_string()
        ? vt["tray_color"].get<std::string>() : "";
    // 既没有材料类型也没有颜色 → 视为空槽，不下发（不显示外挂料盘项）
    if (type.empty() && rawColor.empty()) {
        return "";
    }
    nlohmann::json t;
    t["type"] = type;
    t["color"] = colorToHex(rawColor);
    t["remain"] = vt.contains("remain") ? asInt(vt["remain"]) : -1;
    return t.dump();
}

// 合并诊断关注的字段（用于"本帧携带的字段列表 / 沿用上次值字段列表"日志）
// 注：这只是一份**诊断清单**（决定每帧那条日志里列哪些字段），不是合并白名单 —— 合并是显式逐字段做的。
// 最近的扩展：`print_error` 与 `hms` 加进来 —— 它们决定设备页的错误条显不显示，
// 排查「机器在故障态但界面没错误条」时需要一眼看出该帧到底有没有带这两个字段。
inline const char* const kTrackedReportFields[] = {
    "gcode_state", "mc_percent", "layer_num", "total_layer_num", "mc_remaining_time",
    "nozzle_temper", "bed_temper", "chamber_temper", "nozzle_target_temper",
    "bed_target_temper", "chamber_target_temper", "fan_gear", "cooling_fan_speed",
    "big_fan1_speed", "ams", "vt_tray", "print_error", "hms", "xcam"
};
inline const int kTrackedReportFieldCount =
    static_cast<int>(sizeof(kTrackedReportFields) / sizeof(kTrackedReportFields[0]));

// 该字段在本帧 report 中是否"被上报"（腔体温度在 X1 上报为 print.info.temp，等效于 chamber_temper）
inline bool reportHasField(const nlohmann::json& p, const std::string& f)
{
    if (p.contains(f)) { return true; }
    if (f == "chamber_temper" && p.contains("info") && p["info"].is_object() && p["info"].contains("temp")) {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 表驱动扩展字段
//
// 为什么要这张表：以前每加一个上报字段都要改 5 处（白名单、结构体成员、合并、StateToJson、ETS 类型），
// 漏一处就「解析了但没显示」。现在只加一行：这里加一项 → 合并进 PrinterState::ext → StateToJson 原样输出
// → ETS 的「状态详情」区直接渲染（label 就是显示名，所以 ETS 侧零改动）。
//   · 只放**标量**字段：数组/对象（lights_report、ams…）塞进「显示名=值」的列表里既难看又没用；
//   · 未上报的字段不会进 map → UI 自然不显示（A1 不会显示它没有的腔体/模块字段）；
//   · 「缺字段保留旧值」的语义与强类型字段一致：本帧没带就沿用上次的值。
// ---------------------------------------------------------------------------
enum ExtKind { EXT_INT, EXT_STR, EXT_BOOL };

struct ExtField {
    const char* key;    // print 对象里的 json key
    ExtKind kind;
    const char* label;  // 中文显示名（直接进 UI，不需要额外映射表）
};

inline const ExtField kExtReportFields[] = {
    {"subtask_name",        EXT_STR,  "任务名"},      // 正在打印的任务名
    {"gcode_file",          EXT_STR,  "文件"},        // 切片文件名
    {"print_type",          EXT_STR,  "任务类型"},
    {"wifi_signal",         EXT_STR,  "信号"},        // 形如 "-55dBm"
    {"print_error",         EXT_INT,  "错误码"},      // 十进制；HMS 文案查表用它转 8 位十六进制
    {"mc_print_stage",      EXT_INT,  "阶段"},        // 新固件
    {"mc_print_sub_stage",  EXT_INT,  "子阶段"},
    {"stg",                 EXT_INT,  "阶段(旧)"},    // 旧固件
    {"stg_cur",             EXT_INT,  "子阶段(旧)"},
    {"spd_lvl",             EXT_INT,  "速度档"},
    {"spd_mag",             EXT_INT,  "速度"},
    {"nozzle_diameter",     EXT_STR,  "喷嘴"},
    {"sdcard",              EXT_BOOL, "SD 卡"}
    // 刻意不收的两个（真机联调时发现是噪声）：
    //   · home_flag：回零状态是**位掩码**，按十进制显示成 -1067072120 这种数，既看不懂又容易被当成故障；
    //   · upgrade_state：0/1/2 枚举，且正常永远 0 → 平时只是多一行没信息的"升级状态 0"。
    // 需要时再按各自的语义单独解析（别用通用标量通道硬塞）。
};
inline const int kExtReportFieldCount =
    static_cast<int>(sizeof(kExtReportFields) / sizeof(kExtReportFields[0]));

// 把一帧里的值转成"给人看的字符串"（转换失败返回空串 → 调用方不写进 ext，UI 不显示空行）
inline std::string extValueText(const nlohmann::json& v, ExtKind kind)
{
    switch (kind) {
    case EXT_STR: {
        if (v.is_string()) { return v.get<std::string>(); }
        if (v.is_number_integer()) { return std::to_string(v.get<long long>()); }
        if (v.is_number_float()) { return std::to_string(v.get<double>()); }
        return "";
    }
    case EXT_BOOL: {
        if (v.is_boolean()) { return v.get<bool>() ? "是" : "否"; }
        if (v.is_number()) { return asInt(v) != 0 ? "是" : "否"; }
        if (v.is_string()) {
            const std::string s = v.get<std::string>();
            return (s == "true" || s == "1") ? "是" : "否";
        }
        return "";
    }
    case EXT_INT:
    default:
        return std::to_string(asInt(v));
    }
}

// 固件版本不在 print 顶层：报在 print.info.module[]（元素形如 {name:"ota", sw_ver:"01.07.00.00"}）。
// 取不到就**不写**（UI 不显示该行），绝不编造。
inline std::string extFirmware(const nlohmann::json& p)
{
    if (!p.contains("info") || !p["info"].is_object()) { return ""; }
    const nlohmann::json& info = p["info"];
    if (!info.contains("module") || !info["module"].is_array()) { return ""; }
    for (const auto& m : info["module"]) {
        if (!m.is_object()) { continue; }
        const std::string nm = m.contains("name") && m["name"].is_string() ? m["name"].get<std::string>() : "";
        if (nm != "ota") { continue; }
        if (m.contains("sw_ver") && m["sw_ver"].is_string()) { return m["sw_ver"].get<std::string>(); }
    }
    return "";
}

// 把一帧 report 的 print 对象合并进 st（st 作为"上次已知值"基线，只覆盖本帧出现的字段）。
// 同时输出两串诊断信息：frameFields=本帧携带的字段、inheritedFields=沿用上次值的字段。
inline void applyReport(const nlohmann::json& p, PrinterState& st,
                        std::string& frameFields, std::string& inheritedFields, int& frameCount)
{
    frameFields.clear();
    inheritedFields.clear();
    frameCount = 0;

    // ---- 逐字段合并：出现才覆盖，未出现则沿用 st 里的基线值 ----
    if (p.contains("gcode_state") && p["gcode_state"].is_string()) {
        st.gcodeState = p["gcode_state"].get<std::string>();
    }
    if (p.contains("mc_percent")) { st.progress = asInt(p["mc_percent"]); }
    if (p.contains("layer_num")) { st.layer = asInt(p["layer_num"]); }
    if (p.contains("total_layer_num")) { st.totalLayers = asInt(p["total_layer_num"]); }
    if (p.contains("mc_remaining_time")) { st.remainingMinutes = asInt(p["mc_remaining_time"]); }

    // 温度（未上报 → 保留基线值，且不改变已知标记）
    if (p.contains("nozzle_temper")) { st.nozzleTemp = asDouble(p["nozzle_temper"]); st.hasNozzleTemp = true; }
    if (p.contains("bed_temper")) { st.bedTemp = asDouble(p["bed_temper"]); st.hasBedTemp = true; }
    if (p.contains("chamber_temper")) {
        st.chamberTemp = asDouble(p["chamber_temper"]);
        st.hasChamberTemp = true;
    } else if (p.contains("info") && p["info"].is_object() && p["info"].contains("temp")) {
        st.chamberTemp = asDouble(p["info"]["temp"]);
        st.hasChamberTemp = true;
    }
    if (p.contains("nozzle_target_temper")) { st.nozzleTargetTemp = asDouble(p["nozzle_target_temper"]); }
    if (p.contains("bed_target_temper")) { st.bedTargetTemp = asDouble(p["bed_target_temper"]); }
    if (p.contains("chamber_target_temper")) {
        st.chamberTargetTemp = asDouble(p["chamber_target_temper"]);
        st.hasChamberHeater = true; // 有腔体目标温度字段 → 有主动腔体加热
    }

    // 风扇：fan_gear 合并编码 part/aux/chamber（各 8 位，0-255 刻度）；未上报 → 沿用基线
    if (p.contains("fan_gear")) {
        int fg = asInt(p["fan_gear"]);
        st.partFan = (fg & 0xFF) * 100 / 255;
        st.auxFan = ((fg >> 8) & 0xFF) * 100 / 255;
        st.chamberFan = ((fg >> 16) & 0xFF) * 100 / 255;
    } else {
        if (p.contains("cooling_fan_speed")) { st.partFan = asInt(p["cooling_fan_speed"]) * 100 / 15; }
        if (p.contains("big_fan1_speed")) { st.chamberFan = asInt(p["big_fan1_speed"]) * 100 / 15; }
    }

    // AMS（嵌套在 print.ams 内）；未上报 → 沿用基线
    if (p.contains("ams") && p["ams"].is_object()) {
        st.amsJson = parseAms(p["ams"]);
    }
    // 外挂料盘（print.vt_tray）；未上报 → 沿用基线
    if (p.contains("vt_tray")) {
        st.externalSpoolJson = parseExternalSpool(p["vt_tray"]);
    }

    // ---- 表驱动扩展字段：遍历 kExtReportFields，出现才覆盖（未出现沿用上次值）----
    for (int i = 0; i < kExtReportFieldCount; ++i) {
        const ExtField& f = kExtReportFields[i];
        if (!p.contains(f.key)) { continue; }
        const std::string v = extValueText(p[f.key], f.kind);
        if (v.empty()) { continue; }      // 转不出可读值就不写（UI 不显示空行）
        st.ext[f.label] = v;
    }
    // 固件版本（在 print.info.module[] 里，单独取）
    const std::string fw = extFirmware(p);
    if (!fw.empty()) { st.ext["固件"] = fw; }

    // ---- HMS 故障数组：**整体替换**，不是"缺字段保留" ----
    // 原因：设备故障恢复后会推**空数组**，若按"缺字段沿用旧值"处理，界面上那条错误永远消不掉。
    if (p.contains("hms")) {
        st.hmsJson = p["hms"].is_array() ? p["hms"].dump() : "[]";
    }

    // ---- 机器侧 AI 检测开关（print.xcam）：原样透传 ----
    // 为什么说它重要：打印板检测/炒面/首层检测都是**机器侧开关**，关掉之后机器根本不会提醒
    //（界面上只会看到"什么都没发生"）。把开关状态显示出来，用户才能判断"为什么没弹提醒"。
    // 与 hms 不同，这是**设置**不是事件：每帧带就覆盖（设备改了设置能立刻反映）。
    if (p.contains("xcam") && p["xcam"].is_object()) {
        st.xcamJson = p["xcam"].dump();
    }

    // ---- 诊断：本帧携带 / 沿用上次 ----
    for (int i = 0; i < kTrackedReportFieldCount; ++i) {
        const std::string f = kTrackedReportFields[i];
        if (reportHasField(p, f)) {
            if (!frameFields.empty()) { frameFields += ", "; }
            frameFields += f;
            ++frameCount;
        } else {
            if (!inheritedFields.empty()) { inheritedFields += ", "; }
            inheritedFields += f;
        }
    }
}

} // namespace BambuMqtt

#endif // BAMBU_STATE_MERGE_HPP
