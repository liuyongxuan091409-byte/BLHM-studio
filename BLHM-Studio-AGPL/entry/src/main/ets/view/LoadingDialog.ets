import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// 大模型载入弹窗：分阶段进度条 + 整行日志（视觉严格对齐原型
// mockups/loading-dialog2.html）。强制模态，无取消按钮、不可关闭。
//
// 日志为什么不做打字机：ForEach 的条目一旦生成就不会因为「快照对象里的普通字段」变化而
// 刷新（快照不是 @Observed，读取它的字段建立不了观察依赖）——打字机原地改某一行的文本，
// 只有「新增这一行」引发的重建会画出当时的第一个字，之后所有原地修改都不触发刷新，
// 屏幕上永远停在第一个字符。所以这里一律「整行一次性写入、行内容生成后不可变」，
// 并把亮度编进 ForEach 的 key，保证压暗/点亮这类位置相关的视觉变化也能刷出来。
//
// 日志上滑用「位移动画」实现，不要用 Scroll + 自动滚到底（那会导致跳变/居中/不跟手）：
// 日志区是一个固定高度、clip(true) 的窗口，里面就是一个普通 Column 逐行渲染；
// 新行到来时先把内容整体下推 N 行（视觉上仍是上一屏），再把位移缓动归 0，新行即从底部平滑浮现。
//
// 数据全部由页面侧驱动（LoadDlgModel），组件只负责渲染 + 动画，不参与载入逻辑，
// 这样「谁负责载入、谁负责显示」边界清晰。这里刻意不做任何超时判定：弹窗只在
// 页面收到 onLoadDone / failLoad 时被关掉；「已用 / 预计剩余」只是显示。
// =============================================================================

const TAG: string = 'LoadDlg';

// 阶段名（与 C++ BambuMesh::MeshStage 一一对应）
export const LOAD_STAGES: string[] = ['解析文件', '顶点焊接', '法线重建', '上传几何', '生成缩略图'];

// 每个阶段占全局进度条的比重（合计 100），大致贴合实测耗时分布：
// 焊接是最重的一段，解析次之，缩略图最轻。
const STAGE_WEIGHT: number[] = [14, 48, 16, 15, 7];

// ===== 切片模式（同一套弹窗视觉，只换阶段名/权重/标题/副标题）=====
// 阶段链与原型 mockups/slice-dialog.html 完全一致（顺序即原型）。
//   0 装载模型 / 1 贴板居中 / 2 合并配置  —— 内核无细粒度钩子，只报进入/完成
//   3 分层与路径                          —— Print::process() 的子步骤级 percent
//   4 导出 G-code                         —— export_gcode() 的按层 "layer N"
//   5 生成预览                            —— ArkTS 侧驱动
export const SLICE_STAGES: string[] = ['装载模型', '贴板居中', '合并配置', '分层与路径', '导出 G-code', '生成预览'];
const SLICE_WEIGHT: number[] = [12, 6, 8, 42, 27, 5];

const SEG_COUNT: number = 34;      // 进度条分段数（原型 34 格）

// 调色板（原型 CSS 变量）
const C_ACC: string = '#35D07F';           // 单一绿色强调色
const C_ACC_DIM: string = '#0F2A1D';       // 强调色低亮底
const C_ACC_LINE: string = '#4735D07F';    // rgba(53,208,127,.28) 边框
const C_TEXT1: string = '#ECECF1';
const C_TEXT2: string = '#9A9AA4';
const C_TEXT3: string = '#63636D';
const C_BORDER: string = '#2A2A35';
const C_LINE: string = '#1E1E27';
const C_PANEL: string = '#181820';
const C_LOG_BG: string = '#080A09';
const C_LOG_BORDER: string = '#1C2A22';
const C_LOG_TEXT: string = '#5AE596';
const C_LOG_DIM: string = '#357A55';
const C_LOG_TS: string = '#2F7E56';
const C_LOG_HI: string = '#D2FDE6';
// 亮度分档（离底部越远越暗，形成纵深）：第 0 档最亮，第 3 档最暗
const C_LOG_T1: string = '#49C97F';
const C_LOG_T2: string = '#3F9E67';
const SH_LOG_HI: string = '#8035D07F';
const SH_LOG_0: string = '#4D35D07F';
const SH_LOG_1: string = '#3335D07F';
const SH_LOG_2: string = '#1A35D07F';
const SH_LOG_OFF: string = '#0035D07F';

const MONO_FONT: string = 'monospace';

// 日志区：固定高度的窗口（clip）里放一个普通 Column 逐行渲染 —— 回到「最开始那版」的结构。
// 改下面的 LOG_VISIBLE_LINES 这一个常量即可调整窗口可见行数。
const LOG_VISIBLE_LINES: number = 10;   // 窗口可见行数
const LOG_LINE_HEIGHT: number = 18;     // 单行高：11.5 字号配 18 行高，密而不挤（必须固定，位移量按它算）
const LOG_PANEL_HEIGHT: number = LOG_VISIBLE_LINES * LOG_LINE_HEIGHT;   // 窗口高（固定 px）
// 内部最多保留 20 行：比可见行多，供上滑动画期间从底部滑出（超出丢最老）。
const LOG_MAX_LINES: number = 20;

// 日志上滑：只做「位移 + 动画」——用 translate(y) 配合 animateTo 缓动，绝不用 Scroll + 自动滚到底。
// 用 Scroll / scrollTo / scrollEdge 会带来：①跳到底部不丝滑 ②内容不满一屏时被居中（首行跑到中间）
// ③不跟手。所以这里一个滚动容器都不留，位移量完全由「行数 × LOG_LINE_HEIGHT」算出。
const LOG_SLIDE_MS: number = 200;       // 上滑位移动画时长（180~220ms 之间）

// 全局百分比：阶段前缀和 + 阶段内百分比 × 该阶段权重
export function globalPercent(stage: number, pctInStage: number): number {
  return globalPercentWith(STAGE_WEIGHT, stage, pctInStage);
}

// 同上，但权重由调用方给（导入 / 切片两套阶段链共用这一份算法）
export function globalPercentWith(weights: number[], stage: number, pctInStage: number): number {
  if (stage < 0) { return 100; }
  let base: number = 0;
  for (let i = 0; i < stage && i < weights.length; i++) { base += weights[i]; }
  const w: number = stage < weights.length ? weights[stage] : 0;
  const p: number = Math.max(0, Math.min(100, pctInStage));
  return Math.max(0, Math.min(100, base + w * p / 100));
}

// ---- 数据模型 ---------------------------------------------------------------

// 一行日志（seq 单调递增，作为 ForEach 的稳定 key；对象生成后不再修改任何字段）
export class LoadLogLine {
  seq: number = 0;
  ts: string = '';
  text: string = '';
  hi: boolean = false;   // 重点行（上传/完成）：更亮的绿 + 更强辉光
}

// 弹窗状态载体：由页面持有并驱动；弹窗通过 @ObjectLink 观察渲染
@Observed
export class LoadDlgModel {
  visible: boolean = false;
  fileName: string = '';
  fileMeta: string = '';
  stage: number = -1;      // 当前阶段 0..4；-1 = 全部完成
  stagePct: number = 0;    // 阶段内 0..100
  percent: number = 0;     // 全局 0..100（单调不回退）
  startMs: number = 0;
  logs: LoadLogLine[] = [];

  // ---- 模式（导入 / 切片共用同一套视觉，只换这几项文案与阶段链）----
  mode: string = 'import';                  // 'import' | 'slice'
  stages: string[] = LOAD_STAGES;           // 阶段链（胶囊文案）
  weights: number[] = STAGE_WEIGHT;         // 阶段权重（全局百分比合成）
  titleLabel: string = 'LOADING MODEL';     // 左上角标题
  lockText: string = '载入完成前界面不可操作'; // 底部锁定文案

  private seqCounter: number = 0;

  // 切模式：只改「阶段链 / 权重 / 标题 / 锁定文案」，不碰进度与日志。
  // 两个弹窗必须共用同一套视觉语言 —— 将来改样式只改本文件这一处。
  setMode(mode: string): void {
    this.mode = mode;
    if (mode === 'slice') {
      this.stages = SLICE_STAGES;
      this.weights = SLICE_WEIGHT;
      this.titleLabel = 'SLICING';
      this.lockText = '切片完成前界面不可操作';
    } else {
      this.stages = LOAD_STAGES;
      this.weights = STAGE_WEIGHT;
      this.titleLabel = 'LOADING MODEL';
      this.lockText = '载入完成前界面不可操作';
    }
  }

  // 打开弹窗：所有字段一次性重置（数组重新赋值以触发观察）
  reset(): void {
    this.visible = true;
    this.fileName = '';
    this.fileMeta = '';
    this.stage = -1;
    this.stagePct = 0;
    this.percent = 0;
    this.startMs = Date.now();
    this.logs = [];
    this.seqCounter = 0;
  }

  // 追加一行日志：一律「push 新对象 + 整体重新赋值数组」，绝不原地改已有行。
  // 整数组重新赋值是 @Observed 上的第一层属性变化，弹窗侧能观察到；行内字段不可变，
  // 因此缺少深层观察也不会出问题。
  pushLog(text: string, hi: boolean): void {
    const d: Date = new Date();
    const line: LoadLogLine = new LoadLogLine();
    this.seqCounter++;
    line.seq = this.seqCounter;
    line.ts = '[' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()) + ']';
    line.text = text;
    line.hi = hi;
    const arr: LoadLogLine[] = this.logs.slice();
    arr.push(line);
    while (arr.length > LOG_MAX_LINES) { arr.shift(); }   // 只保留最近 LOG_MAX_LINES 条（多留几行供上滑滑出）
    this.logs = arr;
  }

  // 最近一条日志文本（诊断：让页面侧能打出「界面状态被赋值成了什么」）
  lastLogText(): string {
    const n: number = this.logs.length;
    return n > 0 ? this.logs[n - 1].text : '';
  }

  // 只更新「数值状态」：全局百分比单调不回退、阶段只向前推进（晚到的旧进度不会把界面拽回去）。
  // 数值状态与日志行必须分开处理：数值可以「只取最新」地合并（合并是合理的），
  // 但日志行一旦跟着一起合并，主线程忙的时候几十条进度就会塌缩成一行 —— 所以日志走独立队列。
  applyNumeric(stage: number, pctInStage: number): void {
    if (stage > this.stage) {
      this.stage = stage;
      this.stagePct = pctInStage;
    } else if (stage === this.stage && pctInStage > this.stagePct) {
      this.stagePct = pctInStage;
    }
    const g: number = globalPercentWith(this.weights, this.stage, this.stagePct);
    if (g > this.percent) { this.percent = g; }
  }

  // 应用一条进度（数值 + 日志一次做完）：仅用于「页面主动推进」的少量收尾进度。
  // C++ 高频进度不要走这里 —— 那必须用 applyNumeric（合并）+ 页面侧日志队列（逐条）两条路。
  applyProgress(stage: number, pctInStage: number, msg: string): void {
    this.applyNumeric(stage, pctInStage);
    if (msg.length > 0) { this.pushLog(msg, stage >= 3); }
  }
}

function pad2(v: number): string {
  return v < 10 ? ('0' + v) : ('' + v);
}

// 进度回调用的小结构（JSON.parse 的结果按它取字段）
export class ProgressMsg {
  stage: number = 0;
  pct: number = 0;
  msg: string = '';
}

// 渲染用的一行（亮度分档在生成快照时算好；快照生成后不再变化）
class DisplayLine {
  key: string = '';
  ts: string = '';
  text: string = '';
  color: string = C_LOG_TEXT;
  shadow: string = SH_LOG_OFF;
}

function buildSegIndexes(): number[] {
  const a: number[] = [];
  for (let i = 0; i < SEG_COUNT; i++) { a.push(i); }
  return a;
}

const SEG_INDEXES: number[] = buildSegIndexes();

// =============================================================================

@Component
export struct LoadingDialog {
  @ObjectLink model: LoadDlgModel;

  // ---- 显示态 ----
  @State private pulseOn: boolean = false;    // 当前进度格呼吸
  @State private elapsedSec: number = 0;
  @State private etaSec: number = -1;         // -1 未知 / -2 已完成 / >=0 剩余秒数

  // ---- 日志区扫描线画布 ----
  private scanSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private scanCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.scanSettings);

  // ---- 日志上滑（位移 + 动画）----
  // 组件自己维护「当前已布局出来的行」快照 viewLines，不直接渲染 model.logs：
  // 这样「新日志到达」和「开始上滑」能在同一拍里一起完成，屏幕不会先跳到最新再被推回去。
  // 注意：日志行本身绝不在原地改字段，靠「新增行 → 快照整体重建 + key 含亮度档」刷新，
  // 避免重蹈「ForEach 读新建快照的字段建立不了观察依赖、界面停在第一个字」的覆辙。
  @State private viewLines: DisplayLine[] = [];
  @State private offsetY: number = 0;        // 日志内容垂直位移（px）：上滑动画只动它
  private lastLogSeq: number = 0;            // 已处理的最后一条日志序号（seq 单调，用来判「有新行」）
  private slideRunning: boolean = false;     // 是否有一段上滑动画在跑（跑完前不接新行，避免互相打断抖动）
  private slideToken: number = 0;            // 动画代次：复位/新一轮会让旧动画的 onFinish 失效（防拿到旧快照回滚画面）
  private animSource: LoadLogLine[] = [];    // 本段动画用的日志源快照（收尾时按它收敛，保证视觉连续）

  // ---- 定时器 ----
  private clockTimer: number = -1;
  private pulseTimer: number = -1;
  private logTimer: number = -1;

  aboutToAppear(): void {
    this.seedLogView();     // 首次布局：直接贴出最近 LOG_VISIBLE_LINES 行，不做动画
    // 已用 / 预计剩余：每 100ms 刷新
    this.clockTimer = setInterval(() => { this.tickClock(); }, 100);
    this.pulseTimer = setInterval(() => { this.pulseOn = !this.pulseOn; }, 550);
    // 日志上滑：@ObjectLink 拿不到属性变化回调，只能轮询判「有没有新行」（@ObjectLink 只在 build 时驱动重渲染）；
    // 判新行用「最后一条的 seq」（单调唯一），不能用数组长度 —— 到达保留上限后长度会稳定不变，会漏掉之后所有新行。
    this.logTimer = setInterval(() => { this.tickLog(); }, 60);
  }

  aboutToDisappear(): void {
    if (this.clockTimer !== -1) { clearInterval(this.clockTimer); this.clockTimer = -1; }
    if (this.pulseTimer !== -1) { clearInterval(this.pulseTimer); this.pulseTimer = -1; }
    if (this.logTimer !== -1) { clearInterval(this.logTimer); this.logTimer = -1; }
    this.slideRunning = false;
  }

  // ---------------------------------------------------------------------------
  // 时钟 / 日志上滑
  // ---------------------------------------------------------------------------
  private tickClock(): void {
    const el: number = Math.max(0, (Date.now() - this.model.startMs) / 1000);
    this.elapsedSec = el;
    const p: number = this.model.percent;
    if (this.model.stage < 0) {
      this.etaSec = -2;                              // 已进入终态
    } else if (p > 4 && el > 0.3) {
      this.etaSec = Math.max(0, el / p * (100 - p)); // 按当前平均速度线性外推
    } else {
      this.etaSec = -1;                              // 样本太少，先不猜
    }
  }

  // 首次布局 / 新一轮载入：直接贴出最近 LOG_VISIBLE_LINES 行，不做动画。
  private seedLogView(): void {
    const arr: LoadLogLine[] = this.model.logs;
    const n: number = arr.length;
    this.lastLogSeq = n > 0 ? arr[n - 1].seq : 0;
    this.offsetY = 0;
    this.slideRunning = false;
    this.slideToken++;      // 让这一拍之前发起的动画 onFinish 失效
    this.animSource = arr;
    this.viewLines = this.buildDisplay(arr, LOG_VISIBLE_LINES);
  }

  // 日志上滑：探测到新行 → 用「位移 + 一次动画」把内容整体上滑 N 行（cmd.exe 那种上滑）。
  // ① 先把「窗口下方多渲染 N 行」的快照放上去，此刻位移仍为 0 —— 屏幕显示的还是上一屏，不跳变；
  // ② 再在同一拍用 animateTo 把位移从 0 缓动到 -N×行高 —— 内容平滑上滑、新行从底部浮现；
  // ③ 动画跑完（onFinish）再把快照收敛回「最近 LOG_VISIBLE_LINES 行」并复位位移 —— 收敛前后显示的行完全一致。
  // ④ 动画进行中不接新行（等这一段落定，下一拍再一次性处理），避免互相打断造成抖动。
  // 判新行用「最后一条的 seq」（单调唯一），不用数组长度 —— 到达保留上限后长度会稳定不变，会漏掉之后所有新行。
  private tickLog(): void {
    const arr: LoadLogLine[] = this.model.logs;
    const n: number = arr.length;
    if (n <= 0) {
      // reset 后日志被清空：把窗口也清掉，别把上一轮的残行留在屏幕上。
      if (this.viewLines.length > 0) { this.seedLogView(); }
      return;
    }
    const seq: number = arr[n - 1].seq;
    if (seq < this.lastLogSeq) {
      // seq 回退 = 弹窗被 reset 后重新计数：按新一轮重建基线，不做动画。
      this.seedLogView();
      return;
    }
    if (seq === this.lastLogSeq) { return; }      // 没有新行就不动，避免无谓重排
    if (this.slideRunning) { return; }            // 上一段上滑还没跑完：这一拍先不动，避免打断抖动
    const added: number = this.lastLogSeq === 0 ? n : (seq - this.lastLogSeq);
    this.lastLogSeq = seq;
    if (n <= LOG_VISIBLE_LINES) {
      // 内容还没满窗口：不需要上滑（内容没满，谈不上「往上推」），直接正常渲染、位移保持 0。
      this.offsetY = 0;
      this.animSource = arr;
      this.viewLines = this.buildDisplay(arr, LOG_VISIBLE_LINES);
      return;
    }
    // 本次上滑行数不能超过「窗口下方还能缓冲的行数」，否则滑到最后底部会露出空档。
    const maxSlide: number = n - LOG_VISIBLE_LINES;
    const lines: number = added < maxSlide ? added : maxSlide;
    if (lines <= 0) { return; }
    // ① 快照：最近 LOG_VISIBLE_LINES+lines 行（多出来的 lines 行在窗口下方，供滑出）。
    this.slideToken++;
    const token: number = this.slideToken;
    this.animSource = arr;
    this.viewLines = this.buildDisplay(arr, LOG_VISIBLE_LINES + lines);
    this.slideRunning = true;
    const dist: number = lines * LOG_LINE_HEIGHT;
    hilog.info(0x0000, TAG, 'offset 动画：新增=%{public}d 位移=%{public}d 时长=%{public}d', lines, dist, LOG_SLIDE_MS);
    // ② 位移从当前(0) 缓动到 -dist：内容整体平滑上滑 lines 行。
    this.getUIContext().animateTo({
      duration: LOG_SLIDE_MS,
      curve: Curve.EaseOut,
      onFinish: () => { this.finishSlide(token); }
    }, () => {
      this.offsetY = -dist;
    });
  }

  // 上滑动画收尾：按本段动画的日志源把快照收敛回「最近 LOG_VISIBLE_LINES 行」，位移复位为 0。
  // 收敛前后显示的行完全一致（位移补上的那 lines 行 + 收敛掉的 lines 行正好互换），所以视觉无跳变。
  // token 对不上说明这期间发生过复位/新一轮，本次收尾作废（避免拿旧快照把画面滚回去）。
  private finishSlide(token: number): void {
    if (token !== this.slideToken) { return; }
    this.slideRunning = false;
    this.offsetY = 0;
    this.viewLines = this.buildDisplay(this.animSource, LOG_VISIBLE_LINES);
  }

  private elapsedText(): string {
    return this.elapsedSec.toFixed(1) + 's';
  }

  private etaText(): string {
    if (this.etaSec === -2) { return '已完成'; }
    if (this.etaSec < 0) { return '—'; }
    return this.etaSec.toFixed(1) + 's';
  }

  // ---------------------------------------------------------------------------
  // 进度条 / 阶段链状态
  // ---------------------------------------------------------------------------
  private segColor(i: number): string {
    const lit: number = Math.round(this.model.percent / 100 * SEG_COUNT);
    if (i < lit - 1) { return C_ACC; }
    if (i === lit - 1) { return this.pulseOn ? '#48B37C' : '#2C6B4C'; }
    return '#26262F';
  }

  private phaseState(i: number): number {   // 0 未开始 / 1 进行中 / 2 已完成
    const st: number = this.model.stage;
    if (st < 0) { return 2; }
    if (i < st) { return 2; }
    if (i === st) { return 1; }
    return 0;
  }

  // 进行中的胶囊直接写「阶段名 N%」（原型就是这么做的）
  private phaseText(i: number): string {
    const stages: string[] = this.model.stages;
    const name: string = i < stages.length ? stages[i] : ('stage' + i);
    if (this.phaseState(i) === 1) {
      return name + ' ' + Math.round(this.model.stagePct) + '%';
    }
    return name;
  }

  private phaseFg(i: number): string {
    const s: number = this.phaseState(i);
    if (s === 2) { return C_ACC; }
    if (s === 1) { return '#08261A'; }
    return C_TEXT3;
  }

  private phaseBg(i: number): string {
    const s: number = this.phaseState(i);
    if (s === 2) { return C_ACC_DIM; }
    if (s === 1) { return C_ACC; }
    return '#16161D';
  }

  private phaseBorder(i: number): string {
    const s: number = this.phaseState(i);
    if (s === 2) { return C_ACC_LINE; }
    if (s === 1) { return C_ACC; }
    return C_BORDER;
  }

  // ---------------------------------------------------------------------------
  // 日志行（离底部越远越暗，形成纵深）
  // 这里返回的是「普通对象快照」：ForEach 的条目不会因为快照里的普通字段变化而刷新，
  // 所以 text/ts/hi 一律在生成快照时定死、之后不再变；唯一会变的是「亮度档」（取决于它离
  // 底部多远，行数越多越按梯度压暗）。把亮度档编进 key —— 档位变化 → key 变化 → ForEach
  // 重建该行。这条正是防「只显示一个字」的命门：绝不用会与内容变化脱钩的稳定 key。
  // ---------------------------------------------------------------------------
  private brightnessTier(distFromBottom: number): number {
    if (distFromBottom <= 4) { return 0; }    // 最新 5 行：最亮
    if (distFromBottom <= 9) { return 1; }
    if (distFromBottom <= 15) { return 2; }
    return 3;                                 // 更早：最暗
  }

  // 从日志源里取「最近 takeLast 行」生成渲染快照（takeLast 就是本次要渲染的行数）。
  // 生成的是「普通对象快照」：ForEach 的条目不会因为快照里的普通字段变化而刷新，
  // 所以 text/ts/hi 一律在生成快照时定死、之后不再变；唯一会变的是「亮度档」（取决于它离
  // 最新一行多远）。把亮度档编进 key —— 档位变化 → key 变化 → ForEach 重建该行。
  // 这条正是防「只显示一个字」的命门：绝不用会与内容变化脱钩的稳定 key。
  private buildDisplay(src: LoadLogLine[], takeLast: number): DisplayLine[] {
    const out: DisplayLine[] = [];
    const n: number = src.length;
    let start: number = n - takeLast;
    if (start < 0) { start = 0; }
    for (let i = start; i < n; i++) {
      const row: LoadLogLine = src[i];
      const dist: number = n - 1 - i;          // 离最新一行越远越大
      const tier: number = this.brightnessTier(dist);
      const d: DisplayLine = new DisplayLine();
      // key 含序号 + 亮度档 + 重点标记：任何会改变本行渲染结果的量都进 key
      d.key = '' + row.seq + '_' + tier + '_' + (row.hi ? '1' : '0');
      d.ts = row.ts;
      d.text = row.text;                       // 整行一次性写入，不再逐字（禁用打字机）
      if (tier === 0) {
        d.color = row.hi ? C_LOG_HI : C_LOG_TEXT;
        d.shadow = row.hi ? SH_LOG_HI : SH_LOG_0;
      } else if (tier === 1) {
        d.color = C_LOG_T1;
        d.shadow = SH_LOG_1;
      } else if (tier === 2) {
        d.color = C_LOG_T2;
        d.shadow = SH_LOG_2;
      } else {
        d.color = C_LOG_DIM;
        d.shadow = SH_LOG_OFF;
      }
      out.push(d);
    }
    return out;
  }

  // 日志区扫描线：静态内容，onReady 时画一次即可
  private drawScanlines(): void {
    const ctx: CanvasRenderingContext2D = this.scanCtx;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 1 || h <= 1) { return; }
    try {
      ctx.clearRect(0, 0, w, h);
      ctx.lineWidth = 1;
      ctx.strokeStyle = '#0C35D07F';
      ctx.beginPath();
      for (let y = 0; y < h; y += 3) {
        ctx.moveTo(0, y + 0.5);
        ctx.lineTo(w, y + 0.5);
      }
      ctx.stroke();
    } catch (err) {
      hilog.warn(0x0000, TAG, 'drawScanlines failed');
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @Builder
  header() {
    Column() {
      Row() {
        Text(this.model.titleLabel)
          .fontSize(10.5)
          .letterSpacing(2)
          .fontColor(C_ACC)
          .fontFamily(MONO_FONT)
        Blank()
        Text('' + Math.round(this.model.percent))
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT1)
          .fontFamily(MONO_FONT)
        Text('%')
          .fontSize(13)
          .fontColor(C_TEXT3)
          .margin({ left: 2, bottom: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Row() {
        Text(this.model.fileName)
          .fontSize(13.5)
          .fontColor(C_TEXT1)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.model.fileMeta)
          .fontSize(11.5)
          .fontColor(C_TEXT3)
          .fontFamily(MONO_FONT)
          .maxLines(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ top: 9 })
      .alignItems(VerticalAlign.Center)

      // 分段进度条：34 格，on / act 两态，当前格呼吸脉冲
      Row({ space: 2 }) {
        ForEach(SEG_INDEXES, (i: number) => {
          Column()
            .layoutWeight(1)
            .height(6)
            .borderRadius(1)
            .backgroundColor(this.segColor(i))
            .animation({ duration: 260, curve: Curve.EaseOut })
        }, (i: number) => i.toString())
      }
      .width('100%')
      .height(6)
      .margin({ top: 13 })

      // 阶段链
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.model.stages, (name: string, i: number) => {
          Text(this.phaseText(i))
            .fontSize(10.5)
            .fontFamily(MONO_FONT)
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
            .borderRadius(999)
            .margin({ right: 6, top: 6 })
            .maxLines(1)
            .fontColor(this.phaseFg(i))
            .backgroundColor(this.phaseBg(i))
            .border({ width: 1, color: this.phaseBorder(i) })
            .animation({ duration: 220, curve: Curve.EaseOut })
        }, (name: string, i: number) => name)
      }
      .width('100%')
      .margin({ top: 5 })
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 18, bottom: 14 })
    .border({ width: { bottom: 1 }, color: C_LINE })
  }

  // 日志区：占满整行（旋转线框预览已移除，不要加回）。固定高度的窗口（clip(true)），
  // 里面就是一个普通 Column 逐行渲染 —— 回到「最开始那版」的结构，没有滚动容器、没有滚动条。
  // 新行追加时不用 Scroll，改为给这个 Column 一个垂直位移并缓动归 0：
  // 先把内容整体下推「新增行数 × 行高」（此时屏幕显示的仍是上一屏，不跳变），再动画把位移归 0，
  // 视觉上内容就平滑向上滑、新行从底部浮现。不要用 Scroll + 自动滚到底（会跳变/居中/不跟手）。
  @Builder
  logPanel() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 日志内容：普通 Column，从顶部排（内容不满时贴顶，不会被居中）；位移只作用在它身上。
        Column() {
          ForEach(this.viewLines, (ln: DisplayLine) => {
            Row() {
              Text(ln.ts)
                .fontSize(11.5)
                .fontFamily(MONO_FONT)
                .fontColor(C_LOG_TS)
              Text(ln.text)
                .fontSize(11.5)
                .fontFamily(MONO_FONT)
                .fontColor(ln.color)
                .textShadow({ radius: 12, color: ln.shadow, offsetX: 0, offsetY: 0 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 8 })
                .layoutWeight(1)
            }
            .width('100%')
            .height(LOG_LINE_HEIGHT)
            .alignItems(VerticalAlign.Center)
          }, (ln: DisplayLine) => ln.key)
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)      // 内容从顶部开始排（不依赖默认值）
        .padding({ left: 13, right: 13 })
        .translate({ y: this.offsetY })       // 上滑动画：位移量 = 本次新增行数 × LOG_LINE_HEIGHT

        // 顶部 26px 渐隐遮罩（不拦截手势：否则从顶部起的拖动会被它吃掉）
        Column()
          .width('100%')
          .height(26)
          .linearGradient({
            angle: 180,
            colors: [['#FF080A09', 0.0], ['#00080A09', 1.0]]
          })
          .hitTestBehavior(HitTestMode.None)

        // 极淡横向扫描线
        Canvas(this.scanCtx)
          .width('100%')
          .height(LOG_PANEL_HEIGHT)
          .opacity(0.32)
          .hitTestBehavior(HitTestMode.None)
          .onReady(() => { this.drawScanlines(); })
      }
      .width('100%')
      .height(LOG_PANEL_HEIGHT)      // 固定 px 高度 → 超出部分被裁掉（不依赖父容器百分比）
      .backgroundColor(C_LOG_BG)
      .border({ width: 1, color: C_LOG_BORDER })
      .borderRadius(10)
      .clip(true)
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .margin({ top: 14 })
  }

  @Builder
  footer() {
    Row() {
      Text('已用')
        .fontSize(11)
        .fontColor(C_TEXT3)
        .fontFamily(MONO_FONT)
      Text(this.elapsedText())
        .fontSize(11)
        .fontColor(C_TEXT2)
        .fontFamily(MONO_FONT)
        .margin({ left: 5 })
      Text('预计剩余')
        .fontSize(11)
        .fontColor(C_TEXT3)
        .fontFamily(MONO_FONT)
        .margin({ left: 16 })
      Text(this.etaText())
        .fontSize(11)
        .fontColor(C_TEXT2)
        .fontFamily(MONO_FONT)
        .margin({ left: 5 })
      Blank()
      Column()
        .width(9)
        .height(9)
        .borderRadius(2)
        .backgroundColor(C_ACC_DIM)
        .border({ width: 1, color: C_ACC_LINE })
      // 载入只由 onLoadDone / failLoad 结束，等待期间不给任何「等太久」的提示：文案随模式固定。
      Text(this.model.lockText)
        .fontSize(11)
        .fontColor(C_TEXT3)
        .fontFamily(MONO_FONT)
        .margin({ left: 7 })
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 14, bottom: 18 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  panel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.header()
        this.logPanel()
        this.footer()
      }
      .width('100%')

      // 四角 12px 直角刻度
      Column()
        .width(12).height(12).opacity(0.5)
        .border({ width: { left: 1, top: 1 }, color: C_ACC })
        .borderRadius({ topLeft: 3 })
        .align(Alignment.TopStart)
        .margin({ left: 8, top: 8 })
      Column()
        .width(12).height(12).opacity(0.5)
        .border({ width: { right: 1, top: 1 }, color: C_ACC })
        .borderRadius({ topRight: 3 })
        .align(Alignment.TopEnd)
        .margin({ right: 8, top: 8 })
      Column()
        .width(12).height(12).opacity(0.5)
        .border({ width: { left: 1, bottom: 1 }, color: C_ACC })
        .borderRadius({ bottomLeft: 3 })
        .align(Alignment.BottomStart)
        .margin({ left: 8, bottom: 8 })
      Column()
        .width(12).height(12).opacity(0.5)
        .border({ width: { right: 1, bottom: 1 }, color: C_ACC })
        .borderRadius({ bottomRight: 3 })
        .align(Alignment.BottomEnd)
        .margin({ right: 8, bottom: 8 })
    }
    .width('92%')
    .constraintSize({ maxWidth: 672 })
    .borderRadius(16)
    .border({ width: 1, color: '#33333F' })
    .linearGradient({
      angle: 180,
      colors: [['#F9181820', 0.0], ['#FB0E0E13', 1.0]]
    })
  }

  build() {
    Stack() {
      // 遮罩：吃掉全部手势 → 载入完成前界面不可操作（强制弹窗，无取消按钮）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#A8060609')
        .hitTestBehavior(HitTestMode.Block)

      this.panel()
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}

// 供页面复用的进度 JSON 解析（失败返回 null，调用方自己决定兜底）
export function parseProgressJson(json: string): ProgressMsg | null {
  try {
    const p: ProgressMsg = JSON.parse(json) as ProgressMsg;
    if (typeof p.stage !== 'number' || typeof p.pct !== 'number') { return null; }
    return p;
  } catch (e) {
    return null;
  }
}
