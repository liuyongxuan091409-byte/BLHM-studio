import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MqttService } from './MqttService';
import { AppLog } from './AppLog';
import { GcodePackage } from './ThreeMfExport';
import { ftpFolderOf, matchModelId } from '../model/PrinterMatrix';

// =============================================================================
// 打印弹窗的数据服务：AMS 槽位（真实设备状态）+ 三个开关的记忆/下发。
//
// AMS 数据来源（**真实设备状态，不是假数据**）：
//   设备 → MQTT report（print.ams.ams[].tray[]）→ C++ parseAms()
//   （cpp/bambu_mqtt.cpp:233，字段 tray_type / tray_color / remain）
//   → PrinterState.amsJson（cpp/bambu_mqtt.cpp:435）
//   → StateToJson 的 "ams" 字段（cpp/napi_init.cpp:577）
//   → MqttService.getStatus()（ets/service/MqttService.ets:29）→ 这里解析。
//   取不到（未连接 / 无 AMS / 字段为空）→ 按「无 AMS」处理（槽位数组为空）。
//
// 三个开关的真实参数 key（查证结论，详见报告）：
//   · 延时摄影   → AppConfig「print」段 print.timelapse   （AppConfig.cpp:478，默认 "1"）
//   · 打印板调平 → AppConfig「print」段 print.bed_leveling（AppConfig.cpp:472，默认 "1"）
//   · 动态流量调整 → AppConfig「print」段 print.flow_cali （AppConfig.cpp:475，默认 "1"）
//   注：PrintConfig 里确有一个切片侧 timelapse 开关 enable_timelapse（coBool，PrintConfig.cpp:10117，
//   被 Print::enable_timelapse_print 用于生成延时摄影塔身几何，Print.cpp:3314），但它语义是「切片时
//   为延时摄影预留结构」，与设备侧「本单是否录制延时视频」不同；bed_leveling/flow_cali 在 PrintConfig
//   里没有任何对应项。这三个开关本质是设备侧打印选项，因此不走 collectParamsJson/apply_params
//   （内核会把未知 key 记进 skipped）；这里按 collectParamsJson 的写法单独打包成「打印选项 JSON」，
//   随打印请求走设备下发链路。
// =============================================================================

const DOMAIN: number = 0x0000;
// 打印弹窗日志 tag（hilog / 应用内日志 / files/diag/gcode_diag.txt 三通道同用）
export const PRINT_DLG_TAG: string = 'PrintDlg';
// 打印发送链路日志 tag（独立新增 tag，不改动既有 tag）
export const PRINT_SEND_TAG: string = 'PrintSend';

// 安全闸门（任务红线）：未获用户显式授权前，任何情况下都不得真正 publish 打印命令。
// 【用户已明确授权实发】ALLOW_LIVE_PRINT 保持为 true（本轮用户再次确认：不要保险、要真打印）。
// 注：原「空跑保险」（历史 print_options.json 里的一个布尔字段）已按用户要求**整条删除**，点「开始打印」= 导出 → 上传 → 发 MQTT 的完整链路，
// 不再有任何「已构造未发送」的短路分支。
const ALLOW_LIVE_PRINT: boolean = true;

// 持久化文件名（与 panel_width.json / preset_last.json 同级的 filesDir）
const OPTIONS_FILE: string = 'print_options.json';

// AMS 槽位（一条 = 一个物理槽位；来自真实设备状态）
export class AmsSlot {
  slotId: string = '';     // 展示编号：AMS0 → A1..A4，AMS1 → B1..B4
  amsId: number = 0;       // 所属 AMS 单元（真实 ams.id）
  index: number = 0;       // 单元内槽位下标
  color: string = '#808080';
  material: string = '';   // tray_type（如 "PLA Basic"），空 = 空槽位
  remain: number = -1;      // 剩余百分比，-1 = 未知
}

// 外挂料盘（external spool）在 AmsSlot 里的约定：amsId = EXTERNAL_AMS_ID、slotId = EXTERNAL_SLOT_LABEL。
// 取不到数据时【不生成】这条槽位（界面自然不显示该项），绝不编造。
export const EXTERNAL_AMS_ID: number = -1;
export const EXTERNAL_SLOT_LABEL: string = '外挂';

// 打开打印弹窗时的设备快照
export class PrintDeviceInfo {
  connected: boolean = false;
  serial: string = '';
  ip: string = '';
  slots: AmsSlot[] = [];
}

// 三个开关（默认全开；跨会话记忆）
export class PrintOptionsSnapshot {
  timelapse: boolean = true;
  bedLeveling: boolean = true;
  flowCali: boolean = true;
}

// =============================================================================
// 打印请求计划：把「会被打印的 3MF 包 + AMS 映射 + 三个开关」组装成与真实协议一致的
// payload 与上传步骤。全部字段可序列化以便日志回显。
//
// 协议查证结论（本轮已查清；来源逐条标注）：
//   A. 外部权威来源（三个独立项目互相印证，见报告 URL）：
//      · synman/bambu-printer-manager：src/bpm/bambucommands.py:168-190 的 PRINT_3MF_FILE
//        模板，逐字给出 print.project_file 字段表（command/sequence_id/use_ams/ams_mapping/
//        bed_type/url/file/param/md5/profile_id/project_id/subtask_id/subtask_name/task_id/
//        timelapse/bed_leveling/flow_cali/layer_inspect/vibration_cali）。
//      · Doridian/OpenBambuAPI：mqtt.md 确认信封 {"print":{...}}、topic
//        device/{id}/request|report、pushall 请求体 {"pushing":{...,"command":"pushall"}}。
//      · maziggy/bambuddy（生产级客户端 + 真实打印机抓包，与我们的 LAN 场景一致）完整命令：
//        {"print":{"sequence_id":"20000","command":"project_file","param":"Metadata/plate_5.gcode",
//         "url":"ftp://<file>","file":"<file>","md5":"","bed_type":"auto","timelapse":false,
//         "bed_leveling":true,"auto_bed_leveling":1,"flow_cali":false,"vibration_cali":true,
//         "layer_inspect":false,"use_ams":true,"cfg":"0","extrude_cali_flag":0,
//         "extrude_cali_manual_mode":0,"nozzle_offset_cali":2,"subtask_name":"<name>",
//         "profile_id":"0","project_id":"0","subtask_id":"0","task_id":"0",
//         "ams_mapping":[1,3],"ams_mapping2":[{"ams_id":0,"slot_id":1},{"ams_id":0,"slot_id":3}]}}
//   B. 本机真实上报（_evidence_connect/z5.json）print 段 key 原文里：
//      有 **mapping**、无 ams_mapping。→ 请求字段名是 ams_mapping(+ams_mapping2)，
//      上报里的 mapping 是「上报独有」的另一字段，二者不可互用。
//   C. 勘误：**plate_idx 不存在**（三个来源都没有）；盘号只体现在 param="Metadata/plate_<N>.gcode"。
//   · 仓库依据：topic=device/{serial}/request（bambu_mqtt.cpp:759/771）；
//     param 的 gcode 路径格式（bbs_3mf.hpp:25）；信封写法（DevicePanel.ets:728）。
//   · 三个开关的真身是 AppConfig 的 print 段键（AppConfig.cpp:472/475/478），
//     但在 project_file 请求里以同名 bool 出现（bed_leveling/flow_cali/timelapse）。
// =============================================================================

// ams_mapping2 的一项：{ams_id, slot_id}。ams_mapping 是「全局 tray」，本结构是它的显式分解
// （ams_id*4+slot_id），外部料盘/未映射用哨兵值（254/255），见 buildPlan 注释。
export class AmsMap2 {
  amsId: number = 255;
  slotId: number = 255;
}

export class PrintTaskPlan {
  fileName: string = '';        // 上传/打印用的包名（优先 .gcode.3mf，其次项目 3MF）
  filePath: string = '';        // 本地沙箱内该文件的绝对路径
  fileExists: boolean = false;  // 本地是否存在（决定 md5 能否现算、上传是否可行）
  hasGcodePackage: boolean = false; // 是否存在含 gcode 的 .gcode.3mf（能真打印的前提）
  param: string = '';           // 3MF 内 gcode 路径（Metadata/plate_<N>.gcode）
  url: string = '';             // 请求引用的 url；形态按机型：A1系=file:///sdcard<落点>，非A1=ftp://<落点>
  // 本次打印所用机型判定（用于决定 url 形态；来自「当前选中的打印机预设名」）
  printerName: string = '';     // 当前选中的打印机预设名（如 "Bambu Lab A1 mini 0.4 nozzle"）
  a1Series: boolean = false;    // 是否 A1 系列（含 "A1"）→ url 用文件系统路径
  md5: string = '';             // 文件 md5（A: 允许为空串；这里现算，失败留空）
  plateNumber: number = 1;      // 盘号（只用于拼 param，**不是**独立协议字段 plate_idx）
  bedType: string = 'auto';     // A: bed_type，"auto" 为默认
  useAms: boolean = false;
  amsMapping: number[] = [];    // A: 全局 tray 列表；-1=不走 AMS
  amsMapping2: AmsMap2[] = [];  // A: 与 ams_mapping 同长度的 {ams_id,slot_id} 明细
  timelapse: boolean = true;
  bedLeveling: boolean = true;
  flowCali: boolean = true;
  sequenceId: string = '1';
  subtaskName: string = '';
  payload: string = '';         // 最终 MQTT payload 原文
  mappingDetail: string = '';   // 对象→槽位→全局 tray 的换算明细（日志回显）
  uploadPlan: string = '';      // 上传步骤文字计划
  gapNote: string = '';         // 距「真正能打印」还差哪一步
}

// ---- JSON.parse 的中间类型（ArkTS 静态类型，禁止 any）----
class RawTray {
  type: string = '';
  color: string = '#808080';
  remain: number = -1;
}

class RawAmsUnit {
  id: string = '';
  humidity: number = 0;
  temp: number = 0;
  trays: RawTray[] = [];
}

class RawStatus {
  connected: boolean = false;
  serial: string = '';
  ip: string = '';
  ams: RawAmsUnit[] = [];
  // 外挂料盘（print.vt_tray）：缺省/空槽时为空对象，界面据「type/color 是否为空」决定是否显示该项
  externalSpool: RawTray = new RawTray();
}

// FTPS 上传结果（原生 ftpsUpload 返回 JSON 的同构解析类型）
class RawFtpsResult {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  remotePath: string = '';
  sentBytes: number = -1;
  log: string[] = [];
}

// FTPS LIST 结果（原生 ftpsList 返回 JSON 的同构解析类型）：entries = 目录原始行（含权限/大小/名字）
class RawFtpsList {
  ok: boolean = false;
  code: string = '';
  message: string = '';
  dir: string = '';
  entries: string[] = [];
  log: string[] = [];
}

// 落点探测结果（一次 LIST 一个候选目录）：entries = 目录原始行（权限/大小/名字）。
class DirProbe {
  dir: string = '';
  ok: boolean = false;
  code: string = '';
  message: string = '';
  entries: string[] = [];
}

// 单个候选落点的上传尝试结果：ok=true 表示 FTPS PUT 成功；否则 reason = 该落点的失败原因。
// 为什么要带上原因：A1 系列常在没有诊断文件可捞的机器（如客户的手机）上测试，
// 必须在 UI 提示里直接写明卡在哪一步（登录/EPSV/STOR 收尾…），否则只能看到一句笼统的失败。
class DirTry {
  ok: boolean = false;
  reason: string = '';
}

// 上传 + LIST 复核的最终结论（导出给 UI 判读：Index.ets）。
export class UploadOutcome {
  ok: boolean = false;     // 上传成功**且** LIST 复核到本次文件名确实在列
  landed: string = '';     // 最终落点（如 "/cache/bhlm_....gcode.3mf"）；未确认时为空
  message: string = '';    // 可读结语 / 失败原因（可直接提示用户）
}

// 槽位展示编号：AMS0=A1..A4，AMS1=B1..B4…
function slotLabel(amsId: number, index: number): string {
  const a: number = (amsId >= 0 && amsId < 26) ? amsId : 0;
  return String.fromCharCode(65 + a) + (index + 1);
}

export class PrintOptions {
  // 读取真实设备状态 → 连接态 + AMS 槽位。异常不吞：打 hilog 后返回「未连接」快照。
  static fetch(): Promise<PrintDeviceInfo> {
    return MqttService.getStatus().then((json: string): PrintDeviceInfo => {
      const info: PrintDeviceInfo = new PrintDeviceInfo();
      try {
        const st: RawStatus = JSON.parse(json) as RawStatus;
        info.connected = st.connected === true;
        info.serial = st.serial !== undefined ? st.serial : '';
        info.ip = st.ip !== undefined ? st.ip : '';
        const units: RawAmsUnit[] = st.ams !== undefined ? st.ams : [];
        for (let u = 0; u < units.length; u++) {
          const unit: RawAmsUnit = units[u];
          const parsed: number = parseInt(unit.id);
          const amsId: number = Number.isNaN(parsed) ? u : parsed;
          const trays: RawTray[] = unit.trays !== undefined ? unit.trays : [];
          for (let i = 0; i < trays.length; i++) {
            const t: RawTray = trays[i];
            const s: AmsSlot = new AmsSlot();
            s.amsId = amsId;
            s.index = i;
            s.slotId = slotLabel(amsId, i);
            s.color = t.color !== undefined && t.color !== '' ? t.color : '#808080';
            s.material = t.type !== undefined ? t.type : '';
            s.remain = t.remain !== undefined ? t.remain : -1;
            info.slots.push(s);
          }
        }
        // 外挂料盘（print.vt_tray）：type/color 都为空 = 空槽/取不到 → 不生成该项（不显示、不编造）
        const ext: RawTray = st.externalSpool;
        const extType: string = ext !== undefined && ext.type !== undefined ? ext.type : '';
        const extColor: string = ext !== undefined && ext.color !== undefined ? ext.color : '';
        if (extType !== '' || (extColor !== '' && extColor !== '#808080')) {
          const s: AmsSlot = new AmsSlot();
          s.amsId = EXTERNAL_AMS_ID;
          s.index = 0;
          s.slotId = EXTERNAL_SLOT_LABEL;
          s.color = extColor !== '' ? extColor : '#808080';
          s.material = extType;
          s.remain = ext.remain !== undefined ? ext.remain : -1;
          info.slots.push(s);
        }
      } catch (e) {
        hilog.error(DOMAIN, PRINT_DLG_TAG, '解析设备状态失败: %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
        info.connected = false;
        info.slots = [];
      }
      return info;
    }).catch((e: Error): PrintDeviceInfo => {
      hilog.error(DOMAIN, PRINT_DLG_TAG, '读取设备状态异常: %{public}s', e.message);
      return new PrintDeviceInfo();
    });
  }

  // 读开关记忆（无文件 = 首次启动，用默认全开）
  static load(filesDir: string): PrintOptionsSnapshot {
    const snap: PrintOptionsSnapshot = new PrintOptionsSnapshot();
    if (filesDir.length === 0) {
      return snap;
    }
    const path: string = `${filesDir}/${OPTIONS_FILE}`;
    try {
      if (!fs.accessSync(path)) {
        return snap;
      }
      const text: string = fs.readTextSync(path);
      if (text.length === 0) {
        return snap;
      }
      const saved: PrintOptionsSnapshot = JSON.parse(text) as PrintOptionsSnapshot;
      snap.timelapse = saved.timelapse === true;
      snap.bedLeveling = saved.bedLeveling === true;
      snap.flowCali = saved.flowCali === true;
      // 兼容旧文件：历史 print_options.json 里可能还有「空跑保险」布尔键 —— 该字段已整体移除，
      // 这里不读、不认，一律忽略（反序列化到上面这个不含它的类即可，多余键自然被丢弃）。
    } catch (e) {
      hilog.error(DOMAIN, PRINT_DLG_TAG, '读取开关记忆失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    return snap;
  }

  // 写开关记忆（映射不落盘：对象每次都会变，跨次记忆会张冠李戴 —— 见报告）
  static save(filesDir: string, snap: PrintOptionsSnapshot): void {
    if (filesDir.length === 0) {
      return;
    }
    const path: string = `${filesDir}/${OPTIONS_FILE}`;
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(snap));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(DOMAIN, PRINT_DLG_TAG, '保存开关记忆失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 打印选项打包（沿用 SliceParamStore.collectParamsJson 的写法）：
  // 这三个 key 是设备侧打印选项（Bambu 的 print 段），随打印请求下发，不参与切片参数。
  static collectJson(o: PrintOptionsSnapshot): string {
    return '{"timelapse":' + (o.timelapse ? 'true' : 'false') +
      ',"bed_leveling":' + (o.bedLeveling ? 'true' : 'false') +
      ',"flow_cali":' + (o.flowCali ? 'true' : 'false') + '}';
  }

  static optionsText(o: PrintOptionsSnapshot): string {
    return `延时=${o.timelapse ? '开' : '关'} 调平=${o.bedLeveling ? '开' : '关'} 流量=${o.flowCali ? '开' : '关'}`;
  }

  // 三通道日志：hilog + 应用内日志 + files/diag/gcode_diag.txt（沿用 ThreeMfExport.log 的通道）
  static log(filesDir: string, text: string): void {
    hilog.info(DOMAIN, PRINT_DLG_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${PRINT_DLG_TAG}] ${text}`);
      if (filesDir.length > 0) {
        if (!AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`, [`[${PRINT_DLG_TAG}] ${text}`])) {
          hilog.warn(DOMAIN, PRINT_DLG_TAG, '打印弹窗日志落盘失败');
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, PRINT_DLG_TAG, '打印弹窗日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // ===========================================================================
  // 打印发送链路（tag PrintSend；三通道日志）
  // ===========================================================================

  // 槽位号 → 全局 tray 索引。
  // 依据：DevicePanel.sendAmsRefresh 用 M620 R{amsId*4+slotId}（DevicePanel.ets:765）表达
  // 「从哪个 tray 取料」，即 全局 tray = ams_id*4 + 槽位下标。此处沿用同一口径。
  // 槽位号来自 AmsSlot.slotLabel：A1..A4=A 单元(amsId0)、B1..B4=B 单元…；解析失败返回 -1。
  static slotToTrayIndex(slotId: string): number {
    if (slotId.length < 2) { return -1; }
    const letter: number = slotId.charCodeAt(0) - 65;         // 'A'→0, 'B'→1 …
    const num: number = parseInt(slotId.substring(1));
    if (letter < 0 || Number.isNaN(num) || num < 1) { return -1; }
    return letter * 4 + (num - 1);
  }

  // ams_mapping2 数组 → JSON 原文（ArkTS 静态类型，手写序列化避免 any）。
  private static map2Json(list: AmsMap2[]): string {
    const parts: string[] = [];
    for (const m of list) {
      parts.push('{"ams_id":' + m.amsId + ',"slot_id":' + m.slotId + '}');
    }
    return '[' + parts.join(',') + ']';
  }

  // 组装 payload 原文（每次 md5 定稿后调用，保证 payload 里是最终值）。
  // 字段名/类型全部按来源 A（三来源一致 + bambuddy 真实抓包）确定：
  //   · **不含 plate_idx**（该字段不存在）；盘号在 param 里。
  //   · 请求字段名是 ams_mapping + ams_mapping2（上报侧的 mapping 不用于请求）。
  //   · 常量项（vibration_cali/layer_inspect/cfg/校准系列）取自 bambuddy 真实抓包固定值，
  //     标注「单来源(真实抓包)」，实发前应抓一次官方请求核对。
  private static composePayload(plan: PrintTaskPlan): string {
    return '{"print":{' +
      '"sequence_id":"' + plan.sequenceId + '",' +
      '"command":"project_file",' +
      '"param":"' + plan.param + '",' +
      '"url":"' + plan.url + '",' +
      '"file":"' + plan.fileName + '",' +
      '"md5":"' + plan.md5 + '",' +
      '"bed_type":"' + plan.bedType + '",' +
      '"subtask_name":"' + plan.subtaskName + '",' +
      '"profile_id":"0",' +
      '"project_id":"0",' +
      '"subtask_id":"0",' +
      '"task_id":"0",' +
      '"use_ams":' + (plan.useAms ? 'true' : 'false') + ',' +
      '"ams_mapping":[' + plan.amsMapping.join(',') + '],' +
      '"ams_mapping2":' + PrintOptions.map2Json(plan.amsMapping2) + ',' +
      '"bed_leveling":' + (plan.bedLeveling ? 'true' : 'false') + ',' +
      '"flow_cali":' + (plan.flowCali ? 'true' : 'false') + ',' +
      '"vibration_cali":true,' +
      '"layer_inspect":false,' +
      '"timelapse":' + (plan.timelapse ? 'true' : 'false') + ',' +
      '"cfg":"0",' +
      '"auto_bed_leveling":1,' +
      '"extrude_cali_flag":0,' +
      '"extrude_cali_manual_mode":0,' +
      '"nozzle_offset_cali":2' +
      '}}';
  }

  // 机型判定：当前选中的打印机预设名含 "A1"（大小写不敏感）→ A1 系列（A1 / A1 mini 都含 "A1"）。
  // 判定不了（空名）→ 保守返回 false（走非 A1 分支，保持既有可用口径）。
  static isA1Series(printerName: string): boolean {
    return printerName.toUpperCase().indexOf('A1') >= 0;
  }

  // url 形态按机型选择（A1 修复的核心）：
  //   A1 系列（A1 / A1 mini）→ file:///sdcard<落点>（**文件系统路径**）。
  //     依据：A1 的 /cache 实为 FAT32 SD 卡；project_file 的 url 发 ftp:///cache/<名> 会被当 host/协议
  //     处理 → 作业被接受后随即取消并报 0500-C010（SD 卡读写异常）。
  //     参见 https://dev.to/amsozzer/driving-a-bambu-lab-printer-over-mqtt-12nb（A1 mini 逐行验证）。
  //   非 A1（X1/P1/H2D/P2S…）→ ftp://<落点>（既有可用口径：空 host + 绝对路径，已跑通，不动）。
  static urlForLanded(a1Series: boolean, landed: string): string {
    return a1Series ? `file:///sdcard${landed}` : `ftp://${landed}`;
  }

  // url 形态的可读标签（仅用于日志自证）。
  static urlFormText(a1Series: boolean): string {
    return a1Series ? 'file:///sdcard/cache/...' : 'ftp:///cache/...';
  }

  // subtask_name：去掉包名末尾的 .3mf / .gcode 扩展名（来源 A：bambu-printer-manager 的
  // 「Strip .3mf and .gcode extensions」；bambuddy 抓包里 "He_Man_Wig.3mf" → "He_Man_Wig"）。
  private static stripExt(fileName: string): string {
    let n: string = fileName;
    if (n.endsWith('.3mf')) { n = n.substring(0, n.length - 4); }
    if (n.endsWith('.gcode')) { n = n.substring(0, n.length - 6); }
    return n;
  }

  // 两位补零（ASCII 时间戳拼装用）。
  private static pad2(n: number): string {
    return n < 10 ? '0' + n : `${n}`;
  }

  // 上传/打印用的**纯 ASCII 短文件名**：bhlm_<yyMMddHHmmss>_p<plate>.gcode.3mf。
  // 为什么必须 ASCII：A1/A1 mini 的 /cache 是 FAT32 SD 卡，固件解析非 ASCII（中文）名失败 →
  // 报 0500-C010。为什么带时间戳：同一盘反复打印/上传不会覆盖同名旧文件，便于在 /cache LIST 里认出本次。
  private static asciiUploadName(plate: number): string {
    const d: Date = new Date();
    const ts: string = `${PrintOptions.pad2(d.getFullYear() % 100)}${PrintOptions.pad2(d.getMonth() + 1)}` +
      `${PrintOptions.pad2(d.getDate())}${PrintOptions.pad2(d.getHours())}${PrintOptions.pad2(d.getMinutes())}` +
      `${PrintOptions.pad2(d.getSeconds())}`;
    return `bhlm_${ts}_p${plate}.gcode.3mf`;
  }

  // 从 param（形如 "Metadata/plate_1.gcode"）里解析盘号 N；解析不到回退 1（不用正则，避免运行时类型差异）。
  private static plateFromParam(param: string): number {
    const key: string = 'plate_';
    const i: number = param.indexOf(key);
    if (i < 0) { return 1; }
    let j: number = i + key.length;
    let s: string = '';
    while (j < param.length && param.charCodeAt(j) >= 48 && param.charCodeAt(j) <= 57) {
      s += param.charAt(j);
      j++;
    }
    const n: number = s.length > 0 ? parseInt(s) : 0;
    return n > 0 ? n : 1;
  }

  // 是否全部为 ASCII 可见字符（自检：上传名不得含中文/空格等，打印进日志便于核对）。
  private static isAscii(s: string): boolean {
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 0x21 || c > 0x7E) { return false; }
    }
    return s.length > 0;
  }

  // 构造打印请求计划。pkg 是**打印前实际产出**的含 gcode 3MF（ThreeMfExport.ensureGcodePackage 的返回值），
  // 直接用它记录的真实落盘路径 / 文件名 / 包 md5 —— 绝不按名字去沙箱拼路径猜。
  // pairs 形如 "3→A1,4→B2"（对象 id → 槽位号），来自 PrintDialog.mappingPairs()。
  static buildPlan(filesDir: string, info: PrintDeviceInfo, pairs: string,
    opts: PrintOptionsSnapshot, seq: string, pkg: GcodePackage, printerName: string,
    connectedModel: string): Promise<PrintTaskPlan> {
    const plan: PrintTaskPlan = new PrintTaskPlan();
    plan.timelapse = opts.timelapse;
    plan.bedLeveling = opts.bedLeveling;
    plan.flowCali = opts.flowCali;
    plan.sequenceId = seq;
    // param = 包内真实存在的 gcode 路径（由 ThreeMfExport.ensureGcodePackage 从 zip 中央目录读出），不写死
    plan.param = pkg.param;
    plan.plateNumber = PrintOptions.plateFromParam(pkg.param);   // 盘号真身=param 里的 plate_N

    // 会被打印 / 上传的包 = 刚才**实际产出**的那个文件（真实路径，不是按名字猜的沙箱路径）
    // 【A1 / A1 mini 修复】上传与引用用的文件名必须是**纯 ASCII 短名**。
    //   依据：A1 系列/P1 系列无「内部存储」，/cache 实际就是 FAT32 的 SD 卡；固件解析中文/空格等
    //   非 ASCII 文件名会失败 → 作业被接受后随即取消并报 0500-C010「SD 卡读写异常」。
    //   包内文件名（pkg.fileName，中文「未命名项目.gcode.3mf」）只用于本地保存展示，
    //   上传 PUT 名 / url / file 字段统一改用这里的 ASCII 名；本地 md5 计算的是同一个 pkg.path，
    //   故「PUT 名 = url 名 = file 字段 = md5 对象」四者同源同名。
    plan.fileName = PrintOptions.asciiUploadName(plan.plateNumber);
    plan.filePath = pkg.path;
    plan.md5 = pkg.md5;
    plan.fileExists = true;
    plan.hasGcodePackage = pkg.withGcode === true && pkg.hasPlateEntry === true;
    PrintOptions.logSend(filesDir,
      `上传名 ASCII 改写 原包名=${pkg.fileName} → 上传名=${plan.fileName}（盘号=${plan.plateNumber} 取自 param=${plan.param}）`);

    // 机型判定（本轮 A1 修复）：用「当前选中的打印机预设名」判定是否 A1 系列（含 "A1"）。
    // 判定不了（空名）→ 保守走非 A1 分支，保持既有可用口径。
    plan.printerName = printerName;
    // 【机型判定取谁】决定 url 形态时优先看**实际连接的打印机机型**（SSDP 友好名，如 "A1"/"A1 mini"/"X1C"）：
    // 最终是打印机自己去解析这个 url，所以它认哪台机才是对的。只看「切片预设名」不够——
    // 预设是用户可选的，曾经出现「连着 A1 但预设停在 X1 Carbon」→ 判成非 A1 → 发出 A1 不认的
    // ftp:///cache/... 形态，打印机接单后立刻取消并报 0500-C010（客户实测现象，日志留证）。
    // 连接机型未知（空）时退回切片预设名（既有口径，保持兼容）。
    const modelForUrl: string = connectedModel !== '' ? connectedModel : printerName;
    plan.a1Series = PrintOptions.isA1Series(modelForUrl);

    // 【与机型能力矩阵交叉校验：只落日志、不改行为】
    // 矩阵里 ftp_folder = "sdcard/" 的机型是 A1 / A1 mini / P1P / P1S / A2L（桌面版口径，见 PrinterMatrix）。
    // 但其中只有 A1 / A1 mini 是**我们真机验证过**的「必须用 file:///sdcard/... 形态」，
    // P1P/P1S 尚无真机证据 —— 所以 url 形态的判据暂时保持既有启发式，不一致时落日志留证，
    // 等 P1P/P1S 可测时再据此决定是否切到矩阵口径（避免「用推断替换已验证结论」）。
    const matrixId: string = matchModelId(modelForUrl);
    const matrixFtp: string = ftpFolderOf(modelForUrl);
    if (matrixId !== '' && (matrixFtp === 'sdcard/') !== plan.a1Series) {
      PrintOptions.logSend(filesDir,
        `【机型判定与矩阵不一致·待真机验证】矩阵 model=${matrixId} ftp_folder=${matrixFtp === '' ? '(空)' : matrixFtp} ` +
        `→ 矩阵口径为 ${matrixFtp === 'sdcard/' ? 'SD 卡路径形态' : 'ftp:// 形态'}，` +
        `当前判据走了 ${plan.a1Series ? 'SD 卡路径形态' : 'ftp:// 形态'}`);
    }

    // url 形态按机型选择：
    //   A1 系列（A1 / A1 mini）→ file:///sdcard/cache/<名>（文件系统路径；发 ftp:// 到 A1 会 0500-C010）
    //   非 A1（X1/P1/H2D/P2S…）→ ftp:///cache/<名>（既有可用口径：空 host + 绝对路径）
    // 这里给的是**临时默认**（/cache）；真实落点由 uploadPrintFile 的「探测 → 上传」决定，
    // 上传成功后会用它按同规则改写 plan.url（见 uploadPrintFile），故最终 url 一定对应真实到位的文件。
    const initialLanded: string = `/cache/${plan.fileName}`;
    plan.url = PrintOptions.urlForLanded(plan.a1Series, initialLanded);
    PrintOptions.logSend(filesDir,
      `机型判定=${plan.a1Series ? 'A1系' : '非A1系'}（判定依据=${connectedModel !== '' ? '已连接机型' : '切片预设'} ` +
      `已连接机型=${connectedModel !== '' ? connectedModel : '(未知)'} ` +
      `切片预设=${printerName !== '' ? printerName : '(未知)'}） ` +
      `url形态=${PrintOptions.urlFormText(plan.a1Series)} 初始url=${plan.url}`);
    plan.subtaskName = PrintOptions.stripExt(plan.fileName);   // A: 去掉 .3mf/.gcode 扩展名
    plan.bedType = 'auto';                                     // A: bed_type 默认 "auto"
    plan.useAms = info.slots.length > 0;

    // ---- AMS 映射换算：对象 → 槽位号 → 全局 tray（全局 tray = ams_id*4 + 槽位下标）----
    // 依据：DevicePanel.ets:765 的 M620 R{amsId*4+slotId}；来源 A 的 tray 编码表
    // （标准 AMS 0-103 = ams_id*4+slot_id；AMS-HT 128-135；外部料盘 254/255）。
    // 语义（来源 A，bambuddy 源码 resolve_external_spools_in_mapping）：
    //   ams_mapping[i] = 第 i 个**切片包耗材槽位**要用的全局 tray；-1 = 该槽位不走 AMS；
    //   固件拒绝在扁平表里写 254/255，外部料盘的真实目标只放在 ams_mapping2={ams_id:254|255,slot_id:0}；
    //   {255,255} = 「未映射」。数组长度 = 切片包的耗材槽位数。
    // **已知缺口**：本工程只有「对象→槽位」映射，没有切片包的耗材槽位顺序，
    //   故按对象首次出现顺序去重近似；多耗材场景还缺 gcode 的 `; filament` / plate_x.json 顺序。
    const detail: string[] = [];
    const trayIds: number[] = [];
    const items: string[] = pairs === '-' ? [] : pairs.split(',');
    for (const it of items) {
      const seg: string[] = it.split('→');
      if (seg.length !== 2) { continue; }
      const tray: number = PrintOptions.slotToTrayIndex(seg[1]);
      detail.push(`${seg[0]}→${seg[1]}→tray${tray}`);
      if (tray >= 0 && trayIds.indexOf(tray) < 0) { trayIds.push(tray); }
    }
    const map2: AmsMap2[] = [];
    if (plan.useAms && trayIds.length > 0) {
      plan.amsMapping = trayIds;
      for (const t of trayIds) {
        const m: AmsMap2 = new AmsMap2();
        m.amsId = Math.floor(t / 4);
        m.slotId = t % 4;
        map2.push(m);
      }
    } else {
      // 不走 AMS：扁平表用 -1；ams_mapping2 用未映射哨兵 {255,255}（来源 A）。
      plan.useAms = false;
      plan.amsMapping = [-1];
      const m: AmsMap2 = new AmsMap2();
      m.amsId = 255;
      m.slotId = 255;
      map2.push(m);
    }
    plan.amsMapping2 = map2;
    plan.mappingDetail = detail.length > 0 ? detail.join(' ') : '无映射(未指定槽位)';

    plan.uploadPlan = `FTPS ${info.ip}:990 用户=bblp PUT <候选落点>/${plan.fileName} 源=${plan.filePath}` +
      `（落点由探测决定：先 /cache，复核失败回退实测存在的目录；隐式 FTPS + 仅该连接 VERIFY_NONE）`;
    plan.gapNote = '缺口: 1) ams_mapping 下标应为「切片包耗材槽位顺序」，现按对象映射顺序近似(缺 gcode 的 ; filament 顺序);' +
      ' 2) 实发前需抓一次官方(BambuStudio/Handy)请求核对 cfg/auto_bed_leveling/校准系列取值';

    PrintOptions.logSend(filesDir,
      `打印计划就绪 包=${plan.fileName} 路径=${plan.filePath} 字节=${pkg.sizeBytes} ` +
      `含gcode=${plan.hasGcodePackage ? '是' : '否'} param=${plan.param} 包md5=${plan.md5} 内核gcodeMd5=${pkg.gcodeMd5}`);
    plan.payload = PrintOptions.composePayload(plan);
    return Promise.resolve(plan);
  }

  // ---- FTPS 上传 + 落点探测/自愈（把计划里那个**真实落盘的**含 gcode 3MF PUT 到打印机）---------
  // 本轮（A1/A1 mini 0500-C010）核心：**不硬编码 /cache，按实测落点决定**。
  //   · 先 LIST "/"、"/cache"、"/sdcard" 看清真实目录结构（逐条落日志，供与 X1C 对比）；
  //   · 按候选顺序上传 → 每次用 LIST 复核「本次文件名确实在列」→ 取第一个复核通过的落点；
  //   · 全部失败 → 绝不盲发 project_file，返回可读提示。
  // X1/P1/H2D 既有口径不动：/cache 永远排候选第一，回退只在其复核失败时生效。
  // 用 plan.filePath / plan.fileName（来自实际产出的文件），**不再按名字去沙箱拼路径猜**。
  // 打印/上传前的会话等待 + 上传（对外入口）。
  static uploadPrintFile(filesDir: string, plan: PrintTaskPlan): Promise<UploadOutcome> {
    // 【为什么要等】A 系列实测：打印机会周期性关闭 MQTT 连接（约每 20 秒一次），App 自愈要 3~5 秒。
    // 若用户恰好在这个断线窗口里点打印，FTPS 第一步就会因「没有 MQTT 会话」返回 NOSESSION，
    // 整个打印在还没发起任何网络请求前就失败（客户实测现象）。这里先有界等待连接恢复，
    // 把这段抖动对用户隐藏；超时也照常继续，由后续步骤给出真实失败原因。
    return PrintOptions.waitSession(filesDir, 8000).then((): Promise<UploadOutcome> => {
      return PrintOptions.uploadPrintFileNow(filesDir, plan);
    });
  }

  // 打印前等待 MQTT 会话恢复（有界轮询）。只做等待，不发起重连——重连由原生侧自愈负责。
  private static waitSession(filesDir: string, waitMs: number): Promise<boolean> {
    const t0: number = Date.now();
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      const tick = (): void => {
        MqttService.getStatus().then((s: string): void => {
          let ok: boolean = false;
          try {
            ok = (JSON.parse(s) as RawStatus).connected === true;
          } catch (e) {
            ok = false;
          }
          if (ok) {
            PrintOptions.logSend(filesDir, `打印前会话等待：已连接（等了 ${Date.now() - t0}ms）`);
            resolve(true);
            return;
          }
          if (Date.now() - t0 >= waitMs) {
            PrintOptions.logSend(filesDir,
              `打印前会话等待：${waitMs}ms 内未恢复连接，仍继续（后续会给出真实原因）`);
            resolve(false);
            return;
          }
          setTimeout(tick, 300);
        }).catch((e: Error): void => {
          if (Date.now() - t0 >= waitMs) { resolve(false); return; }
          setTimeout(tick, 300);
        });
      };
      tick();
    });
  }

  private static uploadPrintFileNow(filesDir: string, plan: PrintTaskPlan): Promise<UploadOutcome> {
    const outcome: UploadOutcome = new UploadOutcome();
    const filePath: string = plan.filePath;
    const fileName: string = plan.fileName;
    if (filePath === '' || fileName === '') {
      outcome.message = '计划里没有可上传的文件（尚未产出含 gcode 3MF）';
      PrintOptions.logSend(filesDir, `跳过上传：${outcome.message}`);
      return Promise.resolve(outcome);
    }
    // 前置校验：真实路径必须存在、可读、非空
    let size: number = -1;
    try {
      const st: fs.Stat = fs.statSync(filePath);
      if (!st.isFile()) {
        outcome.message = `目标不是普通文件 ${filePath}`;
        PrintOptions.logSend(filesDir, `跳过上传：${outcome.message}`);
        return Promise.resolve(outcome);
      }
      size = st.size;
    } catch (e) {
      const reason: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      outcome.message = `本地文件不存在或不可读 ${filePath}（${reason}）`;
      PrintOptions.logSend(filesDir, `跳过上传：${outcome.message}`);
      return Promise.resolve(outcome);
    }
    if (size <= 0) {
      outcome.message = `本地文件为空 ${filePath}（0 字节）`;
      PrintOptions.logSend(filesDir, `跳过上传：${outcome.message}`);
      return Promise.resolve(outcome);
    }
    PrintOptions.logSend(filesDir,
      `待上传文件 ${filePath} 大小=${size}字节 上传名=${fileName} 格式=.gcode.3mf(含gcode) 用户=bblp 端口=990 隐式FTPS`);

    // ① 探测目录结构（只读，**仅诊断**）→ ② 依据实测决定候选落点顺序 → ③ 逐个上传（LIST 复核仅记日志）
    return PrintOptions.probeDirs(filesDir).then((probes: DirProbe[]): Promise<UploadOutcome> => {
      const candidates: string[] = PrintOptions.candidateDirs(probes);
      PrintOptions.logSend(filesDir, `候选落点顺序（由实测探测得出）=${candidates.join(' → ')}`);
      // 逐个候选落点的失败原因（汇总进最终提示，让用户/客户在手机上直接看到卡在哪一步）
      const fails: string[] = [];
      let chain: Promise<void> = Promise.resolve();
      for (const d of candidates) {
        chain = chain.then((): Promise<void> => {
          if (outcome.ok) { return Promise.resolve(); }   // 已确认落点，后续候选不再试
          return PrintOptions.uploadAndVerify(filesDir, plan, d).then((hit: DirTry): void => {
            if (hit.ok) {
              outcome.ok = true;
              outcome.landed = `${d}/${fileName}`;
              // 【A1 修复】url 形态按机型：A1系=file:///sdcard<落点>，非A1=ftp://<落点>
              plan.url = PrintOptions.urlForLanded(plan.a1Series, outcome.landed);
              // url 变了：payload 里内嵌 url，必须用最终落点重算，保证「上传到的位置 = 请求引用的位置」
              plan.payload = PrintOptions.composePayload(plan);
              outcome.message = `上传成功 落点=${outcome.landed}（LIST 复核结果见日志，仅诊断、不阻塞）`;
              PrintOptions.logSend(filesDir,
                `最终采用落点=${outcome.landed} → url=${plan.url} ` +
                `机型判定=${plan.a1Series ? 'A1系' : '非A1系'} url形态=${PrintOptions.urlFormText(plan.a1Series)}（payload 已按最终落点重算）`);
            } else {
              fails.push(`${d}：${hit.reason !== '' ? hit.reason : '未返回原因'}`);
              PrintOptions.logSend(filesDir, `候选落点上传失败（继续下一个，若有）：${d}`);
            }
          });
        });
      }
      return chain.then((): UploadOutcome => {
        if (!outcome.ok) {
          outcome.message = '无法把打印包写入打印机存储（各候选落点上传均失败），请检查 SD 卡/连接。'
            + `失败原因：${fails.join('；')}`;
          PrintOptions.logSend(filesDir, `上传自检结论：${outcome.message}`);
        }
        return outcome;
      });
    });
  }

  // 探测目录（只读）：依次 LIST 给定目录，把每个目录的条目逐条落日志，返回每个目录的结果。
  // 目的：看清 A1/A1 mini（无内部存储）真实的 SD 卡落点层级，并与 X1C（有 /cache）对比。
  private static probeDirs(filesDir: string): Promise<DirProbe[]> {
    const dirs: string[] = ['/', '/cache', '/sdcard'];
    const results: DirProbe[] = [];
    PrintOptions.logSend(filesDir, `探测目录 开始 依次 LIST ${dirs.join(' ')}`);
    let chain: Promise<void> = Promise.resolve();
    for (const d of dirs) {
      chain = chain.then((): Promise<void> => {
        return MqttService.ftpsList(d).then((json: string): void => {
          const p: DirProbe = new DirProbe();
          p.dir = d;
          try {
            const r: RawFtpsList = JSON.parse(json) as RawFtpsList;
            p.ok = r.ok === true;
            p.code = r.code !== undefined ? r.code : '-';
            p.message = r.message !== undefined ? r.message : '';
            p.entries = r.entries !== undefined ? r.entries : [];
          } catch (e) {
            p.ok = false;
            p.code = 'PARSE';
            p.message = `结果解析失败 原文=${json}`;
          }
          PrintOptions.logSend(filesDir,
            `探测目录 LIST ${d} ok=${p.ok ? '是' : '否'} 返回码=${p.code} 条目数=${p.entries.length} 说明=${p.message}`);
          // 把 LIST 的 FTPS 交互原文也落下来：LIST 与 STOR 走同一段数据口代码，
          // 「LIST 成功、STOR 数据口没回音」这种对照必须能看到 LIST 用的是哪个数据口变体。
          PrintOptions.logUploadDetail(filesDir, json);
          for (const e of p.entries) { PrintOptions.logSend(filesDir, `探测目录 ${d}| ${e}`); }
          results.push(p);
        }).catch((e: Error): void => {
          const p: DirProbe = new DirProbe();
          p.dir = d;
          p.message = `异常 ${e.message}`;
          PrintOptions.logSend(filesDir, `探测目录 LIST ${d} 异常 ${e.message}`);
          results.push(p);
        });
      });
    }
    return chain.then((): DirProbe[] => results);
  }

  // 候选落点顺序：/cache 永远第一（X1/P1/H2D 既有可用口径）；其后是实测存在的兜底目录（如 /sdcard）。
  private static candidateDirs(probes: DirProbe[]): string[] {
    const out: string[] = [];
    out.push('/cache');                 // 无条件先试 /cache（回退只在其复核失败时生效）
    for (const p of probes) {
      if (p.ok && p.dir !== '' && p.dir !== '/' && out.indexOf(p.dir) < 0) { out.push(p.dir); }
    }
    return out;
  }

  // 上传到某个候选目录。返回 DirTry：ok=true = FTPS PUT 成功（本次文件名已写入该目录）；
  // ok=false 时 reason 给出原生返回的「返回码 + 说明」，供上层汇总成用户可见的失败原因。
  // 【A1 修复】LIST 复核降级为**诊断**：只记日志，**不再作为放行条件**（LIST 失败不得阻塞打印）。
  private static uploadAndVerify(filesDir: string, plan: PrintTaskPlan, dir: string): Promise<DirTry> {
    const remotePath: string = `${dir}/${plan.fileName}`;
    const res: DirTry = new DirTry();
    PrintOptions.logSend(filesDir, `上传目标=${remotePath}（候选落点 ${dir}）`);
    return MqttService.ftpsUpload(plan.filePath, remotePath).then((json: string): Promise<DirTry> => {
      let r: RawFtpsResult;
      try {
        r = JSON.parse(json) as RawFtpsResult;
      } catch (e) {
        PrintOptions.logSend(filesDir, `上传结果解析失败 原文=${json}`);
        res.reason = '原生返回内容无法解析';
        return Promise.resolve(res);
      }
      const sent: number = r.sentBytes !== undefined ? r.sentBytes : -1;
      PrintOptions.logUploadDetail(filesDir, json);
      if (r.ok !== true) {
        const code: string = r.code !== undefined ? `${r.code}` : '-';
        const msg: string = r.message !== undefined ? r.message : '';
        PrintOptions.logSend(filesDir,
          `上传结果 失败 落点=${remotePath} 返回码=${code} 说明=${msg}`);
        res.reason = `返回码=${code} ${msg}`;
        return Promise.resolve(res);
      }
      res.ok = true;
      PrintOptions.logSend(filesDir,
        `上传结果 成功 返回码=${r.code !== undefined ? r.code : '-'} ` +
        `远端=${r.remotePath !== undefined ? r.remotePath : '-'} 字节=${sent}`);
      // LIST 复核（**仅诊断**）：把该目录条目逐条落日志，便于核对本次文件名是否在列；
      // 无论结果如何都算成功（上传已 226 确认）——不让 LIST 失败阻塞正常打印。
      return MqttService.ftpsList(dir).then((ljson: string): DirTry => {
        let lr: RawFtpsList;
        try {
          lr = JSON.parse(ljson) as RawFtpsList;
        } catch (e) {
          PrintOptions.logSend(filesDir, `LIST 复核(诊断) ${dir} 结果解析失败 原文=${ljson}`);
          return res;
        }
        const entries: string[] = lr.entries !== undefined ? lr.entries : [];
        let hit: boolean = false;
        for (const e of entries) {
          if (e.indexOf(plan.fileName) >= 0) { hit = true; }
        }
        PrintOptions.logSend(filesDir,
          `LIST 复核(诊断) ${dir} ok=${lr.ok === true ? '是' : '否'} 返回码=${lr.code !== undefined ? lr.code : '-'} ` +
          `条目数=${entries.length} 本次文件名在列=${hit ? '是' : '否'} 说明=${lr.message !== undefined ? lr.message : ''}`);
        for (const e of entries) { PrintOptions.logSend(filesDir, `LIST 复核(诊断) ${dir}| ${e}`); }
        return res;   // 诊断结果不影响放行
      }).catch((e: Error): DirTry => {
        PrintOptions.logSend(filesDir, `LIST 复核(诊断) ${dir} 异常 ${e.message}（不阻塞打印）`);
        return res;
      });
    }).catch((e: Error): DirTry => {
      PrintOptions.logSend(filesDir, `上传异常 落点=${remotePath} ${e.message}`);
      res.reason = `上传异常 ${e.message}`;
      return res;
    });
  }

  // 把原生返回的交互日志逐条落 PrintSend 通道（FTPS 交互原文，作为上传证据）
  private static logUploadDetail(filesDir: string, json: string): void {
    try {
      const r: RawFtpsResult = JSON.parse(json) as RawFtpsResult;
      const lines: string[] = r.log !== undefined ? r.log : [];
      for (const ln of lines) {
        PrintOptions.logSend(filesDir, `FTPS| ${ln}`);
      }
    } catch (e) {
      hilog.error(DOMAIN, PRINT_SEND_TAG, 'FTPS 日志展开失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  // 实发计划日志：把完整 payload、上传计划、映射明细、字段来源一次性落三通道
  static logPlan(filesDir: string, plan: PrintTaskPlan): void {
    PrintOptions.logSend(filesDir,
      `打印请求(实发) 包=${plan.fileName} 含gcode=${plan.hasGcodePackage ? '是' : '否'} ` +
      `use_ams=${plan.useAms ? '1' : '0'} ams_mapping=[${plan.amsMapping.join(',')}] ` +
      `ams_mapping2=${PrintOptions.map2Json(plan.amsMapping2)} ` +
      `开关(延时=${plan.timelapse ? '1' : '0'} 调平=${plan.bedLeveling ? '1' : '0'} 流量=${plan.flowCali ? '1' : '0'}) ` +
      `结果=已发布`);
    PrintOptions.logSend(filesDir, `payload ${plan.payload}`);
    PrintOptions.logSend(filesDir,
      `机型判定=${plan.a1Series ? 'A1系' : '非A1系'} 打印机预设名=${plan.printerName !== '' ? plan.printerName : '(未知→保守按非A1)'} ` +
      `url形态=${PrintOptions.urlFormText(plan.a1Series)} 实发url=${plan.url}`);
    PrintOptions.logSend(filesDir,
      `上传名字段自检 file=${plan.fileName} url=${plan.url} 全ASCII=${PrintOptions.isAscii(plan.fileName) ? '是' : '否'} ` +
      `md5=${plan.md5}（md5 是本地待上传文件 ${plan.filePath} 的内容摘要，与 FTPS PUT 来源为同一文件）`);
    PrintOptions.logSend(filesDir, `上传计划 ${plan.uploadPlan}`);
    PrintOptions.logSend(filesDir,
      `AMS换算 依据=全局tray(ams_id*4+slot_id, DevicePanel.ets:765) 明细=${plan.mappingDetail} ` +
      `语义=A: ams_mapping[i]=第i个切片耗材槽位→全局tray; -1=不走AMS; 外部料盘在ams_mapping2={254|255,0}; {255,255}=未映射`);
    // 逐字段依据来源（A=外部权威来源；B=本机上报；仓库=行号）
    PrintOptions.logSend(filesDir,
      '字段来源 command/sequence_id/param/url/file/md5/bed_type/subtask_name/use_ams/ams_mapping/' +
      'ams_mapping2/bed_leveling/flow_cali/timelapse/layer_inspect/vibration_cali/profile_id/project_id/' +
      'subtask_id/task_id/cfg/auto_bed_leveling/extrude_cali_flag/extrude_cali_manual_mode/nozzle_offset_cali' +
      '=A(synman/bambu-printer-manager bambucommands.py:168-190 模板 + maziggy/bambuddy 真实抓包 + OpenBambuAPI mqtt.md)');
    PrintOptions.logSend(filesDir,
      '字段依据(仓库) 信封={"print":{...}}(DevicePanel.ets:728) param格式(bbs_3mf.hpp:25) ' +
      '开关key(bed_leveling/flow_cali/timelapse, AppConfig.cpp:472/475/478)');
    PrintOptions.logSend(filesDir,
      '字段依据(B 本机上报 z5.json) print段 key 含 mapping、不含 ams_mapping/ams_mapping2 ' +
      '→ 请求用 ams_mapping(+ams_mapping2)，上报的 mapping 是另一字段，不可互用');
    PrintOptions.logSend(filesDir,
      '勘误 plate_idx=不存在(A 三来源均无；盘号只体现在 param=Metadata/plate_<N>.gcode)；' +
      '单来源(真实抓包)字段 cfg/auto_bed_leveling/extrude_cali_flag/extrude_cali_manual_mode/nozzle_offset_cali 取值取自 bambuddy');
    PrintOptions.logSend(filesDir, plan.gapNote);
  }

  // 执行完整链路：**先探测+上传**（用计划里的真实路径）→ 上传成功才发 MQTT；
  // 上传失败一律不发送（避免打印机去取一个不存在的 url）。LIST 复核仅作诊断（不阻塞）。仍需 ALLOW_LIVE_PRINT 闸门。
  static execute(filesDir: string, plan: PrintTaskPlan): Promise<string> {
    if (!ALLOW_LIVE_PRINT) {
      PrintOptions.logSend(filesDir,
        `实发被安全闸门拦截(ALLOW_LIVE_PRINT=false) 未发送 文件=${plan.fileName}（红线：怕撞机）`);
      return Promise.resolve('实发被安全闸门拦截（ALLOW_LIVE_PRINT=false），未发送');
    }
    return PrintOptions.uploadPrintFile(filesDir, plan).then((up: UploadOutcome): Promise<string> => {
      if (!up.ok) {
        PrintOptions.logSend(filesDir,
          `上传未成功，已取消发送 MQTT（避免打印机去取不存在的 url）：${up.message}`);
        return Promise.resolve(up.message);
      }
      // 落点已确认（plan.url / plan.payload 均按真实落点定稿）→ 再落完整计划日志并实发
      PrintOptions.logPlan(filesDir, plan);
      return MqttService.sendCommand(plan.payload).then((res: string): string => {
        PrintOptions.logSend(filesDir, `实发返回 ${res}（落点=${up.landed}）`);
        return `已发送 project_file：${res}`;
      }).catch((e: Error): string => {
        PrintOptions.logSend(filesDir, `实发异常 ${e.message}`);
        return `实发异常：${e.message}`;
      });
    });
  }

  // PrintSend 三通道日志：hilog + 应用内日志 + files/diag/gcode_diag.txt
  static logSend(filesDir: string, text: string): void {
    hilog.info(DOMAIN, PRINT_SEND_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${PRINT_SEND_TAG}] ${text}`);
      if (filesDir.length > 0) {
        if (!AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`, [`[${PRINT_SEND_TAG}] ${text}`])) {
          hilog.warn(DOMAIN, PRINT_SEND_TAG, '打印发送日志落盘失败');
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, PRINT_SEND_TAG, '打印发送日志写入异常: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
  }
}
