import { Theme } from '../common/Theme';
import { MqttService } from '../service/MqttService';
import uiMaterial from '@ohos.arkui.uiMaterial';
import promptAction from '@ohos.promptAction';
import image from '@ohos.multimedia.image';
import {
  Scene, SceneResourceFactory, MaterialType, LightType, PrimitiveTopology,
  CustomGeometry, Camera, Node, Geometry, MeshResource, Material,
  MetallicRoughnessMaterial, CullMode, RenderingPipelineType, EnvironmentBackgroundType
} from '@kit.ArkGraphics3D';
import type { Vec3, Quaternion, Light } from '@kit.ArkGraphics3D';
import {
  MeshGeometry, eulerToQuaternion, dirToQuaternion, multiplyQuaternion,
  rotateVecByQuat, autoFitDistance, materializeVerticesChunked, materializeIndicesChunked
} from '../model/MeshUtils';
import { modelState, ModelInstance } from '../model/ModelState';
import { PrinterCaps, capsOf, matchModelId } from '../model/PrinterMatrix';
import { hmsTable, HmsItem, HmsHit } from '../service/HmsTable';
import { deviceBook, KnownDevice } from '../service/DeviceBook';
import { PrinterFiles, RemoteFile } from '../service/PrinterFiles';
import { ThreeMfExport } from '../service/ThreeMfExport';
import picker from '@ohos.file.picker';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 设备页零件 3D 预览的 hilog tag（新增，不改动任何既有 tag）
const PV_TAG: string = 'DevicePreview';

// 设备页「切页保活/回页自动恢复」的 hilog tag（新增，不改动任何既有 tag 的语义）
const DEV_TAG: string = 'DevicePanel';

// MQTT 连接结果（原生 MqttConnect 回传）：ok=false 时带 code/message（可行动失败原因，供 UI 直接展示）
interface MqttConnectResult {
  ok?: boolean;
  code?: string;
  message?: string;
}

// 打印机状态（对应 C++ getPrinterState 返回 JSON）
class PrinterState {
  connected: boolean = false;
  serial: string = '';
  ip: string = '';
  state: string = '';
  progress: number = 0;
  layer: number = 0;
  totalLayers: number = 0;
  remainingMinutes: number = 0;
  nozzleTemp: number = 0;
  bedTemp: number = 0;
  chamberTemp: number = 0;
  // 温度是否"已知"：增量上报（P1/A1 只发变化过的字段）下未收到该字段 → false，UI 显示 "--"（不用 0 冒充）
  nozzleTempKnown: boolean = false;
  bedTempKnown: boolean = false;
  chamberTempKnown: boolean = false;
  nozzleTargetTemp: number = 0;
  bedTargetTemp: number = 0;
  chamberTargetTemp: number = 0;
  hasChamberHeater: boolean = false;
  partFan: number = 0;
  auxFan: number = 0;
  chamberFan: number = 0;
  ams: AmsUnit[] = [];
  npEnabled: boolean = false;
  // 本会话收到的状态推送(push_status)条数：0 = 已连接但未收到任何状态数据
  pushStatusCount: number = 0;
  // 表驱动扩展字段（显示名 → 显示值，由 C++ 的 kExtReportFields 决定内容）：
  // 这里刻意不做强类型成员 —— 以后 C++ 加字段，这个面板一个字都不用改。
  ext: Record<string, string> = {};
  // HMS 故障数组（原样透传，文案由 service/HmsTable 查离线码表）
  hms: HmsItem[] = [];
  // 机器侧 AI 检测开关（原样透传的 print.xcam；{} = 该机型没有这套检测）
  xcam: Record<string, Object> = {};
}

// 「状态详情」的一行（显示名 / 显示值）
class ExtRow {
  k: string = '';
  v: string = '';
}

// 摄像头帧数据
//   · format='rgba'（默认）：data 为 width*height*4 字节 RGBA
//   · format='jpeg'        ：data 为完整 JPEG，交由系统 image 模块解码
interface CameraFrameData {
  width: number;
  height: number;
  seq: number;
  format?: string;
  data: ArrayBuffer;
}

// 命令下发结果（mqttSendCommand 回调 JSON）
class CmdResult {
  ok: boolean = false;
}

// AMS 料盘
class AmsTray {
  type: string = '';
  color: string = '#808080';
  remain: number = -1;
}

// AMS 单元
class AmsUnit {
  id: string = '';
  humidity: number = 0;
  temp: number = 0;
  trays: AmsTray[] = [];
}

// 发现的打印机
class DiscoveredPrinter {
  ip: string = '';
  serial: string = '';
  model: string = '';
}

// 设备页：仅「设备状态」（局域网下其余功能无效）
@Component
export struct DevicePanel {
  @State nozzleTemp: number = 0;
  @State bedTemp: number = 0;
  @State chamberTemp: number = 0;
  // 温度是否已知（false → 显示 "--"，不用 0 冒充）
  @State nozzleTempKnown: boolean = false;
  @State bedTempKnown: boolean = false;
  @State chamberTempKnown: boolean = false;
  @State nozzleTargetTemp: number = 0;
  @State bedTargetTemp: number = 0;
  @State chamberTargetTemp: number = 0;
  @State hasChamberHeater: boolean = false;
  @State chamberFan: number = 0;
  @State auxFan: number = 0;
  @State partFan: number = 0;
  @State layer: number = 0;
  @State totalLayers: number = 0;
  @State progress: number = 0;
  @State state: string = '--';
  // 剩余时间（设备上报 print.mc_remaining_time，单位分钟）；0 = 未上报/未知 → UI 显示 "--"
  @State remainingMinutes: number = 0;
  // 「状态详情」：表驱动扩展字段的渲染行（顺序固定，见 buildExtRows）
  @State extRows: ExtRow[] = [];
  // HMS 故障（已查离线码表）：空 = 当前无故障
  @State hmsHits: HmsHit[] = [];
  // 机器侧 AI 检测开关（X1/H2D 这类带摄像头的机型才上报；空 = 整块隐藏）
  @State xcamRows: ExtRow[] = [];
  // 打印错误码（print_error → device_error 码表）查表结果；undefined = 无错误
  @State printErrHit: HmsHit | undefined = undefined;
  // 「打印暂停告警」是否已发布（跨页模态由 Index 渲染）+ 已发布过的故障签名
  private pauseShown: boolean = false;
  private pauseSig: string = '';
  @State connected: boolean = false;
  // 本会话收到的状态推送条数（0 = 已连接但未收到状态数据 → UI 明确标注，避免"连上却没数据"被误显示为已连接）
  @State statusCount: number = 0;
  @State connectedSerial: string = '';
  @State ledOn: boolean = true;
  @State autoFilament: boolean = true;
  @State printers: DiscoveredPrinter[] = [];
  @State accessCode: string = '';
  @State discovering: boolean = false;
  // 是否已执行过一次"发现打印机"（用于区分"还没点过发现"与"点了但没发现到"，
  // 后者才给出"手动输入 IP + 访问码"的引导）
  @State discovered: boolean = false;
  @State connecting: boolean = false;
  @State connectingSerial: string = '';
  @State showAccessDialog: boolean = false;
  @State pendingIp: string = '';
  // 「我的打印机」设备簿（记住连过的机器 + 访问码，一键直连）
  @State knownDevices: KnownDevice[] = [];
  // 正在就地改名的设备 serial + 输入中的名字（空 = 不在改名）
  @State editingBookSerial: string = '';
  @State editingBookName: string = '';
  // 回页自动重连只尝试一次（避免打印机离线时每次轮询都重试）
  private autoReconnectTried: boolean = false;
  // ---- 打印机文件（浏览 / 下载 / 删除）----
  @State showFilesDialog: boolean = false;
  @State fileDir: string = '/cache';
  @State fileItems: RemoteFile[] = [];
  @State filesLoading: boolean = false;
  @State filesMsg: string = '';
  // 正在操作的文件名（下载/删除中，该行按钮换成"处理中…"）
  @State fileBusy: string = '';
  @State pendingSerial: string = '';
  // 手动连接（跳过局域网发现，直接填 IP + 访问码）
  @State showManualDialog: boolean = false;
  @State manualIp: string = '';
  @State manualCode: string = '';
  private pollTimer: number = -1;
  // 各温度命令下发时间戳（用于乐观更新，避免命令生效前被 pollState 覆盖）
  private nozzleCmdTime: number = 0;
  private bedCmdTime: number = 0;
  private chamberCmdTime: number = 0;
  // 当前正在编辑的温度类型（-1 表示无），聚焦输入时阻止 pollState 覆盖
  private editingKind: number = -1;
  // 各风扇命令下发时间戳（用于乐观更新）
  private partFanCmdTime: number = 0;
  private auxFanCmdTime: number = 0;
  private chamberFanCmdTime: number = 0;
  // 摄像头
  private connectedIp: string = '';
  // 已连接打印机的机型（SSDP 友好名，用于选择 322/6000 端口；空则由原生侧按序列号前缀兜底）
  private connectedModel: string = '';
  // 摄像头端口强制开关（测试注入用）：0 自动 / 1 强制 322 / 2 强制 6000
  private cameraForceProto: number = 0;
  private cameraTimer: number = -1;
  // 上次启动摄像头取流时用的序列号（空 = 启动时 SN 还未学到，端口只能靠试）
  private cameraSerial: string = '';
  // 新协议(NP)模式（report 含 cfg/fun/aux/stat），决定 AMS 刷新命令格式
  private npEnabled: boolean = false;
  // AMS 刷新节流（RFID 读卡需数秒且 AMS 同一时间只能读一个槽位）
  @State amsRefreshBusy: boolean = false;
  // 最近收到的帧序号/时间（seq 去重 + 断流看门狗）
  private lastFrameSeq: number = -1;
  private lastFrameTime: number = 0;
  // PixelMap 创建中标记（防止异步回调乱序覆盖）
  private pmPending: boolean = false;

  // 沉浸光感材质：按下发光（interactive 关闭，避免抢占 Button 点击）
  private buttonMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THICK,
    materialColor: '#1A1F2733',
    applyShadow: true,
    interactive: true,
    lightEffect: { color: '#00C48C' },
  });
  // 轻量版（无阴影）：滚动列表里的小按钮用，避免逐帧重采样阴影导致滑动卡顿
  private fanButtonMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THICK,
    materialColor: '#1A1F2733',
    applyShadow: false,
    interactive: true,
    lightEffect: { color: '#00C48C' },
  });
  // 手动连接的玻璃质感（THIN，高透明 + 绿色光感）
  private manualMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#141A1E24',
    applyShadow: true,
    interactive: true,
    lightEffect: { color: '#00C48C' },
  });

  // AMS 实时数据
  @State amsUnits: AmsUnit[] = [];
  // 摄像头帧（RGBA PixelMap）
  @State cameraPixelMap: image.PixelMap | undefined = undefined;

  // ---- 零件预览窗口：复用准备页同款 ArkGraphics3D 渲染 ----------------------------------
  // 为什么另建一个 Scene 而不是把准备页那个 Scene 直接挂上来（可行性结论见报告）：
  //   · ArkGraphics3D 没有任何「把一个 Scene 绑到第二个 Component3D」的接口或文档支持，
  //     且 Component3D 的 SceneOptions 创建后不可动态修改（官方文档明确）；
  //   · 设备页是条件渲染（离开即销毁），把准备页那份「保活 Scene」挂进来会在切页时
  //     反复给同一份场景挂/卸渲染表面，极易打乱准备页的渲染状态（这正是需求里点名要避免的）。
  // 因此走官方明确支持的共享路径：RenderResourceFactory 创建的资源可跨「同一 RenderContext」
  // 的多个 Scene 共享（Scene.d.ts:128-135）——网格数据仍只有一份（modelState 单例里的
  // MeshGeometry 纯数据，这里按引用喂给第二个场景，JS 侧零拷贝），只是引擎侧多上传一份 GPU 顶点/索引缓冲。
  @State private pvReady: boolean = false;      // 预览场景就绪（就绪后才创建 Component3D）
  @State private pvHasModel: boolean = false;    // 是否存在可预览的零件模型（空态判定）
  @State private pvText: string = '初始化预览…'; // 过程/失败态文案（空态另有专门文案）
  // 与准备页同一套「回前台重贴材质」信号（失焦/前后台切换会重建渲染表面，材质绑定丢失→变灰）
  @StorageLink('renderResumeSeq') @Watch('onPvRenderResume') pvResumeSeq: number = 0;
  private pvScene: Scene | null = null;
  private pvFactory: SceneResourceFactory | null = null;
  private pvCamera: Camera | null = null;
  private pvWorld: Node | null = null;   // 只做平移（把取景锚点挪到屏幕中心）
  private pvPivot: Node | null = null;   // 只做旋转（相机固定，内容整体旋转）
  private pvModelMat: MetallicRoughnessMaterial | null = null;
  private pvGeos: Map<number, Geometry> = new Map<number, Geometry>();
  private pvMats: Map<number, Material> = new Map<number, Material>();
  // 与准备页一致的取景角（俯仰/偏航）与默认模型色（PBR 橙）
  private readonly pvPitch: number = 0.5;
  private readonly pvYaw: number = 0.7;
  private readonly pvDefaultRgb: Vec3 = { x: 0.95, y: 0.45, z: 0.13 };

  aboutToAppear(): void {
    this.pollTimer = setInterval(() => {
      this.pollState();
    }, 2000);
    this.initPreviewScene();
    // 【回页自动恢复】设备页在 Index.ets 里仍是【条件渲染】（切走即销毁、切回是全新实例），
    // 所以这里所有 @State 都回到初始值（connected=false、connectedIp=''），若不处理就会
    // 一直显示"未连接"。而 MQTT 是 C++ 侧的常驻单例（切页不会断开），因此以单例为准恢复：
    //   1) 访问码从 AppStorage 取（单例状态不回传访问码，需自己持久化，供重建 RTSP URL）；
    //   2) resumeFromService()：单例仍 connected → 恢复 UI 状态 + 自动重启摄像头流。
    const saved: string | undefined = AppStorage.get<string>('deviceAccessCode');
    if (saved !== undefined) {
      this.accessCode = saved;
    }
    // 设备簿：记住的打印机（含访问码）—— 要 filesDir 才能读盘
    const ctx = this.getUIContext().getHostContext();
    deviceBook.load(ctx === undefined ? '' : ctx.filesDir);
    this.knownDevices = deviceBook.list();
    this.resumeFromService();
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    // 【离开优雅停止】只停摄像头流（省带宽/CPU，避免后台偷跑），**刻意不调用
    // MqttService.disconnect()**：MQTT 会话必须跨切页存活，回页时才能按单例状态自动恢复。
    // 这正是"切页中断"（单例仍连接）与"用户主动断开"（单例 connected=false）的区分依据。
    this.stopCamera();
    // 离开设备页（条件渲染 → 本组件被销毁）时把预览场景整份释放，绝不残留引擎资源
    this.destroyPreviewScene();
  }

  // 回到设备页时以单例服务（MqttService → C++ g_state）为准恢复 UI 与流。
  // 结果由 C++ 侧连接状态决定，而不是组件初始值，避免"底层还连着、界面却显示未连接"。
  private resumeFromService(): void {
    MqttService.getStatus().then((json: string) => {
      let st: PrinterState | null = null;
      try {
        st = JSON.parse(json) as PrinterState;
      } catch (e) {
        hilog.error(0x0000, DEV_TAG, '回页恢复解析状态失败: %{public}s',
          e instanceof Error ? e.message : JSON.stringify(e));
        return;
      }
      if (st === null) {
        return;
      }
      this.applyState(st);
      if (!st.connected) {
        hilog.info(0x0000, DEV_TAG, '回页恢复：单例未连接（用户主动断开/会话已死）→ 不自动拉流');
        this.tryAutoReconnect();
        return;
      }
      if (this.accessCode === '') {
        hilog.warn(0x0000, DEV_TAG, '回页恢复：单例已连接但缺访问码，无法重建 RTSP URL → 跳过拉流');
        return;
      }
      hilog.info(0x0000, DEV_TAG, '回页恢复：单例仍连接 → 自动重启摄像头流 ip=%{public}s', st.ip);
      this.startCamera(true);
    });
  }

  // ---------------------------------------------------------------------------
  // 零件预览：初始化第二个 Scene（与准备页同款相机/光照/材质/取景），并复用同一份网格数据
  // ---------------------------------------------------------------------------
  private async initPreviewScene(): Promise<void> {
    try {
      this.pvHasModel = modelState.hasModel();
      const scene: Scene = await Scene.load();
      this.pvScene = scene;
      const root: Node | null = scene.root;
      if (root === null) {
        this.pvText = '预览初始化失败：无根节点';
        return;
      }
      const factory: SceneResourceFactory = scene.getResourceFactory();
      this.pvFactory = factory;

      // 相机：与准备页同参数（fov / MSAA / 前向管线）。
      // 【暗角真因（官方答复 + 真机实测）】暗角是 ArkGraphics3D 引擎【默认使能】的后处理，
      // 与「引擎默认影棚背景」无关。上一轮「不设 postProcess」= 沿用引擎默认 → 暗角仍在；
      // 只写 `vignette: { intensity: 0 }` 也无效（真机实测四角仍压暗到中心的 0.77）。
      // 官方答复（华为开发者问答，2025-10-16）：当前版本要靠设置相机的 postProcess 属性来
      // 「关闭全部后处理（暗角等）」——把 postProcess 显式赋成【空对象 {}】即可；
      // 传 {vignette:{intensity:0}} 之类「带上 vignette 字段」的写法不能关掉它。
      // 只改设备页这份相机；准备页那份（0.12 暗角 + 泛光）保持原样。
      const cam: Camera | null = await factory.createCamera({ name: 'devicePvCam' });
      if (cam === null) {
        hilog.warn(0x0000, PV_TAG, 'createCamera 返回空 → 预览中止');
        this.pvText = '预览初始化失败：无法创建相机';
        return;
      }
      cam.fov = 0.72;
      cam.nearPlane = 5;
      cam.farPlane = 5000;
      // 不透明纯色清屏 = ArkUI 视口底 #1A1A22（26,26,34）。注意 clearColor 按【线性色】处理，
      // 要显示成 sRGB 的 #1A1A22 必须写它的线性值（≈0.0103 / 0.0103 / 0.016）。
      // 纯色不透明 → 四角与中心完全同色，从根上不存在「边缘压暗」，也不会过曝。
      cam.clearColor = { r: 0.0103, g: 0.0103, b: 0.016, a: 1 };
      cam.enabled = true;
      cam.msaa = true;
      cam.renderingPipeline = RenderingPipelineType.FORWARD;
      // 【关键】postProcess = {} → 关闭引擎全部后处理（暗角、泛光、色晕、色调映射），
      // 这是官方给出的「关掉默认暗角」的唯一写法；不加任何发光效果。
      cam.postProcess = {};
      hilog.info(0x0000, PV_TAG,
        '设备页相机后处理：postProcess={} 关闭全部后处理（含默认暗角）、清屏色为不透明纯色');
      cam.position = { x: 0, y: 0, z: 480 };
      cam.rotation = { x: 0, y: 0, z: 0, w: 1 };
      this.pvCamera = cam;
      root.children.append(cam);

      // 不绘制引擎默认背景（BACKGROUND_NONE）：背景完全由上面的不透明清屏色给出，
      // 既无贴图衰减、也不会把引擎默认影棚背景透出来。
      scene.environment.backgroundType = EnvironmentBackgroundType.BACKGROUND_NONE;
      // 【刻意不设 indirectDiffuseFactor】：环境光保持引擎默认的朴素值，
      // 避免任何「发光感」；照明只靠下面两盏方向光（直接光照），零件看得清即可。
      const sun: Light | null = await factory.createLight({ name: 'devSun' }, LightType.DIRECTIONAL);
      if (sun === null) {
        hilog.warn(0x0000, PV_TAG, 'createLight(sun) 返回空 → 跳过主光');
      } else {
        sun.intensity = 3.0;
        sun.shadowEnabled = false; // 与准备页一致：阴影保持关闭（不改既有阴影设置）
        sun.enabled = true;
        sun.rotation = dirToQuaternion(0.45, -0.85, 0.3);
        root.children.append(sun);
      }
      const fill: Light | null = await factory.createLight({ name: 'devFill' }, LightType.DIRECTIONAL);
      if (fill === null) {
        hilog.warn(0x0000, PV_TAG, 'createLight(fill) 返回空 → 跳过补光');
      } else {
        fill.intensity = 1.1;
        fill.shadowEnabled = false;
        fill.enabled = true;
        fill.rotation = dirToQuaternion(-0.6, -0.3, 0.5);
        root.children.append(fill);
      }

      // 共享默认模型材质（PBR 橙，与准备页 defaultModelRgb 同色；关闭背面剔除）
      const mmRaw: Material | null =
        await factory.createMaterial({ name: 'devModelMat' }, MaterialType.METALLIC_ROUGHNESS);
      if (mmRaw === null) {
        hilog.warn(0x0000, PV_TAG, 'createMaterial(devModelMat) 返回空 → 无兜底材质');
      } else {
        const mm: MetallicRoughnessMaterial = mmRaw as MetallicRoughnessMaterial;
        mm.baseColor.factor = { x: this.pvDefaultRgb.x, y: this.pvDefaultRgb.y, z: this.pvDefaultRgb.z, w: 1.0 };
        mm.cullMode = CullMode.NONE;
        this.pvModelMat = mm;
      }

      // 世界 / 枢轴节点：与准备页同一套「相机固定 (0,0,dist)，内容经 pivot 旋转 + world 平移」取景方式
      const world: Node | null = await factory.createNode({ name: 'devWorld' });
      if (world === null) {
        hilog.warn(0x0000, PV_TAG, 'createNode(world) 返回空 → 预览中止');
        this.pvText = '预览初始化失败：无法创建世界节点';
        return;
      }
      root.children.append(world);
      this.pvWorld = world;
      const pivot: Node | null = await factory.createNode({ name: 'devPivot' });
      if (pivot === null) {
        hilog.warn(0x0000, PV_TAG, 'createNode(pivot) 返回空 → 预览中止');
        this.pvText = '预览初始化失败：无法创建枢轴节点';
        return;
      }
      world.children.append(pivot);
      this.pvPivot = pivot;

      // 无模型：不建任何几何（空态由 UI 给出「尚未导入零件」提示，不显示假文本）
      if (this.pvHasModel) {
        // 注意：createMesh 是长同步 NAPI（大模型可达数秒）——这一步会在预览态文案下进行，
        // 完成后才置 pvReady=true 创建 Component3D，避免用户看到空黑视口。
        await this.pvSyncModels();
      }
      this.pvReady = true;
      this.pvText = '';
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, PV_TAG, '预览场景初始化失败: %{public}s', msg);
      this.pvText = `预览初始化失败：${msg}`;
    }
  }

  // 把准备页那份网格数据喂给本场景：逐个对象建材质 + 几何（同一条载入链路）
  private async pvSyncModels(): Promise<void> {
    if (this.pvFactory === null || this.pvPivot === null) {
      return;
    }
    for (const inst of modelState.instances) {
      const mat: Material | null = await this.pvEnsureMat(inst);
      const geo: Geometry | null = await this.pvAppendGeometry(inst, mat);
      if (geo !== null) {
        this.pvGeos.set(inst.id, geo);
      }
    }
    this.pvFitView();
  }

  // 取（必要时创建）某对象的专属材质，并按 displayColor 着色；失败退回共享默认材质
  private async pvEnsureMat(inst: ModelInstance): Promise<Material | null> {
    const cached: Material | undefined = this.pvMats.get(inst.id);
    if (cached !== undefined) {
      return cached;
    }
    if (this.pvFactory === null) {
      return this.pvModelMat;
    }
    const raw: Material | null =
      await this.pvFactory.createMaterial({ name: `devMat_${inst.id}` }, MaterialType.METALLIC_ROUGHNESS);
    if (raw === null) {
      hilog.warn(0x0000, PV_TAG, 'createMaterial(devMat_%{public}d) 返回空 → 用共享默认材质', inst.id);
      return this.pvModelMat;
    }
    const mat: MetallicRoughnessMaterial = raw as MetallicRoughnessMaterial;
    mat.cullMode = CullMode.NONE;
    const rgb: Vec3 = this.pvHexToVec3(inst.displayColor);
    mat.baseColor.factor = { x: rgb.x, y: rgb.y, z: rgb.z, w: 1.0 };
    this.pvMats.set(inst.id, mat);
    return mat;
  }

  // 建网格资源 + 几何节点（复用与准备页相同的 MeshGeometry → CustomGeometry → createMesh 链路）。
  // 网格数据【按引用】取自 modelState（同一份数据，JS 侧不复制）；创建一律判空。
  private async pvAppendGeometry(inst: ModelInstance, mat: Material | null): Promise<Geometry | null> {
    if (this.pvFactory === null || this.pvPivot === null) {
      return null;
    }
    const g: MeshGeometry = inst.geometry;
    const cg: CustomGeometry = new CustomGeometry();
    // 大网格（TypedArray）分块物化（每块让帧）；createMesh 之后立即释放物化出的对象数组
    if (g.pos !== null) {
      cg.vertices = await materializeVerticesChunked(g.pos);
      if (g.nrm !== null && g.nrm.length > 0) { cg.normals = await materializeVerticesChunked(g.nrm); }
      if (g.idx !== null && g.idx.length > 0) { cg.indices = await materializeIndicesChunked(g.idx); }
    } else {
      cg.vertices = g.vertices;
      if (g.normals.length > 0) { cg.normals = g.normals; }
      if (g.indices.length > 0) { cg.indices = g.indices; }
    }
    cg.topology = PrimitiveTopology.TRIANGLE_LIST;
    const meshRes: MeshResource | null = await this.pvFactory.createMesh({ name: `devMesh_${inst.id}` }, cg);
    if (g.pos !== null) { cg.vertices = []; cg.normals = undefined; cg.indices = undefined; }
    if (meshRes === null) {
      hilog.warn(0x0000, PV_TAG, 'createMesh(devMesh_%{public}d) 返回空 → 跳过该对象', inst.id);
      return null;
    }
    const geo: Geometry | null = await this.pvFactory.createGeometry({ name: `devGeo_${inst.id}` }, meshRes);
    if (geo === null) {
      hilog.warn(0x0000, PV_TAG, 'createGeometry(devGeo_%{public}d) 返回空 → 跳过该对象', inst.id);
      try { meshRes.destroy(); } catch (e) {
        hilog.warn(0x0000, PV_TAG, 'mesh 释放失败: %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      }
      return null;
    }
    if (mat !== null) {
      geo.mesh.materialOverride = mat;
    }
    // 与准备页一致的挂法：平移放容器节点（不随旋转翻转），旋转/缩放放网格节点
    const container: Node | null = await this.pvFactory.createNode({ name: `devContainer_${inst.id}` });
    if (container === null) {
      hilog.warn(0x0000, PV_TAG, 'createNode(devContainer_%{public}d) 返回空 → 跳过该对象', inst.id);
      try { geo.mesh.destroy(); } catch (e) {
        hilog.warn(0x0000, PV_TAG, 'mesh 释放失败: %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      }
      try { geo.destroy(); } catch (e) {
        hilog.warn(0x0000, PV_TAG, 'geometry 释放失败: %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      }
      return null;
    }
    container.position = inst.transform.position;
    this.pvPivot.children.append(container);
    container.children.append(geo);
    geo.rotation = this.pvComputeRotation(inst);
    const s: Vec3 = inst.transform.scale;
    geo.scale = { x: s.x, y: s.y, z: s.z };
    return geo;
  }

  // 取景：与准备页 resetView 同一算法（按模型最大尺寸定距、按内容中心把锚点挪到屏幕中心）
  private pvFitView(): void {
    if (this.pvCamera === null || this.pvWorld === null || this.pvPivot === null) {
      return;
    }
    let maxDim: number = 0;
    let cx: number = 0, cy: number = 0, cz: number = 0, n: number = 0;
    for (const inst of modelState.instances) {
      // 解析尺寸是 Z-up：本地 X=sizeX、本地 Y(高)=sizeZ、本地 Z=sizeY（与准备页 localSize 一致）
      const lx: number = inst.size.x;
      const ly: number = inst.size.z;
      const lz: number = inst.size.y;
      const s: Vec3 = inst.transform.scale;
      maxDim = Math.max(maxDim, Math.max(lx * s.x, Math.max(ly * s.y, lz * s.z)));
      const rc: Vec3 = rotateVecByQuat(this.pvComputeRotation(inst),
        { x: 0, y: ly * 0.5 * s.y, z: 0 });
      cx += inst.transform.position.x + rc.x;
      cy += inst.transform.position.y + rc.y;
      cz += inst.transform.position.z + rc.z;
      n++;
    }
    const target: Vec3 = n > 0 ? { x: cx / n, y: cy / n, z: cz / n } : { x: 0, y: 0, z: 0 };
    const R: Quaternion = eulerToQuaternion(this.pvPitch, this.pvYaw);
    this.pvCamera.position = { x: 0, y: 0, z: autoFitDistance(maxDim) };
    this.pvCamera.rotation = { x: 0, y: 0, z: 0, w: 1 };
    this.pvPivot.rotation = R;
    const rp: Vec3 = rotateVecByQuat(R, target);
    this.pvWorld.position = { x: -rp.x, y: -rp.y, z: -rp.z };
  }

  // 实例旋转 = 用户欧拉角 × 选面基准朝向（与准备页 computeRotation 完全一致）
  private pvComputeRotation(inst: ModelInstance): Quaternion {
    const t = inst.transform;
    const qx: Quaternion = this.pvAxisQuat('x', t.rotX);
    const qy: Quaternion = this.pvAxisQuat('z', t.rotY);
    const qz: Quaternion = this.pvAxisQuat('y', t.rotZ);
    const user: Quaternion = multiplyQuaternion(multiplyQuaternion(qx, qy), qz);
    return multiplyQuaternion(user, t.baseRotation);
  }

  private pvAxisQuat(key: string, deg: number): Quaternion {
    const h: number = deg * Math.PI / 360;
    const s: number = Math.sin(h);
    const w: number = Math.cos(h);
    if (key === 'x') { return { x: s, y: 0, z: 0, w: w }; }
    if (key === 'y') { return { x: 0, y: s, z: 0, w: w }; }
    return { x: 0, y: 0, z: s, w: w };
  }

  // hex（如 '#D8322B'）→ 归一化 RGB；空串/非法一律退回默认色（不抛异常）
  private pvHexToVec3(hex: string): Vec3 {
    if (hex === '') {
      return this.pvDefaultRgb;
    }
    const h: string = hex.startsWith('#') ? hex.substring(1) : hex;
    if (h.length !== 6) {
      hilog.warn(0x0000, PV_TAG, '非法的显示色 %{public}s → 退回默认色', hex);
      return this.pvDefaultRgb;
    }
    const r: number = parseInt(h.substring(0, 2), 16);
    const gg: number = parseInt(h.substring(2, 4), 16);
    const b: number = parseInt(h.substring(4, 6), 16);
    if (isNaN(r) || isNaN(gg) || isNaN(b)) {
      hilog.warn(0x0000, PV_TAG, '显示色解析失败 %{public}s → 退回默认色', hex);
      return this.pvDefaultRgb;
    }
    return { x: r / 255, y: gg / 255, z: b / 255 };
  }

  // 与准备页同一套「回前台重贴材质」：前后台切换/失焦会重建渲染表面，materialOverride 随之丢失
  // （几何回落到引擎默认灰）。这里把每个几何的材质重贴一遍，颜色与准备页一致。
  private onPvRenderResume(propName: string): void {
    try {
      if (this.pvScene === null) {
        return;
      }
      let n: number = 0;
      this.pvGeos.forEach((geo: Geometry, id: number): void => {
        const own: Material | undefined = this.pvMats.get(id);
        const use: Material | null = own !== undefined ? own : this.pvModelMat;
        if (use !== null) {
          geo.mesh.materialOverride = use;
          n++;
        }
      });
      hilog.info(0x0000, PV_TAG, '回前台重贴材质：几何=%{public}d', n);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, PV_TAG, '重贴材质异常: %{public}s', msg);
    }
  }

  // 释放整个预览场景（destroy 会一并回收相机/光照/材质/网格等场景资源）
  private destroyPreviewScene(): void {
    if (this.pvScene !== null) {
      try {
        this.pvScene.destroy();
      } catch (e) {
        hilog.warn(0x0000, PV_TAG, '预览场景释放失败: %{public}s',
          e instanceof Error ? e.message : JSON.stringify(e));
      }
      this.pvScene = null;
    }
    this.pvFactory = null;
    this.pvCamera = null;
    this.pvWorld = null;
    this.pvPivot = null;
    this.pvModelMat = null;
    this.pvGeos.clear();
    this.pvMats.clear();
    this.pvReady = false;
  }

  // 启动摄像头拉流（连接后调用；silent=true 用于回页自动恢复，避免每次切页都弹 Toast）
  private startCamera(silent: boolean): void {
    if (this.connectedIp === '') {
      return;
    }
    // 缺访问码无法拼出 RTSP URL（回页恢复的极少数兜底）→ 不启动，仅打日志
    if (this.accessCode === '') {
      hilog.warn(0x0000, DEV_TAG, 'startCamera 跳过：访问码为空');
      return;
    }
    // 端口选择交给原生侧：X1/X1C/X1E/H2D/P2S/X2D → 322(RTSPS/H.264)；
    // A1/A1 mini/P1P/P1S/A2L → 6000(TCP+TLS chamber image/JPEG)；机型未知则 322→6000 回退。
    // 机型优先用 SSDP 友好名（connectedModel），缺失时原生侧用序列号前缀兜底。
    // cameraForceProto 供测试注入（0 自动 / 1 强制 322 / 2 强制 6000）。
    const protoHint: string = MqttService.cameraResolveProtocol(this.connectedModel, this.connectedSerial);
    hilog.info(0x0000, DEV_TAG, 'startCamera 机型=%{public}s SN=%{public}s 端口候选=%{public}s force=%{public}d',
      this.connectedModel === '' ? '(未知)' : this.connectedModel, this.connectedSerial, protoHint, this.cameraForceProto);
    try {
      const ok: boolean = MqttService.cameraStart(
        this.connectedIp, this.accessCode, this.connectedModel, this.connectedSerial, this.cameraForceProto);
      hilog.info(0x0000, DEV_TAG, 'startCamera 结果=%{public}s silent=%{public}s', `${ok}`, `${silent}`);
      // 记录本次取流使用的序列号：用于"学到 SN 后用机型/SN 重启取流"的判定
      this.cameraSerial = this.connectedSerial;
      if (!silent) {
        promptAction.showToast({ message: ok ? '摄像头启动中' : '摄像头启动失败' });
      }
      if (ok && this.cameraTimer < 0) {
        this.lastFrameTime = Date.now();
        // 66ms 轮询 → 上限 15fps。无新帧时 NAPI 仅做一次锁内比较即返回 null，开销极小
        this.cameraTimer = setInterval(() => {
          this.pollCameraFrame();
        }, 66);
      }
    } catch (e) {
      hilog.error(0x0000, DEV_TAG, 'startCamera 异常: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      if (!silent) {
        promptAction.showToast({ message: '摄像头异常' });
      }
    }
  }

  private stopCamera(): void {
    if (this.cameraTimer >= 0) {
      clearInterval(this.cameraTimer);
      this.cameraTimer = -1;
    }
    MqttService.cameraStop();
    hilog.info(0x0000, DEV_TAG, 'stopCamera：已停流并释放 PixelMap');
    const old: image.PixelMap | undefined = this.cameraPixelMap;
    this.cameraPixelMap = undefined;
    if (old) {
      old.release().catch(() => {});
    }
  }

  private pollCameraFrame(): void {
    const frame: CameraFrameData | null = MqttService.cameraGetFrame();
    if (frame && frame.seq !== this.lastFrameSeq) {
      const isJpeg: boolean = frame.format === 'jpeg';
      // RGBA 帧需已知宽高；JPEG 帧尺寸由 image 模块自行解析（C++ 仅尽力解析，宽高可能为 0）
      if (isJpeg || (frame.width > 0 && frame.height > 0)) {
        this.lastFrameSeq = frame.seq;
        this.lastFrameTime = Date.now();
        if (!this.pmPending) {
          this.pmPending = true;
          if (isJpeg) {
            this.decodeJpegFrame(frame.data);
          } else {
            this.decodeRgbaFrame(frame.data, frame.width, frame.height);
          }
        }
      }
    }
    // 断流看门狗：12 秒无新帧 → 自动重启拉流（C++ 侧 10 秒卡流会自动退出，这里负责重连）
    if (this.cameraTimer >= 0 && Date.now() - this.lastFrameTime > 12000) {
      this.lastFrameTime = Date.now();
      promptAction.showToast({ message: '监控中断，自动重连' });
      this.stopCamera();
      this.startCamera(false);
    }
  }

  // 换帧：先挂新 PixelMap 再释放旧的（不释放会持续泄漏原生内存 → 卡死）
  private swapCameraPixelMap(pm: image.PixelMap): void {
    this.pmPending = false;
    // 创建期间摄像头已停止 → 丢弃该帧，避免停止后又挂上新 PixelMap
    if (this.cameraTimer < 0) {
      pm.release().catch(() => {});
      return;
    }
    const old: image.PixelMap | undefined = this.cameraPixelMap;
    this.cameraPixelMap = pm;
    if (old) {
      old.release().catch(() => {});
    }
  }

  // RGBA 帧：直接用系统 PixelMap（既有链路，保持数组缓冲复用优化不变）
  private decodeRgbaFrame(buf: ArrayBuffer, w: number, h: number): void {
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false,
    };
    image.createPixelMap(buf, opts).then((pm: image.PixelMap) => {
      this.swapCameraPixelMap(pm);
    }).catch(() => {
      this.pmPending = false;
    });
  }

  // JPEG 帧（6000 通道）：C++ 交付完整 JPEG，这里用系统 @ohos.multimedia.image 解码（不依赖 FFmpeg mjpeg）。
  // 注意：createImageSource 会持有缓冲并在后续异步解码，而 NAPI 侧是"同一 ArrayBuffer 反复覆盖"，
  // 故先 slice 出一份独立副本再交给解码器（JPEG 仅百 KB 级，拷贝开销远小于 RGBA 帧）。
  private decodeJpegFrame(buf: ArrayBuffer): void {
    const jpegBuf: ArrayBuffer = buf.slice(0);
    const src: image.ImageSource = image.createImageSource(jpegBuf);
    src.createPixelMap().then((pm: image.PixelMap) => {
      src.release().catch(() => {});
      this.swapCameraPixelMap(pm);
    }).catch((e: Error) => {
      src.release().catch(() => {});
      this.pmPending = false;
      hilog.warn(0x0000, DEV_TAG, 'JPEG 解码失败: %{public}s', e.message);
    });
  }

  private pollState(): void {
    MqttService.getStatus().then((json: string) => {
      try {
        const st = JSON.parse(json) as PrinterState;
        this.applyState(st);
      } catch (e) {
        // 不吞异常：解析失败按告警记录，UI 保持当前值
        hilog.warn(0x0000, DEV_TAG, 'pollState 解析失败: %{public}s',
          e instanceof Error ? e.message : JSON.stringify(e));
      }
    });
  }

  // 把「单例（MqttService → C++ g_state）的设备状态」同步到 UI 字段。
  // 抽出来是为了让轮询（pollState）与回页恢复（resumeFromService）共用同一套同步逻辑，
  // 保证回页时 UI 状态一定来自服务端的真实状态，而不是组件的初始值。
  private applyState(st: PrinterState): void {
    this.connected = st.connected;
    if (!st.connected) {
      return;
    }
    // 状态推送计数：0 = 已连接但未收到任何状态数据（UI 会明确标注，日志同时记录）
    const prevCount: number = this.statusCount;
    this.statusCount = st.pushStatusCount !== undefined ? st.pushStatusCount : 0;
    if (this.statusCount !== prevCount) {
      hilog.info(0x0000, DEV_TAG, '收到状态(push_status)=%{public}d 条 serial=%{public}s',
        this.statusCount, st.serial === '' ? '(空)' : st.serial);
    }
    this.connectedSerial = st.serial;
    // 手动连接时序列号是连上后从 report 里学到的 → 学到后补记进设备簿。
    // 只在"簿里还没有这台"时写（否则每 2 秒轮询都会落盘一次）。
    if (this.connectedSerial !== '' && this.bookCode(this.connectedSerial) === ''
        && this.connectedIp.length > 0 && this.accessCode.length > 0) {
      deviceBook.remember(this.connectedIp, this.connectedSerial, this.connectedModel, this.accessCode);
      this.knownDevices = deviceBook.list();
    }
    // 回页恢复的关键：组件重建后 connectedIp 会丢（初始 ''），必须从单例状态补回来，
    // 否则 startCamera() 的「无 IP」守卫会直接返回 → 画面永远停在"未连接"。
    this.connectedIp = st.ip;
    // 机型：回页后 connectedModel 也会丢；若本次会话已发现过该 SN 则补回，否则留空（原生按 SN 前缀兜底）
    if (this.connectedModel === '') {
      this.connectedModel = this.modelOfSerial(st.serial);
    }
    // 把已连接机型（SSDP 友好名）供打印弹窗做「机型不匹配」对照（空则弹窗不提示）
    AppStorage.setOrCreate<string>('connectedDeviceModel', this.connectedModel);
    // 机型/序列号传入摄像头模块：连上初期 SN 可能还没学到（model/serial 为空，端口只能靠试）。
    // 一旦学到 SN，且摄像头正在运行但启动时无 SN → 用已知机型/SN 静默重启取流，让端口选择有依据。
    if (this.connectedSerial !== '' && this.cameraSerial === '' && this.cameraTimer >= 0) {
      hilog.info(0x0000, DEV_TAG, '学到 SN=%{public}s → 用机型/SN 重启摄像头取流', this.connectedSerial);
      this.stopCamera();
      this.startCamera(true);
    }
    this.nozzleTemp = st.nozzleTemp;
    this.bedTemp = st.bedTemp;
    this.chamberTemp = st.chamberTemp;
    // 已知标记：未知（未收到该字段）时 UI 显示 "--"，不显示 0（A1/P1 增量上报可能整帧不带某温度）
    this.nozzleTempKnown = st.nozzleTempKnown === true;
    this.bedTempKnown = st.bedTempKnown === true;
    this.chamberTempKnown = st.chamberTempKnown === true;
    // 乐观更新：正在编辑或命令刚下发 3 秒内不覆盖目标温度，避免闪烁
    if (this.editingKind !== 0 && Date.now() - this.nozzleCmdTime >= 3000) {
      this.nozzleTargetTemp = st.nozzleTargetTemp;
    }
    if (this.editingKind !== 1 && Date.now() - this.bedCmdTime >= 3000) {
      this.bedTargetTemp = st.bedTargetTemp;
    }
    if (this.editingKind !== 2 && Date.now() - this.chamberCmdTime >= 3000) {
      this.chamberTargetTemp = st.chamberTargetTemp;
    }
    this.hasChamberHeater = st.hasChamberHeater;
    // 风扇：四舍五入到 10% 挡位，且命令刚下发 3 秒内不覆盖
    if (Date.now() - this.partFanCmdTime >= 3000) {
      this.partFan = Math.round(st.partFan / 10) * 10;
    }
    if (Date.now() - this.auxFanCmdTime >= 3000) {
      this.auxFan = Math.round(st.auxFan / 10) * 10;
    }
    if (Date.now() - this.chamberFanCmdTime >= 3000) {
      this.chamberFan = Math.round(st.chamberFan / 10) * 10;
    }
    this.layer = st.layer;
    this.totalLayers = st.totalLayers;
    this.progress = st.progress;
    this.state = this.stateText(st.state);
    this.amsUnits = st.ams;
    this.npEnabled = st.npEnabled;
    // 剩余时间（此前解析了但界面没用，功能 11）
    this.remainingMinutes = st.remainingMinutes !== undefined ? st.remainingMinutes : 0;
    // 表驱动扩展字段 + HMS 故障（功能 10 / 12）
    this.extRows = this.buildExtRows(st.ext);
    this.hmsHits = this.mapHms(st.hms);
    this.printErrHit = this.lookupPrintError(st.ext);
    this.xcamRows = this.buildXcamRows(st.xcam);
    // 打印暂停告警：跨页模态（由 Index 渲染，见 publishPauseAlert）
    this.publishPauseAlert(st.state === 'PAUSE');
  }

  // ---- 「打印已暂停」全局告警的发布 ----
  // 背景：机器侧的 AI/传感器提醒（打印板类型不匹配、炒面、首层缺陷、热床异物、门未关…）
  // 在协议里**全都是 HMS 码**，机器会自己暂停打印。此前 app 只在设备页显示一行小字，
  // 用户在「准备」页打印时根本看不到 —— 所以这里把「暂停 + 有 HMS」合成一条全局告警。
  // 为什么放在 AppStorage：Index（模态框）与 DevicePanel（数据源）是两个组件，且页面切页会重建，
  // AppStorage 是同一运行时内唯一能跨组件观察的通道（与 docRecents / historyCanUndo 同一套路）。
  // 「同一批故障只弹一次」：用户点「稍后处理」后把签名写进 pauseAckSig，签名变了才再弹；
  // 打印恢复（状态离开 PAUSE）时清掉签名，下一次同类故障还要弹。
  private publishPauseAlert(paused: boolean): void {
    if (!paused || this.hmsHits.length === 0) {
      if (this.pauseShown) {
        AppStorage.setOrCreate<HmsHit[]>('pauseHits', []);
        this.pauseShown = false;
      }
      if (!paused) {
        AppStorage.setOrCreate<string>('pauseAckSig', '');
      }
      return;
    }
    const parts: string[] = [];
    for (const h of this.hmsHits) {
      parts.push(h.ecode);
    }
    parts.sort();     // 设备上报顺序可能抖动，排序后再当签名
    const sig: string = parts.join(',');
    if (sig === this.pauseSig) {
      return;         // 同一批故障：已弹过（或已被「稍后处理」），不重复弹
    }
    const ack: string = AppStorage.get<string>('pauseAckSig') ?? '';
    if (sig === ack) {
      return;
    }
    AppStorage.setOrCreate<HmsHit[]>('pauseHits', this.hmsHits);
    this.pauseSig = sig;
    this.pauseShown = true;
    hilog.info(0x0000, DEV_TAG, '打印暂停告警已发布 故障=%{public}s', sig);
  }

  // 「显示名 → 显示值」按固定优先级排列：设备每帧上报的字段集合可能不同，
  // 若照 Object.keys 的顺序渲染，界面会随上报抖动 → 定死顺序，未知键排在后面。
  private buildExtRows(ext: Record<string, string>): ExtRow[] {
    const rows: ExtRow[] = [];
    if (ext === undefined) {
      return rows;
    }
    const known: string[] = ['任务名', '文件', '任务类型', '固件', '信号', '阶段', '子阶段',
      '阶段(旧)', '子阶段(旧)', '速度档', '速度', '错误码', '喷嘴', 'SD 卡', '回零', '升级状态'];
    const keys: string[] = Object.keys(ext);
    const order: string[] = [];
    for (const k of known) {
      if (keys.indexOf(k) >= 0) {
        order.push(k);
      }
    }
    for (const k of keys) {
      if (order.indexOf(k) < 0) {
        order.push(k);
      }
    }
    for (const k of order) {
      const v: string = ext[k] ?? '';
      if (v.length === 0) {
        continue;
      }
      const r: ExtRow = new ExtRow();
      r.k = k;
      r.v = v;
      rows.push(r);
    }
    return rows;
  }

  // 机器侧 AI 检测开关（print.xcam）：键名用协议里同源的名字，**未知键原样显示键名** ——
  // 固件加了新检测项时也能显示出来（不认识的字段不该被藏掉）。
  private xcamLabel(k: string): string {
    if (k === 'buildplate_marker_detector') { return '打印板检测'; }
    if (k === 'spaghetti_detector') { return '炒面检测'; }
    if (k === 'first_layer_inspector') { return '首层检测'; }
    if (k === 'printing_monitor') { return '打印监控'; }
    if (k === 'allow_skip_parts') { return '允许跳件'; }
    if (k === 'halt_print_sensitivity') { return '停机灵敏度'; }
    return k;
  }

  // 值 → 可读文本；对象/数组返回空串（不是"开关"，调用方据此跳过）
  private xcamValue(k: string, v: Object): string {
    if (typeof v === 'boolean') {
      return (v as boolean) ? '开' : '关';
    }
    if (typeof v === 'string') {
      const s: string = v as string;
      if (s === 'low') { return '低'; }
      if (s === 'medium') { return '中'; }
      if (s === 'high') { return '高'; }
      return s;
    }
    if (typeof v === 'number') {
      return `${v as number}`;
    }
    return '';
  }

  private buildXcamRows(x: Record<string, Object>): ExtRow[] {
    const rows: ExtRow[] = [];
    if (x === undefined) {
      return rows;
    }
    // 固定顺序（已知键在前），未知键排后面 —— 与「状态详情」同一原则：界面不随上报抖动
    const order: string[] = ['buildplate_marker_detector', 'spaghetti_detector',
      'first_layer_inspector', 'printing_monitor', 'allow_skip_parts', 'halt_print_sensitivity'];
    const keys: string[] = Object.keys(x);
    const ordered: string[] = [];
    for (const k of order) {
      if (keys.indexOf(k) >= 0) {
        ordered.push(k);
      }
    }
    for (const k of keys) {
      if (ordered.indexOf(k) < 0) {
        ordered.push(k);
      }
    }
    for (const k of ordered) {
      const v: string = this.xcamValue(k, x[k]);
      if (v.length === 0) {
        continue;
      }
      const r: ExtRow = new ExtRow();
      r.k = this.xcamLabel(k);
      r.v = v;
      rows.push(r);
    }
    return rows;
  }

  // HMS 数组 → 查表结果（去重：设备偶尔会重复上报同一条）
  private mapHms(list: HmsItem[]): HmsHit[] {
    const out: HmsHit[] = [];
    if (list === undefined || list.length === 0) {
      return out;
    }
    const seen: string[] = [];
    for (const it of list) {
      const hit: HmsHit = hmsTable.lookup(it.attr, it.code);
      if (hit.ecode.length === 0 || seen.indexOf(hit.ecode) >= 0) {
        continue;
      }
      seen.push(hit.ecode);
      out.push(hit);
    }
    return out;
  }

  // print_error（单码故障）→ device_error 码表；0/无此字段 → undefined（不显示错误条）
  private lookupPrintError(ext: Record<string, string>): HmsHit | undefined {
    if (ext === undefined) {
      return undefined;
    }
    const raw: string = ext['错误码'] ?? '';
    if (raw.length === 0) {
      return undefined;
    }
    const n: number = parseInt(raw, 10);
    if (isNaN(n) || n === 0) {
      return undefined;
    }
    const hit: HmsHit = hmsTable.lookupPrintError(n);
    return hit.ecode.length > 0 ? hit : undefined;
  }

  // HMS 等级配色：code 高 16 位（1/2/3，越小越严重）。
  // 刻意不给等级编中文名（"严重/重要/一般"未与官方文案核对过），只用颜色区分轻重。
  private hmsColor(level: number): string {
    if (level <= 1) { return '#FF3D2E'; }
    if (level === 2) { return '#FF9F1A'; }
    return '#FFD23F';
  }

  // 剩余时间展示：分钟 → 「1h20m」/「45m」；未知（0）显示 "--"
  //（不显示 0 —— 那会和"真的只剩 0 分钟"混淆；A1 mini 上曾出现过设备报 0M0s 的情况）
  private remainingText(): string {
    const m: number = this.remainingMinutes;
    if (m <= 0) {
      return '--';
    }
    if (m < 60) {
      return `${m}m`;
    }
    const h: number = Math.floor(m / 60);
    const r: number = m % 60;
    return r === 0 ? `${h}h` : `${h}h${r}m`;
  }

  private stateText(s: string): string {
    if (s === 'RUNNING') { return '打印中'; }
    if (s === 'PAUSE') { return '已暂停'; }
    if (s === 'FINISH') { return '完成'; }
    if (s === 'FAILED') { return '失败'; }
    if (s === 'IDLE') { return '待机'; }
    return s;
  }

  // 温度显示统一保留 1 位小数（数据层精度不变，仅展示层四舍五入）。
  private fmt1(n: number): string {
    return n.toFixed(1);
  }

  // 机型识别串（判据的单一入口）：优先「实际连接的机型」——最终是打印机自己认这个能力表，
  // 所以 SSDP 友好名最可信；取不到再退回切片预设名（可能与整机不符，但好过没有）。
  private modelHint(): string {
    if (this.connectedModel !== '') { return this.connectedModel; }
    return AppStorage.get<string>('platePrinter') ?? '';
  }

  // 机型能力矩阵查询（源自桌面版同源的机型能力表，见 PrinterMatrix.ets）。
  // 识别不出机型时 capsOf() 返回 FALLBACK_CAPS（X1 Carbon），此时下面的判定会退回子串启发式。
  private caps(): PrinterCaps {
    return capsOf(this.modelHint());
  }

  // 是否有**主动腔体**（可加热的腔体）：机型能力矩阵 support_chamber 为准
  //（A1 / A1 mini / A2L / P1P = false，X1/X1C/X1E/P1S/H2D/P2S… = true）。
  // 用途：无主动腔体的机型上报的「腔温」只是环境读数，显示灰色 "--" 且不给编辑目标温度。
  // 判据来源从「名字里含 A1」升级为机型能力表 —— 桌面版就是用这张表决定腔体 UI 的，
  // 而字符串启发式会漏判（例如 P1P 声明 support_chamber=false 却因不含 "A1" 而被当成有腔体）。
  private hasActiveChamber(): boolean {
    if (matchModelId(this.modelHint()) !== '') {
      return this.caps().supportChamber;
    }
    return !this.isA1Series();
  }

  // 是否 A1 系列（A1 / A1 mini）：该机型无主动腔体（不报 chamber_target_temper），
  // 上报的腔体读数只是环境值 → 不显示腔体温度（显示灰色 "--"）。
  // 现在只作为「机型识别失败时」的兜底判据（矩阵命中时以矩阵为准，见 hasActiveChamber）。
  private isA1Series(): boolean {
    const m: string = this.connectedModel.toUpperCase();
    if (m.indexOf('A1') >= 0) { return true; }
    const preset: string = (AppStorage.get<string>('platePrinter') ?? '').toUpperCase();
    return preset.indexOf('A1') >= 0;
  }

  private discover(): void {
    this.discovering = true;
    MqttService.discover().then((json: string) => {
      this.discovering = false;
      this.discovered = true;
      try {
        this.printers = JSON.parse(json) as DiscoveredPrinter[];
      } catch (e) {
        this.printers = [];
      }
    });
  }

  // 从最近一次 SSDP 发现结果里按序列号查机型（友好名）；找不到返回 ''（交原生按 SN 前缀兜底）
  private modelOfSerial(serial: string): string {
    for (const p of this.printers) {
      if (p.serial === serial) {
        return p.model;
      }
    }
    return '';
  }

  // 进设备页（或回页）时若单例没连接，就尝试连「上次用过的打印机」——只试一次。
  // 为什么自动连：访问码已存在设备簿里，用户不该每次手点；
  // 为什么只试一次：打印机不在线时会话建立失败，反复重试只会刷日志、白耗电。
  private tryAutoReconnect(): void {
    if (this.autoReconnectTried || this.connected || this.connecting) {
      return;
    }
    this.autoReconnectTried = true;
    const d: KnownDevice | null = deviceBook.last();
    if (d === null || d.accessCode.length === 0) {
      return;
    }
    hilog.info(0x0000, DEV_TAG, '自动重连上次设备 %{public}s（%{public}s）', d.serial, d.ip);
    this.connect(d.ip, d.serial, d.accessCode, true);
  }

  // 设备簿里这台机器的访问码（有 → 一键直连，不再弹输入框）
  private bookCode(serial: string): string {
    for (const d of this.knownDevices) {
      if (d.serial === serial) {
        return d.accessCode;
      }
    }
    return '';
  }

  // 副标题：名字本身已经是 serial 时不再重复它（手动连接的机器没有 SSDP 机型名，否则一行里出现两遍）
  private bookSubText(d: KnownDevice): string {
    return deviceBook.displayName(d) === d.serial ? d.ip : `${d.serial} · ${d.ip}`;
  }

  // 最后连接时间（人话；不刷新，够用）
  private bookTimeText(ms: number): string {
    if (ms <= 0) {
      return '尚未连接';
    }
    const diff: number = Date.now() - ms;
    if (diff < 60 * 1000) {
      return '刚刚连接过';
    }
    if (diff < 3600 * 1000) {
      return `最后连接 ${Math.floor(diff / 60000)} 分钟前`;
    }
    if (diff < 24 * 3600 * 1000) {
      return `最后连接 ${Math.floor(diff / 3600000)} 小时前`;
    }
    return `最后连接 ${Math.floor(diff / 86400000)} 天前`;
  }

  // 连接（code 省略 = 用当前输入框里的访问码；silent = 自动重连，不弹提示只记日志）
  private connect(ip: string, serial: string, code: string = '', silent: boolean = false): void {
    this.accessCode = code.length > 0 ? code : this.accessCode;
    this.connecting = true;
    this.connectingSerial = serial;
    MqttService.connect(ip, this.accessCode, serial).then((json: string) => {
      this.connecting = false;
      this.connectingSerial = '';
      const ok: boolean = json.indexOf('"ok":true') >= 0;
      if (ok) {
        this.connected = true;
        this.connectedSerial = serial;
        this.connectedIp = ip;
        // 记录机型（来自 SSDP 发现结果），用于选择摄像头端口；找不到则留空走序列号兜底
        this.connectedModel = this.modelOfSerial(serial);
        // 供打印弹窗做「机型不匹配」对照（SSDP 友好名；空则弹窗不提示）
        AppStorage.setOrCreate<string>('connectedDeviceModel', this.connectedModel);
        // 持久化访问码：单例状态不回传访问码，回页重建取流参数时必须能拿到
        AppStorage.setOrCreate<string>('deviceAccessCode', this.accessCode);
        // 记住这台（ip/机型/访问码/时间）→ 下次进来一键直连，不用再扫再填
        deviceBook.remember(ip, serial, this.connectedModel, this.accessCode);
        this.knownDevices = deviceBook.list();
        this.startCamera(false);
        if (!silent) {
          promptAction.showToast({ message: '连接成功' });
        }
      } else {
        // 把笼统的「连接失败」换成原生侧给出的具体可行动原因
        //（如 TCP 不可达 / TLS 握手失败 / 访问码错误 / 订阅被拒）；原始错误码仍在 MqttConn 日志里。
        let reason: string = '连接失败';
        try {
          const res: MqttConnectResult = JSON.parse(json) as MqttConnectResult;
          if (res.message !== undefined && res.message !== '') {
            reason = res.message;
          }
        } catch (e) {
          // 解析失败 → 保底文案
        }
        if (silent) {
          // 自动重连失败不该弹框打扰（用户可能只是暂时没开打印机）→ 只记日志
          hilog.info(0x0000, DEV_TAG, '自动重连失败: %{public}s', reason);
        } else {
          promptAction.showToast({ message: reason, duration: 6000 });
        }
      }
      // 三通道日志：把本次连接的 MqttConn 逐步诊断追加写进 files/diag/gcode_diag.txt
      this.dumpMqttDiag();
      this.pollState();
    });
  }

  // 把原生 MQTT 日志（含 MqttConn 连接诊断）追加落盘到 files/diag/gcode_diag.txt
  private dumpMqttDiag(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) { return; }
      MqttService.flushLogsToDiag(`${ctx.filesDir}/diag/gcode_diag.txt`);
    } catch (e) {
      // 忽略：诊断落盘失败不影响主流程
    }
  }

  // 用户在设备页主动断开：结束 MQTT 会话 + 停流 + 清掉持久化访问码。
  // 这样回到本页时 resumeFromService() 读到单例 connected=false → 不自动重连，
  // 从而把"用户主动断开"与"切页导致的中断（单例仍 connected）"区分开。
  private manualDisconnect(): void {
    MqttService.disconnect();
    this.stopCamera();
    this.connected = false;
    this.connectedSerial = '';
    this.connectedIp = '';
    this.connectedModel = '';
    this.cameraSerial = '';
    this.statusCount = 0;
    this.accessCode = '';
    AppStorage.setOrCreate<string>('deviceAccessCode', '');
    AppStorage.setOrCreate<string>('connectedDeviceModel', '');
    hilog.info(0x0000, DEV_TAG, '用户主动断开：已结束 MQTT 会话并停流，回页不再自动重连');
    promptAction.showToast({ message: '已断开连接' });
  }

  private showDialog(ip: string, serial: string): void {
    this.pendingIp = ip;
    this.pendingSerial = serial;
    this.accessCode = '';
    this.showAccessDialog = true;
  }

  private confirmConnect(): void {
    this.showAccessDialog = false;
    this.connect(this.pendingIp, this.pendingSerial, this.accessCode);
  }

  // 手动连接：只给 IP + 访问码，序列号由原生层从 report topic 学出（跳过局域网发现）
  private manualConnect(): void {
    const ip: string = this.manualIp.trim();
    const code: string = this.manualCode.trim();
    if (ip === '') {
      promptAction.showToast({ message: '请输入打印机 IP' });
      return;
    }
    if (code === '') {
      promptAction.showToast({ message: '请输入访问码' });
      return;
    }
    this.accessCode = code;
    this.pendingIp = ip;
    this.pendingSerial = '';
    this.showManualDialog = false;
    this.connect(ip, '');
  }

  // ---- 打印机文件：浏览 / 下载 / 删除（FTPS）----
  private openFiles(): void {
    this.showFilesDialog = true;
    this.fileDir = '/cache';
    this.fileItems = [];
    this.loadFiles();
  }

  private loadFiles(): void {
    if (this.filesLoading) {
      return;
    }
    this.filesLoading = true;
    this.filesMsg = '';
    PrinterFiles.list(this.fileDir).then((r): void => {
      this.filesLoading = false;
      this.fileItems = r.ok ? r.files : [];
      if (!r.ok) {
        this.filesMsg = `读取失败：${r.message}`;
      } else if (r.files.length === 0) {
        this.filesMsg = '这个目录是空的';
      }
    }).catch((e: Object): void => {
      this.filesLoading = false;
      this.filesMsg = `读取异常：${e instanceof Error ? e.message : JSON.stringify(e)}`;
    });
  }

  private switchFileDir(dir: string): void {
    if (this.fileDir === dir || this.filesLoading) {
      return;
    }
    this.fileDir = dir;
    this.fileItems = [];
    this.loadFiles();
  }

  // 删除前二次确认：删的是打印机存储里的真文件，不可恢复
  private removeRemoteFile(f: RemoteFile): void {
    if (this.fileBusy !== '' || f.isDir) {
      return;
    }
    promptAction.showDialog({
      title: '删除打印机上的文件',
      message: `${f.name}\n\n删除后不可恢复（文件在打印机存储里）。`,
      buttons: [
        { text: '取消', color: '#9AA4B2' },
        { text: '删除', color: '#FF3D2E' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse): void => {
      if (res.index !== 1) {
        return;
      }
      this.fileBusy = f.name;
      PrinterFiles.remove(f.path).then((r): void => {
        this.fileBusy = '';
        promptAction.showToast({ message: r.ok ? `已删除 ${f.name}` : `删除失败：${r.message}` });
        if (r.ok) {
          this.loadFiles();
        }
      });
    }).catch((e: Object): void => {
      // 弹窗被外部关掉 = 取消（不删）
      hilog.info(0x0000, DEV_TAG, '删除确认弹窗未确认（按取消处理）');
    });
  }

  private downloadRemoteFile(f: RemoteFile): void {
    if (this.fileBusy !== '' || f.isDir) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    const filesDir: string = ctx === undefined ? '' : ctx.filesDir;
    this.fileBusy = f.name;
    promptAction.showToast({ message: `开始下载 ${f.name}…` });
    PrinterFiles.download(filesDir, f.path, f.name).then((r): void => {
      this.fileBusy = '';
      if (!r.ok) {
        promptAction.showToast({ message: `下载失败：${r.message}`, duration: 6000 });
        return;
      }
      // 下载成功 → 让用户选落点（默认就是系统的下载目录）
      this.saveDownloadedToUser(r.localPath, f.name);
    });
  }

  // 把刚下载到沙箱的文件另存到用户选择的位置（系统「另存为」，默认落在下载目录）。
  // 为什么先落沙箱再复制：原生 RETR 只会按**路径**写文件，选择器给的是 URI（只能拿到 fd），
  // 原生侧不认；fd→fd 复制（ThreeMfExport.copyFile）已经在上传/导出链路验证过。
  // 用户取消/选择器不可用时不丢文件：明确告诉他沙箱里那份在哪。
  private saveDownloadedToUser(srcPath: string, name: string): void {
    const fallback = (why: string): void => {
      promptAction.showToast({
        message: `${why}；文件已存到应用沙箱：${srcPath}`,
        duration: 6000
      });
      hilog.info(0x0000, DEV_TAG, '下载落点回退沙箱: %{public}s', srcPath);
    };
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [name];
      docPicker.save(opts).then((uris: string[]): void => {
        if (uris.length === 0) {
          fallback('已取消保存');
          return;
        }
        if (ThreeMfExport.copyFile(srcPath, uris[0])) {
          promptAction.showToast({ message: `已保存 ${name}`, duration: 4000 });
        } else {
          fallback('写入所选位置失败');
        }
      }).catch((e: Object): void => {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        hilog.warn(0x0000, DEV_TAG, '另存为选择器失败: %{public}s', msg);
        fallback('选择器不可用');
      });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.warn(0x0000, DEV_TAG, '另存为选择器异常: %{public}s', msg);
      fallback('选择器异常');
    }
  }

  private fileSizeText(n: number): string {
    if (n >= 1024 * 1024) {
      return `${(n / (1024 * 1024)).toFixed(1)} MB`;
    }
    if (n >= 1024) {
      return `${Math.round(n / 1024)} KB`;
    }
    return `${n} B`;
  }

  // 下发打印控制命令（暂停/继续/停止）
  private cmdSeq: number = 0;
  private sendPrintCommand(cmd: string): void {
    this.cmdSeq++;
    const json: string = `{"print":{"command":"${cmd}","sequence_id":"${this.cmdSeq}","param":""}}`;
    MqttService.sendCommand(json);
  }

  // 下发 LED 灯控制命令（Bambu 协议：system.command = ledctrl）
  private sendLedCommand(on: boolean): void {
    this.cmdSeq++;
    const mode: string = on ? 'on' : 'off';
    const json: string = `{"system":{"command":"ledctrl","led_node":"chamber_light","led_mode":"${mode}","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0,"sequence_id":"${this.cmdSeq}"}}`;
    MqttService.sendCommand(json);
  }

  // 下发风扇速度命令（M106：P1=部件 P2=辅助 P3=机箱，S 值 0-255）
  private sendFanCommand(fanNo: number, percent: number): void {
    this.cmdSeq++;
    const s: number = Math.round(percent * 255 / 100);
    const gcode: string = `M106 P${fanNo} S${s}`;
    const json: string = `{"print":{"command":"gcode_line","param":"${gcode}\\n","sequence_id":"${this.cmdSeq}"}}`;
    MqttService.sendCommand(json);
    const now: number = Date.now();
    if (fanNo === 1) { this.partFanCmdTime = now; }
    else if (fanNo === 2) { this.auxFanCmdTime = now; }
    else { this.chamberFanCmdTime = now; }
  }

  // 重新读取 AMS 槽位 RFID（官方双协议：NP 打印机 ams_get_rfid，旧协议 M620 R{amsId*4+slotId}）
  // 节流 5 秒：RFID 读卡需数秒，且 AMS 同一时间只能读一个槽位，连点会压垮 AMS 服务
  private sendAmsRefresh(amsId: number, slotId: number): void {
    if (this.amsRefreshBusy) {
      return;
    }
    this.amsRefreshBusy = true;
    this.cmdSeq++;
    let json: string = '';
    if (this.npEnabled) {
      json = `{"print":{"command":"ams_get_rfid","sequence_id":"${this.cmdSeq}","ams_id":${amsId},"slot_id":${slotId}}}`;
    } else {
      const trayId: number = amsId * 4 + slotId;
      json = `{"print":{"command":"gcode_line","param":"M620 R${trayId}\\n","sequence_id":"${this.cmdSeq}"}}`;
    }
    MqttService.sendCommand(json).then((res: string) => {
      try {
        const r: CmdResult = JSON.parse(res) as CmdResult;
        if (!r.ok) {
          promptAction.showToast({ message: '连接已断开，正在自动重连' });
        }
      } catch (e) {
        // 解析失败忽略
      }
    });
    setTimeout(() => {
      this.amsRefreshBusy = false;
    }, 5000);
  }

  build() {
    Stack() {
      Row() {
        // 中央：打印进度
      Column() {
        Text('打印进度')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
          .width('100%')
          .padding({ left: 16, top: 14 })

        // 零件预览窗口：复用准备页同款 ArkGraphics3D 渲染（相机/光照/材质/取景/配色完全一致）
        Stack({ alignContent: Alignment.Center }) {
          // 视口底：与准备页视口同款深色底（3D 场景透明清屏，背景由该容器给出）
          Column()
            .width('90%')
            .height('75%')
            .backgroundColor('#1A1A22')
            .borderRadius(8)
            .border({ width: 1, color: Theme.border })
          if (this.pvReady && this.pvScene !== null && this.pvHasModel) {
            // 场景就绪且已有零件 → 直接在该窗口渲染模型。
            // 场景对象在组件创建前就已赋好（SceneOptions 创建后不可动态修改，见 Component3D 文档）。
            Component3D({ scene: this.pvScene })
              .width('90%')
              .height('75%')
              .borderRadius(8)
              .clip(true)
          } else if (this.pvReady) {
            // 合理空态（不是假文本）：没有可预览的零件时给出明确指引
            Column({ space: 6 }) {
              Text('尚未导入零件')
                .fontSize(13)
                .fontColor(Theme.textSecondary)
              Text('在「准备」页导入 STL / STEP 后在此预览')
                .fontSize(11)
                .fontColor(Theme.textSecondary)
            }
            .width('90%')
            .padding({ left: 12, right: 12 })
          } else {
            // 初始化 / 失败：显示真实过程态文案（不再是零件占位）
            Text(this.pvText)
              .fontSize(13)
              .fontColor(Theme.textSecondary)
              .maxLines(3)
              .textAlign(TextAlign.Center)
              .width('90%')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .clip(true)

        Row() {
          Text(`层：${this.layer} / ${this.totalLayers}`)
            .fontSize(13)
            .fontColor(Theme.textPrimary)
          Text(`剩余 ${this.remainingText()}`)
            .fontSize(13)
            .fontColor(Theme.textPrimary)
            .margin({ left: 16 })
          Blank()
          Text(this.state)
            .fontSize(13)
            .fontColor(Theme.accent)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 14 })

        // HMS 故障条 / 打印错误码（设备报了才显示；表里没文案时只显示码，绝不编造）
        if (this.hmsHits.length > 0 || this.printErrHit !== undefined) {
          this.hmsBar()
        }
      }
      .width('60%')
      .height('100%')

      // 右侧：打印机监控画面
      Column() {
        Text('打印机监控画面')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
          .width('100%')
          .padding({ left: 14, top: 14 })

        // 摄像头监控（右上角，16:9 比例）
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#0A0A10')
            .borderRadius(6)
            .border({ width: 1, color: Theme.border })
          if (this.cameraPixelMap) {
            Image(this.cameraPixelMap)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .borderRadius(6)
          } else if (!this.connected) {
            Text('摄像头 · 未连接')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          } else {
            // 已连接但无画面：不要把「未开启实况/未取到流」误报成「未连接」，避免客户以为设备坏了。
            // 现版本已覆盖两类协议：X1/X1C/X1E/H2D/P2S/X2D 走 322 RTSPS；
            // A1/A1 mini/P1P/P1S/A2L 走 6000 端口 chamber image（TCP+TLS/JPEG）。
            Column({ space: 3 }) {
              Text('未获取到画面')
                .fontSize(10)
                .fontColor(Theme.textSecondary)
              Text('请确认打印机已开启「局域网模式 / Developer Mode」；X1/P2S/H2D/X2D 另需开启「局域网模式实况(Liveview)」，A1/A1 mini 需在「摄像头选项」开启 Video')
                .fontSize(8)
                .fontColor(Theme.textSecondary)
                .textAlign(TextAlign.Center)
                .padding({ left: 10, right: 10 })
            }
          }
        }
        .width('100%')
        .aspectRatio(16 / 9)
        .margin({ left: 14, right: 14, top: 6, bottom: 6 })

        Scroll() {
          Column({ space: 8 }) {
            this.statusCard()
            // 打印控制
            Row({ space: 8 }) {
              Button('暂停')
                .layoutWeight(1).height(30).fontSize(12).fontColor(Theme.textPrimary)
                .backgroundColor(Theme.surfaceElevated).borderRadius(6)
                .systemMaterial(this.buttonMaterial)
                .onClick(() => { this.sendPrintCommand('pause'); })
              Button('继续')
                .layoutWeight(1).height(30).fontSize(12).fontColor(Theme.textPrimary)
                .backgroundColor(Theme.surfaceElevated).borderRadius(6)
                .systemMaterial(this.buttonMaterial)
                .onClick(() => { this.sendPrintCommand('resume'); })
              Button('停止')
                .layoutWeight(1).height(30).fontSize(12).fontColor(Theme.textPrimary)
                .backgroundColor(Theme.accent).borderRadius(6)
                .systemMaterial(this.buttonMaterial)
                .onClick(() => { this.sendPrintCommand('stop'); })
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            // ---- 我的打印机：连过的机器（记住访问码）→ 一键直连 ----
            // 为什么放在「发现打印机」上面：连过的机器是主路径（尤其机器换网段/SSDP 收不到时），
            // 发现只是"加新机器"。
            if (this.knownDevices.length > 0) {
              Row() {
                Text('我的打印机')
                  .fontSize(12)
                  .fontColor(Theme.textSecondary)
                Blank()
                Text('已记住访问码')
                  .fontSize(10)
                  .fontColor('#6C6C7C')
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 2 })

              ForEach(this.knownDevices, (d: KnownDevice) => {
                Row() {
                  Column({ space: 2 }) {
                    if (this.editingBookSerial === d.serial) {
                      TextInput({ text: this.editingBookName, placeholder: '给它起个名字' })
                        .height(30)
                        .fontSize(12)
                        .placeholderFont({ size: 11 })
                        .placeholderColor(Theme.textSecondary)
                        .backgroundColor('#26FFFFFF')
                        .borderRadius(5)
                        .onChange((v: string) => { this.editingBookName = v; })
                    } else {
                      Text(deviceBook.displayName(d))
                        .fontSize(12)
                        .fontColor(Theme.textPrimary)
                      Text(this.bookSubText(d))
                        .fontSize(10)
                        .fontColor(Theme.textSecondary)
                      Text(this.bookTimeText(d.lastConnectedAt))
                        .fontSize(10)
                        .fontColor('#6C6C7C')
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (this.editingBookSerial === d.serial) {
                    Button('保存')
                      .height(26)
                      .fontSize(11)
                      .fontColor('#06281E')
                      .backgroundColor(Theme.accent)
                      .borderRadius(4)
                      .margin({ left: 6 })
                      .onClick(() => {
                        deviceBook.rename(d.serial, this.editingBookName.trim());
                        this.knownDevices = deviceBook.list();
                        this.editingBookSerial = '';
                      })
                  } else {
                    Text('改名')
                      .fontSize(10)
                      .fontColor(Theme.textSecondary)
                      .margin({ right: 10 })
                      .onClick(() => {
                        this.editingBookSerial = d.serial;
                        this.editingBookName = d.alias;
                      })
                    Text('移除')
                      .fontSize(10)
                      .fontColor('#9A7A7A')
                      .margin({ right: 10 })
                      .onClick(() => {
                        const nm: string = deviceBook.displayName(d);
                        deviceBook.remove(d.serial);
                        this.knownDevices = deviceBook.list();
                        promptAction.showToast({ message: `已移除 ${nm}` });
                      })
                    Button(this.connectedSerial === d.serial ? '已连接'
                        : (this.connecting && this.connectingSerial === d.serial ? '连接中…' : '连接'))
                      .height(28)
                      .fontSize(11)
                      .fontColor(this.connectedSerial === d.serial ? '#00C48C' : Theme.textPrimary)
                      .backgroundColor(this.connectedSerial === d.serial ? '#14281F' : Theme.accent)
                      .borderRadius(4)
                      .stateEffect(true)
                      .systemMaterial(this.buttonMaterial)
                      .onClick(() => { this.connect(d.ip, d.serial, d.accessCode); })
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 4, bottom: 4 })
              }, (d: KnownDevice) => `${d.serial}=${d.lastConnectedAt}`)
            }

            // 发现打印机 / 手动输入连接（跳过长发现过程）
            Row({ space: 8 }) {
              Button(this.discovering ? '发现中…' : '发现打印机')
                .layoutWeight(1)
                .height(32)
                .fontSize(12)
                .fontColor(Theme.textPrimary)
                .backgroundColor(Theme.surfaceElevated)
                .borderRadius(4)
                .stateEffect(true)
                .systemMaterial(this.buttonMaterial)
                .onClick(() => { this.discover(); })
              Button(this.connecting && this.connectingSerial === '' ? '连接中…' : '输入连接')
                .height(32)
                .padding({ left: 12, right: 12 })
                .fontSize(12)
                .fontColor(Theme.accentSoft)
                .backgroundColor(Theme.surfaceElevated)
                .borderRadius(4)
                .border({ width: 1, color: '#3300C48C' })
                .stateEffect(true)
                .systemMaterial(this.manualMaterial)
                .onClick(() => {
                  this.manualIp = '';
                  this.manualCode = '';
                  this.showManualDialog = true;
                })
              // 打印机存储（FTPS）：浏览 / 下载 / 删除。未连接时禁用（拿不到会话就列不了）
              Button('文件')
                .height(32)
                .padding({ left: 12, right: 12 })
                .fontSize(12)
                .fontColor(this.connected ? Theme.textPrimary : '#55555F')
                .backgroundColor(Theme.surfaceElevated)
                .borderRadius(4)
                .border({ width: 1, color: this.connected ? '#33FFFFFF' : '#26262C' })
                .enabled(this.connected)
                .stateEffect(true)
                .systemMaterial(this.buttonMaterial)
                .onClick(() => { this.openFiles(); })
            }
            .width('100%')
            .padding({ left: 14, right: 14 })

            ForEach(this.printers, (p: DiscoveredPrinter) => {
              Row() {
                Column({ space: 2 }) {
                  Text(p.model === '' ? 'Bambu 打印机' : p.model)
                    .fontSize(12)
                    .fontColor(Theme.textPrimary)
                  Text(p.serial)
                    .fontSize(10)
                    .fontColor(Theme.textSecondary)
                  Text(p.ip)
                    .fontSize(10)
                    .fontColor(Theme.textSecondary)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Button(this.connectedSerial === p.serial ? '已连接' : (this.connecting && this.connectingSerial === p.serial ? '连接中…' : '连接'))
                  .height(28)
                  .fontSize(11)
                  .fontColor(this.connectedSerial === p.serial ? '#00C48C' : Theme.textPrimary)
                  .backgroundColor(this.connectedSerial === p.serial ? '#14281F' : Theme.accent)
                  .borderRadius(4)
                  .stateEffect(true)
                  .systemMaterial(this.buttonMaterial)
                  .onClick(() => {
                    // 设备簿里已有这台（连过）→ 直接用记住的访问码连，不再弹输入框
                    const c: string = this.bookCode(p.serial);
                    if (c.length > 0) {
                      this.connect(p.ip, p.serial, c);
                    } else {
                      this.showDialog(p.ip, p.serial);
                    }
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 2, bottom: 2 })
            }, (p: DiscoveredPrinter) => p.serial)

            // 发现为空时的可诊断引导：明确告诉用户可手动输入 IP + 访问码（部分机型/网络下
            // SSDP 可能收不到响应，例如打印机未开 LAN 模式、或 A1 系列响应方式不同）
            if (this.discovered && !this.discovering && this.printers.length === 0) {
              Column({ space: 4 }) {
                Text('未发现设备')
                  .fontSize(12)
                  .fontColor(Theme.textPrimary)
                Text('可点击右上「输入连接」手动填写打印机 IP 与访问码。若仍发现不到，请在打印机「设置」开启局域网模式后重试（设置路径以官方文档为准）：A1/A1 mini 为「设置 → 局域网模式」；P1P/P1S 为「设置 → WLAN → 局域网模式」；X1/P2S/H2D 为「设置 → 仅局域网」。')
                  .fontSize(10)
                  .fontColor(Theme.textSecondary)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 14, right: 14, top: 4, bottom: 4 })
            }

            // 温度（可编辑数值）
            this.tempEditRow('喷嘴温度', 0)
            this.tempEditRow('热床温度', 1)
            this.tempEditRow('腔体温度', 2)

            // 风扇控制（三个，10% 步进，按钮加减）
            Row() {
              Text('机箱风扇').fontSize(12).fontColor(Theme.textPrimary).layoutWeight(1)
              Button() {
                Text('-').fontSize(20).fontColor('#00C48C')
              }
              .width(36).height(36).backgroundColor(Theme.surfaceElevated).borderRadius(6)
              .stateEffect(true)
              .systemMaterial(this.fanButtonMaterial)
              .onClick(() => { this.chamberFan = Math.max(0, this.chamberFan - 10); this.sendFanCommand(3, this.chamberFan); })
              Text(`${this.chamberFan}%`).width(56).fontSize(14).fontColor(Theme.accentSoft).textAlign(TextAlign.Center)
              Button() {
                Text('+').fontSize(20).fontColor('#00C48C')
              }
              .width(36).height(36).backgroundColor(Theme.surfaceElevated).borderRadius(6)
              .stateEffect(true)
              .systemMaterial(this.fanButtonMaterial)
              .onClick(() => { this.chamberFan = Math.min(100, this.chamberFan + 10); this.sendFanCommand(3, this.chamberFan); })
            }
            .width('100%').padding({ left: 14, right: 14, top: 6, bottom: 6 })

            Row() {
              Text('辅助风扇').fontSize(12).fontColor(Theme.textPrimary).layoutWeight(1)
              Button() {
                Text('-').fontSize(20).fontColor('#00C48C')
              }
              .width(36).height(36).backgroundColor(Theme.surfaceElevated).borderRadius(6)
              .stateEffect(true)
              .systemMaterial(this.fanButtonMaterial)
              .onClick(() => { this.auxFan = Math.max(0, this.auxFan - 10); this.sendFanCommand(2, this.auxFan); })
              Text(`${this.auxFan}%`).width(56).fontSize(14).fontColor(Theme.accentSoft).textAlign(TextAlign.Center)
              Button() {
                Text('+').fontSize(20).fontColor('#00C48C')
              }
              .width(36).height(36).backgroundColor(Theme.surfaceElevated).borderRadius(6)
              .stateEffect(true)
              .systemMaterial(this.fanButtonMaterial)
              .onClick(() => { this.auxFan = Math.min(100, this.auxFan + 10); this.sendFanCommand(2, this.auxFan); })
            }
            .width('100%').padding({ left: 14, right: 14, top: 6, bottom: 6 })

            Row() {
              Text('部件风扇').fontSize(12).fontColor(Theme.textPrimary).layoutWeight(1)
              Button() {
                Text('-').fontSize(20).fontColor('#00C48C')
              }
              .width(36).height(36).backgroundColor(Theme.surfaceElevated).borderRadius(6)
              .stateEffect(true)
              .systemMaterial(this.fanButtonMaterial)
              .onClick(() => { this.partFan = Math.max(0, this.partFan - 10); this.sendFanCommand(1, this.partFan); })
              Text(`${this.partFan}%`).width(56).fontSize(14).fontColor(Theme.accentSoft).textAlign(TextAlign.Center)
              Button() {
                Text('+').fontSize(20).fontColor('#00C48C')
              }
              .width(36).height(36).backgroundColor(Theme.surfaceElevated).borderRadius(6)
              .stateEffect(true)
              .systemMaterial(this.fanButtonMaterial)
              .onClick(() => { this.partFan = Math.min(100, this.partFan + 10); this.sendFanCommand(1, this.partFan); })
            }
            .width('100%').padding({ left: 14, right: 14, top: 6, bottom: 6 })

            // AMS 耗材
            this.amsRow()

            this.switchRow('LED 灯', this.ledOn, (on: boolean) => { this.ledOn = on; this.sendLedCommand(on); })
            this.switchRow('自动续料', this.autoFilament, (on: boolean) => { this.autoFilament = on; })

            // 机器侧 AI 检测开关（带摄像头的机型才有；关掉后机器就不会在对应场景提醒/暂停）
            if (this.xcamRows.length > 0) {
              this.xcamSection()
            }

            // 状态详情（表驱动扩展字段）：设备报了才显示
            if (this.extRows.length > 0) {
              this.extSection()
            }
          }
          .width('100%')
          .padding({ top: 8, bottom: 20 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('40%')
      .height('100%')
      .backgroundColor(Theme.surface)
      .border({ width: { left: 1 }, color: Theme.border })
    }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)

      if (this.showAccessDialog) {
        this.accessDialog()
      }

      if (this.showManualDialog) {
        this.manualDialog()
      }

      if (this.showFilesDialog) {
        this.filesDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  accessDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => { this.showAccessDialog = false; })
      Column({ space: 14 }) {
        Text('输入访问码')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Text(`${this.pendingIp} · ${this.pendingSerial}`)
          .fontSize(11)
          .fontColor(Theme.textSecondary)
        TextInput({ text: this.accessCode, placeholder: 'Access Code' })
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor(Theme.textPrimary)
          .backgroundColor(Theme.surfaceElevated)
          .borderRadius(6)
          .onChange((v: string) => { this.accessCode = v; })
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Theme.textPrimary)
            .backgroundColor(Theme.surfaceElevated)
            .borderRadius(6)
            .onClick(() => { this.showAccessDialog = false; })
          Button('连接')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Theme.textPrimary)
            .backgroundColor(Theme.accent)
            .borderRadius(6)
            .onClick(() => { this.confirmConnect(); })
        }
        .width('100%')
      }
      .width(300)
      .padding(20)
      .backgroundColor(Theme.surfaceElevated)
      .borderRadius(12)
      .border({ width: 1, color: Theme.border })
      .backgroundEffect({ radius: 24, saturation: 1.15 })
    }
    .width('100%')
    .height('100%')
  }

  // 手动连接弹窗：IP + 访问码，玻璃质感
  @Builder
  manualDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => { this.showManualDialog = false; })
      Column({ space: 12 }) {
        Text('手动连接打印机')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Text('填入 IP 与访问码，直接与打印机通信，跳过局域网发现')
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .lineHeight(16)
        TextInput({ text: this.manualIp, placeholder: 'IP 地址，如 192.168.1.101' })
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor(Theme.textPrimary)
          .backgroundColor('#26FFFFFF')
          .borderRadius(6)
          .onChange((v: string) => { this.manualIp = v; })
        TextInput({ text: this.manualCode, placeholder: '访问码（打印机 LAN 模式可查）' })
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor(Theme.textPrimary)
          .backgroundColor('#26FFFFFF')
          .borderRadius(6)
          .onChange((v: string) => { this.manualCode = v; })
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Theme.textPrimary)
            .backgroundColor('#26FFFFFF')
            .borderRadius(6)
            .onClick(() => { this.showManualDialog = false; })
          Button('连接')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#06281E')
            .backgroundColor(Theme.accent)
            .borderRadius(6)
            .onClick(() => { this.manualConnect(); })
        }
        .width('100%')
      }
      .width(330)
      .padding(20)
      .borderRadius(14)
      .backgroundColor('#D91F1F27')
      .border({ width: 1, color: Theme.border })
      .systemMaterial(this.manualMaterial)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  card(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textPrimary)
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor(Theme.textSecondary)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(Theme.surfaceElevated)
    .borderRadius(6)
  }

  // 下发目标温度命令（M104 喷嘴 / M140 热床 / M141 腔体）
  private sendTargetTemp(kind: number): void {
    // 温度上限校验：上限优先取**机型能力矩阵**（喷嘴 nozzle_temp_range 上限、热床 bed_temperature_limit、
    // 腔体 65），矩阵未声明（0/空数组）时退回既有硬编码默认值 —— 只为「按机型收紧」，不会因缺数据放松。
    // 例：A1 mini 热床上限 80、A1/P1P/P1S 100、X1E 110 —— 此前一律放行到 110，打印机侧会拒绝或报错。
    const caps: PrinterCaps = this.caps();
    let maxTemp: number = 300;
    if (kind === 0) {
      maxTemp = (caps.nozzleTempRange.length > 1 && caps.nozzleTempRange[1] > 0)
        ? caps.nozzleTempRange[1] : 300;
    } else if (kind === 1) {
      maxTemp = caps.bedTemperatureLimit > 0 ? caps.bedTemperatureLimit : 110;
    } else {
      maxTemp = 65;
    }
    const curTemp: number = kind === 0 ? this.nozzleTargetTemp : (kind === 1 ? this.bedTargetTemp : this.chamberTargetTemp);
    if (curTemp > maxTemp) {
      if (kind === 0) { this.nozzleTargetTemp = 0; }
      else if (kind === 1) { this.bedTargetTemp = 0; }
      else { this.chamberTargetTemp = 0; }
      const name: string = kind === 0 ? '喷嘴' : (kind === 1 ? '热床' : '腔体');
      promptAction.showDialog({
        title: '温度超限',
        message: `${name}温度不能超过 ${maxTemp}℃`,
        buttons: [{ text: '确定', color: '#00C48C' }]
      });
      return;
    }

    this.cmdSeq++;
    let gcode: string = '';
    if (kind === 0) {
      gcode = `M104 S${Math.round(this.nozzleTargetTemp)}`;
      this.nozzleCmdTime = Date.now();
    } else if (kind === 1) {
      gcode = `M140 S${Math.round(this.bedTargetTemp)}`;
      this.bedCmdTime = Date.now();
    } else {
      gcode = `M141 S${Math.round(this.chamberTargetTemp)}`;
      this.chamberCmdTime = Date.now();
    }
    const json: string = `{"print":{"command":"gcode_line","param":"${gcode}\\n","sequence_id":"${this.cmdSeq}"}}`;
    MqttService.sendCommand(json);
  }

  @Builder
  tempEditRow(label: string, kind: number) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textPrimary)
      Blank()
      if (this.connected) {
        if (kind === 0) {
          Text(`${this.nozzleTempKnown ? this.fmt1(this.nozzleTemp) : '--'}`)
            .fontSize(14).fontWeight(FontWeight.Bold)
            .fontColor(this.nozzleTargetTemp <= 0 ? Theme.textPrimary : (this.nozzleTemp < this.nozzleTargetTemp - 1 ? '#FF5A5A' : (this.nozzleTemp > this.nozzleTargetTemp + 1 ? '#4FA8FF' : Theme.textPrimary)))
          Text('/').fontSize(12).fontColor(Theme.textSecondary).margin({ left: 4, right: 4 })
          TextInput({ text: `${this.fmt1(this.nozzleTargetTemp)}` })
            .width(56).height(30).fontSize(12).fontColor(Theme.accentSoft)
            .backgroundColor(Theme.surfaceElevated).borderRadius(4)
            .enterKeyType(EnterKeyType.Done)
            .onFocus(() => { this.editingKind = 0; })
            .onBlur(() => { this.editingKind = -1; })
            .onChange((v: string) => {
              const n: number = Number(v.replace(/[^0-9.\-]/g, ''));
              if (!isNaN(n)) { this.nozzleTargetTemp = n; }
            })
            .onSubmit(() => { this.sendTargetTemp(0); })
        } else if (kind === 1) {
          Text(`${this.bedTempKnown ? this.fmt1(this.bedTemp) : '--'}`)
            .fontSize(14).fontWeight(FontWeight.Bold)
            .fontColor(this.bedTargetTemp <= 0 ? Theme.textPrimary : (this.bedTemp < this.bedTargetTemp - 1 ? '#FF5A5A' : (this.bedTemp > this.bedTargetTemp + 1 ? '#4FA8FF' : Theme.textPrimary)))
          Text('/').fontSize(12).fontColor(Theme.textSecondary).margin({ left: 4, right: 4 })
          TextInput({ text: `${this.fmt1(this.bedTargetTemp)}` })
            .width(56).height(30).fontSize(12).fontColor(Theme.accentSoft)
            .backgroundColor(Theme.surfaceElevated).borderRadius(4)
            .enterKeyType(EnterKeyType.Done)
            .onFocus(() => { this.editingKind = 1; })
            .onBlur(() => { this.editingKind = -1; })
            .onChange((v: string) => {
              const n: number = Number(v.replace(/[^0-9.\-]/g, ''));
              if (!isNaN(n)) { this.bedTargetTemp = n; }
            })
            .onSubmit(() => { this.sendTargetTemp(1); })
        } else {
          Text(`${(this.hasActiveChamber() && this.chamberTempKnown) ? this.fmt1(this.chamberTemp) : '--'}`)
            .fontSize(14).fontWeight(FontWeight.Bold)
            .fontColor(this.hasActiveChamber() ? (this.chamberTargetTemp <= 0 ? Theme.textPrimary : (this.chamberTemp < this.chamberTargetTemp - 1 ? '#FF5A5A' : (this.chamberTemp > this.chamberTargetTemp + 1 ? '#4FA8FF' : Theme.textPrimary))) : Theme.textSecondary)
          Text('/').fontSize(12).fontColor(Theme.textSecondary).margin({ left: 4, right: 4 })
          if (this.hasChamberHeater && this.hasActiveChamber()) {
            TextInput({ text: `${this.fmt1(this.chamberTargetTemp)}` })
              .width(56).height(30).fontSize(12).fontColor(Theme.accentSoft)
              .backgroundColor(Theme.surfaceElevated).borderRadius(4)
              .enterKeyType(EnterKeyType.Done)
              .onFocus(() => { this.editingKind = 2; })
              .onBlur(() => { this.editingKind = -1; })
              .onChange((v: string) => {
                const n: number = Number(v.replace(/[^0-9.\-]/g, ''));
                if (!isNaN(n)) { this.chamberTargetTemp = n; }
              })
              .onSubmit(() => { this.sendTargetTemp(2); })
          } else {
            Text('--').fontSize(12).fontColor(Theme.textSecondary)
          }
        }
        Text('℃')
          .fontSize(12)
          .fontColor(Theme.textSecondary)
          .margin({ left: 4 })
      } else {
        Text('-- / -- ℃')
          .fontSize(12)
          .fontColor(Theme.textSecondary)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
  }

  @Builder
  statusCard() {
    Column({ space: 6 }) {
      Row() {
        Text('连接状态')
          .fontSize(12)
          .fontColor(Theme.textPrimary)
        Blank()
        if (this.connected) {
          Row({ space: 10 }) {
            Row({ space: 5 }) {
              Column()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor(this.statusCount > 0 ? '#00C48C' : '#FFB454')
              Text(this.connectedLabel())
                .fontSize(11)
                .fontColor(this.statusCount > 0 ? '#00C48C' : '#FFB454')
            }
            // 用户主动断开（与"切页中断"区分：按下后单例 connected=false，回页不自动重连）
            Button('断开')
              .fontSize(11)
              .height(24)
              .padding({ left: 10, right: 10 })
              .fontColor(Theme.textSecondary)
              .backgroundColor(Theme.surface)
              .borderRadius(4)
              .stateEffect(true)
              .onClick(() => { this.manualDisconnect(); })
          }
        } else {
          Row({ space: 5 }) {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(Theme.textSecondary)
            Text('未连接')
              .fontSize(12)
              .fontColor(Theme.textSecondary)
          }
        }
      }
      .width('100%')

      // 连上但还没收到任何状态上报时如实提示（不假装已完整连接）。
      // 与"已连接（未收到状态数据）"一致：若同时缺 SN，额外提示补 SN。
      if (this.connected && this.statusCount === 0) {
        Text(this.connectedSerial === ''
          ? '已建立连接但尚未收到状态上报（未获取到序列号 SN）。请确认已开启局域网模式(LAN Only)/开发者模式；仍无数据请看日志页 MqttConn 诊断。'
          : '已建立连接但尚未收到状态上报。请确认已开启局域网模式(LAN Only)/开发者模式；仍无数据请看日志页 MqttConn 诊断。')
          .fontSize(10)
          .fontColor('#FFB454')
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(Theme.surfaceElevated)
    .borderRadius(6)
  }

  // 连接状态文案：连上但一条状态都没收到时不再只显示"已连接"，
  // 避免客户看到"连接成功"（Toast）与状态互斥/矛盾。
  private connectedLabel(): string {
    const sn: string = this.connectedSerial === '' ? '' : ` · ${this.connectedSerial}`;
    if (this.statusCount > 0) {
      return `已连接${sn}`;
    }
    return `已连接（未收到状态数据）${sn}`;
  }

  @Builder
  amsRow() {
    Column({ space: 6 }) {
      Row() {
        Text('AMS 耗材')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Blank()
        Text(this.amsUnits.length === 0 ? '未连接 AMS' : `${this.amsUnits.length} 单元`)
          .fontSize(11)
          .fontColor(Theme.textSecondary)
      }
      .width('100%')

      ForEach(this.amsUnits, (unit: AmsUnit) => {
        Column({ space: 4 }) {
          Row() {
            Text(`AMS ${unit.id}`)
              .fontSize(11)
              .fontColor(Theme.accentSoft)
            Blank()
            Text(`湿度 ${unit.humidity}/5 · ${unit.temp}℃`)
              .fontSize(10)
              .fontColor(Theme.textSecondary)
          }
          .width('100%')

          Row({ space: 10 }) {
            ForEach(unit.trays, (tray: AmsTray, i: number) => {
              Column({ space: 2 }) {
                Column()
                  .width(24)
                  .height(24)
                  .borderRadius(4)
                  .backgroundColor(tray.color)
                Text(tray.type)
                  .fontSize(9)
                  .fontColor(Theme.textSecondary)
                  .maxLines(1)
                Text(tray.remain >= 0 ? `${tray.remain}%` : '--')
                  .fontSize(8)
                  .fontColor(Theme.textSecondary)
                // 重新读取该槽位 RFID 耗材信息（读取期间显示"读取中"，全局节流 5 秒）
                Button(this.amsRefreshBusy ? '读取中' : '刷新')
                  .fontSize(9)
                  .height(20)
                  .padding({ left: 6, right: 6 })
                  .fontColor(this.amsRefreshBusy ? Theme.textSecondary : Theme.accentSoft)
                  .backgroundColor(Theme.surfaceElevated)
                  .borderRadius(4)
                  .stateEffect(true)
                  .onClick(() => { this.sendAmsRefresh(parseInt(unit.id), i); })
              }
            }, (tray: AmsTray, i: number) => `${unit.id}-${i}`)
          }
          .width('100%')
        }
        .width('100%')
      }, (unit: AmsUnit) => `ams-${unit.id}`)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
    .backgroundColor(Theme.surfaceElevated)
    .borderRadius(6)
  }

  @Builder
  switchRow(label: string, isOn: boolean, onChange: (on: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textPrimary)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(Theme.accent)
        .onChange((on: boolean) => { onChange(on); })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
  }

  // HMS 故障条：设备上报 print.hms 时显示（按等级配色）。
  // 文案来自离线码表；表里没有的条目只显示码 —— 用户拿码可以去官方文档/客服查，
  // 比"什么都不显示"强，但绝不编造一句听起来像官方的话。
  @Builder
  hmsBar() {
    Column({ space: 4 }) {
      ForEach(this.hmsHits, (h: HmsHit) => {
        Row() {
          Text('●')
            .fontSize(9)
            .fontColor(this.hmsColor(h.level))
            .margin({ top: 3 })
          Text(h.intro.length > 0 ? h.intro : `HMS ${h.ecode}`)
            .fontSize(11)
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (h: HmsHit) => h.ecode)

      if (this.printErrHit !== undefined) {
        Row() {
          Text('●')
            .fontSize(9)
            .fontColor('#FF3D2E')
            .margin({ top: 3 })
          Text(this.printErrHit.intro.length > 0
            ? this.printErrHit.intro
            : `错误码 ${this.printErrHit.ecode}`)
            .fontSize(11)
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .backgroundColor('#1AFF3D2E')
    .borderRadius(6)
    .margin({ left: 16, right: 16, bottom: 14 })
  }

  // 打印机文件对话框：浏览打印机存储（cache / 根目录）、下载到应用沙箱、删除文件。
  // 只做「文件级」操作：目录只展示不进入（列表里点目录不下钻 —— 打印机上的目录是固定几个，
  // 下钻对用户没有价值，反而多一层状态）。
  @Builder
  filesDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#A6000000')
        .onClick(() => { this.showFilesDialog = false; })

      Column({ space: 10 }) {
        Row() {
          Text('打印机文件')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary)
          Blank()
          Text(this.connected ? this.connectedSerial : '未连接')
            .fontSize(10)
            .fontColor(Theme.textSecondary)
          Text('关闭')
            .fontSize(11)
            .fontColor(Theme.textSecondary)
            .margin({ left: 14 })
            .onClick(() => { this.showFilesDialog = false; })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text('cache')
            .fontSize(11)
            .fontColor(this.fileDir === '/cache' ? '#06281E' : Theme.textSecondary)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.fileDir === '/cache' ? Theme.accent : '#1FFFFFFF')
            .borderRadius(9)
            .onClick(() => { this.switchFileDir('/cache'); })
          Text('根目录')
            .fontSize(11)
            .fontColor(this.fileDir === '/' ? '#06281E' : Theme.textSecondary)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.fileDir === '/' ? Theme.accent : '#1FFFFFFF')
            .borderRadius(9)
            .onClick(() => { this.switchFileDir('/'); })
          Blank()
          Text(this.filesLoading ? '读取中…' : '刷新')
            .fontSize(11)
            .fontColor(this.filesLoading ? '#55555F' : Theme.accentSoft)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor('#1FFFFFFF')
            .borderRadius(9)
            .onClick(() => {
              if (!this.filesLoading) {
                this.loadFiles();
              }
            })
        }
        .width('100%')

        if (this.filesMsg.length > 0) {
          Text(this.filesMsg)
            .fontSize(11)
            .fontColor('#FF9F1A')
            .width('100%')
        }

        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.fileItems, (f: RemoteFile) => {
              Row() {
                Column({ space: 2 }) {
                  Text(f.name)
                    .fontSize(12)
                    .fontColor(f.isDir ? Theme.textSecondary : Theme.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(f.isDir ? `目录 · ${f.timeText}` : `${this.fileSizeText(f.size)} · ${f.timeText}`)
                    .fontSize(10)
                    .fontColor('#7A7A88')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (!f.isDir) {
                  if (this.fileBusy === f.name) {
                    Text('处理中…')
                      .fontSize(10)
                      .fontColor('#7A7A88')
                  } else {
                    Text('下载')
                      .fontSize(10)
                      .fontColor(Theme.accentSoft)
                      .margin({ right: 10 })
                      .onClick(() => { this.downloadRemoteFile(f); })
                    Text('删除')
                      .fontSize(10)
                      .fontColor('#FF8A7A')
                      .onClick(() => { this.removeRemoteFile(f); })
                  }
                }
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .backgroundColor('#0DFFFFFF')
              .borderRadius(5)
            }, (f: RemoteFile) => `${f.path}=${f.size}`)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
      }
      .width(620)
      .constraintSize({ maxHeight: 640 })
      .padding(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#F2181D25')
      .borderRadius(14)
      .border({ width: 1, color: '#33FFFFFF' })
      .shadow({ radius: 28, color: '#99000000', offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
  }

  // 「AI 检测开关」：只读显示机器侧检测的开关状态（这些开关由打印机固件管，
  // 桌面版能改、我们只读）。为什么值得显示：打印板检测/炒面/首层检测关掉后，
  // 机器根本不会提醒 —— 用户会以为"app 没做"，看到开关是关的就一目了然。
  @Builder
  xcamSection() {
    Column({ space: 6 }) {
      Row() {
        Text('AI 检测')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Blank()
        Text('机器侧设置')
          .fontSize(10)
          .fontColor('#7A7A88')
      }
      .width('100%')

      ForEach(this.xcamRows, (r: ExtRow) => {
        Row() {
          Text(r.k)
            .fontSize(12)
            .fontColor(Theme.textSecondary)
            .width(96)
          Text(r.v)
            .fontSize(12)
            .fontColor(r.v === '开' ? Theme.accent : '#8A8A96')
            .layoutWeight(1)
        }
        .width('100%')
      }, (r: ExtRow) => `${r.k}=${r.v}`)

      Text('在打印机屏幕上修改；关掉后机器不会在对应场景提醒或暂停')
        .fontSize(10)
        .fontColor('#6C6C7C')
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 10, bottom: 4 })
  }

  // 「状态详情」：表驱动扩展字段（任务名/阶段/信号/固件/错误码…）。
  // 这一块**不需要随 C++ 加字段而改动** —— 显示名与值都是 C++ 给的字符串。
  @Builder
  extSection() {
    Column({ space: 6 }) {
      Text('状态详情')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
        .width('100%')
      ForEach(this.extRows, (r: ExtRow) => {
        Row() {
          Text(r.k)
            .fontSize(12)
            .fontColor(Theme.textSecondary)
            .width(72)
          Text(r.v)
            .fontSize(12)
            .fontColor(Theme.textPrimary)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (r: ExtRow) => `${r.k}=${r.v}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 10, bottom: 6 })
  }
}
