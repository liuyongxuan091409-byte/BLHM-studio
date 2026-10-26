import promptAction from '@ohos.promptAction';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme } from '../common/Theme';
import { PressGlow } from '../common/Glow';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { SlicerService } from '../service/SlicerService';
import { SliceParamStore } from '../service/SliceParamStore';
import { SliceParam, PresetOptionItem, PresetOptions, PresetIndexSelectResult, PresetSelection, ConfigSnapshot, PrinterBed } from '../model/SliceModels';
import { zhOf } from '../model/ParamZhMap';
import { PlateSize, plateSizeForPrinter, ModelFile, Import3mfSettings } from '../model/Models';
import { helpFor } from '../model/ParamHelp';
import { history } from '../model/History';
import { modelState, ModelInstance, DISPLAY_COLORS, DisplayColorOption } from '../model/ModelState';
import { AppLog } from '../service/AppLog';
import { PresetPersist, PresetSnapshot } from '../service/PresetPersist';
import { ThreeMfImport } from '../service/ThreeMfImport';
import { FilamentGrouping } from '../service/FilamentGrouping';
import { plateSetBed, plateBedName, bedOptionValues } from '../service/PlateActions';

// 分组（subgroup 面板）
class SubGroup {
  name: string = '';
  params: SliceParam[] = [];
}

// 对象级「工艺/打印机/耗材」覆盖（对象模式）：空串 = 未覆盖（回落全局预设）。
// 与 objectOverrides 同一套语义（按对象覆盖优先、否则回落全局），只是这几项是预设名而非数值键。
class ObjPresetSel {
  printer: string = '';
  process: string = '';
  filament: string = '';
}

// 「导入设置写回参数」的结果统计。
// 为什么要把两个数分开：原来日志只有「写回参数=N」，而 N 只数"真正改了值"的项，
// 于是「文件里 20 项里 15 项本来就与当前预设一致」看起来像"丢了 5 个值"。
// 现在分成「实际变更」与「已一致、无需变更」，一眼能看出是二者之和，不再误读。
class WriteBackStat {
  changed: number = 0; // 实际改动了值的项数（会触发橙色高亮）
  same: number = 0;    // 文件值与当前值本就一致、无需变更的项数
}

// 打印板类型由顶部「打印板」下拉承载，这个分组不进 tab 列表（避免同一项出现两次）
const PLATE_GROUP: string = '打印板';

// 内核兜底项的二级分组前缀（由 C++ BuildSchemaJson 打：'内核 · <原分类>'）。
// 它同时是「这一项来自内核兜底、需要中文化」的判定依据，必须与 C++ 侧字面量保持一致。
const KERNEL_SUBGROUP_PREFIX: string = '内核 · ';

// 预设还没就绪时的初始候选 / 初始化失败时的兜底显示名：就是内核里的真实预设名，不做翻译
const DEFAULT_PRINTER: string = 'Bambu Lab X1 Carbon 0.4 nozzle';
const DEFAULT_PROCESS: string = '0.20mm Standard @BBL X1C';
const DEFAULT_FILAMENT: string = 'Bambu PLA Basic @BBL X1C';

const LOG_TAG: string = 'SliceParam';

// 预设候选表（slicerPresetOptions）相关日志单独用一个 tag，方便按 tag 过滤定位
// 「换了机型但工艺/耗材候选没跟着换」这类问题。
const COMPAT_TAG: string = 'PresetCompat';

// 「参数被修改 -> 标橙」的日志 tag（应用内日志用）
const HILITE_TAG: string = 'ParamHighlight';

// 数值输入提交（Enter / 失焦）相关日志的 hilog tag（新增，不改动既有 tag）
const PARAM_INPUT_TAG: string = 'ParamInput';

// 浮点参数的"是否被改动"判定容差：内核快照与界面显示之间存在极小浮点误差，
// 用绝对容差比较可避免"明明没改却标橙"的假阳性（布尔 / 枚举不走容差，按相等判断）。
const NUM_EPS: number = 1e-6;

// 预设未就绪时下拉的占位文案（下拉禁用，提示用户在等初始化）
const LOADING_TEXT: string = '加载中…';

// ---- 参数搜索（Phase 4）--------------------------------------------------------
const SEARCH_TAG: string = 'ParamSearch';
// 结果条数上限：命中可能上百条（高级视图有几百个参数），平铺出来反而找不着；
// 截断后由界面提示「还有 N 条」，引导用户把词打准一点。
const SEARCH_MAX_HITS: number = 60;
// 命中跳转后行高亮的持续时间
const SEARCH_FLASH_MS: number = 1600;

// 搜索命中项（带着分数，便于按相关度排序）
class SearchHit {
  p: SliceParam;
  score: number;

  constructor(p: SliceParam, score: number) {
    this.p = p;
    this.score = score;
  }
}

// 模糊子序列匹配：q 的字符按序出现在 s 中（不要求连续）。
// 返回「首尾跨度 - 查询长度」（值越小越紧凑）；不匹配返回 -1。
// 只在查询串 >= 3 个字符时才用（太短会匹配到一大片无关项）。
function subsequenceGap(s: string, q: string): number {
  let from: number = 0;
  let first: number = -1;
  let last: number = -1;
  for (let qi = 0; qi < q.length; qi++) {
    const c: string = q.charAt(qi);
    let found: number = -1;
    for (let k = from; k < s.length; k++) {
      if (s.charAt(k) === c) {
        found = k;
        break;
      }
    }
    if (found < 0) {
      return -1;
    }
    if (first < 0) {
      first = found;
    }
    last = found;
    from = found + 1;
  }
  return (last - first + 1) - q.length;
}


// 预设初始化失败时下拉的占位文案（下拉禁用；参数区另有失败卡片 + 重试按钮）
const FAILED_TEXT: string = '预设加载失败';

// 内核判定该机型没有兼容的工艺/耗材预设时的下拉占位文案（下拉禁用，不静默保留旧列表）
const NO_COMPAT_TEXT: string = '无兼容预设';

// ---- 需求 3：预设区按面板可用宽度分档 -------------------------------------------
// 右面板 = 「更改预设」所在容器。其可用宽 < 该阈值时视为「手机 / 窄内容区」：
//   · 4 个预设下拉（工艺/打印机/耗材/打印板）收进一个可折叠区，默认收起，收起时只显示当前值摘要；
//   · 行高 / 内边距 / 字号一并压缩，解决手机上占地过大、下拉文字被截断的问题。
// ≥ 该阈值（平板 / 2in1 默认右栏 320vp 起）保持原有观感不变（平板不为手机改窄）。
// 阈值与右栏拖拽区间 [RIGHT_MIN=220, RIGHT_MAX=480] 协同：拖动改宽跨越阈值时档位自动切换。
const PANEL_COMPACT_W: number = 320;

// 通用动态切片参数面板：根据内核驱动出的 schema 元数据自动渲染，不硬编码参数项
@Component
export struct DynamicParamsPanel {
  // 打开「耗材编辑」弹窗（入口在本面板「耗材」选择器正下方，取代原顶栏入口）
  onFilament: () => void = () => {};

  @State printerIndex: number = 0;
  @State filamentIndex: number = 0;
  @State processIndex: number = 0;
  @State plateIndex: number = 0;
  // 盘级床型（仅多盘时有意义）：0 = 跟随全局；1..N = plateOptions 下标 + 1（见 plateBedSelectorLabels）
  @State plateBedIndex: number = 0;
  @StorageLink('activePlate') @Watch('onActivePlateForBed') activePlate: number = -1;
  // 需求 3：面板可用宽度（vp，onAreaChange 实测）→ 决定预设区「紧凑/常规」档位
  @State private panelW: number = 0;
  // 紧凑档下预设折叠区是否展开（默认收起；点标题展开/收起）
  @State private presetsExpanded: boolean = false;
  @State globalMode: boolean = true;

  // 沉浸材质：系统支持就用真·系统材质（预设卡片呈现玻璃质地），否则退回普通模糊。
  @State private matSupported: boolean = false;
  private material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#141A1E24'
  });
  @State objectIndex: number = 0;
  @State activeGroup: number = 0;
  @State allParams: SliceParam[] = [];
  @State groups: string[] = [];
  @State collapsed: string[] = [];

  // ---- 参数搜索（Phase 4）----
  // 搜索词非空 → 参数区切换为「扁平结果列表」（跨分组、跨页签）；
  // 点结果 → 切到该参数所在的分组/子分组，滚到那一行并短暂高亮。
  @State private searchText: string = '';
  // 命中跳转后高亮的 key（1.6s 后自动清掉）
  @State private flashKey: string = '';
  private flashTimer: number = -1;
  // 参数区滚动控制器：跳转到某一行必须能滚过去，所以要绑 Scroller（裸 Scroll 只能靠偏移估算）
  private bodyScroller: Scroller = new Scroller();
  // 行在滚动内容里的 y 偏移。子分组上报「相对内容 Column」的 y、行上报「相对所属子分组」的 y，
  // 两者相加即该行在内容里的位置 —— Scroll 的 scrollTo 要的就是这个值。
  private subY: Map<string, number> = new Map<string, number>();
  private rowY: Map<string, number> = new Map<string, number>();

  // 参数"被修改"代次：每次改值（updateValue）或换预设重置基准（loadSchema）时 +1。
  // 为什么需要它：ForEach 复用同 key 的项、不会重跑 item builder，所以"改一下值就让本行变橙"
  // 必须靠一个 @State 代次去驱动该行颜色属性重算（见 isParamModified / ensureModifiedCache）。
  @State private modifyRev: number = 0;

  // 预设初始化状态（本地 @State，由 SlicerService 的显式订阅回调驱动）。
  //
  // 为什么不再用 @StorageLink + @Watch：把"就绪"当 AppStorage 的**值**发布、靠 @StorageLink
  // 双向同步去"等值变化"，不是事件通知（官方明确不建议这么用）。本工程里还叠加了组件内
  // syncStateFromService() 回写同一个变量，实测表现就是：**停在本页的组件收不到通知、四个下拉
  // 永远「加载中…」，而切到预览页再回来（重新挂载 -> aboutToAppear 直接读服务静态状态）就正常**。
  // 现在改为在 aboutToAppear 里向 SlicerService 显式订阅，状态一变就主动回调、直接刷新下拉与参数。
  //
  // 三态字符串（见 SlicerService.STATE_*）：loading=加载中、ready=按内核真实预设渲染、
  // failed=显示失败原因 + 重试按钮。
  @State presetState: string = 'loading';
  // 失败原因（与 presetState 配套，由同一个回调一起更新）
  @State presetError: string = '';
  // 订阅 token：aboutToAppear 订阅、aboutToDisappear 取消（-1 表示未订阅）
  private presetStateToken: number = -1;

  // 预设切换后 +1，并塞进 ForEach 的 key。
  // 为什么必须这样：ArkUI 的 ForEach 对「key 相同的项」是复用组件、不重跑 item builder 的，
  // 而参数项的 key 只由 group/subgroup/key 组成、预设切换后完全不变 —— 于是表单会一直显示
  // 上一个预设的值（现象就是「选了 0.16 的工艺，层高还显示 0.2」）。
  // 让 key 带上这个版本号，预设一变整棵参数树重建，值才会真正刷到控件上；
  // 用户手动编辑单项时不动它，所以输入框聚焦不会被顶掉。
  @State schemaRev: number = 0;

  // ---- 数值输入的「编辑缓冲」（修正 3）-----------------------------------------
  // 为什么需要它：数值输入框若直接把 displayValue（含单位、随参数值实时格式化）绑到 text、
  // 又在 onChange 里立刻解析回写，用户删到一半（例如把 "0.42 mm" 的 "m" 删掉）就会被立刻
  // 「纠正」回原值，根本没法编辑。这里用「正在编辑的 key + 用户原样的输入串」接管编辑过程：
  //   · 编辑中：文本完全由 editText 决定 —— 不解析、不校验、不格式化、不回填；
  //   · 提交（Enter / 失焦）：才解析 → 校验 → 写回参数（见 commitNumericEdit）。
  // 单位改成输入框外的独立标签，绝不放进可编辑文本里（用户会误删）。
  @State private editKey: string = '';
  @State private editText: string = '';

  // 三个预设下拉 + 打印板下拉的显示项。
  // **顺序与内容直接来自内核候选表（slicerPresetOptions），界面不得重排/裁剪**：
  // 界面回传给内核的下标就是这份数组的下标，名字只用于展示。
  // 打印机=全部可见机型；工艺/耗材=内核判定兼容当前机型的子集（kind 1/2）。
  @State printerOptions: string[] = [DEFAULT_PRINTER];
  @State processOptions: string[] = [DEFAULT_PROCESS];
  @State filamentOptions: string[] = [DEFAULT_FILAMENT];
  @State plateOptions: string[] = ['低温打印板', '工程材料打印板', '高温打印板', '纹理 PEI 打印板', 'SuperTack 打印板'];

  // 内核候选表原文（含 name / layerHeight / nozzle），与上面三个 options 一一对应（同一顺序）。
  // 只读展示信息，参与日志对照；选择仍只用下标。
  private printerItems: PresetOptionItem[] = [];
  private processItems: PresetOptionItem[] = [];
  private filamentItems: PresetOptionItem[] = [];
  // 内核"当前真实选中"的工艺/耗材名（来自候选表的 selectedName）；用于判断界面选中项是否已与内核一致
  private kernelProcessName: string = '';
  private kernelFilamentName: string = '';

  // 内核预设已就绪（候选表可用）
  private presetReady: boolean = false;
  // 防止重复构建（订阅回调可能多次触发）
  private catalogBuilt: boolean = false;
  // 未就绪时下拉的占位候选（只一项，配合 enabled(false)）
  private loadingOptions: string[] = [LOADING_TEXT];
  // 初始化失败时下拉的占位候选（只一项，配合 enabled(false)）
  private failedOptions: string[] = [FAILED_TEXT];
  // 机型无兼容预设时的下拉占位候选（只一项，配合 enabled(false)）
  private noCompatOptions: string[] = [NO_COMPAT_TEXT];

  // 候选表代次号：每次重建候选列表（printerOptions / processOptions / filamentOptions）时 +1。
  //
  // 为什么需要它：下拉回传给内核的是**下标**，而下标的语义依附于"当时那份列表"。
  // 一旦列表在"渲染下拉"与"用户点中"之间被刷新过，同一个下标就指向了另一个预设
  // （现象 = 用户点的名字是 A、实际下发给内核的是 B，层高随之错值）。
  // 渲染下拉时会把当时的代次一起冻结进回调；点击时若代次已变化，就按名字在最新列表里重定位，
  // 定位不到则提示并**不下发** —— 绝不用一个漂移的下标去选预设（见 dispatchDropdownPick）。
  private optionsGen: number = 0;

  // 「对象」页签：对象选择器数据源与当前选中项。
  // 与左侧对象列表同源：@StorageLink('modelObjects') 拿对象列表，
  // @StorageLink('selectedModelId') + @Watch 与左侧选中双向同步（单一事实源 = AppStorage）。
  @StorageLink('modelObjects') objects: ModelFile[] = [];
  @StorageLink('selectedModelId') @Watch('onSelectedObjectChanged') selectedModelId: number = -1;
  // 撤销/重做改过「全局参数覆盖表」时，History 会 +1 这个序号 → 本面板把值重新对齐（见 onParamRestore）
  @StorageLink('paramRestoreSeq') @Watch('onParamRestore') paramRestoreSeq: number = 0;
  // 耗材编辑「保存 / 重置」后 +1 → 重新对齐参数表（否则面板仍显示改之前的出厂值）
  @StorageLink('filamentEditSeq') @Watch('onFilamentEdited') filamentEditSeq: number = 0;

  // 3MF 导入设置（由 ThreeMfImport 发布到 AppStorage）：**文件 > 本机持久化**。
  // 面板是预设/参数的唯一所有者，所以导入的预设与参数都从这里应用一次
  // （走现成的「按名定位 → 按索引下发 → 内核校验 → 失败回滚」路径）。
  // 监听用自增序号（number 类型最稳），设置本体从 AppStorage 现取。
  @StorageLink('importSettingsSeq') @Watch('onImportSettingsSeqChanged') importSettingsSeq: number = 0;

  // 对象参数覆盖表：objectId -> (参数 key -> 数值)。按 key 取值，绝不用对象下标去索引参数。
  // 未覆盖的 key 回落到全局参数值（对象继承全局）；仅内存态、按对象持久，不参与内核切片。
  // 【跨页面存活】指向 SliceParamStore 的同一份表（而非本组件私有 Map）：组件随切页销毁重建后，
  //   对象覆盖值仍在（修「切页回来对象参数也重置」）。
  private objectOverrides: Map<number, Map<string, number>> = SliceParamStore.getObjectOverrides();

  // 对象级「工艺/打印机/耗材」覆盖表：objectId -> ObjPresetSel（对象模式专用，不污染全局预设）。
  // 与 objectOverrides 同一套「对象覆盖优先、否则回落全局」语义。
  private objPresets: Map<number, ObjPresetSel> = new Map<number, ObjPresetSel>();

  // 「预设默认值」基准表：key -> 该预设下内核回读的默认值（loadSchema 时刷新）。
  // 高亮判定 = 当前有效值 vs 这份基准；基准来自内核 config 快照，绝不自编默认值。
  private presetBaseline: Map<string, number> = new Map<string, number>();
  // 已修改参数集合 + 缓存代次（避免每行 / 每标签都全量遍历参数）
  private modifiedKeys: Set<string> = new Set<string>();
  private modCacheRev: number = -1;
  private modCacheSchema: number = -1;
  // 恢复过程中为 true：期间不写盘，避免把"半恢复"的中间态固化成上次值
  private restoring: boolean = false;

  aboutToAppear(): void {
    try {
      this.matSupported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      this.matSupported = false;
    }
    // 打印板尺寸要等内核预设就绪后由 applyPrinterPlate() 从当前打印机预设读取，
    // 这里不做兜底设置，避免先画一个错的板再跳变。

    // 防御：理论上不会重复 aboutToAppear，但若发生则先退掉上一次订阅，避免重复回调/泄漏。
    if (this.presetStateToken !== -1) {
      SlicerService.unsubscribePresetState(this.presetStateToken);
      this.presetStateToken = -1;
    }

    // ① 挂载先同步一次当前状态：本组件挂载时初始化可能早已完成/失败（入口路径一直可用）。
    this.syncStateFromService();
    // 盘级床型：若参数已就绪，立刻定位「当前盘」的选择器下标（参数未就绪时 loadSchema 里再定位）
    this.syncPlateBedIndex();

    // ② 显式订阅：subscribe 会**立刻**用当前状态回调一次（所以上面 ① 之后 isReady/isFailed
    //    都由回调统一处理），之后每次状态变化也会回调 —— 这就是"停在本页也能自愈"的通道，
    //    不再依赖 @StorageLink/@Watch 那条不可靠的 AppStorage 通知路径。
    this.presetStateToken = SlicerService.subscribePresetState(
      (state: string, err: string): void => {
        this.onPresetState(state, err);
      });

    // ③ 仍未就绪（loading）才发起/等待初始化；ready/failed 已由订阅回调处理。
    //    loading 时绝不调 loadSchema() 抢先渲染：此刻内核还没加载官方预设，
    //    slicerConfigSnapshot/schema 都落在"内核默认值"上，渲染出来是退化表单。
    if (this.presetState === SlicerService.STATE_LOADING) {
      this.startInit();
    }
  }

  aboutToDisappear(): void {
    // 退出兜底保存：主通道是"每次切换成功即写盘"，这里在组件卸载（切页 / 退出）时再补一次，
    // 但不依赖它（被强杀时不会走到卸载）。未就绪时 savePresetState 内部会自行跳过。
    this.savePresetState('页面卸载兜底');
    // 组件卸载必须取消订阅：否则回调会打到已销毁的组件上（同时造成监听者泄漏）
    if (this.presetStateToken !== -1) {
      SlicerService.unsubscribePresetState(this.presetStateToken);
      this.presetStateToken = -1;
    }
    // 高亮定时器同理：卸载后回调没有意义
    if (this.flashTimer !== -1) {
      clearTimeout(this.flashTimer);
      this.flashTimer = -1;
    }
  }

  // ---------------------------------------------------------------------------
  // 参数搜索（Phase 4）
  //
  // 学桌面版 Search.cpp 的思路做**阈值式打分**：分数低于阈值的直接不显示，
  // 避免「搜一个词出来一大片无关项」。档位从高到低：key 精确 > 名称精确 > 名称前缀 >
  // 名称子串 > key 子串 > 说明子串 > 模糊子序列（>=3 字符才启用）。
  // 搜索范围是**全部参数**（不分页签、不看简易/高级）—— 跨页签才能「搜到就能到」，
  // 命中高级项时跳转会自动帮你切到高级视图。
  // ---------------------------------------------------------------------------
  private scoreOf(p: SliceParam, q: string): number {
    const key: string = p.key.toLowerCase();
    const label: string = p.label.toLowerCase();
    if (key === q) { return 1000; }
    if (label === q) { return 900; }
    if (label.startsWith(q)) { return 820 - Math.min(60, label.length - q.length); }
    const li: number = label.indexOf(q);
    if (li >= 0) { return 740 - Math.min(80, li); }
    const ki: number = key.indexOf(q);
    if (ki >= 0) { return 640 - Math.min(80, ki); }
    if (p.tooltip.toLowerCase().indexOf(q) >= 0) { return 420; }
    if (q.length >= 3) {
      const gap: number = subsequenceGap(label, q);
      if (gap >= 0) { return 300 - Math.min(90, gap); }
    }
    return -1;
  }

  private searchHits(): SliceParam[] {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) { return []; }
    const hits: SearchHit[] = [];
    for (const p of this.allParams) {
      const s: number = this.scoreOf(p, q);
      if (s >= 300) { hits.push(new SearchHit(p, s)); }
    }
    hits.sort((a: SearchHit, b: SearchHit) => b.score - a.score);
    const out: SliceParam[] = [];
    for (let i = 0; i < hits.length && i < SEARCH_MAX_HITS; i++) {
      out.push(hits[i].p);
    }
    return out;
  }

  // 命中总数（用于「显示 60 / 共 N 条」提示；搜索是纯前端过滤，重算成本可忽略）
  private searchHitCount(): number {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) { return 0; }
    let n: number = 0;
    for (const p of this.allParams) {
      if (this.scoreOf(p, q) >= 300) { n++; }
    }
    return n;
  }

  // 命中 label 的子串区间（用于结果行里把命中的那几个字标成强调色）；没命中返回 -1
  private hitAt(p: SliceParam): number {
    const q: string = this.searchText.trim().toLowerCase();
    if (q.length === 0) { return -1; }
    return p.label.toLowerCase().indexOf(q);
  }

  private hitPart(p: SliceParam, which: number): string {
    const at: number = this.hitAt(p);
    const q: number = this.searchText.trim().length;
    if (at < 0 || which === 0) { return which === 0 ? p.label : ''; }
    if (which === 1) { return p.label.substring(at, at + q); }
    return p.label.substring(at + q);
  }

  // 点结果 → 跳过去：切模式/页签 → 展开子分组 → 清空搜索 → 滚到那一行并短暂高亮。
  // 顺序不能乱：① 渲染条件（视图档位 / 页签 / 折叠）要先定下来，否则滚过去的是一屏不存在的行；
  //            ② 清空搜索词会让参数区从「结果列表」切回「分组列表」，那是一次重新布局，
  //               所以滚动必须等这一帧布局完成（onAreaChange 上报了新偏移）之后再发起。
  private jumpToParam(p: SliceParam): void {
    if (p.mode === 1 && this.paramViewMode === 0) {
      this.paramViewMode = 1;                 // 高级项在简易视图里根本不渲染，先切档
      SliceParamStore.setParamViewMode(1);
    }
    const gi: number = this.groups.indexOf(p.group);
    if (gi >= 0) {
      this.activeGroup = gi;
    }
    if (p.subgroup.length > 0 && this.isCollapsed(p.subgroup)) {
      this.toggleCollapse(p.subgroup);        // 折叠着的话先展开，否则那一行不存在
    }
    this.flashKey = p.key;
    if (this.flashTimer !== -1) {
      clearTimeout(this.flashTimer);
    }
    this.flashTimer = setTimeout(() => {
      this.flashTimer = -1;
      this.flashKey = '';
    }, SEARCH_FLASH_MS);
    this.searchText = '';
    this.scrollToRow(p.key, 0);
    hilog.info(0x0000, SEARCH_TAG, '跳转 param=%{public}s 分组=%{public}s/%{public}s',
      p.key, p.group, p.subgroup);
  }

  // 滚到某一行：偏移由 onAreaChange 逐级上报（见 build 里的 subY/rowY）。
  // 首次拿不到就再试一次 —— 清空搜索词会触发一次重新布局，布局没完成时 rowY 还是空的。
  private scrollToRow(key: string, attempt: number): void {
    setTimeout(() => {
      const y: number | undefined = this.rowY.get(key);
      if (y === undefined) {
        if (attempt < 2) {
          this.scrollToRow(key, attempt + 1);
        } else {
          hilog.warn(0x0000, SEARCH_TAG, '拿不到行偏移，只高亮不滚动 param=%{public}s', key);
        }
        return;
      }
      // y - 36：让目标行落在视口上部一点，不要把行顶到边缘
      this.bodyScroller.scrollTo({
        xOffset: 0,
        yOffset: Math.max(0, y - 36),
        animation: { duration: 240, curve: Curve.EaseOut }
      });
      hilog.info(0x0000, SEARCH_TAG, '滚动定位 param=%{public}s y=%{public}d 第%{public}d次',
        key, Math.round(y), attempt + 1);
    }, attempt === 0 ? 150 : 250);
  }

  // 发起（或等待）预设初始化。幂等：EntryAbility 已发起时这里只是同一个 promise。
  private startInit(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      // 拿不到上下文就等于这次初始化不可能完成：必须落一个失败终态，不能留 loading
      hilog.error(0x0000, 'PresetInit', '拿不到 UIContext，无法发起预设初始化');
      SlicerService.markFailed('无法获取应用上下文');
      this.syncStateFromService();
      return;
    }
    hilog.info(0x0000, 'PresetInit', '面板发起 ensurePresets（当前状态=%{public}s）', this.presetState);
    SlicerService.ensurePresets(ctx.filesDir)
      .then((ok: boolean) => {
        // 终态由服务在 publish() 里主动回调（本组件已订阅），这里只做兜底对齐（幂等）
        hilog.info(0x0000, 'PresetInit', '面板侧 ensurePresets 回调 ok=%{public}s，服务状态=%{public}s',
          ok ? 'true' : 'false', SlicerService.getState());
        this.syncStateFromService();
      })
      .catch((e: Object) => {
        // 理论上 ensurePresets 永不 reject；这里兜底，保证异常也有终态（不吞异常）
        hilog.error(0x0000, 'PresetInit', '面板侧 ensurePresets 异常: %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
        SlicerService.markFailed('初始化调用异常');
        this.syncStateFromService();
      });
  }

  // 用户点「重试」：重置幂等状态后重新走一次初始化
  private onRetryPresets(): void {
    const ctx = this.getUIContext().getHostContext();
    hilog.info(0x0000, 'PresetInit', '用户点击重试预设初始化');
    if (!ctx) {
      hilog.error(0x0000, 'PresetInit', '重试时拿不到 UIContext');
      SlicerService.markFailed('无法获取应用上下文');
      this.syncStateFromService();
      return;
    }
    // 重新初始化时允许重建下拉/参数树
    this.catalogBuilt = false;
    this.presetReady = false;
    SlicerService.retryPresets(ctx.filesDir)
      .then((ok: boolean) => {
        hilog.info(0x0000, 'PresetInit', '重试完成 ok=%{public}s，服务状态=%{public}s',
          ok ? 'true' : 'false', SlicerService.getState());
        this.syncStateFromService();
      })
      .catch((e: Object) => {
        hilog.error(0x0000, 'PresetInit', '重试异常: %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
        SlicerService.markFailed('重试调用异常');
        this.syncStateFromService();
      });
  }

  // 把本组件本地状态与服务的权威状态对齐（只在真的不同才回写）
  private syncStateFromService(): void {
    const s: string = SlicerService.getState();
    if (this.presetState !== s) {
      this.presetState = s;
    }
    const err: string = SlicerService.getError();
    if (this.presetError !== err) {
      this.presetError = err;
    }
  }

  // SlicerService 的显式订阅回调：初始化状态变化时（含订阅瞬间的初次回调）刷新界面。
  // 这条是"停在本页无需任何操作即可看到全量列表"的唯一通道。
  private onPresetState(state: string, err: string): void {
    hilog.info(0x0000, 'PresetInit', '预设状态回调 state=%{public}s err=%{public}s', state, err);
    this.presetState = state;
    this.presetError = err;
    if (state === SlicerService.STATE_READY) {
      this.buildPresetSelectors();
      return;
    }
    if (state === SlicerService.STATE_FAILED) {
      // 失败态：清掉"已构建"标记，让重试成功后能重建；参数区改由失败卡片承载，
      // 不用内核默认值渲染退化表单（那正是层高显示 0.06 的来源）。
      this.catalogBuilt = false;
      this.presetReady = false;
      return;
    }
    // loading：什么都不渲染，等下一次状态变化
  }

  // 下拉占位候选：loading/failed 各一套（都只有一项，配合 enabled(false)）
  private statePlaceholder(): string[] {
    return this.presetState === SlicerService.STATE_FAILED ? this.failedOptions : this.loadingOptions;
  }

  // 下拉占位文案：loading/failed 各一套
  private statePlaceholderText(): string {
    return this.presetState === SlicerService.STATE_FAILED ? FAILED_TEXT : LOADING_TEXT;
  }

  // ---- 需求 3：预设区宽度分档 ----------------------------------------------------
  // 是否「紧凑档」：面板可用宽 < PANEL_COMPACT_W。宽度还没测到（panelW<=0）时按常规档，
  // 避免首帧先闪一下折叠再展开。
  private compactPanel(): boolean {
    return this.panelW > 0 && this.panelW < PANEL_COMPACT_W;
  }

  // 紧凑档 + 收起时的「当前预设摘要」（2 行）：
  //   第 1 行 工艺 / 打印机，第 2 行 耗材 / 板。用真实显示名，不编造；未就绪时显示占位文案。
  private presetSummary(): string {
    if (this.presetState !== SlicerService.STATE_READY) {
      return this.statePlaceholderText();
    }
    const proc: string = this.processLabel();
    const printer: string = this.printerOptions[this.printerIndex] ?? '';
    const fil: string = this.filamentLabel();
    const plate: string = this.plateOptions[this.plateIndex] ?? '';
    return `工艺 ${proc} · 打印机 ${printer}\n耗材 ${fil} · 板 ${plate}`;
  }

  // 面板可用宽实测（挂在最外层 Column）：拖动右栏宽度 / 旋转 / 窗口尺寸变化都会触发 → 自动切档
  private onPanelArea(n: Area): void {
    const w: number = Number(n.width);
    if (w > 0 && Math.abs(w - this.panelW) >= 0.5) {
      this.panelW = w;
    }
  }

  // ===== 预设驱动的三个下拉（候选项与下标全部来自内核候选表）=====

  // 预设名的"规格前缀"：去掉 " @BBL ..." 后缀。
  // 例 "0.20mm Standard @BBL X1C" -> "0.20mm Standard"。
  // 只用于「换机型后挑一个与旧选择同规格的默认项」，不参与兼容性判断（兼容性一律由内核候选表决定）。
  private presetBaseName(name: string): string {
    const at: number = name.indexOf(' @BBL');
    return at > 0 ? name.substring(0, at) : name;
  }

  // 在内核候选表里给「界面默认选中项」定位：优先同名，其次同规格前缀
  //（"0.20mm Standard @BBL X1C" -> "0.20mm Standard @BBL A1"），再退到列表首项。
  // 只有"内核当前预设不在候选表内"（selectedIndex=-1）这一极端情况才用它兜底；
  // 优先"同规格前缀"而不是直接取首项：候选表首项是 "0.06mm ..." 这类极端预设，
  // 静默取首项会把层高变成 0.06mm。
  private pickInList(list: string[], oldName: string): number {
    if (list.length === 0) {
      return 0;
    }
    const exact: number = list.indexOf(oldName);
    if (exact >= 0) {
      return exact;
    }
    const base: string = this.presetBaseName(oldName);
    if (base !== '') {
      for (let i = 0; i < list.length; i++) {
        if (this.presetBaseName(list[i]) === base) {
          return i;
        }
      }
    }
    return 0;
  }

  // 下拉显示项：候选为空时用「无兼容预设」占位（配合 enabled(false)）
  private selectDisplay(opts: string[]): string[] {
    return opts.length > 0 ? opts : this.noCompatOptions;
  }

  // 候选表 items -> 展示用名字数组（顺序原样保留 = 内核下标顺序，**绝不重排**）
  private namesOf(items: PresetOptionItem[]): string[] {
    const out: string[] = [];
    for (const it of items) {
      out.push(it.name);
    }
    return out;
  }

  private clampIndex(i: number): number {
    return i >= 0 ? i : 0;
  }

  // 取内核候选表（kind: 0=printer / 1=process / 2=filament）。解析或内核失败返回 undefined（不吞异常）。
  private fetchOptions(kind: number, label: string): PresetOptions | undefined {
    try {
      const opts: PresetOptions = JSON.parse(SlicerService.presetOptions(kind)) as PresetOptions;
      if (!opts.ok) {
        hilog.error(0x0000, COMPAT_TAG, '%{public}s候选表内核返回失败: %{public}s', label, opts.message);
        return undefined;
      }
      return opts;
    } catch (e) {
      hilog.error(0x0000, COMPAT_TAG, '%{public}s候选表解析失败: %{public}s', label,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return undefined;
    }
  }

  // 用内核候选表重建三个下拉（机型全量 + 内核真实名字与顺序，不翻译、不裁剪、不重排）。
  // 候选项 = 内核"可被选中"的集合，下标即内核顺序，界面选择时只回传下标。
  private buildPresetSelectors(): void {
    if (this.catalogBuilt) {
      return;
    }

    const printerOpts: PresetOptions | undefined = this.fetchOptions(0, '打印机');
    if (printerOpts === undefined || printerOpts.items.length === 0) {
      hilog.warn(0x0000, LOG_TAG, '打印机候选表不可用，预设下拉保持兜底值');
      return;
    }
    this.catalogBuilt = true;
    this.presetReady = true;

    this.printerItems = printerOpts.items;
    this.printerOptions = this.namesOf(printerOpts.items);
    // 候选表换代：任何以旧列表下标"冻结"的下拉回调，点击时都能据此判断下标是否已过期
    this.optionsGen = this.optionsGen + 1;
    // 下拉默认选中 = 内核当前选中的机型（用内核给的 selectedIndex，绝不静默取 0）
    this.printerIndex = this.clampIndex(printerOpts.selectedIndex);

    // 工艺/耗材候选：内核按"当前打印机"给出的兼容子集（界面不传名字，天然与内核同源）
    this.refreshProcessFilamentOptions(printerOpts.selectedName);

    const printerSel: PresetOptionItem | undefined = this.printerItems[this.printerIndex];
    hilog.info(0x0000, LOG_TAG,
      '预设候选就绪：机%d/工艺%d/耗材%d；内核选中 机=%{public}s(喷嘴%{public}s) 工艺=%{public}s 耗材=%{public}s',
      this.printerOptions.length, this.processOptions.length, this.filamentOptions.length,
      printerOpts.selectedName,
      printerSel !== undefined && printerSel.nozzle >= 0 ? printerSel.nozzle.toFixed(2) : '?',
      this.kernelProcessName, this.kernelFilamentName);

    // 只有界面选中项与内核真值不一致（内核当前预设不在候选表内，selectedIndex=-1 的极端情况）
    // 才下发一次，让界面与内核重新对齐；一致时不下发，避免每次进页面都做无谓的预设切换。
    if (this.alignProcessFilamentWithKernel()) {
      this.refreshProcessFilamentOptions(printerOpts.selectedName);
    }

    this.loadSchema();
    this.applyPrinterPlate(printerOpts.selectedName);

    // 预设目录就绪、界面已按内核真值渲染之后，再尝试恢复"上次使用的预设"。
    // 放在这里的理由：恢复要复用下面的选择/校验/回滚路径，而那条路径依赖候选表已建好。
    this.restorePresetState();

    // 恢复「上次使用」之后再看有没有待应用的 3MF 导入设置：
    // 优先级是 **文件 > 本机持久化**，所以必须在 restorePresetState 之后应用。
    this.applyImportSettings();
  }

  // 刷新「工艺 / 耗材」候选：直接取内核候选表（kind 1/2）。
  //
  // 与旧实现的根本区别：旧实现要界面先拿"内核回读的机型名"再去查兼容列表，一旦名字对不上
  // 就查不到、退回旧列表 —— 这正是「换了机型下拉却不换」以及"列表过期 -> 拿对不上的名字去选
  // -> 内核静默回退 -> 层高变 0.18/0.28/0.3"的来源。现在候选由内核自己按"它当前选中的机型"
  // 产出，界面不传任何名字，因此不存在过期列表。
  // logPrinter 仅用于日志对照（候选表里自带的 printer 才是权威机型名）。
  private refreshProcessFilamentOptions(logPrinter: string): void {
    if (!this.presetReady) { return; }

    const oldProc: string = this.processOptions[this.processIndex] ?? '';
    const oldFil: string = this.filamentOptions[this.filamentIndex] ?? '';

    const procOpts: PresetOptions | undefined = this.fetchOptions(1, '工艺');
    const filOpts: PresetOptions | undefined = this.fetchOptions(2, '耗材');
    if (procOpts === undefined || filOpts === undefined) {
      // 查询失败绝不保留旧列表：清空候选（下拉显示「无兼容预设」并禁用），
      // 避免把上一台机器的候选冒充成这台机器的结果。
      this.processItems = [];
      this.filamentItems = [];
      this.processOptions = [];
      this.filamentOptions = [];
      // 候选表换代（即使这次是清空）：旧下标一律作废，点击时按名字重定位/拒绝
      this.optionsGen = this.optionsGen + 1;
      this.processIndex = 0;
      this.filamentIndex = 0;
      this.kernelProcessName = '';
      this.kernelFilamentName = '';
      promptAction.showToast({ message: '兼容预设查询失败' });
      return;
    }

    this.processItems = procOpts.items;
    this.filamentItems = filOpts.items;
    this.processOptions = this.namesOf(procOpts.items);
    this.filamentOptions = this.namesOf(filOpts.items);
    // 候选表换代：工艺/耗材列表刚被重建，渲染时冻结的旧下标不再可信
    this.optionsGen = this.optionsGen + 1;
    this.kernelProcessName = procOpts.selectedName;
    this.kernelFilamentName = filOpts.selectedName;

    // 选中项优先用内核回读的下标（selectedIndex）；内核没给（-1）时按"同名 -> 同规格前缀 -> 首项"兜底
    this.processIndex = procOpts.selectedIndex >= 0
      ? procOpts.selectedIndex : this.pickInList(this.processOptions, oldProc);
    this.filamentIndex = filOpts.selectedIndex >= 0
      ? filOpts.selectedIndex : this.pickInList(this.filamentOptions, oldFil);

    const procSel: PresetOptionItem | undefined = this.processItems[this.processIndex];
    hilog.info(0x0000, COMPAT_TAG,
      '候选表刷新（内核机型=%{public}s 参考=%{public}s）：工艺%d/耗材%d；工艺选中=%{public}s(层高%{public}s) 耗材选中=%{public}s',
      procOpts.printer, logPrinter, this.processOptions.length, this.filamentOptions.length,
      this.processLabel(),
      procSel !== undefined && procSel.layerHeight >= 0 ? procSel.layerHeight.toFixed(2) : '?',
      this.filamentLabel());

    // 空列表要显式暴露出来（下拉禁用 + toast），不能悄悄留着上一台机器的候选
    if (this.processOptions.length === 0) {
      hilog.warn(0x0000, COMPAT_TAG, '内核机型%{public}s无兼容工艺预设，工艺下拉置为「%{public}s」并禁用',
        procOpts.printer, NO_COMPAT_TEXT);
      promptAction.showToast({ message: `该机型无兼容工艺预设` });
    }
    if (this.filamentOptions.length === 0) {
      hilog.warn(0x0000, COMPAT_TAG, '内核机型%{public}s无兼容耗材预设，耗材下拉置为「%{public}s」并禁用',
        filOpts.printer, NO_COMPAT_TEXT);
      promptAction.showToast({ message: `该机型无兼容耗材预设` });
    }
  }

  // 界面选中项 vs 内核真值：只有不一致才按索引下发，一致时不下发。返回是否下发过。
  private alignProcessFilamentWithKernel(): boolean {
    let pushed: boolean = false;
    if (this.processOptions.length > 0 &&
        this.processOptions[this.processIndex] !== this.kernelProcessName) {
      this.pushIndex(1, this.processIndex);
      pushed = true;
    }
    if (this.filamentOptions.length > 0 &&
        this.filamentOptions[this.filamentIndex] !== this.kernelFilamentName) {
      this.pushIndex(2, this.filamentIndex);
      pushed = true;
    }
    return pushed;
  }

  // 内核可能按可用预设做了兜底，把下拉同步成内核真正用的那个
  private syncSelection(sel: PresetSelection): void {
    const pi: number = this.printerOptions.indexOf(sel.printer);
    const ri: number = this.processOptions.indexOf(sel.process);
    const fi: number = this.filamentOptions.indexOf(sel.filament);
    if (pi >= 0) { this.printerIndex = pi; }
    if (ri >= 0) { this.processIndex = ri; }
    if (fi >= 0) { this.filamentIndex = fi; }
    // 候选本身为空（该机型无兼容预设）不算"对不上"，无需提示；只有候选非空却没命中才提示
    if ((this.processOptions.length > 0 && ri < 0) || (this.filamentOptions.length > 0 && fi < 0)) {
      promptAction.showToast({ message: `内核实际使用：${sel.process} / ${sel.filament}` });
    }
  }

  // 调内核"按索引"切换预设并解析返回值：打印三方对照日志
  //「请求下标/该下标对应的内核候选名 -> 内核真实选中 -> 回读层高 -> 结果」。
  // 结果取值 ok=成功、rollback=失败已回滚、reject=失败未下发（下标越界/候选表不可用）。
  // 解析异常时落日志并返回 undefined（不吞异常）。
  private callSelectByIndex(kind: number, index: number): PresetIndexSelectResult | undefined {
    try {
      const res: PresetIndexSelectResult =
        JSON.parse(SlicerService.selectPresetByIndex(kind, index)) as PresetIndexSelectResult;
      const result: string = res.ok ? 'ok' : (res.rolledBack ? 'rollback' : 'reject');
      // 对照日志：一旦「请求下标对应的名字 ≠ 内核选中」或结果=rollback，就说明内核没认下，
      // 层高错值的来源立刻清楚。名字只出现在日志里，下发永远只用下标。
      hilog.info(0x0000, LOG_TAG,
        '按索引切换预设: kind=%{public}d index=%{public}d 请求名=%{public}s | 内核选中 机=%{public}s 工=%{public}s 耗=%{public}s | 回读层高=%{public}s | 结果=%{public}s',
        kind, index, res.requestedName,
        res.selected.printer, res.selected.process, res.selected.filament,
        res.layerHeight >= 0 ? res.layerHeight.toFixed(2) : '?', result);
      if (res.rolledBack) {
        hilog.warn(0x0000, LOG_TAG,
          '按索引切换已回滚: 内核未认下该下标，已恢复到 机=%{public}s 工=%{public}s 耗=%{public}s',
          res.rolledBackTo.printer, res.rolledBackTo.process, res.rolledBackTo.filament);
      }
      // 【机型校验修复】用内核回读的真实选中刷新内存预设目录（getCatalog 的 selected），
      // 否则换机后 currentSlicePrinter() 仍读到启动时冻结的旧机型（打印弹窗误报机型不匹配）。
      if (res.ok) {
        SlicerService.updateSelected(res.selected.printer, res.selected.process, res.selected.filament);
      }
      return res;
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, '按索引切换预设返回解析失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return undefined;
    }
  }

  // 只下发 + 日志（不重载 schema/板）；用于挂载对齐与换机后的候选对齐。
  private pushIndex(kind: number, index: number): PresetIndexSelectResult | undefined {
    const res: PresetIndexSelectResult | undefined = this.callSelectByIndex(kind, index);
    if (res === undefined) { return undefined; }
    if (!res.ok) {
      hilog.error(0x0000, LOG_TAG, '按索引下发未被内核接受(kind=%{public}d index=%{public}d): %{public}s',
        kind, index, res.message);
    }
    return res;
  }

  // 用户在某一下拉里选了第 index 项：按索引下发 -> 失败即回滚 -> 按内核真值回填下拉 + 重取参数/板。
  private applyIndexSelection(kind: number, index: number): void {
    const res: PresetIndexSelectResult | undefined = this.callSelectByIndex(kind, index);
    if (res === undefined) { return; }
    if (!res.ok) {
      // 内核没能认下该下标（理论上不会：下标就来自内核候选表）：C++ 侧已回滚到切换前状态，
      // 这里只把界面同步回滚到 selected，绝不让"下拉显示 A、参数值是 B"。
      hilog.error(0x0000, LOG_TAG, '按索引切换未被内核接受: %{public}s', res.message);
      promptAction.showToast({ message: res.rolledBack ? '该预设不适用于当前机型' : `切换预设失败：${res.message}` });
    }
    // 无论成功与否都按内核真实选中回填下拉 + 重取参数值，保证「界面显示 == 内核当前配置」。
    // 失败回滚时 selected 就是"切换前的那一个"，界面随之回到原处。
    this.syncSelection(res.selected);
    // 换预设 = 预设基准整体变化：清掉旧的用户覆盖（它们属于上一套预设），橙色随之清除。
    // 【恢复路径不清】restorePresetState() 期间 restoring=true：那时"换预设"只是把上次的选择还原，
    //   覆盖值本就属于这个预设，若在这里清掉就会把当前会话内的覆盖值一并抹掉。
    this.clearOverridesOnPresetChange();
    this.loadSchema();
    this.applyPrinterPlate(res.selected.printer);
    // 切换落定即写盘（增量 4 个键）；内核失败已回滚时写的是回滚后的真实选择。
    this.savePresetState('切换工艺/耗材');
  }

  // 用户主动换预设（工艺/耗材/打印机）时才清空覆盖值；恢复上次预设（restoring=true）时保留。
  private clearOverridesOnPresetChange(): void {
    if (this.restoring) {
      return;
    }
    SliceParamStore.clearUserOverrides();
  }

  // ===== 需求 2：保存 / 恢复上次使用的预设 =====

  // 保存当前选中（打印机 / 打印板 / 工艺 / 耗材）到 filesDir 下的 JSON。
  // 调用时机：每次"切换成功就写盘"（见 onPrinterChanged / applyIndexSelection / setPlateParam），
  // 而不是只靠退出时保存（被强杀 / 崩溃时那一步不会执行）。
  private savePresetState(reason: string): void {
    // 未就绪时下拉还是占位 / 兜底值，存了就是脏数据；恢复过程中也不存，避免固化半恢复状态。
    if (!this.presetReady || this.restoring) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      hilog.error(0x0000, LOG_TAG, '保存预设跳过：获取上下文失败');
      return;
    }
    const snap = new PresetSnapshot();
    snap.printer = this.printerOptions[this.printerIndex] ?? '';
    snap.process = this.processOptions[this.processIndex] ?? '';
    snap.filament = this.filamentOptions[this.filamentIndex] ?? '';
    snap.bedType = this.plateOptions[this.plateIndex] ?? '';
    snap.savedAt = new Date().toLocaleString();
    const ok: boolean = PresetPersist.save(ctx.filesDir, snap);
    if (!ok) {
      PresetPersist.log(ctx.filesDir, '预设持久化 写盘失败（仅打日志，不影响使用）');
      return;
    }
    PresetPersist.log(ctx.filesDir,
      `预设持久化 保存 机=${snap.printer} 板=${snap.bedType} 工=${snap.process} 耗=${snap.filament}` +
      `（${reason}）`);
    // 全局耗材名发布 + 按「耗材→喷嘴」分组重算（供打印弹窗/告警看到最新喷嘴归属）
    this.publishGlobalFilament(snap.filament);
  }

  // 发布「全局耗材名」到 AppStorage 并重算耗材分组（对象无覆盖时用全局耗材）
  private publishGlobalFilament(filament: string): void {
    AppStorage.setOrCreate<string>('globalFilamentName', filament);
    const printer: string = this.printerOptions[this.printerIndex] ?? '';
    if (FilamentGrouping.applyToState(printer, [])) {
      modelState.publish();
    }
  }

  // 启动恢复：预设就绪后按「打印机 -> 工艺 -> 耗材 -> 打印板」顺序恢复上次选择。
  //
  // 为什么必须复用现有选择路径：直接用名字下发会重现"内核静默退回第一个预设"那类 bug，
  // 所以每一项都先「按名在内核候选表里定位下标」（不在表内 = 不存在/不兼容 -> 回退），
  // 再用现有「按索引下发 + 内核校验 + 失败回滚」路径。
  private restorePresetState(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      hilog.error(0x0000, LOG_TAG, '恢复预设跳过：获取上下文失败');
      return;
    }
    const filesDir: string = ctx.filesDir;
    const snap: PresetSnapshot | undefined = PresetPersist.load(filesDir);
    if (snap === undefined) {
      // 首次启动：没有记录，属正常情况
      PresetPersist.log(filesDir, '预设持久化 恢复 结果=无记录(首次启动) 跳过');
      return;
    }
    if (snap.printer === '' && snap.process === '' && snap.filament === '' && snap.bedType === '') {
      PresetPersist.log(filesDir, '预设持久化 恢复 结果=无记录(空) 跳过');
      return;
    }

    this.restoring = true;
    const falls: string[] = [];
    try {
      // ① 打印机：先恢复机型（工艺/耗材的兼容候选依赖它）
      const pi: number = this.printerOptions.indexOf(snap.printer);
      if (snap.printer !== '') {
        if (pi < 0) {
          falls.push(`打印机「${snap.printer}」已不存在`);
        } else if (pi !== this.printerIndex) {
          this.onPrinterChanged(pi);
          // onPrinterChanged 内部失败会回滚并 syncSelection：用内核真值判断是否真的换上
          if ((this.printerOptions[this.printerIndex] ?? '') !== snap.printer) {
            falls.push(`打印机「${snap.printer}」不被内核接受`);
          }
        }
      }

      // ② 工艺：在当前机型的兼容候选表里按名定位；不在表内 = 不存在或不兼容 -> 回退默认
      if (snap.process !== '') {
        const ri: number = this.processOptions.indexOf(snap.process);
        if (ri < 0) {
          falls.push(`工艺「${snap.process}」不可用`);
        } else if ((this.processOptions[this.processIndex] ?? '') !== snap.process) {
          this.applyIndexSelection(1, ri);
          if ((this.processOptions[this.processIndex] ?? '') !== snap.process) {
            falls.push(`工艺「${snap.process}」不被内核接受`);
          }
        }
      }

      // ③ 耗材：同上
      if (snap.filament !== '') {
        const fi: number = this.filamentOptions.indexOf(snap.filament);
        if (fi < 0) {
          falls.push(`耗材「${snap.filament}」不可用`);
        } else if ((this.filamentOptions[this.filamentIndex] ?? '') !== snap.filament) {
          this.applyIndexSelection(2, fi);
          if ((this.filamentOptions[this.filamentIndex] ?? '') !== snap.filament) {
            falls.push(`耗材「${snap.filament}」不被内核接受`);
          }
        }
      }

      // ④ 打印板：在 curr_bed_type 的枚举项里按名定位；不在表内 = 该板型在当前机型不可用 -> 回退默认板
      if (snap.bedType !== '') {
        const bi: number = this.plateOptions.indexOf(snap.bedType);
        if (bi < 0) {
          falls.push(`打印板「${snap.bedType}」在当前机型不可用`);
        } else if (bi !== this.plateIndex) {
          this.setPlateParam(bi);   // 复用现有：写回 curr_bed_type 参数
        }
      }
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, LOG_TAG, '恢复预设异常: %{public}s', msg);
      falls.push('恢复过程异常');
    } finally {
      this.restoring = false;
    }

    const result: string = falls.length === 0 ? '成功' : `回退(${falls.join('；')})`;
    PresetPersist.log(filesDir,
      `预设持久化 恢复 结果=${result} 机=${this.printerOptions[this.printerIndex] ?? ''} ` +
      `工=${this.processOptions[this.processIndex] ?? ''} 耗=${this.filamentOptions[this.filamentIndex] ?? ''}`);
    // 把恢复后的真实选择（含回退结果）回写，保证下次启动与本次实际一致
    this.savePresetState('恢复后回写');
  }

  // ===== 3MF 导入设置应用（文件 > 本机持久化）=====

  // @Watch：ThreeMfImport 发布了新的导入设置（序号 +1）
  private onImportSettingsSeqChanged(): void {
    this.applyImportSettings();
  }

  // 应用待处理的导入设置。三处保证：
  //   ① 预设未就绪时**不应用**（此刻候选表还是占位值，按名定位必然失败）——
  //      等 buildPresetSelectors() 就绪后会再调一次，所以不会漏；
  //   ② 同一份设置只应用一次（settings.applied），避免面板重挂载时覆盖用户后续编辑；
  //   ③ 每一项都走现成的「按名定位 → 按索引下发 → 内核校验 → 失败回滚」，失败只记日志不误导。
  private applyImportSettings(): void {
    const s: Import3mfSettings | undefined = AppStorage.get<Import3mfSettings>('importSettings');
    if (s === undefined || s.applied) {
      return;
    }
    if (!this.presetReady) {
      hilog.info(0x0000, LOG_TAG, '导入设置待应用：预设尚未就绪（就绪后会自动应用）');
      return;
    }
    s.applied = true;
    const falls: string[] = [];

    // ① 机型：候选表里按精确名定位 → 现有换机流程（内核校验 + 失败回滚）
    if (s.printer !== '') {
      const pi: number = this.printerOptions.indexOf(s.printer);
      if (pi < 0) {
        falls.push(`机型「${s.printer}」不可用`);
      } else if (pi !== this.printerIndex) {
        this.onPrinterChanged(pi);
        if ((this.printerOptions[this.printerIndex] ?? '') !== s.printer) {
          falls.push(`机型「${s.printer}」不被内核接受`);
        }
      }
    }

    // ② 工艺 / ③ 耗材：候选表里按精确名定位 → 现有按索引下发流程
    if (s.process !== '') {
      const ri: number = this.processOptions.indexOf(s.process);
      if (ri < 0) {
        falls.push(`工艺「${s.process}」不可用`);
      } else if ((this.processOptions[this.processIndex] ?? '') !== s.process) {
        this.applyIndexSelection(1, ri);
        if ((this.processOptions[this.processIndex] ?? '') !== s.process) {
          falls.push(`工艺「${s.process}」不被内核接受`);
        }
      }
    }
    if (s.filament !== '') {
      const fi: number = this.filamentOptions.indexOf(s.filament);
      if (fi < 0) {
        falls.push(`耗材「${s.filament}」不可用`);
      } else if ((this.filamentOptions[this.filamentIndex] ?? '') !== s.filament) {
        this.applyIndexSelection(2, fi);
        if ((this.filamentOptions[this.filamentIndex] ?? '') !== s.filament) {
          falls.push(`耗材「${s.filament}」不被内核接受`);
        }
      }
    }

    // ④ 打印板：内核床型名 → curr_bed_type 的下标（用内核枚举名与中文标签同序这一点）
    if (s.bed !== '') {
      const bi: number = this.bedIndexByName(s.bed);
      if (bi < 0) {
        falls.push(`打印板「${s.bed}」在当前机型不可用`);
      } else if (bi !== this.plateIndex) {
        this.setPlateParam(bi);
      }
    }

    // ⑤ 参数逐项写回（文件 > 预设）：写回后与 presetBaseline 不同 → 现有逻辑自动标橙
    const wb: WriteBackStat = this.writeBackImportedParams(s);
    this.modifyRev = this.modifyRev + 1;

    // 导入成功后「当前状态即新的上次使用」：按现有 PresetPersist 机制保存一次
    this.savePresetState('导入3mf');

    const result: string = falls.length === 0 ? '成功' : `回退(${falls.join('；')})`;
    const text: string = `导入3mf 应用设置 结果=${result} 写回参数 变更=${wb.changed} 已一致=${wb.same} ` +
      `机=${this.printerOptions[this.printerIndex] ?? ''} 工=${this.processOptions[this.processIndex] ?? ''} ` +
      `耗=${this.filamentOptions[this.filamentIndex] ?? ''} 板=${this.plateOptions[this.plateIndex] ?? ''}`;
    hilog.info(0x0000, LOG_TAG, '%{public}s', text);
    // 三通道落地（hilog + 应用内日志 + diag 文件），与导入日志同一出口
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      ThreeMfImport.log(ctx.filesDir, `${text}（来源=${s.source}）`);
    }
    if (falls.length > 0) {
      promptAction.showToast({ message: `导入设置部分回退：${falls.join('；')}` });
    }
  }

  // 把导入文件里的参数逐项写回表单：只有表单里存在的 key 才写（内核里没有的不造假项）。
  // 枚举用内核下标（与 options/values 同序），数值带容差比较，避免"没变也写"打断高亮语义。
  // 返回统计（实际变更 / 已一致），供日志如实呈现，不再用一个数字笼统表示。
  private writeBackImportedParams(s: Import3mfSettings): WriteBackStat {
    // 导入的是工程级设置：一律写全局参数（对象模式下的对象覆盖不参与）
    this.globalMode = true;
    const stat: WriteBackStat = new WriteBackStat();
    const n: number = Math.min(s.keys.length, s.values.length);
    for (let i = 0; i < n; i++) {
      const key: string = s.keys[i];
      const v: number = s.values[i];
      if (key === 'curr_bed_type') {
        // 打印板已由 ④ 单独按「内核床型名」定位（更稳：名不在表内即判为当前机型不支持）。
        // 这里跳过只为避免同一项写两次；下标语义现在已与内核同源
        // （内核 config_flat_json 发的就是 enum_values 下标），两条路等价。
        continue;
      }
      if (!Number.isFinite(v)) {
        // 非数值（coString 型选项，如 gcode 模板/注释）在表单里不是数值控件，跳过即可。
        // 这里刻意不逐条打日志：一份工程配置里字符串项有几百个，打日志会刷屏。
        continue;
      }
      for (const p of this.allParams) {
        if (p.key !== key) {
          continue;
        }
        // differ = 文件值与本表单当前值不一致（需要变更）；否则记为"已一致"
        if (p.type === 4) {
          const idx: number = Math.round(v);
          if (idx < 0 || idx >= p.options.length) {
            break; // 下标越界：既非变更也非"已一致"，不计入统计
          }
          if (Math.round(p.value) !== idx) {
            this.updateValue(p, idx);
            stat.changed++;
          } else {
            stat.same++;
          }
        } else if (p.type === 3) {
          const b: number = v === 0 ? 0 : 1;
          if (p.value !== b) {
            this.updateValue(p, b);
            stat.changed++;
          } else {
            stat.same++;
          }
        } else if (Math.abs(p.value - v) > NUM_EPS) {
          this.updateValue(p, v);
          stat.changed++;
        } else {
          stat.same++;
        }
        break;
      }
    }
    return stat;
  }

  // 内核床型名（如 "Cool Plate"）→ 打印板下拉下标。
  // 依据：BuildSchemaJson 给枚举项的 values = 内核 enum_values（顺序 = 内核下标），
  // 而 plateOptions 用的是同一项的中文标签数组（两者等长同序），所以下标可直接互通。
  private bedIndexByName(name: string): number {
    for (const p of this.allParams) {
      if (p.key !== 'curr_bed_type') {
        continue;
      }
      const i: number = p.values.indexOf(name);
      if (i >= 0 && i < this.plateOptions.length) {
        return i;
      }
      break;
    }
    // 兜底：也许 options 本身就是内核名
    return this.plateOptions.indexOf(name);
  }

  // 下拉 onSelect 的"渲染时冻结回调"工厂。
  //
  // 为什么需要工厂而不在 onSelect 箭头函数体里直接读 this.processOptions：
  // ArkUI 的 onSelect 回调体是在**用户点击这一刻**才执行的，直接读 this.* 拿到的是"点击时"的最新列表；
  // 而用户看到并点中的是"渲染时"的那份列表。两者若期间被刷新过，同一个下标就落到了不同预设上
  // （用户点名字 A、下发成 B）。工厂的入参在 build() 求值，因此返回的闭包把"渲染时的列表 + 代次"
  // 一起冻结了下来，正好作为点击时对照的基准。
  private dropdownHandler(kind: number, shownOptions: string[], shownGen: number): (i: number) => void {
    return (i: number): void => {
      this.dispatchDropdownPick(kind, i, shownOptions, shownGen);
    };
  }

  // 候选表最新列表（kind: 0=打印机 / 1=工艺 / 2=耗材）
  private optionsForKind(kind: number): string[] {
    if (kind === 0) { return this.printerOptions; }
    if (kind === 1) { return this.processOptions; }
    return this.filamentOptions;
  }

  // 下拉选择的统一入口：先做「下标漂移」校验，再分派到各自的处理流程。
  //
  // 规则：用户点中的是"渲染时所显示列表"的第 i 项名字 shownName；
  //   * 若当前候选表代次仍等于渲染时冻结的代次 -> 列表没换过，下标语义一致，正常按索引下发；
  //   * 若代次已变化 -> 说明列表在期间被重建过，旧下标不再可信，改用 shownName 在最新列表里重新定位；
  //     定位不到（该预设已不属于当前机型）则提示并**不下发** —— 绝不用漂移的下标去选预设。
  private dispatchDropdownPick(kind: number, i: number, shownOptions: string[], shownGen: number): void {
    const shownName: string = shownOptions[i] ?? '';
    let index: number = i;
    if (shownGen !== this.optionsGen) {
      const latest: string[] = this.optionsForKind(kind);
      const hit: number = latest.indexOf(shownName);
      if (hit < 0) {
        hilog.warn(0x0000, COMPAT_TAG,
          '下拉选择被丢弃(kind=%{public}d)：用户看到的「%{public}s」已不在第%{public}d代候选表内，不下发',
          kind, shownName, this.optionsGen);
        promptAction.showToast({ message: '该预设不适用于当前机型' });
        return;
      }
      hilog.info(0x0000, COMPAT_TAG,
        '下拉选择按名重定位(kind=%{public}d)：「%{public}s」渲染下标=%{public}d -> 最新下标=%{public}d',
        kind, shownName, i, hit);
      index = hit;
    }
    if (kind === 0) {
      // 换机型走专用流程：内核先真的换机 -> 用内核回读的机型名取兼容候选 -> 再下发候选。
      // 打印板尺寸也在这条流程的末尾（内核切完机型之后）从新打印机预设读取。
      this.onPrinterChanged(index);
    } else if (kind === 1) {
      // 候选来自内核、下标即内核顺序：把（校验后的）下标回传给内核选，不回传名字
      this.processIndex = index;
      this.applyIndexSelection(1, index);
    } else {
      // 耗材同理：只回传下标
      this.filamentIndex = index;
      this.applyIndexSelection(2, index);
    }
  }

  // 打印机下拉变更。顺序严格为：
  //   ① 按索引把机型下发给内核（只动机型，工艺/耗材不动）；
  //   ② 内核真的切完之后，用内核候选表（kind 1/2，内核按它自己的当前机型产出）刷新工艺/耗材候选；
  //   ③ 界面选中项与内核真值不一致时按索引下发，令「界面显示 == 内核配置」。
  //
  // 为什么必须先切机型再取候选：候选属于"新机型"，权威候选只有内核切完才能给出。
  // 由于候选由内核按当前机型自己产出（界面不传名字），不存在"把旧机型的列表当新机型用"。
  private onPrinterChanged(i: number): void {
    if (!this.presetReady) { return; }

    const res: PresetIndexSelectResult | undefined = this.callSelectByIndex(0, i);
    if (res === undefined) { return; }
    if (!res.ok) {
      hilog.error(0x0000, LOG_TAG, '打印机切换未被内核接受: %{public}s', res.message);
      // 失败即回滚：C++ 侧已把内核恢复到切换前的机型/工艺/耗材，界面同步回滚到 selected，绝不留在错值上
      promptAction.showToast({ message: res.rolledBack ? '该预设不适用于当前机型' : `切换打印机失败：${res.message}` });
      this.syncSelection(res.selected);
      this.clearOverridesOnPresetChange();
      this.loadSchema();
      this.applyPrinterPlate(res.selected.printer);
      return;
    }
    this.printerIndex = i;

    // ② 候选表按内核当前机型重取（内核自己给的，界面不传名字）
    this.refreshProcessFilamentOptions(res.selected.printer);

    // ③ 与内核对齐工艺/耗材：一致时不下发
    this.alignProcessFilamentWithKernel();

    // 换机型 = 预设基准变化：清掉旧的用户覆盖（它们属于上一套预设），橙色随之清除。
    this.clearOverridesOnPresetChange();
    this.loadSchema();
    // 打印板必须在"内核真的切完机型之后"再取：此刻 printable_area 才属于新打印机。
    // 换机型时板子要跟着变大变小，靠这里刷新 plateW/plateH（3D 视图 @Watch 会重建板/网格并重新取景）。
    this.applyPrinterPlate(res.selected.printer);
    // 换机型 = 预设变化：广播一次参数变化（3D 页据此重算悬空告警，并重建板前端辅助线）。
    // 为什么必须广播：不同机型的 machine_start_gcode 不同；若新旧机型盘面尺寸恰好相同
    // （如 A1 与 X1C 都是 256×256），plateW/plateH 的 @Watch 不会触发，辅助线就会残留旧机型的。
    const rev: number = AppStorage.get<number>('paramRevSeq') ?? 0;
    AppStorage.setOrCreate<number>('paramRevSeq', rev + 1);
    // 换机成功后写盘：机型 + 内核随之对齐后的工艺/耗材一起落盘（板型不变）
    this.savePresetState('切换打印机');
  }

  // 切换打印机 -> 用内核当前打印机预设的真实 printable_area 刷新 3D 视图的打印板尺寸。
  //
  // 之前这里查的是一份硬编码机型表（A1 mini/H2D/H2S 之外一律 256×256），A2L 不在表里，
  // 所以换到 A2L 后打印板仍是 256×256（=A1/X1C）。现在改从内核取真值；只在预设未就绪
  //（拿不到内核值时）退到旧表兜底，避免出现无板可画的中间态。
  private applyPrinterPlate(model: string): void {
    if (!this.presetReady) {
      // 预设未就绪：内核还没有打印机预设，此时拿不到真值；等 buildPresetSelectors() 就绪后会再刷新一次
      return;
    }
    try {
      const bed: PrinterBed = JSON.parse(SlicerService.printerBed()) as PrinterBed;
      if (bed.ok && bed.bbox.length === 4) {
        const w: number = bed.bbox[2] - bed.bbox[0];
        const d: number = bed.bbox[3] - bed.bbox[1];
        if (w > 0 && d > 0) {
          AppStorage.setOrCreate<number>('plateW', w);
          AppStorage.setOrCreate<number>('plateH', d);
          // 机型名（内核打印机预设名）也下发：3D 页的板形/单喷嘴区日志按机型自证，避免同名板模型的不同机型被去重吞掉。
          AppStorage.setOrCreate<string>('platePrinter', bed.printer);
          // 该机型的开源板模型名（预设 bed_model）+ 单喷嘴专属区（由 extruder_printable_area 真值算得）。
          // 板模型/专属区变了要重建盘面：即使 plateW/H 与上一机型相同（例如都是 256×256），
          // 也靠 plateRev 自增让 3D 视图的 @Watch 一定触发（修「同尺寸不重建」的漏洞）。
          AppStorage.setOrCreate<string>('plateBedModel', bed.bedModel !== undefined ? bed.bedModel : '');
          const zones: string = this.computeNozzleZones(bed.extruderAreas);
          AppStorage.setOrCreate<string>('plateZones', zones);
          this.bumpPlateRev();
          // 逐跳自证：内核打印机预设名 / printer_model / bed_model / 厂商解析 / 专属区条数 / 归属区 JSON。
          hilog.info(0x0000, LOG_TAG,
            '打印板取自内核打印机预设: %{public}s = %{public}s×%{public}s mm 高%{public}s 机型=%{public}s 板模型=%{public}s(厂商=%{public}s 模型表=%{public}d 命中=%{public}s 来源=%{public}s) 专属区数=%{public}d 单喷嘴区=%{public}s',
            bed.printer, w.toFixed(1), d.toFixed(1), bed.height.toFixed(1),
            (bed.printerModel !== undefined && bed.printerModel.length > 0) ? bed.printerModel : '(无)',
            (bed.bedModel !== undefined && bed.bedModel.length > 0) ? bed.bedModel : '(无)',
            (bed.bedVendorId !== undefined && bed.bedVendorId.length > 0) ? bed.bedVendorId : '(无)',
            bed.bedModelsCount !== undefined ? bed.bedModelsCount : -1,
            (bed.bedModelId !== undefined && bed.bedModelId.length > 0) ? bed.bedModelId : '(无)',
            (bed.bedModelSrc !== undefined && bed.bedModelSrc.length > 0) ? bed.bedModelSrc : '(无)',
            bed.extruderAreaCount !== undefined ? bed.extruderAreaCount : -1,
            zones.length > 0 ? zones : '(无)');
          return;
        }
      }
      hilog.warn(0x0000, LOG_TAG, '内核打印板不可用(%{public}s)，退回机型硬编码尺寸', bed.message);
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, '打印板查询失败，退回机型硬编码尺寸: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    // 内核查不到板：退回机型硬编码尺寸，且明确「无板模型 / 无单喷嘴区」（不编造）
    const ps: PlateSize = plateSizeForPrinter(model);
    AppStorage.setOrCreate<number>('plateW', ps.w);
    AppStorage.setOrCreate<number>('plateH', ps.h);
    AppStorage.setOrCreate<string>('platePrinter', model);
    AppStorage.setOrCreate<string>('plateBedModel', '');
    AppStorage.setOrCreate<string>('plateZones', '');
    this.bumpPlateRev();
  }

  // 盘面重建代次 +1：3D 视图订阅它，切机型时即使 plateW/plateH 没变也一定重建盘面。
  private bumpPlateRev(): void {
    const rev: number = AppStorage.get<number>('plateRev') ?? 0;
    AppStorage.setOrCreate<number>('plateRev', rev + 1);
  }

  // 由 extruder_printable_area（每个喷嘴的可达打印区，官方预设真值）算出「仅某个喷嘴可打印」的专属带。
  // 口径：专属区 = 该喷嘴可达区 \ 所有喷嘴可达区的交集（矩形近似）。单喷嘴机型（<2 个区）→ 返回空串，
  // 渲染侧据此不画任何专属带。左/右按该带中心相对整板中心的位置判定。
  private computeNozzleZones(areas: number[][][]): string {
    if (areas === undefined || areas.length < 2) {
      return '';
    }
    const boxes: number[][] = [];   // [minX, minY, maxX, maxY]
    for (const poly of areas) {
      if (poly.length < 2) {
        return '';
      }
      let mnx: number = poly[0][0];
      let mny: number = poly[0][1];
      let mxx: number = poly[0][0];
      let mxy: number = poly[0][1];
      for (const p of poly) {
        mnx = Math.min(mnx, p[0]); mny = Math.min(mny, p[1]);
        mxx = Math.max(mxx, p[0]); mxy = Math.max(mxy, p[1]);
      }
      boxes.push([mnx, mny, mxx, mxy]);
    }
    // 交集（所有喷嘴都能到的区域）
    let sx0: number = -1e9, sy0: number = -1e9, sx1: number = 1e9, sy1: number = 1e9;
    let bedMinX: number = 1e9, bedMaxX: number = -1e9;
    for (const b of boxes) {
      sx0 = Math.max(sx0, b[0]); sy0 = Math.max(sy0, b[1]);
      sx1 = Math.min(sx1, b[2]); sy1 = Math.min(sy1, b[3]);
      bedMinX = Math.min(bedMinX, b[0]); bedMaxX = Math.max(bedMaxX, b[2]);
    }
    const bedCx: number = (bedMinX + bedMaxX) * 0.5;
    const zones: string[] = [];
    for (const b of boxes) {
      const zy0: number = Math.max(b[1], sy0);
      const zy1: number = Math.min(b[3], sy1);
      if (zy1 <= zy0) {
        continue;
      }
      // 左侧专属：该喷嘴能到「交集左界」以左
      if (b[0] < sx0 - 1e-6) {
        const side: string = ((b[0] + sx0) * 0.5 < bedCx) ? 'left' : 'right';
        zones.push(`{"minX":${b[0]},"maxX":${sx0},"minY":${zy0},"maxY":${zy1},"side":"${side}"}`);
      }
      // 右侧专属：该喷嘴能到「交集右界」以右
      if (b[2] > sx1 + 1e-6) {
        const side: string = ((sx1 + b[2]) * 0.5 < bedCx) ? 'left' : 'right';
        zones.push(`{"minX":${sx1},"maxX":${b[2]},"minY":${zy0},"maxY":${zy1},"side":"${side}"}`);
      }
    }
    if (zones.length === 0) {
      return '';
    }
    return `{"ox":${bedMinX},"oy":${sy0},"zones":[${zones.join(',')}]}`;
  }

  // 参数视图档位（0 简易 / 1 高级）：由 SliceParamStore 落盘记忆（面板随页签切换会被销毁重建，
  // 档位若只存在内存，用户切一次页签就被重置回简易）。kSchema 的 mode 字段（0 简易 / 1 高级）
  // 一直由 C++ 带出却从未在 ETS 侧被消费 —— 两档形同虚设；这里开始真正生效（见 currentSubGroups 的过滤）。
  @State paramViewMode: number = SliceParamStore.getParamViewMode();

  // 当前是否有「可复位的修改」（决定复位按钮的亮度与是否需要提示）
  //   全局模式 = 有全局手改值；对象模式 = 当前对象有参数覆盖。
  private hasOverridesToReset(): boolean {
    if (this.globalMode) {
      return SliceParamStore.userOverrideCount() > 0;
    }
    const oid: number = this.currentObjectId();
    if (oid < 0) {
      return false;
    }
    const b: Map<string, number> | undefined = SliceParamStore.getObjectOverrides().get(oid);
    return b !== undefined && b.size > 0;
  }

  // 复位参数（一键回到预设原值）。作用范围跟随当前模式，避免「按钮点了不知道清了什么」：
  //   全局模式：清掉全部全局手改值 → 重新拉内核快照 → 所有参数回到当前预设的原值（橙色高亮同时消失）；
  //   对象模式：只清掉当前对象的参数覆盖（对象本身保留）→ 该对象回到全局参数。
  // 为什么用「重新 loadSchema」而不是自己逐项回填：内核 config 快照就是这个预设的权威原值，
  // 拉它一次最省事也最不容易回填错（向量/枚举/布尔三种形态的取值规则都在那一处）。
  private resetToPreset(): void {
    const objMode: boolean = !this.globalMode;
    if (!this.hasOverridesToReset()) {
      promptAction.showToast({ message: objMode ? '当前对象没有参数覆盖' : '当前没有手动修改的参数' });
      return;
    }
    const msg: string = objMode
      ? '将清除当前对象的参数覆盖，该对象恢复为使用全局参数。'
      : '将清除全部手动修改的切片参数，恢复为当前预设的原值。';
    // 【复位必须保住的项】「打印板类型」就是参数 curr_bed_type（顶部下拉通过 setPlateParam 写它），
    // 它还驱动 3D 里打印板的外观（AppStorage plateBedModel）与四套板温的选用。
    // 它属于「当前在用哪块板」的环境选择，不是用户在参数面板里调出来的工艺参数 ——
    // 若被复位连坐冲掉，表现就是「点了复位，打印板也跟着换了」（用户实测反馈）。
    const keepBedName: string = this.plateOptions[this.plateIndex] ?? '';
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '复位参数',
        message: msg,
        buttons: [
          { text: '取消', color: '#9A9AA4' },
          { text: '复位', color: '#FF7A45' }
        ]
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index !== 1) {
          return;
        }
        if (objMode) {
          SliceParamStore.clearObjectOverrides(this.currentObjectId());
        } else {
          SliceParamStore.clearUserOverrides(); // 内部同步落盘（写空表），重启也不会复活
        }
        this.loadSchema(); // 值 + 高亮基准 + modifyRev 一起刷新
        // 板型恢复为用户刚才的选择（按名定位，避免枚举顺序变化时错位）
        if (!objMode && keepBedName !== '') {
          const bi: number = this.plateOptions.indexOf(keepBedName);
          if (bi >= 0) {
            this.setPlateParam(bi);
          }
        }
        promptAction.showToast({ message: objMode ? '已恢复为全局参数' : '已恢复为预设原值' });
      }).catch((err: Error) => {
        hilog.error(0x0000, LOG_TAG, 'reset: showDialog failed %{public}s', `${err.name}: ${err.message}`);
      });
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, 'reset: showDialog threw %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 长按参数名 → 参数信息（说明 + 结构性信息）。
  // 为什么用对话框而不是 toast：toast 两行就截断，而这里要容纳「说明 + 当前值 + 范围/可选 + 分类」。
  // 说明来源优先级：ParamHelp 手写详解 → 内核 tooltip（仅在它不只是在重复参数名时采用）。
  // 用户反馈过「所谓说明就是显示参数名」——所以这里保证一定说出「它是什么、现在多少、能填多少」。
  private showParamInfo(p: SliceParam): void {
    const lines: string[] = [];
    const explain: string = helpFor(p.key);
    if (explain.length > 0) {
      lines.push(explain);
    } else if (p.tooltip !== undefined && p.tooltip.length > 0 && p.tooltip !== p.label) {
      lines.push(p.tooltip);
    }
    lines.push(`当前值：${this.displayValue(p)}${p.type === 4 ? '' : p.unit}`);
    if (p.type === 4 && p.options.length > 0) {
      lines.push(`可选：${p.options}`);
    } else if (p.type !== 3 && p.max > p.min) {
      lines.push(`取值范围：${p.min} ~ ${p.max}${p.unit}`);
    }
    lines.push(`分类：${p.group} / ${p.subgroup}`);
    lines.push(`内核参数：${p.key}`);
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: p.label,
        message: lines.join('\n'),
        buttons: [{ text: '知道了', color: '#00C48C' }]
      }).catch((err: Error) => {
        hilog.error(0x0000, LOG_TAG, 'paramInfo: showDialog failed %{public}s', `${err.name}: ${err.message}`);
      });
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, 'paramInfo: showDialog threw %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 内核兜底项的中文化：手写中文表里没有、由内核 PrintConfigDef 带出来的那批参数，
  // 内核 label/tooltip 都是英文，这里用**官方译法**换成中文。
  //
  // 判定「是不是内核兜底项」用 C++ 显式打的 src 标记（比在两侧各维护一个中文字符串前缀去匹配可靠）；
  // `subgroup` 那边 C++ 给的是内核原分类（英文），这里翻译后拼成「内核 · <中文分类>」。
  // 命中不到译法就保留英文（只做有据可查的翻译，不自己编）。
  private localizeKernelItems(arr: SliceParam[]): void {
    for (const p of arr) {
      if (p.src !== 'kernel') {
        continue;
      }
      p.label = zhOf(p.label);
      const cat: string = p.subgroup.length > 0 ? p.subgroup : '其他';
      p.subgroup = KERNEL_SUBGROUP_PREFIX + zhOf(cat);
      // 提示里带上内核原始 key：中文名是官方译法，但排障/对照文档时需要知道对应哪个配置项
      p.tooltip = `${p.key} — ${zhOf(p.tooltip)}`;
      // 枚举候选项也是内核英文名（如 nearest），一并过官方译法；
      // 注意只改 options（显示用），values 是写回时的「下标 → 内核实名」凭据，绝不能动。
      for (let i = 0; i < p.options.length; i++) {
        p.options[i] = zhOf(p.options[i]);
      }
    }
  }

  // 预设变化后重新取内核参数表（哪些参数存在 + 当前值），并把表单刷新一遍
  private loadSchema(): void {
    try {
      const json: string = SlicerService.getSliceParamSchema();
      const arr: SliceParam[] = JSON.parse(json) as SliceParam[];
      this.localizeKernelItems(arr);
      this.refreshValuesFromKernel(arr);
      this.logLayerHeightShown(arr);
      this.allParams = arr;

      // 记录「预设默认值」作为高亮基准：此刻 p.value 已被 refreshValuesFromKernel 用内核 config 快照
      // 覆盖，正是"该预设的默认值"（内核回读，不自编）。换预设时这里重置，橙色随之自动清除。
      this.presetBaseline.clear();
      for (const p of arr) {
        this.presetBaseline.set(p.key, p.value);
      }
      // 【回放用户覆盖值】基准（预设默认值）采集完之后再回放 —— 这样「标橙」判定仍是
      // 「当前有效值 vs 预设基准」，重建面板后用户手改的值与橙色高亮一并还原，而不是被内核快照抹掉。
      const replayed: number = SliceParamStore.applyUserOverrides(arr);
      if (replayed > 0) {
        hilog.info(0x0000, LOG_TAG, '参数表重建：回放用户覆盖值 %{public}d 条（跨页面存活）', replayed);
      }
      // 【耗材编辑的覆盖值】按「当前耗材预设」分桶叠加到参数表 —— 面板与「打印板」旁的
      // 床温摘要必须与耗材编辑一致（否则改完温度右侧仍亮出厂预设值）。
      // 放在用户覆盖之后：两者都是用户显式改动，同名键以耗材级为准（与下发顺序一致）。
      // 切桶不依赖 HostContext（目录只在读盘时用一次；读不到就沿用启动时读好的那张表）。
      const fcat = SlicerService.getCatalog();
      const filName: string = fcat !== undefined ? fcat.selected.filament : '';
      const ctx = this.getUIContext().getHostContext();
      SliceParamStore.ensureFilamentOverrides(ctx !== undefined ? ctx.filesDir : '', filName);
      const flReplayed: number = SliceParamStore.applyFilamentOverridesToParams(arr);
      const flTotal: number = SliceParamStore.filamentOverrideCount();
      if (flTotal > 0 || flReplayed > 0) {
        // 「桶内条数」与「真正叠到参数表的条数」分开报：两者不等说明有键不在参数表里
        //（典型：部分耗材预设只显式定义 hot/textured 两套床温，其余三套走继承、快照里没有）。
        hilog.info(0x0000, LOG_TAG, '耗材覆盖 桶=%{public}s 桶内=%{public}d 叠加=%{public}d',
          SliceParamStore.filamentPresetName(), flTotal, flReplayed);
      }
      this.modifyRev = this.modifyRev + 1;   // 基准变了：让高亮缓存失效并重算

      const gs: string[] = [];
      for (const p of arr) {
        // 打印板类型的 group 由顶部下拉承载，不生成 tab
        if (p.group === PLATE_GROUP) { continue; }
        if (gs.indexOf(p.group) < 0) {
          gs.push(p.group);
        }
      }
      this.groups = gs;
      if (this.activeGroup >= gs.length) { this.activeGroup = 0; }
      this.syncPlateFromParam();
      SliceParamStore.setParams(this.allParams);
      // 参数表就绪后才知道床型枚举 → 此时才能把「当前盘独立床型」的下标定位准确
      this.syncPlateBedIndex();
      // 让 ForEach 的 key 全部变化 -> 重建每一行，新值才会真的显示出来
      this.schemaRev = this.schemaRev + 1;
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, '参数表加载失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      this.allParams = [];
      this.groups = [];
      SliceParamStore.setParams([]);
    }
  }

  // 再拉一次内核 config 快照，逐项覆盖表单的值。
  // 三种形态都要认（否则回填会静默失败）：
  //   * 布尔项 -> JSON bool
  //   * 向量型选项（bridge_speed / sparse_infill_speed ... 是 coFloats）-> 数组首元素（数字）
  //   * 枚举项 -> 内核下标（也用内核实名反查一次，兼容发字符串的情况）
  private refreshValuesFromKernel(arr: SliceParam[]): void {
    let snap: ConfigSnapshot | undefined = undefined;
    try {
      snap = ConfigSnapshot.parse(SlicerService.configSnapshot());
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, 'config 快照解析失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return;
    }
    if (snap === undefined) {
      return;
    }
    for (const p of arr) {
      if (p.type === 4) {
        const name: string | undefined = snap.texts.get(p.key);
        if (name !== undefined) {
          const i: number = p.values.indexOf(name);
          if (i >= 0) { p.value = i; }
          continue;
        }
        const n: number | undefined = snap.numbers.get(p.key);
        if (n !== undefined && n >= 0 && n < p.options.length) { p.value = n; }
      } else if (p.type === 3) {
        const b: number | undefined = snap.booleans.get(p.key);
        if (b !== undefined) {
          p.value = b;
        } else {
          const n: number | undefined = snap.numbers.get(p.key);
          if (n !== undefined) { p.value = n === 0 ? 0 : 1; }
        }
      } else {
        const n: number | undefined = snap.numbers.get(p.key);
        if (n !== undefined) { p.value = n; }
      }
    }
  }

  // 打印板下拉的选项/当前值都取自参数 curr_bed_type（它的 options 已由内核 enum 顺序校准）
  private syncPlateFromParam(): void {
    for (const p of this.allParams) {
      if (p.key !== 'curr_bed_type') { continue; }
      if (p.options.length > 0) { this.plateOptions = p.options; }
      this.plateIndex = p.value >= 0 && p.value < this.plateOptions.length ? p.value : 0;
      return;
    }
  }

  // 下拉选打印板 -> 写回参数（collectParamsJson 会把它带给内核）
  private setPlateParam(i: number): void {
    this.plateIndex = i;
    for (const p of this.allParams) {
      if (p.key === 'curr_bed_type') {
        this.updateValue(p, i);
        // 板型落定即写盘
        this.savePresetState('切换打印板');
        return;
      }
    }
    // 参数里没有 curr_bed_type（异常情况）：也要把"当前板型"记下来，避免丢
    this.savePresetState('切换打印板(无参项)');
  }

  // ---- 盘级床型（当前盘独立设置；空 = 跟随全局）----
  // 为什么放这里：盘条只有 76vp 宽，塞不下下拉；而本面板的「打印板」一行正是床型所在，
  // 多盘时在它下面多一行「盘 N 床型」，语义与桌面版「每盘床型」一致。
  private onActivePlateForBed(): void {
    this.syncPlateBedIndex();
  }

  private syncPlateBedIndex(): void {
    if (this.activePlate <= 0) {
      this.plateBedIndex = 0;
      return;
    }
    const own: string = plateBedName(this.activePlate);
    if (own.length === 0) {
      this.plateBedIndex = 0;
      return;
    }
    const vals: string[] = bedOptionValues();
    const i: number = vals.indexOf(own);
    this.plateBedIndex = i >= 0 ? i + 1 : 0;
  }

  // 选择器候选：第 0 项「跟随全局（当前板名）」，其后与 plateOptions 同序
  private plateBedSelectorLabels(): string[] {
    const out: string[] = [];
    const g: string = this.plateOptions[this.plateIndex] ?? '';
    out.push(g.length > 0 ? `跟随全局（${g}）` : '跟随全局');
    for (const l of this.plateOptions) {
      out.push(l);
    }
    return out;
  }

  private pickPlateBed(i: number): void {
    if (this.activePlate <= 0) {
      return;
    }
    this.plateBedIndex = i;
    const vals: string[] = bedOptionValues();
    if (i <= 0 || i - 1 >= vals.length) {
      plateSetBed(this.activePlate, '');
      promptAction.showToast({ message: `盘 ${this.activePlate} 床型：跟随全局` });
      return;
    }
    plateSetBed(this.activePlate, vals[i - 1]);
    promptAction.showToast({ message: `盘 ${this.activePlate} 床型：${this.plateOptions[i - 1] ?? vals[i - 1]}` });
  }

  // 按参数键取数值（取不到返回 undefined）；用于显示板温档位
  private numParamOf(key: string): number | undefined {
    for (const p of this.allParams) {
      if (p.key === key) { return p.value; }
    }
    // 回退：部分耗材预设只显式定义 hot/textured 两套床温，其余三套（工程材料/低温/SuperTack）
    // 靠继承、不进内核配置快照 → schema 里没有这一项 → 摘要恒为空。
    // 这种情况下「耗材编辑里给过的覆盖值」就是唯一可知的当前值，直接拿它显示，
    // 否则用户改完温度看到的仍是空白/出厂值（反馈的正是这一条）。
    const ov: string[] | undefined = SliceParamStore.getFilamentOverride(key);
    if (ov !== undefined && ov.length > 0) {
      const v: number = Number.parseFloat(ov[0]);
      if (Number.isFinite(v)) { return v; }
    }
    return undefined;
  }

  // 板型名 -> 该板型对应的两个床温键（首层 / 其他层）。
  // 内核里四套床温是独立的：cool / hot / textured / supertack，curr_bed_type 选哪个就只读哪套。
  private bedTempKeysOf(bedName: string): string[] {
    const n: string = bedName.toLowerCase();
    if (n.includes('super')) { return ['supertack_plate_temp_initial_layer', 'supertack_plate_temp']; }
    if (n.includes('textured') || n.includes('纹理')) { return ['textured_plate_temp_initial_layer', 'textured_plate_temp']; }
    if (n.includes('high temp') || n.includes('高温')) { return ['hot_plate_temp_initial_layer', 'hot_plate_temp']; }
    if (n.includes('engineering') || n.includes('工程')) { return ['eng_plate_temp_initial_layer', 'eng_plate_temp']; }
    if (n.includes('cool') || n.includes('低温')) { return ['cool_plate_temp_initial_layer', 'cool_plate_temp']; }
    return [];
  }

  // 当前板型的床温档位文本，如 "70/65℃"（首层/其他层）；取不到时返回空串
  private bedTempText(): string {
    const name: string = this.plateOptions[this.plateIndex] ?? '';
    const keys: string[] = this.bedTempKeysOf(name);
    if (keys.length < 2) { return ''; }
    const a: number | undefined = this.numParamOf(keys[0]);
    const b: number | undefined = this.numParamOf(keys[1]);
    if (a === undefined || b === undefined) { return ''; }
    if (a <= 0 && b <= 0) { return ''; }
    return `${Math.round(a)}/${Math.round(b)}℃`;
  }

  // 工艺显示名（内核真实预设名，不做翻译/裁剪）；候选为空时显示"无兼容预设"
  private processLabel(): string {
    if (this.processOptions.length === 0) { return NO_COMPAT_TEXT; }
    const n: string | undefined = this.processOptions[this.processIndex];
    return n !== undefined ? n : '';
  }

  // 耗材显示名，同上
  private filamentLabel(): string {
    if (this.filamentOptions.length === 0) { return NO_COMPAT_TEXT; }
    const n: string | undefined = this.filamentOptions[this.filamentIndex];
    return n !== undefined ? n : '';
  }

  // ===== 任务 C/D：对象模式的「工艺 / 打印机 / 耗材」（对象级覆盖，不污染全局）=====

  // 机型名归一：小写、去 "bambu lab" 前缀、去掉尾部喷嘴口径（"0.4 nozzle" 里的 "0.4"）。
  // 用于把「同机型的喷嘴变体」聚到一起（如 H2D 0.4/0.6/0.8 nozzle）。
  private baseModelOf(name: string): string {
    let s: string = name.toLowerCase().trim();
    s = s.replace('bambu lab', '').trim();
    const ni: number = s.indexOf('nozzle');
    if (ni >= 0) { s = s.substring(0, ni).trim(); }
    const parts: string[] = s.split(' ');
    while (parts.length > 1) {
      const last: string = parts[parts.length - 1];
      if (last.length > 0 && !Number.isNaN(Number(last))) { parts.pop(); } else { break; }
    }
    return parts.join(' ').trim();
  }

  private globalPrinterName(): string {
    const n: string | undefined = this.printerOptions[this.printerIndex];
    return n !== undefined ? n : '';
  }

  private ensureObjPreset(id: number): ObjPresetSel {
    let o: ObjPresetSel | undefined = this.objPresets.get(id);
    if (o === undefined) {
      o = new ObjPresetSel();
      this.objPresets.set(id, o);
    }
    return o;
  }

  // 对象模式下「打印机」下拉：只列【当前机型的不同喷嘴变体】（数据来自内核候选表，数据驱动、不写死）。
  private objectPrinterOptions(): string[] {
    const base: string = this.baseModelOf(this.globalPrinterName());
    const out: string[] = [];
    for (const n of this.printerOptions) {
      if (this.baseModelOf(n) === base) { out.push(n); }
    }
    if (out.length > 0) { return out; }
    // 兜底：至少返回当前全局机型一项（不跨机型）
    return this.globalPrinterName() !== '' ? [this.globalPrinterName()] : [];
  }

  // 对象级有效预设名（有覆盖取覆盖，否则回落全局）
  private objectPrinterName(): string {
    const o: ObjPresetSel | undefined = this.objPresets.get(this.currentObjectId());
    if (o !== undefined && o.printer !== '') { return o.printer; }
    return this.globalPrinterName();
  }

  private objectProcessName(): string {
    const o: ObjPresetSel | undefined = this.objPresets.get(this.currentObjectId());
    if (o !== undefined && o.process !== '') { return o.process; }
    return this.processLabel();
  }

  private objectFilamentName(): string {
    const o: ObjPresetSel | undefined = this.objPresets.get(this.currentObjectId());
    if (o !== undefined && o.filament !== '') { return o.filament; }
    return this.filamentLabel();
  }

  private objectPrinterIndex(): number {
    const opts: string[] = this.objectPrinterOptions();
    const i: number = opts.indexOf(this.objectPrinterName());
    return i >= 0 ? i : 0;
  }

  private objectProcessIndex(): number {
    const i: number = this.processOptions.indexOf(this.objectProcessName());
    return i >= 0 ? i : 0;
  }

  private objectFilamentIndex(): number {
    const i: number = this.filamentOptions.indexOf(this.objectFilamentName());
    return i >= 0 ? i : 0;
  }

  // 对象模式：打印机下拉选择（数据驱动，仅同机型喷嘴变体；只写对象覆盖，绝不切内核）
  private onObjectPrinterPicked(i: number): void {
    const id: number = this.currentObjectId();
    if (id < 0) { return; }
    const opts: string[] = this.objectPrinterOptions();
    if (i < 0 || i >= opts.length) { return; }
    this.ensureObjPreset(id).printer = opts[i];
    this.onObjectPresetChanged(id, '打印机', opts[i]);
  }

  private onObjectProcessPicked(i: number): void {
    const id: number = this.currentObjectId();
    if (id < 0 || i < 0 || i >= this.processOptions.length) { return; }
    const name: string = this.processOptions[i];
    this.ensureObjPreset(id).process = name;
    this.onObjectPresetChanged(id, '工艺', name);
  }

  private onObjectFilamentPicked(i: number): void {
    const id: number = this.currentObjectId();
    if (id < 0 || i < 0 || i >= this.filamentOptions.length) { return; }
    const name: string = this.filamentOptions[i];
    this.ensureObjPreset(id).filament = name;
    // 对象级耗材落到 ModelState（分组依据）；随后重算「耗材→喷嘴」分组
    const inst: ModelInstance | undefined = modelState.get(id);
    if (inst !== undefined) { inst.filamentName = name; }
    this.onObjectPresetChanged(id, '耗材', name);
  }

  // 对象预设变更后的统一处理：任务 D —— 自动给该对象分配一个与其它对象不同的颜色，
  // 并立即刷新预览（modelState.setDisplayColor → revision++ → 3D 页只改材质 baseColor，不重建几何）。
  private onObjectPresetChanged(id: number, kind: string, name: string): void {
    const color: string = this.assignDistinctColor(id);
    this.schemaRev = this.schemaRev + 1;
    const line: string = `[ObjPreset] 对象${id} 覆盖${kind}=${name} 自动配色=${color}（对象级，未改全局预设/参数）`;
    hilog.info(0x0000, 'ObjPreset', '%{public}s', line);
    AppLog.push(line);
    // 耗材变更会改变「耗材→喷嘴」分组（对象喷嘴侧 = 其耗材所在分组的喷嘴）→ 立即重算
    if (kind === '耗材') {
      const printer: string = this.printerOptions[this.printerIndex] ?? '';
      if (FilamentGrouping.applyToState(printer, [])) {
        modelState.publish();
      }
    }
  }

  // 任务 D：从既有调色板里挑一个【与场景中其它对象都不同】的颜色；全被占用则按 id 循环并记日志。
  private assignDistinctColor(id: number): string {
    const used: Set<string> = new Set<string>();
    for (const inst of modelState.instances) {
      if (inst.id !== id && inst.displayColor !== '') { used.add(inst.displayColor); }
    }
    const inst: ModelInstance | undefined = modelState.get(id);
    const cur: string = inst !== undefined ? inst.displayColor : '';
    let picked: string = '';
    // 优先：未被占用且与当前不同
    for (const c of DISPLAY_COLORS) {
      if (!used.has(c.hex) && c.hex !== cur) { picked = c.hex; break; }
    }
    // 次选：任取一个未被占用的
    if (picked === '') {
      for (const c of DISPLAY_COLORS) {
        if (!used.has(c.hex)) { picked = c.hex; break; }
      }
    }
    // 兜底：全被占用 → 按 id 循环，并记日志
    if (picked === '') {
      picked = DISPLAY_COLORS[id % DISPLAY_COLORS.length].hex;
      hilog.warn(0x0000, 'ObjPreset', '调色板已全被占用，对象%{public}d 循环取色 %{public}s', id, picked);
      AppLog.push(`[ObjPreset] 调色板全占用，对象${id} 循环取色 ${picked}`);
    }
    modelState.setDisplayColor(id, picked);
    modelState.publish();
    return picked;
  }

  private currentSubGroups(): SubGroup[] {
    const gname: string = this.groups[this.activeGroup];
    const out: SubGroup[] = [];
    for (const p of this.allParams) {
      if (p.group !== gname) { continue; }
      // 简易视图只渲染 mode=0 的常用项；高级视图渲染全部（含 mode=1 的进阶/开发项）。
      // 只影响「这一屏渲染哪些行」：参数值、预设基准、覆盖表、切片 payload 都不受影响。
      if (this.paramViewMode === 0 && p.mode !== 0) { continue; }
      let sg: SubGroup | undefined = undefined;
      for (const s of out) {
        if (s.name === p.subgroup) { sg = s; break; }
      }
      if (sg === undefined) {
        sg = new SubGroup();
        sg.name = p.subgroup;
        out.push(sg);
      }
      sg.params.push(p);
    }
    return out;
  }

  private isCollapsed(name: string): boolean {
    return this.collapsed.indexOf(name) >= 0;
  }

  private toggleCollapse(name: string): void {
    const idx: number = this.collapsed.indexOf(name);
    if (idx >= 0) {
      this.collapsed.splice(idx, 1);
    } else {
      this.collapsed.push(name);
    }
    this.collapsed = this.collapsed.slice();
  }

  // ===== 「对象」页签：对象选择器 + 按对象参数 + 模型颜色 =====

  // 选择器显示项（对象名，顺序 = objects 顺序）
  private objectNames(): string[] {
    const out: string[] = [];
    for (const o of this.objects) {
      out.push(o.name);
    }
    return out;
  }

  // 对象 id 列表（与 objectNames 同序，用于"选择器下标 -> 对象 id"）
  private objectIds(): number[] {
    const out: number[] = [];
    for (const o of this.objects) {
      out.push(o.id);
    }
    return out;
  }

  // 安全的选中下标：对象被删除后下标可能越界，这里夹到合法范围（无对象时返回 0）
  private safeObjectIndex(): number {
    const n: number = this.objects.length;
    if (n === 0) {
      return 0;
    }
    return (this.objectIndex >= 0 && this.objectIndex < n) ? this.objectIndex : 0;
  }

  // 当前选中对象的 id；没有对象 / 下标无效时回落 selectedModelId（可能为 -1）
  private currentObjectId(): number {
    const ids: number[] = this.objectIds();
    if (ids.length === 0) {
      return -1;
    }
    return ids[this.safeObjectIndex()];
  }

  // 左侧列表选中变化 -> 选择器下标跟着变（双向同步之一：左 -> 右）
  private onSelectedObjectChanged(propName: string): void {
    const idx: number = this.objectIds().indexOf(this.selectedModelId);
    if (idx >= 0 && idx !== this.objectIndex) {
      this.objectIndex = idx;
      // 参数区展示的是"该对象"的值（覆盖表），换了对象必须重建参数树才能刷新显示
      this.schemaRev = this.schemaRev + 1;
    }
  }

  private switchMode(isGlobal: boolean): void {
    if (this.globalMode === isGlobal) {
      return;
    }
    this.globalMode = isGlobal;
    this.schemaRev = this.schemaRev + 1;
  }

  // 选择器选中某对象 -> 同步左侧列表选中（双向同步之二：右 -> 左）。
  // 写 selectedModelId（@StorageLink）会回到 AppStorage，左侧对象列表随即高亮同一对象。
  private onObjectPicked(i: number): void {
    const ids: number[] = this.objectIds();
    if (i < 0 || i >= ids.length) {
      return;
    }
    if (this.objectIndex !== i) {
      this.objectIndex = i;
      // 切换对象后重建参数树，显示该对象的参数
      this.schemaRev = this.schemaRev + 1;
    }
    const id: number = ids[i];
    modelState.select(id);
    this.selectedModelId = id;
  }

  // 某参数当前该显示的值：全局模式取全局值；对象模式有覆盖取覆盖，否则回落全局值（对象继承全局）
  private effectiveValue(p: SliceParam): number {
    if (this.globalMode) {
      return p.value;
    }
    const id: number = this.currentObjectId();
    const overrides: Map<string, number> | undefined = this.objectOverrides.get(id);
    if (overrides !== undefined) {
      const v: number | undefined = overrides.get(p.key);
      if (v !== undefined) {
        return v;
      }
    }
    return p.value;
  }

  // 当前对象已设置的显示色（hex）；未设置/无对象返回空串（= 预览用默认色）
  private currentDisplayColor(): string {
    const inst: ModelInstance | undefined = modelState.get(this.currentObjectId());
    return inst !== undefined ? inst.displayColor : '';
  }

  // 点击色块：把颜色按对象写进 ModelState（不写全局参数），再 publish 一下
  // -> AppStorage('modelRevision') 变化 -> 预览页 @Watch 立即重新着色（只改材质属性，不重建几何）。
  private pickDisplayColor(hex: string, name: string): void {
    const id: number = this.currentObjectId();
    if (id < 0) {
      return;
    }
    try {
      modelState.setDisplayColor(id, hex);
      modelState.publish();
      // modelState 不是可观察状态，色块的选中态（描边/对勾）不会自己刷新；
      // 借 schemaRev 触发一次 build 重跑（同时预览页经 modelRevision 立即改色）。
      this.schemaRev = this.schemaRev + 1;
      hilog.info(0x0000, 'ObjColor', '对象%{public}d 显示色设为 %{public}s(%{public}s)', id, name, hex);
    } catch (e) {
      hilog.error(0x0000, 'ObjColor', '设置显示色失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 耗材编辑保存/重置后：整表重建（重新拉内核快照 → 再叠加两类覆盖）。
  // 为什么不能只叠加覆盖：点「重置」时覆盖表被清空，参数表里的旧覆盖值必须靠内核快照刷回来。
  onFilamentEdited(): void {
    if (this.presetState !== SlicerService.STATE_READY) {
      return;
    }
    hilog.info(0x0000, LOG_TAG, '耗材编辑已变更 → 参数表重建');
    this.loadSchema();
  }

  // 撤销/重做改过「全局参数覆盖表」→ 把面板值与之一致：
  // 先全部回到「预设基准」，再回放覆盖表 —— 这是唯一能表达「某个覆盖被撤销掉」的方式
  //（只回放不重置的话，被撤销的那个键会继续显示旧值）。
  // 走 AppStorage 序号广播而非直接调用：History 与面板之间没有引用关系。
  onParamRestore(): void {
    try {
      for (const p of this.allParams) {
        const base: number | undefined = this.presetBaseline.get(p.key);
        if (base !== undefined) {
          p.value = base;
        }
      }
      const n: number = SliceParamStore.applyUserOverrides(this.allParams);
      // 耗材编辑的覆盖值同样要回放（否则撤销/重做会把面板上的耗材级改动抹掉）
      SliceParamStore.applyFilamentOverridesToParams(this.allParams);
      this.allParams = this.allParams.slice();
      SliceParamStore.setParams(this.allParams);
      this.modifyRev = this.modifyRev + 1;
      hilog.info(0x0000, LOG_TAG, '撤销/重做：参数覆盖回放 %{public}d 条', n);
    } catch (e) {
      hilog.error(0x0000, LOG_TAG, '参数覆盖回放异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  private updateValue(p: SliceParam, v: number): void {
    // 记下改前的有效值，用于「参数高亮」日志（值真的变了才记）
    const oldV: number = this.effectiveValue(p);
    if (this.globalMode) {
      p.value = v;
      // 记入「跨页面存活的用户覆盖表」：切页回来重建面板时据此回放（值等于预设默认值时移除覆盖，
      // 避免用户改回默认后仍被旧覆盖钉死）。
      const base: number | undefined = this.presetBaseline.get(p.key);
      if (base !== undefined && ((p.type === 3 || p.type === 4) ? v === base : Math.abs(v - base) <= NUM_EPS)) {
        SliceParamStore.removeUserOverride(p.key);
      } else {
        SliceParamStore.setUserOverride(p.key, v);
      }
      this.allParams = this.allParams.slice();
      SliceParamStore.setParams(this.allParams);
      // 全局参数的一次提交 = 一步撤销（离散操作，立即入栈）
      history.commitNow('修改参数');
    } else {
      // 对象模式：按「对象 id + 参数 key」存覆盖值，绝不改全局参数（切片仍用全局值）。
      // 重建 allParams 引用触发重渲染，但 ForEach key 不变 -> 输入框聚焦不会被顶掉。
      // 走 SliceParamStore.setObjectOverride：写入的正是本面板持有的同一份表（跨页面存活）。
      const id: number = this.currentObjectId();
      if (id < 0) {
        return;
      }
      SliceParamStore.setObjectOverride(id, p.key, v);
      // 对象级参数的每次提交记一步撤销（离散操作，立即入栈；不是逐键防抖）
      history.commitNow('对象参数');
      this.allParams = this.allParams.slice();
    }
    // 代次 +1：让"已修改集合"缓存失效，本行数值与所属分类标签立即重算颜色（实时标橙 / 恢复清橙）
    this.modifyRev = this.modifyRev + 1;
    // 参数变化广播：3D 页据此重算「悬空/支撑告警」显隐
    //（支撑开关等改了要立即生效，不能等下次载入）。
    const rev: number = AppStorage.get<number>('paramRevSeq') ?? 0;
    AppStorage.setOrCreate<number>('paramRevSeq', rev + 1);
    this.logParamHighlight(p, oldV, v);
  }

  // ===== 需求 3：参数被修改 -> 高亮橙（数值 + 分类标签）=====

  // 与「预设默认值」比较，判断某参数是否被自定义修改过。
  // 数值带容差（浮点），布尔 / 枚举按相等判断。
  private computeModified(p: SliceParam): boolean {
    const base: number | undefined = this.presetBaseline.get(p.key);
    if (base === undefined) {
      // 没有基准（例如快照里没有该 key）就不标，避免误报
      return false;
    }
    const cur: number = this.effectiveValue(p);
    if (p.type === 3 || p.type === 4) {
      return cur !== base;
    }
    return Math.abs(cur - base) > NUM_EPS;
  }

  // 已修改参数集合（按 modifyRev / schemaRev 代次缓存）。
  // 为什么缓存：本函数被每一行参数 + 每一个分类标签调用，逐次全量遍历太浪费；
  // 同时读这两个 @State（改值 / 换预设 / 换对象 / 切模式都会变），建立"立即重算"的响应式依赖，
  // 从而做到实时标橙而不必重建整棵参数树（也就不会打断输入框焦点）。
  private ensureModifiedCache(): void {
    if (this.modCacheRev === this.modifyRev && this.modCacheSchema === this.schemaRev) {
      return;
    }
    this.modCacheRev = this.modifyRev;
    this.modCacheSchema = this.schemaRev;
    this.modifiedKeys.clear();
    for (const p of this.allParams) {
      if (this.computeModified(p)) {
        this.modifiedKeys.add(p.key);
      }
    }
  }

  private isParamModified(p: SliceParam): boolean {
    this.ensureModifiedCache();
    return this.modifiedKeys.has(p.key);
  }

  // 某分类下是否存在被修改的参数（分类标签据此标橙）
  private groupHasModified(group: string): boolean {
    this.ensureModifiedCache();
    for (const p of this.allParams) {
      if (p.group === group && this.modifiedKeys.has(p.key)) {
        return true;
      }
    }
    return false;
  }

  // 参数值的纯文本（用于高亮日志，与 displayValue 的展示口径一致但不带单位）
  private paramValueText(p: SliceParam, v: number): string {
    if (p.type === 4) { return p.options[v] ?? `${v}`; }
    if (p.type === 3) { return v === 1 ? '开' : '关'; }
    return `${v}`;
  }

  // 「参数高亮」自证日志：值真的变了才记（含改回预设值时那条，便于核对橙色已清除）。
  private logParamHighlight(p: SliceParam, oldV: number, newV: number): void {
    const changed: boolean = (p.type === 3 || p.type === 4)
      ? (oldV !== newV) : (Math.abs(newV - oldV) > NUM_EPS);
    if (!changed) {
      return;
    }
    const base: number | undefined = this.presetBaseline.get(p.key);
    const baseText: string = base !== undefined ? this.paramValueText(p, base) : '?';
    const state: string = this.computeModified(p) ? '标橙' : '恢复';
    const text: string =
      `参数高亮 修改=${p.key} 分类=${p.group} 当前=${this.paramValueText(p, newV)} 预设=${baseText} ${state}`;
    hilog.info(0x0000, HILITE_TAG, '%{public}s', text);
    AppLog.push(text);
  }

  private displayValue(p: SliceParam): string {
    const v: number = this.effectiveValue(p);
    if (p.type === 4) { return p.options[v] ?? ''; }
    if (p.type === 3) { return v === 1 ? '开' : '关'; }
    const d: number = (p.type === 1) ? 0 : 2;
    return `${v.toFixed(d)}${p.unit ? ' ' + p.unit : ''}`;
  }

  private toSelectOptions(arr: string[]): SelectOption[] {
    const out: SelectOption[] = [];
    for (const o of arr) {
      out.push({ value: o } as SelectOption);
    }
    return out;
  }

  // 界面层高最终显示值。和 callSelectByIndex() 里的「请求下标/请求名 / 内核选中 / 回读层高」对照，
  // 可确认「界面显示的值 == 内核当前配置的值」。
  private logLayerHeightShown(arr: SliceParam[]): void {
    for (const p of arr) {
      if (p.key === 'layer_height') {
        hilog.info(0x0000, LOG_TAG, '界面层高最终显示=%{public}s mm', p.value.toFixed(2));
        return;
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      // 全局/对象 切换 + 对象选择
      Row({ space: 6 }) {
        this.modeBtn('全局', true)
        this.modeBtn('对象', false)
        if (!this.globalMode) {
          // 对象选择器：列出当前场景全部对象（用对象名），与左侧列表双向同步。
          // 无对象时显示空态，不显示假数据、不崩。
          if (this.objects.length === 0) {
            Text('无对象')
              .fontSize(12)
              .fontColor(Theme.textSecondary)
              .width(110)
          } else {
            Select(this.toSelectOptions(this.objectNames()))
              .selected(this.safeObjectIndex())
              .value(this.objectNames()[this.safeObjectIndex()] ?? '')
              .font({ size: 12 })
              .fontColor(Theme.accentSoft)
              .width(110)
              .onSelect((i: number) => { this.onObjectPicked(i); })
          }
        }
        Blank()
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10 })

      // 打印机 / 耗材 / 工艺 / 打印板 下拉
      // 三态：loading -> 占位「加载中…」并禁用；failed -> 占位「预设加载失败」并禁用；
      //       ready -> 用内核真实预设名（工艺/耗材仅限内核判定兼容的子集）
      // 工艺/耗材候选为空（该机型无兼容预设）时：显示"无兼容预设"并禁用
      //
      // 为什么这四个 Select 必须**直接内联在 build() 里**，不能再走多参 @Builder（如旧的 dropdownRow）：
      //   ArkUI 的 @Builder 只有"按引用传参且仅一个参数"才会建立动态刷新关系；多参数 / 按值传参时
      //   状态变量改变不会触发 @Builder 内部 UI 重建。四个下拉恰好是 6 个参数、全部按值传递，
      //   于是首帧把 Select 固化成「加载中…」+ 禁用后，即便 presetState 变成 ready 这棵子树也永不重建
      //   （停在本页永远「加载中…」，切到预览页再回来才正常）。内联后 Select 的属性直接依赖
      //   this.presetState / printerOptions / processOptions / filamentOptions / plateOptions 及各自下标，
      //   走普通响应式路径，状态一变立即刷新。以后请勿再把这些下拉改回多参 @Builder。
      Column({ space: this.compactPanel() ? 4 : 6 }) {
        // 紧凑档（手机 / 窄内容区）：整块预设区可折叠 —— 标题常驻，默认收起，收起时显示当前值摘要，
        // 既省空间、又不会被下拉把文字截断；展开后仍是同一批下拉，切换逻辑完全不变。
        if (this.compactPanel()) {
          Row({ space: 6 }) {
            Text('打印预设')
              .fontSize(11)
              .fontColor(Theme.textSecondary)
            Blank()
            Text(this.presetsExpanded ? '收起' : '展开')
              .fontSize(11)
              .fontColor(Theme.accent)
            Text(this.presetsExpanded ? '▾' : '▸')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          }
          .width('100%')
          .height(30)
          .padding({ left: 8, right: 8 })
          .backgroundColor(Theme.surfaceElevated)
          .borderRadius(6)
          .onClick(() => { this.presetsExpanded = !this.presetsExpanded; })
        }
        // 收起态：2 行当前值摘要（工艺/打印机、耗材/板），替代整块下拉，避免文字被截断
        if (this.compactPanel() && !this.presetsExpanded) {
          Text(this.presetSummary())
            .fontSize(10)
            .fontColor(Theme.textSecondary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        }
        // 4 个预设下拉：常规档常显；紧凑档展开后显示（字号 / 内边距同步压缩）
        if (!this.compactPanel() || this.presetsExpanded) {
        Row() {
          Text('工艺')
            .fontSize(this.compactPanel() ? 10 : 11)
            .fontColor(Theme.textSecondary)
            .width(this.compactPanel() ? 38 : 44)
          Select(this.toSelectOptions(this.presetState === SlicerService.STATE_READY
            ? this.selectDisplay(this.processOptions) : this.statePlaceholder()))
            .selected(this.presetState === SlicerService.STATE_READY
              ? (this.globalMode ? this.processIndex : this.objectProcessIndex()) : 0)
            .value(this.presetState === SlicerService.STATE_READY
              ? (this.globalMode ? this.processLabel() : this.objectProcessName()) : this.statePlaceholderText())
            .font({ size: this.compactPanel() ? 11 : 12 })
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .enabled(this.presetState === SlicerService.STATE_READY && this.processOptions.length > 0
              && (this.globalMode || this.currentObjectId() >= 0))
            // 对象模式：只写该对象的覆盖（任务 C/D），不切内核；全局模式走原有内核切换链路。
            .onSelect(this.globalMode ? this.dropdownHandler(1,
              this.presetState === SlicerService.STATE_READY
                ? this.selectDisplay(this.processOptions) : this.statePlaceholder(),
              this.optionsGen) : (i: number) => { this.onObjectProcessPicked(i); })
          // 紧凑档去掉多余的「▾」（Select 自带下拉箭头），把宽度让给预设名，减少截断
          if (!this.compactPanel()) {
            Text('▾')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10,
          top: this.compactPanel() ? 3 : 6, bottom: this.compactPanel() ? 3 : 6 })
        .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
        .borderRadius(6)
        .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
        .systemMaterial(this.matSupported ? this.material : undefined)

        Row() {
          Text('打印机')
            .fontSize(this.compactPanel() ? 10 : 11)
            .fontColor(Theme.textSecondary)
            .width(this.compactPanel() ? 38 : 44)
          Select(this.toSelectOptions(this.presetState === SlicerService.STATE_READY
            ? (this.globalMode ? this.printerOptions : this.objectPrinterOptions()) : this.statePlaceholder()))
            .selected(this.presetState === SlicerService.STATE_READY
              ? (this.globalMode ? this.printerIndex : this.objectPrinterIndex()) : 0)
            .value(this.presetState === SlicerService.STATE_READY
              ? (this.globalMode ? this.globalPrinterName() : this.objectPrinterName()) : this.statePlaceholderText())
            .font({ size: this.compactPanel() ? 11 : 12 })
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .enabled(this.presetState === SlicerService.STATE_READY
              && (this.globalMode || this.currentObjectId() >= 0))
            // 对象模式：打印机只列同机型喷嘴变体，仅写对象覆盖，不切内核（任务 C）。
            .onSelect(this.globalMode ? this.dropdownHandler(0,
              this.presetState === SlicerService.STATE_READY ? this.printerOptions : this.statePlaceholder(),
              this.optionsGen) : (i: number) => { this.onObjectPrinterPicked(i); })
          if (!this.compactPanel()) {
            Text('▾')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10,
          top: this.compactPanel() ? 3 : 6, bottom: this.compactPanel() ? 3 : 6 })
        .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
        .borderRadius(6)
        .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
        .systemMaterial(this.matSupported ? this.material : undefined)

        Row() {
          Text('耗材')
            .fontSize(this.compactPanel() ? 10 : 11)
            .fontColor(Theme.textSecondary)
            .width(this.compactPanel() ? 38 : 44)
          Select(this.toSelectOptions(this.presetState === SlicerService.STATE_READY
            ? this.selectDisplay(this.filamentOptions) : this.statePlaceholder()))
            .selected(this.presetState === SlicerService.STATE_READY
              ? (this.globalMode ? this.filamentIndex : this.objectFilamentIndex()) : 0)
            .value(this.presetState === SlicerService.STATE_READY
              ? (this.globalMode ? this.filamentLabel() : this.objectFilamentName()) : this.statePlaceholderText())
            .font({ size: this.compactPanel() ? 11 : 12 })
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .enabled(this.presetState === SlicerService.STATE_READY && this.filamentOptions.length > 0
              && (this.globalMode || this.currentObjectId() >= 0))
            // 对象模式：只写该对象的覆盖（任务 C/D），不切内核；全局模式走原有内核切换链路。
            .onSelect(this.globalMode ? this.dropdownHandler(2,
              this.presetState === SlicerService.STATE_READY
                ? this.selectDisplay(this.filamentOptions) : this.statePlaceholder(),
              this.optionsGen) : (i: number) => { this.onObjectFilamentPicked(i); })
          if (!this.compactPanel()) {
            Text('▾')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10,
          top: this.compactPanel() ? 3 : 6, bottom: this.compactPanel() ? 3 : 6 })
        .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
        .borderRadius(6)
        .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
        .systemMaterial(this.matSupported ? this.material : undefined)

        // 耗材编辑入口：紧贴「耗材」选择器下方（取代原顶栏入口）。
        // 与拓竹一致 —— 「耗材设置」属于耗材这一栏，板温/喷嘴温度/风扇等都在里面改。
        Row() {
          Text('耗材编辑')
            .fontSize(this.compactPanel() ? 10 : 11)
            .fontColor(Theme.accent)
          Blank()
          Text('打开 ▸')
            .fontSize(this.compactPanel() ? 10 : 11)
            .fontColor(Theme.textSecondary)
        }
        .width('100%')
        .padding({ left: 10, right: 10,
          top: this.compactPanel() ? 4 : 6, bottom: this.compactPanel() ? 4 : 6 })
        .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
        .borderRadius(6)
        .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
        .systemMaterial(this.matSupported ? this.material : undefined)
        .onClick(() => { this.onFilament(); })

        Row() {
          Text('打印板')
            .fontSize(this.compactPanel() ? 10 : 11)
            .fontColor(Theme.textSecondary)
            .width(this.compactPanel() ? 38 : 44)
          Select(this.toSelectOptions(this.presetState === SlicerService.STATE_READY
            ? this.plateOptions : this.statePlaceholder()))
            .selected(this.presetState === SlicerService.STATE_READY ? this.plateIndex : 0)
            .value(this.presetState === SlicerService.STATE_READY
              ? this.plateOptions[this.plateIndex] : this.statePlaceholderText())
            .font({ size: this.compactPanel() ? 11 : 12 })
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .enabled(this.presetState === SlicerService.STATE_READY)
            // 打印板选项来自参数 curr_bed_type 的 enum（不是内核预设候选表），下标语义稳定，
            // 仍直接写回参数即可；候选表那套代次保护只针对机型/工艺/耗材。
            .onSelect((i: number) => { this.setPlateParam(i); })
          // 当前板型对应的床温档位（首层/其他层）就显示在选择器右边。
          // 为什么加：板型决定内核读哪一组床温（cool / hot / textured / supertack_plate_temp*），
          // 光看板名看不出"这次打几度"，曾出现"我明明改了 70/65 却没生效"——其实改的是另一档。
          // 把当前生效的两个值亮出来，一眼可核。
          if (this.presetState === SlicerService.STATE_READY && this.bedTempText().length > 0) {
            Text(this.bedTempText())
              .fontSize(this.compactPanel() ? 9 : 10)
              .fontColor(Theme.textSecondary)
              .margin({ left: 6 })
          }
          if (!this.compactPanel()) {
            Text('▾')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10,
          top: this.compactPanel() ? 3 : 6, bottom: this.compactPanel() ? 3 : 6 })
        .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
        .borderRadius(6)
        .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
        .systemMaterial(this.matSupported ? this.material : undefined)

        // 盘级床型（多盘）：第 0 项 = 跟随全局；其余与上面的全局床型同序。
        // 只改本盘（PlateRec.bed），逐盘切片时按盘覆盖 curr_bed_type。
        if (this.activePlate > 0 && this.presetState === SlicerService.STATE_READY
          && this.plateOptions.length > 0) {
          Row() {
            Text('盘床型')
              .fontSize(this.compactPanel() ? 10 : 11)
              .fontColor(Theme.textSecondary)
              .width(this.compactPanel() ? 38 : 44)
            Select(this.toSelectOptions(this.plateBedSelectorLabels()))
              .selected(this.plateBedIndex)
              .value(this.plateBedSelectorLabels()[this.plateBedIndex] ?? '跟随全局')
              .font({ size: this.compactPanel() ? 11 : 12 })
              .fontColor(Theme.textPrimary)
              .layoutWeight(1)
              .onSelect((i: number) => { this.pickPlateBed(i); })
            if (!this.compactPanel()) {
              Text('▾')
                .fontSize(10)
                .fontColor(Theme.textSecondary)
            }
          }
          .width('100%')
          .padding({ left: 10, right: 10,
            top: this.compactPanel() ? 3 : 6, bottom: this.compactPanel() ? 3 : 6 })
          .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
          .borderRadius(6)
          .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
          .systemMaterial(this.matSupported ? this.material : undefined)
        }
        }

        // 模型颜色：紧接「打印板」那一行【下方】，仅「对象」页签显示。
        // 颜色按对象存在 ModelState.displayColor（不写全局参数）；点击即生效、无需确认，
        // 预览页通过 modelRevision 立即重新着色（只改材质属性，不重建几何）。
        if (!this.globalMode) {
          Column({ space: 6 }) {
            Text('模型颜色')
              .fontSize(11)
              .fontColor(Theme.textSecondary)
            // 色板：所见即所得的一排色块；Flex 自动换行，窄面板也不会溢出
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(DISPLAY_COLORS, (c: DisplayColorOption) => {
                Stack() {
                  Circle()
                    .width(20)
                    .height(20)
                    .fill(c.hex)
                    // 选中态：强调色粗描边 + 对勾；未选中：细描边
                    .stroke(this.currentDisplayColor() === c.hex ? Theme.accent : Theme.border)
                    .strokeWidth(this.currentDisplayColor() === c.hex ? 3 : 1)
                  if (this.currentDisplayColor() === c.hex) {
                    Text('✓')
                      .fontSize(10)
                      .fontColor('#FFFFFF')
                  }
                }
                .width(22)
                .height(22)
                .margin({ right: 6, bottom: 6 })
                .onClick(() => { this.pickDisplayColor(c.hex, c.name); })
              }, (c: DisplayColorOption) => c.hex)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(this.matSupported ? Color.Transparent : Theme.surfaceElevated)
          .borderRadius(6)
          .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1 })
          .systemMaterial(this.matSupported ? this.material : undefined)
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6 })

      if (this.presetState === SlicerService.STATE_LOADING) {
        // 预设初始化中：不渲染任何参数（此刻的 schema/snapshot 是内核默认值，渲染出来就是退化表单）
        Column({ space: 10 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Theme.accent)
          Text('正在加载切片预设…')
            .fontSize(12)
            .fontColor(Theme.textSecondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.presetState === SlicerService.STATE_FAILED) {
        // 失败态：明确告知 + 可操作（重试）。绝不继续显示「加载中…」，也不用退化数据渲染参数
        Column({ space: 10 }) {
          Text(FAILED_TEXT)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary)
          Text(this.presetError !== '' ? this.presetError : '未知原因')
            .fontSize(11)
            .fontColor(Theme.textSecondary)
            .textAlign(TextAlign.Center)
            .maxLines(4)
          Button('重试')
            .fontSize(13)
            .fontColor(Theme.textPrimary)
            .backgroundColor(Theme.surfaceElevated)
            .borderRadius(8)
            .onClick(() => { this.onRetryPresets(); })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 16, right: 16 })
      } else {
        // 参数搜索（Phase 4）：跨分组/跨页签。输入非空时下方参数区变成扁平结果列表。
        // 放在页签之上：搜索是「跨页签」的行为，压在页签下面会让人以为只搜当前页签。
        // 注意：占位文字**不吃 `.fontSize()`**，必须单独设 `.placeholderFont()`，
        // 否则输入文字是小的、灰提示字还是默认 16 号，看起来又大又挤（这里踩过一次）。
        Row({ space: 4 }) {
          TextInput({ text: this.searchText, placeholder: '搜索参数（中文名 / key）' })
            .fontSize(this.compactPanel() ? 10 : 11)
            .placeholderFont({ size: this.compactPanel() ? 10 : 11 })
            .placeholderColor(Theme.textSecondary)
            .height(this.compactPanel() ? 24 : 26)
            .padding({ left: 6, right: 6, top: 0, bottom: 0 })
            .fontColor(Theme.textPrimary)
            .backgroundColor(Theme.surfaceElevated)
            .borderRadius(5)
            .layoutWeight(1)
            .onChange((v: string) => { this.searchText = v; })
          if (this.searchText.length > 0) {
            Text('清除')
              .fontSize(this.compactPanel() ? 10 : 11)
              .fontColor(Theme.accent)
              .padding({ left: 6, right: 4, top: 4, bottom: 4 })
              .onClick(() => { this.searchText = ''; })
          }
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 3, bottom: 1 })

        // 分类页签（最左的「简易/高级」是参数视图档位：控制这一屏渲染 kSchema 的哪一档参数）
        Scroll() {
          Row() {
            Text(this.paramViewMode === 0 ? '简易' : '高级')
              .fontSize(11)
              .fontColor(this.paramViewMode === 0 ? Theme.textSecondary : Theme.accent)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .margin({ left: 2, right: 6 })
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(10)
              .onClick(() => {
                this.paramViewMode = this.paramViewMode === 0 ? 1 : 0;
                SliceParamStore.setParamViewMode(this.paramViewMode);
              })
            // 复位：一键回到预设原值（作用范围跟随当前模式，见 resetToPreset）。
            // 亮度表示「当前是否有可复位的修改」，避免用户点了以为没有反应。
            Text('复位')
              .fontSize(11)
              .fontColor(this.hasOverridesToReset() ? Theme.modified : Theme.textSecondary)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .margin({ right: 6 })
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(10)
              .onClick(() => { this.resetToPreset(); })
            ForEach(this.groups, (g: string, index: number) => {
              this.categoryTab(g, index)
            }, (g: string, index: number) => `${g}-${index}`)
          }
          .padding({ left: 8, right: 8 })
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .border({ width: { bottom: 1 }, color: Theme.border })

        // 操作提示（用户要求）：一句话告诉用户「怎么看到参数说明」——
        // 长按是隐式交互，不写出来没人会试；放在页签行与列表之间，不占内容区高度。
        Text('提示：长按参数名可查看说明')
          .fontSize(10)
          .fontColor(Theme.textSecondary)
          .width('100%')
          .padding({ left: 10, top: 3, bottom: 3 })

        // 参数区：搜索中 → 扁平结果列表；否则 → 动态 subgroup 折叠面板
        if (this.searchText.trim().length > 0) {
          Scroll() {
            Column({ space: 2 }) {
              Row() {
                Text(this.searchHitCount() > this.searchHits().length
                  ? `显示前 ${this.searchHits().length} 条 / 共 ${this.searchHitCount()} 条（把词打准些）`
                  : `${this.searchHits().length} 条结果`)
                  .fontSize(10)
                  .fontColor(Theme.textSecondary)
                Blank()
                Text('点一行跳到该参数')
                  .fontSize(10)
                  .fontColor(Theme.textSecondary)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 2, bottom: 4 })

              if (this.searchHits().length === 0) {
                Text('没有匹配的参数：可试试中文名（如「支撑」「填充」）或内核 key（如 wall_loops）')
                  .fontSize(11)
                  .fontColor(Theme.textSecondary)
                  .width('100%')
                  .padding({ left: 10, right: 10, top: 12, bottom: 12 })
              }
              ForEach(this.searchHits(), (p: SliceParam) => {
                this.searchRow(p)
              }, (p: SliceParam) => `hit-${p.key}`)
            }
            .width('100%')
            .padding({ bottom: 20 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        } else {
        // 参数（动态 subgroup 折叠面板）。
        // 必须绑 Scroller：搜索结果点进来要能滚到目标行（裸 Scroll 拿不到可靠偏移）。
        Scroll(this.bodyScroller) {
          Column({ space: 2 }) {
            ForEach(this.currentSubGroups(), (sg: SubGroup) => {
              Column() {
                if (sg.name !== '') {
                  Row() {
                    Text(sg.name)
                      .fontSize(12)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.accentSoft)
                      .layoutWeight(1)
                    Text(this.isCollapsed(sg.name) ? '▸' : '▾')
                      .fontSize(12)
                      .fontColor(Theme.textSecondary)
                  }
                  .width('100%')
                  .padding({ left: 10, right: 10, top: 8, bottom: 4 })
                  .onClick(() => { this.toggleCollapse(sg.name); })
                }
                if (!this.isCollapsed(sg.name)) {
                  ForEach(sg.params, (p: SliceParam) => {
                    this.paramRow(p)
                  }, (p: SliceParam) => `${this.schemaRev}-${p.group}-${p.subgroup}-${p.key}`)
                }
              }
              .width('100%')
              // 上报本子分组在滚动内容里的 y（它的父就是内容 Column，所以这就是内容内偏移）
              .onAreaChange((_o: Area, n: Area) => {
                this.subY.set(sg.name, Number(n.position.y));
              })
            }, (sg: SubGroup) => `${this.schemaRev}-${this.groups[this.activeGroup]}-${sg.name}`)
          }
          .width('100%')
          .padding({ bottom: 20 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        }
      }
      }
      // 光晕层：铺满整栏；指针监听挂在最上层，Transparent 不挡下面按钮点击
      PressGlow({ radius: 70 })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor(Theme.surface)
    .border({ width: { left: 1 }, color: Theme.border })
    // 需求 3：实测面板可用宽（拖动右栏宽度 / 旋转 / 窗口尺寸变化都会触发）→ 自动切紧凑/常规档
    .onAreaChange((_o: Area, n: Area) => { this.onPanelArea(n); })
  }

  @Builder
  modeBtn(label: string, isGlobal: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor(this.globalMode === isGlobal ? Theme.textPrimary : Theme.textSecondary)
      .fontWeight(this.globalMode === isGlobal ? FontWeight.Bold : FontWeight.Normal)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .backgroundColor(this.globalMode === isGlobal ? Theme.surfaceElevated : '#00000000')
      .borderRadius(6)
      .onClick(() => { this.switchMode(isGlobal); })
  }

  @Builder
  categoryTab(label: string, index: number) {
    // 该分类下只要有一个参数偏离预设默认值，标签就标橙（全部恢复后自动清橙）
    Text(label)
      .fontSize(12)
      .fontColor(this.groupHasModified(label)
        ? Theme.modified
        : (this.activeGroup === index ? Theme.accent : Theme.textSecondary))
      .fontWeight(this.activeGroup === index ? FontWeight.Bold : FontWeight.Normal)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .border({
        width: { bottom: this.activeGroup === index ? 2 : 0 },
        color: this.groupHasModified(label) ? Theme.modified : Theme.accent})
      .onClick(() => {
        this.activeGroup = index;
        // 在搜索态点页签 = 想看该分组 → 顺手退出搜索（否则点了页签界面纹丝不动，像坏了）
        if (this.searchText.length > 0) {
          this.searchText = '';
        }
      })
  }

  // 搜索结果行：名称（命中片段标强调色）+「分组 ▸ 子分组」+ 内核 key + 当前值；点一行跳过去。
  @Builder
  searchRow(p: SliceParam) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text() {
          Span(this.hitPart(p, 0))
          Span(this.hitPart(p, 1)).fontColor(Theme.accent)
          Span(this.hitPart(p, 2))
        }
        .fontSize(12)
        .fontColor(Theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${p.group} ▸ ${p.subgroup}`)
          .fontSize(9)
          .fontColor(Theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(p.key)
        .fontSize(9)
        .fontColor('#6E6E7A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(90)

      Text(this.displayValue(p))
        .fontSize(11)
        .fontColor(Theme.accentSoft)
        .width(54)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .borderRadius(6)
    .border({ width: { bottom: 1 }, color: '#1F1F27' })
    .onClick(() => { this.jumpToParam(p); })
  }

  @Builder
  paramRow(p: SliceParam) {
    Row() {
      Text(p.label)
        .fontSize(12)
        .fontColor(Theme.textPrimary)
        .width(110)
        // 参数说明（长按标题）：说明文字 + 当前值 + 取值范围/可选值 + 分类，见 showParamInfo。
        // 注：Text 没有 .onLongPress 属性，长按必须走通用手势 LongPressGesture。
        .gesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
          this.showParamInfo(p);
        }))
      Blank()
      if (p.type === 3) {
        // 布尔项无"数值文本"，用开关的选中色标橙（与数值标橙同一套判定）
        Toggle({ type: ToggleType.Switch, isOn: this.effectiveValue(p) === 1 })
          .selectedColor(this.isParamModified(p) ? Theme.modified : Theme.accent)
          .onChange((on: boolean) => {
            this.updateValue(p, on ? 1 : 0);
          })
      } else if (p.type === 4) {
        Select(this.toSelectOptions(p.options))
          .selected(this.effectiveValue(p))
          .value(this.displayValue(p))
          .font({ size: 12 })
          .fontColor(this.isParamModified(p) ? Theme.modified : Theme.accentSoft)
          .width(120)
          .onSelect((index: number) => {
            this.updateValue(p, index);
          })
      } else {
        // 数值输入：编辑中只更新缓冲（绝不在编辑过程中解析/回填），Enter / 失焦才提交。
        // text = 正在编辑 → 用户原样输入；否则 → 参数真值的纯数字（单位在框外）
        TextInput({ text: this.editKey === p.key ? this.editText : this.numericText(p) })
          .width(88)
          .height(28)
          .fontSize(12)
          .fontColor(this.isParamModified(p) ? Theme.modified : Theme.accentSoft)
          .backgroundColor(Theme.surfaceElevated)
          .borderRadius(4)
          .onChange((v: string) => {
            // 进入编辑：记下 key，原文照收（不做任何过滤 / 解析 / 回写）
            this.editKey = p.key;
            this.editText = v;
          })
          .onSubmit(() => { this.commitNumericEdit(p); })
          .onBlur(() => { this.commitNumericEdit(p); })
        // 单位：输入框外的独立标签（不参与编辑，不会被误删）
        if (p.unit !== '') {
          Text(p.unit)
            .fontSize(11)
            .fontColor(Theme.textSecondary)
            .width(36)
            .margin({ left: 4 })
        }
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .border({ width: { bottom: 1 }, color: '#1F1F27' })
    // 搜索命中跳转过来的那一行短暂染色（1.6s）——滚动到位后用户要一眼认出是哪一行
    .backgroundColor(p.key === this.flashKey ? '#2600C48C' : Color.Transparent)
    // 上报本行的 y（相对所属子分组）；加上子分组的 y 就是它在滚动内容里的位置（跳转定位用）
    .onAreaChange((_o: Area, n: Area) => {
      const base: number | undefined = this.subY.get(p.subgroup);
      this.rowY.set(p.key, (base !== undefined ? base : 0) + Number(n.position.y));
    })
  }

  // 参数的纯数字文本（不带单位）：整数型不带小数，浮点 / 百分比保留 2 位。
  private numericText(p: SliceParam): string {
    const v: number = this.effectiveValue(p);
    const d: number = (p.type === 1) ? 0 : 2;
    return v.toFixed(d);
  }

  // 数值输入提交（Enter / 失焦）—— 只有这里才解析 / 校验 / 写回参数。
  // 各异常输入的处理：
  //   · 空串 / 非数字（只有符号、字母等）→ 非法：提示 + 回退到「上一个合法值」（=当前参数值），不写参数；
  //   · 超范围 → 夹到 [min,max] 后写回，并提示已夹取；
  //   · 整数型（type=1）→ 四舍五入取整；负值 → 由范围决定（min<0 才允许，否则夹到 min）。
  private commitNumericEdit(p: SliceParam): void {
    if (this.editKey !== p.key) {
      return;   // 不是当前编辑项（失焦事件重复到达）→ 忽略
    }
    const raw: string = this.editText.trim();
    this.editKey = '';
    this.editText = '';   // 缓冲清空 → 输入框回落到参数真值的 numericText（重新渲染时生效）
    const n: number = Number(raw);
    if (raw === '' || !Number.isFinite(n)) {
      // 非法输入：回退到上一个合法值（即当前参数值），并留痕（hilog + 应用日志 + 轻提示）
      hilog.warn(0x0000, PARAM_INPUT_TAG,
        '数值输入非法 → 回退到上一个合法值 param=%{public}s raw="%{public}s"', p.key, raw);
      AppLog.warn('SliceParam', '数值输入非法，已回退到上一个合法值 param=%{public}s raw="%{public}s"', p.key, raw);
      promptAction.showToast({ message: `${p.label} 输入非法，已保留原值`, duration: 1500 });
      return;
    }
    let v: number = (p.type === 1) ? Math.round(n) : n;   // 整数型取整
    let clamped: boolean = false;
    // min/max 都为 0 视为「schema 未声明范围」→ 不夹取（避免把合法值误夹成 0）
    if (!(p.min === 0 && p.max === 0)) {
      const lo: number = Math.min(p.min, p.max);
      const hi: number = Math.max(p.min, p.max);
      if (v < lo) { v = lo; clamped = true; }
      if (v > hi) { v = hi; clamped = true; }
    }
    if (clamped) {
      hilog.warn(0x0000, PARAM_INPUT_TAG,
        '数值输入超范围 → 夹到边界 param=%{public}s 输入=%{public}s 写回=%{public}s', p.key, raw, `${v}`);
      AppLog.warn('SliceParam', '数值输入超范围已夹取 param=%{public}s 输入=%{public}s', p.key, `${raw}→${v}`);
      promptAction.showToast({ message: `${p.label} 已夹到 ${v}`, duration: 1500 });
    }
    this.updateValue(p, v);   // 合法才写回参数（内部会 bump modifyRev，触发高亮重算）
  }
}
