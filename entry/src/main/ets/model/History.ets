import { modelState, ModelSnapshot } from './ModelState';
import { SliceParamStore } from '../service/SliceParamStore';
import { docState } from './DocState';
import { autoBackup } from '../service/AutoBackup';

// =============================================================================
// 撤销 / 重做栈（快照式）
//
// 覆盖范围 = **工程内容**：对象与摆放（增删/复制/剪切/粘贴/变换）+ 盘 + 对象级参数覆盖
//            + **全局参数覆盖**（改切片参数也能撤销，见 paramsBefore/paramsAfter）。
//
// 两个关键设计：
//   ① **持久基线**：History 始终持有「当前已提交状态」的快照（baseline + baselineParams），
//      新编辑的「前」就是它 —— 不在 mark 时拍快照。这样 mark 变成零成本，可以放在每帧都会走的
//      收尾函数里；也不会出现「拖拽第一帧的位移已算进 before」导致撤销后残留偏移。
//   ② **标记 + 防抖**：mark 只记「有编辑发生 + 操作名」，静默 350ms 才入栈 → 一次拖拽 = 一步；
//      离散操作（删除/复制/粘贴/导入/参数提交）用 commitNow 立即入栈。
//      另有最长等待 MAX_WAIT_MS：防止标记被周期性调用把防抖无限推后（那样栈里永远空着）。
//
// 摘要比较**刻意排除选中集合与当前盘**：它们只是 UI 状态，变了不算编辑。
//
// 另一半正确性来自 ModelState.restore()：它必须**克隆**快照内容再当活动状态，
// 否则活动对象被就地改写会同步污染基线（症状：撤销/重做跳到莫名位置、之后编辑不再入栈）。
// =============================================================================
class HistoryEntry {
  label: string = '';
  before: ModelSnapshot | null = null;
  after: ModelSnapshot | null = null;
  paramsBefore: Map<string, number> = new Map<string, number>();
  paramsAfter: Map<string, number> = new Map<string, number>();
}

const MAX_STEPS: number = 50;
const DEBOUNCE_MS: number = 350;
const MAX_WAIT_MS: number = 1200;

export class History {
  private undoStack: HistoryEntry[] = [];
  private redoStack: HistoryEntry[] = [];
  private baseline: ModelSnapshot | null = null;
  private baselineParams: Map<string, number> | null = null;
  private pendingLabel: string = '';
  private timer: number = -1;
  private firstMarkAt: number = 0;
  private rev: number = 0;

  private ensureBaseline(): ModelSnapshot {
    if (this.baseline === null) {
      this.baseline = modelState.snapshot();
    }
    if (this.baselineParams === null) {
      this.baselineParams = SliceParamStore.snapshotUserOverrides();
    }
    return this.baseline;
  }

  private ensureBaselineParams(): Map<string, number> {
    this.ensureBaseline();
    return this.baselineParams !== null ? this.baselineParams : new Map<string, number>();
  }

  // 标记「有编辑发生」：只记操作名 + 重置防抖计时（不拍快照，可高频调用）
  mark(label: string): void {
    const now: number = Date.now();
    if (this.firstMarkAt === 0) {
      this.firstMarkAt = now;
    } else if (now - this.firstMarkAt >= MAX_WAIT_MS) {
      // 已经等够了：即使还在被连续标记也先落定这一步（否则防抖会被无限推后）
      this.pendingLabel = label;
      this.clearTimer();
      this.flush();
      return;
    }
    this.pendingLabel = label;
    this.clearTimer();
    this.timer = setTimeout((): void => {
      this.timer = -1;
      this.flush();
    }, DEBOUNCE_MS);
  }

  // 离散操作：立即入栈（删除 / 复制 / 粘贴 / 参数提交 等）
  commitNow(label: string): void {
    this.mark(label);
    this.clearTimer();
    this.flush();
  }

  private clearTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  // 把待提交的编辑落定；与基线无实质差异则不入栈
  flush(): void {
    // 自动备份的「有变更」信号：flush 是全工程唯一的提交点（编辑落定 / 撤销 / 重做 / 导入
    // 都会经过这里），所以在这里重置防抖计时最省事，也不必让每个编辑入口各排一次。
    // 它只碰计时器、不做 I/O；「该不该备」由 AutoBackup 在计时器到期时再判。
    autoBackup.arm();
    const before: ModelSnapshot = this.ensureBaseline();
    const beforeParams: Map<string, number> = this.ensureBaselineParams();
    const label: string = this.pendingLabel;
    this.pendingLabel = '';
    this.firstMarkAt = 0;
    const after: ModelSnapshot = modelState.snapshot();
    const afterParams: Map<string, number> = SliceParamStore.snapshotUserOverrides();

    // 防御：从「空板」变成「有对象」且栈还是空的 → 这是一次文档载入（导入/打开），不是用户编辑。
    // 导入过程本身会触发 mark（逐对象加入 + 场景重建），而导入耗时可能超过防抖窗口，
    // 若不这样兜住，就会留下「before = 空板」的条目 → 按一下撤销直接回到「没导入」的样子。
    if (before.objects.length === 0 && after.objects.length > 0 && this.undoStack.length === 0) {
      this.baseline = after;
      this.baselineParams = afterParams;
      this.bump();
      // 这是一次文档载入（导入/打开），不算用户编辑；但工程内容确实变了 →
      // 交给 DocState 按「当前摘要 vs 保存基准」判脏（首次导入无基准 → 脏，正确）。
      docState.noteChange(this.digest(after, afterParams));
      return;
    }

    if (this.digest(before, beforeParams) === this.digest(after, afterParams)) {
      return;
    }
    const e: HistoryEntry = new HistoryEntry();
    e.label = label.length > 0 ? label : '编辑';
    e.before = before;
    e.after = after;
    e.paramsBefore = beforeParams;
    e.paramsAfter = afterParams;
    this.undoStack.push(e);
    if (this.undoStack.length > MAX_STEPS) {
      this.undoStack.shift();
    }
    // 新编辑让「重做」失效（标准语义）
    this.redoStack = [];
    this.baseline = after;
    this.baselineParams = afterParams;
    this.bump();
    // 真有一次编辑落定 → 让文档状态判脏（与上次保存的摘要一致时不会变脏）
    docState.noteChange(this.digest(after, afterParams));
  }

  // 当前工程内容的摘要：保存 / 打开工程时记一份当作「已保存基准」（见 DocState）
  currentDigest(): string {
    return this.digest(modelState.snapshot(), SliceParamStore.snapshotUserOverrides());
  }

  // 返回被撤销的操作名（空串 = 无可撤销）
  undo(): string {
    this.clearTimer();
    this.flush(); // 先把防抖窗口里那次编辑落定，否则「点撤销时它还没入栈」
    if (this.undoStack.length === 0) {
      return '';
    }
    const e: HistoryEntry | undefined = this.undoStack.pop();
    if (e === undefined) {
      return '';
    }
    if (e.before !== null) {
      modelState.restore(e.before);
      this.baseline = e.before;
      // 撤销后的状态摘要就是 e.before → 若正好回到「上次保存」那一刻，脏标记会自动消失
      docState.noteChange(this.digest(e.before, e.paramsBefore));
    }
    SliceParamStore.restoreUserOverrides(e.paramsBefore);
    this.baselineParams = e.paramsBefore;
    this.redoStack.push(e);
    modelState.publish();
    this.signalParamRestore();
    this.bump();
    return e.label;
  }

  redo(): string {
    this.clearTimer();
    this.flush();
    if (this.redoStack.length === 0) {
      return '';
    }
    const e: HistoryEntry | undefined = this.redoStack.pop();
    if (e === undefined) {
      return '';
    }
    if (e.after !== null) {
      modelState.restore(e.after);
      this.baseline = e.after;
      // 同 undo：重做后按新状态判脏
      docState.noteChange(this.digest(e.after, e.paramsAfter));
    }
    SliceParamStore.restoreUserOverrides(e.paramsAfter);
    this.baselineParams = e.paramsAfter;
    this.undoStack.push(e);
    modelState.publish();
    this.signalParamRestore();
    this.bump();
    return e.label;
  }

  // 有已入栈的操作，或有一次编辑还在防抖窗口里 → 按钮应可点
  canUndo(): boolean {
    return this.undoStack.length > 0 || this.timer >= 0;
  }

  canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  undoLabel(): string {
    return this.undoStack.length > 0 ? this.undoStack[this.undoStack.length - 1].label : '';
  }

  redoLabel(): string {
    return this.redoStack.length > 0 ? this.redoStack[this.redoStack.length - 1].label : '';
  }

  depth(): number {
    return this.undoStack.length;
  }

  // 重建基线并清空历史：**导入/打开新文件后必须调用** ——
  // 否则新文档的第一次编辑会把「上一个文档的状态」当成 before，撤销一下会串到旧文档。
  // 注意：这里**不广播 paramRestoreSeq** —— 导入会把文件里的设置写回参数面板，
  // 若此刻让面板「按覆盖表重放」，会把刚导入的设置冲回预设默认值。
  reset(): void {
    this.clearTimer();
    this.undoStack = [];
    this.redoStack = [];
    this.pendingLabel = '';
    this.firstMarkAt = 0;
    this.baseline = modelState.snapshot();
    this.baselineParams = SliceParamStore.snapshotUserOverrides();
    this.bump();
  }

  // 通知参数面板「覆盖表被撤销/重做改过了，请重放」——
  // History 无法直接命令面板刷新，用 AppStorage 序号广播（与 renderResumeSeq 同一套路）。
  private signalParamRestore(): void {
    const seq: number = AppStorage.get<number>('paramRestoreSeq') ?? 0;
    AppStorage.setOrCreate<number>('paramRestoreSeq', seq + 1);
  }

  // 结构摘要：只含「编辑语义」的内容（对象/摆放/盘/对象参数覆盖/全局参数覆盖），
  // 不含选中态与当前盘 —— 它们只是 UI 状态。
  private digest(s: ModelSnapshot, params: Map<string, number>): string {
    let out: string = `n=${s.objects.length}`;
    for (const o of s.objects) {
      const t = o.transform;
      out += `|${o.id},${o.name},${o.plate},${o.displayColor},${o.filamentName}` +
        `,${t.position.x.toFixed(3)},${t.position.y.toFixed(3)},${t.position.z.toFixed(3)}` +
        `,${t.rotX.toFixed(2)},${t.rotY.toFixed(2)},${t.rotZ.toFixed(2)}` +
        `,${t.scale.x.toFixed(4)},${t.scale.y.toFixed(4)},${t.scale.z.toFixed(4)}` +
        `,${t.baseRotation.x.toFixed(4)},${t.baseRotation.y.toFixed(4)},${t.baseRotation.z.toFixed(4)},${t.baseRotation.w.toFixed(4)}`;
    }
    out += `|p=${s.plates.length}:`;
    for (const p of s.plates) {
      out += `${p.index}/${p.name}/${p.bed};`;
    }
    out += `|ov=${s.objectOverrides.size}:`;
    s.objectOverrides.forEach((b: Map<string, number>, id: number): void => {
      out += `${id}{`;
      b.forEach((v: number, k: string): void => {
        out += `${k}=${v};`;
      });
      out += '}';
    });
    // 全局参数覆盖：按键名排序后拼接，避免 Map 顺序差异造成「假差异」
    const keys: string[] = [];
    params.forEach((v: number, k: string): void => {
      keys.push(k);
    });
    keys.sort();
    out += `|pr=${keys.length}:`;
    for (const k of keys) {
      out += `${k}=${params.get(k)};`;
    }
    return out;
  }

  // 栈变化广播：UI 据此更新按钮禁用态与标签（AppStorage 是跨组件唯一可观察的通道）
  private bump(): void {
    this.rev++;
    AppStorage.setOrCreate<number>('historyRev', this.rev);
    AppStorage.setOrCreate<boolean>('historyCanUndo', this.undoStack.length > 0 || this.timer >= 0);
    AppStorage.setOrCreate<boolean>('historyCanRedo', this.redoStack.length > 0);
    AppStorage.setOrCreate<string>('historyUndoLabel', this.undoLabel());
    AppStorage.setOrCreate<string>('historyRedoLabel', this.redoLabel());
  }
}

export const history: History = new History();
