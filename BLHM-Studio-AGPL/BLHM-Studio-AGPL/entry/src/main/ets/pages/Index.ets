import { Theme } from '../common/Theme';
import { TopBar } from '../view/TopBar';
import { LeftNav } from '../view/LeftNav';
import { ObjectList } from '../view/ObjectList';
import { DynamicParamsPanel } from '../view/DynamicParamsPanel';
import { ModelPreviewPage } from '../view/ModelPreviewPage';
import { DevicePanel } from '../view/DevicePanel';
import { CalibrationPanel } from '../view/CalibrationPanel';
import { LogPanel } from '../view/LogPanel';
import { SettingsPanel } from '../view/SettingsPanel';
import { TipPanel } from '../view/TipPanel';
import { FilamentEditor } from '../view/FilamentEditor';
import { SliceBar } from '../view/SliceBar';
import { PrintDialog } from '../view/PrintDialog';
import { PrintOptions, PrintOptionsSnapshot, PrintDeviceInfo, AmsSlot, PrintTaskPlan, PRINT_DLG_TAG, UploadOutcome } from '../service/PrintOptions';
import { FilamentGrouping } from '../service/FilamentGrouping';
import { SliceParamStore } from '../service/SliceParamStore';
import { SlicerService } from '../service/SlicerService';
import { SliceResult, Project3mfResult, PlateMeta } from '../model/Models';
import { ThreeMfImport, Import3mfOutcome } from '../service/ThreeMfImport';
import { ThreeMfExport, ExportBundle, SAVE3MF_TAG, GcodePackage, Mf3mfWriteResult } from '../service/ThreeMfExport';
import { GcodePreview } from '../view/GcodePreview';
import { PlateList } from '../view/PlateList';
import { plateBedEnumIndex } from '../service/PlateActions';
import { gcodeSignals } from '../model/GcodeToolpath';
import { LoadingDialog, LoadDlgModel, ProgressMsg, parseProgressJson } from '../view/LoadingDialog';
import { PresetCatalog } from '../model/SliceModels';
import { PresetPersist, PresetSnapshot } from '../service/PresetPersist';
import { IAP_ENTRY_VISIBLE } from '../service/IapService';
import { modelState, ModelInstance } from '../model/ModelState';
import { history } from '../model/History';
import { docState } from '../model/DocState';
import { docGuard } from '../service/DocGuard';
import { autoBackup, BackupInfo, BACKUP_MAX_BYTES } from '../service/AutoBackup';
import { MqttService } from '../service/MqttService';
import { HmsHit } from '../service/HmsTable';
import { common } from '@kit.AbilityKit';
import { objClipboard } from '../model/ObjClipboard';
import { confirmDeleteObjects } from '../service/ObjActions';
import { KeyCode } from '@kit.InputKit';
import { ensureThumbnail, dropThumbnail } from '../model/Thumbnail';
import { AppLog } from '../service/AppLog';
import { SliceCache } from '../service/SliceCache';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import promptAction from '@ohos.promptAction';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';

// 切片弹窗相关日志 tag（异常一律打 hilog，不吞）
const TAG: string = 'SliceDlg';

// 面板宽度自证日志 tag（本次新增 tag，不改动任何既有 tag）
const PANEL_TAG: string = 'PanelWidth';

// ---- 窄屏（短边）判定：不再用于「隐藏侧栏」，只用于给窄屏一个较窄的初始面板宽度 ----
// 桌面三栏（左导航 64 + 对象列表 + 3D + 参数面板）。窄屏判定只影响「首帧初值」，
// 侧栏本身在任何设备上都常驻显示（手机已被强制横屏，横屏宽度约 780vp，足够容纳两侧栏 + 中栏）。
// 用短边（而非宽度）判定：手机强制横屏后宽度变大，按宽度会误判成宽屏。
const NARROW_WIDTH_VP: number = 600;

// ---- 面板宽度拖动约束（vp）----
// 左「对象」栏 / 右「编辑」面板的可拖范围；中栏（3D 视口）始终至少留 CENTER_MIN。
const LEFT_MIN: number = 160;
const LEFT_MAX: number = 360;
const RIGHT_MIN: number = 220;
const RIGHT_MAX: number = 480;
const CENTER_MIN: number = 240;
// 拖动手柄宽度（vp）：加宽到 12 —— 此前 6vp 的细条用户反馈“谁看得见”。
// 手柄位于两侧面板之间，不压住内容；中栏最小宽仍由 CENTER_MIN 统一保证（夹取计算同步用本值）。
const HANDLE_W: number = 12;

// 面板宽度持久化快照。为什么单独建类而不是匿名对象：ArkTS 反序列化需要明确字段类型（不允许 any）。
class PanelWidthSnapshot {
  left: number = 220;
  right: number = 320;
}

// 逐盘切片结果：多盘时「默认切全部盘」逐盘产出，每盘的结果与盘号关联保存。
// 失败时据此点名是哪一盘、什么原因（不整体崩）。
class PlateOutcome {
  plate: number = 0;
  ok: boolean = false;
  output: string = '';
  layers: number = 0;
  grams: number = 0;
  est: string = '';
  message: string = '';
}

// 日志渲染节流与队列上限（与导入弹窗同一套规则：数值可合并、日志一条不丢）
const LOG_FLUSH_INTERVAL_MS: number = 130;
const LOG_QUEUE_MAX: number = 200;

// 让出一帧：把控制权交回事件循环，让已更新的进度 / 日志真正绘制出来
function yieldToUi(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => { resolve(); }, 0);
  });
}

function fmtSize(bytes: number): string {
  if (bytes <= 0) { return '未知大小'; }
  if (bytes >= 1024 * 1024) { return (bytes / (1024 * 1024)).toFixed(1) + ' MB'; }
  return Math.round(bytes / 1024).toString() + ' KB';
}

// 主界面：Bambu Studio 桌面端布局（准备/预览/设备/校准）
@Entry
@Component
struct Index {
  @State activeTab: number = 0; // 0准备 1预览 2设备 3校准 4日志 5设置 6打赏

  // 撤销：History 内部完成 restore + publish；这里只补「撤销后必须重建的 UI 副作用」——
  // 对象缩略图（删除时已 dropThumbnail 释放过，撤销把对象带回来就得重建）。
  private doUndo(): void {
    const label: string = history.undo();
    if (label === '') {
      promptAction.showToast({ message: '没有可撤销的操作' });
      return;
    }
    this.afterHistoryJump();
    promptAction.showToast({ message: `已撤销：${label}` });
  }

  private doRedo(): void {
    const label: string = history.redo();
    if (label === '') {
      promptAction.showToast({ message: '没有可重做的操作' });
      return;
    }
    this.afterHistoryJump();
    promptAction.showToast({ message: `已重做：${label}` });
  }

  // 历史跳转后的收尾：补缩略图 + 落日志（对象数/栈深便于排查「撤销后界面没变」）
  private afterHistoryJump(): void {
    for (const inst of modelState.instances) {
      ensureThumbnail(inst.id, inst.geometry);
    }
    this.sliceLog(`历史跳转 撤销栈深=${history.depth()} 对象=${modelState.instances.length}`);
  }

  // 工作区快捷键（PC / 2in1）：Ctrl+C 复制对象、Ctrl+V 粘贴、Ctrl+Z 撤销、Ctrl+Shift+Z 重做。
  // 为什么挂在工作区根容器上：输入框会自己消费文本编辑类按键（不会冒泡到这里），
  // 因此「在参数输入框里按 Ctrl+C」仍然是复制文本，不会被我们抢走。
  //
  // 修饰键状态**自己跟踪**（按下 / 抬起都记）而不是调 event.getModifierKeyState：
  // 该接口在不同 API 版本里返回类型不一致（同步 boolean / 异步 Promise），跟踪按键状态更稳。
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;

  private onWorkspaceKey(event: KeyEvent): void {
    const code: number = event.keyCode;
    const down: boolean = event.type === KeyType.Down;
    // 先维护修饰键状态（按下与抬起都要记，否则抬起后就一直以为是按着）
    if (code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT) {
      this.ctrlDown = down;
      // 同时广播到 AppStorage：列表行点击要靠它判断「Ctrl+点击 = 加选」，
      // 而那个点击回调拿不到按键事件（跨组件只能走 AppStorage）。
      AppStorage.setOrCreate<boolean>('ctrlDown', down);
      return;
    }
    if (code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT) {
      this.shiftDown = down;
      return;
    }
    if (!down || !this.ctrlDown) {
      // Delete / Backspace：直接删除选中对象（**不需要 Ctrl**）—— 与桌面习惯一致
      if (down && (code === KeyCode.KEYCODE_DEL || code === KeyCode.KEYCODE_FORWARD_DEL)) {
        const ids: number[] = modelState.selectedIds.slice();
        if (ids.length === 0) {
          promptAction.showToast({ message: '先选中要删除的对象' });
          return;
        }
        confirmDeleteObjects(this.getUIContext(), ids);
      }
      return;
    }
    if (code === KeyCode.KEYCODE_S) {
      // Ctrl+S = 保存（已有当前文件则直接覆盖写，否则退化成另存为）—— 桌面软件的标准习惯
      this.saveCurrent();
      return;
    }
    if (code === KeyCode.KEYCODE_A) {
      // 全选：多盘时只选「当前盘 + 未分盘」的对象（与列表显示、3D 可见性同一口径），
      // 否则手柄会作用到看不见的对象上。
      const cur: number = AppStorage.get<number>('activePlate') ?? -1;
      const n: number = modelState.selectAllOnPlate(cur);
      promptAction.showToast({ message: n > 0 ? `已全选 ${n} 个对象` : '当前盘没有对象' });
      return;
    }
    if (code === KeyCode.KEYCODE_C) {
      const ids: number[] = modelState.selectedIds;
      if (ids.length === 0) {
        promptAction.showToast({ message: '先选中一个对象再复制' });
        return;
      }
      const n: number = objClipboard.copy(ids);
      promptAction.showToast({ message: n > 0 ? `已复制 ${n} 个对象到剪贴板` : '复制失败' });
      return;
    }
    if (code === KeyCode.KEYCODE_V) {
      const cur: number = AppStorage.get<number>('activePlate') ?? -1;
      const ids: number[] = objClipboard.paste(cur > 0 ? cur : -1);
      if (ids.length === 0) {
        promptAction.showToast({ message: '剪贴板为空' });
        return;
      }
      for (const nid of ids) {
        const o = modelState.get(nid);
        if (o !== undefined) {
          ensureThumbnail(nid, o.geometry);
        }
      }
      history.commitNow('粘贴对象');
      promptAction.showToast({ message: `已粘贴 ${ids.length} 个对象` });
      return;
    }
    if (code === KeyCode.KEYCODE_Z) {
      if (this.shiftDown) {
        this.doRedo();
      } else {
        this.doUndo();
      }
    }
  }
  @State showFilament: boolean = false;
  @State slicing: boolean = false;
  @State sliceResult: string = '';
  // 切片失败原因：toast 一闪而过且可能被截断，这里常驻显示一份（诊断信息较长）
  @State sliceError: string = '';
  // 「预览」页的显示模式：0=模型 1=切片路径
  @State previewMode: number = 0;
  // 多盘文件的盘列表（与准备页 / 切片路径页盘列表同一份数据源）：>=2 时切片路径态渲染右侧可点盘列表。
  @StorageProp('modelPlates') plates: PlateMeta[] = [];

  // ---- 切片弹窗（与导入弹窗同一套视觉，走 mode='slice'）----
  @State private dlgVisible: boolean = false;
  @State private dlgModel: LoadDlgModel = new LoadDlgModel();
  // 进度处理：日志流与数值状态彻底分开（与导入弹窗同一套规则）
  //   数值 pendingNumeric 只留最新（合并合理）；日志 pendingLogs 每条都入队、一条不丢。
  private appliedStage: number = -1;
  private pendingNumeric: ProgressMsg | null = null;
  private pendingLogs: ProgressMsg[] = [];
  private flushTimer: number = -1;
  private lastFlushMs: number = 0;
  private sliceSettled: boolean = false;   // onDone 已到：数值不再被迟到进度改动（日志照收）
  private sliceStartedMs: number = 0;
  // 多盘逐盘切片的起点（runPlateSequence 设置）：用于打「点击→结束」的总耗时自证。
  private plateSeqStartMs: number = 0;
  // 主线程心跳探针：切片期间每 250ms 记一次。两次心跳的间隔就是主线程被占住的时长
  // （AppFreeze 看门狗判的就是这个）。间隔远超 250ms 的那一段 = 主线程被同步工作堵住的时段。
  private hbTimer: number = -1;
  private hbLastMs: number = 0;
  private hbMaxGapMs: number = 0;
  private logReceived: number = 0;
  private logRendered: number = 0;
  @State logDropped: number = 0;
  @State statsLogged: boolean = false;
  // 窄屏（手机）标志：只用于给窄屏一个较窄的初始面板宽度（见 applyNarrowDefaults），不再用于隐藏侧栏
  @State private isNarrow: boolean = false;

  // ---- 打印弹窗（对象颜色 ⇄ AMS 槽位映射 + 三个打印开关）----
  @State private printDlgVisible: boolean = false;
  @State private printSlots: AmsSlot[] = [];
  @State private printPrinterText: string = '';
  // 机型对照（弹窗内非阻塞提示用）：切片所用机型预设 + 当前已连接打印机机型（SSDP 友好名）
  @State private printSlicePrinter: string = '';
  @State private printConnPrinter: string = '';
  @State private printInitialOpts: PrintOptionsSnapshot = new PrintOptionsSnapshot();
  // 打开弹窗时的设备快照（构造打印请求需要 ip/serial/slots）
  private printInfo: PrintDeviceInfo = new PrintDeviceInfo();
  // 打印命令 sequence_id 自增（与 DevicePanel.cmdSeq 同思路）
  private printSeq: number = 0;
  // 打印弹窗打开请求进行中（避免重复点「打印」发起多次状态查询）
  private printOpening: boolean = false;

  // ---- 两侧面板宽度（vp）：可拖动调整并持久化 ----
  // 默认值 = 改造前的固定宽（左 220 / 右 320）；窄屏启动会先给一个较窄初值。
  @State private leftW: number = 220;
  @State private rightW: number = 320;
  // 当前正在拖动的句柄：0=左侧 1=右侧 -1=无（仅用于把被拖句柄的握把点亮，不改布局）
  @State private draggingSide: number = -1;
  // 中栏（左侧栏 + 手柄 + 3D + 手柄 + 右侧栏）的可用总宽，由 onAreaChange 实测（vp）；
  // 非 @State：只在夹取计算里用，不需要触发重渲染
  private contentW: number = 0;
  // 本次拖动开始时的面板宽度，配合手势 offsetX 计算候选值（避免累积误差）
  private dragStartW: number = 0;

  // 安全区 inset（px，来自 EntryAbility 广播）：沉浸式下由 UI 用自身背景为顶栏/底部工具栏留间距，
  // 保证内容铺满到屏幕底（无黑边），同时按钮不被系统状态栏/导航区盖住。
  @StorageLink('safeTopPx') private safeTopPx: number = 0;
  @StorageLink('safeBottomPx') private safeBottomPx: number = 0;

  // 打印已暂停告警（跨页模态）：数据由 DevicePanel 在「状态=PAUSE 且 HMS 非空」时发布，
  // 这里只负责渲染 —— 为什么放根页：用户可能正在「准备」页操作，告警必须跨页可见。
  @StorageLink('pauseHits') pauseHits: HmsHit[] = [];

  aboutToAppear(): void {
    this.detectNarrowScreen();
    this.applyNarrowDefaults();
    // 持久化优先：若存在上次拖动的宽度，覆盖上面的默认/窄屏初值
    this.loadPanelWidths();
    // 双喷嘴分组设置（模式 + AMS↔喷嘴配对）启动读盘（仅一次）
    this.ensureGroupingLoaded();
    // 当前工程状态（工程名 / 未保存标记 / 最近文件）：顶栏与文档菜单都靠它
    const dctx = this.getUIContext().getHostContext();
    docState.load(dctx === undefined ? '' : dctx.filesDir);
    // 耗材编辑的覆盖值（按耗材预设分桶）在这里先读盘一次：面板的 loadSchema 有时拿不到
    // HostContext，靠它保证「覆盖表已加载」不依赖那一次调用是否能取到目录。
    SliceParamStore.ensureFilamentOverrides(dctx === undefined ? '' : dctx.filesDir, '');
    // 关窗前把关：有未保存改动时先问（保存并退出 / 不保存 / 取消）。
    // 触发点在 EntryAbility 的 windowWillClose，那里只负责转发到这个回调。
    docGuard.ask = async (): Promise<boolean> => {
      return await this.confirmBeforeClose();
    };
    // 自动备份：本模块只做机制（会话锁 / 防抖 / 槽位轮转），「该不该备」与「怎么备」由这里注入。
    //   · skip：没有未保存改动、或空文档 → 不必备份（否则会用空工程覆盖掉好备份）；
    //   · perform：走与「保存」同一条内核导出链路，只是落点换到 backup/ 槽位。
    autoBackup.skip = (): boolean => (!docState.dirty || modelState.instances.length === 0);
    autoBackup.perform = async (): Promise<number> => this.performAutoBackup();
  }

  // ---- 文档守卫：关窗 / 新建 / 打开 前的「有未保存改动」确认 ----
  //
  // 三个入口共用一套语义：
  //   [保存并继续] → 把「原本要做的事」记在 pendingAfterSave 上，先走保存；保存成功后自动继续
  //   [不保存，继续] → 直接继续
  //   [取消]        → 什么都不做
  // 这样「保存」那条异步链路（内核导出 → 可能还要弹文件选择器）不需要在三个地方各写一份。
  private pendingAfterSave: (() => void) | null = null;

  private runPendingAfterSave(): void {
    const act: (() => void) | null = this.pendingAfterSave;
    this.pendingAfterSave = null;
    if (act !== null) {
      act();
    }
  }

  private confirmDiscardIfDirty(what: string, then: () => void): void {
    if (!docState.dirty) {
      then();
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '有未保存的改动',
        message: `「${docState.displayName()}」还有未保存的改动。${what}会丢弃这些改动，要先保存吗？`,
        buttons: [
          { text: '保存并继续', color: '#00C48C' },
          { text: '不保存，继续', color: '#FF3D2E' },
          { text: '取消', color: '#9A9AA4' }
        ]
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 0) {
          this.pendingAfterSave = then;
          this.saveCurrent();
        } else if (res.index === 1) {
          then();
        } else {
          promptAction.showToast({ message: '已取消' });
        }
      }).catch((e: Object) => {
        // 弹窗被外部关掉 = 用户没确认 → 按取消处理（不吞原因）
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.info(0x0000, 'DocGuard', '未保存确认弹窗未确认（按取消处理）: %{public}s', msg);
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'DocGuard', '未保存确认弹窗异常: %{public}s', msg);
      then();   // 弹窗都弹不出来时不能把用户卡住：放行
    }
  }

  // 关窗前确认：返回 true = 允许关闭。
  // 「保存并退出」要**先阻止这次关闭**（返回 false），等保存完成后由我们自己 terminateSelf ——
  // 否则会出现「保存还没跑完窗口就没了」。
  private async confirmBeforeClose(): Promise<boolean> {
    if (!docState.dirty) {
      return true;
    }
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      try {
        this.getUIContext().getPromptAction().showDialog({
          title: '有未保存的改动',
          message: `「${docState.displayName()}」还有未保存的改动，关闭前要保存吗？`,
          buttons: [
            { text: '保存并退出', color: '#00C48C' },
            { text: '不保存，退出', color: '#FF3D2E' },
            { text: '取消', color: '#9A9AA4' }
          ]
        }).then((res: promptAction.ShowDialogSuccessResponse) => {
          if (res.index === 0) {
            this.pendingAfterSave = (): void => { this.terminateApp(); };
            this.saveCurrent();
            resolve(false);      // 先别关，保存完成后自己退出
          } else if (res.index === 1) {
            resolve(true);
          } else {
            resolve(false);
          }
        }).catch((e: Object) => {
          const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
          hilog.info(0x0000, 'DocGuard', '关窗确认弹窗未确认（按取消处理）: %{public}s', msg);
          resolve(false);
        });
      } catch (e) {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.error(0x0000, 'DocGuard', '关窗确认弹窗异常: %{public}s', msg);
        resolve(true);   // 弹不出来不拦用户
      }
    });
  }

  private terminateApp(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      promptAction.showToast({ message: '已保存，请手动关闭窗口' });
      return;
    }
    try {
      (ctx as common.UIAbilityContext).terminateSelf().catch((e: Object) => {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.error(0x0000, 'DocGuard', 'terminateSelf 失败: %{public}s', msg);
        promptAction.showToast({ message: '已保存，请手动关闭窗口' });
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'DocGuard', 'terminateSelf 异常: %{public}s', msg);
      promptAction.showToast({ message: '已保存，请手动关闭窗口' });
    }
  }

  // 「新建工程」：清空当前文档，回到「未命名项目」。
  // 清空范围 = 对象 / 盘 / 对象级参数覆盖 / 全局参数覆盖 + 文档状态；
  // **不动**机型/工艺/耗材预设与面板宽度等应用级偏好（那是「这台机器的偏好」，不是「这份工程的内容」）。
  private newProject(): void {
    this.confirmDiscardIfDirty('新建工程', (): void => {
      const n: number = modelState.instances.length;
      for (const id of modelState.instances.map((m: ModelInstance) => m.id)) {
        dropThumbnail(id);   // 缩略图是 CPU 光栅化的 PixelMap，清文档时必须显式释放
      }
      modelState.clearAll();
      SliceParamStore.restoreUserOverrides(new Map<string, number>());
      AppStorage.setOrCreate<string>('sliceModelPath', '');
      AppStorage.setOrCreate<number>('activePlate', -1);
      modelState.publish();
      history.reset();          // 新文档：撤销栈从零开始（不能撤回到上一份工程）
      docState.noteUntitled();  // 未命名 + 有内容才脏（此刻没内容 → 干净）
      promptAction.showToast({ message: n > 0 ? `已新建工程（清空 ${n} 个对象）` : '已新建空工程' });
      hilog.info(0x0000, 'DocGuard', '新建工程：清空对象=%{public}d', n);
    });
  }

  // ---- 自动备份 / 崩溃恢复 ----------------------------------------------------
  //
  // 分工：机制（会话锁 / 防抖 / 槽位轮转）在 `service/AutoBackup`，这里只负责
  // 「怎么备」与「恢复时怎么载入」—— 这两件事都要 UIContext 与内核导出链路。
  private recoveryOffered: boolean = false;

  // 启动后第一次页面可见时问一次：上次是否异常退出、且有没有可用备份。
  // 放在 onPageShow 而不是 aboutToAppear：此时页面已挂载完成，弹窗才能正常显示。
  private maybeOfferRecovery(): void {
    if (this.recoveryOffered) {
      return;
    }
    this.recoveryOffered = true;
    if (!autoBackup.abnormalExit()) {
      return;
    }
    const info: BackupInfo | null = autoBackup.latest();
    if (info === null) {
      // 异常退出但没有可用备份（如空文档时被杀）：不打扰用户
      hilog.info(0x0000, 'AutoBackup', '检测到上次异常退出，但没有可用备份 → 不提示恢复');
      return;
    }
    hilog.info(0x0000, 'AutoBackup', '检测到上次异常退出且存在备份 %{public}s（%{public}d 字节）',
      info.path, info.size);
    // 推迟一拍再弹：onPageShow 里立刻 showDialog 时首帧布局还没落定（实测弹窗可能不显示）
    setTimeout((): void => {
      this.askRecover(info);
    }, 300);
  }

  private askRecover(info: BackupInfo): void {
    try {
      promptAction.showDialog({
        title: '检测到上次未正常退出',
        message: `上次运行可能异常结束。已保留 ${this.timeText(info.at)} 的自动备份` +
          `（${this.sizeText(info.size)}），要恢复它吗？`,
        buttons: [
          { text: '恢复备份', color: '#00C48C' },
          { text: '放弃', color: '#9A9AA4' }
        ]
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 0) {
          this.restoreBackup(info.path);
        } else {
          // 选「放弃」**不删备份**：下次自动备份会把它轮转掉，留着也比误删强
          hilog.info(0x0000, 'AutoBackup', '用户放弃恢复备份');
          // 但必须把「当前文件」关联清掉：启动时已从 doc_state 恢复出「当前文件=华为徽章.3mf」，
          // 而内容此刻是空的 —— 留着关联会让用户按 Ctrl+S 直接把空工程覆盖到原文件上。
          // 清成未命名项目后，原文件仍在「最近打开」里，想用再打开即可。
          docState.noteUntitled();
        }
      }).catch((e: Object) => {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.info(0x0000, 'AutoBackup', '恢复提示弹窗未确认（按放弃处理）: %{public}s', msg);
        docState.noteUntitled();
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'AutoBackup', '恢复提示弹窗异常: %{public}s', msg);
    }
  }

  // 恢复 = 走「导入 3MF」链路载入那份备份，但**不**把它关联成当前文件：
  // 恢复出来的内容属于「未保存」；若关联成当前文件，用户按 Ctrl+S 会把备份文件本身覆盖掉。
  // （导入完成后判脏 → 顶栏带橙点，用户另存为即可）
  private restoreBackup(path: string): void {
    promptAction.showToast({ message: '正在恢复自动备份…' });
    hilog.info(0x0000, 'AutoBackup', '开始恢复备份 %{public}s', path);
    this.doImport3mf(path, false, (): void => {
      // 导入**完成后**才判脏：工程 3MF 的导入走的是 history.reset()（不算一次编辑），
      // 不会触发 noteChange，所以脏标记不会自己变 true —— 必须在这里显式落一次
      //（实测：不落的话恢复完顶栏不带橙点、用户以为「已经保存过了」）。
      // noteUntitled 同时把上次会话残留的文件关联清掉：恢复出来的内容不该覆盖用户的原文件。
      docState.noteUntitled();
    });
  }

  // 自动备份的「执行体」：与「保存」同一条内核导出链路（通用 3MF 当输入 → store_bbs_3mf 出工程 3MF）。
  // 与保存的两点差异：
  //   ① 落点是 backup/ 的轮转槽位（内核直接写过去，省一次「沙箱产出 → 拷贝」）；
  //   ② **不**动「当前文件」状态 —— 不能调 docState.noteSaved，那会把备份当成用户保存
  //      （顶栏清脏 + 进最近文件），用户会以为「已经保存过了」。
  private performAutoBackup(): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        resolve(0);
        return;
      }
      const filesDir: string = ctx.filesDir;
      let bundle: ExportBundle | null = null;
      try {
        bundle = ThreeMfExport.build(filesDir);
      } catch (e) {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.error(0x0000, 'AutoBackup', '备份构建异常: %{public}s', msg);
        resolve(0);
        return;
      }
      if (bundle === null || bundle.bytes.length === 0) {
        resolve(0);
        return;
      }
      const b: ExportBundle = bundle;
      const tmpPath: string = autoBackup.inputTmpPath();
      if (!ThreeMfExport.writeFile(tmpPath, b.bytes)) {
        hilog.warn(0x0000, 'AutoBackup', '备份跳过：输入临时文件写入失败');
        resolve(0);
        return;
      }
      const dest: string = autoBackup.nextSlotPath();
      let paramsJson: string = '';
      try {
        // 与保存完全同一份参数快照（含多色映射），保证备份能被完整还原
        paramsJson = SliceParamStore.mergeExtra(SliceParamStore.collectParamsJson(),
          SliceParamStore.multicolorFragment(modelState.instances));
      } catch (e) {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.error(0x0000, 'AutoBackup', '备份参数快照异常: %{public}s', msg);
        resolve(0);
        return;
      }
      try {
        SlicerService.exportProject3mf(tmpPath, paramsJson, dest, (rj: string): void => {
          let ok: boolean = false;
          let why: string = '';
          try {
            const r: Project3mfResult = JSON.parse(rj) as Project3mfResult;
            ok = r.ok === true;
            why = r.message !== undefined ? r.message : '';
          } catch (e) {
            ok = false;
            why = '结果解析异常';
          }
          if (!ok) {
            hilog.warn(0x0000, 'AutoBackup', '备份失败（内核）: %{public}s', why);
            resolve(0);
            return;
          }
          const bytes: Uint8Array | null = ThreeMfExport.readFileBytes(dest);
          if (bytes === null) {
            hilog.warn(0x0000, 'AutoBackup', '备份失败：读回产出文件失败 %{public}s', dest);
            resolve(0);
            return;
          }
          // 占用上限：单份工程 3MF 超过 BACKUP_MAX_BYTES 就丢掉这份（3 槽位 → 上限 = 3 × 该值）。
          // 判据用**产出的工程 3MF**，不是导出前的通用 3MF 输入（后者大一个数量级，见 AutoBackup 注释）。
          if (bytes.length > BACKUP_MAX_BYTES) {
            autoBackup.drop(dest);
            hilog.warn(0x0000, 'AutoBackup', '备份超上限已丢弃：%{public}d 字节', bytes.length);
            resolve(0);
            return;
          }
          // 与保存链路同一套三通道日志（hilog + 应用内日志 + diag），便于事后取证
          ThreeMfExport.log(filesDir,
            `自动备份 路径=${dest} 字节=${bytes.length} 对象=${b.objectCount} 结果=成功`);
          resolve(bytes.length);
        });
      } catch (e) {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.error(0x0000, 'AutoBackup', '备份内核调用异常: %{public}s', msg);
        resolve(0);
      }
    });
  }

  private two(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  // 备份提示里的时间（只给用户看，不引入本地化库）
  private timeText(ms: number): string {
    const d: Date = new Date(ms);
    return `${d.getFullYear()}-${this.two(d.getMonth() + 1)}-${this.two(d.getDate())} ` +
      `${this.two(d.getHours())}:${this.two(d.getMinutes())}`;
  }

  private sizeText(b: number): string {
    if (b >= 1024 * 1024) {
      return `${(b / (1024 * 1024)).toFixed(1)} MB`;
    }
    if (b >= 1024) {
      return `${Math.round(b / 1024)} KB`;
    }
    return `${b} B`;
  }

  // 双喷嘴分组设置读盘（filesDir 可用时读；取不到 filesDir 则等打印入口再读）
  private ensureGroupingLoaded(): void {
    if (FilamentGrouping.isLoaded()) { return; }
    const ctx = this.getUIContext().getHostContext();
    FilamentGrouping.load(ctx === undefined ? '' : ctx.filesDir);
  }

  // 探测窄屏：取默认显示的「短边」并换算成 vp。失败一律按「宽屏」处理，保持桌面既有布局。
  //
  // 为什么用短边而不是宽度：手机被强制横屏后，宽度会变大（如 ~780vp），若仍按宽度判定，
  // 会误判成宽屏而不给窄屏初值。短边在旋转前后不变（手机恒为 ~360vp），因此手机在
  // 「竖屏 / 横屏」两种朝向下都能拿到一致的判定；平板 / 2in1 的短边通常 ≥600vp。
  private detectNarrowScreen(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const shortPx: number = Math.min(d.width, d.height);
      // 全局 px2vp 自 API 18 起废弃（SDK: @useinstead ohos.arkui.UIContext.UIContext#px2vp），改用 UIContext 版本
      const w: number = this.getUIContext().px2vp(shortPx);
      this.isNarrow = w > 0 && w < NARROW_WIDTH_VP;
      hilog.info(0x0000, 'Layout', '短边=%{public}d vp (屏 %{public}dx%{public}d) 窄屏=%{public}s',
        Math.round(w), d.width, d.height, this.isNarrow ? '是' : '否');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'Layout', '探测屏宽失败（按宽屏处理）: %{public}s', msg);
      this.isNarrow = false;
    }
  }

  // 窄屏（手机）启动初值：用较窄的面板，避免首帧（onAreaChange 还没测到可用宽）就把中栏挤到 240 以下。
  // 只影响初始值；若存在持久化宽度，随后会被 loadPanelWidths 覆盖。
  private applyNarrowDefaults(): void {
    if (!this.isNarrow) {
      return;
    }
    this.leftW = LEFT_MIN;
    this.rightW = RIGHT_MIN;
  }

  // ---- 面板宽度：夹取 / 持久化 / 日志 -----------------------------------------

  // 两侧面板宽度之和的上限 = 中栏可用总宽 - 两条手柄 - 中栏最小宽。
  // contentW 还没测到（<=0）时返回一个足够大的值表示「无约束」，测到之后由 onAreaChange 重夹。
  private maxPanelSum(): number {
    if (!(this.contentW > 0)) {
      return 100000;
    }
    return Math.max(0, this.contentW - HANDLE_W * 2 - CENTER_MIN);
  }

  // 中栏当前可用宽度（vp，粗算，仅供日志/自证）
  private centerWidthVp(): number {
    const w: number = this.contentW - HANDLE_W * 2 - this.leftW - this.rightW;
    return Math.round(Math.max(0, w));
  }

  // 左面板拖到候选宽度：先夹到 [LEFT_MIN, LEFT_MAX]；若与右面板之和超出可用宽（中栏 < CENTER_MIN），
  // 先把右面板压到其最小值，仍不够再把左面板压回（保证中栏始终 ≥ CENTER_MIN）。
  private applyLeftDrag(cand: number): void {
    let l: number = Math.max(LEFT_MIN, Math.min(LEFT_MAX, Math.round(cand)));
    const room: number = this.maxPanelSum();
    if (l + this.rightW > room) {
      const r: number = Math.max(RIGHT_MIN, room - l);
      if (r < this.rightW) {
        this.rightW = r;
      }
      if (l + this.rightW > room) {
        l = Math.max(LEFT_MIN, room - this.rightW);
      }
    }
    this.leftW = l;
  }

  // 右面板拖到候选宽度：与 applyLeftDrag 对称（超出时先把左面板压到最小值）。
  private applyRightDrag(cand: number): void {
    let r: number = Math.max(RIGHT_MIN, Math.min(RIGHT_MAX, Math.round(cand)));
    const room: number = this.maxPanelSum();
    if (this.leftW + r > room) {
      const l: number = Math.max(LEFT_MIN, room - r);
      if (l < this.leftW) {
        this.leftW = l;
      }
      if (this.leftW + r > room) {
        r = Math.max(RIGHT_MIN, room - this.leftW);
      }
    }
    this.rightW = r;
  }

  // 可用宽变化（窗口尺寸 / 旋转 / 折叠 / 安全区变化）后重新夹取，保证中栏 ≥ CENTER_MIN 且不溢出。
  private reclampWidths(): void {
    const room: number = this.maxPanelSum();
    if (room >= 100000) {
      return;
    }
    if (this.leftW + this.rightW > room) {
      const r: number = Math.max(RIGHT_MIN, room - this.leftW);
      if (r < this.rightW) {
        this.rightW = r;
      }
      if (this.leftW + this.rightW > room) {
        this.leftW = Math.max(LEFT_MIN, room - this.rightW);
      }
    }
  }

  // 中栏可用宽实测回调（挂在承载三栏的 Row 上）
  private onContentArea(n: Area): void {
    const w: number = Number(n.width);
    if (!(w > 0)) {
      return;
    }
    if (Math.abs(w - this.contentW) < 0.5) {
      return;
    }
    this.contentW = w;
    const beforeL: number = this.leftW;
    const beforeR: number = this.rightW;
    this.reclampWidths();
    if (beforeL !== this.leftW || beforeR !== this.rightW) {
      this.writePanelLog(`面板宽度 左=${Math.round(this.leftW)} 右=${Math.round(this.rightW)}` +
        ` 中=${this.centerWidthVp()}（可用宽 ${Math.round(w)} 变化重夹）`);
    }
  }

  private beginDrag(side: number): void {
    this.draggingSide = side;
    this.dragStartW = side === 0 ? this.leftW : this.rightW;
  }

  private updateDrag(side: number, dx: number): void {
    if (side === 0) {
      this.applyLeftDrag(this.dragStartW + dx);
    } else {
      this.applyRightDrag(this.dragStartW - dx);
    }
  }

  private endDrag(): void {
    this.draggingSide = -1;
    // 放手后持久化，保证下次启动保持
    this.savePanelWidths();
    this.writePanelLog(`面板宽度 左=${Math.round(this.leftW)} 右=${Math.round(this.rightW)}` +
      ` 中=${this.centerWidthVp()}（拖动结束）`);
  }

  // 面板宽度持久化通道：沿用工程既有做法 —— filesDir 下 JSON 文件（与 preset_last.json 同级）
  private panelWidthFile(): string | undefined {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return undefined;
      }
      return `${ctx.filesDir}/panel_width.json`;
    } catch (e) {
      hilog.error(0x0000, PANEL_TAG, '取 filesDir 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return undefined;
    }
  }

  private savePanelWidths(): void {
    const path: string | undefined = this.panelWidthFile();
    if (path === undefined) {
      return;
    }
    try {
      const snap: PanelWidthSnapshot = new PanelWidthSnapshot();
      snap.left = this.leftW;
      snap.right = this.rightW;
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(snap));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0x0000, PANEL_TAG, '面板宽度保存失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  private loadPanelWidths(): void {
    const path: string | undefined = this.panelWidthFile();
    if (path === undefined) {
      this.writePanelLog('面板宽度 读取跳过（无上下文）');
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        // 首次启动的正常情况，不算错误
        this.writePanelLog(`面板宽度 无持久化 左=${Math.round(this.leftW)} 右=${Math.round(this.rightW)}（启动）`);
        return;
      }
      const text: string = fs.readTextSync(path);
      if (text.length === 0) {
        return;
      }
      const snap: PanelWidthSnapshot = JSON.parse(text) as PanelWidthSnapshot;
      this.leftW = Math.max(LEFT_MIN, Math.min(LEFT_MAX, Math.round(snap.left)));
      this.rightW = Math.max(RIGHT_MIN, Math.min(RIGHT_MAX, Math.round(snap.right)));
      this.reclampWidths();
      this.writePanelLog(`面板宽度 已恢复 左=${Math.round(this.leftW)} 右=${Math.round(this.rightW)}（启动）`);
    } catch (e) {
      hilog.error(0x0000, PANEL_TAG, '面板宽度读取失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 面板宽度自证日志：hilog + 应用内日志 + files/diag/gcode_diag.txt 三通道同写
  private writePanelLog(text: string): void {
    hilog.info(0x0000, PANEL_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${PANEL_TAG}] ${text}`);
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      const ok: boolean = AppLog.writeDiagFile(`${ctx.filesDir}/diag/gcode_diag.txt`,
        [`[${PANEL_TAG}] ${text}`]);
      if (!ok) {
        hilog.warn(0x0000, PANEL_TAG, '面板宽度日志落盘失败');
      }
    } catch (e) {
      hilog.error(0x0000, PANEL_TAG, '面板宽度日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 兜底自愈：页面重新可见（含应用回到前台）时，让 SlicerService 再把当前预设状态广播一次，
  // 保证从任何路径回到本页时，已挂载的面板都能拿到最新状态（不依赖 AppStorage/@Watch）。
  onPageShow(): void {
    SlicerService.resyncPresetState();
    // 重新可见时再探一次屏宽：旋转 / 折叠屏状态变化后能及时更新窄屏判定
    this.detectNarrowScreen();
    // 页面重新显示（ArkUI 文档：应用进入前台也会触发 onPageShow）时同样广播一次「渲染恢复」信号。
    // 与 EntryAbility.onForeground / windowStageEvent 互为补充：失焦或前后台切换会让渲染表面重建、
    // 材质绑定丢失（切片路径/打印板变灰），任何「回到可见」的路径都必须让 3D 场景页重贴材质。
    const cur: number = AppStorage.get<number>('renderResumeSeq') ?? 0;
    AppStorage.setOrCreate<string>('renderResumeSrc', 'onPageShow');
    AppStorage.setOrCreate<number>('renderResumeSeq', cur + 1);
    // 崩溃恢复提示：只在本次进程的第一次可见时问一次（见 maybeOfferRecovery 里的开关）
    this.maybeOfferRecovery();
  }

  // ---- 打印弹窗：入口 / 收尾 -------------------------------------------------
  // 取应用沙箱 filesDir（日志落盘 / 开关记忆都用它）
  private filesDirOrEmpty(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx === undefined ? '' : ctx.filesDir;
  }

  // 「跟随全局」时的打印板枚举下标：参数面板尚未初始化时，参数表里的 curr_bed_type
  // 还是内核兜底值（High Temp），会把 A1 mini 的纹理 PEI 切成高温板（板温 75/65 而不是 60/60）。
  // 持久化快照（PresetPersist.bedType）才是界面当前选择，按名字换回下标；取不到返回 -1（不覆盖）。
  private globalBedEnumIndex(filesDir: string): number {
    const snap: PresetSnapshot | undefined = PresetPersist.load(filesDir);
    return SliceParamStore.bedTypeIndexOf(snap !== undefined ? snap.bedType : '');
  }

  // 切片所用机型预设：优先内核当前选中机型（权威），取不到再退回上次持久化的预设名（均无则空）。
  private currentSlicePrinter(filesDir: string): string {
    const cat: PresetCatalog | undefined = SlicerService.getCatalog();
    if (cat !== undefined && cat.selected.printer !== '') {
      return cat.selected.printer;
    }
    const snap: PresetSnapshot | undefined = PresetPersist.load(filesDir);
    return snap !== undefined ? snap.printer : '';
  }

  // 底部「打印」：已连接打印机时弹出打印弹窗；未连接时只提示，不崩。
  // 现状查证：改造前 onPrint 是空实现（点「打印」无任何反应），且工程没有"下发到设备打印"的链路
  //（DevicePanel 只有 pause/resume/stop，无文件上传 / project_file）。因此这里只负责打开弹窗，
  // 未连接时明确给一句提示 —— 与「切片」在无模型时的提示同一风格。
  private openPrintDialog(): void {
    if (this.printOpening) { return; }
    // 校准试块：校准页切完会把 output.gcode + sliceModelPath 准备好并置 calibPrintReady，
    // 此时「准备」页本来就没有对象 —— 若还按「必须有对象」拦，校准结果就只能看不能印。
    const calibPrint: boolean = AppStorage.get<boolean>('calibPrintReady') === true;
    if (modelState.instances.length === 0 && !calibPrint) {
      promptAction.showToast({ message: '请先在「准备」页导入模型' });
      return;
    }
    if (modelState.instances.length === 0) {
      hilog.info(0x0000, 'Print', '校准试块打印：准备页无对象，按校准产物打开打印弹窗');
    }
    // 双头机型约束在拿到真实 AMS 后判定（见下方 then）：区域冲突 / 材料级限制 / 耗材分组冲突
    // 一律复用「超出打印区域」告警并在此阻止打印（不放行到打印弹窗），不新做一种告警。
    this.printOpening = true;
    PrintOptions.fetch().then((info: PrintDeviceInfo) => {
      this.printOpening = false;
      const filesDir: string = this.filesDirOrEmpty();
      const amsState: string = info.slots.length > 0 ? '有' : '无';
      // 先按「耗材分组 + AMS↔喷嘴配对 + 材料限制 + 区域/高度约束」用真实 AMS 重算最终喷嘴侧
      this.ensureGroupingLoaded();
      FilamentGrouping.applyToState(this.currentSlicePrinter(filesDir), info.slots);
      // 阻止打印：区域冲突（同时触碰左右专属区）或 材料/分组冲突（侧被约束冲突）
      let blockId: number = -1;
      let blockMsg: string = '';
      for (const inst of modelState.instances) {
        if (inst.zoneConflict) { blockId = inst.id; blockMsg = '对象同时触碰左右喷嘴专属区'; break; }
        if (inst.sideError !== '') { blockId = inst.id; blockMsg = inst.sideError; break; }
      }
      if (blockId >= 0) {
        hilog.warn(0x0000, 'DualNozzle',
          '阻止打印：对象 %{public}d %{public}s（复用超出打印区域告警）', blockId, blockMsg);
        AppLog.push(`[DualNozzle] 阻止打印：对象 ${blockId} ${blockMsg}`);
        promptAction.showToast({ message: `超出打印区域：${blockMsg}，无法打印` });
        return;
      }
      if (!info.connected) {
        PrintOptions.log(filesDir,
          `打印弹窗 对象=${modelState.instances.length} AMS=${amsState} 映射=- 开关(-) 结果=未连接打印机(已提示)`);
        promptAction.showToast({ message: '请先连接打印机（设备页）' });
        return;
      }
      this.printSlots = info.slots;
      this.printInfo = info;
      this.printPrinterText = (info.serial !== '' ? info.serial : info.ip) + ' · 已连接';
      // 机型对照：切片所用机型预设（内核当前选中→无则退持久化）vs 已连接打印机机型（SSDP 友好名）
      this.printSlicePrinter = this.currentSlicePrinter(filesDir);
      this.printConnPrinter = AppStorage.get<string>('connectedDeviceModel') ?? '';
      this.printInitialOpts = PrintOptions.load(filesDir);
      this.printDlgVisible = true;
      PrintOptions.log(filesDir,
        `打印弹窗 对象=${modelState.instances.length} AMS=${amsState} 映射=- 开关(${PrintOptions.optionsText(this.printInitialOpts)}) 结果=已打开`);
      PrintOptions.log(filesDir,
        `打印弹窗机型对照 切片预设=${this.printSlicePrinter !== '' ? this.printSlicePrinter : '(未知)'} ` +
        `已连接=${this.printConnPrinter !== '' ? this.printConnPrinter : '(未知)'}`);
      // 开关的真实 key 现场留证：三个都是 AppConfig 的 print 段键，PrintConfig 无对应 on/off 项。
      PrintOptions.log(filesDir,
        '打印开关 key 延时=AppConfig.print.timelapse 调平=AppConfig.print.bed_leveling 流量=AppConfig.print.flow_cali 默认=1 PrintConfig=无对应项');
    }).catch((e: Error) => {
      this.printOpening = false;
      hilog.error(0x0000, PRINT_DLG_TAG, '打开打印弹窗失败: %{public}s', e.message);
      promptAction.showToast({ message: '打开打印弹窗失败：' + e.message });
    });
  }

  // 打印弹窗「开始打印」：记忆开关 → 打印前**自动产出含 gcode 的 3MF** → 构造请求 →
  // 执行完整链路（上传 → 发 MQTT）。空跑保险已整条删除，这里就是真发。
  private onPrintConfirmed(opts: PrintOptionsSnapshot, pairs: string, mapped: number, unmapped: number): void {
    const filesDir: string = this.filesDirOrEmpty();
    PrintOptions.save(filesDir, opts);
    this.startPrintPrep(opts, pairs, mapped, unmapped, false);
  }

  // 打印弹窗「上传·不打印」：同样先产出含 gcode 3MF，再 FTPS 上传（**不发任何打印命令**）。不关弹窗。
  private onPrintUpload(opts: PrintOptionsSnapshot, pairs: string, mapped: number, unmapped: number): void {
    this.startPrintPrep(opts, pairs, mapped, unmapped, true);
  }

  // 打印/上传共用：产出打印包（③ Worker 化 + ① 缓存 + ② 失败即停）→ 构造计划 → 执行。
  // 构建期间打主线程心跳（复用切片探针），构建失败不再自动重来，改为显式「重试」。
  private startPrintPrep(opts: PrintOptionsSnapshot, pairs: string, mapped: number,
                         unmapped: number, uploadOnly: boolean): void {
    const filesDir: string = this.filesDirOrEmpty();
    this.printSeq++;
    const seq: string = `${this.printSeq}`;
    promptAction.showToast({ message: '正在准备含 gcode 的打印包…' });
    this.sliceStartedMs = Date.now();
    this.startHeartbeat(uploadOnly ? '上传包构建' : '打印包构建');
    ThreeMfExport.ensureGcodePackage(filesDir).then((pkg: GcodePackage) => {
      this.stopHeartbeat();
      this.sliceLog(`${uploadOnly ? '上传' : '打印'}包构建 心跳收尾 最大间隔=${this.hbMaxGapMs}ms ` +
        `缓存命中=${pkg.cacheHit ? '是' : '否'} 总耗时=${pkg.totalMs}ms`);
      if (!pkg.ok) {
        PrintOptions.logSend(filesDir, `${uploadOnly ? '上传' : '打印'}前产出含 gcode 3MF 失败：${pkg.reason}`);
        this.showPkgRetry(filesDir, uploadOnly ? '上传包构建失败' : '打印包构建失败', pkg.reason, () => {
          ThreeMfExport.resetGcodePackageFailure();
          this.startPrintPrep(opts, pairs, mapped, unmapped, uploadOnly);
        });
        return;
      }
      // 机型判定给「实际连接的打印机机型」：SSDP 友好名（如 "A1"/"A1 mini"/"X1C"）。
      // 取不到则留空 → buildPlan 退回按切片预设名判（保持既有口径）。
      const connModel: string = AppStorage.get<string>('connectedDeviceModel') ?? this.printConnPrinter;
      PrintOptions.buildPlan(filesDir, this.printInfo, pairs, opts, seq, pkg,
        this.currentSlicePrinter(filesDir), connModel)
        .then((plan: PrintTaskPlan) => {
          if (uploadOnly) {
            promptAction.showToast({ message: '正在上传到打印机（不上传即不打印）…' });
            PrintOptions.uploadPrintFile(filesDir, plan).then((r: UploadOutcome) => {
              const msg: string = r.ok
                ? `上传成功并 LIST 复核通过（未发送打印命令）落点=${r.landed}`
                : `上传未成功：${r.message}`;
              if (r.ok) {
                promptAction.showToast({ message: msg });
              } else {
                // 失败原因可能较长（含「失败原因：落点：返回码=… 说明=…」），toast 会截断，
                // 改用对话框完整显示 —— 便于在拿不到诊断文件的机器（客户手机）上直接拍照留证。
                promptAction.showDialog({
                  title: '上传到打印机失败', message: msg,
                  buttons: [{ text: '知道了', color: '#FF7A1A' }]
                });
              }
            });
          } else {
            PrintOptions.execute(filesDir, plan).then((r: string) => {
              this.printDlgVisible = false;
              if (r.indexOf('已发送 project_file') === 0) {
                promptAction.showToast({ message: r });
              } else {
                promptAction.showDialog({
                  title: '打印未发送', message: r,
                  buttons: [{ text: '知道了', color: '#FF7A1A' }]
                });
              }
            });
          }
        });
    });
  }

  // ② 失败即停 + 显式「重试」入口：构建失败后不自动重来，弹一个带原因的重试框。
  private showPkgRetry(filesDir: string, title: string, reason: string, onRetry: () => void): void {
    if (reason.indexOf('请先切片') === 0 || reason.indexOf('当前没有可导出对象') === 0
      || reason.indexOf('当前没有可导出的对象') >= 0) {
      promptAction.showToast({ message: reason });
      return;
    }
    promptAction.showDialog({
      title,
      message: `${reason}\n\n（已停止自动重试，避免反复重建导致内存累加）`,
      buttons: [
        { text: '重试', color: '#FF7A1A' },
        { text: '取消', color: '#9AA4B2' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 0) {
        onRetry();
      }
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.info(0x0000, SAVE3MF_TAG, '构建失败重试框未确认: %{public}s', msg);
    });
  }

  private onPrintCancelled(): void {
    const filesDir: string = this.filesDirOrEmpty();
    if (this.printDlgVisible) {
      PrintOptions.log(filesDir,
        `打印弹窗 对象=${modelState.instances.length} AMS=${this.printSlots.length > 0 ? '有' : '无'} 映射=- 开关(-) 结果=取消`);
    }
    this.printDlgVisible = false;
  }

  // 切片：等预设就绪 → 收集动态表单参数 → 打开切片弹窗 → 调带进度的切片内核
  //
  // 多盘语义（本轮）：**默认切全部盘**，逐盘产出各自结果，绝不把不同盘叠加到同一块板。
  //   · 单盘 / 无盘信息 → 沿用原行为（直接切原始文件到 output.gcode）；
  //   · 多盘 → 逐盘构建「只含该盘对象」的输入工程 → 逐盘切片 → output_plate_<N>.gcode。
  private startSlice(): void {
    if (this.slicing) { return; }
    // 由「准备」页导入模型时写入（见 ModelPreviewPage / ThreeMfImport）
    const modelPath: string | undefined = AppStorage.get<string>('sliceModelPath');
    if (modelPath === undefined || modelPath === '') {
      promptAction.showToast({ message: '请先在「准备」页导入模型' });
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      promptAction.showToast({ message: '获取上下文失败' });
      return;
    }
    this.slicing = true;
    this.sliceResult = '切片中…';
    this.sliceError = '';
    // 弹窗先于内核调用出现，避免大模型切片期间界面「毫无反应」
    this.openSliceDialog();
    // 等 BBL 官方预设就绪（首次运行要解压预设包）。即使失败也不阻断：
    // 内核会退回内置默认值，切片仍能跑，只是参数不是官方预设。
    SlicerService.ensurePresets(ctx.filesDir)
      .then((ok: boolean) => {
        if (!ok) {
          this.dlgModel.pushLog('预设加载失败 · 本次使用内核默认参数', false);
        }
        // 内存快照（切片前）：配合切片后快照定位「手机端首次切片 OOM」的峰值落在哪一段。
        AppLog.mem('Slice', `切片前 对象=${modelState.instances.length}`);
        // 耗材编辑的覆盖值：保证已读盘，并把「桶」指向内核当前选中的耗材预设
        // （按预设名分桶 → 换耗材自动隔离，不与别的预设冲突；重启后依然生效）
        const fcat = SlicerService.getCatalog();
        SliceParamStore.ensureFilamentOverrides(ctx.filesDir,
          fcat !== undefined ? fcat.selected.filament : '');
        const paramsJson: string = SliceParamStore.collectParamsJson();
        const plates: number[] = this.slicePlates();
        if (plates.length > 1) {
          this.sliceLog(`切片 多盘 盘数=${plates.length} 盘号=${plates.join(',')} · 默认逐盘全切`);
          this.runPlateSequence(ctx.filesDir, plates, paramsJson);
          return;
        }
        // 单盘 / 无盘信息。
        // 「对象颜色 → 耗材槽位」：按整份对象下发多耗材请求（内核据此分出多个耗材槽位）。
        const mcFragment: string = SliceParamStore.multicolorFragment(modelState.instances);
        // 盘级床型：单盘也要生效（plates 恰好 1 盘时按该盘；0 盘 = 无盘信息，跟随全局）
        const singlePlate: number = plates.length === 1 ? plates[0] : 0;
        let singleBedIdx: number = singlePlate > 0 ? plateBedEnumIndex(singlePlate) : -1;
        if (singleBedIdx < 0) {
          // 跟随全局：按界面当前打印板名回填枚举下标（见 globalBedEnumIndex 的说明）
          singleBedIdx = this.globalBedEnumIndex(ctx.filesDir);
        }
        const paramsJsonMc: string = SliceParamStore.withBedType(
          SliceParamStore.mergeExtra(paramsJson, mcFragment), singleBedIdx);
        this.sliceLog(`切片 多耗材请求 对象=${modelState.instances.length} ` +
          `槽位=${mcFragment.length > 0 ? '见请求' : '单耗材(N<=1)'}`);
        this.sliceLog(`切片 床型=${singleBedIdx >= 0 ? '盘级覆盖 idx=' + singleBedIdx : '跟随全局'}`);
        const outPath: string = `${ctx.filesDir}/output.gcode`;
        // ★ 变换烘入：把「准备」页里的旋转 / 缩放 / 移动真的带进切片。
        //   旧实现直接把导入时的原始文件副本（sliceModelPath）交给内核 —— 用户动过模型后，
        //   切出来的走线仍是没动过的那个（预览里模型与走线对不上，用户反馈的正是这一条）。
        //   改法：用户动过模型就先用「多盘」同一条链路（ThreeMfExport.buildToFileViaWorker →
        //   itemMatrixOf 把 position/rot/scale 写进 3MF item 变换）落一份输入工程再切；
        //   没动过仍走原始文件 —— 既省掉一次整包构建（大模型上是秒级），也保住 3MF 工程内嵌的设置。
        // 需要「烘入」的两种情形（合并成一个 flag，两者走同一条生成输入工程的链路）：
        //   ① 用户改过变换（旋转/缩放/移动/贴面）—— 原始文件里没有这些改动；
        //   ② 存在**对象级参数覆盖** —— 原始文件里同样没有，只有我们自己生成的 3MF 会带上它
        //      （逐对象参数写在 Metadata/model_settings.config，见 Mf3mfWriter / ThreeMfExport.serializeOverride）。
        //   少了 ② 就会出现「在对象页签改了参数、切出来还是没改」的静默失效。
        const tfEdited: boolean = modelState.transformsEditedSinceLoad();
        const hasObjOv: boolean = modelState.hasObjectOverrides();
        const edited: boolean = tfEdited || hasObjOv;
        this.sliceLog(`切片 输入工程 变换=${tfEdited ? '已改动' : '未改动'} ` +
          `对象参数覆盖=${hasObjOv ? '有' : '无'} → ${edited ? '烘入自建工程' : '用原始文件'} ` +
          `对象=${modelState.instances.length}`);
        const bakedPath: string = `${ctx.filesDir}/slice_baked.3mf`;
        if (edited) {
          this.dlgModel.pushLog('已重新生成切片输入（含当前变换与对象参数）…', false);
        }
        this.prepareSliceInput(ctx.filesDir, edited, bakedPath).then((baked: string): void => {
          const inPath: string = baked !== '' ? baked : modelPath;
          if (baked !== '') {
            // 打印包内嵌的模型也换成同一份：否则「包里的模型」与「包里的 gcode」姿态不一致。
            AppStorage.setOrCreate<string>('sliceModelPath', baked);
          } else if (edited) {
            this.sliceLog('切片 输入工程不可用 → 退回原始文件（变换不会生效）');
            this.dlgModel.pushLog('变换烘入失败 · 本次按导入原样切片', true);
          }
          try {
            SlicerService.sliceJsonWithProgress(inPath, paramsJsonMc, outPath,
              (pj: string) => { this.onSliceProgress(pj); },
              (rj: string) => { this.onSliceDone(rj); });
          } catch (e) {
            const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
            hilog.error(0x0000, TAG, 'slicerSliceWithProgress 同步异常: %{public}s', msg);
            this.failSlice('切片调用失败: ' + msg);
          }
        }).catch((e: Error): void => {
          hilog.error(0x0000, TAG, '切片输入工程准备异常: %{public}s', e.message);
          this.failSlice('切片输入准备失败: ' + e.message);
        });
      })
      .catch((e: Error) => {
        hilog.error(0x0000, TAG, '预设准备异常: %{public}s', e.message);
        this.failSlice('预设准备失败: ' + e.message);
      });
  }

  // 需要切片的盘号（去重升序）。无分盘信息（全 0）时返回空数组 = 走单盘/原始文件路径。
  private slicePlates(): number[] {
    const set: Set<number> = new Set<number>();
    for (const m of modelState.instances) {
      if (m.plate > 0) { set.add(m.plate); }
    }
    const arr: number[] = [];
    set.forEach((p: number) => { arr.push(p); });
    arr.sort((a: number, b: number) => a - b);
    return arr;
  }

  // 切片输入工程的准备（见 startSlice 的「变换烘入」说明）。
  //   edited=false → 直接返回 ''（调用方用原始文件，行为与旧版完全一致）；
  //   edited=true  → 用与「多盘」同一条链路（Worker 里构建 + 落盘）写出含当前变换的 3MF，
  //                  成功返回该路径；失败/Worker 不可用且主线程构建也失败 → 返回 ''（调用方退回原文件）。
  // 绝不在失败时抛异常打断切片：退回原文件只是「变换不生效」，比整个切片失败好得多（并有日志留痕）。
  private prepareSliceInput(filesDir: string, edited: boolean, outPath: string): Promise<string> {
    if (!edited) {
      return Promise.resolve('');
    }
    return new Promise<string>((resolve: (v: string) => void) => {
      const t0: number = Date.now();
      ThreeMfExport.buildToFileViaWorker(filesDir, 0, outPath)
        .then((r: Mf3mfWriteResult): void => {
          let ok: boolean = r.ok;
          if (r.workerUnavailable) {
            // Worker 不可用（该模块在真机上有过加载失败的历史）→ 退回主线程构建，行为与多盘一致。
            this.sliceLog('切片 输入工程 Worker 不可用 → 回退主线程构建（会占主线程）');
            const bundle: ExportBundle | null = ThreeMfExport.build(filesDir, 0);
            ok = bundle !== null && ThreeMfExport.writeFile(outPath, bundle.bytes);
          }
          if (!ok) {
            this.sliceLog(`切片 输入工程构建失败（${r.reason}）→ 退回原始文件`);
            resolve('');
            return;
          }
          this.sliceLog(`切片 输入工程构建完成 ${Date.now() - t0}ms 字节=${r.bytes} 路径=${outPath}`);
          resolve(outPath);
        })
        .catch((e: Error): void => {
          this.sliceLog(`切片 输入工程构建异常：${e.message} → 退回原始文件`);
          resolve('');
        });
    });
  }

  // 三条日志通道的统一出口（hilog + 应用内日志页 + files/diag/gcode_diag.txt）。
  // 切片现场与失败原因必须三处都能看到（用户人不在设备旁时靠 diag 文件自证）。
  private sliceLog(text: string): void {
    hilog.info(0x0000, TAG, '%{public}s', text);
    try {
      AppLog.push(`[${TAG}] ${text}`);
      const ctx = this.getUIContext().getHostContext();
      if (ctx) {
        if (!AppLog.writeDiagFile(`${ctx.filesDir}/diag/gcode_diag.txt`, [`[${TAG}] ${text}`])) {
          hilog.warn(0x0000, TAG, '切片日志落盘失败');
        }
      }
    } catch (e) {
      hilog.error(0x0000, TAG, '切片日志写入异常: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  // 逐盘切片：为每盘构建「只含该盘对象」的输入工程 → 切片 → 各自落盘 output_plate_<p>.gcode。
  // 顺序执行（内核一次只切一盘）；某盘失败只记该盘并继续下一盘，不整体崩。
  //
  // 【主线程占用自证】本方法全程打三类耗时日志：
  //   · buildMs   —— 输入工程构建（ThreeMfExport.build：纯 JS 的 3MF XML 序列化）在主线程上的同步耗时；
  //   · sliceMs   —— 切片内核调用（异步，见 SlicerService.sliceJsonWithProgress 的 NAPI async_work）；
  //   · 盘间间隔  —— 上一盘收尾到下一盘开始之间的空档（用于对比「主线程被谁占住」）。
  private runPlateSequence(filesDir: string, plates: number[], baseParamsJson: string): void {
    this.plateSeqStartMs = Date.now();
    // 【多盘：一次清空所有盘号的旧产物】之前只在每盘开始前删「本盘」那个文件，
    // 于是导入「盘数更少」的文件后，旧盘号的 output_plate_<N>.gcode 会永久残留。
    SliceCache.clearPlateGcodes(filesDir, true);
    const outcomes: PlateOutcome[] = [];
    let idx: number = 0;
    const step: (() => Promise<void>) = async (): Promise<void> => {
      if (idx >= plates.length) {
        this.finishPlateSequence(filesDir, outcomes);
        return;
      }
      const p: number = plates[idx++];
      // 盘间让帧：上一盘的进度/日志在同一拍内可能还没画出来，这里先交回事件循环，
      // 保证「每一盘开始/结束」在弹窗里都可见，且盘与盘之间界面保持可响应。
      await yieldToUi();
      const plateStartMs: number = Date.now();
      this.dlgModel.pushLog(`盘 ${p} · 开始切片（共 ${plates.length} 盘）`, false);
      const inPath: string = `${filesDir}/slice_plate_${p}.3mf`;
      // 【必开线程】这份「只含该盘对象」的 3MF XML 在真机上是重活（盘1 约 42 万面 / 74MB）：
      // 放主线程实测连续占用 22.8~41 秒 → AppFreeze THREAD_BLOCK（系统「无响应」弹窗）。
      // 改为在独立 ThreadWorker 里构建并落盘，主线程只装配 job + 收结果；Worker 不可用才回退主线程。
      const buildT0: number = Date.now();
      let wrote: boolean = false;
      let bytes: number = 0;
      let viaWorker: boolean = false;
      // Worker 内逐段耗时（自证：把「构建」拆成 XML / 顶点 / 三角 / zip / 落盘各段）。
      let wTotalMs: number = 0;
      let wXmlMs: number = 0;
      let wVMs: number = 0;
      let wTriMs: number = 0;
      let wZipMs: number = 0;
      let wWriteMs: number = 0;
      let verts: number = 0;
      try {
        const r: Mf3mfWriteResult = await ThreeMfExport.buildToFileViaWorker(filesDir, p, inPath);
        if (r.workerUnavailable) {
          const bundle: ExportBundle | null = ThreeMfExport.build(filesDir, p);
          wrote = bundle !== null && ThreeMfExport.writeFile(inPath, bundle.bytes);
          bytes = bundle !== null ? bundle.bytes.length : 0;
          this.sliceLog(`切片 盘=${p} Worker 不可用 → 回退主线程构建（会占主线程）`);
        } else {
          wrote = r.ok;
          bytes = r.bytes;
          viaWorker = true;
          verts = r.verts;
          wTotalMs = r.workerTotalMs;
          wXmlMs = r.xmlMs;
          wVMs = r.vMs;
          wTriMs = r.triMs;
          wZipMs = r.zipMs;
          wWriteMs = r.writeMs;
          if (!r.ok) {
            this.sliceLog(`切片 盘=${p} Worker 构建失败：${r.reason}`);
          }
        }
      } catch (e) {
        hilog.error(0x0000, TAG, '盘 %{public}d 构建输入工程异常: %{public}s', p,
          e instanceof Error ? e.message : JSON.stringify(e));
        wrote = false;
      }
      const buildMs: number = Date.now() - buildT0;
      this.sliceLog(`切片 盘=${p} 输入工程构建=${buildMs}ms 构建方=${viaWorker ? 'Worker' : '主线程'} 字节=${bytes}`);
      if (viaWorker) {
        // 主线程侧 buildMs 与 Worker 侧 workerTotalMs 的差值 ≈ 主线程开销（job 装配 + 消息结构化克隆 + 调度）。
        this.sliceLog(`切片 盘=${p} Worker分段 总=${wTotalMs}ms XML=${wXmlMs}ms(顶点=${wVMs} 三角=${wTriMs}) ` +
          `zip=${wZipMs}ms 落盘=${wWriteMs}ms 顶点数=${verts} 主线程净开销=${buildMs - wTotalMs}ms`);
      }
      if (!wrote) {
        outcomes.push(this.makePlateOutcome(p, false, '', '该盘无对象或输入工程写入失败'));
        this.sliceLog(`切片 盘=${p} 结果=失败(输入工程不可用)`);
        this.dlgModel.pushLog(`盘 ${p} · 失败：输入工程不可用`, true);
        void step();
        return;
      }
      const outPath: string = `${filesDir}/output_plate_${p}.gcode`;
      // 【先删旧产物】同一盘的 output_plate_<p>.gcode 可能是上一次切片留下的：若不删，
      // 本次切片失败时会残留旧文件，预览页就会把「上一份结果」当成「本盘结果」显示（张冠李戴）。
      // 删掉后语义明确：切片成功后重新落盘；失败则无文件 → 预览明确提示「该盘无切片结果（切片失败）」。
      try { if (fs.accessSync(outPath)) { fs.unlinkSync(outPath); } } catch (e) {
        hilog.warn(0x0000, TAG, '删除旧盘产物失败 %{public}s: %{public}s', outPath,
          e instanceof Error ? e.message : JSON.stringify(e));
      }
      const sliceT0: number = Date.now();
      // 本盘的多耗材请求：对象只取本盘（与输入工程里对象顺序一致）→ 颜色不同即拆成多个耗材槽位。
      const plateInsts: ModelInstance[] = modelState.instances.filter((m: ModelInstance) => m.plate === p);
      // 盘级床型：本盘若单独设了床型，覆盖本盘切片参数里的 curr_bed_type（-1 = 跟随全局）
      let bedIdx: number = plateBedEnumIndex(p);
      if (bedIdx < 0) {
        bedIdx = this.globalBedEnumIndex(filesDir);
      }
      const paramsJson: string = SliceParamStore.withBedType(
        SliceParamStore.mergeExtra(baseParamsJson, SliceParamStore.multicolorFragment(plateInsts)), bedIdx);
      this.sliceLog(`切片 盘=${p} 多耗材请求 对象=${plateInsts.length} 槽位=` +
        `${paramsJson.indexOf('__bbs_filament_count') >= 0 ? '多耗材' : '单耗材(N<=1)'}`);
      this.sliceLog(`切片 盘=${p} 床型=${bedIdx >= 0 ? '盘级覆盖 idx=' + bedIdx : '跟随全局'}`);
      try {
        SlicerService.sliceJsonWithProgress(inPath, paramsJson, outPath,
          (pj: string) => { this.onSliceProgress(this.prefixPlateProgress(pj, p)); },
          (rj: string) => {
            const sliceMs: number = Date.now() - sliceT0;
            const o: PlateOutcome = this.parsePlateOutcome(p, rj, outPath);
            outcomes.push(o);
            this.warnIfAny(rj);
            this.sliceLog(`切片 盘=${p} 结果=${o.ok ? '成功' : '失败'} 层=${o.layers} 切片调用=${sliceMs}ms ` +
              `本盘总耗时=${Date.now() - plateStartMs}ms 输出=${o.output}${o.ok ? '' : ' 原因=' + o.message}`);
            this.dlgModel.pushLog(`盘 ${p} · ${o.ok ? `完成 · ${o.layers} 层` : '失败：' + o.message}`, true);
            void step();
          });
      } catch (e) {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        outcomes.push(this.makePlateOutcome(p, false, '', '切片调用异常: ' + msg));
        this.sliceLog(`切片 盘=${p} 结果=失败(调用异常:${msg})`);
        this.dlgModel.pushLog(`盘 ${p} · 失败：切片调用异常`, true);
        void step();
      }
    };
    void step();
  }

  private makePlateOutcome(plate: number, ok: boolean, output: string, message: string): PlateOutcome {
    const o: PlateOutcome = new PlateOutcome();
    o.plate = plate;
    o.ok = ok;
    o.output = output;
    o.message = message;
    return o;
  }

  // 解析单盘切片结果 JSON；失败时 message 为内核原始文本（C++ 侧已把多条 SlicingError 展开）。
  private parsePlateOutcome(plate: number, resultJson: string, outPath: string): PlateOutcome {
    const o: PlateOutcome = new PlateOutcome();
    o.plate = plate;
    try {
      const r: SliceResult = JSON.parse(resultJson) as SliceResult;
      o.ok = r.ok === true;
      o.output = r.ok === true ? (r.output !== undefined && r.output !== '' ? r.output : outPath) : '';
      o.layers = r.layers !== undefined ? r.layers : 0;
      o.grams = r.filamentUsedG !== undefined ? r.filamentUsedG : 0;
      o.est = r.estimatedPrintTime !== undefined ? r.estimatedPrintTime : '';
      o.message = r.message !== undefined ? r.message : '';
    } catch (e) {
      o.ok = false;
      o.message = '结果解析异常: ' + (e instanceof Error ? e.message : JSON.stringify(e));
    }
    return o;
  }

  // 给某盘的进度文案加盘号前缀，便于用户在弹窗里看出「当前在切哪一盘」。
  private prefixPlateProgress(progressJson: string, plate: number): string {
    const m: ProgressMsg | null = parseProgressJson(progressJson);
    if (m === null) { return progressJson; }
    m.msg = `盘${plate} · ` + m.msg;
    return JSON.stringify(m);
  }

  // 全部盘切完：汇总结果。任一盘失败 → 整体 ok=false 并点名是哪一盘、什么原因；
  // 全部成功 → ok=true。另把「当前选中盘」（找不到则第一个成功盘）的产物复制成 output.gcode，
  // 供既有打印/导出链路使用；预览页按盘号直接读 output_plate_<N>.gcode，无需复制。
  private finishPlateSequence(filesDir: string, outcomes: PlateOutcome[]): void {
    // 逐盘序列收尾：释放复用的单例 Worker（本段只创建一次 → hilog 自证「创建=1」）。
    ThreeMfExport.disposeMf3mfWorker('逐盘序列收尾');
    const failed: PlateOutcome[] = outcomes.filter((o: PlateOutcome) => !o.ok);
    let layers: number = 0;
    let grams: number = 0;
    const parts: string[] = [];
    for (const o of outcomes) {
      if (o.ok) { layers += o.layers; grams += o.grams; }
      parts.push(`盘${o.plate}:${o.ok ? '成功(' + o.layers + '层)' : '失败'}`);
    }
    const act: number = AppStorage.get<number>('activePlate') ?? -1;
    let pick: PlateOutcome | undefined = outcomes.find((o: PlateOutcome) => o.ok && o.plate === act);
    if (pick === undefined) { pick = outcomes.find((o: PlateOutcome) => o.ok); }
    let outPath: string = '';
    if (pick !== undefined && pick.output !== '') {
      const dst: string = `${filesDir}/output.gcode`;
      try {
        fs.copyFileSync(pick.output, dst);
        outPath = dst;
      } catch (e) {
        hilog.warn(0x0000, TAG, '复制盘产物到 output.gcode 失败: %{public}s',
          e instanceof Error ? e.message : JSON.stringify(e));
        outPath = pick.output;
      }
    }
    const message: string = failed.length === 0 ? ''
      : `${failed.length} 个盘失败：` +
        failed.map((o: PlateOutcome) => `盘${o.plate}（${o.message !== '' ? o.message : '未知原因'}）`).join('；');
    this.sliceLog(`切片 多盘完成 汇总=${parts.join(' ')} 输出=${outPath} ` +
      `总耗时(逐盘起)→收尾=${Date.now() - this.plateSeqStartMs}ms ` +
      `点击→收尾=${Date.now() - this.sliceStartedMs}ms`);
    const res: SliceResult = {
      ok: failed.length === 0,
      status: failed.length === 0 ? 'done' : 'error',
      output: outPath,
      layers: layers,
      filamentUsedG: grams,
      estimatedPrintTime: '',
      message: message
    };
    this.onSliceDone(JSON.stringify(res));
  }

  // ---- 切片弹窗：打开 / 驱动 / 收尾 -------------------------------------------

  private currentPresetName(kind: number): string {
    // 【优先读「界面持久化的当前预设」】SlicerService 的候选表 selected 是初始化时缓存的，
    // 用户切了工艺/耗材后它不跟着变 → 切片弹窗会**一直显示旧名字**。
    // PresetPersist 的快照是「每次切换成功就写盘」的，才真正等于界面当前选择。
    const filesDir: string = this.filesDirOrEmpty();
    if (filesDir.length > 0) {
      const snap: PresetSnapshot | undefined = PresetPersist.load(filesDir);
      if (snap !== undefined) {
        if (kind === 1 && snap.process !== '') { return snap.process; }
        if (kind === 2 && snap.filament !== '') { return snap.filament; }
      }
    }
    const cat: PresetCatalog | undefined = SlicerService.getCatalog();
    if (cat !== undefined) {
      if (kind === 1 && cat.selected.process !== '') { return cat.selected.process; }
      if (kind === 2 && cat.selected.filament !== '') { return cat.selected.filament; }
    }
    return kind === 1 ? '内置默认工艺' : '内置默认耗材';
  }

  private openSliceDialog(): void {
    this.sliceSettled = false;
    this.sliceStartedMs = Date.now();
    this.appliedStage = -1;
    this.pendingNumeric = null;
    this.pendingLogs = [];
    if (this.flushTimer !== -1) { clearTimeout(this.flushTimer); this.flushTimer = -1; }
    this.lastFlushMs = 0;
    this.logReceived = 0;
    this.logRendered = 0;
    this.logDropped = 0;
    this.statsLogged = false;
    this.dlgModel.setMode('slice');
    this.dlgModel.reset();
    // 副标题：当前工艺预设 + 耗材 + 对象数（都是真实值，不编造）
    this.dlgModel.fileName = this.currentPresetName(1);
    this.dlgModel.fileMeta =
      '· ' + this.currentPresetName(2) + ' · ' + modelState.instances.length + ' 个对象';
    this.dlgVisible = true;
    this.dlgModel.pushLog('开始切片 · ' + modelState.instances.length + ' 个对象', false);
    // 主线程心跳探针：切片只由 onSliceDone / failSlice 两条路径结束，这里同样不引入任何超时判定，
    // 只用来「测量」主线程被同步工作堵住的时段（间隔远超 250ms 的那一段）。
    this.startHeartbeat();
    // 刻意不启动任何超时计时器：切片只由 onSliceDone / failSlice 两条路径结束。
  }

  private startHeartbeat(label: string = '切片'): void {
    this.stopHeartbeat();
    this.hbLastMs = Date.now();
    this.hbMaxGapMs = 0;
    this.hbTimer = setInterval(() => {
      const now: number = Date.now();
      const gap: number = now - this.hbLastMs;
      this.hbLastMs = now;
      if (gap > this.hbMaxGapMs) { this.hbMaxGapMs = gap; }
      // >600ms 视为「主线程被同步工作堵住可观的一段时间」（正常心跳间隔 ≈250ms）
      const lvl: string = gap > 600 ? '阻塞' : '正常';
      // 只走 hilog（不落 diag 文件）：心跳每秒 4 条，避免日志写盘本身给主线程加负载、污染测量。
      hilog.info(0x0000, TAG, '主线程心跳[%{public}s] 间隔=%{public}dms %{public}s（自%{public}s起 %{public}dms）',
        label, gap, lvl, label, now - this.sliceStartedMs);
    }, 250);
  }

  private stopHeartbeat(): void {
    if (this.hbTimer !== -1) { clearInterval(this.hbTimer); this.hbTimer = -1; }
  }

  private stageName(stage: number): string {
    const stages: string[] = this.dlgModel.stages;
    if (stage >= 0 && stage < stages.length) { return stages[stage]; }
    return 'stage' + stage;
  }

  private onSliceProgress(progressJson: string): void {
    const p: ProgressMsg | null = parseProgressJson(progressJson);
    if (p === null) {
      hilog.warn(0x0000, TAG, 'bad progress json: %{public}s', progressJson);
      return;
    }
    this.logReceived++;
    hilog.debug(0x0000, TAG, '进度 stage=%{public}s 阶段内=%{public}s %{public}s',
      this.stageName(p.stage), (Math.round(p.pct) + '%'), p.msg);
    this.acceptProgress(p);
  }

  // 收下一条 C++ 进度：数值与日志走两条独立通道（与导入弹窗同一套规则）。
  private acceptProgress(p: ProgressMsg): void {
    if (this.sliceSettled) {
      // onDone 已到：数值不再被迟到消息改动，但日志仍逐条入队（一条都不丢）。
      this.enqueueLog(p);
      this.scheduleFlush();
      return;
    }
    const isKey: boolean = (p.stage !== this.appliedStage) || p.pct >= 100 || p.stage < 0;
    if (isKey) {
      this.flushLogQueue(this.pendingLogs.length);
      this.pendingNumeric = null;
      this.appliedStage = p.stage;
      this.applyNumericNow(p.stage, p.pct);
      this.writeProgressLog(p);
      return;
    }
    this.enqueueLog(p);
    this.pendingNumeric = p;
    this.scheduleFlush();
  }

  private enqueueLog(p: ProgressMsg): void {
    if (p.msg.length === 0) { return; }
    if (this.pendingLogs.length >= LOG_QUEUE_MAX) {
      this.pendingLogs.shift();
      this.logDropped++;
    }
    this.pendingLogs.push(p);
  }

  // 固定节奏节流：这段时间累积的多行一次性加入（弹窗侧因此只做一次位移动画）
  private scheduleFlush(): void {
    if (this.flushTimer !== -1) { return; }
    const since: number = Date.now() - this.lastFlushMs;
    const delay: number = since >= LOG_FLUSH_INTERVAL_MS ? 0 : (LOG_FLUSH_INTERVAL_MS - since);
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.lastFlushMs = Date.now();
      const num: ProgressMsg | null = this.pendingNumeric;
      this.pendingNumeric = null;
      if (num !== null) { this.applyNumericNow(num.stage, num.pct); }
      this.flushLogQueue(this.pendingLogs.length);
      if (this.pendingLogs.length > 0) { this.scheduleFlush(); }
    }, delay);
  }

  private flushLogQueue(maxCount: number): void {
    let n: number = Math.min(maxCount, this.pendingLogs.length);
    while (n > 0) {
      const p: ProgressMsg | undefined = this.pendingLogs.shift();
      if (p === undefined) { break; }
      this.writeProgressLog(p);
      n--;
    }
  }

  private writeProgressLog(p: ProgressMsg): void {
    if (p.msg.length === 0) { return; }
    this.dlgModel.pushLog(p.msg, p.stage >= 4);
    this.logRendered++;
  }

  private applyNumericNow(stage: number, pct: number): void {
    this.dlgModel.applyNumeric(stage, pct);
  }

  private logSliceStats(): void {
    if (this.statsLogged) { return; }
    this.statsLogged = true;
    hilog.info(0x0000, TAG,
      '日志统计 收到=%{public}s 已渲染=%{public}s 丢弃=%{public}s 队列残留=%{public}s',
      this.logReceived.toString(), this.logRendered.toString(),
      this.logDropped.toString(), this.pendingLogs.length.toString());
  }

  private closeSliceDialog(): void {
    this.logSliceStats();
    this.sliceLog(`主线程心跳 收尾 最大间隔=${this.hbMaxGapMs}ms（切片总耗时 ${Date.now() - this.sliceStartedMs}ms）`);
    this.stopHeartbeat();
    this.dlgVisible = false;
    if (this.flushTimer !== -1) { clearTimeout(this.flushTimer); this.flushTimer = -1; }
  }

  // 失败终态：弹窗内显示失败原因（不静默关闭），并把完整原因留在常驻面板 + hilog 里。
  private failSlice(msg: string): void {
    this.sliceSettled = true;
    this.slicing = false;
    const m: string = msg !== '' ? msg : '切片失败';
    this.sliceError = m;
    hilog.error(0x0000, TAG, '切片失败: %{public}s', m);
    // 三通道落地：hilog + 应用内日志页 + files/diag/gcode_diag.txt（用户要能看到真实原因）
    this.sliceLog('切片失败 · ' + m);
    // 关键：把「失败」写进弹窗日志并让出 2 帧，保证原因真的被渲染出来，再关窗（不是静默关闭）
    this.pendingNumeric = null;
    this.flushLogQueue(this.pendingLogs.length);
    this.dlgModel.pushLog('失败 · ' + m, true);
    promptAction.showToast({ message: `切片失败：${m}` });
    this.yieldAndClose();
  }

  private async yieldAndClose(): Promise<void> {
    await yieldToUi();
    await yieldToUi();
    this.closeSliceDialog();
  }

  // 「切片失败」提示面板的关闭：只清掉失败原因 —— 不清除已切好的结果、不改盘选择状态。
  // 面板是条件渲染（sliceError !== ''），清空即整块移除，不残留遮罩、不影响后续手势与操作。
  private dismissSliceError(): void {
    hilog.info(0x0000, TAG, '用户关闭切片失败提示');
    this.sliceError = '';
  }

  // 内核的「非阻断警告」→ 弹窗日志（不影响切片继续）。
  // 目前只有一条：板型/耗材温度不匹配（Print.cpp 里把原来的 return 改成了写 warning，见移植注释）。
  // 为什么用正则而不是加一个结果类型字段：SliceResult/PlateOutcome 都要跟着改，
  // 而这条信息只用于展示，直接在原始 JSON 上取最省、也不动别的链路。
  private warnIfAny(resultJson: string): void {
    const m: RegExpMatchArray | null = resultJson.match(/"warning"\s*:\s*"([^"]*)"/);
    if (m === null) {
      return;
    }
    const text: string = m[1].replace(/\\n/g, ' ').trim();
    if (text.length > 0) {
      this.dlgModel.pushLog('警告：' + text + '（已按现有参数继续切片）', false);
    }
  }

  private onSliceDone(resultJson: string): void {
    this.warnIfAny(resultJson);
    // 内存快照（切片完成/收尾前）：与「切片前」那条对比即得本次切片的净内存增量。
    AppLog.mem('Slice', '切片完成后(收尾前)');
    // 先让帧：把此前已送达但还没渲染的进度日志排空，再进入收尾
    this.yieldThenHandleDone(resultJson);
  }

  // 把内核写的「切片参数核对」块转发进三通道日志（hilog + 「日志」页 + diag）。
  // 为什么必须转发：那块是内核直接写在 files/diag/gcode_diag.txt 里的，沙箱文件在设备侧
  // （hdc）读不到，只有从应用内读出来再打日志，人和工具才看得到。
  private pushAuditToLog(): void {
    const filesDir: string = this.filesDirOrEmpty();
    if (filesDir.length === 0) { return; }
    try {
      const p: string = `${filesDir}/diag/gcode_diag.txt`;
      if (!fs.accessSync(p)) { return; }
      const txt: string = fs.readTextSync(p);
      const i: number = txt.lastIndexOf('===== [Audit] 切片参数核对');
      if (i < 0) { return; }
      const block: string = txt.substring(i);
      this.sliceLog('---- 切片参数核对（内核自动取证）----');
      const lines: string[] = block.split('\n');
      for (const ln of lines) {
        if (ln.indexOf('[Audit]') >= 0) { this.sliceLog(ln); }
      }
      this.sliceLog('---- 核对结束 ----');
    } catch (e) {
      // 取证失败不影响切片结果
    }
  }

  private async yieldThenHandleDone(resultJson: string): Promise<void> {
    await yieldToUi();
    await yieldToUi();
    try {
      this.sliceSettled = true;
      this.sliceResult = resultJson;
      // 显式排空队列（不依赖定时器竞态），确保已送达的进度都画出来
      const num: ProgressMsg | null = this.pendingNumeric;
      this.pendingNumeric = null;
      if (num !== null) { this.applyNumericNow(num.stage, num.pct); }
      this.flushLogQueue(this.pendingLogs.length);

      const r: SliceResult = JSON.parse(resultJson) as SliceResult;
      if (!r.ok) {
        const m: string = r.message !== undefined && r.message !== '' ? r.message : '(无消息)';
        this.failSlice(m);
        return;
      }
      const layers: number = r.layers !== undefined ? r.layers : 0;
      const grams: number = r.filamentUsedG !== undefined ? r.filamentUsedG : 0;
      // 参数核对取证（内核写文件 → 这里读出来接进 hilog/「日志」页）
      this.pushAuditToLog();
      const est: string = r.estimatedPrintTime !== undefined ? r.estimatedPrintTime : '';
      hilog.info(0x0000, TAG, '切片完成: %{public}s', resultJson);

      // ---- 阶段 5：生成预览（由 ArkTS 侧驱动，数字取自真实结果）----
      this.applyNumericNow(5, 25);
      this.dlgModel.pushLog('生成切片路径预览 · ' + layers + ' 层', true);
      await yieldToUi();
      // 既有行为：通知 G-code 预览重新读取 output.gcode
      const rev: number = AppStorage.get<number>('gcodeRevision') ?? 0;
      AppStorage.setOrCreate<number>('gcodeRevision', rev + 1);
      let bytes: number = 0;
      const outPath: string = r.output !== undefined ? r.output : '';
      if (outPath !== '') {
        try { bytes = fs.statSync(outPath).size; } catch (e) {
          hilog.warn(0x0000, TAG, 'stat output 失败: %{public}s',
            e instanceof Error ? e.message : JSON.stringify(e));
        }
      }
      this.applyNumericNow(5, 70);
      this.dlgModel.pushLog('路径数据就绪 · output.gcode · ' + fmtSize(bytes), true);
      await yieldToUi();
      const used: number = (Date.now() - this.sliceStartedMs) / 1000;
      this.applyNumericNow(5, 100);
      this.dlgModel.pushLog('完成 · 用时 ' + used.toFixed(1) + 's · ' + layers + ' 层 · ' +
        grams.toFixed(1) + 'g · 预计 ' + est, true);
      this.slicing = false;
      promptAction.showToast({ message: `切片完成：${layers} 层 · ${grams.toFixed(1)}g · ${est}` });
      // 关窗前至少让出 2 帧：把 100% 与最后一条日志真正画出来，再关窗
      await yieldToUi();
      await yieldToUi();
      this.closeSliceDialog();
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, TAG, 'onSliceDone 抛出异常: %{public}s', msg);
      this.failSlice('切片结果解析异常');
    }
  }

  // 底部左侧「导入」：选择 .3mf 并解析入库（asOpenProject=true 时同时把它记成「当前工程」）
  private import3mf(asOpenProject: boolean = false): void {
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.fileSuffixFilters = ['.3mf'];
      docPicker.select(opts).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        this.doImport3mf(uris[0], asOpenProject);
      }).catch(() => {
      });
    } catch (e) {
      promptAction.showToast({ message: '打开选择器失败' });
    }
  }

  // 顶栏文档菜单：打开工程（= 选一个 3MF 打开，并把它设为当前文件）。
  // 打开会整体替换当前文档 → 有未保存改动时先确认（保存并继续 / 不保存 / 取消）。
  private openProject(): void {
    this.confirmDiscardIfDirty('打开工程', (): void => { this.import3mf(true); });
  }

  // 顶栏文档菜单 / 最近文件：直接打开某个已知路径。
  // 路径优先取沙箱里的**副本**（原文件被移走/删除也能打开，见 DocState.openPathFor）。
  private openRecent(path: string): void {
    if (path.length === 0) {
      return;
    }
    let target: string = path;
    for (const r of docState.recents()) {
      if (r.path === path) {
        target = docState.openPathFor(r);
        break;
      }
    }
    const name: string = ThreeMfExport.shortName(target);
    this.confirmDiscardIfDirty('打开工程', (): void => {
      promptAction.showToast({ message: `正在打开 ${name}` });
      this.doImport3mf(target, true);
    });
  }

  // onDone：导入**完成后**（成功或失败）回调一次 —— 崩溃恢复要在导入完成后才能正确判脏
  private doImport3mf(uri: string, asOpenProject: boolean = false, onDone?: () => void): void {
    const finish = (): void => {
      if (onDone !== undefined) {
        onDone();
      }
    };
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      promptAction.showToast({ message: '获取上下文失败' });
      finish();
      return;
    }
    promptAction.showToast({ message: '正在解析 3MF…' });
    const filesDir: string = ctx.filesDir;
    // 【导入新文件：先清上一次的切片产物】否则旧 gcode / 盘产物 / 打包缓存一直堆着
    // （实测沙箱已 425MB）。放在导入前清，顺便把 project_input.tmp.3mf 这类大文件腾出空间。
    SliceCache.clearAll(filesDir, '导入新文件');
    // 导入全程走内核 BBL 3MF 加载器（几何 + 设置 + 盘一次拿全），日志由 ThreeMfImport 三通道落地
    ThreeMfImport.importFromUri(uri, filesDir).then((r: Import3mfOutcome) => {
      if (!r.ok) {
        promptAction.showToast({ message: `3MF 导入失败：${r.message}` });
        finish();
        return;
      }
      if (r.objectCount > 0) {
        promptAction.showToast({ message: `已导入 ${r.objectCount} 个对象 · ${r.plateCount} 盘` });
      } else {
        // 几何为 0 也不是「失败」：包内无网格（如切片盘 .3mf），但设置已经读到并应用
        promptAction.showToast({
          message: r.message !== '' ? r.message : '该文件不含模型，仅读取设置'
        });
      }
      if (asOpenProject) {
        // 打开工程：把该文件记成「当前文件」——顶栏改名、脏标记清掉、写进最近文件，
        // 之后 Ctrl+S / 「保存」直接覆盖它。摘要取**导入完成后**的工程内容（含刚载入的对象/参数）。
        docState.noteOpened(uri, history.currentDigest());
      }
      // 底面「点/尖接触」提示：这是几何问题（世界 Zmin 已确认=0、摆放无误），
      // 但首层没有有效挤出截面 → 内核会报 empty initial layer。给一句能操作的建议。
      if (ThreeMfImport.thinBottoms.length > 0) {
        const names: string = ThreeMfImport.thinBottoms.slice(0, 3).join('、');
        const more: string = ThreeMfImport.thinBottoms.length > 3
          ? ` 等 ${ThreeMfImport.thinBottoms.length} 件` : '';
        promptAction.showToast({
          message: `提示：${names}${more} 底部为点/尖接触，切片可能报「首层为空」——建议开启支撑或切平底部`
        });
      }
      finish();
    }).catch((e: Object) => {
      // 不吞异常：完整原因进 hilog（tag=Import3mf），界面给一句可读提示
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'Import3mf', '导入异常: %{public}s', msg);
      promptAction.showToast({ message: '3MF 导入失败：' + msg });
      finish();
    });
  }

  // 底部左侧「保存」：先让用户选导出格式，再走对应导出（不新增按钮，仍接这一个「保存」）。
  //   · 项目 3MF（含切片设置，默认）：内核 store_bbs_3mf 写拓竹原生工程 3MF；
  //   · 通用 3MF（仅模型）：上一轮的实现，标准 OPC 包，第三方切片器都能打开。
  private saveProject(): void {
    // 底部那个「保存」按钮 = 保存当前工程（有路径就覆盖，没有就退化成另存为）
    this.saveCurrent();
  }

  // 「保存」：已有当前文件 → 直接覆盖写（不再弹选择器/格式弹窗）；没有 → 等于另存为。
  // 这是「当前文件」概念落地后的核心行为变化：以前每次保存都要重新挑路径。
  private saveCurrent(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      promptAction.showToast({ message: '获取上下文失败' });
      return;
    }
    const filesDir: string = ctx.filesDir;
    if (modelState.instances.length === 0) {
      ThreeMfExport.log(filesDir, this.saveLog('项目', 0, 0, true, '-', '失败(无可保存对象)'));
      promptAction.showToast({ message: '当前没有可保存的对象' });
      return;
    }
    if (docState.path.length === 0) {
      this.askSaveFormat(filesDir);   // 从未保存过：没有可覆盖的路径，等于另存为
      return;
    }
    this.exportProjectTo(filesDir, docState.path, '保存');
  }

  // 「另存为」：始终弹格式选择（项目 / 含 G-code / 通用），落点由文件选择器定
  private saveAsDoc(): void {
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      promptAction.showToast({ message: '获取上下文失败' });
      return;
    }
    if (modelState.instances.length === 0) {
      promptAction.showToast({ message: '当前没有可保存的对象' });
      return;
    }
    this.askSaveFormat(ctx.filesDir);
  }

  // 统一的 Save3mf 日志行（三通道落地由 ThreeMfExport.log 负责）
  private saveLog(format: string, objectCount: number, triangleCount: number,
                  withSettings: boolean, path: string, result: string): string {
    return `保存3mf 格式=${format} 对象=${objectCount} 三角面=${triangleCount}` +
      ` 含设置=${withSettings ? '是' : '否'} 路径=${path} 结果=${result}`;
  }

  // 格式选择弹窗：index 0=项目 3MF（默认高亮）/ 1=含 G-code 3MF（.gcode.3mf）/ 2=通用 3MF / 3=取消。
  private askSaveFormat(filesDir: string): void {
    try {
      promptAction.showDialog({
        title: '保存 3MF',
        message: '项目 3MF 会写入机型/工艺/耗材预设与全部切片参数，可被 Bambu Studio 完整还原；' +
          '含 G-code 3MF（.gcode.3mf）在项目 3MF 基础上再打进已切好的 G-code（Metadata/plate_1.gcode），' +
          '是打印机可直接打印的包；通用 3MF 只含几何，第三方切片器都能打开。',
        buttons: [
          { text: '项目 3MF（含切片设置）', color: '#FF7A1A' },
          { text: '含 G-code 3MF（.gcode.3mf）', color: '#FF7A1A' },
          { text: '通用 3MF（仅模型）', color: '#9AA4B2' },
          { text: '取消', color: '#9AA4B2' }
        ]
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index === 0) {
          this.startProjectExport(filesDir);
        } else if (res.index === 1) {
          this.startGcodeExport(filesDir);
        } else if (res.index === 2) {
          this.startGenericExport(filesDir);
        } else {
          ThreeMfExport.log(filesDir, `保存3mf 格式=- 对象=${modelState.instances.length}` +
            ' 三角面=- 含设置=- 路径=- 结果=取消');
          promptAction.showToast({ message: '已取消保存' });
        }
      }).catch((e: Object) => {
        // 弹窗被返回键/点击外部关闭也走这里 —— 按「取消」处理，但真实原因不吞，进 hilog
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.info(0x0000, SAVE3MF_TAG, '格式选择弹窗未确认（按取消处理）: %{public}s', msg);
        ThreeMfExport.log(filesDir, `保存3mf 格式=- 对象=${modelState.instances.length}` +
          ' 三角面=- 含设置=- 路径=- 结果=取消');
        promptAction.showToast({ message: '已取消保存' });
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, SAVE3MF_TAG, '格式选择弹窗同步异常: %{public}s', msg);
      ThreeMfExport.log(filesDir, `保存3mf 格式=- 对象=${modelState.instances.length}` +
        ` 三角面=- 含设置=- 路径=- 结果=失败(弹窗异常:${msg})`);
      promptAction.showToast({ message: '保存失败：' + msg });
    }
  }

  // 构建内存工程的「通用 3MF」字节；失败返回 null 并已打日志（调用方不得吞）。
  private buildGenericBundle(filesDir: string, format: string, withSettings: boolean): ExportBundle | null {
    try {
      const b: ExportBundle | null = ThreeMfExport.build(filesDir);
      if (b === null) {
        ThreeMfExport.log(filesDir, this.saveLog(format, 0, 0, withSettings, '-', '失败(无可保存对象)'));
        promptAction.showToast({ message: '当前没有可保存的对象' });
        return null;
      }
      return b;
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, SAVE3MF_TAG, '保存3mf 构建异常: %{public}s', msg);
      ThreeMfExport.log(filesDir, this.saveLog(format, 0, 0, withSettings, '-', `失败(构建异常:${msg})`));
      promptAction.showToast({ message: '保存失败：' + msg });
      return null;
    }
  }

  // 「通用 3MF（仅模型）」：上一轮实现原样保留
  private startGenericExport(filesDir: string): void {
    const bundle: ExportBundle | null = this.buildGenericBundle(filesDir, '通用', false);
    if (bundle === null) {
      return;
    }
    this.writeWithPicker(filesDir, bundle.bytes, bundle.fileName, '通用', false,
      bundle.objectCount, bundle.triangleCount);
  }

  // 「项目 3MF（含切片设置）」：先把内存工程写成「通用 3MF」临时文件当输入（内核按路径读），
  // 再交给内核 store_bbs_3mf 导出拓竹原生工程 3MF，最后把产出复制到用户选择的位置。
  // 「另存为」里的「项目 3MF」分支：落点交给文件选择器（dest 传空串）
  private startProjectExport(filesDir: string): void {
    this.exportProjectTo(filesDir, '', '另存为');
  }

  // 导出「项目 3MF」到指定落点：
  //   dest 为空 → 走文件选择器（另存为）；dest 非空 → 直接写到该路径（保存/覆盖）。
  private exportProjectTo(filesDir: string, dest: string, how: string): void {
    const bundle: ExportBundle | null = this.buildGenericBundle(filesDir, '项目', true);
    if (bundle === null) {
      return;
    }
    promptAction.showToast({ message: how === '保存' ? '正在保存工程…' : '正在导出项目 3MF…' });
    // 1) 临时输入：内核导出需要文件路径作为源（.3mf 扩展名即走内核的 3MF 加载分支）
    const tmpPath: string = `${filesDir}/project_input.tmp.3mf`;
    if (!ThreeMfExport.writeFile(tmpPath, bundle.bytes)) {
      ThreeMfExport.log(filesDir, this.saveLog('项目', bundle.objectCount, bundle.triangleCount, true,
        '-', '失败(临时输入写入失败)'));
      promptAction.showToast({ message: '项目 3MF 导出失败：临时文件写入失败' });
      return;
    }
    // 2) 内核导出（worker 线程；结果经回调回主线程）。outPath 是内核落点（应用沙箱）。
    const outPath: string = ThreeMfExport.projectSandboxPath(filesDir);
    const b: ExportBundle = bundle;
    try {
      // 「对象颜色 → 耗材槽位」也要随导出下发：内核据此把每个对象的 extruder 写进 model_settings.config、
      // 把 N 档 filament_colour 写进 project_settings.config —— 存盘后再打开颜色仍在。
      const paramsJson: string = SliceParamStore.mergeExtra(SliceParamStore.collectParamsJson(),
        SliceParamStore.multicolorFragment(modelState.instances));
      SlicerService.exportProject3mf(tmpPath, paramsJson, outPath, (rj: string) => {
        this.onProjectExportDone(filesDir, b, rj, outPath, dest, how);
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, SAVE3MF_TAG, '内核导出调用异常: %{public}s', msg);
      ThreeMfExport.log(filesDir, this.saveLog('项目', b.objectCount, b.triangleCount, true,
        '-', `失败(内核调用异常:${msg})`));
      promptAction.showToast({ message: '项目 3MF 导出失败：' + msg });
    }
  }

  // 内核项目 3MF 导出回调：解析结果 → 落日志（含往返自测数据）→ 写到目标落点
  //   dest 非空 = 直接覆盖写该路径（「保存」）；dest 为空 = 交给文件选择器（「另存为」）
  private onProjectExportDone(filesDir: string, bundle: ExportBundle,
                              resultJson: string, outPath: string,
                              dest: string, how: string): void {
    let r: Project3mfResult;
    try {
      r = JSON.parse(resultJson) as Project3mfResult;
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, SAVE3MF_TAG, '项目3mf 结果解析失败: %{public}s', msg);
      ThreeMfExport.log(filesDir, this.saveLog('项目', bundle.objectCount, bundle.triangleCount, true,
        '-', `失败(结果解析异常:${msg})`));
      promptAction.showToast({ message: '项目 3MF 导出失败：结果解析异常' });
      return;
    }
    const objCount: number = r.objects !== undefined ? r.objects : bundle.objectCount;
    const triCount: number = r.facets !== undefined ? r.facets : bundle.triangleCount;
    if (r.ok !== true) {
      const m: string = r.message !== undefined && r.message !== '' ? r.message : '(无消息)';
      ThreeMfExport.log(filesDir, this.saveLog('项目', objCount, triCount, true, '-', `失败(${m})`));
      promptAction.showToast({ message: '项目 3MF 导出失败：' + m });
      return;
    }
    // 往返自测（内核读回的对象/面数）落 hilog，作为「写出去能读回」的现场证据
    let rtText: string = '';
    if (r.roundTrip !== undefined) {
      const rtOk: boolean = r.roundTrip.ok === true;
      rtText = ` 往返=${rtOk ? 'ok' : 'fail'}` +
        ` 读回对象=${r.roundTrip.objects !== undefined ? r.roundTrip.objects : -1}` +
        ` 读回三角面=${r.roundTrip.facets !== undefined ? r.roundTrip.facets : -1}` +
        (rtOk ? '' : ` 读回原因=${r.roundTrip.message !== undefined ? r.roundTrip.message : '-'}`);
    }
    hilog.info(0x0000, SAVE3MF_TAG,
      '项目3mf 已写入 %{public}s 机=%{public}s 工艺=%{public}s 耗材=%{public}s%{public}s',
      outPath, r.printer !== undefined ? r.printer : '', r.process !== undefined ? r.process : '',
      r.filament !== undefined ? r.filament : '', rtText);
    const bytes: Uint8Array | null = ThreeMfExport.readFileBytes(outPath);
    if (bytes === null) {
      ThreeMfExport.log(filesDir, this.saveLog('项目', objCount, triCount, true, outPath,
        '失败(沙箱产出读取失败)'));
      promptAction.showToast({ message: '项目 3MF 导出失败：读取产出文件失败' });
      return;
    }
    if (dest.length > 0) {
      // 「保存」：直接覆盖写当前文件；成功后把该路径记成当前文件（清脏标记 + 进最近文件）
      if (ThreeMfExport.writeFile(dest, bytes)) {
        ThreeMfExport.log(filesDir, this.saveLog('项目', objCount, triCount, true, dest, `成功(${how})`));
        docState.noteSaved(dest, history.currentDigest());
        promptAction.showToast({ message: `已保存 ${ThreeMfExport.shortName(dest)}` });
        this.runPendingAfterSave();   // 「保存并继续/退出」里被挂起的那个动作
      } else {
        ThreeMfExport.log(filesDir, this.saveLog('项目', objCount, triCount, true, dest,
          `失败(${how} 写入失败)`));
        promptAction.showToast({ message: '保存失败：写入文件失败' });
      }
      return;
    }
    this.writeWithPicker(filesDir, bytes, ThreeMfExport.projectFileName(), '项目', true, objCount, triCount);
  }

  // 「含 G-code 3MF（.gcode.3mf）」：与打印链路走**同一条**「构建或复用」服务函数（同一份产物）。
  // 这样本地「保存两次」即可验证缓存命中（第二次直接复用，不序列化、不调内核），完全不碰打印机。
  private startGcodeExport(filesDir: string): void {
    promptAction.showToast({ message: '正在导出含 G-code 3MF…' });
    // ③ 构建期间打主线程心跳（复用切片探针），证明主线程全程可响应。
    this.sliceStartedMs = Date.now();
    this.startHeartbeat('含G-code保存构建');
    ThreeMfExport.buildOrReuseGcodePackage(filesDir, '保存').then((pkg: GcodePackage) => {
      this.stopHeartbeat();
      ThreeMfExport.log(filesDir, this.saveLog('含G-code', pkg.objectCount, pkg.triangleCount, true,
        pkg.ok ? pkg.path : '-',
        pkg.ok
          ? `${pkg.cacheHit ? '成功(缓存命中)' : '成功'} 构建=${pkg.buildMs}ms 导出=${pkg.exportMs}ms ` +
            `总=${pkg.totalMs}ms 心跳最大间隔=${this.hbMaxGapMs}ms`
          : `失败(${pkg.reason})`));
      if (!pkg.ok) {
        this.showPkgRetry(filesDir, '含 G-code 3MF 导出失败', pkg.reason, () => {
          ThreeMfExport.resetGcodePackageFailure();
          this.startGcodeExport(filesDir);
        });
        return;
      }
      this.writeGcodeWithPicker(filesDir, pkg);
    });
  }

  // 把已构建/复用的包写到用户选择的位置（fd→fd 复制：不把几十 MB 包读回 JS 堆）。
  private writeGcodeWithPicker(filesDir: string, pkg: GcodePackage): void {
    const fileName: string = ThreeMfExport.gcodeFileName();
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [fileName];
      opts.fileSuffixChoices = ['.3mf'];
      docPicker.save(opts).then((uris: string[]) => {
        if (uris.length === 0) {
          ThreeMfExport.log(filesDir, this.saveLog('含G-code', pkg.objectCount, pkg.triangleCount, true, '-', '取消'));
          promptAction.showToast({ message: '已取消保存' });
          return;
        }
        const uri: string = uris[0];
        if (ThreeMfExport.copyFile(pkg.path, uri)) {
          ThreeMfExport.log(filesDir, this.saveLog('含G-code', pkg.objectCount, pkg.triangleCount, true, uri, '成功'));
          promptAction.showToast({ message: `已保存 ${ThreeMfExport.shortName(uri)}` });
        } else {
          ThreeMfExport.log(filesDir, this.saveLog('含G-code', pkg.objectCount, pkg.triangleCount, true, uri,
            '失败(写入选择器路径失败)'));
          promptAction.showToast({ message: '保存失败：写入文件失败' });
        }
      }).catch((err: Object) => {
        const msg: string = err instanceof Error ? `${err.name}: ${err.message}` : JSON.stringify(err);
        hilog.error(0x0000, SAVE3MF_TAG, '含G-code 保存选择器失败: %{public}s', msg);
        this.fallbackWriteGcode(filesDir, pkg, msg);
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, SAVE3MF_TAG, '含G-code 保存选择器同步异常: %{public}s', msg);
      this.fallbackWriteGcode(filesDir, pkg, msg);
    }
  }

  private fallbackWriteGcode(filesDir: string, pkg: GcodePackage, reason: string): void {
    const path: string = `${filesDir}/${ThreeMfExport.gcodeFileName()}`;
    if (ThreeMfExport.copyFile(pkg.path, path)) {
      ThreeMfExport.log(filesDir, this.saveLog('含G-code', pkg.objectCount, pkg.triangleCount, true, path,
        `成功(选择器不可用回退沙箱:${reason})`));
      promptAction.showToast({ message: `选择器不可用，已保存到应用沙箱：${path}` });
    } else {
      ThreeMfExport.log(filesDir, this.saveLog('含G-code', pkg.objectCount, pkg.triangleCount, true, path,
        '失败(沙箱写入失败)'));
      promptAction.showToast({ message: '保存失败：写入应用沙箱失败' });
    }
  }

  // 选择器保存：成功给提示；用户取消给提示；调用失败/选择器不可用 → 回退沙箱（并写明路径）。
  private writeWithPicker(filesDir: string, bytes: Uint8Array, fileName: string,
                          format: string, withSettings: boolean,
                          objectCount: number, triangleCount: number): void {
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [fileName];
      opts.fileSuffixChoices = ['.3mf'];
      docPicker.save(opts).then((uris: string[]) => {
        if (uris.length === 0) {
          ThreeMfExport.log(filesDir, this.saveLog(format, objectCount, triangleCount, withSettings,
            '-', '取消'));
          promptAction.showToast({ message: '已取消保存' });
          return;
        }
        const uri: string = uris[0];
        if (ThreeMfExport.writeFile(uri, bytes)) {
          ThreeMfExport.log(filesDir, this.saveLog(format, objectCount, triangleCount, withSettings,
            uri, '成功'));
          // 「项目 3MF」就是本应用的工程格式 → 记成当前文件（顶栏改名、清脏标记、进最近文件）
          if (format === '项目') {
            docState.noteSaved(uri, history.currentDigest());
            this.runPendingAfterSave();
          }
          promptAction.showToast({ message: `已保存 ${ThreeMfExport.shortName(uri)}` });
        } else {
          ThreeMfExport.log(filesDir, this.saveLog(format, objectCount, triangleCount, withSettings,
            uri, '失败(写入选择器路径失败)'));
          promptAction.showToast({ message: '保存失败：写入文件失败' });
        }
      }).catch((err: Object) => {
        // 不吞异常：完整原因进 hilog，随后回退沙箱保证用户至少拿到一份文件
        const msg: string = err instanceof Error ? `${err.name}: ${err.message}` : JSON.stringify(err);
        hilog.error(0x0000, SAVE3MF_TAG, '保存选择器失败: %{public}s', msg);
        this.fallbackWrite(filesDir, bytes, fileName, format, withSettings, objectCount, triangleCount, msg);
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, SAVE3MF_TAG, '保存选择器同步异常: %{public}s', msg);
      this.fallbackWrite(filesDir, bytes, fileName, format, withSettings, objectCount, triangleCount, msg);
    }
  }

  private fallbackWrite(filesDir: string, bytes: Uint8Array, fileName: string,
                        format: string, withSettings: boolean,
                        objectCount: number, triangleCount: number, reason: string): void {
    const path: string = `${filesDir}/${fileName}`;
    const ok: boolean = ThreeMfExport.writeFile(path, bytes);
    if (ok) {
      ThreeMfExport.log(filesDir, this.saveLog(format, objectCount, triangleCount, withSettings, path,
        `成功(选择器不可用回退沙箱:${reason})`));
      if (format === '项目') {
        // 回退到沙箱也算「当前文件」：之后再按保存就直接覆盖它
        docState.noteSaved(path, history.currentDigest());
        this.runPendingAfterSave();
      }
      promptAction.showToast({ message: `选择器不可用，已保存到应用沙箱：${path}` });
    } else {
      ThreeMfExport.log(filesDir, this.saveLog(format, objectCount, triangleCount, withSettings, path,
        '失败(沙箱写入失败)'));
      promptAction.showToast({ message: '保存失败：写入应用沙箱失败' });
    }
  }

  // ---- 「打印已暂停」全局模态告警（机器侧 HMS）----
  // 机器侧的 AI/传感器（打印板类型不匹配、炒面、首层缺陷、热床异物、门未关…）在协议里都是 HMS 码，
  // 机器会自己暂停打印。此前 app 只在设备页给一行小字，用户在「准备」页打印时根本看不到。
  // 这里做成模态：必须明确选「继续打印 / 停止打印」，或点「稍后处理」先关掉。
  private pauseDismiss(): void {
    const parts: string[] = [];
    for (const h of this.pauseHits) {
      parts.push(h.ecode);
    }
    parts.sort();
    // 记下「这批故障已看过」：DevicePanel 发布前会对签名，避免同一批故障反复弹
    AppStorage.setOrCreate<string>('pauseAckSig', parts.join(','));
    AppStorage.setOrCreate<HmsHit[]>('pauseHits', []);
    hilog.info(0x0000, 'PauseAlert', '稍后处理 故障=%{public}s', parts.join(','));
  }

  // 机器没停的时候也别让用户猜：下发后无论成败都打日志（失败给 toast）
  private pauseAct(cmd: string): void {
    const seq: string = `${Date.now() % 100000}`;
    const json: string = `{"print":{"command":"${cmd}","sequence_id":"${seq}","param":""}}`;
    hilog.info(0x0000, 'PauseAlert', '下发 %{public}s', cmd);
    MqttService.sendCommand(json).then((r: string): void => {
      hilog.info(0x0000, 'PauseAlert', '%{public}s 返回=%{public}s', cmd, r);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'PauseAlert', '%{public}s 下发异常: %{public}s', cmd, msg);
      promptAction.showToast({ message: `指令下发失败：${msg}` });
    });
    this.pauseDismiss();
    promptAction.showToast({ message: cmd === 'resume' ? '已发送「继续打印」' : '已发送「停止打印」' });
  }

  // 等级配色与设备页保持一致（≤1 红 / 2 橙 / ≥3 黄；不给等级编中文名）
  private pauseLevelColor(level: number): string {
    if (level <= 1) { return '#FF5A3C'; }
    if (level === 2) { return '#FF9F1A'; }
    return '#FFD23F';
  }

  @Builder
  pauseAlertDialog() {
    Stack() {
      // 遮罩：点外部 = 稍后处理（不把人卡死在弹窗里）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#A6000000')
        .onClick(() => { this.pauseDismiss(); })

      Column({ space: 14 }) {
        Row({ space: 10 }) {
          Text('!')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#0B0E13')
            .textAlign(TextAlign.Center)
            .width(26)
            .height(26)
            .backgroundColor('#FF5A3C')
            .borderRadius(13)
          Text('打印已暂停')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary)
          Blank()
          Text(`${this.pauseHits.length} 项故障`)
            .fontSize(11)
            .fontColor('#FFB4A8')
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
            .backgroundColor('#26FF5A3C')
            .borderRadius(9)
        }
        .width('100%')

        Text('打印机检测到异常并暂停了打印。处理完再继续，或直接停止：')
          .fontSize(12)
          .fontColor(Theme.textSecondary)
          .lineHeight(18)
          .width('100%')

        Column({ space: 8 }) {
          ForEach(this.pauseHits, (h: HmsHit) => {
            Row() {
              Text('●')
                .fontSize(9)
                .fontColor(this.pauseLevelColor(h.level))
                .margin({ top: 3 })
              Column({ space: 3 }) {
                Text(h.intro.length > 0 ? h.intro : `HMS ${h.ecode}`)
                  .fontSize(13)
                  .fontColor(Theme.textPrimary)
                  .lineHeight(19)
                  .width('100%')
                Text(`HMS ${h.ecode}`)
                  .fontSize(10)
                  .fontColor('#7A7A88')
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (h: HmsHit) => h.ecode)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .backgroundColor('#14FFFFFF')
        .borderRadius(10)
        .border({ width: 1, color: '#1FFFFFFF' })

        Row({ space: 10 }) {
          Button('停止打印')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor('#FF8A7A')
            .backgroundColor('#26FF5A3C')
            .borderRadius(10)
            .onClick(() => { this.pauseAct('stop'); })
          Button('继续打印')
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#06281E')
            .backgroundColor(Theme.accent)
            .borderRadius(10)
            .onClick(() => { this.pauseAct('resume'); })
        }
        .width('100%')

        Text('稍后处理')
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .textAlign(TextAlign.Center)
          .width('100%')
          .onClick(() => { this.pauseDismiss(); })
      }
      .width(470)
      .padding(20)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#F2181D25')
      .borderRadius(16)
      .border({ width: 1, color: '#33FFFFFF' })
      .shadow({ radius: 30, color: '#99000000', offsetX: 0, offsetY: 12 })
    }
    .width('100%')
    .height('100%')
  }

  // 中栏（3D 视口）左右两侧的「拖动手柄」：拖动改变对应面板宽度。
  // 视觉：深色玻璃风格一致（surfaceElevated 底 + border 描边），**不使用 .shadow()**。
  // 【看得见】本轮的可见性设计（组合拳，不做常驻动画以免持续耗电/干扰）：
  //   ① 手柄条加宽到 HANDLE_W=12vp，且底色比两侧面板（左 bg / 右 surface）都亮一档 → 整条能看出来；
  //   ② 居中一个 10×30vp 的「抓手」胶囊：近黑底 + 品牌绿 3 段短横线（抓手纹理）→ 一眼就知道能拖；
  //   ③ 拖动中整块点亮为品牌绿（active 反馈），松手后回到常态。
  // 手柄位于两侧面板之间、不覆盖内容，窄屏（手机横屏）下也不会挡住 3D 或参数。
  // side：0=左（向右拖 → 左栏变宽）1=右（向右拖 → 右栏变窄）
  @Builder
  dragHandle(side: number) {
    Column() {
      // 抓手胶囊：3 段短横线（抓手纹理）竖排居中
      Column({ space: 3 }) {
        Column()
          .width(8).height(2).borderRadius(1)
          .backgroundColor(this.draggingSide === side ? '#0B0B0F' : Theme.accentSoft)
        Column()
          .width(8).height(2).borderRadius(1)
          .backgroundColor(this.draggingSide === side ? '#0B0B0F' : Theme.accentSoft)
        Column()
          .width(8).height(2).borderRadius(1)
          .backgroundColor(this.draggingSide === side ? '#0B0B0F' : Theme.accentSoft)
      }
      .width(10)
      .height(30)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(5)
      // 常态：近黑底 + 描边（与亮一档的手柄条对比明显）；拖动中：整块点亮为品牌绿
      .backgroundColor(this.draggingSide === side ? Theme.accent : '#0E0E12')
      .border({ width: 1, color: this.draggingSide === side ? Theme.accentSoft : Theme.border })
    }
    .width(HANDLE_W)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 手柄条底色比左右两块面板都亮一档，整条即为一条清晰的分界/抓手
    .backgroundColor(Theme.surfaceElevated)
    .border({ width: { left: 1, right: 1 }, color: Theme.border })
    .gesture(
      // distance=1：让拖动尽快被识别，保证「实时生效、不卡顿」
      PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
        .onActionStart(() => { this.beginDrag(side); })
        .onActionUpdate((e: GestureEvent) => { this.updateDrag(side, e.offsetX); })
        .onActionEnd(() => { this.endDrag(); })
        .onActionCancel(() => { this.draggingSide = -1; })
    )
  }

  build() {
    Stack() {
      Column() {
        TopBar({
          onNewDoc: (): void => { this.newProject(); },
          onSaveDoc: (): void => { this.saveCurrent(); },
          onSaveAsDoc: (): void => { this.saveAsDoc(); },
          onOpenDoc: (): void => { this.openProject(); },
          onOpenRecent: (path: string): void => { this.openRecent(path); },
          onRemoveRecent: (path: string): void => { docState.removeRecent(path); },
          onClearRecents: (): void => { docState.clearRecents(); }
        })
        Row() {
          LeftNav({
            active: this.activeTab,
            onChange: (i: number) => { this.activeTab = i; },
            // 设置按钮：不再弹全屏浮层，而是把 activeTab 切到「设置」页 —— 与准备/预览/设备
            // 完全同一种展现方式，设置页渲染在内容区、受左侧导航栏约束（导航栏始终可见、可切走）。
            onSettings: () => { this.activeTab = 5; },
            // 打赏按钮（位于「设置」上方）：同样切 activeTab 到常规内容页，导航栏始终可见。
            // ★ 内购手续未办妥期间入口已隐藏（IapService.IAP_ENTRY_VISIBLE=false）：
            //   这里也不再切到打赏页，保证没有任何路径能把 activeTab 落到 6。
            onTip: () => { if (IAP_ENTRY_VISIBLE) { this.activeTab = 6; } }
          })

          // 内容区：Stack 叠放两层 —— 底层是「准备/预览」共用的常驻 3D 子树，
          // 上层是设备/校准/日志（与引擎无关，保持原来的条件渲染，最小改动）。
          Stack() {
            // ===== 3D 引擎承载链（准备 0 / 预览 1）：必须「常驻」=====
            // 【为什么不能再用条件渲染】ArkUI 的 if 分支在条件变假时会【卸载并销毁整个子树】：
            // Component3D / Scene / 相机 / 光照 / 材质 / 几何 会被一起拆掉，切回来要重新加载
            // 3D 引擎并重建几何（慢），而且这个「销毁再重建」过程正是「材质丢失变灰」的主要来源。
            // 所以这里改成 .visibility() 只切显示/隐藏：组件始终留在组件树上，仅不可见、不吃手势。
            Row() {
              // 准备页左侧：对象列表（所有设备都显示 —— 手机已被强制横屏，宽度够）；
              // 宽度交给外层容器控制（拖动可改），ObjectList 自身铺满该容器。
              if (this.activeTab === 0) {
                Column() {
                  ObjectList()
                }
                .width(this.leftW)
                .height('100%')
                this.dragHandle(0)
              }
              // 3D 视口列：模型页常驻；预览页的「模型/切片路径」切换条仅在预览页出现
              Column() {
                if (this.activeTab === 1) {
                  Row({ space: 6 }) {
                    Button('模型')
                      .fontSize(12)
                      .height(26)
                      .backgroundColor(this.previewMode === 0 ? Theme.accent : Theme.surfaceElevated)
                      .fontColor(this.previewMode === 0 ? Theme.bg : Theme.textPrimary)
                      .onClick(() => { this.previewMode = 0; })
                    Button('切片路径')
                      .fontSize(12)
                      .height(26)
                      .backgroundColor(this.previewMode === 1 ? Theme.accent : Theme.surfaceElevated)
                      .fontColor(this.previewMode === 1 ? Theme.bg : Theme.textPrimary)
                      .onClick(() => { this.previewMode = 1; })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 6, bottom: 4 })
                  .justifyContent(FlexAlign.Start)
                }

                // alignContent.End：本层 Stack 负责把「按内容自适应」的盘列表容器摆到右侧。
                // 其余子节点均为 100%×100%，对齐方式对其无影响。不能用子节点自身的 .align()：
                // .align() 的语义是「对齐组件自身内容」，不能把组件摆到父 Stack 的右侧（默认 Center 会摆到屏幕中部）。
                Stack({ alignContent: Alignment.End }) {
                  // 模型预览常驻：切页只切可见性，绝不销毁场景（否则丢引擎/丢材质）
                  // hidePlateList：切片路径态由外层（本 Stack）在 GcodePreview 之上再渲染一份可点的盘列表
                  //（否则 ModelPreviewPage 内的那份被覆盖层吃掉点击、切片路径态点不到）；两份不同时显示。
                  ModelPreviewPage({
                    pageVisible: this.activeTab === 0 || this.activeTab === 1,
                    hidePlateList: this.activeTab === 1 && this.previewMode === 1,
                    // 「准备」页可见性：离开准备页时模型页会把编辑工具栏/三维手柄收起，
                    // 避免「在准备页开着旋转/缩放/移动手柄直接切到预览页」时手柄残留在预览页上。
                    prepareVisible: this.activeTab === 0
                  })
                    .width('100%')
                    .height('100%')
                  // 切片路径控制层同样常驻（不再随 previewMode 被销毁），仅切可见性。
                  // 不可见时置 HitTestMode.None，避免隐藏层吃掉 3D 视口的手势。
                  GcodePreview({
                    gcodeVisible: this.activeTab === 1 && this.previewMode === 1,
                    // 「3D 页面」可见性（与 ModelPreviewPage 同源）：用于区分「切到非 3D 页」与
                    // 「切到准备页 / 模型态」—— 前者可保留切片路径几何（保活），后者必须释放以显示模型。
                    pageVisible: this.activeTab === 0 || this.activeTab === 1
                  })
                    .width('100%')
                    .height('100%')
                    .visibility((this.activeTab === 1 && this.previewMode === 1) ? Visibility.Visible : Visibility.Hidden)
                    .hitTestBehavior((this.activeTab === 1 && this.previewMode === 1) ? HitTestMode.Default : HitTestMode.None)
                  // 切片路径态的右侧竖排盘列表：渲染在 GcodePreview 覆盖层【之上】（Stack 后置子节点层级更高），
                  // 故这几行位置的命中目标就是它本身。
                  // 【关键：包裹容器只包住列表本身、不要铺满全屏】上一层若用「全屏 + HitTestMode.Transparent」的容器，
                  // 则该容器「自身不阻塞兄弟节点」→ 下方的 GcodePreview 手势层（PanGesture distance=2）仍与同一触点
                  // 处于同一条命中链 → 手指在缩略图这类大目标上的微小位移会被下方手势抢走、点击落空（表现为「只有
                  // 较小的文字能点中」）。这里改为：包裹容器按内容自适应（恰好=列表尺寸），保持默认 HitTestMode.Default
                  // （自身与子节点响应、且在自身 bounds 内阻塞兄弟节点）→ 列表范围内不再有手势竞争；列表四周的空白
                  // 不再被覆盖，照常穿透给覆盖层，旋转/缩放/平移不受影响。
                  // 位置：右对齐居中、右边距 14（由【父 Stack 的 alignContent = End】定位，外观与原先一致）。
                  if (this.activeTab === 1 && this.previewMode === 1 && this.plates.length >= 2) {
                    Column() {
                      PlateList({ onSelect: (n: number) => { gcodeSignals.switchPlate(n); } })
                    }
                    .margin({ right: 14 })
                    .hitTestBehavior(HitTestMode.Default)
                  }
                }
                .width('100%')
                .layoutWeight(1)
              }
              .width('100%')
              .layoutWeight(1)
              // 准备页右侧：动态参数面板（所有设备都显示）；宽度交给外层容器控制（拖动可改）
              if (this.activeTab === 0) {
                this.dragHandle(1)
                Column() {
                  DynamicParamsPanel({ onFilament: () => { this.showFilament = true; } })
                }
                .width(this.rightW)
                .height('100%')
              }
            }
            .width('100%')
            .height('100%')
            // 实测三栏可用总宽：窗口尺寸 / 旋转 / 折叠 / 安全区变化都会触发，用于重夹面板宽度
            .onAreaChange((_o: Area, n: Area) => { this.onContentArea(n); })
            // 只切可见性：切到设备/校准/日志时本体仍在树上（引擎/场景不被销毁），
            // 但不可见、不响应手势，也不会盖住上层的可见页。
            .visibility((this.activeTab === 0 || this.activeTab === 1) ? Visibility.Visible : Visibility.Hidden)
            .hitTestBehavior((this.activeTab === 0 || this.activeTab === 1) ? HitTestMode.Default : HitTestMode.None)

            // ===== 设备 / 校准 / 日志 / 设置：与引擎无关，保持原有条件渲染 =====
            if (this.activeTab === 2) {
              DevicePanel()
                .width('100%')
                .height('100%')
            } else if (this.activeTab === 3) {
              CalibrationPanel({ onShowSlicePath: () => { this.previewMode = 1; this.activeTab = 1; } })
                .width('100%')
                .height('100%')
            } else if (this.activeTab === 4) {
              LogPanel()
                .width('100%')
                .height('100%')
            } else if (this.activeTab === 5) {
              // 设置页：与设备/校准/日志同一容器写法（宽度/高度一致），渲染在内容区，
              // 因此左侧导航栏照常可见、可点其它页切走；不再用覆盖全屏的 Stack 浮层。
              SettingsPanel()
                .width('100%')
                .height('100%')
            } else if (this.activeTab === 6) {
              // 打赏页：同「设置」页一样渲染在内容区（非全屏浮层），左侧导航栏始终可见。
              TipPanel()
                .width('100%')
                .height('100%')
            }
          }
          .width('100%')
          .height('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)

        if (this.activeTab === 0 || this.activeTab === 1) {
          SliceBar({
            onSlice: () => { this.startSlice(); },
            onPrint: () => { this.openPrintDialog(); },
            onSave: () => { this.saveProject(); },
            onUndo: () => { this.doUndo(); },
            onRedo: () => { this.doRedo(); }
          })
        }
      }
      .width('100%')
      .height('100%')

      // 耗材编辑弹窗（入口在右侧参数面板「耗材」选择器下方）。
      // 结构照搬 PrintDialog：同窗口 + Stack 叠层 + 全屏遮罩 —— 那条路真机已验证可点。
      if (this.showFilament) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#B8060609')
            .onClick(() => { this.showFilament = false; })
          FilamentEditor({ onClose: () => { this.showFilament = false; } })
        }
        .width('100%')
        .height('100%')
      }

      // 切片弹窗：复用导入弹窗组件（同一套视觉），强制模态、无取消按钮
      if (this.dlgVisible) {
        LoadingDialog({ model: this.dlgModel })
      }

      // 打印弹窗：对象颜色 ⇄ AMS 槽位映射 + 三个打印开关（数据来自真实设备状态）
      if (this.printDlgVisible) {
        PrintDialog({
          slots: this.printSlots,
          printerText: this.printPrinterText,
          slicePrinter: this.printSlicePrinter,
          connectedPrinter: this.printConnPrinter,
          initialOptions: this.printInitialOpts,
          onCancel: () => { this.onPrintCancelled(); },
          onConfirm: (opts: PrintOptionsSnapshot, pairs: string, mapped: number, unmapped: number) => {
            this.onPrintConfirmed(opts, pairs, mapped, unmapped);
          },
          onUpload: (opts: PrintOptionsSnapshot, pairs: string, mapped: number, unmapped: number) => {
            this.onPrintUpload(opts, pairs, mapped, unmapped);
          }
        })
      }

      // 切片失败详情：常驻显示（可选中复制），toast 看不到的东西在这里看。
      // 右下角「关闭」按钮：显式关闭（只清 sliceError，不动已切好的结果 / 盘选择状态）。
      if (this.sliceError !== '' && !this.slicing) {
        Column({ space: 10 }) {
          Text('切片失败')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF6B6B')
          Text(this.sliceError)
            .fontSize(12)
            .fontColor(Theme.textPrimary)
            .constraintSize({ maxHeight: 220 })
          Row() {
            Blank()
            // 深色玻璃 + 品牌绿文字（工程既有按钮风格，不用 .shadow()）
            Button('关闭')
              .fontSize(12)
              .height(30)
              .padding({ left: 16, right: 16 })
              .backgroundColor('#CC12161C')
              .fontColor(Theme.accent)
              .borderRadius(8)
              .border({ width: 1, color: '#4700C48C' })
              .onClick(() => { this.dismissSliceError(); })
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        // 必须给面板「确定宽度」：内部 Row 的 .width('100%') 百分比是按父（本 Column）确定的基准解析，
        // 若本 Column 只是 constraintSize({maxWidth})（按内容自适应、无确定宽度），'100%' 会落到更外层
        // （整屏）解析 → Blank 吃掉整行、右侧「关闭」按钮被推到屏幕外而不渲染。width(620) 给出确定基准。
        .width(620)
        .constraintSize({ maxHeight: 320 })
        .padding(16)
        .margin({ bottom: 96 })
        .backgroundColor(Theme.surfaceElevated)
        .borderRadius(12)
        .border({ width: 1, color: '#FF6B6B' })
        .align(Alignment.Bottom)
      }

      // 打印已暂停告警（跨页模态）：只在机器报「状态=PAUSE + HMS 非空」时出现。
      // 作为根 Stack 的最后一个子节点 → 覆盖顶栏与所有页签，用户在任何页面都能看到。
      if (this.pauseHits.length > 0) {
        this.pauseAlertDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    // 沉浸式安全区（加在布局根上，覆盖主界面 + 全部浮层，避免浮层里的按钮被系统栏遮住）：
    // 顶部为状态栏让出高度（顶栏不被遮），底部为三键导航栏让出高度（底部工具栏/关闭按钮不被压到导航区之下）。
    // 留白由本节点的 backgroundColor(Theme.bg) 填充 —— 内容铺满到屏幕底，而不是系统栏默认的那条黑边。
    .padding({
      top: this.getUIContext().px2vp(this.safeTopPx),
      bottom: this.getUIContext().px2vp(this.safeBottomPx)
    })
    // PC / 2in1 快捷键入口（Ctrl+C / Ctrl+V / Ctrl+Z / Ctrl+Shift+Z）：
    // 容器必须可获焦才能收到按键；输入框内的按键会被输入框自己消费，不会冒泡到这里。
    .focusable(true)
    .onKeyEvent((event: KeyEvent): void => {
      this.onWorkspaceKey(event);
    })
  }
}
