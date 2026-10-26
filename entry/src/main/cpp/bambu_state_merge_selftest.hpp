#ifndef BAMBU_STATE_MERGE_SELFTEST_HPP
#define BAMBU_STATE_MERGE_SELFTEST_HPP

// 增量字段合并的单元自测（不依赖任何打印机）：
// 直接喂"故意缺字段"的 report JSON 给真实的 applyReport()，断言未上报字段保持上次值、
// 且未知温度被标记为未知（UI 显示 "--"），绝不会被默认 0 覆盖。
// 由 napi_init.cpp 的 mqttSelfTestMerge() 调用，结果写入 hilog + 应用沙箱诊断文件。

#include "bambu_state_merge.hpp"

#include <cmath>
#include <cstdio>
#include <map>
#include <string>

namespace BambuMqtt {

inline std::string selfTestMerge()
{
    std::string out;
    int pass = 0;
    int fail = 0;

    auto nearEq = [](double a, double b) -> bool { return std::fabs(a - b) < 1e-6; };
    auto toStr = [](double v) -> std::string {
        char buf[32];
        snprintf(buf, sizeof(buf), "%.2f", v);
        return std::string(buf);
    };
    auto check = [&](const std::string& name, bool ok, const std::string& detail) {
        out += std::string(ok ? "[PASS] " : "[FAIL] ") + name + " :: " + detail + "\n";
        if (ok) { ++pass; } else { ++fail; }
    };
    auto apply = [](PrinterState& st, const std::string& printJson,
                    std::string& ff, std::string& inh, int& fc) {
        nlohmann::json j = nlohmann::json::parse(printJson);
        applyReport(j, st, ff, inh, fc);
    };
    // ext 取值的两个小工具（自测里断言 + 打印全量，便于在 diag 文件里肉眼核对）
    auto getExt = [](const PrinterState& st, const std::string& k) -> std::string {
        auto it = st.ext.find(k);
        return it == st.ext.end() ? std::string("(缺)") : it->second;
    };
    auto extDump = [](const std::map<std::string, std::string>& m) -> std::string {
        std::string s = "{";
        bool first = true;
        for (auto it = m.begin(); it != m.end(); ++it) {
            if (!first) { s += ", "; }
            first = false;
            s += it->first + "=" + it->second;
        }
        return s + "}";
    };

    out += "=== 增量字段合并 单元自测（applyReport 真实逻辑，不连打印机）===\n";

    // 用例 A：已有已知温度基线；本帧只带 gcode_state（缺 nozzle/bed/chamber/mc_percent）
    PrinterState s;
    s.hasNozzleTemp = true; s.nozzleTemp = 25.4;
    s.hasBedTemp = true;    s.bedTemp = 60.1;
    s.hasChamberTemp = true; s.chamberTemp = 32.0;
    s.gcodeState = "IDLE";
    s.progress = 10;
    {
        std::string ff, inh; int fc = 0;
        apply(s, "{\"gcode_state\":\"RUNNING\"}", ff, inh, fc);
        out += "输入A = {\"gcode_state\":\"RUNNING\"}（故意缺 bed_temper/nozzle_temper/chamber_temper/mc_percent）\n";
        out += "  本帧字段: " + ff + "（共" + std::to_string(fc) + "项）；沿用上次值: " + inh + "\n";
        check("A1 缺 bed_temper → 沿用上次值 60.1（未被清零）", nearEq(s.bedTemp, 60.1) && s.hasBedTemp,
              "bed=" + toStr(s.bedTemp) + " known=" + (s.hasBedTemp ? "true" : "false"));
        check("A2 缺 nozzle_temper → 沿用上次值 25.4（未被清零）", nearEq(s.nozzleTemp, 25.4) && s.hasNozzleTemp,
              "nozzle=" + toStr(s.nozzleTemp) + " known=" + (s.hasNozzleTemp ? "true" : "false"));
        check("A3 缺 chamber_temper → 沿用上次值 32.0（未被清零）", nearEq(s.chamberTemp, 32.0) && s.hasChamberTemp,
              "chamber=" + toStr(s.chamberTemp) + " known=" + (s.hasChamberTemp ? "true" : "false"));
        check("A4 gcode_state 已更新为 RUNNING", s.gcodeState == "RUNNING", "state=" + s.gcodeState);
        check("A5 缺 mc_percent → 沿用上次值 10（未被清零）", s.progress == 10,
              "progress=" + std::to_string(s.progress));
    }

    // 用例 B：本帧带 bed_temper（应更新），仍缺 nozzle/chamber（应沿用）
    {
        std::string ff, inh; int fc = 0;
        apply(s, "{\"bed_temper\":75.5}", ff, inh, fc);
        out += "输入B = {\"bed_temper\":75.5}（缺 nozzle_temper/chamber_temper）\n";
        out += "  本帧字段: " + ff + "（共" + std::to_string(fc) + "项）；沿用上次值: " + inh + "\n";
        check("B1 本帧带 bed_temper → 更新为 75.5", nearEq(s.bedTemp, 75.5),
              "bed=" + toStr(s.bedTemp));
        check("B2 仍缺 nozzle_temper → 保持 25.4", nearEq(s.nozzleTemp, 25.4),
              "nozzle=" + toStr(s.nozzleTemp));
        check("B3 仍缺 chamber_temper → 保持 32.0", nearEq(s.chamberTemp, 32.0),
              "chamber=" + toStr(s.chamberTemp));
    }

    // 用例 C：显式上报 0 是"真实值"，必须接受（区分"未上报"与"上报了 0"）
    {
        std::string ff, inh; int fc = 0;
        apply(s, "{\"bed_temper\":0}", ff, inh, fc);
        out += "输入C = {\"bed_temper\":0}（显式上报 0）\n";
        check("C1 显式上报 bed_temper=0 → 接受为 0（非沿用）", nearEq(s.bedTemp, 0.0) && s.hasBedTemp,
              "bed=" + toStr(s.bedTemp) + " known=" + (s.hasBedTemp ? "true" : "false"));
    }

    // 用例 D：全新状态（从未收到过温度）→ 未知温度保持 0 且"未知"标记为 false（UI 显示 "--"），
    //          只有本帧上报的 nozzle 变已知
    {
        PrinterState fresh;
        std::string ff, inh; int fc = 0;
        apply(fresh, "{\"nozzle_temper\":\"221.5\"}", ff, inh, fc);
        out += "输入D = {\"nozzle_temper\":\"221.5\"}（全新状态，字符串数值）\n";
        check("D1 nozzle 解析字符串 221.5 且标记已知", nearEq(fresh.nozzleTemp, 221.5) && fresh.hasNozzleTemp,
              "nozzle=" + toStr(fresh.nozzleTemp) + " known=" + (fresh.hasNozzleTemp ? "true" : "false"));
        check("D2 bed 从未上报 → 保持 0 且标记未知（UI 显示 --）", nearEq(fresh.bedTemp, 0.0) && !fresh.hasBedTemp,
              "bed=" + toStr(fresh.bedTemp) + " known=" + (fresh.hasBedTemp ? "true" : "false"));
        check("D3 chamber 从未上报 → 标记未知（UI 显示 --）", !fresh.hasChamberTemp,
              "known=" + std::string(fresh.hasChamberTemp ? "true" : "false"));
    }

    // 用例 E：X1 腔体温度落在 print.info.temp（等效 chamber_temper 上报）
    {
        PrinterState x;
        std::string ff, inh; int fc = 0;
        apply(x, "{\"info\":{\"temp\":\"35.2\"}}", ff, inh, fc);
        out += "输入E = {\"info\":{\"temp\":\"35.2\"}}（X1 腔体温度）\n";
        check("E1 chamber 取 print.info.temp=35.2 且标记已知", nearEq(x.chamberTemp, 35.2) && x.hasChamberTemp,
              "chamber=" + toStr(x.chamberTemp) + " known=" + (x.hasChamberTemp ? "true" : "false"));
    }

    // 用例 F：表驱动扩展字段（任务名/信号/错误码/阶段/SD 卡）+ 固件版本，
    //          以及"本帧未上报 → 沿用上次值"的语义
    {
        PrinterState e;
        std::string ff, inh; int fc = 0;
        apply(e, "{\"subtask_name\":\"小飞船\",\"wifi_signal\":\"-55dBm\",\"print_error\":117669906,"
                 "\"mc_print_stage\":13,\"sdcard\":true,"
                 "\"info\":{\"module\":[{\"name\":\"ota\",\"sw_ver\":\"01.07.00.00\"}]}}", ff, inh, fc);
        out += "输入F = 任务名/信号/错误码/阶段/SD 卡 + info.module(ota)\n";
        out += "  ext = " + extDump(e.ext) + "\n";
        check("F1 任务名（字符串）", getExt(e, "任务名") == "小飞船", "=" + getExt(e, "任务名"));
        check("F2 信号（字符串 -55dBm）", getExt(e, "信号") == "-55dBm", "=" + getExt(e, "信号"));
        check("F3 错误码（数字 → 十进制字符串）", getExt(e, "错误码") == "117669906", "=" + getExt(e, "错误码"));
        check("F4 阶段（数字）", getExt(e, "阶段") == "13", "=" + getExt(e, "阶段"));
        check("F5 SD 卡（布尔 → 是/否）", getExt(e, "SD 卡") == "是", "=" + getExt(e, "SD 卡"));
        check("F6 固件版本（取 info.module 里 name=ota 的 sw_ver）",
              getExt(e, "固件") == "01.07.00.00", "=" + getExt(e, "固件"));
        // 本帧只带一个温度字段 → ext 里的字段应全部沿用
        std::string ff2, inh2; int fc2 = 0;
        apply(e, "{\"bed_temper\":61.0}", ff2, inh2, fc2);
        check("F7 本帧未上报 ext 字段 → 沿用上次值",
              getExt(e, "任务名") == "小飞船" && getExt(e, "阶段") == "13",
              "任务名=" + getExt(e, "任务名") + " 阶段=" + getExt(e, "阶段"));
    }

    // 用例 G：HMS 数组是"整体替换"，故障恢复推空数组时必须能清掉
    {
        PrinterState h;
        std::string ff, inh; int fc = 0;
        apply(h, "{\"hms\":[{\"attr\":83887360,\"code\":65585}]}", ff, inh, fc);
        check("G1 HMS 已记录（非空）", !h.hmsJson.empty() && h.hmsJson != "[]",
              "hms=" + h.hmsJson);
        apply(h, "{\"gcode_state\":\"RUNNING\"}", ff, inh, fc);
        check("G2 本帧未上报 hms → 沿用（不是清空）", h.hmsJson != "[]", "hms=" + h.hmsJson);
        apply(h, "{\"hms\":[]}", ff, inh, fc);
        check("G3 上报空数组 → 清空（故障恢复能消掉错误条）", h.hmsJson == "[]", "hms=" + h.hmsJson);
    }

    out += "=== 结果: PASS=" + std::to_string(pass) + " FAIL=" + std::to_string(fail) + " ===\n";
    return out;
}

} // namespace BambuMqtt

#endif // BAMBU_STATE_MERGE_SELFTEST_HPP
