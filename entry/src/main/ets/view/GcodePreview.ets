import { Theme } from '../common/Theme';
import { gcodeToolpath, gcodeSignals, ROLE_LABEL, ROLE_COLOR_HEX, RELEASE_GCODE_ON_LEAVE } from '../model/GcodeToolpath';
import { ThreeMfExport } from '../service/ThreeMfExport';
import { PlateMeta } from '../model/Models';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 切片路径预览的控制层。
//
// 几何不在这里画：真正的切片路径由模型页的 ArkGraphics3D 场景渲染
// （见 ModelPreviewPage 的 rebuildToolpath —— 路径是同一个场景里的棱柱网格，
// 所以打印板、光照、相机、材质与「模型」页完全一致）。
// 本组件只做三件事：
//   1) 解析 output.gcode（gcodeToolpath 单例，扁平数组存段）；
//   2) 通过 AppStorage 通知模型页「是否显示路径 / 当前第几层 / 重新读取过了」；
//   3) 画顶栏、层滑条和图例这些 UI。
//
// 整层背景透明且 hitTestBehavior = None：中间区域的手势直接落到下面的 3D 场景，
// 旋转/缩放沿用模型页自己的轨道相机。只有按钮和滑条自己吃事件。

@Component
export struct GcodePreview {
  // 切片成功时由 Index 递增，触发重新读取
  @StorageProp('gcodeRevision') @Watch('onRevision') gcodeRev: number = 0;
  // 只让「是否显示路径」走 AppStorage（切换频率极低）；层号刻意留在组件内部，
  // 通过 gcodeSignals 直接通知模型页 —— 若挂成 @StorageProp，模型页会跟着每格重渲染并闪烁。
  @StorageLink('gcodeShow') gcodeShow: boolean = false;
  // 多盘文件的盘列表（与准备页 / 右侧竖排盘列表同一份数据源）；用于判定「多盘无产物 = 切片失败」。
  @StorageProp('modelPlates') plates: PlateMeta[] = [];
  // 本轮「几何对应的盘号」：用于「在准备页换了盘、再切回切片路径」时判定保活几何是否过期。
  private geomPlate: number = -1;

  // ---- 可见性开关（由 Index 的「切页保活」驱动）----
  // 本组件现在被 Index 常驻（不再随 previewMode 被条件渲染销毁），因此「是否真的显示切片路径」
  // 必须由外部显式告知：activeTab===1（预览页）且 previewMode===1（切片路径态）时才为真。
  // 语义：
  //   · 变为可见 → 首次走 reload() 读取 output.gcode 并通知模型页重建几何 + 扫层；
  //     若是上一次「保活隐藏」后的回归，则只确认几何是否还在（不重跑 reload / 不重扫层）。
  //   · 变为不可见 → 【只停工作、只隐藏，不销毁几何】（见 evaluateHide / keepAlivePause / hidePathKeepGeometry）。
  //     几何、块状态、层滑条位置、相机视角全部保留，切回来直接呈现原状态。
  //
  // 【切页是否释放几何由 RELEASE_GCODE_ON_LEAVE 决定（见 GcodeToolpath，改那一个常量即可）】
  //   · false（新默认）：切到「非 3D 页」只暂停、切到「准备页 / 模型态」只隐藏路径根，几何一律保留；
  //   · true（旧行为，逃生开关）：切走一律释放几何，回来走 reload→重建。
  @Prop @Watch('onVisibleChanged') gcodeVisible: boolean = false;

  // 「3D 页面」是否可见（准备页 0 / 预览页 1 为真；设备 2 / 校准 3 / 日志 4 为假）。
  // 与 ModelPreviewPage 的 pageVisible 同源（Index 用同一表达式传入）。
  // 【为什么需要它】单看 gcodeVisible 无法区分两种「不可见」，两种都不能销毁几何，区别只在「怎么隐藏」：
  //   · 切到非 3D 页（设备/校准/日志）：整块 3D 子树都不可见 → 路径根可以保持可见（反正看不到），只暂停工作；
  //   · 切到准备页 / 预览页的「模型」态：3D 子树仍可见、且必须显示模型 → 把 gcodeShow 置回 false：
  //     模型页据此把模型放回原位、并把路径根置为不可见（模型与路径是同一场景里的互斥显示），几何仍保留。
  @Prop @Watch('onPageVisibleChanged') pageVisible: boolean = true;

  @State ready: boolean = false;
  @State msg: string = '正在读取切片结果…';
  @State statText: string = '';
  @State layerCount: number = 0;
  @State cur: number = 1;
  @State curZ: number = 0;
  // 扫层进行中：由模型页通过 gcodeSignals.sweepState 回调驱动（扫层动画期间为真）。
  // 与 @StorageProp('gcodeRendering') 一起决定右上角「渲染中」提示的显隐。
  @State sweeping: boolean = false;
  @State presentRoles: number[] = [];
  @State legendOpen: boolean = true;
  // 「渲染中」提示显隐：由模型页通过 AppStorage 的 gcodeRendering 广播。
  // 刻意用 @StorageProp（可观察）订阅而不是读普通对象字段 —— 本项目老坑就是「值改了但界面不刷新」，
  // 可观察存储能保证值一变 ArkUI 必然重刷；@Watch 仅用于打日志（显示/隐藏各一条），自证链路通断。
  @StorageProp('gcodeRendering') @Watch('onRenderingChanged') rendering: boolean = false;

  // 视角操作：与「模型浏览」页用同一套声明式手势，只是把手势增量转发给 gcodeSignals
  // （pan/orbit/zoom → 场景相机）。
  //
  // 为什么不再自己 onTouch 解析原始触摸：
  //   1) 触控板产生的是鼠标/滚轮/轴事件，根本不是 TouchEvent，onTouch 完全收不到，
  //      所以旧写法在触控板上「完全不能用」；
  //   2) 自己解析手指数与位移的手感/映射和模型页不一致。
  //
  // 为什么内层用 GestureMode.Parallel（而不是模型页的 Exclusive）：
  //   模型页把「捏合缩放」和「双指拖动旋转」放进 Exclusive 组，二者互斥 ——
  //   实测双指旋转会被捏合识别器抢掉（表现就是「双指不能旋转」）。
  //   改成 Parallel 后捏合与双指拖动可以同时识别：缩放 + 旋转同时生效。
  private lastPanX: number = 0;
  private lastPanY: number = 0;
  private lastRotateX: number = 0;
  private lastRotateY: number = 0;
  private lastPinchScale: number = 1;

  // 上一次「不可见」是否走了「保留几何（保活）」分支：决定切回来时是「直接呈现」还是「重新读取重建」。
  private keptGeometry: boolean = false;
  // 隐藏侧判定是否已排定：同一帧内 gcodeVisible / pageVisible 可能一起变化，合并成一次判定（见 scheduleHideEval）。
  private hideEvalScheduled: boolean = false;
  // 读取序号：reload() 现在是异步分块解析，可能被后一次 reload 取代（快速连续切片 / 反复进出）。
  // 只有最新一次的序号才允许把结果写回 UI，避免旧解析覆盖新状态（异步竞态）。
  private loadSeq: number = 0;

  aboutToAppear(): void {
    // 先注册回调再 reload：reload() 会调用 startSweep()，模型页随即回调 sweepState(true)，
    // 回调必须已经就位，否则「扫层进行中」这一次状态会被丢掉。
    gcodeSignals.sweepState = (v: boolean): void => { this.sweeping = v; };
    // 扫层逐层揭示时同步滑条位置与 Z 值，让用户看到「正在从底部长到顶」
    gcodeSignals.onSweepLayer = (n: number): void => {
      this.cur = n;
      this.curZ = gcodeToolpath.layerZAt(n - 1);
    };
    // 切片路径态里右侧竖排盘列表的点击 → 走本组件的 switchPlate（写 activePlate + 重载该盘几何）。
    gcodeSignals.switchPlate = (n: number): void => { this.switchPlate(n); };
    // 常驻组件：只有「真正可见」（预览页的切片路径态）时才去读 gcode / 建几何；
    // 不可见期间保持未加载，避免在准备页 / 设备页空跑解析。
    if (this.gcodeVisible) {
      this.reload();
    }
  }

  // 当前选中盘号：直接从 AppStorage 读（@StorageProp 的值同步在切页时可能晚一拍，
  // 读写盘号的逻辑一律走这里，避免用到过期的 this.activePlate）。
  private currentPlate(): number {
    return AppStorage.get<number>('activePlate') ?? -1;
  }

  // 可见性变化（Index 切页 / 预览页「模型↔切片路径」切换）。
  // 策略由 RELEASE_GCODE_ON_LEAVE 决定（改 GcodeToolpath 里那一个常量即可）。
  onVisibleChanged(): void {
    if (this.gcodeVisible) {
      // 可见：与 pageVisible 无关，可直接判定。
      // 若这次「可见」是上一次「保活隐藏」后的回归，则只确认几何是否还在，绝不重跑 reload()
      // —— reload() 会复位 currentLayer 并重跑扫层，正是用户抱怨的「需要重新渲染」。
      // 【但保活几何只对「同一个盘」有效】：用户可能在准备页（此时切片路径不可见）换了盘，
      // 此时保留下来的几何属于旧盘 —— 若直接呈现就是「标签变了、路径还是上一盘的」张冠李戴。
      // 所以先比对盘号：不一致 → 作废保活、走 reload 重新读取该盘产物。
      if (!RELEASE_GCODE_ON_LEAVE && this.keptGeometry) {
        const cur: number = this.currentPlate();
        if (cur !== this.geomPlate) {
          hilog.info(0x0000, 'GcodePreview',
            '切片路径可见 → 保活几何属于盘 %{public}d、当前盘 %{public}d → 作废并重载', this.geomPlate, cur);
          this.keptGeometry = false;
          this.reload();
          return;
        }
        hilog.info(0x0000, 'GcodePreview', '切片路径可见 → 保活命中，直接呈现原状态（不重跑 reload / 不重扫层）');
        this.resumeKeptGeometry();
        return;
      }
      hilog.info(0x0000, 'GcodePreview', '切片路径可见 → 重新读取 gcode 并重建几何/扫层');
      this.reload();
      return;
    }
    // 不可见：需要 pageVisible 才能区分「切到非 3D 页」与「切到准备页/模型态」，
    // 而父组件会在同一帧内同时更新这两个 @Prop，@Watch 触发顺序不保证 → 推迟一拍、等值落定后再判定。
    this.scheduleHideEval();
  }

  // pageVisible 变化时也要判定：从「非 3D 页」直接切到「准备页」或预览页的「模型」态时，
  // gcodeVisible 并不变化（本就是 false），但此情此景必须把路径隐藏起来（这些页要显示模型）。
  onPageVisibleChanged(): void {
    if (!this.gcodeVisible) {
      this.scheduleHideEval();
    }
  }

  private scheduleHideEval(): void {
    if (this.hideEvalScheduled) {
      return;
    }
    this.hideEvalScheduled = true;
    setTimeout((): void => {
      this.hideEvalScheduled = false;
      this.evaluateHide();
    }, 0);
  }

  private evaluateHide(): void {
    if (this.gcodeVisible) {
      return; // 已经切回可见，交给 onVisibleChanged 处理
    }
    if (RELEASE_GCODE_ON_LEAVE) {
      // 逃生开关（旧行为）：离开切片路径一律释放几何，回来走 reload→重建。
      hilog.info(0x0000, 'GcodePreview', '切片路径不可见 → 释放几何（RELEASE_GCODE_ON_LEAVE=true 逃生开关）');
      this.releasePath();
      return;
    }
    if (!this.pageVisible) {
      // 切到「非 3D 页」（设备 / 校准 / 日志）：整块 3D 子树都不可见 → 只暂停工作、保留几何。
      // （路径根保持可见无害：它所在的 3D 子树本身就不显示。）
      hilog.info(0x0000, 'GcodePreview', '切片路径不可见（切到非 3D 页）→ 仅暂停，保留几何');
      this.keepAlivePause();
      return;
    }
    // 切到准备页 / 预览页的「模型」态：3D 子树仍可见、且必须显示模型。
    // 这里【只隐藏、不销毁】—— 旧写法是释放几何，回来要重新解析+重建+重扫层，正是用户抱怨的
    // 「一回到准备页再切回切片路径就卡一下然后重新渲染」。
    hilog.info(0x0000, 'GcodePreview', '切片路径不可见（切到准备页 / 模型态）→ 只隐藏路径根，保留几何');
    this.hidePathKeepGeometry();
  }

  // 非 3D 页保活：只做「暂停工作」，【不】置 gcodeShow=false（3D 子树整体不可见，路径根可见也无所谓）。
  // 暂停项（扫层定时器 / 后台补建 / 日志 flush /「渲染中」广播 / 越界脉冲）由模型页的 pageVisible
  // 暂停逻辑统一处理（Index 用同一表达式同时驱动两个开关，因此这里无需重复），这里只把本组件 UI
  // 侧的状态收敛干净，避免「渲染中」残留到下次回来。
  private keepAlivePause(): void {
    this.keptGeometry = true;
    this.sweeping = false;
    AppStorage.setOrCreate<boolean>('gcodeRendering', false);
  }

  // 准备页 / 预览页「模型」态：3D 仍可见，但必须「只看到模型」。
  // 模型与路径是同一个场景里的互斥显示，靠 gcodeShow 这一处开关切换：
  //   · gcodeShow=true  → 模型被移到视锥外(HIDDEN_POS)、路径根可见；
  //   · gcodeShow=false → 模型回到原位、路径根被置为不可见（模型页 updateToolpath 的「路径已隐藏」分支）。
  // 所以这里只置 gcodeShow=false 就同时做到「显示模型 + 隐藏路径」，且【不销毁】任何几何：
  // 块节点/几何、lastVisChunks、层滑条位置、相机视角全部保留，切回切片路径时原样复用。
  private hidePathKeepGeometry(): void {
    this.keptGeometry = true;
    this.sweeping = false;
    AppStorage.setOrCreate<boolean>('gcodeRendering', false);
    this.gcodeShow = false;
  }

  // 保活隐藏后切回来：几何应当仍在 → 直接呈现原状态。
  // 真正的「几何是否还在」判定在模型页（它持有 toolpathRoot / 块节点），本组件只发一个恢复请求；
  // 模型页在几何缺失时自动降级为重建（见 ModelPreviewPage.resumeGcodeKeepAlive）。
  // 这里【不】调用 reload()、【不】调用 startSweep()，因此层滑条位置 / 可见块状态 / 相机视角全部保留。
  private resumeKeptGeometry(): void {
    this.keptGeometry = false;
    // 隐藏时若曾把 gcodeShow 置回 false（准备页 / 模型态），切回切片路径要重新置 true：
    // 模型页据此把模型重新藏起、并把路径根恢复可见；几何仍在 → 不重建、不重跑 reload、不重扫层。
    // （非 3D 页保活情形下 gcodeShow 本就是 true，这里是空操作。）
    if (!this.gcodeShow) {
      this.gcodeShow = true;
    }
    gcodeSignals.resumeKeepAlive();
  }

  // 逃生开关（RELEASE_GCODE_ON_LEAVE=true）专用：置 gcodeShow=false 让模型页走「撤下即销毁」分支，
  // 只销毁切片路径根节点与相关缓存，场景 / 相机 / 光照 / 材质 / 打印板与网格全部保留。
  private releasePath(): void {
    this.keptGeometry = false;
    this.sweeping = false;
    this.gcodeShow = false;
    // 「渲染中」标志立刻复位：不可见期间不能继续显示，也不能残留到下次回来
    AppStorage.setOrCreate<boolean>('gcodeRendering', false);
  }

  onRevision(): void {
    if (!this.gcodeVisible) {
      // 不可见时不做任何解析/建几何；同时把保活标记作废 —— 切片结果已变，保留下来的几何已过期，
      // 下次真正进入切片路径时要走 reload()（load() 会推进 generation），由模型页按
      // 「gcode 变化」这一【唯一必须销毁的时机】销毁旧几何并重建。
      this.keptGeometry = false;
      return;
    }
    this.reload();
  }

  // 换盘（切片路径态里右侧竖排盘列表 PlateList 点击 → gcodeSignals.switchPlate → 这里）。
  // 【为什么是显式调用而不是 @Watch('activePlate')】本项目实测：AppStorage 的值变化 +
  // @StorageProp/@Watch 的通知在本工程里不可靠（值相同不通知、时序竞争），所以切盘这条链路
  // 由 UI 直接驱动 —— 先写 AppStorage（准备页盘列表 / 模型页可见性据此同步），再显式 reload()。
  private switchPlate(n: number): void {
    if (n <= 0) { return; }
    const old: number = this.currentPlate();
    if (n === old) { return; }
    hilog.info(0x0000, 'GcodePreview', '切片路径换盘 %{public}d → %{public}d', old, n);
    AppStorage.setOrCreate<number>('activePlate', n);
    // 换盘即作废保活几何：必须整棵重建，绝不能让「标签变了、路径还是上一盘的」发生。
    this.keptGeometry = false;
    if (this.gcodeVisible) {
      this.reload();
    }
  }

  // 清空顶栏统计 / 层滑条状态：换到「无产物」的盘时必须清掉，避免顶栏残留上一盘的面数与层数。
  private clearStat(): void {
    this.statText = '';
    this.layerCount = 0;
    this.presentRoles = [];
    this.cur = 1;
    this.curZ = 0;
    this.sweeping = false;
  }

  // 「渲染中」标志的 UI 侧自证日志：能打出来说明 AppStorage → @StorageProp 链路通了；
  // 若模型页那边打了「显示」而这里没打，就是界面没收到状态（可观察性问题）。
  onRenderingChanged(): void {
    hilog.info(0x0000, 'GcodePreview', '渲染中标志 UI %{public}s', this.rendering ? '显示' : '隐藏');
  }

  aboutToDisappear(): void {
    // 摘掉回调，避免组件销毁后模型页仍在扫层、回调打到已卸载的实例
    gcodeSignals.sweepState = (v: boolean): void => {};
    gcodeSignals.onSweepLayer = (n: number): void => {};
    gcodeSignals.switchPlate = (n: number): void => {};
    this.sweeping = false;
    // 置 gcodeShow=false 让模型页撤掉路径节点并复位「渲染中」标志。
    this.gcodeShow = false;
  }

  private async reload(): Promise<void> {
    // 走完整重建流程 → 不再是「保活几何」，避免下次切回来误判为可直接呈现。
    this.keptGeometry = false;
    const seq: number = ++this.loadSeq;
    const ctx = this.getUIContext().getHostContext();
    if (!ctx) {
      this.ready = false;
      this.msg = '获取上下文失败';
      return;
    }
    // 按当前选中盘取切片产物：
    //   · 多盘（plates>=2 且 activePlate>0）→ 只认本盘的 output_plate_<N>.gcode；【绝不回退到 output.gcode】。
    //     该盘没有产物 = 该盘切片失败 → 明确提示，且不显示任何别的盘的路径（避免张冠李戴）。
    //   · 单盘 / 无盘信息（activePlate<=0，或盘列表只有 1 盘）→ 沿用 output.gcode（原行为）。
    //     单盘文件切片走的是「原始文件 → output.gcode」这条老路，根本不会产出 output_plate_<N>.gcode，
    //     所以「找不到本盘产物」在单盘情形下不是失败，必须回退 output.gcode（否则单盘回归会被误判为切片失败）。
    const act: number = this.currentPlate();
    let path: string = `${ctx.filesDir}/output.gcode`;
    if (act > 0) {
      const platePath: string = `${ctx.filesDir}/output_plate_${act}.gcode`;
      if (ThreeMfExport.fileExists(platePath)) {
        path = platePath;
      } else if (this.plates.length < 2) {
        path = `${ctx.filesDir}/output.gcode`;
      } else {
        // 多盘文件里本盘无切片产物：不复用上一盘的几何 / 也不回退别的文件 —— 直接落「失败」提示态。
        this.loadSeq++;
        this.ready = false;
        this.geomPlate = -1;
        this.msg = `盘 ${act} 无切片结果（切片失败）`;
        // 顶栏统计与层滑条状态一并清空：否则会残留上一盘的面数/层数（同样是「张冠李戴」）。
        this.clearStat();
        hilog.info(0x0000, 'GcodePreview', '盘 %{public}d 无切片产物 → 提示失败、不显示其它盘路径', act);
        AppStorage.setOrCreate<boolean>('gcodeRendering', false);
        this.gcodeShow = false;
        return;
      }
    }
    // 【分块异步解析】load() 不再在主线程一次性 readTextSync + 同步解析整份 gcode（大模型会触发
    // THREAD_BLOCK_6S → AppFreeze）。这里先置未就绪并复用既有的「正在读取切片结果…」提示显示进度，
    // 每解析完一块都会回调 progress 刷新百分比，解析全程主线程保持可响应。
    this.ready = false;
    this.msg = '正在读取切片结果…';
    const ok: boolean = await gcodeToolpath.load(path, (pct: number, m: string): void => {
      if (seq !== this.loadSeq) { return; }
      // pct < 0 = 解析在独立线程里跑、没有细粒度进度 → 只显示文案（不带百分比）
      this.msg = pct >= 0 ? `${m} ${pct}%` : m;
    });
    // 已被更新的一次 reload 取代（快速连续切片 / 反复进出），或等待期间已切走（不再需要显示路径）
    // → 本次结果作废，不写回 UI（否则会把已经隐藏的路径又强行点亮）。
    if (seq !== this.loadSeq || !this.gcodeVisible) { return; }
    this.ready = ok;
    if (!ok) {
      this.msg = act > 0 ? `盘 ${act} 无切片结果（切片失败）` : '还没有切片结果：先在「准备」页点「切片」';
      this.geomPlate = -1;
      this.clearStat();
      // 无切片结果 → 模型页不会建几何，标志直接复位，避免上次会话的残留值继续显示
      AppStorage.setOrCreate<boolean>('gcodeRendering', false);
      this.gcodeShow = false;
      return;
    }
    // 本轮几何对应的盘号：用于切回切片路径时判定保活几何是否过期（见 onVisibleChanged）。
    this.geomPlate = act;
    this.statText = gcodeToolpath.statText;
    this.layerCount = gcodeToolpath.layerCount;
    this.presentRoles = gcodeToolpath.presentRoles;
    // 进入预览即「显示全部层」：模型页按当前目标层分批建几何并逐批揭示，形成自下而上的自然长出；
    // 等所有层建成并收敛后，「渲染中」标志由模型页自动隐藏。
    gcodeToolpath.currentLayer = gcodeToolpath.layerCount;
    this.cur = gcodeToolpath.layerCount;
    this.curZ = gcodeToolpath.layerZAt(gcodeToolpath.layerCount - 1);
    this.gcodeShow = true;
    // 解析已经完成，通知模型页建几何
    gcodeSignals.rebuild();
    // 并要求「自下而上逐层揭示」扫层动画（约 1.4 秒）。
    // 时序要点：模型页对 gcodeShow 的 @StorageProp 通知晚一拍才到，若那里把这份
    // 「自己触发的重建」也当成外部操作去 cancelSweep，就会把刚启动的扫层掐掉；
    // 模型页已用 selfTriggered 标记区分（见 onGcodeState），因此这里可以放心启动。
    gcodeSignals.startSweep();
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 8 }) {
        Text('切片路径')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Text(this.statText)
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button(this.legendOpen ? '隐藏图例' : '显示图例')
          .fontSize(11)
          .height(26)
          .padding({ left: 10, right: 10 })
          .backgroundColor(Theme.surfaceElevated)
          .fontColor(Theme.textPrimary)
          .onClick(() => { this.legendOpen = !this.legendOpen; })
        Button('适应')
          .fontSize(11)
          .height(26)
          .padding({ left: 10, right: 10 })
          .backgroundColor(Theme.surfaceElevated)
          .fontColor(Theme.textPrimary)
          .onClick(() => { gcodeSignals.fit(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#B3171C22')
      .borderRadius(10)
      .margin({ left: 12, right: 12, top: 8 })

      if (!this.ready) {
        Column() {
          Text(this.msg)
            .fontSize(13)
            .fontColor(Theme.textSecondary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 中间区域：透明，但自己接管手势并转发给场景相机（结构与参数抄自 ModelPreviewPage，
        // 只保留与视角相关的部分；缩放手势的系数换算也与那里一致）
        Stack() {
          // 右上角「渲染中」提示：扫层动画进行中，或层还在补建中时显示，全部结束即隐藏。
          // 两个来源取或：@StorageProp('gcodeRendering')（模型页广播）与 @State sweeping（扫层回调）。
          // 深色玻璃小胶囊 + 绿色强调色 + 等宽字体（沿用项目视觉语言）；禁用 .shadow()。
          // hitTestBehavior=None：绝不吃 3D 视口的手势（旋转/缩放/平移照常）。
          if (this.rendering || this.sweeping) {
            Row({ space: 6 }) {
              Circle({ width: 6, height: 6 }).fill(Theme.accent)
              Text('渲染中')
                .fontSize(11)
                .fontColor(Theme.textPrimary)
                .fontFamily('monospace')
            }
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor('#CC12161C')
            .borderRadius(9)
            .border({ width: 1, color: '#4700C48C' })
            .margin({ right: 14, top: 12 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .alignContent(Alignment.TopEnd)
        .width('100%')
        .layoutWeight(1)
        // 触控板：双指拖动（轴事件）→ 旋转视角（与模型页 onAxisEvent 一致）。
        // 触控板不产生 TouchEvent，只能靠这个入口，这也是旧 onTouch 方案在触控板上失效的原因。
        .onAxisEvent((e: AxisEvent) => {
          const h: number = e.getHorizontalAxisValue();
          const v: number = e.getVerticalAxisValue();
          if (h !== 0 || v !== 0) {
            gcodeSignals.orbit(h, v);
          }
        })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            // 单指 / 按住鼠标拖动 → 平移
            PanGesture({ fingers: 1, distance: 2 })
              .onActionStart(() => {
                this.lastPanX = 0;
                this.lastPanY = 0;
              })
              .onActionUpdate((e: GestureEvent) => {
                const dx: number = e.offsetX - this.lastPanX;
                const dy: number = e.offsetY - this.lastPanY;
                this.lastPanX = e.offsetX;
                this.lastPanY = e.offsetY;
                gcodeSignals.pan(dx, dy);
              }),
            GestureGroup(GestureMode.Parallel,
              // 双指捏合 → 缩放（factor = 本次 scale / 上次 scale）
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.lastPinchScale = 1;
                })
                .onActionUpdate((e: GestureEvent) => {
                  if (this.lastPinchScale > 0.01) {
                    gcodeSignals.zoom(e.scale / this.lastPinchScale);
                  }
                  this.lastPinchScale = e.scale;
                }),
              // 双指拖动 → 二轴旋转
              PanGesture({ fingers: 2, distance: 6 })
                .onActionStart(() => {
                  this.lastRotateX = 0;
                  this.lastRotateY = 0;
                })
                .onActionUpdate((e: GestureEvent) => {
                  const dx: number = e.offsetX - this.lastRotateX;
                  const dy: number = e.offsetY - this.lastRotateY;
                  this.lastRotateX = e.offsetX;
                  this.lastRotateY = e.offsetY;
                  gcodeSignals.orbit(dx, dy);
                })
            )
          )
        )

        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(`第 ${this.cur}/${this.layerCount} 层`)
              .fontSize(11)
              .fontColor(Theme.textPrimary)
              .width(96)
            Slider({ value: this.cur, min: 1, max: this.layerCount, step: 1 })
              .layoutWeight(1)
              .trackColor(Theme.surfaceElevated)
              .selectedColor(Theme.accent)
              .onChange((v: number, mode: SliderChangeMode) => {
                // 拖动与松手在这里【无需】再做任何「来源标记」：模型页的块大小已按总层数一次性定死，
                // 与可见层数无关 —— 拖动期间不会有任何销毁 / 重建 / 块重排，故这里只更新层号与视角无关状态。
                const n: number = Math.max(1, Math.min(this.layerCount, Math.round(v)));
                if (n !== this.cur) {
                  this.cur = n;
                  this.curZ = gcodeToolpath.layerZAt(n - 1);
                  gcodeToolpath.currentLayer = n;
                  gcodeSignals.rebuild();
                }
              })
            Text(`Z ${this.curZ.toFixed(2)}`)
              .fontSize(11)
              .fontColor(Theme.textSecondary)
              .width(58)
          }
          .width('100%')

          if (this.legendOpen) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.presentRoles, (r: number) => {
                Row({ space: 4 }) {
                  Circle({ width: 7, height: 7 }).fill(ROLE_COLOR_HEX[r])
                  Text(ROLE_LABEL[r]).fontSize(10).fontColor(Theme.textSecondary)
                }
                .margin({ right: 10 })
              }, (r: number) => `role-${r}`)
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#B3171C22')
        .borderRadius(10)
        .margin({ left: 12, right: 12, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
    // 自己吃掉手势（默认行为），不让它再落到下面模型页的那套手势上，否则会双份移动
    .hitTestBehavior(HitTestMode.Default)
  }
}
