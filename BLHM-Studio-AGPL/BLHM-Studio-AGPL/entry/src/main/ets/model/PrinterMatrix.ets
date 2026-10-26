/**
 * PrinterMatrix.ets —— 机型能力矩阵（纯数据 + 纯函数，无 import / 无 @ohos.* 依赖）
 *
 * 数据来源：桌面版 Bambu Studio 安装目录展开的机型能力表（windows 本机）
 *   来源路径：%APPDATA%\BambuStudio\printers\*.json
 *   抽取日期：2026-10-16
 *
 * 说明：
 *   - printers 目录下每个 <model_id>.json 对应一个机型（文件名即 model_id）。
 *   - 文件内容形如 { "<固件版本>": {机型对象} }，本表统一取第一个固件键 '00.00.00.00' 对应的机型对象。
 *   - 某字段在该机型中不存在时，用合理默认值（false / "" / 0 / []）兜底，
 *     并在对应条目处用「// 该机型未声明」标注。
 */

export interface PrinterCaps {
  displayName: string;
  printerType: string;
  printerSeries: string;
  printerArch: string;
  ftpFolder: string;
  supportTimelapse: boolean;
  supportChamber: boolean;
  supportChamberTempEdit: boolean;
  supportChamberFan: boolean;
  supportAuxFan: boolean;
  supportFlowCalibration: boolean;
  supportAutoFlowCalibration: boolean;
  supportExtrusionCali: boolean;
  supportBedLeveling: number;
  supportSendToSd: boolean;
  supportPrintWithoutSd: boolean;
  supportPrintAll: boolean;
  supportAmsExtMixPrint: boolean;
  supportAiMonitoring: boolean;
  supportFirstLayerInspect: boolean;
  supportLidarCalibration: boolean;
  supportMotorNoiseCali: boolean;
  supportAutoRecoveryStepLoss: boolean;
  supportWrappingDetection: boolean;
  bedTemperatureLimit: number;
  autoCaliNotSupportFilaments: string[];
  useAmsType: string;
  ipcamResolutionSupported: string[];
  ipcamLiveviewLocal: string;
  ipcamLiveviewRemote: string;
  nozzleTempRange: number[];
}

// X1 Carbon（BL-P001）
const X1_CARBON: PrinterCaps = {
  displayName: "Bambu Lab X1 Carbon", printerType: "3DPrinter-X1-Carbon",
  printerSeries: "series_x1", printerArch: "core_xy",
  ftpFolder: "", // 该机型未声明
  supportTimelapse: true, supportChamber: true,
  supportChamberTempEdit: false, supportChamberFan: true, supportAuxFan: true,
  supportFlowCalibration: true, supportAutoFlowCalibration: false, supportExtrusionCali: false,
  supportBedLeveling: 1, supportSendToSd: false, supportPrintWithoutSd: true,
  supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: false,
  supportFirstLayerInspect: true, supportLidarCalibration: true,
  supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: false,
  supportWrappingDetection: false,
  bedTemperatureLimit: 0, // 该机型未声明
  autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "generic",
  ipcamResolutionSupported: ["720p", "1080p"],
  ipcamLiveviewLocal: "", // 该机型未声明
  ipcamLiveviewRemote: "tutk",
  nozzleTempRange: [0, 300]
};

export const PRINTER_MATRIX: Record<string, PrinterCaps> = {
  // X1 Carbon（BL-P001）
  "BL-P001": X1_CARBON,
  // X1（BL-P002）
  "BL-P002": {
    displayName: "Bambu Lab X1", printerType: "3DPrinter-X1",
    printerSeries: "series_x1", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: false, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: false, supportExtrusionCali: false,
    supportBedLeveling: 1, supportSendToSd: false, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: false,
    supportFirstLayerInspect: true, supportLidarCalibration: true,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: false,
    supportWrappingDetection: false,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "generic",
    ipcamResolutionSupported: ["720p", "1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 300]
  },
  // P1P（C11）
  "C11": {
    displayName: "Bambu Lab P1P", printerType: "C11",
    printerSeries: "series_p1p", printerArch: "core_xy",
    ftpFolder: "sdcard/",
    supportTimelapse: true, supportChamber: false,
    supportChamberTempEdit: false, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: false, supportAutoFlowCalibration: false, supportExtrusionCali: true,
    supportBedLeveling: 1, supportSendToSd: false, supportPrintWithoutSd: false,
    supportPrintAll: false, supportAmsExtMixPrint: true, supportAiMonitoring: false,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 100,
    autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "generic",
    ipcamResolutionSupported: ["720p"],
    ipcamLiveviewLocal: "local",
    ipcamLiveviewRemote: "", // 该机型未声明
    nozzleTempRange: [0, 300]
  },
  // P1S（C12）
  "C12": {
    displayName: "Bambu Lab P1S", printerType: "C12",
    printerSeries: "series_p1p", printerArch: "core_xy",
    ftpFolder: "sdcard/",
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: false, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: false, supportAutoFlowCalibration: false, supportExtrusionCali: true,
    supportBedLeveling: 1, supportSendToSd: true, supportPrintWithoutSd: false,
    supportPrintAll: false, supportAmsExtMixPrint: true, supportAiMonitoring: false,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 100,
    autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "generic",
    ipcamResolutionSupported: ["720p"],
    ipcamLiveviewLocal: "local",
    ipcamLiveviewRemote: "", // 该机型未声明
    nozzleTempRange: [0, 300]
  },
  // X1E（C13）
  "C13": {
    displayName: "Bambu Lab X1E", printerType: "C13",
    printerSeries: "series_x1", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: false, supportExtrusionCali: false,
    supportBedLeveling: 1, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: true, supportLidarCalibration: true,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 110,
    autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "generic",
    ipcamResolutionSupported: ["720p", "1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 320]
  },
  // A1 mini（N1）
  "N1": {
    displayName: "Bambu Lab A1 mini", printerType: "N1",
    printerSeries: "series_n", printerArch: "i3",
    ftpFolder: "sdcard/",
    supportTimelapse: true, supportChamber: false,
    supportChamberTempEdit: false, supportChamberFan: false, supportAuxFan: false,
    supportFlowCalibration: true, supportAutoFlowCalibration: false, supportExtrusionCali: true,
    supportBedLeveling: 1, supportSendToSd: true, supportPrintWithoutSd: false,
    supportPrintAll: false, supportAmsExtMixPrint: true, supportAiMonitoring: false,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: true, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 80,
    autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "f1",
    ipcamResolutionSupported: ["720p"],
    ipcamLiveviewLocal: "local",
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 300]
  },
  // A1（N2S）
  "N2S": {
    displayName: "Bambu Lab A1", printerType: "N2S",
    printerSeries: "series_n", printerArch: "i3",
    ftpFolder: "sdcard/",
    supportTimelapse: true, supportChamber: false,
    supportChamberTempEdit: false, supportChamberFan: false, supportAuxFan: false,
    supportFlowCalibration: true, supportAutoFlowCalibration: false, supportExtrusionCali: true,
    supportBedLeveling: 1, supportSendToSd: true, supportPrintWithoutSd: false,
    supportPrintAll: false, supportAmsExtMixPrint: true, supportAiMonitoring: false,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: true, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 100,
    autoCaliNotSupportFilaments: ["GFU03", "GFU04"], useAmsType: "f1",
    ipcamResolutionSupported: ["720p"],
    ipcamLiveviewLocal: "local",
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 300]
  },
  // X2D（N6）
  "N6": {
    displayName: "Bambu Lab X2D", printerType: "N6",
    printerSeries: "series_x1", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 300]
  },
  // P2S（N7）
  "N7": {
    displayName: "Bambu Lab P2S", printerType: "N7",
    printerSeries: "series_x1", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: false, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: true,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 300]
  },
  // A2L（N9）
  "N9": {
    displayName: "Bambu Lab A2L", printerType: "N9",
    printerSeries: "series_n", printerArch: "i3",
    ftpFolder: "sdcard/",
    supportTimelapse: true, supportChamber: false,
    supportChamberTempEdit: false, supportChamberFan: false, supportAuxFan: false,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: true,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: false,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: false,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: true, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: false,
    bedTemperatureLimit: 80,
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["720p"],
    ipcamLiveviewLocal: "local",
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 300]
  },
  // H2C（O1C）
  "O1C": {
    displayName: "Bambu Lab H2C", printerType: "O1C",
    printerSeries: "series_o", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: true,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 350]
  },
  // H2C（O1C2，O1C 的换代型号，display_name 与 O1C 相同）
  "O1C2": {
    displayName: "Bambu Lab H2C", printerType: "O1C2",
    printerSeries: "series_o", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: true,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 350]
  },
  // H2D（O1D）
  "O1D": {
    displayName: "Bambu Lab H2D", printerType: "O1D",
    printerSeries: "series_o", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: true,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 350]
  },
  // H2D Pro（O1E）
  "O1E": {
    displayName: "Bambu Lab H2D Pro", printerType: "O1E",
    printerSeries: "series_o", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: true,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 350]
  },
  // H2S（O1S）
  "O1S": {
    displayName: "Bambu Lab H2S", printerType: "O1S",
    printerSeries: "series_o", printerArch: "core_xy",
    ftpFolder: "", // 该机型未声明
    supportTimelapse: true, supportChamber: true,
    supportChamberTempEdit: true, supportChamberFan: true, supportAuxFan: true,
    supportFlowCalibration: true, supportAutoFlowCalibration: true, supportExtrusionCali: false,
    supportBedLeveling: 2, supportSendToSd: true, supportPrintWithoutSd: true,
    supportPrintAll: true, supportAmsExtMixPrint: true, supportAiMonitoring: true,
    supportFirstLayerInspect: false, supportLidarCalibration: false,
    supportMotorNoiseCali: false, supportAutoRecoveryStepLoss: true,
    supportWrappingDetection: true,
    bedTemperatureLimit: 0, // 该机型未声明
    autoCaliNotSupportFilaments: [], // 该机型未声明
    useAmsType: "generic",
    ipcamResolutionSupported: ["1080p"],
    ipcamLiveviewLocal: "", // 该机型未声明
    ipcamLiveviewRemote: "tutk",
    nozzleTempRange: [0, 350]
  }
};

/**
 * 兜底能力：取 X1 Carbon（BL-P001）。
 * 选择理由：X1 Carbon 属 X1 旗舰系列，能力项覆盖最全（腔体/风扇/激光雷达/首层检测等均有声明），
 * 作为未知机型的保守默认最不容易出现「支持项被误判为不支持」。
 */
export const FALLBACK_CAPS: PrinterCaps = X1_CARBON;

// 机型识别串 → model_id 映射（键统一存小写，匹配时再去空格，故大小写/空格均不敏感）
// 顺序不影响结果：matchModelId 采用「最长命中」策略。
export const PRINTER_MODEL_ALIASES: Record<string, string> = {
  // X1 Carbon → BL-P001
  "3dprinter-x1-carbon": "BL-P001",
  "x1 carbon": "BL-P001",
  "x1carbon": "BL-P001",
  "x1c": "BL-P001",
  // X1E → C13
  "x1e": "C13",
  "c13": "C13",
  // X1 → BL-P002
  "3dprinter-x1": "BL-P002",
  "x1": "BL-P002",
  // P1P → C11
  "p1p": "C11",
  "c11": "C11",
  // P1S → C12
  "p1s": "C12",
  "c12": "C12",
  // A1 mini → N1
  "a1 mini": "N1",
  "a1mini": "N1",
  "n1": "N1",
  // A1 → N2S
  "a1": "N2S",
  "n2s": "N2S",
  // X2D → N6
  "x2d": "N6",
  "n6": "N6",
  // P2S → N7
  "p2s": "N7",
  "n7": "N7",
  // A2L → N9
  "a2l": "N9",
  "n9": "N9",
  // H2C（O1C / O1C2 同名，此处取基型 O1C）→ O1C
  "h2c": "O1C",
  "o1c2": "O1C2",
  "o1c": "O1C",
  // H2D Pro → O1E
  "h2d pro": "O1E",
  "h2dpro": "O1E",
  "o1e": "O1E",
  // H2D → O1D
  "h2d": "O1D",
  "o1d": "O1D",
  // H2S → O1S
  "h2s": "O1S",
  "o1s": "O1S"
};

/**
 * 按识别串匹配 model_id：去空格 + 转小写 + 包含匹配（取命中最长的识别串，避免 "x1" 抢先命中 "x1 carbon"）。
 * 无命中返回 ''。
 */
export function matchModelId(hint: string): string {
  const norm: string = hint.replace(/\s+/g, '').toLowerCase();
  if (norm === '') {
    return '';
  }
  let bestId: string = '';
  let bestLen: number = 0;
  const keys: string[] = Object.keys(PRINTER_MODEL_ALIASES);
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i].replace(/\s+/g, '').toLowerCase();
    if (key !== '' && key.length > bestLen && norm.includes(key)) {
      bestLen = key.length;
      bestId = PRINTER_MODEL_ALIASES[keys[i]];
    }
  }
  return bestId;
}

/** 命中则返回对应机型能力；未命中返回 FALLBACK_CAPS。 */
export function capsOf(hint: string): PrinterCaps {
  const id: string = matchModelId(hint);
  if (id === '') {
    return FALLBACK_CAPS;
  }
  return PRINTER_MATRIX[id];
}

/** 返回该机型的 FTP 上传目录（空串表示上传到 FTP 根目录）。 */
export function ftpFolderOf(hint: string): string {
  return capsOf(hint).ftpFolder;
}
