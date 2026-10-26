// 数据类型与 Mock 数据（切片内核与 MQTT 未接好前，页面先用这些假数据跑通 UI）

export interface FilamentTray {
  index: number;
  colorHex: string;
  type: string;
  remaining: number; // 0-100
}

export interface AMSUnit {
  id: number;
  humidity: number; // 1-5 级
  temp: number;
  trays: FilamentTray[];
}

export interface Printer {
  serial: string;
  model: string;
  name: string;
  ip: string;
  online: boolean;
  state: string; // IDLE / PRINTING / PAUSED / OFFLINE
  nozzleTemp: number;
  targetNozzleTemp: number;
  bedTemp: number;
  targetBedTemp: number;
  chamberTemp: number;
  progress: number; // 0-100
  layer: number;
  totalLayers: number;
  remainingMinutes: number;
  speedLevel: number; // 1 静音 2 标准 3 运动 4 狂暴
  ams: AMSUnit[];
}

export interface SliceParams {
  layerHeight: number;   // mm
  infillDensity: number; // %
  wallLoops: number;
  nozzleTemp: number;    // °C
  bedTemp: number;       // °C
  printSpeed: number;    // mm/s
  supportsEnabled: boolean;
  brimEnabled: boolean;
}

// 切片内核返回结果（对应 C++ Slic3r::ohos::slicer_slice 的 JSON）
export interface SliceResult {
  ok: boolean;
  status: string;
  output?: string;            // 实际写出的 G-code 路径
  layers?: number;            // 层数
  timeSeconds?: number;       // 内核耗时（秒）
  filamentUsedMm?: number;    // 耗材长度 mm
  filamentUsedG?: number;     // 耗材重量 g
  estimatedPrintTime?: string; // 预计打印时长（如 "1h 2m 3s"）
  skippedParams?: string[];   // 未被采纳的界面参数（未知 key / 类型不匹配）
  message?: string;           // 失败原因
}

// 「项目 3MF」导出结果（内核 slicer_export_project_3mf 的返回 JSON 同构）。
// roundTrip = 导出后立刻用内核 BBL 3MF 加载器读回的实测数据（自证文件可被原样读回）。
export interface Project3mfRoundTrip {
  ok?: boolean;
  message?: string;
  objects?: number;
  facets?: number;
  isBbl3mf?: boolean;
  fileVersion?: string;
}

export interface Project3mfResult {
  ok?: boolean;
  message?: string;
  path?: string;              // 内核实际写出的 3MF 路径（沙箱）
  objects?: number;
  facets?: number;
  printer?: string;           // 写进 project_settings.config 的机型预设名
  process?: string;           // 工艺预设名
  filament?: string;          // 耗材预设名
  printerModel?: string;
  layerHeight?: number;
  skippedParams?: string[];   // 未被内核采纳的界面参数
  roundTrip?: Project3mfRoundTrip;
  // 含 gcode 的 .gcode.3mf 导出（slicer_export_gcode_3mf）额外回报的字段
  withGcode?: boolean;        // 本包是否含 Metadata/plate_1.gcode
  gcode?: string;             // 打进包的源 gcode 路径
  gcodeMd5?: string;          // 内核算出的 gcode md5（大写十六进制）
}

export interface ModelFile {
  id: number;
  name: string;
  format: string;
  sizeKB: number;
  triangles: number;
  importedAt: string;
  plate: number;     // 所属盘（1 起；0 = 未分盘）
  plateName: string;
}

// 多盘文件里的盘信息（右侧盘列表 / 左侧盘列表用）
export interface PlateMeta {
  index: number;   // 1 起
  name: string;
  count: number;   // 该盘的模型数
  firstId: number; // 该盘第一个模型 id（取缩略图）
  bed: string;     // 该盘床型（内核 curr_bed_type 名，如 "Cool Plate"；空 = 未知）
  objNames: string[]; // 该盘包含的对象名（左侧盘列表展示「每盘有哪些对象」）
}

// =============================================================================
// 3MF 导入（内核 slicer_import_3mf 返回）——几何走 ArrayBuffer，其余走 info JSON。
// 这里只描述 JSON 部分的形状（positions 单独作为 ArrayBuffer 传入）。
// =============================================================================

// 导入设置里的预设名（文件里 project_settings.config 的真实值，未翻译）
export interface ImportPresets {
  printer: string;
  process: string;
  filament: string;
  bed: string;      // 床型内核名，如 "Cool Plate"
}

// 热床尺寸（文件内 printable_area 存在时才有）
export interface ImportBed {
  minX: number;
  minY: number;
  w: number;
  h: number;
}

// 一个导入对象（对应一段顶点区间 positions[vertOffset, vertOffset+vertCount)）
export interface ImportObjectMeta {
  name: string;
  triangles: number;
  offset: number[];   // 摆放 [x,y,z]（盘面坐标 mm）
  bbox: number[];     // [minX,minY,minZ,maxX,maxY,maxZ]
  size: number[];     // [sx,sy,sz]
  vertOffset: number; // 在 positions 里的 float 起始下标
  vertCount: number;  // float 个数
  plate: number;      // 所属盘（1 起；0 = 未分盘）
  // 对象所用耗材/挤出机序号（1 基；来自 model_settings.config 的 extruder）。
  // 多色工程往返用：与 filamentColours 配合还原对象显示色。
  extruder?: number;
}

// 一个盘
export interface ImportPlateMeta {
  id: number;
  name: string;
  bed: string;
  objects: number[];  // objects 数组下标（该盘包含哪些对象）
}

// 内核导入返回的元数据（info JSON 的静态形态）
export interface Import3mfInfo {
  ok: boolean;
  hasModel: boolean;
  message: string;
  presets: ImportPresets;
  layerHeight: number;
  wallLoops: number;
  initialLayerSpeed: number;
  bed: ImportBed;
  settingKeys: string[];
  settingValues: number[];
  objects: ImportObjectMeta[];
  plates: ImportPlateMeta[];
  // 耗材槽位颜色列表（project_settings.config 的 filament_colour）—— 与对象 extruder 配合还原显示色
  filamentColours?: string[];
  filamentCount?: number;
}

// 导入后要「应用到界面 + 内核」的设置：预设名 + 需要逐项写回参数面板的键值。
// 通过 AppStorage 交给 DynamicParamsPanel 应用（面板是预设/参数的唯一所有者，
// 走它现成的「按名定位 → 按索引下发 → 内核校验 → 失败回滚」路径）。
export class Import3mfSettings {
  printer: string = '';
  process: string = '';
  filament: string = '';
  bed: string = '';
  keys: string[] = [];
  values: number[] = [];
  source: string = '';   // 来源文件短名（日志/提示用）
  // 是否已被参数面板应用过。面板可能被卸载/重挂载（窄屏切换、切页），
  // 用这个标记保证「同一份导入设置只下发一次」，不会在重挂载时覆盖用户后续编辑。
  applied: boolean = false;
}

// ---- Mock：可发现的局域网打印机 ----
export const MOCK_DISCOVERED_PRINTERS: Printer[] = [
  {
    serial: '000000000000001',
    model: 'X1 Carbon',
    name: 'X1C-客厅',
    ip: '192.168.1.101',
    online: true,
    state: 'PRINTING',
    nozzleTemp: 220,
    targetNozzleTemp: 220,
    bedTemp: 55,
    targetBedTemp: 55,
    chamberTemp: 38,
    progress: 67,
    layer: 165,
    totalLayers: 248,
    remainingMinutes: 84,
    speedLevel: 2,
    ams: [
      {
        id: 0,
        humidity: 2,
        temp: 26,
        trays: [
          { index: 0, colorHex: '#E53935', type: 'PLA', remaining: 82 },
          { index: 1, colorHex: '#1E88E5', type: 'PLA', remaining: 45 },
          { index: 2, colorHex: '#43A047', type: 'PETG', remaining: 100 },
          { index: 3, colorHex: '#FDD835', type: 'PLA', remaining: 8 },
        ],
      },
    ],
  },
  {
    serial: '000000000000002',
    model: 'P1S',
    name: 'P1S-书房',
    ip: '192.168.1.102',
    online: true,
    state: 'IDLE',
    nozzleTemp: 25,
    targetNozzleTemp: 0,
    bedTemp: 25,
    targetBedTemp: 0,
    chamberTemp: 25,
    progress: 0,
    layer: 0,
    totalLayers: 0,
    remainingMinutes: 0,
    speedLevel: 2,
    ams: [],
  },
];

// ---- Mock：当前打印监控的打印机 ----
export const MOCK_ACTIVE_PRINTER: Printer = MOCK_DISCOVERED_PRINTERS[0];

// ---- Mock：切片参数 ----
export const MOCK_SLICE_PARAMS: SliceParams = {
  layerHeight: 0.20,
  infillDensity: 15,
  wallLoops: 3,
  nozzleTemp: 220,
  bedTemp: 55,
  printSpeed: 100,
  supportsEnabled: false,
  brimEnabled: false,
};

// ---- 打印板尺寸（mm）----
export interface PlateSize {
  w: number;
  h: number;
}

// 打印机型号 → 打印板尺寸（按官方规格；未列出的默认 256×256）
export function plateSizeForPrinter(model: string): PlateSize {
  if (model.indexOf('A1 mini') >= 0) {
    return { w: 180, h: 180 };
  }
  if (model.indexOf('H2D') >= 0) {
    return { w: 350, h: 320 };
  }
  if (model.indexOf('H2S') >= 0) {
    return { w: 340, h: 320 };
  }
  return { w: 256, h: 256 };
}

// 当前生效的打印板尺寸（mm）。
// 为什么要有它：3MF 的 <item transform> 平移是「床绝对坐标」（盘中心 = 床宽高/2），导出必须把
// 盘中心加回去；多盘 3MF 导入也必须把各盘对象搬回「我们这块板」——两处都要用**同一块板**的尺寸。
// 取法（按可信度）：先取界面真正在用的 plateW/plateH（3D 视图取景与切片都按它），拿不到再按机型
// 官方规格 plateSizeForPrinter，最后兜底 256×256。非 256 床（A1 mini 180、H2D 350×320 等）必须算对，
// 否则 item 平移会整体偏移。
export function resolvePlateSize(printer: string): PlateSize {
  const w: number = AppStorage.get<number>('plateW') ?? 0;
  const h: number = AppStorage.get<number>('plateH') ?? 0;
  if (w > 0 && h > 0) {
    return { w: w, h: h };
  }
  if (printer.length > 0) {
    return plateSizeForPrinter(printer);
  }
  return { w: 256, h: 256 };
}
