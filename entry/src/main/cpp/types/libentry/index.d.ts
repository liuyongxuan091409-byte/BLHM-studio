// Bambu Studio HM —— 切片内核 + 打印机通信 NAPI 接口类型声明
// 与 C++ napi_init.cpp 一一对应；异步接口通过回调返回 JSON 字符串。

// 切片参数（对应 ArkTS 侧 SliceParams，JSON 序列化传输）
export interface SliceParamsNapi {
  layerHeight: number;
  infillDensity: number;
  wallLoops: number;
  nozzleTemp: number;
  bedTemp: number;
  printSpeed: number;
  supportsEnabled: boolean;
  brimEnabled: boolean;
}

// 同步：示例加法
export const add: (a: number, b: number) => number;

// 同步：切片内核版本号
export const slicerGetVersion: () => string;

// 同步：初始化 rawfile 资源管理器（ArkTS 传 context.resourceManager）
export const initResourceManager: (resMgr: object) => void;

// 同步：返回全部切片参数 schema（元数据 + 值，JSON 字符串）
export const getSliceParamSchema: () => string;

// 异步：初始化切片预设（把 rawfile 里的 bambu_res.zip 交给内核解压 + 加载 BBL 官方预设）
// 回调 JSON: {ok, selected:{printer,process,filament}, printers:[], processes:[], filaments:[]} 或 {ok:false,message}
export const slicerInitPresets: (
  filesDir: string,
  callback: (resultJson: string) => void
) => void;

// 同步：切换预设（空串 = 保持当前值），返回 {ok, requested, selected:{...}, layerHeight}
// 失败：{ok:false, message, requested, selected, notFound:[...]}（非空请求名内核不可选中时）
export const slicerSelectPresets: (printer: string, process: string, filament: string) => string;

// 同步：枚举"可被选中"的预设候选表（kind: 0=printer / 1=process / 2=filament）。
// 返回 JSON: {ok, kind, printer, items:[{name, layerHeight, nozzle}], selectedIndex, selectedName, notes}
// kind 1/2 的 items 是当前打印机下内核判定兼容的子集；列表顺序 = 内核顺序，UI 直接用下标选择。
export const slicerPresetOptions: (kind: number) => string;

// 同步：按索引选择预设（kind 同上，index 为候选表下标）。
// 返回 JSON: {ok, kind, index, requestedName, requested, selected, rolledBack, rolledBackTo, layerHeight}
// 越界/非法输入 = no-op；回读不一致 = 回滚到切换前状态（ok:false, rolledBack:true）
export const slicerSelectPresetByIndex: (kind: number, index: number) => string;

// 同步：当前打印机预设的真实打印板。
// 返回 JSON: {ok, printer, area:[[x,y],...], height, bbox:[minX,minY,maxX,maxY]} 或 {ok:false, message}
export const slicerPrinterBed: () => string;

// 同步：用内核兼容性元数据（compatible_printers / compatible_printers_condition）查询
// 某台打印机真正兼容的工艺 / 耗材预设名。
// 返回 JSON: {ok, printer, processes:[], filaments:[], notes} 或 {ok:false, message}
export const slicerPresetsForPrinter: (printer: string) => string;

// 同步：当前预设合成出的配置快照（动态表单取初值用），JSON 字符串
export const slicerConfigSnapshot: () => string;

// 同步：当前被编辑的耗材预设的键值快照（含向量型，按数组返回），JSON 字符串
export const slicerFilamentSnapshot: () => string;

// 同步：枚举选项的内核权威取值表，JSON 字符串
export const slicerEnumValues: () => string;

// 同步：导出「项目 3MF」（含完整切片设置，内核 store_bbs_3mf 写文件）
export const slicerExportProject3mf: (
  inputPath: string,
  paramsJson: string,
  outputPath: string,
  callback: (resultJson: string) => void
) => void;

// 异步：导出「含 gcode 的 .gcode.3mf」（同一 store_bbs_3mf 链路 + gcodePath 指定的 gcode 作为
// Metadata/plate_1.gcode）。gcodePath 必须是已存在的 .gcode 文件。
// 回调 JSON 在项目导出结果基础上多出 withGcode/gcode/gcodeMd5。
export const slicerExportGcode3mf: (
  inputPath: string,
  paramsJson: string,
  outputPath: string,
  gcodePath: string,
  callback: (resultJson: string) => void
) => void;

// 3MF 导入结果回调对象（slicerImport3mf 用）
//   info      : 元数据 JSON —— {ok, hasModel, message, presets:{printer,process,filament,bed},
//               layerHeight, wallLoops, initialLayerSpeed, bed:{minX,minY,w,h},
//               settingKeys:[], settingValues:[],
//               objects:[{name,triangles,offset,bbox,size,vertOffset,vertCount,plate}],
//               plates:[{id,name,bed,objects}]}
//   positions : Float32 三角汤顶点（Z 轴向上），第 i 个对象占 [vertOffset, +vertCount)
export interface Import3mfResult {
  info: string;
  positions: ArrayBuffer;
}

// 异步：导入 3MF（复用内核 BBL 加载器：几何 + 设置 + 盘一次拿全）。
// 几何走 ArrayBuffer（大模型不塞 JSON），元数据走 info JSON。
export const slicerImport3mf: (
  path: string,
  callback: (result: Import3mfResult) => void
) => void;

// 对象级布尔（同步）：A/B 为索引网格。
//   op: "union" | "difference" | "intersection"
//   result JSON: {ok,triangles,vertices,parts,message}
//   positions/indices: 结果几何（失败时长度 1 的占位缓冲，按 result.ok 判断是否可用）
export interface MeshBooleanResult {
  result: string;
  positions: ArrayBuffer;
  indices: ArrayBuffer;
}
export const slicerMeshBoolean: (
  aPositions: ArrayBuffer,
  aIndices: ArrayBuffer,
  bPositions: ArrayBuffer,
  bIndices: ArrayBuffer,
  op: string
) => MeshBooleanResult;

// 异步：切片（inputPath 模型，paramsJson 参数，outputPath 输出）
export const slicerSlice: (
  inputPath: string,
  paramsJson: string,
  outputPath: string,
  callback: (resultJson: string) => void
) => void;

// 异步：带进度的切片。语义与 slicerSlice 完全一致，额外上报真实进度。
//   onProgress: 进度 JSON {"stage":0..4,"pct":0..100,"msg":"..."}
//               stage 0=装载模型 1=贴板居中 2=合并配置 3=分层与路径 4=导出 G-code
//               （5=生成预览由 ArkTS 侧驱动）
//               进度由 C++ worker 经 napi_threadsafe_function 转发到 JS 主线程（每条一次）
//   onDone    : 切片结果 JSON（与 slicerSlice 的 callback 同构）；成功或失败都一定会被调用一次
export const slicerSliceWithProgress: (
  inputPath: string,
  paramsJson: string,
  outputPath: string,
  onProgress: (progressJson: string) => void,
  onDone: (resultJson: string) => void
) => void;

// 异步：局域网发现打印机，回调打印机列表 JSON
export const mqttDiscover: (callback: (printersJson: string) => void) => void;

// 异步：连接打印机（ip + accessCode + serial）
export const mqttConnect: (
  ip: string,
  accessCode: string,
  serial: string,
  callback: (resultJson: string) => void
) => void;

// 同步：断开连接
export const mqttDisconnect: () => void;

// 同步：返回 MQTT 运行日志（JSON 字符串数组）
export const mqttGetLogs: () => string;

// 异步：读取打印状态，回调状态 JSON
export const mqttGetStatus: (callback: (statusJson: string) => void) => void;

// 同步：增量字段合并单元自测（喂缺字段 JSON 给真实 applyReport，返回逐条 PASS/FAIL 文本）
export const mqttSelfTestMerge: () => string;

// 异步：下发指令，commandJson 为指令 JSON
export const mqttSendCommand: (
  commandJson: string,
  callback: (resultJson: string) => void
) => void;

// 异步：FTPS 上传（隐式 FTPS 990，把本地文件 PUT 到打印机）。**只上传，不触发打印**。
// ip + 访问码取自当前 MQTT 会话（不经过 JS 层）。
// remotePath 以 '/' 开头 = 完整远端路径（如 "/sdcard/x.3mf"，用于落点回退）；
// 否则视作裸文件名，内部拼成 "/cache/<name>"（保持既有 /cache 口径向后兼容）。
// 回调 JSON: {ok, code, message, remotePath, sentBytes, log:[]}
export const ftpsUpload: (
  localPath: string,
  remotePath: string,
  callback: (resultJson: string) => void
) => void;

// 异步：FTPS 列目录（隐式 FTPS 990，只读）。列打印机某目录（如 "/cache"）的目录项。
// ip + 访问码取自当前 MQTT 会话（不经过 JS 层）。**只读，不上传、不打印**。
// 回调 JSON: {ok, code, message, dir, entries: string[], log: []}
export const ftpsList: (
  dir: string,
  callback: (resultJson: string) => void
) => void;

// 异步：FTPS 删除打印机上的一个文件（DELE，只删文件不删目录）。
// remotePath 允许 "cache/x.3mf" 或 "/cache/x.3mf"。
// 回调 JSON: {ok, code, message, remotePath, log: []}
export const ftpsRemove: (
  remotePath: string,
  callback: (resultJson: string) => void
) => void;

// 异步：FTPS 下载打印机上的一个文件到本地（RETR + TYPE I，边读边落盘）。
// maxBytes > 0 时超过即中止（服务端半截文件会被删掉），回调 ok=false、code="TOOBIG"。
// 回调 JSON: {ok, code, message, remotePath, localPath, bytes, log: []}
export const ftpsDownload: (
  remotePath: string,
  localPath: string,
  maxBytes: number,
  callback: (resultJson: string) => void
) => void;

// 摄像头帧。format='rgba'（默认）：data 为 width*height*4 字节 RGBA；
//             format='jpeg'：data 为完整 JPEG（6000 通道），交由系统 image 模块解码。
// seq 为帧序号，ArkTS 用它去重。
export interface CameraFrame {
  width: number;
  height: number;
  seq: number;
  format?: string;
  data: ArrayBuffer;
}

// 同步：启动摄像头拉流（按机型选择端口）
//   model      = SSDP 友好机型名（可空，空则用 serial 前缀兜底）
//   serial     = 打印机序列号
//   forceProto = 0 自动 / 1 强制 322(RTSPS) / 2 强制 6000(chamber image)
export const cameraStart: (
  ip: string,
  accessCode: string,
  model: string,
  serial: string,
  forceProto: number
) => boolean;

// 同步：查询机型/序列号 → 端口候选顺序描述（不发起连接，供日志/自检）
export const cameraResolveProtocol: (model: string, serial: string) => string;

// 同步：停止摄像头拉流
export const cameraStop: () => void;

// 同步：获取最新一帧（无帧时返回 null）
export const cameraGetFrame: () => CameraFrame | null;

// 模型加载结果（rendererLoadModel 回调 JSON）
export interface ModelLoadResult {
  ok: boolean;
  error?: string;
  triangles: number;
  sizeX: number;
  sizeY: number;
  sizeZ: number;
}

// 同步：注册 XComponent 表面回调（XComponent onLoad 时调用）
export const rendererAttach: () => boolean;

// 异步：加载 STL/OBJ 模型（worker 解析 → JS 线程上传 GPU + 自动取景）
export const rendererLoadModel: (
  path: string,
  callback: (resultJson: string) => void
) => void;

// 网格解析结果回调对象（meshParse / meshParseWithProgress 用；positions/normals 为 Float32 唯一顶点数组，Z 轴向上已居中贴板）
export interface MeshParseResult {
  // JSON: {ok, triangles, sizeX, sizeY, sizeZ, origTriangles, weldInVerts, uniqueVerts, creaseSplit, outVerts,
  //        overhangRatioPct, overhangAngleDeg, overhangAreaPctThreshold, needsSupport}
  // 或 {ok:false, error}
  // overhang*/needsSupport = 原生侧「悬空（朝下）面」启发式统计（真实数字，不是切片器级别的精确悬空分析）
  info: string;
  positions: ArrayBuffer;
  normals: ArrayBuffer;
  /** 唯一顶点索引，Uint32，每 3 个 = 一个三角面 */
  indices: ArrayBuffer;
}

// 异步：纯网格解析（3D 预览页用，C++ 不做渲染；STL/OBJ/STEP 按扩展名分发）
export const meshParse: (
  path: string,
  callback: (result: MeshParseResult) => void
) => void;

// 载入进度回调：progressJson = {"stage":0..4,"pct":0..100,"msg":"..."}
//   stage 0=解析文件 1=顶点焊接 2=法线重建 3=上传几何 4=生成缩略图
//   进度由 C++ worker 线程经 napi_threadsafe_function 转发到 JS 主线程（每条进度一次）
// 异步：带分阶段进度的网格解析；结果与 meshParse 完全同构。
// onDone 一定会被调用（成功或失败），失败时 info 里 ok=false + error。
export const meshParseWithProgress: (
  path: string,
  onProgress: (progressJson: string) => void,
  onDone: (result: MeshParseResult) => void
) => void;

// 内置托盘网格结果（bedMesh 同步返回；positions/normals 为 Float32 平面数组，Z 轴向上已居中）
export interface BedMeshResult {
  positions: ArrayBuffer;
  normals: ArrayBuffer;
  triangles: number;
}

// 同步：返回内置开源托盘模型（bbl-3dp-X1.stl）网格数据
export const bedMesh: () => BedMeshResult;

// 按机型返回对应的开源打印板网格（bedModel 取自 BBL 预设的 bed_model 字段，如 "bbl-3dp-H2D.stl"）
// ok=false 表示该机型暂无对应板模型；width/height 为板模型自身包围盒尺寸（mm），用于缩放。
// bboxMinX/MinY/MaxX/MaxY 为板模型在【绝对床坐标】里的包围盒（mm），用于把绝对床坐标
// （extruder_printable_area 等）映射到与板模型完全相同的坐标系。
export interface BedMeshModelResult {
  ok: boolean;
  positions: ArrayBuffer;
  normals: ArrayBuffer;
  triangles: number;
  width: number;
  height: number;
  bboxMinX: number;
  bboxMinY: number;
  bboxMaxX: number;
  bboxMaxY: number;
}

export const bedMeshForModel: (bedModel: string) => BedMeshModelResult;

// 内置 logo 网格结果（logoMesh 同步返回；两组均为 Float32 平面数组，Z 轴向上已居中）
export interface LogoMeshResult {
  lightPositions: ArrayBuffer;
  lightTriangles: number;
  darkPositions: ArrayBuffer;
  darkTriangles: number;
}

// 同步：返回内置开源 logo（bbl-3dp-logo.svg）网格数据
export const logoMesh: () => LogoMeshResult;

// 同步：轨道相机控制（单指旋转）
export const rendererRotate: (dx: number, dy: number) => void;

// 同步：缩放（factor>1 放大，双指捏合增量比例）
export const rendererZoom: (factor: number) => void;

// 同步：平移（双指拖动增量）
export const rendererPan: (dx: number, dy: number) => void;

// 同步：重置视角（按模型自动取景）
export const rendererResetView: () => void;

// 同步：切片路径（3D 预览）
//   verts  : Float32Array，[x,y,z] 顶点序列，世界坐标 mm（床角原点）
//   batches: Int32Array，三元组 {调色板下标, first, count}，顶点按颜色分组连续排布
//            调色板下标 0 = 下层鬼影灰，1..10 = 路径类型（与 ArkTS 端 ROLE_COLOR 一致）
export const rendererSetGcode: (verts: Float32Array, batches: Int32Array) => void;

// 同步：切换切片预览模式（true 时隐藏模型实体，只画网格 + 路径）
export const rendererSetGcodeMode: (on: boolean) => void;

// 同步：清除切片路径（退回模型显示）
export const rendererClearGcode: () => void;
