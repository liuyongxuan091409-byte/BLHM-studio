import testNapi from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SliceParams } from '../model/Models';
import { PresetCatalog } from '../model/SliceModels';
import { MeshGeometry, meshTriCount } from '../model/MeshUtils';
import { MeshOps } from '../model/MeshOps';

// 3MF 导入回调对象（与 cpp/types/libentry/index.d.ts 的 Import3mfResult 同构）。
// 这里本地声明一份，避免 ArkTS 从 .so 模块做类型具名导入。
interface Import3mfNapiResult {
  info: string;
  positions: ArrayBuffer;
}

// 布尔运算（slicerMeshBoolean）的 NAPI 返回与结果元数据
interface MeshBooleanNapiResult {
  result: string;
  positions: ArrayBuffer;
  indices: ArrayBuffer;
}
interface MeshBooleanMeta {
  ok: boolean;
  triangles?: number;
  vertices?: number;
  parts?: number;
  message?: string;
}

// 布尔结果（几何已按内核回报的长度切好）
export class MeshBooleanOut {
  ok: boolean = false;
  message: string = '';
  triangles: number = 0;
  vertices: number = 0;
  positions: Float32Array = new Float32Array(0);
  indices: Uint32Array = new Uint32Array(0);
}

// 看门狗超时：15 秒内没有拿到终态就判失败。界面会显示"预设加载失败 + 原因 + 重试"，
// 从此不允许出现"既不 ready 也不 failed"的无声无限加载。
const PRESET_TIMEOUT_MS: number = 15000;

// 预设状态监听回调：(state, err) -> void。
// state 取 SlicerService.STATE_* 三态之一，err 仅 failed 时非空。
export type PresetStateListener = (state: string, err: string) => void;

// 切片服务：封装 NAPI（预设 / schema / 切片 / 资源管理器）
//
// 预设初始化（解 bambu_res.zip + 加载 2538 项官方 profile）在 EntryAbility.onCreate 里
// 就发起，属于「应用启动预热」。为了不让「准备」页在预热完成前用内核默认值渲染出
// 退化表单，这里把状态发布出去；界面通过**显式订阅**（subscribePresetState）接收通知并刷新，
// 不再用 @StorageLink + @Watch（AppStorage 值同步不是事件通知，实测会漏掉已挂载组件的更新）。
//
// 状态用三态字符串（loading / ready / failed），不用单个 boolean：
//   * boolean 只有"就绪/未就绪"两义，表达不了"失败"，上一轮界面因此出现了
//     "既不是 ready 也不是 failed"的第三态 —— 表现就是四个下拉永久停在「加载中…」；
//   * 这里同时保证：成功、失败、异常、超时四条路径**都**会写一个终态（ready/failed），
//     并且服务内部状态（stateCode）、AppStorage、监听者回调在同一个函数里一起更新，
//     杜绝"服务认为已就绪、界面读到的却还是 loading"这类不一致。
export class SlicerService {
  // 三态常量（互斥且穷尽）
  static readonly STATE_LOADING: string = 'loading';
  static readonly STATE_READY: string = 'ready';
  static readonly STATE_FAILED: string = 'failed';

  // 服务内部权威状态：界面只读它发布出去的那一份，不自己推导
  private static stateCode: string = 'loading';
  private static errorText: string = '';
  private static presetInfo: string = '';
  private static presetsPromise: Promise<boolean> | null = null;
  // 每次初始化尝试的序号：看门狗与原生回调都只认"自己那一次"，重试后旧回调直接作废
  private static attemptId: number = 0;
  private static watchdogId: number = -1;

  // ===== 显式订阅机制 =====
  //
  // 为什么不再依赖 @StorageLink + @Watch 通知界面：把"就绪"当 AppStorage 的**值**发布，
  // 靠 @StorageLink 双向同步 + @Watch 去"等值变化"，官方明确不建议拿 @StorageLink 做
  // 事件通知（值相同时不通知、组件回写又会制造双向依赖）。本工程里还叠加了组件内
  // syncStateFromService() 回写同一个变量，导致"停在页面上的组件收不到通知、重新挂载的
  // 组件在 aboutToAppear 直接读服务静态状态却正常"——这正是"必须切页再回来才好"的原因。
  // 所以改为服务侧维护监听者列表，状态一变就**主动逐个回调**，界面回调里直接刷新下拉与参数。
  private static listeners: Map<number, PresetStateListener> = new Map<number, PresetStateListener>();
  private static nextListenerToken: number = 1;

  // AppStorage 键名
  static readonly STATE_KEY: string = 'presetsState';   // loading/ready/failed（界面订阅这个）
  static readonly ERROR_KEY: string = 'presetsError';   // 失败原因（仅 failed 时非空）
  static readonly READY_KEY: string = 'presetsReady';   // 兼容旧读取方的 boolean（等价于 state==ready）

  static getVersion(): string {
    return testNapi.slicerGetVersion();
  }

  // 初始化 rawfile 资源管理器（供 C++ 读取预设包）
  static initResourceManager(resMgr: object): void {
    testNapi.initResourceManager(resMgr);
  }

  // 唯一的状态发布出口：内部状态、AppStorage、监听者回调在同一处一起更新，
  // 且先写原因再写状态，保证监听者读到的 error 一定与当前 state 配套。
  private static publish(state: string, err: string): void {
    SlicerService.stateCode = state;
    SlicerService.errorText = err;
    AppStorage.setOrCreate<string>(SlicerService.ERROR_KEY, err);
    AppStorage.setOrCreate<string>(SlicerService.STATE_KEY, state);
    AppStorage.setOrCreate<boolean>(SlicerService.READY_KEY, state === SlicerService.STATE_READY);
    hilog.info(0x0000, 'PresetInit', 'publishState state=%{public}s err=%{public}s 订阅者=%{public}d',
      state, err, SlicerService.listeners.size);
    // 发布后立刻主动逐个回调：不依赖 AppStorage/@Watch 这条不可靠的通知路径。
    SlicerService.notifyListeners();
  }

  // 订阅预设状态：注册后**立刻**用当前状态回调一次（订阅方无需再自己读一遍，也不会
  // 漏掉"订阅之前就已经到终态"的情况）。返回 token，用于取消订阅。
  static subscribePresetState(cb: PresetStateListener): number {
    const token: number = SlicerService.nextListenerToken;
    SlicerService.nextListenerToken = token + 1;
    SlicerService.listeners.set(token, cb);
    hilog.info(0x0000, 'PresetInit', '订阅预设状态 token=%{public}d（当前=%{public}s）',
      token, SlicerService.stateCode);
    try {
      cb(SlicerService.stateCode, SlicerService.errorText);
    } catch (e) {
      // 订阅瞬间的回调异常不能影响后续订阅者（不吞异常，留 hilog）
      hilog.error(0x0000, 'PresetInit', '订阅回调(初次)异常 token=%{public}d: %{public}s',
        token, e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    return token;
  }

  static unsubscribePresetState(token: number): void {
    if (SlicerService.listeners.delete(token)) {
      hilog.info(0x0000, 'PresetInit', '取消订阅预设状态 token=%{public}d（剩余=%{public}d）',
        token, SlicerService.listeners.size);
    }
  }

  // 重新广播当前状态（onPageShow / 页面重新可见时调用）：让仍挂载的组件自愈一次。
  static resyncPresetState(): void {
    hilog.info(0x0000, 'PresetInit', '重新广播预设状态 state=%{public}s（订阅者=%{public}d）',
      SlicerService.stateCode, SlicerService.listeners.size);
    SlicerService.notifyListeners();
  }

  // 逐个回调监听者；单个回调抛异常只记日志，不影响其余监听者与状态本身。
  private static notifyListeners(): void {
    SlicerService.listeners.forEach((cb: PresetStateListener, token: number) => {
      try {
        cb(SlicerService.stateCode, SlicerService.errorText);
      } catch (e) {
        hilog.error(0x0000, 'PresetInit', '预设状态回调异常 token=%{public}d: %{public}s',
          token, e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      }
    });
  }

  // 对外只读状态（界面/切片用）
  static getState(): string {
    return SlicerService.stateCode;
  }

  static getError(): string {
    return SlicerService.errorText;
  }

  static isPresetsReady(): boolean {
    return SlicerService.stateCode === SlicerService.STATE_READY;
  }

  // 外部（界面拿不到上下文时）把初始化判为失败：保证仍有终态，不留 loading
  static markFailed(reason: string): void {
    hilog.error(0x0000, 'PresetInit', '初始化判为失败（外部）：%{public}s', reason);
    SlicerService.clearWatchdog();
    SlicerService.publish(SlicerService.STATE_FAILED, reason);
  }

  private static clearWatchdog(): void {
    if (SlicerService.watchdogId !== -1) {
      clearTimeout(SlicerService.watchdogId);
      SlicerService.watchdogId = -1;
    }
  }

  // 看门狗：只负责把"超时"变成一个可见的失败终态（不 resolve promise）。
  // 若原生回调稍后真的成功，settle 会把状态从 failed 升级成 ready，界面自动恢复。
  private static startWatchdog(attempt: number): void {
    SlicerService.clearWatchdog();
    SlicerService.watchdogId = setTimeout(() => {
      SlicerService.watchdogId = -1;
      if (SlicerService.attemptId !== attempt) {
        return;
      }
      if (SlicerService.stateCode !== SlicerService.STATE_LOADING) {
        return;
      }
      const reason: string = `初始化超时（${PRESET_TIMEOUT_MS / 1000} 秒未完成）`;
      hilog.error(0x0000, 'PresetInit',
        '看门狗超时 %{public}dms，判定失败 attempt=%{public}d', PRESET_TIMEOUT_MS, attempt);
      SlicerService.publish(SlicerService.STATE_FAILED, reason);
    }, PRESET_TIMEOUT_MS);
  }

  // 初始化切片预设（BBL 官方 profile）。幂等：进行中重复调用等同一个 promise。
  static initPresets(filesDir: string): Promise<boolean> {
    if (SlicerService.stateCode === SlicerService.STATE_READY) {
      return Promise.resolve(true);
    }
    if (SlicerService.presetsPromise !== null) {
      return SlicerService.presetsPromise;
    }
    const attempt: number = SlicerService.attemptId + 1;
    SlicerService.attemptId = attempt;
    hilog.info(0x0000, 'PresetInit', 'initPresets 发起 attempt=%{public}d filesDir=%{public}s',
      attempt, filesDir);
    SlicerService.publish(SlicerService.STATE_LOADING, '');
    SlicerService.startWatchdog(attempt);

    SlicerService.presetsPromise = new Promise<boolean>((resolve: (v: boolean) => void) => {
      let done: boolean = false;
      // 终态收敛点：成功/失败/异常/超时四条路径最终都走到这里，
      // 保证 promise 一定被 resolve、状态一定被发布，绝不留悬空。
      const settle = (ok: boolean, err: string): void => {
        if (done) {
          return;
        }
        done = true;
        SlicerService.clearWatchdog();
        if (attempt !== SlicerService.attemptId) {
          // 用户已经点了重试、起了新的尝试：本次结果作废，但仍要解除等待者
          hilog.warn(0x0000, 'PresetInit', '丢弃过期 attempt=%{public}d 的结果 ok=%{public}s',
            attempt, ok ? 'true' : 'false');
          resolve(ok);
          return;
        }
        if (ok) {
          SlicerService.publish(SlicerService.STATE_READY, '');
        } else {
          SlicerService.publish(SlicerService.STATE_FAILED, err !== '' ? err : '未知原因');
        }
        hilog.info(0x0000, 'PresetInit', '预设初始化终态 attempt=%{public}d ok=%{public}s err=%{public}s',
          attempt, ok ? 'true' : 'false', err);
        resolve(ok);
      };

      try {
        testNapi.slicerInitPresets(filesDir, (resultJson: string) => {
          // 回调整体包 try/finally：解析、写 AppStorage 任何一步抛异常，
          // 也必须在 finally 里落一个终态 —— 这正是上一轮"永久加载中"的直接成因。
          let ok: boolean = false;
          let reason: string = '';
          try {
            SlicerService.presetInfo = resultJson;
            hilog.info(0x0000, 'PresetInit', '已写入 presetInfo(len=%{public}d)，随后发布终态',
              resultJson.length);
            const cat: PresetCatalog = JSON.parse(resultJson) as PresetCatalog;
            ok = cat.ok === true;
            if (ok) {
              hilog.info(0x0000, 'PresetInit',
                '预设目录: 机%{public}d/工艺%{public}d/耗材%{public}d 选中 机=%{public}s 工艺=%{public}s 耗材=%{public}s',
                cat.printers.length, cat.processes.length, cat.filaments.length,
                cat.selected.printer, cat.selected.process, cat.selected.filament);
            } else {
              reason = cat.message !== undefined && cat.message !== '' ? cat.message : '内核未返回 ok';
              hilog.error(0x0000, 'PresetInit', '内核返回失败: %{public}s', reason);
            }
          } catch (e) {
            reason = '初始化返回解析失败: '
              + (e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
            hilog.error(0x0000, 'PresetInit', '%{public}s', reason);
            ok = false;
          } finally {
            settle(ok, reason);
          }
        });
      } catch (e) {
        // NAPI 同步抛异常（例如 .so 未加载）：必须转成失败终态，不能让 promise 悬空
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.error(0x0000, 'PresetInit', 'slicerInitPresets 同步异常: %{public}s', msg);
        settle(false, '初始化调用异常: ' + msg);
      }
    });
    return SlicerService.presetsPromise;
  }

  // 等预设就绪（未初始化时先初始化）。永不 reject：调用方只需看 resolve 的值。
  static ensurePresets(filesDir: string): Promise<boolean> {
    return SlicerService.initPresets(filesDir);
  }

  // 重试：重置幂等状态后重新走一次初始化（复用同一套逻辑）。
  static retryPresets(filesDir: string): Promise<boolean> {
    hilog.info(0x0000, 'PresetInit', '用户重试：重置初始化状态，重新走一次');
    SlicerService.clearWatchdog();
    // 清掉旧 promise，让 initPresets 不再复用上一次（可能已超时/失败）的结果
    SlicerService.presetsPromise = null;
    return SlicerService.initPresets(filesDir);
  }

  // 预设目录（printers/processes/filaments + 当前选中）；未就绪时返回 undefined
  static getCatalog(): PresetCatalog | undefined {
    if (SlicerService.presetInfo === '') {
      return undefined;
    }
    try {
      return JSON.parse(SlicerService.presetInfo) as PresetCatalog;
    } catch (e) {
      hilog.error(0x0000, 'SliceParam', '预设目录解析失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return undefined;
    }
  }

  // 切换预设（空串 = 保持当前值）
  static selectPresets(printer: string, process: string, filament: string): string {
    return testNapi.slicerSelectPresets(printer, process, filament);
  }

  // 【机型校验修复】预设切换成功后把「当前选中」同步进内存目录。
  // 背景：presetInfo 只在初始化时写一次，之后内核换成 A1 mini 也不会更新 →
  // getCatalog().selected.printer 永远停在启动时冻结的机型（如 X1C），
  // 导致打印弹窗的「机型对照」误报「选择了 X1C…」，3MF 导出的机型预设也会用错。
  // 这里在每次「按索引切换/恢复」成功后用内核回读的选中名刷新它，令 getCatalog() 与内核同源同值。
  static updateSelected(printer: string, process: string, filament: string): void {
    const cat: PresetCatalog | undefined = SlicerService.getCatalog();
    if (cat === undefined) { return; }
    if (printer !== '') { cat.selected.printer = printer; }
    if (process !== '') { cat.selected.process = process; }
    if (filament !== '') { cat.selected.filament = filament; }
    SlicerService.presetInfo = JSON.stringify(cat);
    hilog.info(0x0000, 'PresetInit',
      '预设目录同步选中 机=%{public}s 工=%{public}s 耗=%{public}s',
      cat.selected.printer, cat.selected.process, cat.selected.filament);
  }

  // 内核权威候选表（kind: 0=printer / 1=process / 2=filament）。界面下拉直接用这份列表 + 下标。
  static presetOptions(kind: number): string {
    return testNapi.slicerPresetOptions(kind);
  }

  // 按候选表下标选择预设（不再传名字字符串，从根本上消除"名字对不上→内核静默回退"）
  static selectPresetByIndex(kind: number, index: number): string {
    return testNapi.slicerSelectPresetByIndex(kind, index);
  }

  // 用内核兼容性元数据查询某台打印机真正兼容的工艺/耗材预设（返回 JSON 字符串）
  static presetsForPrinter(printer: string): string {
    return testNapi.slicerPresetsForPrinter(printer);
  }

  // 当前打印机预设的真实打印板（完整多边形 + 高度 + 包围盒）
  static printerBed(): string {
    return testNapi.slicerPrinterBed();
  }

  // 当前预设合成出的配置快照
  static configSnapshot(): string {
    return testNapi.slicerConfigSnapshot();
  }

  // 当前被编辑的耗材预设的键值快照（含向量型，按数组返回）—— 耗材编辑弹窗取初值用
  static filamentSnapshot(): string {
    return testNapi.slicerFilamentSnapshot();
  }

  // 枚举选项的内核权威取值表
  static enumValues(): string {
    return testNapi.slicerEnumValues();
  }

  // 返回全部切片参数 schema（JSON 字符串）
  static getSliceParamSchema(): string {
    return testNapi.getSliceParamSchema();
  }

  static slice(inputPath: string, params: SliceParams, outputPath: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.slicerSlice(inputPath, JSON.stringify(params), outputPath, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // 用已打包的 paramsJson 直接切片（key->value 扁平 JSON，见 SliceParamStore.collectParamsJson）
  // 返回切片内核的结果 JSON（SliceResult）
  static sliceJson(inputPath: string, paramsJson: string, outputPath: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.slicerSlice(inputPath, paramsJson, outputPath, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // 导出「项目 3MF」（含完整切片设置）——由内核 store_bbs_3mf 写文件（拓竹原生工程格式）。
  // inputPath 通常是我们先落盘的「通用 3MF」临时文件；paramsJson 与切片同一份扁平参数。
  // onDone 在成功或失败时一定会被调用一次（结果 JSON 为 Project3mfResult）。
  static exportProject3mf(inputPath: string, paramsJson: string, outputPath: string,
                          onDone: (resultJson: string) => void): void {
    testNapi.slicerExportProject3mf(inputPath, paramsJson, outputPath, onDone);
  }

  // 导出「含 gcode 的 .gcode.3mf」：同一 store_bbs_3mf 链路，额外把 gcodePath 指定的已切 gcode
  // 作为 Metadata/plate_1.gcode 打进包。gcodePath 必须存在（否则内核侧直接返回 ok:false）。
  static exportGcode3mf(inputPath: string, paramsJson: string, outputPath: string, gcodePath: string,
                        onDone: (resultJson: string) => void): void {
    testNapi.slicerExportGcode3mf(inputPath, paramsJson, outputPath, gcodePath, onDone);
  }

  // 带真实进度的切片：onProgress 每条进度回调一次（{"stage","pct","msg"}），
  // onDone 在成功或失败时一定会被调用一次（结果 JSON 与 sliceJson 同构）。
  // 进度回调来自 C++ worker 线程经 napi_threadsafe_function 投递，必须在 JS 主线程上处理。
  static sliceJsonWithProgress(inputPath: string, paramsJson: string, outputPath: string,
                               onProgress: (progressJson: string) => void,
                               onDone: (resultJson: string) => void): void {
    testNapi.slicerSliceWithProgress(inputPath, paramsJson, outputPath, onProgress, onDone);
  }

  // 导入 3MF：内核 BBL 加载器一次拿全「几何 + 设置 + 盘」。
  // 几何以 ArrayBuffer 回来（不走 JSON），元数据在 result.info（JSON 字符串）。
  // onDone 成功或失败都只会被调用一次。
  static import3mf(path: string, onDone: (infoJson: string, positions: ArrayBuffer) => void): void {
    testNapi.slicerImport3mf(path, (res: Import3mfNapiResult) => {
      onDone(res.info, res.positions);
    });
  }

  // 对象级布尔（同步内核调用）：a 与 bLocal 必须已在同一坐标系（bLocal 由 MeshOps.bakeToBase 换算）。
  // op: "union" | "difference" | "intersection"
  static meshBoolean(a: MeshGeometry, bLocal: MeshGeometry, op: string): MeshBooleanOut {
    const out: MeshBooleanOut = new MeshBooleanOut();
    const ia = MeshOps.toIndexed(a);
    const ib = MeshOps.toIndexed(bLocal);
    hilog.info(0x0000, 'MeshOps',
      '布尔输入 a(pos=%{public}d idx=%{public}d tri=%{public}d) b(pos=%{public}d idx=%{public}d tri=%{public}d)',
      ia.positions.length, ia.indices.length, meshTriCount(a),
      ib.positions.length, ib.indices.length, meshTriCount(bLocal));
    // 传 ArrayBuffer 而不是 TypedArray：本机 NAPI 的 napi_get_typedarray_info 回的长度是字节数，
    // 原生侧按 ArrayBuffer 的 byte_length 读，单位唯一（见 napi_init.cpp 的 read_f32/read_u32）。
    const r: MeshBooleanNapiResult =
      testNapi.slicerMeshBoolean(ia.positions.buffer, ia.indices.buffer,
        ib.positions.buffer, ib.indices.buffer, op);
    const m: MeshBooleanMeta = JSON.parse(r.result) as MeshBooleanMeta;
    out.ok = m.ok === true;
    out.message = m.message !== undefined ? m.message : '';
    out.triangles = m.triangles !== undefined ? m.triangles : 0;
    out.vertices = m.vertices !== undefined ? m.vertices : 0;
    if (out.ok && out.triangles > 0 && out.vertices > 0) {
      // 注意：vertices 是**顶点数**，positions 是 XYZ 扁平数组 → 元素数 = 顶点数 × 3。
      // 之前按 out.vertices 切，只取到 1/3 的坐标，网格退化成碎渣（Ark3D 抛
      // "Invalid geometry definition given"）。
      out.positions = new Float32Array(r.positions, 0, out.vertices * 3);
      out.indices = new Uint32Array(r.indices, 0, out.triangles * 3);
      // 结果自检：ArkGraphics3D 对 NaN/Inf 顶点或越界索引会抛
      // "Invalid geometry definition given"，必须在建节点前把可疑数据说清楚。
      let bad: number = 0;
      let lo: number = 1e30;
      let hi: number = -1e30;
      for (let i = 0; i < out.positions.length; i++) {
        const v: number = out.positions[i];
        if (!Number.isFinite(v)) {
          bad++;
        } else {
          if (v < lo) { lo = v; }
          if (v > hi) { hi = v; }
        }
      }
      let maxIdx: number = 0;
      for (let i = 0; i < out.indices.length; i++) {
        if (out.indices[i] > maxIdx) { maxIdx = out.indices[i]; }
      }
      hilog.info(0x0000, 'MeshOps',
        '布尔结果 v=' + out.vertices.toString() + ' t=' + out.triangles.toString() +
          ' 非有限=' + bad.toString() + ' 坐标范围=[' + lo.toFixed(2) + ',' + hi.toFixed(2) +
          '] maxIdx=' + maxIdx.toString());
    }
    return out;
  }
}
