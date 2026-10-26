// 切片参数 schema 项（与 C++ getSliceParamSchema 返回的 JSON 对齐）
export class SliceParam {
  key: string = '';
  label: string = '';
  type: number = 0;   // 0=浮点 1=整数 2=百分比 3=布尔 4=枚举
  unit: string = '';
  min: number = 0;
  max: number = 100;
  group: string = '';
  subgroup: string = '';
  mode: number = 0;
  tooltip: string = '';
  options: string[] = [];
  // 枚举项对应的内核实名（与 options 等长）；内核按这份名字解析，所以下标不会错位
  values: string[] = [];
  value: number = 0;
  // 来源：'' 或 'manual' = 我们手写的中文元信息表；'kernel' = 内核 PrintConfigDef 兜底带出来的。
  // 用途：内核兜底项的 label/tooltip/分组是英文，界面需按它决定要不要过官方译法（见 ParamZhMap）。
  src: string = '';
}

// 当前选中的预设（全名，如 "Bambu Lab X1 Carbon 0.4 nozzle"）
export class PresetSelection {
  printer: string = '';
  process: string = '';
  filament: string = '';
}

// 预设目录（C++ slicerInitPresets 返回的 JSON）
export class PresetCatalog {
  ok: boolean = false;
  message: string = '';
  selected: PresetSelection = new PresetSelection();
  printers: string[] = [];
  processes: string[] = [];
  filaments: string[] = [];
}

// 切换预设的结果（C++ slicerSelectPresets 返回的 JSON）
export class PresetSelectResult {
  ok: boolean = false;
  message: string = '';
  // 请求下发的名字（用户点的那一行/当前下拉）
  requested: PresetSelection = new PresetSelection();
  // 内核当前真实选中的名字；ok=false 时它就是"内核保持不动/已回滚"的结果，界面据此回到一致状态
  selected: PresetSelection = new PresetSelection();
  // 内核不可选中的请求名（ok=false 时非空），用于日志说明是哪一项没被认下
  notFound: string[] = [];
  // 内核回读的层高，用于「点击行 ↔ 请求名 ↔ 内核选中 ↔ 回读层高 ↔ 结果」对照日志
  layerHeight: number = -1;
  // 是否发生了失败回滚：true 表示内核没认下请求的预设，已把内核+界面恢复到切换前的预设
  rolledBack: boolean = false;
  // 回滚到的预设（rolledBack=true 时有效，与 selected 一致）
  rolledBackTo: PresetSelection = new PresetSelection();
}

// 当前打印机预设的真实打印板（C++ slicerPrinterBed 返回的 JSON）
export class PrinterBed {
  ok: boolean = false;
  message: string = '';
  printer: string = '';
  // 完整多边形点列表 [[x,y],...]（不是首元素）
  area: number[][] = [];
  // 可打印高度 mm
  height: number = 0;
  // 包围盒 [minX, minY, maxX, maxY]
  bbox: number[] = [];
  // 机型标识（预设 printer_model）
  printerModel: string = '';
  // 该机型的开源打印板模型名（预设 bed_model，如 "bbl-3dp-H2D.stl"）；空 = 未知
  bedModel: string = '';
  // 板模型解析逐跳诊断（厂商是否挂上 / 厂商模型表条数 / 命中的模型 id / 命中来源）
  bedVendorId: string = '';
  bedModelsCount: number = -1;
  bedModelId: string = '';
  bedModelSrc: string = '';
  // 多挤出机机型的「每个喷嘴可达打印区」多边形列表（extruder_printable_area 真值）；空 = 单喷嘴机型
  extruderAreas: number[][][] = [];
  // extruderAreas 的条数（-1 = 未下发；用于日志逐跳核对）
  extruderAreaCount: number = -1;
  // 每个喷嘴的可打印高度（extruder_printable_height；可能为 nan/空）
  extruderHeights: number[] = [];
}

// 某台打印机真正兼容的工艺/耗材预设（C++ slicerPresetsForPrinter 返回的 JSON）。
// 列表来自内核兼容性元数据判断，不是 UI 按名字后缀猜的。
export class PresetCompat {
  ok: boolean = false;
  message: string = '';
  printer: string = '';
  processes: string[] = [];
  filaments: string[] = [];
  notes: string = '';
}

// 内核给出的"可被选中"候选项（C++ slicerPresetOptions 返回的 items 元素）。
// name 只用于展示；选择时回传的是它在列表里的下标，name 不参与选择。
export class PresetOptionItem {
  name: string = '';
  // 只读展示信息；内核该预设里没有这个选项时为 -1
  layerHeight: number = -1;
  nozzle: number = -1;
}

// 内核权威候选表（C++ slicerPresetOptions 返回的 JSON）。
// items 的顺序 = 内核集合顺序，界面必须原样使用：回传的 index 就是这里的下标。
export class PresetOptions {
  ok: boolean = false;
  message: string = '';
  kind: number = -1;
  // kind 1/2 时是内核当前选中的打印机（= 这份兼容候选列表所属的机器）
  printer: string = '';
  items: PresetOptionItem[] = [];
  // 内核当前选中项在 items 里的下标；-1 表示当前选中项不在候选表内
  selectedIndex: number = -1;
  selectedName: string = '';
  notes: string = '';
}

// 按索引选择预设的结果（C++ slicerSelectPresetByIndex 返回的 JSON）。
// 字段含义与 PresetSelectResult 一致，只是请求方从"名字"换成了"下标"。
export class PresetIndexSelectResult {
  ok: boolean = false;
  message: string = '';
  kind: number = -1;
  index: number = -1;
  // 该下标在内核候选表里对应的预设名（仅用于日志对照）
  requestedName: string = '';
  selected: PresetSelection = new PresetSelection();
  layerHeight: number = -1;
  rolledBack: boolean = false;
  rolledBackTo: PresetSelection = new PresetSelection();
}

// 内核 config 快照（C++ slicerConfigSnapshot 返回的 JSON）的取值容器：key -> 值。
//
// 同一项在快照里可能是 JSON number / boolean / string（布尔项发 bool、枚举项发内核下标、
// 字符串项发字符串、向量型选项发数组首元素），所以按类型分开存，
// 这样回填时三种形态都能认出来，不会因为漏认某一种而静默失败。
export class ConfigSnapshot {
  numbers: Map<string, number> = new Map<string, number>();
  booleans: Map<string, number> = new Map<string, number>();
  texts: Map<string, string> = new Map<string, string>();

  static parse(json: string): ConfigSnapshot {
    const out: ConfigSnapshot = new ConfigSnapshot();
    const raw: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    const keys: string[] = Object.keys(raw);
    for (const k of keys) {
      const v: Object = raw[k];
      if (typeof v === 'number') {
        out.numbers.set(k, v as number);
      } else if (typeof v === 'boolean') {
        out.booleans.set(k, (v as boolean) ? 1 : 0);
      } else if (typeof v === 'string') {
        out.texts.set(k, v as string);
      }
    }
    return out;
  }
}
