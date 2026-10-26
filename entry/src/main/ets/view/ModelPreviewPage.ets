import { Theme } from '../common/Theme';
import testNapi from 'libentry.so';
import promptAction from '@ohos.promptAction';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import picker from '@ohos.file.picker';
import uiMaterial from '@ohos.arkui.uiMaterial';
import {
  Scene, SceneResourceFactory, MaterialType, LightType, PrimitiveTopology,
  CustomGeometry, Camera, Node, Geometry, MeshResource, Material,
  MetallicRoughnessMaterial, UnlitMaterial, CullMode, RaycastResult, RenderingPipelineType, PCFConfig, Image
} from '@kit.ArkGraphics3D';
import type { Vec3, Vec2, Quaternion, Color, Light, RaycastParameters, RenderConfiguration, PostProcessSettings } from '@kit.ArkGraphics3D';
// displaySync：系统提供的 VSync 逐帧回调（带 ns 时间戳）—— 本 SDK 上唯一能拿到的真实帧事件。
// ArkGraphics3D 只暴露 Scene.renderFrame()（主动请求渲染），没有「渲染完成」回调，见 FPS 统计一节。
import displaySync from '@ohos.graphics.displaySync';
import {
  MeshGeometry, zUpToYUp, zUpToYUpInPlace, eulerToQuaternion, dirToQuaternion,
  buildGridLines, buildPlateBorder, buildNozzleBorder, buildZoneLabelQuad, autoFitDistance, panPerPixel,
  quatInverse, rotateVecByQuat, fromToQuat, isFiniteVec3, multiplyQuaternion,
  FaceIndex, repairNormals, buildGizmoArrow, buildGizmoRing, gizmoBasis, meshVertexIndex, meshVertexAt,
  materializeVerticesChunked, materializeIndicesChunked
} from '../model/MeshUtils';
import { ModelFile, PlateMeta } from '../model/Models';
import { modelState, ModelInstance, PLATE_LIFT_MM } from '../model/ModelState';
import { MeshOps, MergePart } from '../model/MeshOps';
import { history } from '../model/History';
import { SliceParam } from '../model/SliceModels';
import { SliceParamStore } from '../service/SliceParamStore';
import { SlicerService } from '../service/SlicerService';
import { ensureThumbnail } from '../model/Thumbnail';
import {
  gcodeToolpath, gcodeSignals, GcodeMeshPart, ROLE_RGB, ROLE_COLOR_HEX, paletteProblems,
  RELEASE_GCODE_ON_LEAVE
} from '../model/GcodeToolpath';
import { AppLog } from '../service/AppLog';
import { plateAddEmpty } from '../service/PlateActions';
import { FilamentGrouping } from '../service/FilamentGrouping';
import { PlateList } from './PlateList';
import { LoadingDialog, LoadDlgModel, ProgressMsg, parseProgressJson, globalPercent, LOAD_STAGES } from './LoadingDialog';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 载入弹窗相关日志的 tag（异常一律打 hilog，不吞）
const TAG: string = 'LoadDlg';

// ---- 需求 2：顶部工具抽屉 --------------------------------------------------------
// 新增日志 tag（不动任何既有 tag），用于抽屉开关状态的自证/排查。
const TOPDRAWER_TAG: string = 'TopDrawer';
// 抽屉展开/收起的过渡时长（毫秒）。取 200（需求建议 180~220）：够看出「从上滑入/淡出」，
// 又不拖沓。打开与关闭共用这一条时长（关闭动画靠「常驻挂载 + animateTo」实现，见 topToolDrawer）。
const TOPDRAWER_ANIM_MS: number = 200;

// ---- 进度「日志流」与「数值状态」分开处理的参数 ---------------------------------
// 为什么必须分开：数值状态（全局 pct / 阶段 / 阶段内 pct）合并成「只取最新」是合理的，
// 但日志行一旦跟着一起合并，主线程被长同步块占住时，几十条进度事件会在同一轮事件循环里
// 塌缩成一行 —— 用户看到的就是「一次载入只有十几条日志 + 百分比一顿一顿地跳」。
// 所以：数值走合并（pendingNumeric 只留最新），日志走独立队列（pendingLogs 一条不丢）。
// 渲染时机走「固定节奏」节流：最多每 LOG_FLUSH_INTERVAL_MS 合并渲染一次。进度约 25 条/秒，
// 若每条各自触发一次渲染 + 一次位移动画，动画 churn 本身就会持续抢占 UI 线程（实测 UI 已
// 严重落后于真实进度）；固定节奏下这段时间累积的多行一次性加入，弹窗侧只做一次位移动画。
const LOG_FLUSH_INTERVAL_MS: number = 130;   // 日志/位移动画统一节流节奏（毫秒）：合并渲染一次
const LOG_QUEUE_MAX: number = 200;   // 待渲染日志队列上限（超出丢最老，防极端情况堆积）

// ---- 「自下而上逐层长出」的分批建层粒度 -----------------------------------------
// 建几何按层分批进行：每批最多 GCODE_BUILD_CHUNK 层，建完一批就按当前目标层揭示一次。
// 为什么分批而不是一次 ensureLayers(总层)：一次性建完只有「最后一次性揭示」，看不到
// 逐层长出；分批后每批之间让出一帧，已建好的层一帧一帧地亮起来，形成自然的自下而上观感，
// 同时避免长时间占用 UI 线程（大模型一次建完会把 JS/UI 线程占住几秒）。
// 取 16：批数不至于太多（一千层 ≈ 63 批），单批又不至于让「长出」显得一顿一顿。
const GCODE_BUILD_CHUNK: number = 16;

// ---- 【分块合并：唯一允许的「减批次」手段】每块合并多少层 ------------------------------
// 批次（draw call）由「几何数」决定，不由「节点数」决定：合并前每层每角色各一个几何，
// 实测 998 层模型最终 1804 批 / 可见 336 层时 1604 批，FPS 随规模近似线性下降 = 典型 draw call 瓶颈。
// 这里把「连续 N 层、同一角色」的几何拼成一个几何（顶点/法线数组首尾相接，索引按顶点基址偏移后
// 拼接），于是每块每角色只绘制一次：批次数 ≈ 块数 × 角色数。
//
// ★★ 分块合并【只减批次，块内所有层照画，绝不是稀疏】：区间内每一层的每一段都被原样拼进
//    块几何，块内层数恒等于当前块大小（最后一块可能不足），层与层之间既没有空隙、也不会透光
//    —— 画面与合并前逐层一致。任何「隔层显示」仍然禁止（见下一段注释）。
//
// ★★【粒度一次性定死，本次会话内绝不再变】（这是「回拨又重渲染一遍」的根治点）
//   块大小在「gcode 载入时」按【总层数】定死一次，之后无论用户往哪个方向拖、跨过多少层，
//   本份 gcode 的块大小都不再改变：
//     · 总层数 ≤ GCODE_CHUNK_SMALL_MAX(400) → GCODE_CHUNK_SMALL(1) 层/块 → 逐层手感（拖一层界面就变）；
//     · 总层数 >  GCODE_CHUNK_SMALL_MAX(400) → GCODE_CHUNK_LARGE(4) 层/块 → 上层数极多时省 draw call。
//
//   【为什么必须「一次性」而不是「按应可见层数自适应」】上一版按应可见层数分档 + 滞回：
//   块大小一变，块边界就变、已建块几何整体作废，只能 destroyToolpath 整棵重建；而重建会让可见性
//   从 0 重新收敛 → 用户看到的就是「回拨一下，画面整片消失又重新渲染一遍」。上一版又加了
//   「拖动中不切档 + 松手 280ms 去抖」想绕开它，但回拨一旦跨过滞回阈值，去抖到期仍会切档重建 ——
//   触发链没被消除（真机日志实锤：`拖动结束去抖到期 → 放行切档 4→1 层` 紧随其后就是
//   `渲染中标志 显示 built=0`，即 destroyToolpath）。
//   根治办法只有一个：把「块大小」与「当前可见层数」彻底解耦。因此【整套自适应粒度 / 滞回 / 去抖
//   机制已整体删除】（pickChunkLayers / applyChunkGranularity / onUserDragChanged / userDragging /
//   granSwitchAllowed / GRAN_REEVAL_DELAY_MS 全部不复存在），拖动期间与松手之后都不会再有任何
//   「销毁 / 重建 / 块重排」。
const GCODE_CHUNK_SMALL: number = 1;       // 总层数 ≤ 400：1 层/块（逐层刷新手感，与合并前一致）
const GCODE_CHUNK_LARGE: number = 4;       // 总层数 >  400：4 层/块（省批次；此时屏幕上层数极多）
const GCODE_CHUNK_SMALL_MAX: number = 400; // 粒度分界（按总层数，而非应可见层数）

// ---- 【禁止用「稀疏 / 隔层显示」来省性能】----------------------------------------
// 曾经试过：可见层数超过某个上限时只让第 0、k、2k… 层可见（稀疏提交），想靠「少画」降低
// GPU 负载。这是错的 —— 层与层之间被抽空后，水平方向看就是「透光」，大量中间层消失还会
// 看起来像「大量层变灰 / 缺层」。矮模型（层数不超上限、步长恒为 1）因此完全正常，高模型
// （如 998 层）才出问题，会让人误以为是「层数被限制住了」。
// 结论：可见语义必须是朴素前缀「[0, cur) 全部可见」，任何「隔层显示」都不许再加回来。
// 真要优化只能走无损手段（连续成带、拐点共享顶点 / 背面剔除），绝不能靠少画层换性能。
// —— 本文件已按「连续成带」实现：见上面的分块合并（粒度按总层数定死，只减批次，层一层不少）。

// ---- 进入切片路径时的「自下而上扫层」参数 ---------------------------------------
// 扫层 = 从第 0 层起把可见层数按拍数逐级推上去，让路径从底部长到顶部（约 1.4 秒）。
// 关键：推进只走 applyLayerVisibility + lastVisChunks 的差值管线（每拍只点亮新增的那几块），
// 绝不直接写节点 visible、也绝不全量遍历 —— 否则会重现「旧层不熄灭 / 残留」。
// 合并后可见性最小步进 = 一块（当前块大小 this.chunkLayers 层），所以扫层按「块」推进；
// 每拍间隔按块数重算（见 startSweep），让总时长仍 ≈ SWEEP_FRAMES × SWEEP_TICK_MS ≈ 1.44s。
const SWEEP_TICK_MS: number = 16;
const SWEEP_FRAMES: number = 90;

// ---- 阴影分级档位（性能 / 观感 A/B 用：改这里即可调节）--------------------------------
// ArkGraphics3D 的 PCF 软阴影默认 shadowSampleCount=16、shadowSampleRadius=5.0（官方文档），
// 采样次数越多、每个像素采样的阴影图次数越多、GPU 越贵 —— 这是「切片路径预览 GPU 偏紧」的可控项。
// 档位（推荐值）：16（官方原值，最贵）/ 8 / 4 / 0（完全关闭阴影）。
//   · 0  → 关阴影（shadowEnabled=false，不做任何 PCF 采样）；
//   · >0 → 开阴影，并把场景级 PCF 采样次数设为该档位。
// 注意：这里调的是「阴影贴图/投影」，与防糊无关 —— 防糊靠的是梯形截面 + 角色配色（本文件未改动）。
// 分两套常量（二者需求不同，当前两套都取 0，保持现状）。
// 为什么默认 0（不是 8）：
//   · 本场景 sun / fill 两盏灯创建时就是 light.shadowEnabled = false，阴影本来就是关的；
//   · 且没有任何材质设置 shadowReceiver（官方默认 false）→ 即便把灯打开、也没有任何面接收阴影，
//     观感完全不会改变，只会白花 GPU。所以默认必须为 0：关阴影、零 PCF 开销，与现状一致、无行为变化。
// 将来若要真开阴影：必须【同时】给需要接收阴影的材质设置 shadowReceiver = true，否则开了也看不到效果。
const SHADOW_SAMPLE_COUNT_MODEL: number = 0;   // 模型预览档位（改这里即可调节）
const SHADOW_SAMPLE_COUNT_GCODE: number = 0;   // 切片路径预览档位（改这里即可调节；走线不需要投影）
const SHADOW_SAMPLE_RADIUS: number = 5.0;      // PCF 采样半径（官方默认 5.0，改这里即可调节）

// ---- 打印板前端辅助线（喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线）-------------------
// 这些线是【真值】：它们来自当前机器预设的启动 G-code（machine_start_gcode），任何一次打印
// 都会在板前端打出来；切片预览里同样能在真实 gcode 中解析到（见 GcodeToolpath 的 role=辅助线）。
// 上一版曾用「按板尺寸推导」的条数/间距/长度画过一组示意线——那套是编造的、已全部删除。
// 这里只做一件事：把启动 G-code 的真实 X/Y 路径解析出来、贴在打印板上渲染；解析不到就不画。
// 坐标口径与切片路径一致（见 GcodeToolpath.buildStartGcodeLines 注释）。
// 承载它的节点挂在打印板节点 plate 下，与网格/边框同一层级、随盘面一起重建。

// ---- 需求 4：悬空/支撑告警 -------------------------------------------------------
// 支撑开关的真实参数 key（内核 PrintConfig，默认 0 = 关）；开启支撑后不再提示「需要添加支撑」。
const SUPPORT_ENABLE_KEY: string = 'enable_support';
// 新增自证日志与 UI 用的 hilog tag（不改动任何既有 tag）
const FLOW_TAG: string = 'FlowSupport';

// ---- 载入过程没有超时判定 -----------------------------------------------------
// 这里刻意不做超时：大模型载入本来就慢，按「等了多久」去关窗 / 判失败 / 改文案
// 只会把「慢」误判成「卡死」。载入只由两件事结束：
//   1) onLoadDone —— 正常收尾（先挂模型进场景，再关窗）；
//   2) failLoad —— 真实错误（NAPI 返回失败或抛异常）。
// 请勿再加任何时间阈值。

// 解析结果信息（meshParse / meshParseWithProgress 回调 info JSON）
class ParseInfo {
  ok: boolean = false;
  error: string = '';
  triangles: number = 0;
  sizeX: number = 0;
  sizeY: number = 0;
  sizeZ: number = 0;
  // 单位识别：1 = 原本就是毫米；1000 = 判定为「按米建模」并已自动 ×1000（C++ 侧完成）
  unitScale: number = 1;
  // 载入统计（C++ 侧真实计数，用于弹窗日志）
  origTriangles: number = 0;
  weldInVerts: number = 0;
  uniqueVerts: number = 0;
  creaseSplit: number = 0;
  outVerts: number = 0;
  // 需求 4：原生侧「悬空（朝下）面」启发式统计（真实数字）
  overhangRatioPct: number = 0;
  overhangAngleDeg: number = 0;
  overhangAreaPctThreshold: number = 0;
  needsSupport: boolean = false;
}

// 载入某机型板模型的结果（loadBedPlate 返回）
class BedPlate {
  geom: MeshGeometry = new MeshGeometry();
  width: number = 0;
  height: number = 0;
  src: string = '';
  // 板模型在【绝对床坐标】里的包围盒（mm）；内置兜底板按对称包围盒处理（±width/2 等）
  bboxMinX: number = 0;
  bboxMinY: number = 0;
  bboxMaxX: number = 0;
  bboxMaxY: number = 0;
}

// 单喷嘴专属区（参数面板由 extruder_printable_area 真值算得后下发）
class NozzleZone {
  minX: number = 0;
  maxX: number = 0;
  minY: number = 0;
  maxY: number = 0;
  side: string = '';   // 'left' | 'right'
}

class PlateZones {
  ox: number = 0;      // 盘面原点（printable_area 包围盒左界）
  oy: number = 0;
  zones: NozzleZone[] = [];
}

// 悬空结论汇总（把所有「已加载」模型的启发式统计并成一份，供告警显隐与日志使用）。
class SupportAgg {
  needed: boolean = false;    // 任一模型判定需支撑
  ratio: number = 0;          // 实测朝下面占比（取最大，%）
  angle: number = 0;          // 角度阈值（度）
  threshold: number = 0;      // 面积占比阈值（%）
}

// 字节数 → "83.9 MB"（与 C++ 侧 fmtSize 口径一致）
function fmtSize(bytes: number): string {
  if (bytes <= 0) { return '未知大小'; }
  if (bytes >= 1024 * 1024) { return (bytes / (1024 * 1024)).toFixed(1) + ' MB'; }
  return Math.round(bytes / 1024).toString() + ' KB';
}

function extLabel(ext: string): string {
  return (ext === '.step' || ext === '.stp') ? 'STEP' : 'STL';
}

// 千分位展示（日志里的真实计数）
function fmtNum(v: number): string {
  const s: string = Math.round(v).toString();
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 === 0) { out += ','; }
    out += s.charAt(i);
  }
  return out;
}

// 逐跳插桩用：截断过长的 JSON，避免单条进度把日志刷爆（保留前缀足够定位）
function truncJson(s: string): string {
  return s.length > 160 ? (s.substring(0, 160) + '…') : s;
}

// 逐跳插桩用：进程内相对毫秒（自本次载入开始），用于比对顺序与时间差
function relMs(startMs: number): string {
  return (Date.now() - startMs).toString();
}

// 让出一帧：把控制权交回事件循环，让已更新的进度 / 日志真正绘制出来。
// 大模型在「扁平缓冲 → 渲染几何」这一步是千万级元素，必须分段让帧：否则一口气做完会把
// JS/UI 线程占住几十秒，已发出的进度根本画不出来 —— 用户看到的就是「停在某一步不动」。
// 说明（修 AppFreeze）：这里必须让出【真实的一帧】(16ms)，不能只 setTimeout(0) —— 实测
// setTimeout(0) 的续体会作为微任务立刻跑，主线程几乎没有真正空闲，系统的 THREAD_BLOCK
// 看门狗仍会把连续几百 ms 的 JS 忙判成「卡住」（>3s 报 3S、>6s 直接杀进程）。留 16ms
// 真空闲后，看门狗能拿到自己的消息，段与段之间不再累积成一个长阻塞。
function yieldToUi(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => { resolve(); }, 16);
  });
}

// 模型局部坐标系下的射线
class LocalRay {
  o: Vec3 = { x: 0, y: 0, z: 0 };
  d: Vec3 = { x: 0, y: 1, z: 0 };
}

// ---- 视图预设（Phase 3）----
// 视角预设：yaw/pitch（弧度）。Z-up + 轨道相机：yaw=0 → 正面，pitch=π/2 → 俯视。
// 顶/底取 1.52（≈87°）而不是正好 ±π/2：欧拉角在 π/2 处有奇点（yaw 失去意义、画面会跳）。
interface ViewAngles {
  yaw: number;
  pitch: number;
}

function viewPresetAngles(name: string): ViewAngles | null {
  if (name === 'front') { return { yaw: 0, pitch: 0 }; }
  if (name === 'back') { return { yaw: Math.PI, pitch: 0 }; }
  if (name === 'left') { return { yaw: -Math.PI / 2, pitch: 0 }; }
  if (name === 'right') { return { yaw: Math.PI / 2, pitch: 0 }; }
  if (name === 'top') { return { yaw: 0, pitch: 1.52 }; }
  if (name === 'bottom') { return { yaw: 0, pitch: -1.52 }; }
  if (name === 'iso') { return { yaw: 0.7, pitch: 0.5 }; }
  return null;
}

function viewPresetLabel(name: string): string {
  if (name === 'front') { return '前'; }
  if (name === 'back') { return '后'; }
  if (name === 'left') { return '左'; }
  if (name === 'right') { return '右'; }
  if (name === 'top') { return '顶'; }
  if (name === 'bottom') { return '底'; }
  return '等轴';
}

// 模型在盘面坐标系下的水平包围盒（XZ 平面）
class BoundsXZ {
  minX: number = 0;
  maxX: number = 0;
  minZ: number = 0;
  maxZ: number = 0;
}

// 「整理摆放」用的中间项：对象 + 它在盘面上的水平外框（宽/深 + 左下角）
class FootprintItem {
  inst: ModelInstance | null = null;
  w: number = 0;
  d: number = 0;
  minX: number = 0;
  minZ: number = 0;
}

// 「前台恢复」记账（用具名类而非匿名对象字面量，满足 ArkTS 静态类型）
class ResumeCounts {
  chunks: number = 0;   // 遍历到的切片块数（每块 = 连续 this.chunkLayers 层）
  geoms: number = 0;    // 重新贴上材质的路径几何个数
}

// 向量小工具
function v3sub(a: Vec3, b: Vec3): Vec3 { return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z }; }
function v3add(a: Vec3, b: Vec3): Vec3 { return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }; }
function v3mul(a: Vec3, k: number): Vec3 { return { x: a.x * k, y: a.y * k, z: a.z * k }; }
function v3dot(a: Vec3, b: Vec3): number { return a.x * b.x + a.y * b.y + a.z * b.z; }
function v3cross(a: Vec3, b: Vec3): Vec3 {
  return { x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x };
}
function v3len(a: Vec3): number { return Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }

// 点到线段的屏幕距离
function distSeg(px: number, py: number, a: Vec2, b: Vec2): number {
  const abx: number = b.x - a.x;
  const aby: number = b.y - a.y;
  const l2: number = abx * abx + aby * aby;
  let t: number = l2 > 1e-6 ? ((px - a.x) * abx + (py - a.y) * aby) / l2 : 0;
  t = Math.max(0, Math.min(1, t));
  const dx: number = px - (a.x + abx * t);
  const dy: number = py - (a.y + aby * t);
  return Math.sqrt(dx * dx + dy * dy);
}

// 从选择器返回的 URI 还原原始文件名（去掉查询/片段并做百分号解码）
function fileNameFromUri(uri: string): string {
  let s: string = uri;
  const q: number = s.indexOf('?');
  if (q >= 0) { s = s.substring(0, q); }
  const h: number = s.indexOf('#');
  if (h >= 0) { s = s.substring(0, h); }
  const slash: number = s.lastIndexOf('/');
  let name: string = slash >= 0 ? s.substring(slash + 1) : s;
  try {
    name = decodeURIComponent(name);
  } catch (e) {
    // 解码失败则保留原串
  }
  return name.length > 0 ? name : 'model';
}

// 托盘 STL 原始盘面尺寸（mm）——不同机型按此比例缩放
const BED_STL_SIZE: number = 256;

// 单喷嘴专属区【贴图】相关（本机实测 Material.blend 真 alpha 会让物体整片消失 → 走「烘进贴图」方案）：
// 把「半透明绿 + 板面网格 + 竖排白字」画进一张不透明 PNG，贴到板面上（视觉等同半透明，且随板面变换）。
// 带太窄（如 H2C 右带 5mm）时文字会糊成一团 → 不画字，只保留色块（不为了塞字把带画宽）。
const ZONE_LABEL_MIN_BAND: number = 12;
// 贴图像素：带长方向固定该像素数，带宽方向按同一比例换算（保证网格线在贴图里间距正确）。
const ZONE_TEX_LONG_PX: number = 1024;
// 贴图配色：带底色 = 品牌绿 accent 以约 32% 叠在深色板面上的合成观感（「半透明绿」）；网格线近白；文字纯白。
const ZONE_BAND_HEX: string = '#3D7B6D';
const ZONE_GRID_HEX: string = '#DCE6E2';
const ZONE_TEXT_HEX: string = '#FFFFFF';

// 非当前盘的模型：移到视锥外隐藏（ArkGraphics3D 的 Node 没有 enabled，只能位移）
const HIDDEN_POS: Vec3 = { x: 1e6, y: 1e6, z: 1e6 };

// =============================================================================
// 3D 预览页：Component3D + ArkGraphics3D 渲染，C++ 仅做网格解析。
// 多模型：每个模型 = 容器节点（平移）+ 网格节点（旋转/缩放），支持单独编辑。
// 手势：单指旋转视角 / 双指缩放 / 双指平移；选面模式支持鼠标悬停高亮 + 点击选面。
// =============================================================================
@Component
export struct ModelPreviewPage {
  @State sceneReady: boolean = false;
  @State modelInfoText: string = '初始化中…';
  @State loading: boolean = false;
  @StorageLink('selectedModelId') @Watch('onSelectedChanged') selectedModelId: number = -1;
  @StorageLink('modelRevision') @Watch('onModelRevision') modelRevision: number = 0;
  @StorageLink('focusModelSeq') @Watch('onFocusModel') focusModelSeq: number = 0;
  @StorageLink('modelPlates') plates: PlateMeta[] = [];
  @StorageLink('activePlate') @Watch('onActivePlateChanged') activePlate: number = -1;
  @StorageLink('plateW') @Watch('onPlateChanged') plateW: number = 256;
  @StorageLink('plateH') @Watch('onPlateChanged') plateH: number = 256;
  // 盘面重建代次（切机型时由参数面板自增）：即使 plateW/plateH 与上一机型相同，也能触发重建。
  @StorageLink('plateRev') @Watch('onPlateChanged') plateRev: number = 0;
  // 该机型的开源打印板模型名（预设 bed_model）+ 单喷嘴专属区 JSON（由 extruder_printable_area 真值算得）。
  @StorageLink('plateBedModel') plateBedModel: string = '';
  @StorageLink('plateZones') plateZones: string = '';
  // 当前内核打印机预设名：板形/单喷嘴区日志带机型自证（同尺寸换机型也能各自出一条）。
  @StorageLink('platePrinter') @Watch('onPlateChanged') platePrinter: string = '';
  @StorageProp('gcodeShow') @Watch('onGcodeState') gcodeShow: boolean = false;
  // ---- 前台恢复信号 ----
  // EntryAbility.onForeground / windowStageEvent(ACTIVE/RESUMED/SHOWN) / 页面 onPageShow 都会自增该序号。
  // @Watch 一旦触发就重贴材质：失焦 / 前后台切换会重建渲染表面，已缓存的 materialOverride 随之丢失，
  // 几何回落到引擎默认材质 → 变灰（切片路径与打印板是同一机制）。绝不因此重置层可见性。
  @StorageLink('renderResumeSeq') @Watch('onRenderResume') renderResumeSeq: number = 0;
  @StorageLink('renderResumeSrc') renderResumeSrc: string = '';

  // ---- 页面可见性开关（由 Index 的「切页保活」驱动）----
  // 为什么需要它：Index 已把本页从条件渲染改成 .visibility() 切换 —— 组件【不再被销毁】，
  // 于是「不可见期间仍在跑的周期性工作」（扫层定时器 / 后台补建 / 日志 flush / 「渲染中」广播 /
  // 越界脉冲动画）必须由这个开关显式暂停，恢复可见时再恢复，且状态自洽（不留下半途的定时器）。
  // 注意：它只控制「工作暂停」，【绝不】用来销毁引擎 —— 场景/相机/材质必须一直留着。
  @Prop @Watch('onPageVisibleChanged') pageVisible: boolean = true;
  // 切片路径态（previewMode=1）时置真：本页不再画右侧竖排盘列表 —— 那一份改由 Index 渲染在
  // GcodePreview 覆盖层【之上】（否则它被覆盖层吃掉点击、在切片路径态点不到），避免两份同时可见。
  @Prop hidePlateList: boolean = false;
  // 「准备」页是否可见（由 Index 传入：activeTab === 0）。
  // 为什么需要它：Index 把本页从条件渲染改成「保活 + visibility」后组件【不再被销毁】——
  // 用户在准备页开着旋转/缩放/移动手柄直接切到预览页时，手柄会跟着留在预览页上（残留）。
  // 切走准备页即把编辑工具收起（tool 归 0 + 销毁手柄），回来时工具栏是关闭态。
  @Prop @Watch('onPrepareVisibleChanged') prepareVisible: boolean = true;
  // 已因「不可见」暂停过周期性工作（幂等去重，避免重复暂停/重复恢复）
  private pausedByHidden: boolean = false;

  // 编辑控件显示值（选中模型变化时由 onSelectedChanged 同步）
  @State pickFaceMode: boolean = false; // 选面模式：点击模型面使其朝下

  // ---- 需求 2：顶部工具抽屉（导入/重置视角 + 数值编辑 + 旋转/缩放/移动 工具）----
  // 默认【展开】：需求要求「打开软件时默认展开工具栏」，即每次启动都展开。
  // 因此启动初始状态固定为展开，【不再】用持久化值决定（抽屉开关的持久化已整体移除，
  // 见 toggleTopDrawer / 历史 ui_top_drawer.json —— 移除原因：值不再被读取，留着即死代码）。
  // 展开时抽屉浮在视口之上（overlay，不参与布局 → 不改变视口高度）；会话内可自由收起/展开。
  @State topDrawerOpen: boolean = true;

  // ---- 载入弹窗（大模型载入进度）----
  @State private dlgVisible: boolean = false;
  @State private dlgModel: LoadDlgModel = new LoadDlgModel();
  private loadCloseTimer: number = -1;    // 入场景后的延迟关窗 / 收尾保险
  private loadSettled: boolean = false;   // onDone 已到：数值状态之后不再被迟到进度改动（日志仍逐条收下）
  private loadStartedMs: number = 0;
  private loadProgressCount: number = 0;  // 已收到的进度事件条数（诊断：0 = TSFN 根本没通）
  // ---- 进度处理：日志流与数值状态彻底分开（这是「日志只剩十几条 / 百分比跳跃」的根治点）----
  // appliedStage 记录已渲染到的阶段，用于识别「阶段切换」这类关键进度（关键项立即渲染、不排队）；
  // pendingNumeric 只保留最新一条普通进度的数值（数值合并 = 合理）；
  // pendingLogs 是「待渲染日志队列」，每条普通进度都入队、一条都不丢；渲染时机由 flushTimer
  //   统一按 LOG_FLUSH_INTERVAL_MS 的固定节奏合并 flush（累积的多行一次性加入）；
  // flushTimer 已排定时器 id（-1 = 未排），避免重复排；lastFlushMs 记录上次真正渲染的时刻；
  // logReceived/logRendered/logDropped 是收尾统计用的真实计数（收到 = 已渲染 + 丢弃 + 队列残留）。
  private appliedStage: number = -1;
  private pendingNumeric: ProgressMsg | null = null;
  private pendingLogs: ProgressMsg[] = [];
  private flushTimer: number = -1;
  private lastFlushMs: number = 0;
  private logReceived: number = 0;
  private logRendered: number = 0;
  private logDropped: number = 0;
  private statsLogged: boolean = false;

  // 操作工具：0 无 / 1 旋转 / 2 缩放 / 3 移动
  @State tool: number = 0;
  // 布尔运算是同步内核调用：耗时期间禁用按钮，避免连点
  @State booleanBusy: boolean = false;
  // ---- 框选（工具 4）----
  // 选择矩形：视口本地 vp 坐标 [x0,y0,x1,y1]。框选不画手柄（手柄只服务单对象的精确变换）。
  @State selBoxOn: boolean = false;
  @State selBox: number[] = [0, 0, 0, 0];
  private boxDragging: boolean = false;
  // ---- 多选整体变换的「拖拽起始基线」（按对象 id 存；单选时只有一条）----
  // 为什么按 id 存基线：拖拽每一帧都要由「起始值 + 增量」算出**绝对**目标值，
  // 若拿当前值累加会复利（缩放手感会失控、多选时尤其明显）。
  private dragBasePos: Map<number, Vec3> = new Map<number, Vec3>();
  private dragBaseRot: Map<number, Vec3> = new Map<number, Vec3>();
  private dragBaseScale: Map<number, number> = new Map<number, number>();
  private dragBaseComp: Map<number, number> = new Map<number, number>();
  @State scaleLocked: boolean = true; // 缩放锁定：true 等比，false 每轴独立
  // 数值面板输入框文本
  @State inScale: string = '100';
  @State inDimX: string = '0';
  @State inDimY: string = '0';
  @State inDimZ: string = '0';
  @State inRotX: string = '0';
  @State inRotY: string = '0';
  @State inRotZ: string = '0';
  @State inPosX: string = '0';
  @State inPosY: string = '0';
  @State inPosZ: string = '0';
  // 手柄增量输入
  @State deltaAxis: string = '';
  @State deltaText: string = '';

  // 左下角模型信息 HUD（体积 + X/Y/Z 实际尺寸）
  @State hudVisible: boolean = false;
  @State hudX: string = '0.00';
  @State hudY: string = '0.00';
  @State hudZ: string = '0.00';
  @State hudVol: string = '0.00';
  // 越界警示（模型超出盘面时，3D 视口红光闪烁）
  @State outOfBounds: boolean = false;
  @State warnText: string = '';
  @State warnAlpha: number = 0;
  private readonly boundsEps: number = 0.05; // 判定容差（mm），刚好贴边不算越界

  // ---- 需求 4：悬空/支撑告警（右上角，黄色闪烁）---------------------------------
  // 判定来自原生侧解析时的启发式统计；是否「显示」还要看支撑开关（开启支撑 → 不提示）。
  @State supportNeeded: boolean = false;       // 启发式结论：该模型需要支撑
  @State supportWarnShow: boolean = false;     // 最终是否显示告警（= 需要支撑 且 支撑未启用）
  @State supportWarnAlpha: number = 0;         // 黄色脉冲动画的透明度（animateTo iterations:-1 驱动）
  @State overhangRatioPct: number = 0;         // 朝下悬空面面积占比（%，真实统计值）
  @State overhangAngleDeg: number = 0;         // 判定用到的夹角阈值（度）
  @State overhangAreaPctThr: number = 0;       // 面积占比判定阈值（%）
  private supportPulseOn: boolean = false;     // 脉冲动画是否在跑（幂等去重；隐藏页暂停要用）
  private supportLoggedState: string = '';     // 已记过日志的状态组合（避免参数面板每改一次就写一次诊断文件）

  // 参数变化代次（由 DynamicParamsPanel 在改值时自增）：改支撑开关后立即重算告警。
  @StorageProp('paramRevSeq') @Watch('onParamRevChanged') paramRevSeq: number = 0;
  // 光感设置（全局，设置页可调）
  @StorageLink('glowBg') @Watch('onGlowBgChanged') glowBg: number = 1.0;
  @StorageLink('glowHandle') @Watch('onGlowHandleChanged') glowHandle: number = 1.0;
  // ---- 渲染开销 A/B 开关（日志页「渲染开关（调试）」面板写入；本页订阅后立即应用到场景）----
  // 为什么走 AppStorage 而不是组件回调：面板在「日志」页（条件渲染，随时会被销毁重建），
  // 而 3D 场景页常驻；AppStorage 是两者都能订阅、且改完即响应的唯一现成通道。
  // 【默认值刻意等于改动前的当前值】（MSAA 开 / Bloom 开 / Vignette 开 / 剔除 NONE /
  // 范围=仅切片路径）：装上后画面与行为与旧版完全一致，A/B 由用户自己拨，不给「已优化」的默认。
  @StorageLink('rtMsaa') @Watch('onRenderTuneChanged') rtMsaa: boolean = true;
  @StorageLink('rtBloom') @Watch('onRenderTuneChanged') rtBloom: boolean = true;
  @StorageLink('rtVignette') @Watch('onRenderTuneChanged') rtVignette: boolean = true;
  @StorageLink('rtCullBack') @Watch('onRenderTuneChanged') rtCullBack: boolean = false;
  @StorageLink('rtScopeAll') @Watch('onRenderTuneChanged') rtScopeAll: boolean = false;
  private envBase: Vec3 = { x: 0.38, y: 0.38, z: 0.42 };
  private sunLight: Light | null = null;
  private fillLight: Light | null = null;
  private readonly baseSun: number = 3.0;
  private readonly baseFill: number = 1.1;
  private readonly baseClear: Color = { r: 0.60, g: 0.72, b: 0.88, a: 1.0 }; // 视口背景：浅蓝
  // 手柄纯色（Unlit，高饱和；亮度由「手柄发光」控制，>1 触发 bloom 泛光）
  private gizmoHue: Vec3[] = [
    { x: 1.0, y: 0.06, z: 0.04 },
    { x: 0.10, y: 1.0, z: 0.14 },
    { x: 0.06, y: 0.28, z: 1.0 },
  ];
  private gizmoRoot: Node | null = null;
  private gizmoSeq: number = 0;
  // 手柄拖拽的「事件合并」状态：指针事件频率可能远高于渲染帧率（触摸屏可达 120~240Hz），
  // 每个事件都做一遍「模型变换 + 手柄变换」= 同一帧内重复写场景 → 拖动发卡。
  // 只记最新坐标，按 ~16ms 合并成一次更新。
  private dragPx: number = 0;
  private dragPy: number = 0;
  private dragScheduled: boolean = false;
  private gizmoArm: number = 30; // 手柄臂长（用于拖拽换算）
  private readonly fovY: number = 0.72; // 透视基准视场角（rad）；实际送进相机的是 effFov()（近正交下按其压缩）
  // 手柄拖拽状态
  private dragAxis: string = '';
  private dragS0: number = 0;           // 拖拽起始时指针在轴上的投影
  // 移动拖拽的**固定参考点**（拖拽开始时的模型中心）。
  // 【为什么必须有】轴上的投影距离必须相对一个「不动的」参考点算：若用当前模型中心，
  // 移动改变中心 → 下一帧算出的距离又变 → 位置被反复推回，表现就是「反复抽搐」。
  private dragCenter0: Vec3 = { x: 0, y: 0, z: 0 };
  private dragPos0: Vec3 = { x: 0, y: 0, z: 0 };
  private dragRot0: Vec3 = { x: 0, y: 0, z: 0 };
  private dragScale0: number = 1;
  // 缩放拖拽（解锁/单轴）：起始时**该轴的分量**。
  // 【为什么必须有】用「当前分量」当基数会导致每帧自我复利：k = 当前分量 × f，
  // 而当前分量每帧都被上帧改过 → 指针不动也连乘，表现就是「缩到一定程度突然极小、
  // 反向拉也继续缩」（与移动拖拽的自反馈同一类 bug；锁定分支用的是 dragScale0 所以不犯）。
  private dragComp0: number = 1;
  private dragCenterScreen: Vec2 = { x: 0, y: 0 }; // 手柄中心投影到屏幕
  private dragD0: number = 40;          // 缩放拖拽：起始屏幕半径
  private dragPrevAngle: number = 0;    // 旋转拖拽：上一帧指针角
  private dragAccAngle: number = 0;     // 旋转拖拽：累计角度（弧度）
  private dragRotSign: number = 1;      // 旋转拖拽方向符号

  private viewW: number = 1;
  private viewH: number = 1;

  // ---- 需求：顶部抽屉「随内容自适应高度」所需的状态 ----
  // 真因说明：抽屉面板原来的 .constraintSize({ maxHeight: Math.max(120, this.viewH - 88) }) 里，
  //   viewH 是【普通字段】。ArkUI 只会重算「依赖了被观察状态(@State 等)」的视图节点；这个 Scroll 节点
  //   对 viewH 没有任何可观察依赖，于是它只在【初始渲染】时算过一次高度上限——那一刻视口尚未 onAreaChange，
  //   viewH 还是初值 1 → max(120, 1-88)=120 被永久固化。导入后新增的行由内部 if 分支单独刷新，
  //   而 Scroll 自身的高度上限一直停在 120，所以只露出「尺寸 / 旋转」两行，其余被裁掉。
  // 修法：把面板高度做成 @State（panelH），由内容自然高与「视口可用高上限」取小、经 animateTo 平滑驱动，
  //   高度一变就必然驱动面板重排（因为节点依赖了 @State）。
  @State private panelH: number = 0;
  // 面板内容自然高度（由内容 Column 的 onAreaChange 采集）。Scroll 以主轴无界测量子节点，
  // 因此这里拿到的是「未被上限裁剪的真实内容高」，用它做「内容不足上限时的高度自适应」。
  private contentNaturalH: number = 0;

  private scene: Scene | null = null;
  private factory: SceneResourceFactory | null = null;
  private camera: Camera | null = null;
  private worldNode: Node | null = null;   // 外层：只做平移（旋转恒为单位，避免平移被旋转影响）
  private pivotNode: Node | null = null;   // 内层：绕锚点旋转（模型/底板都在其下）
  private modelMaterial: MetallicRoughnessMaterial | null = null;
  // 每个对象一份材质（按 id 缓存）。颜色写在各自材质上 -> 改一个对象的颜色互不影响，
  // 且只改 baseColor.factor（属性），不重建几何 / 不重解析网格。
  private modelMats: Map<number, MetallicRoughnessMaterial> = new Map<number, MetallicRoughnessMaterial>();
  // 对象默认显示色（= 原有 PBR 橙）：对象没设过 displayColor 时用它，保证打开不变色
  private readonly defaultModelRgb: Vec3 = { x: 0.95, y: 0.45, z: 0.13 };
  private highlightMat: UnlitMaterial | null = null;
  private gizmoMats: Material[] = []; // [X红, Y绿, Z蓝]（自发光）
  private plateNode: Node | null = null;              // 打印板容器（床板 + 网格 + 边框 + 单喷嘴区）
  private plateBedNode: Geometry | null = null;       // 床板几何（前台恢复时重贴 bedMat）
  private plateGridNode: Geometry | null = null;      // 网格几何（前台恢复时重贴 gridMat）
  private plateBorderNode: Geometry | null = null;    // 边框几何（前台恢复时重贴 borderMat）
  private nozzleEdgeNode: Geometry | null = null;     // 单喷嘴专属区【边框】几何（无专属区时为 null）
  private zoneNodeL: Geometry | null = null;          // 左带【贴图面片】几何（板底色+网格+半透明绿+竖排白字，贴板面）
  private zoneNodeR: Geometry | null = null;          // 右带【贴图面片】几何
  // 单喷嘴区【填充 + 文字】贴图材质（Unlit + baseColor.image）：本机实测 Material.blend 真 alpha 会让物体整片消失，
  // 故改用【不透明贴图】——把「半透明绿 + 板面网格 + 竖排白字」直接烘进贴图（视觉等同半透明，见 Theme.zoneBand）。
  private zoneTexMatL: UnlitMaterial | null = null;
  private zoneTexMatR: UnlitMaterial | null = null;
  private nozzleEdgeMat: UnlitMaterial | null = null; // 边框材质（Unlit 更亮品牌绿，不透明）
  private bedBaseGeom: MeshGeometry | null = null;    // 当前机型的板模型几何（按盘面尺寸缩放复用）
  private bedGeomFor: string = '';                    // bedBaseGeom 对应的板模型名（换机型要重取）
  private bedPlateW: number = BED_STL_SIZE;           // 当前板模型自身包围盒 X 尺寸（mm）
  private bedPlateH: number = BED_STL_SIZE;           // 当前板模型自身包围盒 Y 尺寸（mm）
  private bedPlateSrc: string = '';                   // 当前板模型来源（bed_model 名 / 内置兜底）
  // 当前板模型在【绝对床坐标】里的包围盒（mm）：把绝对床坐标映射到与板模型同一坐标系用。
  // 内置兜底板无绝对信息 → 退化为以原点为中心的对称包围盒（即不引入额外偏移）。
  private bedBBoxMinX: number = -BED_STL_SIZE * 0.5;
  private bedBBoxMinY: number = -BED_STL_SIZE * 0.5;
  private bedBBoxMaxX: number = BED_STL_SIZE * 0.5;
  private bedBBoxMaxY: number = BED_STL_SIZE * 0.5;
  private bedMat: MetallicRoughnessMaterial | null = null;
  private gridMat: UnlitMaterial | null = null;
  private borderMat: UnlitMaterial | null = null;
  private lastPlateW: number = 256;
  private lastPlateH: number = 256;
  private lastPlateRev: number = -1;                  // 上次已重建对应的 plateRev（同尺寸换机型也要重建）
  private lastPlateModel: string = '';                // 上次已重建对应的板模型名（板模型变化即重建）
  private lastPlatePrinter: string = '';              // 上次已重建对应的机型名（机型变化即重建）
  private plateShapeLogged: string = '';              // 板形日志去重（键含机型+板模型+请求模型）
  private nozzleLogged: string = '';                  // 单喷嘴区日志去重（键含机型）
  private zoneBoundsLogged: string = '';              // 单喷嘴区矩形数值（绝对/内容坐标）供日志与自证
  // 单喷嘴专属区左右带宽度（mm，真值来自 extruder_printable_area；用于日志逐机核对）
  private zoneLeftWidth: number = 0;
  private zoneRightWidth: number = 0;
  // 左右专属带在【内容坐标】里的中心（mm）：X 为带宽方向中心，Z 为带长方向中心；浮层文字投影用
  private zoneLeftCenterX: number = 0;
  private zoneRightCenterX: number = 0;
  private zoneLeftCenterZ: number = 0;
  private zoneRightCenterZ: number = 0;
  private zoneLeftHalfW: number = 0;   // 左带在内容坐标里的半宽（mm）
  private zoneRightHalfW: number = 0;  // 右带在内容坐标里的半宽（mm）
  // 左/右专属区在【内容坐标】的矩形（与 computeFootprint 的包围盒同一坐标系），供相交检测复用。
  // null = 无该侧专属区（单喷嘴机型 / 未取到数据）→ 不参与判定。
  private zoneRectL: BoundsXZ | null = null;
  private zoneRectR: BoundsXZ | null = null;
  // 单喷嘴专属区文字：改成【贴在打印板上的贴图面片】（随板节点一起透视/倾斜），
  // 不再使用视口浮层文字 → 已删除原来的 screen-space 标注状态（zoneXxxLabelXxx）与投影逻辑。
  @State zoneLeftVisible: boolean = false;
  @State zoneRightVisible: boolean = false;
  private plateTimer: number = -1;        // 合并同一轮 plateW/plateH/plateRev 触发
  private plateChain: Promise<void> = Promise.resolve(); // 盘面重建串行链（防并发创建出多块盘面）
  private toolpathRoot: Node | null = null;                        // 切片路径根节点
  // ★【⑤ 时序防御】路径树「存活代次」：destroyToolpath 每次 +1。
  //   构建几何是异步的（createMesh/createGeometry 是长同步 NAPI，期间会让帧）；若在这段 await 里
  //   用户切了盘 / 换了 gcode / 离开预览，destroyToolpath 会把根节点与块节点 destroy 掉，此时
  //   旧引用上的 node.children 变成 undefined —— 继续 append 就抛
  //   "Cannot read property append of undefined"。构建循环持有本轮代次 seq，append 前一律校验，
  //   失效即丢弃本块几何并打日志（绝不只 try/catch 吞掉）。
  private toolpathSeq: number = 0;
  // ---- 分块合并：块的节点 / 可见性 / 记账 --------------------------------------------
  // 每块 = 连续 this.chunkLayers 层（粒度由总层数一次性决定，见文件顶部常量）；
  // 块内每角色只有一个几何（= 一次绘制）。
  private chunkLayers: number = GCODE_CHUNK_SMALL;                 // 当前块大小（1/4 层；本次 gcode 载入时一次性定死）
  // 「粒度是为哪一份 gcode 定的」：等于 gcodeToolpath.generation 时表示本份 gcode 已定好粒度、不再改变。
  // 换 gcode（generation 变化）才会重新按总层数定一次 —— 这就是「一次性决定」的全部实现。
  private chunkLayersGen: number = -1;
  // 「上一次刷新前是否发生过销毁重建」：destroyToolpath 里置 true，applyLayerVisibility 的验收日志读走并复位。
  // 拖动期间这个值必须恒为 false（这正是本轮要证明的「无重建」）。
  private rebuiltSinceLastVisLog: boolean = false;
  private chunkNodes: Node[] = [];                                 // 每块一个节点（可见性即「看到第几块」）
  private builtLayers: number = 0;                                 // 已建好的层数（已并入块或仍在本块累积），懒建只增不减
  private lastVisChunks: number = 0;                               // 上次已应用到场景的「可见块数」（增量更新的基准）
  private chunkParts: number[] = [];                               // 每块的角色几何数（= 该块批次数），只用于 GcodePerf 验收日志
  private chunkLayerCounts: number[] = [];                         // 每块实际并入的层数（自证：块内层数 = N，合计 = 应有层数）
  // 每块「已成功挂上」的角色几何与其 slot（slot = role + 1），二者顺序一一对应。
  // 前台恢复要按角色重贴 materialOverride；而 children 取出来只有 Node 类型（无法静态转成
  // Geometry 去写 mesh），所以这里显式登记几何引用与对应 slot —— 绝不靠节点名反解（改名/重名会串色）。
  private chunkGeomNodes: Geometry[][] = [];
  private chunkSlots: number[][] = [];
  // 当前这块「还没凑满 N 层、因此还没收尾」的每角色累积几何：下标 = role。
  // 逐层几何按角色拼进来（顶点/法线数组相接、索引按顶点基址偏移），凑满 N 层后建成块几何并立刻清空。
  // 累计式拼接而不是「每加一层就重拼整块」——后者是 O(n²)，会把建几何耗时拖垮。
  // ★【槽位数必须 = 角色档数 = 11】role ∈ [0,10]（0 外壁 … 10 辅助线），下标 = role，故需要 11 个槽。
  //   曾经只开了 10 个槽 → role 10「辅助线」的下标 10 越界，块合并时被整段丢弃（日志可见
  //   `PreviewWarn: 块合并槽位越界 slot=11 → 跳过该段`），切片预览里辅助线因此不并入块几何。
  private pendingParts: (MeshGeometry | null)[] =
    [null, null, null, null, null, null, null, null, null, null, null];
  private gcodeVertCount: number = 0;                              // 已建路径几何的真实顶点数（记账，只用于 GcodePerf 验收日志）
  private perfTick: number = 0;                                    // GcodePerf 日志节流计数（不每帧刷屏）
  // ---- 真实帧率统计（口径：displaySync 的 VSync 逐帧回调）-----------------------
  // fpsLast = 最近一个完整 1 秒窗口的平均 FPS；结果同时写进 AppStorage('rtFps') 供日志页面板显示。
  // 只在页面可见时统计（隐藏时暂停，与「隐藏页暂停」一致）；不可见期间的残留值即「最后一次实测」。
  private fpsSync: displaySync.DisplaySync | null = null;
  private fpsWindowStartNs: number = 0;   // 统计窗口起点（ns；0 = 还没建立基准）
  private fpsWindowFrames: number = 0;    // 本窗口内累计帧数
  private fpsLast: number = 0;            // 最近 1 秒平均 FPS（0 = 还没测到）
  private appliedShadowSamples: number = -1;                       // 已应用的阴影档位（去重：模式切换不重复设置）
  private renderFlag: boolean = false;                             // 上次广播的「渲染中」标志（避免重复写 AppStorage）
  private lastGcodeGen: number = -1;                               // 上次建几何对应的解析代次
  // 路径材质（下标 = role，对应 slot-1）。元素允许 null：某一档创建失败时保留占位，
  // 保证下标与 role 严格对齐（错位会让角色串色，比缺一个材质更糟）；取用处统一走 roleMaterialFor。
  private roleMats: (Material | null)[] = [];
  // 路径材质的显式兜底：越界 / 材质尚未就绪时用它，**绝不**让绑定落到引擎默认材质。
  // 为什么特意用洋红而不是「其他」档的灰：引擎默认材质本身就是一种不可控的灰，
  // 若兜底也用灰，一旦真出现越界就与「顶面变灰」这种故障现象混在一起、肉眼与日志都难区分。
  // 洋红是 3D 里约定俗成的「缺失材质」哨兵色，一眼就能看出「某段路径没拿到自己的材质」。
  private fallbackMat: MetallicRoughnessMaterial | null = null;
  // 打印板/网格/边框的材质（场景资产）。单独收起来，运行时任何改色路径都禁止写它们。
  private plateMats: Material[] = [];
  private plateMatGuardLogged: boolean = false;                    // 打印板材质被误改的告警去重
  // 越界兜底告警去重：key = 越界原因（如 "slot=0"），value = 累计次数（避免同一越界刷屏）。
  private oobMatCounts: Map<string, number> = new Map<string, number>();
  // 已输出 [GcodeDiag] 诊断块的解析代次：每个 gcode（generation）只输出一块，不逐层/逐帧刷。
  private diagGen: number = -1;
  private gcodeTimer: number = -1;
  private gcodeBusy: boolean = false;      // 正在重建路径几何
  private gcodeDirty: boolean = false;     // 重建期间又来了新请求（只保留最后一次）
  private prebuildTimer: number = -1;      // 后台补齐剩余层几何
  // ---- 扫层（进入预览时自下而上逐层揭示）----
  private sweepTimer: number = -1;         // 扫层定时器（setInterval）
  private sweepActive: boolean = false;    // 扫层动画进行中（含到顶后等几何补建的那一段）
  private sweepAwaitingEnd: boolean = false; // 扫层已到顶，但几何还没建完，等建完那一拍收尾
  private sweepCur: number = 0;            // 扫层当前揭示到的层数（供滑条 / Z 值显示）
  private sweepChunks: number = 0;         // 扫层当前已揭示的「块」数（每拍 +1；可见性最小步进 = 一块）
  private sweepChunkTotal: number = 0;     // 总块数 = ceil(总层数 / this.chunkLayers)
  private sweepIntervalMs: number = SWEEP_TICK_MS; // 本轮每拍间隔（按块数重算，保持总时长 ≈1.4s）
  private nodes: Map<number, Geometry> = new Map<number, Geometry>();
  private containers: Map<number, Node> = new Map<number, Node>();
  private pendingIds: Set<number> = new Set<number>(); // 正在异步创建场景节点的模型 id（防重复创建）
  // 节点绑定的是哪一份几何：同一 id 的几何被整体替换（布尔 / 撤销重做 / 整理摆放回退）时，
  // nodes 里已有 id 不代表画面正确 —— 必须按引用比对，不一致就重建节点。
  private nodeGeom: Map<number, MeshGeometry> = new Map<number, MeshGeometry>();
  private lastModelMaxDim: number = 362; // 默认按底板对角线取景

  // 悬停高亮状态
  private highlightNode: Geometry | null = null;
  private highlightTri: number = -1;
  private hlSeq: number = 0;
  private hoverBusy: boolean = false;
  // 拖动（旋转视角/平移）结束后短暂抑制点击选面，避免松开鼠标时误选面
  private suppressTapUntil: number = 0;
  private dragging: boolean = false;      // 本次手势是否处于拖动中
  private readonly panLimit: number = 180; // 摄像机平移边界（mm）

  // 相机/视角状态（轨道相机：相机绕 target 旋转，target 始终在屏幕中心）
  private yaw: number = 0.7;
  private pitch: number = 0.5;
  private dist: number = 480;
  private target: Vec3 = { x: 0, y: 0, z: 0 }; // 屏幕中心对应的世界点（旋转锚点）
  // ---- 视图预设 / 近正交（Phase 3）----
  // 正交投影的现实：ArkGraphics3D 的 Camera 只有透视字段（fov/nearPlane/farPlane，无正交模式），
  // 所以走「退化实现」——把相机推远 + 把 fov 压小。关键约束是**取景必须不变**：
  // 透视投影里屏幕尺寸 ∝ tan(fov/2)/眼距，所以让 tan(fov/2) 缩小 k 倍、眼距放大 1/k 倍，
  // 画面构图完全不动，只有透视收缩变弱（k 越小越接近正交）。
  // 副作用：pan/zoom/autoFit 全部沿用「用户视角」的 dist（上面那个），不需要改。
  @State orthoLike: boolean = false;         // true = 近正交（相机推远 + 小 fov）
  private readonly orthoK: number = 1 / 6;   // 视场角压缩比（1/6 ≈ 7.2°，透视收缩约削弱 6 倍）
  private presetTimer: number = -1;          // 视图预设插值动画定时器（setInterval 16ms）
  // 手势增量基准
  private lastRotateX: number = 0;
  private lastRotateY: number = 0;
  private lastPinchScale: number = 1;
  private lastPanX: number = 0;
  private lastPanY: number = 0;

  // 沉浸光感卡片材质（与项目其他面板风格一致）
  private cardMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THICK,
    materialColor: '#1A1F2733',
    applyShadow: true,
    interactive: true,
    lightEffect: { color: '#00C48C' },
  });

  aboutToAppear(): void {
    if (AppStorage.get<ModelFile[]>('modelObjects') === undefined) {
      AppStorage.setOrCreate<ModelFile[]>('modelObjects', []);
    }
    if (AppStorage.get<number>('selectedModelId') === undefined) {
      AppStorage.setOrCreate<number>('selectedModelId', -1);
    }
    // 顶部工具抽屉：启动即展开（见 topDrawerOpen 默认值），不再读取持久化。
    this.initScene();
    // 首帧就不可见（正常启动是准备页，恒为可见；这里只是兜底）→ 直接进入暂停态
    if (!this.pageVisible) {
      this.pauseHiddenWork();
    }
  }

  // ---- 需求 2：顶部工具抽屉 —— 开关（带动画）--------------------------------------
  private toggleTopDrawer(): void {
    // 用 animateTo 驱动展开/收起过渡：面板是「常驻挂载」的（见 topToolDrawer），
    // 状态一翻转，其 .opacity(0↔1) 与 .translate.y(-8↔0) 就按这条时长/曲线做隐式动画
    // —— 打开与关闭都走这条路径，两个方向都有过渡（条件渲染无法做关闭动画，故已改常驻）。
    // 只驱动 opacity + 位移两个属性，不发散成弹跳/旋转，也不触碰几何/扫层（见「必须保留」约束）。
    this.getUIContext().animateTo({ duration: TOPDRAWER_ANIM_MS, curve: Curve.EaseOut }, () => {
      this.topDrawerOpen = !this.topDrawerOpen;
    });
    this.writeTopDrawerLog(`顶部工具抽屉 ${this.topDrawerOpen ? '展开' : '收起'}`);
  }

  // 抽屉自证日志：hilog + 应用内日志（新增 tag，不改既有 tag）
  private writeTopDrawerLog(text: string): void {
    hilog.info(0x0000, TOPDRAWER_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${TOPDRAWER_TAG}] ${text}`);
    } catch (e) {
      hilog.error(0x0000, TOPDRAWER_TAG, '抽屉日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 抽屉面板「视口可用高」上限 = 视口高 − 顶部偏移 − 底部留白。
  //   顶部偏移 = 触发条(上边距 12 + 高 34 = 46) + 面板容器上边距 12 = 58；
  //   底部留白 30 → 合计 88。面板下缘 = 视口底 − 30，绝不压到底部 SliceBar。
  // 这里取的是【当前真实视口高】(this.viewH 由 3D 视口 onAreaChange 实时采集)：导入 / 切页 / 旋转屏后
  // 视口区域变化 → onAreaChange 再次触发 → 上限按新值重算（旧实现把上限固化成常量，正是被裁的真因）。
  private panelCapVp(): number {
    return Math.max(120, this.viewH - 88);
  }

  // 面板高度同步：目标 = min(内容自然高, 视口可用高上限)，用与开合同一条 animateTo(200/EaseOut) 平滑过渡，
  // 高度与开关透明度都不会突兀跳变。
  private syncPanelH(): void {
    // 内容自然高尚未采集到就先不动：等内容的 onAreaChange 回调来驱动，
    // 避免「先按上限撑满、再缩回内容高」的启动闪动。
    if (this.contentNaturalH <= 0) {
      return;
    }
    const cap: number = this.panelCapVp();
    const target: number = Math.min(this.contentNaturalH, cap);
    if (Math.abs(target - this.panelH) < 0.5) {
      return;
    }
    if (this.panelH <= 0) {
      // 首次还没有任何高度（避免「从 0 长出来」的一次突兀动画）：直接落位，之后的变化才走动画。
      this.panelH = target;
    } else {
      this.getUIContext().animateTo({ duration: TOPDRAWER_ANIM_MS, curve: Curve.EaseOut }, () => {
        this.panelH = target;
      });
    }
    this.writeTopDrawerLog(`面板高 ${target.toFixed(0)}（上限 ${cap.toFixed(0)} / 内容 ${this.contentNaturalH.toFixed(0)}）`);
  }

  aboutToDisappear(): void {
    // 页面销毁（现在只在应用整体退出时发生）：先停掉扫层定时器（否则定时器可能在场景销毁后仍回调）
    this.cancelSweep('模型页销毁');
    // 视图预设的插值动画同理：场景都没了，再回调 updateView 只会碰到 null
    if (this.presetTimer !== -1) {
      clearInterval(this.presetTimer);
      this.presetTimer = -1;
    }
    // FPS 统计也要停：回调在场景销毁后没有意义
    this.stopFpsMeter();
    // 场景销毁前把「渲染中」标志复位，别让离开后的残留值继续显示
    AppStorage.setOrCreate<boolean>('gcodeRendering', false);
    if (this.scene !== null) {
      this.scene.destroy();
      this.scene = null;
    }
  }

  // ---------------------------------------------------------------------------
  // 页面可见性：隐藏时暂停空跑，恢复时按状态自洽地恢复
  // ---------------------------------------------------------------------------
  // 背景：条件渲染换成了「保活 + visibility」，组件不再销毁 —— 好处是引擎/场景/材质一直留着，
  // 坏处是「不可见期间还会继续跑的周期性工作」必须显式暂停，否则就是纯空跑（白耗电/白占 UI 线程）。
  private onPageVisibleChanged(): void {
    if (this.pageVisible) {
      this.resumeHiddenWork();
    } else {
      this.pauseHiddenWork();
    }
  }

  // 离开「准备」页（切到预览/设备/校准/日志）：把编辑工具栏与三维手柄一起收起。
  // 见 prepareVisible 字段说明 —— 组件保活不销毁，不显式收就会把旋转/缩放/移动手柄留在预览页上。
  private onPrepareVisibleChanged(): void {
    if (this.prepareVisible) { return; }
    if (this.tool !== 0) {
      this.tool = 0;
      this.deltaAxis = '';
      this.deltaText = '';
    }
    this.clearGizmo();
  }

  // 暂停（幂等）：扫层定时器 / 后台补建 / 重建合并定时器 / 日志 flush / 「渲染中」广播 / 越界脉冲动画。
  // 全部走「可见性开关」而不是超时判定 —— 不新增任何超时。
  private pauseHiddenWork(): void {
    if (this.pausedByHidden) { return; }
    this.pausedByHidden = true;
    this.cancelSweep('页面不可见');
    if (this.prebuildTimer >= 0) { clearTimeout(this.prebuildTimer); this.prebuildTimer = -1; }
    if (this.gcodeTimer >= 0) { clearTimeout(this.gcodeTimer); this.gcodeTimer = -1; }
    // 视图预设插值动画（200ms 一次性）：不可见时直接掐断，别让它在隐藏页里空跑完
    if (this.presetTimer !== -1) { clearInterval(this.presetTimer); this.presetTimer = -1; }
    // 日志 flush 定时器（载入弹窗）：不可见时不排渲染定时器，队列保留，恢复可见时再排（见 resumeHiddenWork）
    if (this.flushTimer !== -1) { clearTimeout(this.flushTimer); this.flushTimer = -1; }
    // 「渲染中」标志立刻复位：不可见期间不该继续显示，也不能残留到下次回来
    this.renderFlag = false;
    AppStorage.setOrCreate<boolean>('gcodeRendering', false);
    // 越界红光脉冲是 iterations:-1 的无限动画：不可见时停掉，恢复可见时按当前状态重启
    if (this.outOfBounds) {
      this.stopWarnPulse();
    }
    // 需求 4：右上角「需要添加支撑」的黄色脉冲同样是 iterations:-1 的无限动画 ——
    // 必须一起停掉，否则隐藏页会一直烧 GPU（这正是「隐藏页暂停」要解决的问题）。
    if (this.supportPulseOn) {
      this.stopSupportPulse();
    }
    // FPS 统计暂停（不可见时没有真实帧可计），但保留「最后一次实测值」给日志页面板看
    this.stopFpsMeter();
    // 离开预览时补一条 [RenderTune] 结算日志：面板在日志页，切走这一刻的 FPS 才是刚看到的稳定值。
    // 只打日志、不重复应用（应用与否对隐藏页无意义）。
    if (this.scene !== null) {
      this.logRenderTune('离开预览结算');
    }
    hilog.info(0x0000, 'PreviewLife', '页面不可见 → 暂停扫层/后台补建/日志flush/渲染中广播/越界脉冲（引擎与场景保留）');
  }

  // 恢复（幂等）：把恢复后可能「半途」的状态补齐 —— 该排的定时器重排、该重启的动画重启。
  private resumeHiddenWork(): void {
    if (!this.pausedByHidden) { return; }
    this.pausedByHidden = false;
    // 进入 3D 页：立即用「所有已加载模型」的结论重算一次悬空告警（不能只在导入瞬间判一次）
    this.refreshSupportWarn('进入3D页', '已加载');
    // 显式把模型变换重写一遍（applyTransform 按当前 gcodeShow 决定：模型态=原位、切片路径态=HIDDEN_POS）。
    // 3D 页从隐藏恢复可见时保证「模型该在就在」，不依赖 gcodeShow 的单次通知时序。
    this.reassertModelVisibility();
    if (this.outOfBounds) {
      this.startWarnPulse();
    }
    // 需求 4：恢复可见 → 告警仍成立才重启黄色脉冲（状态自洽，不留半途动画）
    if (this.supportWarnShow) {
      this.startSupportPulse();
    }
    // FPS 统计恢复：重新建立 1 秒窗口基准（不沿用暂停前的时间戳，否则会把暂停时长算进去）
    this.startFpsMeter();
    // 日志队列里还有没渲染的（不可见期间入的队）→ 重新按固定节奏排一次 flush
    if (this.pendingLogs.length > 0 || this.pendingNumeric !== null) {
      this.scheduleFlush();
    }
    // 切片路径几何的恢复统一由控制层（GcodePreview）在切回可见时驱动（见 resumeGcodeKeepAlive）：
    //   · 保活策略下离开时并未释放 → 回来只需确认几何是否还在（在则收敛可见性，不在则降级重建）；
    //   · 旧策略下离开时已释放、gcodeShow 为假 → 回来由 GcodePreview 走 reload→重建流程。
    // 这里刻意【不】再主动 requestToolpath：否则从「非 3D 页」直接切到准备页 / 模型态（gcodeShow 仍为
    // 保活态 true）时会把路径重新显示出来，与「该页要显示模型」冲突、并制造一帧闪烁。
    hilog.info(0x0000, 'PreviewLife', '页面恢复可见 → 恢复（切片路径=%{public}s 越界=%{public}s）',
      this.gcodeShow ? 'true' : 'false', this.outOfBounds ? 'true' : 'false');
  }

  // 从「保活隐藏」（切到设备 / 校准 / 日志页，或切到准备页 / 预览页的模型态）切回来时由 GcodePreview 调用：
  // 确认切片路径几何是否仍在场。
  //   · 在场（toolpathRoot !== null 且块节点还在）→ 只把根节点与层可见性收敛回记录状态，不重建、不重跑扫层；
  //   · 不在场（被系统回收 / 层级被整体丢弃 / 记账与节点不一致）→ 自动降级为重建，绝不出现「什么都没有」的空白页。
  // 「在场」的判断依据（两条同时成立）：
  //   1) toolpathRoot !== null —— 路径根节点仍在场景树上；
  //   2) chunkNodes.length > 0 —— 至少有一个块节点已建出（块是可见性的最小单元，正常建完后必 > 0）。
  // 两条都不满足才是「不在场」；只要有一个不满足（含记账说过建过、但节点没了）就按不在场处理、重建。
  private resumeGcodeKeepAlive(): void {
    if (this.pausedByHidden) {
      // 时序早到：页面可见性回调还没把 pausedByHidden 复位 → 推迟一拍再恢复，否则这次恢复会被丢掉
      setTimeout((): void => { this.resumeGcodeKeepAlive(); }, 0);
      return;
    }
    // 这里刻意【不】按 this.gcodeShow 提前返回：控制层（GcodePreview）切回切片路径时一定已把 gcodeShow
    // 置回 true（语义上路径就该显示），而模型页这边的 @StorageProp 通知晚一拍才到；若按旧值 false 提前返回，
    // 这次恢复就会被整个丢掉。
    // 【完整性闸门】保活命中还要求几何「已建完」：builtLayers 必须覆盖全部层。若上次是在扫层/分批建
    // 尚未完成时切走的（用户报告的中间态：toolpathRoot!=null 但 builtLayers<total），这里若直接
    // 「只恢复可见性」就会呈现一条截断的路径、且没有后续流程把它补齐（reload/扫层都被跳过）——
    // 用户看到的就是「路径不完整 + 模型被 gcodeShow 移出视锥」= 空画面。故此时一律降级重建，绝不留半份状态。
    const total: number = gcodeToolpath.layerCount;
    const complete: boolean = total > 0 && this.builtLayers >= total;
    const present: boolean = this.toolpathRoot !== null && this.chunkNodes.length > 0;
    // 【中间态判定】一句话写清「为什么走保活 / 走重建」：判据就是 present（几何在不在场）与
    // complete（built 是否追平 total）。这是排查「切回来只有模型没路径」的关键自证日志。
    hilog.info(0x0000, 'PreviewLife',
      '切片路径中间态判定 present=%{public}s complete=%{public}s built=%{public}d/%{public}d 块=%{public}d → %{public}s',
      present ? 'true' : 'false', complete ? 'true' : 'false', this.builtLayers, total,
      this.chunkNodes.length, (present && complete) ? '走保活' : '走重建');
    if (present && complete) {
      // 在场且完整 → 只恢复可见性：先把根节点打开，再用记录的状态（lastVisChunks）恢复层可见性。
      // 一根几何都不重建、reload() 不跑、扫层不重跑；差值管线通常 0 改动，因此不会闪。
      const root: Node | null = this.toolpathRoot;
      if (root !== null) {
        root.visible = true;
      }
      this.applyLayerVisibility(Math.min(this.builtLayers, this.currentGcodeLayer()));
      this.refreshRendering();
      hilog.info(0x0000, 'PreviewLife',
        '切片路径保活命中：几何仍在且完整（块=%{public}d 已建层=%{public}d/%{public}d）→ 只恢复可见性 / 不重建 / 不重扫',
        this.chunkNodes.length, this.builtLayers, total);
      return;
    }
    hilog.warn(0x0000, 'PreviewLife',
      '切片路径保活未命中：几何缺失或未建完（root=%{public}s 块=%{public}d 已建层=%{public}d/%{public}d 完整=%{public}s）→ 降级重建',
      this.toolpathRoot === null ? 'null' : 'ok', this.chunkNodes.length, this.builtLayers, total,
      complete ? 'true' : 'false');
    // ---- 确定性完整重建：destroy → 重新请求路径 → 重启扫层/补建 ----
    // 为什么必须显式「重启扫层」：updateToolpath 的建几何循环上限只是 currentGcodeLayer()，
    // 如果上次是在扫层/分批建途中切走的（builtLayers<total），仅 requestToolpath 只能补到目标层，
    // 而后台补建（schedulePrebuild）在「隐藏即暂停」里被清掉后并不会自动恢复 —— 结果就是路径长期
    // 停在半份、且没有任何新的 [GcodeChunk]。起一次扫层让「揭示 + 建几何」循环一路推进到建完
    // （扫层到顶但几何未建完时会继续等补建，见 maybeFinishSweep）。
    const hadRoot: boolean = this.toolpathRoot !== null;
    const hadChunks: number = this.chunkNodes.length;
    // 复位记账：destroyToolpath 会把 builtLayers / lastVisChunks / 块登记一并清掉，避免留下半份状态
    this.destroyToolpath();
    // 前置条件快照：直接回答「重建为什么能/不能真正拉起几何」——任一为假都会让 updateToolpath 早退。
    const precond: string =
      `loaded=${gcodeToolpath.loaded ? 'true' : 'false'} gcodeShow=${this.gcodeShow ? 'true' : 'false'}` +
      ` pausedByHidden=${this.pausedByHidden ? 'true' : 'false'} 材质=${this.roleMats.length}` +
      ` 场景=${this.factory !== null ? 'ready' : 'null'}`;
    // selfTriggered=true：这是恢复动作、不是用户操作，不打断扫层语义。
    this.requestToolpath(true);
    // 重启扫层：保证 builtLayers<total 时「续建 / 补建」循环一直跑到建完（不是只在完整时才恢复）。
    this.startSweep();
    hilog.warn(0x0000, 'PreviewLife',
      '降级重建：destroy=ok(原root=%{public}s 原块=%{public}d) requestToolpath=已调用 扫层=已重启 前置条件=%{public}s',
      hadRoot ? 'ok' : 'null', hadChunks, precond);
    AppLog.warn('PreviewWarn',
      '切片路径保活未命中 → 降级重建 toolpath（gen=%{public}d 前置条件=%{public}s）',
      gcodeToolpath.generation, precond);
  }

  // ---------------------------------------------------------------------------
  // 场景构建
  // ---------------------------------------------------------------------------
  private async initScene(): Promise<void> {
    try {
      const scene: Scene = await Scene.load();
      this.scene = scene;
      const root: Node | null = scene.root;
      if (root === null) {
        this.modelInfoText = '场景创建失败：无根节点';
        return;
      }
      const factory: SceneResourceFactory = scene.getResourceFactory();
      this.factory = factory;
      // 控制层（GcodePreview）通过这几个回调驱动路径重建 / 适应视图 / 视角操作
      gcodeSignals.rebuild = (): void => { this.requestToolpath(); };
      // 从「保活隐藏」切回来：确认切片路径几何是否仍在场，在则只收敛可见性、不在则降级重建
      gcodeSignals.resumeKeepAlive = (): void => { this.resumeGcodeKeepAlive(); };
      // 进入切片路径时请求「自下而上扫层」
      gcodeSignals.startSweep = (): void => { this.startSweep(); };
      gcodeSignals.fit = (): void => {
        this.updateFit();
        this.resetView();
      };
      gcodeSignals.pan = (dx: number, dy: number): void => { this.applyPan(dx, dy); };
      gcodeSignals.orbit = (dx: number, dy: number): void => { this.applyOrbit(dx, dy); };
      gcodeSignals.zoom = (f: number): void => {
        if (f > 0.01) {
          this.dist = Math.max(60, Math.min(2500, this.dist / f));
          this.updateView();
        }
      };

      // 相机（必须挂到场景树并 enabled，否则场景无活动相机 → 视口全空白）
      const cam: Camera | null = await factory.createCamera({ name: 'previewCam' });
      if (cam === null) {
        // 资源创建失败（内存压力等）：绝不能继续（后面会解引用 cam）→ 打日志并放弃本次初始化。
        AppLog.error('PreviewWarn', 'createCamera 返回空 → 3D 场景初始化中止');
        this.modelInfoText = '3D 引擎初始化失败：无法创建相机';
        return;
      }
      cam.fov = 0.72;
      cam.nearPlane = 5;
      cam.farPlane = 5000;
      // 清屏色：初始透明，随后由 applyGlowSettings() 按「背景发光」写入不透明底色（真正生效的路径）
      cam.clearColor = { r: 0, g: 0, b: 0, a: 0 };
      cam.enabled = true;
      cam.msaa = true;
      // 启用后处理（泛光需完整前向管线）
      cam.renderingPipeline = RenderingPipelineType.FORWARD;
      // 减弱暗角 + 手柄泛光
      cam.postProcess = {
        vignette: { intensity: 0.12, roundness: 0.85 },
        bloom: { thresholdHard: 0.8, thresholdSoft: 1.3, scaleFactor: 1.5, scatter: 1.0 },
      };
      this.camera = cam;
      root.children.append(cam);

      // 外层世界节点（只做平移，旋转恒为单位）
      const world: Node | null = await factory.createNode({ name: 'world' });
      if (world === null) {
        AppLog.error('PreviewWarn', 'createNode(world) 返回空 → 3D 场景初始化中止');
        this.modelInfoText = '3D 引擎初始化失败：无法创建世界节点';
        return;
      }
      root.children.append(world);
      this.worldNode = world;

      // 内层枢轴节点（绕锚点旋转；底板与模型都在其下）
      const pivot: Node | null = await factory.createNode({ name: 'pivot' });
      if (pivot === null) {
        AppLog.error('PreviewWarn', 'createNode(pivot) 返回空 → 3D 场景初始化中止');
        this.modelInfoText = '3D 引擎初始化失败：无法创建枢轴节点';
        return;
      }
      world.children.append(pivot);
      this.pivotNode = pivot;

      // 环境光（间接漫反射）
      scene.environment.indirectDiffuseFactor = { x: 0.38, y: 0.38, z: 0.42, w: 1.0 };

      // 主平行光 + 补光（挂在根下，保持固定方向）。创建失败只影响观感，判空后跳过即可。
      const light: Light | null = await factory.createLight({ name: 'sun' }, LightType.DIRECTIONAL);
      if (light === null) {
        AppLog.warn('PreviewWarn', 'createLight(sun) 返回空 → 跳过主光');
      } else {
        light.intensity = 3.0;
        light.shadowEnabled = false;
        light.enabled = true;
        light.rotation = dirToQuaternion(0.45, -0.85, 0.3);
        root.children.append(light);
        this.sunLight = light;
      }

      const fill: Light | null = await factory.createLight({ name: 'fill' }, LightType.DIRECTIONAL);
      if (fill === null) {
        AppLog.warn('PreviewWarn', 'createLight(fill) 返回空 → 跳过补光');
      } else {
        fill.intensity = 1.1;
        fill.shadowEnabled = false;
        fill.enabled = true;
        fill.rotation = dirToQuaternion(-0.6, -0.3, 0.5);
        root.children.append(fill);
        this.fillLight = fill;
      }

      // 光源就绪后按「模型预览」档位初始化阴影（进入切片路径时会切到「切片路径」档位，见 onGcodeState）
      this.applyShadowLevel(SHADOW_SAMPLE_COUNT_MODEL);

      // 打印板（托盘 STL + 网格线 + 边框），尺寸随所选打印机变化。
      // 三份材质【各自独立】：床板 / 网格 / 边框互不共享，且运行时任何改色路径都不许写它们
      // （共享材质一旦被别处改色，整块板/网格会跟着变色）。创建一律判空，失败即告警并跳过。
      const bedMatRaw: Material | null =
        await factory.createMaterial({ name: 'bedMat' }, MaterialType.METALLIC_ROUGHNESS);
      if (bedMatRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 bedMat → 床板将没有材质覆盖');
      } else {
        const bedMat: MetallicRoughnessMaterial = bedMatRaw as MetallicRoughnessMaterial;
        bedMat.baseColor.factor = { x: 0.07, y: 0.07, z: 0.08, w: 1.0 };
        this.bedMat = bedMat;
        this.plateMats.push(bedMat);
      }

      const gridMatRaw: Material | null =
        await factory.createMaterial({ name: 'gridMat' }, MaterialType.UNLIT);
      if (gridMatRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 gridMat → 网格将没有材质覆盖');
      } else {
        const gridMat: UnlitMaterial = gridMatRaw as UnlitMaterial;
        gridMat.baseColor.factor = { x: 0.88, y: 0.88, z: 0.90, w: 1.0 };
        gridMat.cullMode = CullMode.NONE;
        this.gridMat = gridMat;
        this.plateMats.push(gridMat);
      }

      const borderMatRaw: Material | null =
        await factory.createMaterial({ name: 'borderMat' }, MaterialType.UNLIT);
      if (borderMatRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 borderMat → 边框将没有材质覆盖');
      } else {
        const borderMat: UnlitMaterial = borderMatRaw as UnlitMaterial;
        borderMat.baseColor.factor = { x: 1.0, y: 1.0, z: 1.0, w: 1.0 };
        borderMat.cullMode = CullMode.NONE;
        this.borderMat = borderMat;
        this.plateMats.push(borderMat);
      }

      this.lastPlateW = this.plateW;
      this.lastPlateH = this.plateH;
      this.lastPlateRev = this.plateRev;
      this.lastPlateModel = this.plateBedModel;
      this.lastPlatePrinter = this.platePrinter;
      await this.queuePlateRebuild();

      // 模型材质（PBR 橙）：无 displayColor 对象的默认色；关闭背面剔除
      const modelMatRaw: Material | null =
        await factory.createMaterial({ name: 'modelMat' }, MaterialType.METALLIC_ROUGHNESS);
      if (modelMatRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 modelMat → 模型将无法入场景');
      } else {
        const modelMat: MetallicRoughnessMaterial = modelMatRaw as MetallicRoughnessMaterial;
        modelMat.baseColor.factor = { x: this.defaultModelRgb.x, y: this.defaultModelRgb.y, z: this.defaultModelRgb.z, w: 1.0 };
        modelMat.cullMode = CullMode.NONE;
        this.modelMaterial = modelMat;
      }

      // 切片路径材质：每个角色一个材质，色相直接取 ROLE_RGB（不做明暗缩放）。
      // 下标 = role，与 GcodeToolpath 的 slot 语义（slot = role + 1）严格对应，
      // 所以取材质时仍写 roleMats[p.slot - 1] 即可，无需额外换算。
      // 元素类型允许 null：某一档创建失败时保留占位（长度不变），取材质处会显式回退兜底，
      // 不能让下标错位（一旦错位，角色会串色，比缺一个材质更糟）。
      const roleMats: (Material | null)[] = [];
      for (let r: number = 0; r < ROLE_RGB.length; r++) {
        const rmatRaw: Material | null =
          await factory.createMaterial({ name: `gcodeR${r}` }, MaterialType.METALLIC_ROUGHNESS);
        if (rmatRaw === null) {
          AppLog.warn('PreviewWarn', '创建材质失败 gcodeR%{public}d → 该角色回退兜底材质', r);
          roleMats.push(null);
          continue;
        }
        const rmat: MetallicRoughnessMaterial = rmatRaw as MetallicRoughnessMaterial;
        rmat.baseColor.factor = { x: ROLE_RGB[r][0], y: ROLE_RGB[r][1], z: ROLE_RGB[r][2], w: 1.0 };
        rmat.cullMode = CullMode.NONE;
        roleMats.push(rmat);
      }
      this.roleMats = roleMats;
      // 配色表自检：三张表长度必须一致，且除「其他」外任何一档都不允许是灰。
      // 谁把某档改成灰 / 两套表漂移，都会在这里被点名（hilog + 应用日志 + 诊断文件），
      // 不会出现「图例是蓝橙黄、模型发灰却毫无告警」。
      const palBad: string[] = paletteProblems();
      if (palBad.length > 0) {
        for (const b of palBad) {
          AppLog.warn('PreviewWarn', '配色表自检未通过：%{public}s', b);
        }
      } else {
        hilog.info(0x0000, 'PreviewWarn',
          '配色表自检通过：%{public}d 档，除「其他」外无灰档，图例与渲染同源', ROLE_RGB.length);
      }

      // 路径材质的显式兜底（洋红哨兵色，见字段注释）。它不属于任何角色，只兜越界/未就绪。
      const fbRaw: Material | null =
        await factory.createMaterial({ name: 'gcodeFallback' }, MaterialType.METALLIC_ROUGHNESS);
      if (fbRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 gcodeFallback → 越界时无法回退');
      } else {
        const fb: MetallicRoughnessMaterial = fbRaw as MetallicRoughnessMaterial;
        fb.baseColor.factor = { x: 1.0, y: 0.0, z: 1.0, w: 1.0 };
        fb.cullMode = CullMode.NONE;
        this.fallbackMat = fb;
      }

      // 选面悬停高亮材质（亮绿，无光照）
      const hlMatRaw: Material | null =
        await factory.createMaterial({ name: 'highlightMat' }, MaterialType.UNLIT);
      if (hlMatRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 highlightMat → 悬停高亮不可用');
      } else {
        const hlMat: UnlitMaterial = hlMatRaw as UnlitMaterial;
        hlMat.baseColor.factor = { x: 0.0, y: 1.0, z: 0.55, w: 1.0 };
        hlMat.cullMode = CullMode.NONE;
        this.highlightMat = hlMat;
      }

      // 手柄材质：无光照纯色（高饱和，不被灯光冲淡）；亮度由「手柄发光」控制，>1 触发泛光。
      // 只把创建成功的推进数组（数组长度可能 < 3，取用处按长度判空，绝不留下 null 元素）。
      const gxRaw: Material | null = await factory.createMaterial({ name: 'gzMatX' }, MaterialType.UNLIT);
      if (gxRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 gzMatX');
      } else {
        const gx: UnlitMaterial = gxRaw as UnlitMaterial;
        gx.baseColor.factor = { x: this.gizmoHue[0].x, y: this.gizmoHue[0].y, z: this.gizmoHue[0].z, w: 1.0 };
        gx.cullMode = CullMode.NONE;
        this.gizmoMats.push(gx);
      }
      const gyRaw: Material | null = await factory.createMaterial({ name: 'gzMatY' }, MaterialType.UNLIT);
      if (gyRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 gzMatY');
      } else {
        const gy: UnlitMaterial = gyRaw as UnlitMaterial;
        gy.baseColor.factor = { x: this.gizmoHue[1].x, y: this.gizmoHue[1].y, z: this.gizmoHue[1].z, w: 1.0 };
        gy.cullMode = CullMode.NONE;
        this.gizmoMats.push(gy);
      }
      const gzRaw: Material | null = await factory.createMaterial({ name: 'gzMatZ' }, MaterialType.UNLIT);
      if (gzRaw === null) {
        AppLog.warn('PreviewWarn', '创建材质失败 gzMatZ');
      } else {
        const gz: UnlitMaterial = gzRaw as UnlitMaterial;
        gz.baseColor.factor = { x: this.gizmoHue[2].x, y: this.gizmoHue[2].y, z: this.gizmoHue[2].z, w: 1.0 };
        gz.cullMode = CullMode.NONE;
        this.gizmoMats.push(gz);
      }
      // 应用当前光感设置
      this.applyGlowSettings();
      // 相机与角色材质都建好了 → 把「渲染开关」当前档位应用一次（首帧就与开关状态一致）。
      // 这里不落日志（reason 为空）：初始化不是「拨开关」动作，避免每次进页面刷一条。
      this.applyRenderTune('');
      // 场景就绪且页面可见 → 启动真实 FPS 统计（页面不可见时由 resumeHiddenWork 再启动）
      if (this.pageVisible) {
        this.startFpsMeter();
      }

      // 恢复所有已导入模型；无模型时 3D 视口保持为空（不再有任何空态占位几何）
      if (modelState.hasModel()) {
        for (const inst of modelState.instances) {
          await this.appendInstance(inst);
        }
        this.updateFit();
      }

      // 锚点 = 当前内容中心，且置于屏幕中心；初始视角 = 重置视角
      this.updateFit();
      this.resetView();
      this.syncSelection();
      this.sceneReady = true;
      // 场景与「路径材质」到这里才真正就绪。若此前已有预览请求（gcodeShow 先于场景就绪到达），
      // updateToolpath 会因「路径材质未就绪」主动让位、没有建任何几何（否则会整片落灰）；
      // 这里补一次重建，保证材质就绪后路径必定被建出来。
      if (gcodeToolpath.loaded) {
        this.kickToolpath();
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      AppLog.error('PreviewWarn', '3D 引擎初始化失败: %{public}s', msg);
      this.modelInfoText = `3D 引擎初始化失败: ${msg}`;
    }
  }

  // MeshGeometry（纯数据）→ CustomGeometry（ArkGraphics3D）。
  // 【大网格（TypedArray 形态）】引擎只收 Vec3[]/number[]，必须物化；但绝不能常驻两份：
  //   这里分块物化（每块让帧），createMesh 之后调用方立刻 releaseCustomGeometry 释放。
  // 【程序化小网格（对象数组形态）】直接按引用传（规模很小，不需要物化）。
  private async toCustomGeometry(g: MeshGeometry): Promise<CustomGeometry> {
    const cg: CustomGeometry = new CustomGeometry();
    if (g.pos !== null) {
      cg.vertices = await materializeVerticesChunked(g.pos);
      // 只有带法线的网格才显式传法线：切片路径的棱柱网格法线留空，
      // 交给引擎 generateNormals 生成（省掉每段 8 个法线对象）；
      // 模型/高亮/底板/手柄的法线都非空，继续按原样传（曲面才不会变成硬边）。
      if (g.nrm !== null && g.nrm.length > 0) {
        cg.normals = await materializeVerticesChunked(g.nrm);
      }
      if (g.idx !== null && g.idx.length > 0) {
        cg.indices = await materializeIndicesChunked(g.idx);
      }
    } else {
      cg.vertices = g.vertices;
      if (g.normals.length > 0) {
        cg.normals = g.normals;
      }
      if (g.indices.length > 0) {
        cg.indices = g.indices;
      }
    }
    // UV 只有「贴图面片」才带（如单喷嘴区文字）；其余网格留空 → 不传 uvs（行为不变）
    if (g.uvs.length > 0) {
      cg.uvs = g.uvs;
    }
    cg.topology = PrimitiveTopology.TRIANGLE_LIST;
    return cg;
  }

  // createMesh 之后立即释放物化出来的对象数组（只释放大网格物化的那几份；
  // 程序化小网格的 cg.vertices 是「按引用」指向 MeshGeometry 自己的数组，不能清空）。
  private releaseCustomGeometry(cg: CustomGeometry, g: MeshGeometry): void {
    if (g.pos === null) {
      return;
    }
    cg.vertices = [];
    cg.normals = undefined;
    cg.indices = undefined;
  }

  // 建网格资源 + 几何节点并挂到 parent 下。返回新节点（失败返回 null）。
  // 创建一律判空：createMesh / createGeometry 在内存压力下可能拿不到资源，
  // 失败时打 PreviewWarn 并跳过（绝不把 null 推进场景树，也不留半个未定义状态的节点）。
  private async appendGeometry(parent: Node, g: MeshGeometry, mat: Material | null, name: string): Promise<Geometry | null> {
    if (this.factory === null) {
      AppLog.warn('PreviewWarn', 'appendGeometry(%{public}s) 跳过：factory 未就绪', name);
      return null;
    }
    const tMat0: number = Date.now();
    const cg: CustomGeometry = await this.toCustomGeometry(g);
    const tMat1: number = Date.now();
    const meshRes: MeshResource | null =
      await this.factory.createMesh({ name: `${name}Mesh` }, cg);
    const tMat2: number = Date.now();
    if (g.pos !== null) {
      hilog.info(0x0000, TAG, 'ModelGeom %{public}s 物化=%{public}sms createMesh=%{public}sms',
        name, (tMat1 - tMat0).toString(), (tMat2 - tMat1).toString());
    }
    // 引擎已把几何拷进自己的资源：立即释放本次物化出的对象数组（大网格 import 后不常驻）
    this.releaseCustomGeometry(cg, g);
    if (meshRes === null) {
      AppLog.warn('PreviewWarn', 'createMesh(%{public}s) 返回空 → 跳过该节点', name);
      return null;
    }
    const geoNode: Geometry | null = await this.factory.createGeometry({ name: name }, meshRes);
    if (geoNode === null) {
      AppLog.warn('PreviewWarn', 'createGeometry(%{public}s) 返回空 → 跳过该节点', name);
      return null;
    }
    if (mat !== null) {
      geoNode.mesh.materialOverride = mat;
    }
    parent.children.append(geoNode);
    return geoNode;
  }

  // 绕 content 某轴旋转的四元数（key: 'x'|'y'|'z'）
  private axisQuatContent(key: string, deg: number): Quaternion {
    const h: number = deg * Math.PI / 360;
    const s: number = Math.sin(h);
    const w: number = Math.cos(h);
    if (key === 'x') {
      return { x: s, y: 0, z: 0, w: w };
    }
    if (key === 'y') {
      return { x: 0, y: s, z: 0, w: w };
    }
    return { x: 0, y: 0, z: s, w: w };
  }

  // 合成最终旋转：面板角按 Z-up 约定映射到 content 轴（UI Y→content Z，UI Z→content Y）
  private computeRotation(inst: ModelInstance): Quaternion {
    const t = inst.transform;
    const qx: Quaternion = this.axisQuatContent('x', t.rotX);
    const qy: Quaternion = this.axisQuatContent('z', t.rotY);
    const qz: Quaternion = this.axisQuatContent('y', t.rotZ);
    const user: Quaternion = multiplyQuaternion(multiplyQuaternion(qx, qy), qz);
    return multiplyQuaternion(user, t.baseRotation);
  }

  // 把实例的变换应用到节点。
  // 关键：平移放在「容器节点」（旋转恒为 identity），旋转/缩放放在「网格节点」。
  // 这样平移不会被旋转影响——ArkGraphics3D 的位置在节点局部（已旋转）坐标系里生效，
  // 若平移和旋转放在同一节点，旋转会让平移量一起翻转，导致模型落到板下面。
  private applyTransform(inst: ModelInstance): void {
    const container: Node | undefined = this.containers.get(inst.id);
    const geo: Geometry | undefined = this.nodes.get(inst.id);
    if (container !== undefined) {
      // 非当前盘的模型移出视锥隐藏（多盘文件一次只看一盘）
      container.position = (this.isPlateVisible(inst.plate) && !this.gcodeShow) ? inst.transform.position : HIDDEN_POS;
    }
    if (geo !== undefined) {
      geo.rotation = this.computeRotation(inst);
      const s: Vec3 = inst.transform.scale;
      geo.scale = { x: s.x, y: s.y, z: s.z };
    }
  }

  // 幂等地把所有已加载模型的变换重写一遍（位置由 applyTransform 按 gcodeShow 决定：模型态=原位，
  // 切片路径态=HIDDEN_POS）。用于「回到模型态」与「3D 页恢复可见」两处显式把模型放回原位，
  // 不再只依赖 gcodeShow 的一次通知。
  private reassertModelVisibility(): void {
    for (const inst of modelState.instances) {
      this.applyTransform(inst);
    }
  }

  // 模型在「Y 轴向上」坐标系下的原始尺寸（几何体已归一化：XY 居中、底面 y=0）
  // 解析结果尺寸是 Z-up 的：本地 X=sizeX，本地 Y(高)=sizeZ，本地 Z=sizeY
  private localSize(inst: ModelInstance): Vec3 {
    return { x: inst.size.x, y: inst.size.z, z: inst.size.y };
  }

  // 模型局部包围盒中心（Y-up 本地坐标）
  private localCenter(inst: ModelInstance): Vec3 {
    const ls: Vec3 = this.localSize(inst);
    return { x: 0, y: ls.y * 0.5, z: 0 };
  }

  // 设置旋转并保持「模型中心」不动（绕中心旋转，而非绕模型底面原点）
  private applyRotationAboutCenter(inst: ModelInstance, rx: number, ry: number, rz: number): void {
    const lc: Vec3 = this.localCenter(inst);
    const s: Vec3 = inst.transform.scale;
    const rcOld: Vec3 = rotateVecByQuat(this.computeRotation(inst),
      { x: lc.x * s.x, y: lc.y * s.y, z: lc.z * s.z });
    const p0: Vec3 = inst.transform.position;
    const cx: number = p0.x + rcOld.x;
    const cy: number = p0.y + rcOld.y;
    const cz: number = p0.z + rcOld.z;
    inst.transform.rotX = rx;
    inst.transform.rotY = ry;
    inst.transform.rotZ = rz;
    const rcNew: Vec3 = rotateVecByQuat(this.computeRotation(inst),
      { x: lc.x * s.x, y: lc.y * s.y, z: lc.z * s.z });
    inst.transform.position = { x: cx - rcNew.x, y: cy - rcNew.y, z: cz - rcNew.z };
  }

  // hex（如 '#D8322B'）→ 归一化 RGB。解析失败退回默认色（不抛异常、不吞异常，落 hilog）。
  private hexToVec3(hex: string): Vec3 {
    let h: string = hex;
    if (h.startsWith('#')) {
      h = h.substring(1);
    }
    if (h.length !== 6) {
      hilog.warn(0x0000, 'ObjColor', '非法的显示色 %{public}s，退回默认色', hex);
      return this.defaultModelRgb;
    }
    const r: number = parseInt(h.substring(0, 2), 16);
    const g: number = parseInt(h.substring(2, 4), 16);
    const b: number = parseInt(h.substring(4, 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      hilog.warn(0x0000, 'ObjColor', '显示色解析失败 %{public}s，退回默认色', hex);
      return this.defaultModelRgb;
    }
    return { x: r / 255, y: g / 255, z: b / 255 };
  }

  // 打印板/网格/边框的材质是「场景资产」：运行时任何改色路径都不得写它们
  // （它们一旦被改成别的颜色，整块板/网格会跟着变，用户看到的就是「打印板变灰」）。
  // 这里显式拦一道，命中即打 PreviewWarn（去重），保证「只改自己那份材质」这条底线。
  private isPlateMaterial(mat: Material): boolean {
    for (const m of this.plateMats) {
      if (m === mat) { return true; }
    }
    return false;
  }

  // 把某个 hex 颜色写到材质上（只改 baseColor.factor，不重建几何）
  private setMaterialColor(mat: MetallicRoughnessMaterial, hex: string): void {
    if (this.isPlateMaterial(mat)) {
      if (!this.plateMatGuardLogged) {
        this.plateMatGuardLogged = true;
        AppLog.warn('PreviewWarn', '拒绝修改打印板/网格材质（运行时只读），已拦下改色请求');
      }
      return;
    }
    const rgb: Vec3 = hex !== '' ? this.hexToVec3(hex) : this.defaultModelRgb;
    mat.baseColor.factor = { x: rgb.x, y: rgb.y, z: rgb.z, w: 1.0 };
  }

  // 取（必要时创建）某个对象专属的模型材质，并按该对象当前 displayColor 着色。
  // 每个对象一份材质，改色互不影响；材质创建很轻，不涉及网格。
  private async ensureInstanceMaterial(inst: ModelInstance): Promise<MetallicRoughnessMaterial | null> {
    const cached: MetallicRoughnessMaterial | undefined = this.modelMats.get(inst.id);
    if (cached !== undefined) {
      this.setMaterialColor(cached, inst.displayColor);
      return cached;
    }
    if (this.factory === null) {
      return null;
    }
    const matRaw: Material | null =
      await this.factory.createMaterial({ name: `modelMat_${inst.id}` }, MaterialType.METALLIC_ROUGHNESS);
    if (matRaw === null) {
      AppLog.warn('PreviewWarn', 'createMaterial(modelMat_%{public}d) 返回空 → 该对象用共享默认材质', inst.id);
      return null;
    }
    const mat: MetallicRoughnessMaterial = matRaw as MetallicRoughnessMaterial;
    mat.cullMode = CullMode.NONE;
    this.setMaterialColor(mat, inst.displayColor);
    this.modelMats.set(inst.id, mat);
    return mat;
  }

  // 把每个对象的显示色刷到它自己的材质上。改色 / 结构变化时调用；
  // 只写 baseColor 属性（引擎下一帧即生效），绝不重建几何或重解析网格。
  private applyAllInstanceColors(): void {
    for (const inst of modelState.instances) {
      const mat: MetallicRoughnessMaterial | undefined = this.modelMats.get(inst.id);
      if (mat !== undefined) {
        this.setMaterialColor(mat, inst.displayColor);
      }
    }
  }

  // 为单个模型实例创建场景节点（容器节点 + 网格节点）
  // onStep：可选的细粒度进度回调，仅载入弹窗路径传入。按真实的 3 个步骤上报
  //   「创建容器节点 / 创建网格资源 / 挂进场景」，并在步骤之间让帧 —— createMesh 是长同步 NAPI
  //   （约 2.4s），前后的让帧给进度队列刷新机会，否则界面在「入场景」期间整块不动。
  private async appendInstance(inst: ModelInstance,
      onStep?: (step: number, total: number, label: string) => void): Promise<void> {
    if (this.pivotNode === null || this.modelMaterial === null || this.factory === null) {
      return;
    }
    // 幂等：已在场景中或正在创建则跳过（避免导入 + 监听到结构变化时重复创建）
    if (this.nodes.has(inst.id) || this.pendingIds.has(inst.id)) {
      return;
    }
    this.pendingIds.add(inst.id);
    // 记下开工时的几何：createMesh 期间几何可能被整体替换（合并/布尔），
    // 完成后必须能识别「我建的是旧几何」，否则会把旧网格挂到新对象上。
    const geomAtStart: MeshGeometry = inst.geometry;
    const total: number = 3;
    try {
      if (onStep !== undefined) { onStep(1, total, '创建容器节点'); }
      const container: Node | null = await this.factory.createNode({ name: `container_${inst.id}` });
      if (container === null) {
        AppLog.warn('PreviewWarn', 'createNode(container_%{public}d) 返回空 → 跳过该对象', inst.id);
        return;
      }
      // createNode 是 await：期间对象可能已被删除/换了几何 —— 立即回收，避免留下孤儿容器
      const cur0: ModelInstance | undefined = modelState.get(inst.id);
      if (cur0 === undefined || cur0 !== inst || inst.geometry !== geomAtStart) {
        hilog.info(0x0000, 'ModelScene',
          'append id=%{public}d 在第 1 步后作废（cur0=%{public}s 几何一致=%{public}s）',
          inst.id, cur0 === undefined ? '无' : (cur0 === inst ? '同一对象' : '被替换'),
          inst.geometry === geomAtStart ? '是' : '否');
        container.destroy();
        return;
      }
      this.pivotNode.children.append(container);
      await yieldToUi();
      if (onStep !== undefined) { onStep(2, total, '创建网格资源'); }
      // 每个对象用自己那份材质（按 displayColor 着色）；拿不到时退回共享默认材质
      const instMat: MetallicRoughnessMaterial | null = await this.ensureInstanceMaterial(inst);
      await yieldToUi();
      if (onStep !== undefined) { onStep(3, total, '挂进场景'); }
      // 直接用 appendGeometry 的返回值，不再从「最后一个子节点」反推（创建失败时那里会拿到错节点）
      const geo: Geometry | null =
        await this.appendGeometry(container, geomAtStart, instMat !== null ? instMat : this.modelMaterial, `model_${inst.id}`);
      if (geo === null) {
        return;
      }
      // createMesh 是长同步 NAPI：期间对象可能已被删除（删行/撤销/合并）或几何被整体替换。
      // 此时若照常登记，syncNodes 的「已删除」扫描看不到它（nodes 里还没有），
      // 网格会永久留在场景里 —— 用户看到的就是「对象栏删了，3D 模型还在」。
      const cur1: ModelInstance | undefined = modelState.get(inst.id);
      if (cur1 === undefined || cur1 !== inst || inst.geometry !== geomAtStart) {
        const gp: Node | null = geo.parent;
        if (gp !== null) { gp.children.remove(geo); }
        try { geo.mesh.destroy(); } catch (e) {
          hilog.warn(0x0000, 'ModelScene', 'stale mesh release failed %{public}s',
            e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
        }
        try { geo.destroy(); } catch (e) {
          hilog.warn(0x0000, 'ModelScene', 'stale geometry destroy failed %{public}s',
            e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
        }
        const cp: Node | null = container.parent;
        if (cp !== null) { cp.children.remove(container); }
        container.destroy();
        return;
      }
      this.nodes.set(inst.id, geo);
      this.containers.set(inst.id, container);
      this.nodeGeom.set(inst.id, geomAtStart);
      this.applyTransform(inst);
    } catch (e) {
      const code: string = (e as Record<string, Object>)['code'] !== undefined
        ? String((e as Record<string, Object>)['code']) : '-';
      AppLog.warn('PreviewWarn', 'appendInstance(%{public}d) 异常 %{public}s',
        inst.id, 'code=' + code + ' ' +
          (e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e)));
    } finally {
      this.pendingIds.delete(inst.id);
    }
  }

  // 构建/重建打印板：床板按盘面尺寸缩放，网格与边框按尺寸重新生成
  private async buildPlateGroup(): Promise<void> {
    if (this.pivotNode === null || this.factory === null) {
      return;
    }
    this.clearPlateGroup();
    const plate: Node | null = await this.factory.createNode({ name: 'plate' });
    if (plate === null) {
      AppLog.warn('PreviewWarn', 'createNode(plate) 返回空 → 本轮盘面重建跳过');
      return;
    }
    this.pivotNode.children.append(plate);
    this.plateNode = plate;

    // 床板：按当前机型的板模型（预设 bed_model，开源板 STL）取网格；查不到退回内置 X1 板。
    // 缓存按「板模型名」判定：换机型（即使盘面尺寸不变）也要重取，杜绝「板形不跟着变」。
    const wantModel: string = this.plateBedModel;
    if (this.bedBaseGeom === null || this.bedGeomFor !== wantModel) {
      const got: BedPlate = this.loadBedPlate(wantModel);
      this.bedBaseGeom = got.geom;
      this.bedGeomFor = wantModel;
      this.bedPlateW = got.width;
      this.bedPlateH = got.height;
      this.bedPlateSrc = got.src;
      this.bedBBoxMinX = got.bboxMinX;
      this.bedBBoxMinY = got.bboxMinY;
      this.bedBBoxMaxX = got.bboxMaxX;
      this.bedBBoxMaxY = got.bboxMaxY;
    }
    const bedNode: Geometry | null = await this.appendGeometry(plate, this.bedBaseGeom, this.bedMat, 'bed');
    if (bedNode !== null) {
      // 板模型按【绝对床坐标 1:1】摆放，不再「缩放到盘面尺寸」。
      // 为什么：板 STL 本身就是按床坐标建模的（比可打印区略大：X1 是 258×276 / 可打印 256×256，
      // A1M 是 184×197 / 可打印 180×180）。旧做法把板模型包围盒缩放到盘面尺寸 → 板面被压小、
      // 与 256 网格/走线对不上（X1 上尤其明显，纵向被压掉 7%）。
      // 生成器已把网格按包围盒中心居中，所以这里补一个平移把它放回绝对坐标：
      //   content_x = (bedX − bcx) + (bcx − plateW/2)
      //   content_z = −bedY + bcy + (plateH/2 − bcy)   ← 注意 Z 轴的符号（content Z 与床 Y 反向）
      const bcx: number = (this.bedBBoxMinX + this.bedBBoxMaxX) * 0.5;
      const bcy: number = (this.bedBBoxMinY + this.bedBBoxMaxY) * 0.5;
      bedNode.scale = { x: 1, y: 1, z: 1 };
      bedNode.position = {
        x: bcx - this.plateW * 0.5,
        y: 0,
        z: this.plateH * 0.5 - bcy
      };
    }
    this.plateBedNode = bedNode;
    this.logPlateShape(wantModel, bedNode !== null);

    // 网格线（每 10mm 一格）+ 边框。各自独立材质；任一创建失败只跳过它自己，
    // 不会连带把已建好的床板/网格拖下水（「网格消失」这类半成品场景正是这么来的）。
    // 三个节点引用都留一份，供「前台恢复」重贴 bedMat/gridMat/borderMat（见 rematerialPlate）。
    this.plateGridNode = await this.appendGeometry(plate, buildGridLines(this.plateW, this.plateH, 10), this.gridMat, 'grid');
    this.plateBorderNode = await this.appendGeometry(plate, buildPlateBorder(this.plateW, this.plateH), this.borderMat, 'border');
    // 单喷嘴专属可打印区（H2D/H2D Pro/H2C 左右、X2 左）：数据来自 extruder_printable_area 真值。
    // 无数据就不画（并打日志），绝不编造尺寸。
    await this.buildNozzleZones(plate);
  }

  // 载入某机型的开源板网格（bed_model）。返回几何 + 板模型自身包围盒尺寸 + 来源描述。
  // 查不到该组件（或 bed_model 为空）→ 退回内置 X1 板（BED_STL_SIZE），来源如实标注。
  private loadBedPlate(model: string): BedPlate {
    const out: BedPlate = new BedPlate();
    if (model.length > 0) {
      try {
        const r: testNapi.BedMeshModelResult = testNapi.bedMeshForModel(model);
        if (r.ok && r.triangles > 0 && r.width > 0 && r.height > 0) {
          const bg: MeshGeometry = new MeshGeometry();
          bg.vertices = zUpToYUp(new Float32Array(r.positions));
          bg.normals = zUpToYUp(new Float32Array(r.normals));
          out.geom = bg;
          out.width = r.width;
          out.height = r.height;
          // 板模型自身的【绝对床坐标】包围盒：与板模型同一坐标系映射的锚点（同一套 中心/缩放）
          out.bboxMinX = r.bboxMinX;
          out.bboxMinY = r.bboxMinY;
          out.bboxMaxX = r.bboxMaxX;
          out.bboxMaxY = r.bboxMaxY;
          out.src = model;
          return out;
        }
        hilog.warn(0x0000, 'BedShape', '板模型 %{public}s 无对应网格 → 退回内置 X1 板', model);
      } catch (e) {
        hilog.error(0x0000, 'BedShape', '取板模型 %{public}s 失败 → 退回内置 X1 板: %{public}s',
          model, e instanceof Error ? e.message : JSON.stringify(e));
      }
    }
    const bedData: testNapi.BedMeshResult = testNapi.bedMesh();
    const bg: MeshGeometry = new MeshGeometry();
    bg.vertices = zUpToYUp(new Float32Array(bedData.positions));
    bg.normals = zUpToYUp(new Float32Array(bedData.normals));
    out.geom = bg;
    out.width = BED_STL_SIZE;
    out.height = BED_STL_SIZE;
    // 内置兜底板：网格已居中，绝对包围盒即 ±BED_STL_SIZE/2（不引入额外偏移）
    out.bboxMinX = -BED_STL_SIZE * 0.5;
    out.bboxMinY = -BED_STL_SIZE * 0.5;
    out.bboxMaxX = BED_STL_SIZE * 0.5;
    out.bboxMaxY = BED_STL_SIZE * 0.5;
    out.src = 'bbl-3dp-X1.stl(内置兜底)';
    return out;
  }

  // 单喷嘴专属可打印区：解析参数面板下发的 plateZones（extruder_printable_area 真值算得），
  // 在板面上画【半透明矩形填充 + 清晰边框 + 贴在板面上的竖排文字贴图】。
  //   · 填充走 alpha 混合（材质 blend + factor.w）→ 可透出板面网格/底色；
  //   · 文字是贴在板面上的贴图面片（随板节点一起透视/倾斜），不再是视口浮层文字。
  //
  // 坐标系（与板模型同一套）：绝对床坐标 1:1 映射到内容坐标 ——
  //   content_x = bedX − plateW/2 ；content_z = −(bedY − plateH/2)
  // 板节点也是这套（板网格回放到绝对床坐标，见 buildPlateGroup），所以区域与板必然对齐。
  // 历史坑：曾把板模型「按包围盒缩放到盘面尺寸」，X1 的板 STL 是 258×276（可打印 256×256），
  // 非等比压缩会让板面比网格/走线小一圈，看起来像「路径错位」。现已改为 1:1。
  private async buildNozzleZones(plate: Node): Promise<void> {
    this.nozzleEdgeNode = null;
    this.zoneNodeL = null;
    this.zoneNodeR = null;
    this.zoneLeftWidth = 0;
    this.zoneRightWidth = 0;
    this.zoneLeftCenterX = 0;
    this.zoneRightCenterX = 0;
    this.zoneLeftCenterZ = 0;
    this.zoneRightCenterZ = 0;
    this.zoneLeftHalfW = 0;
    this.zoneRightHalfW = 0;
    this.zoneRectL = null;
    this.zoneRectR = null;
    let zones: PlateZones | null = null;
    if (this.plateZones.length > 0) {
      try {
        zones = JSON.parse(this.plateZones) as PlateZones;
      } catch (e) {
        hilog.error(0x0000, 'NozzleArea', '单喷嘴区数据解析失败: %{public}s',
          e instanceof Error ? e.message : JSON.stringify(e));
      }
    }
    const list: NozzleZone[] = (zones !== null && zones.zones !== undefined) ? zones.zones : [];
    if (list.length === 0) {
      this.zoneLeftVisible = false;
      this.zoneRightVisible = false;
      this.logNozzleZones('未找到数据，未绘制');
      return;
    }
    const edgeMat: Material | null = await this.ensureNozzleEdgeMaterial();
    // 与板模型同一套映射：绝对床坐标 1:1（content = 床坐标 − 盘中心；content Z 与床 Y 反向）
    let left: boolean = false;
    let right: boolean = false;
    const bounds: string[] = [];
    for (const z of list) {
      const x0: number = z.minX - this.plateW * 0.5;
      const x1: number = z.maxX - this.plateW * 0.5;
      const zc0: number = -(z.maxY - this.plateH * 0.5);
      const zc1: number = -(z.minY - this.plateH * 0.5);
      // 带内贴图面片：把「半透明绿 + 板面网格 + 竖排白字」烘进贴图，贴在板面上（随板节点一起变换）。
      const g: MeshGeometry = buildZoneLabelQuad(x0, x1, zc0, zc1);
      if (g.vertices.length === 0) {
        continue;
      }
      const texMat: Material | null = await this.ensureZoneTexMaterial(z.side, x0, x1, zc0, zc1);
      const node: Geometry | null = await this.appendGeometry(plate, g, texMat, `nozzle_${z.side}`);
      if (node !== null) {
        if (z.side === 'left') { this.zoneNodeL = node; } else { this.zoneNodeR = node; }
      }
      if (edgeMat !== null) {
        const eg: MeshGeometry = buildNozzleBorder(x0, x1, zc0, zc1);
        if (eg.vertices.length > 0) {
          const enode: Geometry | null = await this.appendGeometry(plate, eg, edgeMat, `nozzleEdge_${z.side}`);
          if (enode !== null) {
            this.nozzleEdgeNode = enode;
          }
        }
      }
      const width: number = Math.abs(z.maxX - z.minX);
      const cxContent: number = (x0 + x1) * 0.5;
      const czContent: number = (zc0 + zc1) * 0.5;
      const halfW: number = Math.abs(x1 - x0) * 0.5;
      // 相交检测用矩形（内容坐标，与区域贴图面片同一组 x0/x1/zc0/zc1）
      const rect: BoundsXZ = new BoundsXZ();
      rect.minX = Math.min(x0, x1);
      rect.maxX = Math.max(x0, x1);
      rect.minZ = Math.min(zc0, zc1);
      rect.maxZ = Math.max(zc0, zc1);
      if (z.side === 'left') {
        left = true;
        this.zoneLeftWidth = Math.max(this.zoneLeftWidth, width);
        this.zoneLeftCenterX = cxContent;
        this.zoneLeftCenterZ = czContent;
        this.zoneLeftHalfW = halfW;
        this.zoneRectL = rect;
      } else {
        right = true;
        this.zoneRightWidth = Math.max(this.zoneRightWidth, width);
        this.zoneRightCenterX = cxContent;
        this.zoneRightCenterZ = czContent;
        this.zoneRightHalfW = halfW;
        this.zoneRectR = rect;
      }
      bounds.push(`${z.side} abs[${z.minX.toFixed(2)},${z.maxX.toFixed(2)}]x[${z.minY.toFixed(2)},${z.maxY.toFixed(2)}]`
        + ` -> X[${x0.toFixed(2)},${x1.toFixed(2)}] Z[${zc0.toFixed(2)},${zc1.toFixed(2)}]`);
    }
    this.zoneLeftVisible = left;
    this.zoneRightVisible = right;
    this.zoneBoundsLogged = bounds.join(' ; ');
    this.logNozzleZones('已绘制 ' + list.length.toString() + ' 个专属区');
  }

  // 单喷嘴区【边框】材质：Unlit 更亮的品牌绿（Theme.accentSoft #33E0B0），不透明（不发光）。只建一次复用。
  private async ensureNozzleEdgeMaterial(): Promise<Material | null> {
    if (this.nozzleEdgeMat !== null) {
      return this.nozzleEdgeMat;
    }
    if (this.factory === null) {
      return null;
    }
    const raw: Material | null = await this.factory.createMaterial({ name: 'nozzleZoneEdgeMat' }, MaterialType.UNLIT);
    if (raw === null) {
      AppLog.warn('NozzleArea', 'createMaterial(nozzleZoneEdgeMat) 返回空 → 单喷嘴区边框不可用');
      return null;
    }
    const m: UnlitMaterial = raw as UnlitMaterial;
    const rgb: Vec3 = this.hexToVec3(Theme.accentSoft);
    m.baseColor.factor = { x: rgb.x, y: rgb.y, z: rgb.z, w: 1.0 };
    m.cullMode = CullMode.NONE;
    this.nozzleEdgeMat = m;
    return raw;
  }

  // 单喷嘴区【贴图】材质（左/右各一）：Unlit + baseColor.image，不透明（本机不支持真 alpha 混合）。
  // 贴图在 createZoneImage 里按当前带尺寸生成 → 每次重建都把 baseColor.image 换成新贴图。
  private async ensureZoneTexMaterial(side: string, x0: number, x1: number, z0: number, z1: number): Promise<Material | null> {
    let mat: UnlitMaterial | null = side === 'left' ? this.zoneTexMatL : this.zoneTexMatR;
    if (mat === null) {
      if (this.factory === null) {
        return null;
      }
      const raw: Material | null = await this.factory.createMaterial({ name: `nozzleZoneTex_${side}` }, MaterialType.UNLIT);
      if (raw === null) {
        AppLog.warn('NozzleArea', 'createMaterial(nozzleZoneTex_%{public}s) 返回空 → 单喷嘴区不可用', side);
        return null;
      }
      mat = raw as UnlitMaterial;
      mat.baseColor.factor = { x: 1.0, y: 1.0, z: 1.0, w: 1.0 };  // 颜色全在贴图里，factor 保持白
      mat.cullMode = CullMode.NONE;
      if (side === 'left') { this.zoneTexMatL = mat; } else { this.zoneTexMatR = mat; }
    }
    const img: Image | null = await this.createZoneImage(side, x0, x1, z0, z1);
    if (img !== null) {
      mat.baseColor.image = img;
    }
    return mat;
  }

  // 生成单侧贴图 Image：绝不用 $rawfile（本机实测被解析成 file:// 空路径而失败）；
  // 改为 OffscreenCanvas 画好 → PixelMap → 打包 PNG 写进沙箱 → 用【文件路径】createImage。
  private async createZoneImage(side: string, x0: number, x1: number, z0: number, z1: number): Promise<Image | null> {
    const f: SceneResourceFactory | null = this.factory;
    if (f === null) {
      return null;
    }
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined || ctx === null) {
        hilog.warn(0x0000, 'NozzleTex', 'getHostContext 为空 → 无法写沙箱贴图');
        return null;
      }
      const dst: string = `${ctx.cacheDir}/zone_${side}.png`;
      const ok: boolean = await this.drawZoneTexture(dst, side, x0, x1, z0, z1);
      if (!ok) {
        return null;
      }
      const img: Image | null = await f.createImage({ name: `nozzleZoneImg_${side}`, uri: dst });
      if (img !== null) {
        hilog.info(0x0000, 'NozzleTex', 'createImage(%{public}s) 成功', dst);
        return img;
      }
      hilog.warn(0x0000, 'NozzleTex', 'createImage(%{public}s) 返回空', dst);
    } catch (e) {
      hilog.warn(0x0000, 'NozzleTex', '生成单喷嘴区贴图失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    return null;
  }

  // 把「半透明绿底色 + 板面网格（10mm 一格，与 buildGridLines 同口径） + 竖排白字」画成一张不透明 PNG。
  // 贴图坐标：横向 u ↔ 板面 Z（带长方向）；纵向 v ↔ 板面 X，且因 buildZoneLabelQuad 为修文字镜像
  // 已把 v 取反（v=1→minX、v=0→maxX），故这里 X 方向的网格行号也按同一反转落位，保持与板实体网格对齐。
  private async drawZoneTexture(path: string, side: string, x0: number, x1: number, z0: number, z1: number): Promise<boolean> {
    try {
      const bandWid: number = Math.abs(x1 - x0);   // 带宽（沿板 X）
      const bandLen: number = Math.abs(z1 - z0);   // 带长（沿板 Z）
      if (bandWid <= 0 || bandLen <= 0) {
        return false;
      }
      const zMin: number = Math.min(z0, z1);
      const xMin: number = Math.min(x0, x1);
      const scale: number = ZONE_TEX_LONG_PX / bandLen;   // px/mm
      const W: number = Math.max(16, Math.round(bandLen * scale));
      const H: number = Math.max(8, Math.round(bandWid * scale));
      const off = new OffscreenCanvas(W, H);
      const c = off.getContext('2d');
      // 1) 底色：半透明绿（品牌绿叠在深色板面上的合成观感）
      c.fillStyle = ZONE_BAND_HEX;
      c.fillRect(0, 0, W, H);
      // 2) 板面网格线（10mm 一格，原点在板中心 → 与板实体网格线位置一致）
      c.strokeStyle = ZONE_GRID_HEX;
      c.lineWidth = 1;
      const step: number = 10;
      const nz: number = Math.floor(this.plateH / step);
      for (let j = 0; j <= nz; j++) {
        const zg: number = -this.plateH * 0.5 + j * step;
        if (zg > zMin && zg < zMin + bandLen) {
          const px: number = Math.round(((zg - zMin) / bandLen) * W) + 0.5;
          c.beginPath(); c.moveTo(px, 0); c.lineTo(px, H); c.stroke();
        }
      }
      const nx: number = Math.floor(this.plateW / step);
      for (let i = 0; i <= nx; i++) {
        const xg: number = -this.plateW * 0.5 + i * step;
        if (xg > xMin && xg < xMin + bandWid) {
          // v 已取反（minX↔v=1）：行号按反转落位才与板实体网格对齐
          const py: number = Math.round(((xMin + bandWid - xg) / bandWid) * H) + 0.5;
          c.beginPath(); c.moveTo(0, py); c.lineTo(W, py); c.stroke();
        }
      }
      // 3) 文字（贴图里横排；UV 把贴图横向映射到板 Z → 板面上呈「沿带方向」的竖排）
      //    带太窄（H2C 右带 5mm）→ 不画字，只保留色块（不为了塞字把带画宽）。
      if (bandWid >= ZONE_LABEL_MIN_BAND) {
        const label: string = side === 'left' ? '仅左侧可打印区域' : '仅右侧可打印区域';
        let fontPx: number = H * 0.6;
        c.font = `400 ${fontPx}px sans-serif`;
        const maxTw: number = W * 0.94;
        const tw: number = c.measureText(label).width;
        if (tw > maxTw && tw > 0) {
          fontPx = fontPx * maxTw / tw;
          c.font = `400 ${fontPx}px sans-serif`;
        }
        c.fillStyle = ZONE_TEXT_HEX;
        c.textAlign = 'center';
        c.textBaseline = 'middle';
        c.fillText(label, W * 0.5, H * 0.5);
      }
      // 4) PixelMap → PNG → 沙箱文件
      const pm: image.PixelMap = c.getPixelMap(0, 0, W, H);
      const packer: image.ImagePacker = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packToData(pm, { format: 'image/png', quality: 100 });
      await pm.release();
      packer.release();
      const fh = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fh.fd, buf);
      fs.closeSync(fh);
      hilog.info(0x0000, 'NozzleTex', '贴图已生成 %{public}s (%{public}dx%{public}d)', path, W, H);
      return true;
    } catch (e) {
      hilog.warn(0x0000, 'NozzleTex', 'drawZoneTexture 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return false;
    }
  }

  // 板形自证日志（hilog + 应用日志 + gcode_diag.txt 三通道）。
  // 去重键含「机型 + 板模型 + 请求模型」：同尺寸但换了机型（如 H2D ↔ H2D Pro）也各自出一条，
  // 不会再被"盘面尺寸一致"整行去重吞掉。
  private logPlateShape(model: string, drew: boolean): void {
    const line: string = `[BedShape] 机型板形: 机型=${this.platePrinter.length > 0 ? this.platePrinter : '(无)'}`
      + ` 盘面 ${this.plateW.toFixed(1)}×${this.plateH.toFixed(1)}mm`
      + ` 板模型=${this.bedPlateSrc}(尺寸 ${this.bedPlateW.toFixed(1)}×${this.bedPlateH.toFixed(1)}mm)`
      + ` 映射=绝对床坐标1:1(平移=${((this.bedBBoxMinX + this.bedBBoxMaxX) * 0.5 - this.plateW * 0.5).toFixed(1)},`
      + `${(this.plateH * 0.5 - (this.bedBBoxMinY + this.bedBBoxMaxY) * 0.5).toFixed(1)})`
      + ` 绘制=${drew ? '是' : '否'}`;
    const key: string = line + `|请求模型=${model}`;
    if (key === this.plateShapeLogged) {
      return;
    }
    this.plateShapeLogged = key;
    hilog.info(0x0000, 'BedShape', '%{public}s (请求模型=%{public}s)', line, model.length > 0 ? model : '(无)');
    AppLog.note('BedShape|板形', line);
    this.appendModelDiag('板形诊断', [line]);
  }

  // 单喷嘴区自证日志（三通道）。数据来源写死为「预设 extruder_printable_area」，绝不出现"推导值"。
  // 去重键含「机型 + 左右有无 + 左右宽度 + 区域矩形数值」：每个机型都能各出一条（含"无专属区"的机型），
  // 且带宽度真值 + 区域矩形在「绝对床坐标 / 内容坐标」下的数值 + 颜色常量，便于逐机核对与证明对齐。
  private logNozzleZones(status: string): void {
    const line: string = `[NozzleArea] 单喷嘴专属区: 机型=${this.platePrinter.length > 0 ? this.platePrinter : '(无)'}`
      + ` 左=${this.zoneLeftVisible ? '有' : '无'}(${this.zoneLeftWidth.toFixed(1)}mm)`
      + ` 右=${this.zoneRightVisible ? '有' : '无'}(${this.zoneRightWidth.toFixed(1)}mm)`
      + ` 颜色=填充${Theme.accent}/边框${Theme.accentSoft}`
      + ` 板模型绝对bbox=[${this.bedBBoxMinX.toFixed(1)},${this.bedBBoxMinY.toFixed(1)}]~[${this.bedBBoxMaxX.toFixed(1)},${this.bedBBoxMaxY.toFixed(1)}]`
      + ` 映射=绝对床坐标1:1(减盘中心 ${(this.plateW * 0.5).toFixed(1)},${(this.plateH * 0.5).toFixed(1)})`
      + (this.zoneBoundsLogged.length > 0 ? ` 矩形=${this.zoneBoundsLogged}` : '')
      + ` 来源=预设extruder_printable_area ${status}`;
    if (line === this.nozzleLogged) {
      return;
    }
    this.nozzleLogged = line;
    hilog.info(0x0000, 'NozzleArea', '%{public}s', line);
    AppLog.note('NozzleArea|单喷嘴区', line);
    this.appendModelDiag('单喷嘴区诊断', [line]);
  }

  private clearPlateGroup(): void {
    // 盘面节点即将销毁 → 一并清掉恢复用的引用，避免恢复时写到已销毁的几何上
    this.plateBedNode = null;
    this.plateGridNode = null;
    this.plateBorderNode = null;
    this.nozzleEdgeNode = null;
    this.zoneNodeL = null;
    this.zoneNodeR = null;
    if (this.plateNode !== null) {
      const parent: Node | null = this.plateNode.parent;
      if (parent !== null) {
        parent.children.remove(this.plateNode);
      }
      this.plateNode.destroy();
      this.plateNode = null;
    }
  }

  // 打印板尺寸变化（右侧切换打印机）→ 重建盘面并重新取景。
  // plateW/plateH 是两个独立的 AppStorage 键，切一次会各触发一次；
  // 用 setTimeout 合并到同一轮，再走串行链重建，避免并发创建出多块盘面（网格重叠）。
  private onPlateChanged(propName: string): void {
    // 去重条件（写进日志便于核对）：三者全同才跳过 ——
    //   ① 盘面尺寸（plateW×plateH）  ② 机型名 + 板模型名（机型/板模型变化必须重建，尺寸相同也重建）
    //   ③ plateRev 代次（参数面板每次切机型都自增，兜住①②都相同但换了机型的极端情形）
    const sameSize: boolean = this.plateW === this.lastPlateW && this.plateH === this.lastPlateH;
    const sameMachine: boolean = this.platePrinter === this.lastPlatePrinter
      && this.plateBedModel === this.lastPlateModel;
    if (sameSize && sameMachine && this.plateRev === this.lastPlateRev) {
      return;
    }
    // 盘尺寸变了 → 按「content 盘 → 新盘」做换盘补偿（保持绝对床坐标不变，见 ModelState.syncPlateTo）。
    // 放在下面的 setTimeout 里：plateW/plateH 是两个键、各触发一次，放外面会平两遍。
    if (this.plateTimer >= 0) {
      clearTimeout(this.plateTimer);
    }
    this.plateTimer = setTimeout(() => {
      this.plateTimer = -1;
      const s = modelState.syncPlateTo(this.plateW, this.plateH);
      if (s.applied) {
        // 3D 节点与 UI 都跟着刷新（与「整理摆放」同一套收尾：改完位置要 applyTransform + publish）
        for (const m of modelState.instances) {
          this.applyTransform(m);
        }
        modelState.publish();
        // 换盘补偿改的是「content 坐标系」本身（同一绝对位置在两块盘上 content 值不同），
        // 旧的撤销快照仍是旧坐标系 → 必须重建撤销基线，否则「切完打印机再撤销」会把模型整体偏 38mm。
        // 代价：切换机型会清空撤销栈（与「打开新工程」同一处理，语义上可接受）。
        history.reset();
        hilog.info(0x0000, 'BedShape',
          '换盘补偿: 盘面 %{public}s×%{public}s → %{public}s×%{public}s dx=%{public}s dz=%{public}s',
          s.fromW.toFixed(1), s.fromH.toFixed(1),
          this.plateW.toFixed(1), this.plateH.toFixed(1),
          s.dx.toFixed(2), s.dz.toFixed(2));
      }
      this.lastPlateW = this.plateW;
      this.lastPlateH = this.plateH;
      this.lastPlateRev = this.plateRev;
      this.lastPlateModel = this.plateBedModel;
      this.lastPlatePrinter = this.platePrinter;
      hilog.info(0x0000, 'BedShape',
        '盘面重建触发: 机型=%{public}s 板模型=%{public}s 尺寸=%{public}s×%{public}s plateRev=%{public}d (去重条件: 尺寸/机型+板模型/plateRev 全同才跳过)',
        this.platePrinter.length > 0 ? this.platePrinter : '(无)',
        this.plateBedModel.length > 0 ? this.plateBedModel : '(无)',
        this.plateW.toFixed(1), this.plateH.toFixed(1), this.plateRev);
      this.queuePlateRebuild().then(() => {
        // 切换打印板后重置视角（同「重置视角」按钮）
        this.updateFit();
        this.resetView();
        this.updateBounds();
      });
      // 路径几何依赖 plateW/plateH，尺寸变了旧几何作废，需要整棵树重建
      this.destroyToolpath();
      this.requestToolpath();
    }, 0);
  }

  // 串行化盘面重建：总是排在上一轮之后，保证同一时刻只有一块盘面。
  // 关键：链尾挂一个 catch —— 若某一轮抛异常，绝不能让 plateChain 变成 rejected 的「死链」
  // （否则之后所有 .then 都被跳过，切打印机再也不会重建盘面，看起来就是「板子坏了」）。
  private queuePlateRebuild(): Promise<void> {
    this.plateChain = this.plateChain
      .then((): Promise<void> => this.buildPlateGroup())
      .catch((e: Error): void => {
        AppLog.warn('PreviewWarn', '盘面重建失败: %{public}s', e.message);
      });
    return this.plateChain;
  }

  // ---------------------------------------------------------------------------
  // 切片路径预览（由 GcodePreview 控制层通过 gcodeSignals 驱动）
  // ---------------------------------------------------------------------------
  // 核心：滑层只切可见性，不重建几何。每层的棱柱网格只为它建一次并缓存下来。
  // 之前每动一格重建两万段是做不到实时的；而且新旧两套几乎重合的几何同时在场会
  // Z-fighting，看起来就是一片乱闪。
  private onGcodeState(propName: string): void {
    // gcodeShow 的变化是「控制层自己触发的显示/隐藏」，不是用户对本控制层 UI 的操作：
    // 若把它当成外部重建去 cancelSweep，就会把 reload() 刚启动的扫层掐掉 ——
    // @StorageProp 的通知晚一拍送达，正好落在 startSweep() 之后（这就是上次扫层看不到的时序竞争）。
    // 所以这里标记 selfTriggered=true：仍然请求一次重建（保证离开预览时撤几何、场景未就绪时补一次），
    // 但不打断扫层。用户拖滑条走 gcodeSignals.rebuild（selfTriggered=false）→ 会正常打断扫层。
    this.requestToolpath(true);
    // 模型预览与切片路径共用同一个场景（阴影是场景级的），两者档位不同 → 进/出切片路径时按各自档位重设。
    this.applyShadowLevel(this.gcodeShow ? SHADOW_SAMPLE_COUNT_GCODE : SHADOW_SAMPLE_COUNT_MODEL);
    // 同理：渲染开关的「仅切片路径」范围也随模式切换生效/失效，这里重算一次（不写日志，避免噪音）。
    this.applyRenderTune('');
    // 回到「模型态」（gcodeShow=false）：右上角悬空告警才会重新出现 —— 这里按已加载模型重算一次，
    // 保证「该显示时一定显示」，不会因为中途进过切片路径而被丢掉。
    if (!this.gcodeShow) {
      // 【显式把模型放回原位】此前模型恢复完全依赖「gcodeShow 由 true→false 这一拍」去触发
      // updateToolpath 里的 applyTransform（AppStorage 通知晚一拍才到，是一次隐式副作用）。
      // 这里在 gcodeShow==false 时再显式、幂等地把每个实例的变换写回一次，确保「只要切回模型态，
      // 模型一定回到原位」——不再依赖单一通知时序，避免出现「模型还停在视锥外(HIDDEN_POS)」的空白画面。
      this.reassertModelVisibility();
      this.refreshSupportWarn('回到模型态', '已加载');
    }
  }

  private requestToolpath(selfTriggered: boolean = false): void {
    // 只有「用户的主动操作」（拖滑条 / 换盘面尺寸等）才打断扫层，不和用户抢。
    if (!selfTriggered) {
      this.cancelSweep('用户操作重建');
    }
    this.kickToolpath();
  }

  // 真正把「重建」排进合并管线（按帧合并：连续请求只保留最后一次，见 scheduleToolpath）
  private kickToolpath(): void {
    this.gcodeDirty = true;
    if (!this.gcodeBusy) {
      this.scheduleToolpath();
    }
  }

  // 按帧合并滑条事件：拖动会以「每帧一次、甚至更高」的频率触发重建请求。
  // 这里只在「没有待执行任务」时排一次 ~16ms（一帧）的定时器，已排定就不再重置 ——
  // 保证连续拖动时每帧真正应用一次「最新层号」，中间态全部丢弃。
  // （旧写法每次 clearTimeout 重新计时：连续拖动时事件间隔常 <16ms，定时器会被无限推迟，
  //  反而把更新饿死；这样既没做到按帧生效，又让每一次生效都背上全量遍历的代价。）
  private scheduleToolpath(): void {
    if (this.gcodeTimer >= 0) {
      return;
    }
    this.gcodeTimer = setTimeout(() => {
      this.gcodeTimer = -1;
      this.runToolpath();
    }, 16);
  }

  private runToolpath(): void {
    if (!this.gcodeDirty) {
      return;
    }
    this.gcodeDirty = false;
    this.gcodeBusy = true;
    this.updateToolpath().then(() => {
      this.gcodeBusy = false;
      if (this.gcodeDirty) {
        this.scheduleToolpath();
      } else {
        // 空闲时后台把剩下的层补齐，避免快速滑动时现场建几何而卡顿
        this.schedulePrebuild();
      }
    }).catch((e: Object) => {
      // ★【必须解锁构建泵】否则一次异常就会把 gcodeBusy 永久钉在 true：
      //   之后所有 requestToolpath/kickToolpath 都会因「!gcodeBusy」不成立而不排管线 ——
      //   这正是「降级重建后没有任何新的 [GcodeChunk]、几何始终建不起来」的成因之一。
      //   这里兜底把泵解锁，并在还有待建请求时立刻重排一次。
      this.gcodeBusy = false;
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'PreviewWarn', '切片路径重建异常（已解锁构建泵）: %{public}s', msg);
      AppLog.warn('PreviewWarn', '切片路径重建异常（已解锁构建泵）: %{public}s', msg);
      if (this.gcodeDirty) {
        this.scheduleToolpath();
      }
    });
  }

  private clearToolpathNode(node: Node | null): void {
    if (node === null) {
      return;
    }
    const parent: Node | null = node.parent;
    if (parent !== null) {
      parent.children.remove(node);
    }
    node.destroy();
  }

  private destroyToolpath(): void {
    // 记一笔「本轮发生过销毁重建」：下一次 applyLayerVisibility 的验收日志会读走并复位它
    // （拖动期间该值必须恒为 false —— 这正是「无重建」的自证）。
    this.rebuiltSinceLastVisLog = true;
    if (this.prebuildTimer >= 0) {
      clearTimeout(this.prebuildTimer);
      this.prebuildTimer = -1;
    }
    this.clearToolpathNode(this.toolpathRoot);
    this.toolpathRoot = null;
    // ⑤ 代次 +1：让「构建中持有的旧代次」立刻失效，后续异步 append 前校验会拦截。
    this.toolpathSeq++;
    this.chunkNodes = [];
    this.builtLayers = 0;
    this.lastVisChunks = 0;   // 复位：换 gcode / 切走页签后绝不能残留旧的可见区间
    this.chunkParts = [];
    this.chunkLayerCounts = [];
    this.chunkGeomNodes = [];
    this.chunkSlots = [];
    this.resetPendingParts();  // 当前块的逐层累积几何一并丢弃（绝不与块几何双份占内存）
    this.gcodeVertCount = 0;
    this.perfTick = 0;
  }

  // ⑤ 本轮构建是否仍安全可 append：路径树代次未变（未被 destroyToolpath 作废）且根节点仍在场。
  private toolpathAlive(seq: number): boolean {
    return this.toolpathSeq === seq && this.toolpathRoot !== null;
  }

  // ---------------------------------------------------------------------------
  // 前台恢复：失焦 / 前后台切换后重贴材质
  // ---------------------------------------------------------------------------
  // 真因（用户实测触发条件 + 应用内诊断文件排除法共同定位）：
  //   窗口失焦 / 前后台切换时，ArkGraphics3D 会重建渲染表面；已缓存的 materialOverride 随之丢失，
  //   几何回落到引擎默认材质 → 肉眼就是「切片路径变灰」；打印板/网格「变灰/消失」高度怀疑同源。
  //   诊断文件已证明数据与配色完全正常（角色分布、未识别 feature、配色表自检、材质回退次数全对），
  //   所以这里只做一件事：回到前台时把每个几何节点的材质「按记录重新贴一遍」，并恢复渲染状态。
  // 观测说明：引擎没有暴露「表面是否被重建 / 上下文是否丢失」的回调，无法直接观测；本代码只能
  //   如实记录「这一轮重贴了多少个几何」，靠恢复前后对比来判断是否确有必要（见下方 [RenderResume] 日志）。
  private onRenderResume(propName: string): void {
    const src: string = this.renderResumeSrc !== '' ? this.renderResumeSrc : 'unknown';
    // 第一轮：在回调里立刻做一次。
    this.resumeRender(src, false);
    // 第二轮：引擎很可能在本回调之后才真正完成表面重建，下一帧再补一次才稳（两轮都打日志）。
    setTimeout((): void => {
      this.resumeRender(src, true);
    }, 0);
  }

  // 执行一轮材质恢复（secondRound 仅用于日志区分与降级触发）。
  private resumeRender(src: string, secondRound: boolean): void {
    const round: string = secondRound ? '是' : '否';
    try {
      if (this.scene === null || this.factory === null) {
        // 场景尚未初始化：此刻没有任何材质绑定可谈（也没有会变灰的几何），如实记录后返回。
        this.logResume(`恢复材质 触发=${src} 切片层=0 重贴几何=0 模型=0 盘面=0 第二轮=${round}（场景未就绪）`);
        return;
      }
      const tp: ResumeCounts = this.rematerialToolpath();
      const models: number = this.rematerialModels();
      const plate: number = this.rematerialPlate();
      this.logResume(`恢复材质 触发=${src} 切片块=${tp.chunks} 重贴几何=${tp.geoms} 模型=${models} 盘面=${plate} 第二轮=${round}`);
      // 降级触发条件：本应重贴到切片几何却一个都没命中（几何引用丢失 / 层级被引擎整体丢弃）。
      // 只在第二轮判定，避免第一轮「表面还没重建完」的误判引发不必要的重建。
      if (secondRound && tp.geoms === 0 && this.gcodeShow && this.builtLayers > 0) {
        this.rebuildToolpathFallback();
      }
    } catch (e) {
      // 不吞异常：恢复失败必须留痕（这是「不连设备也能自证」的出口）
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'RenderResume', '恢复材质异常: %{public}s', msg);
      AppLog.warn('PreviewWarn', '恢复材质异常: %{public}s', msg);
    }
  }

  // 切片路径：逐块重贴角色材质，并把块可见性收敛回「记录里的一致状态」。
  private rematerialToolpath(): ResumeCounts {
    const out: ResumeCounts = new ResumeCounts();
    const root: Node | null = this.toolpathRoot;
    if (root === null) {
      return out;
    }
    if (this.gcodeShow) {
      // 路径根被引擎丢弃可见性时兜底打开（进预览时本就是 true）
      root.visible = true;
    } else {
      // 隐藏态（准备页 / 预览页的模型态 / 保活隐藏）：前台恢复绝不能把「本应隐藏的路径」重新显示出来
      // （那会让模型页显示成切片路径），所以这里务必把根节点收敛回不可见。
      // 这里只动根节点、不动块可见性：块仍按 lastVisChunks 记录的状态保留，切回切片路径时可原样复用。
      root.visible = false;
    }
    const chunks: number = this.chunkNodes.length;
    out.chunks = chunks;
    for (let ci: number = 0; ci < chunks; ci++) {
      // 可见性必须回到我们记录的状态（朴素前缀 [0, lastVisChunks) 个块可见），
      // 绝不能因为「恢复」把块可见性重置 —— 否则用户滑到的层会跳回去。复用差值管线用的
      // setChunkVisible，保持「只动登记在 chunkNodes、且父节点是 toolpathRoot 的块」这一道闸。
      this.setChunkVisible(ci, ci < this.lastVisChunks);
      const geos: Geometry[] = ci < this.chunkGeomNodes.length ? this.chunkGeomNodes[ci] : [];
      const slots: number[] = ci < this.chunkSlots.length ? this.chunkSlots[ci] : [];
      for (let gi: number = 0; gi < geos.length; gi++) {
        const slot: number = gi < slots.length ? slots[gi] : 0;
        // 取材质统一走 roleMaterialFor：越界 / 未就绪仍回退洋红兜底，绝不让绑定落到引擎默认灰
        const mat: Material | null = this.roleMaterialFor(slot);
        if (mat === null) {
          continue;
        }
        geos[gi].mesh.materialOverride = mat;
        out.geoms++;
      }
    }
    return out;
  }

  // 模型对象：把每个对象自己的材质（含自定义颜色）重新贴到它的几何节点上。
  private rematerialModels(): number {
    let n: number = 0;
    this.nodes.forEach((geo: Geometry, id: number): void => {
      const own: MetallicRoughnessMaterial | undefined = this.modelMats.get(id);
      const use: Material | null = own !== undefined ? own : this.modelMaterial;
      if (use !== null) {
        geo.mesh.materialOverride = use;
        n++;
      }
    });
    // 顺带把各对象自定义颜色重新写回各自材质（只写 baseColor，不重建几何、不重解析网格）
    this.applyAllInstanceColors();
    return n;
  }

  // 打印板 / 网格 / 边框：分别重贴 bedMat / gridMat / borderMat，并确保盘面节点存在且可见。
  private rematerialPlate(): number {
    if (this.plateNode === null) {
      // 盘面还没建 / 链式构建被打断（「网格消失」的兜底）→ 回前台时重建一次
      this.queuePlateRebuild();
      return 0;
    }
    this.plateNode.visible = true;
    let n: number = 0;
    if (this.plateBedNode !== null && this.bedMat !== null) {
      this.plateBedNode.mesh.materialOverride = this.bedMat;
      this.plateBedNode.visible = true;
      n++;
    }
    if (this.plateGridNode !== null && this.gridMat !== null) {
      this.plateGridNode.mesh.materialOverride = this.gridMat;
      this.plateGridNode.visible = true;
      n++;
    }
    if (this.plateBorderNode !== null && this.borderMat !== null) {
      this.plateBorderNode.mesh.materialOverride = this.borderMat;
      this.plateBorderNode.visible = true;
      n++;
    }
    if (this.zoneNodeL !== null && this.zoneTexMatL !== null) {
      this.zoneNodeL.mesh.materialOverride = this.zoneTexMatL;
      this.zoneNodeL.visible = true;
      n++;
    }
    if (this.zoneNodeR !== null && this.zoneTexMatR !== null) {
      this.zoneNodeR.mesh.materialOverride = this.zoneTexMatR;
      this.zoneNodeR.visible = true;
      n++;
    }
    if (this.nozzleEdgeNode !== null && this.nozzleEdgeMat !== null) {
      this.nozzleEdgeNode.mesh.materialOverride = this.nozzleEdgeMat;
      this.nozzleEdgeNode.visible = true;
      n++;
    }
    // 三个节点引用全丢（盘面被整体丢弃）→ 走重建兜底；材质本身缺失属初始化失败，不在此重复重建。
    if (this.plateBedNode === null && this.plateGridNode === null && this.plateBorderNode === null) {
      this.queuePlateRebuild();
    }
    return n;
  }

  // 降级手段（仅当「重贴材质没有命中任何切片几何」时触发，默认不会走到）：
  // 销毁整棵 toolpath 并重建几何 + 材质绑定。比「重贴材质」重得多（要重新 createMesh，可能卡顿/闪烁），
  // 但材质就绪时一定能恢复绑定；先只做轻量的重贴，是因为它不改几何、代价最小、不会引入闪烁。
  private rebuildToolpathFallback(): void {
    AppLog.warn('PreviewWarn', '恢复材质未命中几何 → 降级重建 toolpath（gen=%{public}d）', gcodeToolpath.generation);
    hilog.warn(0x0000, 'RenderResume', '降级重建 toolpath generation=%{public}d', gcodeToolpath.generation);
    this.destroyToolpath();
    // selfTriggered=true：不打断扫层（这里是恢复动作，不是用户操作）
    this.requestToolpath(true);
  }

  // [RenderResume] 日志：hilog + 应用内日志 + 诊断文件三处同写，
  // 让用户即便不连设备，也能在「日志」页或 files/diag/gcode_diag.txt 里看到恢复是否触发、重贴了多少。
  private logResume(text: string): void {
    hilog.info(0x0000, 'RenderResume', '%{public}s', text);
    try {
      AppLog.push(text);
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        return;
      }
      const ok: boolean = AppLog.writeDiagFile(`${ctx.filesDir}/diag/gcode_diag.txt`,
        [`[RenderResume] ${new Date().toLocaleString()} ${text}`]);
      if (!ok) {
        hilog.warn(0x0000, 'RenderResume', '恢复日志落盘失败');
      }
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'RenderResume', '恢复日志写入异常: %{public}s', msg);
    }
  }

  // 按 slot 取路径材质，保证【绝不返回 undefined / 引擎默认材质】。
  // slot = role + 1（见 GcodeToolpath 的 GcodeMeshPart.slot），所以材质下标 = slot - 1 = role。
  // 这条链路上只有两种「取不到」的情形，都必须留下证据、且都显式回退到洋红兜底：
  //   a) 下标越界（slot 不在合法范围）—— 说明建几何那边把桶号/角色号搞错了；
  //   b) 下标合法但该档材质为 null —— 说明 createMaterial 失败。
  // 为什么不能直接把下标塞进数组：越界会拿到 undefined，传给 materialOverride 就等于
  // 「无材质」，引擎会按自己的默认材质渲染（一层不可控的灰），且不会有任何告警。
  private roleMaterialFor(slot: number): Material | null {
    const idx: number = slot - 1;
    if (idx < 0 || idx >= this.roleMats.length) {
      this.noteMaterialMissing(slot, `下标越界（合法 1..${this.roleMats.length}）`);
      return this.fallbackMat;
    }
    const m: Material | null = this.roleMats[idx];
    if (m === null) {
      this.noteMaterialMissing(slot, '该档材质创建失败');
      return this.fallbackMat;
    }
    return m;
  }

  // 角色材质不可用告警（去重）：同一下标无论触发多少次只打有限的几条，并带累计次数。
  // 形如：角色材质不可用 role=3（该档材质创建失败）已发生 37 次 → 已回退洋红兜底材质
  // hilog 只打有限条；应用日志另用 note() 就地更新为真实累计次数（真机 / 诊断文件都可看）。
  private noteMaterialMissing(slot: number, reason: string): void {
    const key: string = `slot=${slot}`;
    const n: number = (this.oobMatCounts.get(key) ?? 0) + 1;
    this.oobMatCounts.set(key, n);
    const text: string = `角色材质不可用 role=${slot - 1}（${reason}）已发生 ${n} 次 → 已回退洋红兜底材质`;
    AppLog.note(`PreviewWarn|oobMat|${key}`, text);
    if (n === 1 || (n % 32) === 0) {
      hilog.warn(0x0000, 'PreviewWarn', '%{public}s', text);
    }
  }

  // 「材质回退/越界」总次数（所有 slot 之和）：[GcodeDiag] 用它一眼判断是否走了洋红兜底。
  // 0 = 每条路径都拿到了自己的角色材质 → 出现灰就与「材质缺失」无关，只剩特征映射 / 配色问题。
  private oobMaterialTotal(): number {
    let total: number = 0;
    this.oobMatCounts.forEach((v: number): void => {
      total += v;
    });
    return total;
  }

  // [GcodeDiag] 诊断块：每个 gcode 只输出一块（全部层建完、告警计数已到底时输出一次）。
  // 它把「灰」的两种成因一次性摆出来：
  //   · 「角色分布」里「其他」段数  → 多 = feature 未识别/映射问题；少 = 更像配色/下标问题；
  //   · 「材质回退/越界」次数       → >0 = 走了洋红兜底（那看到的就是洋红，不是灰）；
  //   · 「配色表」10 档颜色         → 哪一档本来就是灰/重复/缺失，一眼可见。
  private maybeEmitGcodeDiag(): void {
    if (this.builtLayers < gcodeToolpath.layerCount) {
      return;
    }
    if (this.diagGen === gcodeToolpath.generation) {
      return;
    }
    this.diagGen = gcodeToolpath.generation;
    const lines: string[] = gcodeToolpath.diagLines();
    lines.push(`[GcodeDiag] 角色材质回退/缺失：${this.oobMaterialTotal()} 次（>0 = 走了洋红兜底，看到的应是洋红而非灰）`);
    let pal: string = '';
    for (let r: number = 0; r < ROLE_COLOR_HEX.length; r++) {
      pal += `${r}=${ROLE_COLOR_HEX[r]}`;
      if (r + 1 < ROLE_COLOR_HEX.length) { pal += ' '; }
    }
    lines.push(`[GcodeDiag] 配色表 hex（图例与渲染同源）：${pal}`);
    lines.push(this.chunkSelfCheckLine());
    AppLog.pushBlock(lines);
    // 同一份诊断块再**落一份文件**：用户既抓不到 hilog，也进不去应用内日志页，
    // 这个文件是唯一能拿到的证据（见 writeDiagFile）。
    this.writeDiagFile(lines);
  }

  // 分块合并的自证行（一并写进 files/diag/gcode_diag.txt，不连设备也能核对）：
  //   · 「块内层数 = minN/maxN」应等于当前块大小 this.chunkLayers（最后一块允许不足）→ 证明每块都在按 N 层合并；
  //   · 「块内层数合计 = 应有层数」→ 证明合并【没有丢层】（逐层几何全部被搬进块几何，只是少了批次）；
  //   · 「可见块数 = K」→ 可见语义是块前缀，请求的层一定落在第 K 块内（误差 ≤ N-1 层）。
  // 只要这三项同时成立，画面就与合并前逐层一致（块内所有层都参与绘制，绝不是稀疏）。
  private chunkSelfCheckLine(): string {
    const chunks: number = this.chunkNodes.length;
    let sum: number = 0;
    let minN: number = chunks > 0 ? Number.MAX_SAFE_INTEGER : 0;
    let maxN: number = 0;
    for (let i: number = 0; i < this.chunkLayerCounts.length; i++) {
      const n: number = this.chunkLayerCounts[i];
      sum += n;
      if (n < minN) { minN = n; }
      if (n > maxN) { maxN = n; }
    }
    const total: number = gcodeToolpath.layerCount;
    const expect: number = Math.min(total, chunks * this.chunkLayers);
    const same: string = sum === expect ? '一致' : `不一致(差 ${sum - expect})`;
    return `[GcodeDiag] 分块合并：每块=${this.chunkLayers}层 块数=${chunks} ` +
      `块内层数=min${minN}/max${maxN} 合计=${sum} 应有层数=${expect} ${same} ` +
      `可见块数=${this.lastVisChunks}（块内所有层全部绘制，非稀疏；只减批次不减层）`;
  }

  // 把诊断块追加写入「应用沙箱内」的 filesDir/diag/gcode_diag.txt。
  // 目录与 output.gcode / slice_input.3mf 同级（都是 filesDir），保证沙箱内可写。
  // 追加不覆盖：换一份 gcode 就多一块，每块带 generation 与时间戳便于区分。
  private writeDiagFile(lines: string[]): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        AppLog.warn('PreviewWarn', '诊断文件写入跳过：获取上下文失败');
        return;
      }
      const path: string = `${ctx.filesDir}/diag/gcode_diag.txt`;
      const head: string[] = [`===== gcode#${gcodeToolpath.generation} ${new Date().toLocaleString()} =====`];
      const ok: boolean = AppLog.writeDiagFile(path, head.concat(lines));
      if (ok) {
        hilog.info(0x0000, 'GcodeDiag', '诊断块已落文件 %{public}s', path);
      }
    } catch (e) {
      // 不吞异常：落文件失败必须留痕（这是唯一的自证出口）
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      AppLog.warn('PreviewWarn', '诊断文件写入异常: %{public}s', msg);
    }
  }

  // 关键：先把几何节点藏起来、挂好材质，再入场景树。
  // 否则节点会以默认（白色）材质抢在 materialOverride 之前渲染一两帧——
  // 新建的层永远在堆叠最上方，看起来就是"模型正上方冒出一道白线"。
  // mat 必须非空（调用方已用 roleMaterialFor 保证）：绝不允许出现「无材质节点」。
  // 返回值 = 新几何节点（createMesh/createGeometry 失败时返回 null，跳过、不打脏场景），
  // 调用方据此登记引用，供「前台恢复」重贴材质（见 rematerialToolpath）。
  private async appendToolpathGeometry(parent: Node, g: MeshGeometry, mat: Material,
                                       name: string, seq: number): Promise<Geometry | null> {
    if (this.factory === null) {
      return null;
    }
    const cg: CustomGeometry = await this.toCustomGeometry(g);
    const meshRes: MeshResource | null =
      await this.factory.createMesh({ name: `${name}Mesh` }, cg);
    this.releaseCustomGeometry(cg, g);
    if (meshRes === null) {
      AppLog.warn('PreviewWarn', 'createMesh(%{public}s) 返回空 → 跳过该块路径', name);
      return null;
    }
    const geoNode: Geometry | null = await this.factory.createGeometry({ name: name }, meshRes);
    if (geoNode === null) {
      AppLog.warn('PreviewWarn', 'createGeometry(%{public}s) 返回空 → 跳过该块路径', name);
      return null;
    }
    // ★【⑤ 防御】createMesh/createGeometry 是长同步 NAPI，期间可能已切盘/换 gcode → 路径树被销毁。
    //   此时 parent 已被 destroy，parent.children 变 undefined；这里先校验代次，失效即丢弃（绝不 append）。
    if (!this.toolpathAlive(seq)) {
      AppLog.warn('PreviewWarn',
        '路径树已失效（构建期间被销毁/重建）→ 丢弃块几何 %{public}s，不 append 到已销毁节点', name);
      return null;
    }
    geoNode.mesh.materialOverride = mat;
    geoNode.visible = false;
    parent.children.append(geoNode);
    return geoNode;
  }

  // 补齐第 0..upto-1 层（懒建，已建过的直接跳过）。
  // **分块合并**：每层先用 buildLayer 建出「逐层几何」，随即按角色拼进「当前块」的累积几何
  // （顶点/法线数组首尾相接，索引统一加上该角色几何已有的顶点基址）；等本块凑满
  // this.chunkLayers 层（或已到总层数）时，才把累积几何真正建成场景几何、挂到一个块节点下，
  // 并立刻清空累积器 —— 所以不存在「逐层几何」与「块几何」双份占内存，也不是「每加一层重拼整块」的 O(n²)。
  // 关键：块内每一层都被原样拼进来，画面与合并前逐层一致（只减批次，绝不是稀疏）。
  private async ensureLayers(upto: number, seq: number): Promise<void> {
    const root: Node | null = this.toolpathRoot;
    if (root === null || this.factory === null) {
      return;
    }
    const total: number = gcodeToolpath.layerCount;
    const lim: number = Math.max(0, Math.min(total, Math.round(upto)));
    while (this.builtLayers < lim) {
      // ★【⑤ 防御】每轮先校验路径树仍存活（本轮代次未被 destroyToolpath 作废）；否则丢弃本块累积并退出。
      if (!this.toolpathAlive(seq)) {
        this.resetPendingParts();
        AppLog.warn('PreviewWarn', 'ensureLayers: 路径树已失效 → 中止本轮建几何（代次=%{public}d）', seq);
        return;
      }
      const li: number = this.builtLayers;
      const parts: GcodeMeshPart[] = gcodeToolpath.buildLayer(li, this.plateW, this.plateH);
      let verts: number = 0;
      for (const p of parts) {
        this.mergePartIntoPending(p);
        verts += p.geom.vertices.length;
      }
      this.gcodeVertCount += verts;
      this.builtLayers = li + 1;
      // 块收尾条件：本块已凑满 this.chunkLayers 层，或已经建到总层数（最后一块可能不足）。
      // 粒度切换会整棵销毁重建（builtLayers 归零），所以块起点恒与块大小对齐，取模判据成立。
      if (((this.builtLayers % this.chunkLayers) === 0) || this.builtLayers >= total) {
        await this.flushChunk(root, seq);
      }
    }
  }

  // 把「某一层某一角色」的几何拼进当前块同角色的累积几何：
  // 顶点/法线数组首尾相接；索引统一偏移 = 该角色几何在合并结果里的顶点基址（base = 已有顶点数）。
  // 这就是分块合并的最小单元：只搬数组、按基址偏移索引，不重新三角化、不改截面/层高/线宽。
  private mergePartIntoPending(p: GcodeMeshPart): void {
    const idx: number = p.slot - 1;
    if (idx < 0 || idx >= this.pendingParts.length) {
      AppLog.warn('PreviewWarn', '块合并槽位越界 slot=%{public}d → 跳过该段', p.slot);
      return;
    }
    let acc: MeshGeometry | null = this.pendingParts[idx];
    if (acc === null) {
      acc = new MeshGeometry();
      this.pendingParts[idx] = acc;
    }
    const base: number = acc.vertices.length;
    const vs: Vec3[] = p.geom.vertices;
    for (let i: number = 0; i < vs.length; i++) { acc.vertices.push(vs[i]); }
    const ns: Vec3[] = p.geom.normals;
    for (let i: number = 0; i < ns.length; i++) { acc.normals.push(ns[i]); }
    const is: number[] = p.geom.indices;
    for (let i: number = 0; i < is.length; i++) { acc.indices.push(is[i] + base); }
  }

  // 一块收尾：把当前块累积的「每角色一个大几何」建成场景几何，挂到一个块节点下，然后清空累积器。
  // 只有这里会 createMesh —— 每块每角色一次，所以批次数 = 块数 × 角色数（合并前是 层数 × 角色数）。
  // 一块即使全部角色都为空也照样建节点并登记，保证「块序号 ↔ 层区间」严格对齐（块 i 恒为
  // [i*N, min((i+1)*N, 总层数))）；否则可见性按块前缀推进时会把块映到错误的层区间，滑条语义就错了。
  private async flushChunk(root: Node, seq: number): Promise<void> {
    if (this.factory === null) {
      return;
    }
    const ci: number = this.chunkNodes.length;
    const l0: number = ci * this.chunkLayers;
    const l1: number = this.builtLayers;
    const cn: Node | null = await this.factory.createNode({ name: `tpC${ci}` });
    if (cn === null) {
      // 创建失败：本块不登记（可见性会自然跳过它），累积器照旧清空，避免污染下一块。
      AppLog.warn('PreviewWarn', 'createNode(tpC%{public}d) 返回空 → 该块跳过', ci);
      this.resetPendingParts();
      return;
    }
    // ★【⑤ 防御】createNode 是异步的，期间可能已切盘/换 gcode → root 已被 destroy（children 变 undefined）。
    //   这里先校验代次，失效就丢弃本块（不登记、不 append），绝不触发 "append of undefined"。
    if (!this.toolpathAlive(seq)) {
      AppLog.warn('PreviewWarn', 'flushChunk: 路径树已失效 → 丢弃整块 tpC%{public}d 不挂场景', ci);
      this.resetPendingParts();
      return;
    }
    cn.visible = false;
    root.children.append(cn);
    // 登记「已成功挂上的几何 + 其 slot」，供前台恢复按角色重贴材质（顺序与 children 一致）
    const geos: Geometry[] = [];
    const slots: number[] = [];
    let batches: number = 0;
    for (let s: number = 0; s < this.pendingParts.length; s++) {
      const g: MeshGeometry | null = this.pendingParts[s];
      if (g === null || g.vertices.length === 0) {
        continue;
      }
      batches++;
      // 取材质统一走 roleMaterialFor：越界 / 未就绪一律回退到专门兜底材质并去重告警，
      // 绝不把下标直接塞进数组（那会拿到 undefined → 引擎按「无材质」渲染成默认灰）。
      const mat: Material | null = this.roleMaterialFor(s + 1);
      if (mat === null) {
        // 连兜底材质都没有（场景初始化失败）：跳过该块，绝不留「无材质节点」。
        AppLog.warn('PreviewWarn', '路径材质与兜底均不可用 → 跳过 %{public}s', `tpC${ci}_${s + 1}`);
        continue;
      }
      const geoNode: Geometry | null = await this.appendToolpathGeometry(cn, g, mat, `tpC${ci}_${s + 1}`, seq);
      if (geoNode !== null) {
        geos.push(geoNode);
        slots.push(s + 1);
      }
    }
    this.chunkNodes.push(cn);
    this.chunkParts.push(batches);
    this.chunkLayerCounts.push(Math.max(0, l1 - l0));
    this.chunkGeomNodes.push(geos);
    this.chunkSlots.push(slots);
    this.resetPendingParts();
    hilog.info(0x0000, 'GcodeChunk',
      '块#%{public}d 层=[%{public}d,%{public}d) 层数=%{public}d 角色几何=%{public}d 批次数=%{public}d',
      ci, l0, l1, Math.max(0, l1 - l0), geos.length, batches);
  }

  // 清空当前块的逐层累积几何（块收尾后 / 销毁时调用）：避免与已建出的块几何双份占内存。
  // 槽位数与角色档数一致（11：role 0~10，含「辅助线」），否则 role 10 会被判越界丢弃。
  private resetPendingParts(): void {
    this.pendingParts = [null, null, null, null, null, null, null, null, null, null, null];
  }

  // ---- 分块粒度：本次 gcode 载入时「一次性」按总层数定死，之后绝不再变 --------------------
  // 选块大小只看【总层数】（与用户拖到第几层无关）：
  //   总层数 ≤ GCODE_CHUNK_SMALL_MAX(400) → 1 层/块（逐层手感）；> 400 → 4 层/块（省批次）。
  // 幂等：同一份 gcode（generation 未变）只会真正定一次 —— 这就是「本次会话内不再改变」的实现。
  // 为什么必须与「应可见层数」解耦：按应可见层数分档会让回拨跨过阈值时改变块大小，而块大小一变
  // 就必须 destroyToolpath 整棵重建，重建又会让可见性从头收敛 → 用户看到「回拨一下又重渲染一遍」。
  // 现在粒度与可见层数无关，因此拖动期间【永远不会有】销毁/重建/块重排。
  private decideChunkLayersOnce(): void {
    if (this.chunkLayersGen === gcodeToolpath.generation) {
      return;   // 本份 gcode 已定过：绝不二次改动
    }
    const total: number = gcodeToolpath.layerCount;
    const want: number = total > GCODE_CHUNK_SMALL_MAX ? GCODE_CHUNK_LARGE : GCODE_CHUNK_SMALL;
    const from: number = this.chunkLayers;
    this.chunkLayers = want;
    this.chunkLayersGen = gcodeToolpath.generation;
    const text: string = `[GcodeChunk] 粒度一次性决定（gcode#${gcodeToolpath.generation} 载入）` +
      ` 总层=${total} → 块大小=${want} 层/块（由 ${from} 变更；此后本次会话内不再改变）`;
    hilog.info(0x0000, 'GcodeChunk', '%{public}s', text);
    AppLog.push(text);
    this.writeChunkDiag(text);   // 三通道同写：不连设备也能在 files/diag/gcode_diag.txt 里核对
    // 换 gcode 时块边界变了 → 旧块几何作废，必须销毁重建（这是「gcode 变了」这一必要情形，
    // 绝不会由拖动触发：本方法只在 generation 变化那一轮被调用）。
    if (from !== want && this.chunkNodes.length > 0) {
      this.destroyToolpath();
    }
  }

  // 把 [GcodeChunk] 那行追加写进 files/diag/gcode_diag.txt（与 [GcodePerf] 同一条写入通道）。
  private writeChunkDiag(text: string): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) { return; }
      AppLog.writeDiagFile(`${ctx.filesDir}/diag/gcode_diag.txt`, [text]);
    } catch (e) {
      // 不吞异常：落文件失败必须留痕
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'GcodeChunk', 'Chunk 落文件异常: %{public}s', msg);
    }
  }

  // 设置「单块」的可见性：块节点和它的子几何都显式设置一遍，
  // 不去赌引擎的 visible 是否沿父节点继承。
  // 【作用域硬约束】只允许动「明确登记在 chunkNodes 里、且父节点就是 toolpathRoot」的块节点：
  //   - 绝不遍历通用 root（pivotNode / world / scene.root 下面还挂着打印板、网格、模型、
  //     手柄、高亮等节点，一旦误伤，表现就是「网格/打印板跟着被关掉」）；
  //   - 绝不按节点名做模糊匹配（改名/重名会误判）。
  // 这里的父节点校验是最后一道闸：即便 chunkNodes 被污染，也不会误关非 toolpath 节点。
  private setChunkVisible(ci: number, vis: boolean): void {
    if (ci < 0 || ci >= this.chunkNodes.length) {
      return;
    }
    const cn: Node = this.chunkNodes[ci];
    if (this.toolpathRoot === null || cn.parent !== this.toolpathRoot) {
      AppLog.warn('PreviewWarn', '块节点 %{public}d 不在 toolpath 根下 → 拒绝设置可见性', ci);
      return;
    }
    cn.visible = vis;
    const n: number = cn.children.count();
    for (let i: number = 0; i < n; i++) {
      const c: Node | null = cn.children.get(i);
      if (c !== null) {
        c.visible = vis;
      }
    }
  }

  // 应用「显示到第 cur 层」到场景（滑条变化 / 扫层 / 补建收敛都走这里）。
  //
  // 【滑条必须增量更新，禁止每次全量遍历块节点（那是 O(块数) 的卡顿源）】
  //   用 lastVisChunks 记住上一次已应用的可见块数，本次只动 [prev, c) 的那几块：
  //   —— 区间变大（向后滑）就把新增的块打开，区间变小（向前滑）就把多出来的块关掉，
  //      变大 / 变小都正确，且开销 = O(变化量)（合并后每次通常只变 0~1 块，比合并前更省）。
  //   —— lastVisChunks 会随「已建块数」增长：后台补建的新块下一帧被夹进区间时会被正确点亮
  //      （见下面的夹取逻辑），不会漏块、也不会残留可见。
  //
  // 【可见语义 = 块前缀「第 0..c-1 块全部可见」，c = 请求层 cur 所在块 + 1】
  //   可见性最小步进 = 一块（this.chunkLayers 层）。总层数 ≤ 400 时块大小 = 1 → 每拖一层界面就变
  //   （这就是「滑一格格地刷新」的手感来源）；> 400 时 = 4，误差 ≤ 3 层。这里取「cur 所在块」而不是
  //   「完全装得下的块」：保证「至少能看到你请求的那一层」，误差不超过 块大小-1 层
  //   （cur 很小、比如第 1 层时也一定会看到第 0 块，不会什么都看不到）。
  //   禁止任何稀疏 / 隔层显示：块内所有层都在几何里、都参与绘制。
  private applyLayerVisibility(cur: number): void {
    const t0: number = Date.now();
    const totalChunks: number = this.chunkNodes.length;
    // 请求层所在块（0 起）→ 要显示的块数；cur <= 0 时一块都不显示（扫层起点的全灭）
    const layer: number = Math.round(cur);
    const want: number = layer <= 0 ? 0 : Math.floor((layer - 1) / this.chunkLayers) + 1;
    const c: number = Math.max(0, Math.min(totalChunks, want));
    const prev: number = Math.max(0, Math.min(totalChunks, this.lastVisChunks));
    let changed: number = 0;
    if (c > prev) {
      // 区间变大（向后滑）：只把新增的 [prev, c) 块点亮
      for (let ci: number = prev; ci < c; ci++) {
        this.setChunkVisible(ci, true);
        changed++;
      }
    } else if (c < prev) {
      // 区间变小（向前滑）：只把多出来的 [c, prev) 块熄灭
      for (let ci: number = c; ci < prev; ci++) {
        this.setChunkVisible(ci, false);
        changed++;
      }
    }
    this.lastVisChunks = c;
    // 可见层数 = 可见块覆盖的层数（受「已建层数 / 总层数」限制），供日志自证
    const visLayers: number = Math.min(gcodeToolpath.layerCount,
      Math.min(this.builtLayers, c * this.chunkLayers));
    // 验收依据：改造后「更新块数」应 ≈ 本次变化量（而非块总数），耗时随之大幅下降。
    // 「重建」= 本次刷新前是否发生过 destroyToolpath：拖动（尤其回拨）期间必须恒为「否」——
    // 这就是「回拨不再整片重渲染」的日志自证（读走并复位 rebuiltSinceLastVisLog）。
    const rebuilt: string = this.rebuiltSinceLastVisLog ? '是' : '否';
    this.rebuiltSinceLastVisLog = false;
    hilog.info(0x0000, 'LayerSlider',
      '层滑条 到=%{public}d 可见块=%{public}d→%{public}d 变块=%{public}d 总块=%{public}d 重建=%{public}s 耗时=%{public}dms',
      layer, prev, c, changed, totalChunks, rebuilt, Date.now() - t0);
    this.logGcodePerf(c, visLayers, t0);
  }

  // 提交/更新路径的验收日志（tag: GcodePerf）。节流：每 30 次打一条（不每帧刷屏）。
  // 「帧耗时」拿不到引擎帧时间，这里如实标注为「我们的更新耗时」（本次 applyLayerVisibility 的耗时）。
  private logGcodePerf(visChunks: number, visLayers: number, t0: number): void {
    this.perfTick++;
    if ((this.perfTick % 30) !== 0) { return; }
    // 批次数 = 可见块的角色几何数之和（每块每角色一个几何 = 一次绘制）。
    // 合并前这里 = 「可见层 × 每层角色数」；合并后 = 「可见块 × 每块角色数」，通常下降数倍。
    let batches: number = 0;
    for (let ci: number = 0; ci < visChunks; ci++) {
      if (ci < this.chunkParts.length) { batches += this.chunkParts[ci]; }
    }
    // 真实节点数：从切片路径根节点递归统计（含每块的角色子节点）。
    // 官方基线：节点数「几百个以内」算健康，上千要警惕（节点/几何过多会拖慢渲染提交）。
    const nodes: number = this.toolpathRoot !== null ? this.countNodesRec(this.toolpathRoot) : 0;
    // 角色几何数 = 已真实挂进场景的角色子几何总数（取自 chunkGeomNodes 的真实登记，不做估算）
    let geoms: number = 0;
    for (let ci: number = 0; ci < this.chunkGeomNodes.length; ci++) {
      geoms += this.chunkGeomNodes[ci].length;
    }
    const text: string =
      `gcode 提交：可见层=${visLayers} 批次数=${batches} 顶点数=${this.gcodeVertCount} 节点数=${nodes} ` +
      `角色几何数=${geoms} 材质数=${this.roleMats.length} 更新耗时=${Date.now() - t0}ms(我们的更新耗时) ` +
      `FPS=${Math.round(this.fpsLast)}(最近1秒，与 [RenderTune] 同口径)`;
    hilog.info(0x0000, 'GcodePerf', '%{public}s', text);
    // 同一行也写进应用内日志与 files/diag/gcode_diag.txt（沿用现有写入通道，用户不连设备也能看）
    AppLog.push(`[GcodePerf] ${text}`);
    this.writePerfDiag(text);
  }

  // 递归统计某节点下的节点总数（含自身）：切片路径根 → 各块节点 → 每块的角色几何节点。
  private countNodesRec(node: Node): number {
    let n: number = 1;
    const cnt: number = node.children.count();
    for (let i: number = 0; i < cnt; i++) {
      const child: Node | null = node.children.get(i);
      if (child !== null) {
        n += this.countNodesRec(child);
      }
    }
    return n;
  }

  // 把 GcodePerf 那行追加写进 files/diag/gcode_diag.txt（与 [GcodeDiag] 同一文件、同一条写入通道）。
  private writePerfDiag(text: string): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        return;
      }
      AppLog.writeDiagFile(`${ctx.filesDir}/diag/gcode_diag.txt`, [`[GcodePerf] ${text}`]);
    } catch (e) {
      // 不吞异常：落文件失败必须留痕
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'GcodePerf', 'Perf 落文件异常: %{public}s', msg);
    }
  }

  private currentGcodeLayer(): number {
    const total: number = gcodeToolpath.layerCount;
    return Math.max(1, Math.min(total, Math.round(gcodeToolpath.currentLayer)));
  }

  private async updateToolpath(): Promise<void> {
    if (this.factory === null || this.pivotNode === null) {
      return;
    }
    // 页面不可见（保活的隐藏态）：不建切片路径几何；释放与否取决于 RELEASE_GCODE_ON_LEAVE。
    //   · true（旧策略）：若还有残留（释放通知晚一拍到）一并撤掉 —— 只销毁路径节点与缓存，
    //     场景 / 相机 / 材质 / 打印板始终保持（这就是「释放几何但不卸引擎」）。
    //   · false（新默认，保活）：隐藏期间【不】释放几何，只停住；切回来几何仍在、可直接呈现原状态
    //     （见 resumeGcodeKeepAlive）。这条路径本身不会新建几何（隐藏期间本就不该建），所以只 return。
    if (this.pausedByHidden) {
      if (this.toolpathRoot !== null && RELEASE_GCODE_ON_LEAVE) {
        this.cancelSweep('页面不可见');
        this.destroyToolpath();
      }
      return;
    }
    // 显示路径时把模型藏起来（applyTransform 里 gcodeShow 为真就落到 HIDDEN_POS）；
    // 反之 gcodeShow 为假时模型回到原位 —— 模型与路径是同一场景里的互斥显示，全部靠 gcodeShow 这一处开关。
    for (const inst of modelState.instances) {
      this.applyTransform(inst);
    }
    // 【唯一必须销毁的时机：gcode 变了】重新切片 / 换 gcode / generation 变化 → 旧几何彻底作废，
    // 只能整棵销毁重建（几何是按这份 gcode 的层号/线宽/层高算出来的，留着就是错的）。
    // 为什么只有这里必须销毁：除「数据本身换了」以外的所有场景（切非 3D 页 / 切准备页 / 预览页的
    // 模型态）都只是「换个地方看不见」，几何、块状态、滑条位置、相机视角全都还有效，销毁纯属浪费
    // —— 那正是用户抱怨的「切回切片路径要卡一下重新渲染」。所以这类切走一律【只隐藏、不销毁】。
    if (gcodeToolpath.generation !== this.lastGcodeGen) {
      this.destroyToolpath();
      this.lastGcodeGen = gcodeToolpath.generation;
      // 材质回退/越界计数按「一份 gcode」重新累计，[GcodeDiag] 里的次数才对应本份 gcode
      this.oobMatCounts.clear();
      // 新 gcode 载入 → 按【总层数】把块大小一次性定死（本份 gcode 的会话内绝不再变）：
      //   总层数 ≤ 400 → 1 层/块；> 400 → 4 层/块。此后无论用户怎么拖都不再改变块大小，
      //   因此拖动期间绝不会触发 destroyToolpath / 重建 / 块重排。
      this.decideChunkLayersOnce();
    }
    if (!this.gcodeShow || !gcodeToolpath.loaded) {
      // 路径应当隐藏（切走页签 / 准备页 / 预览页的模型态）：【只隐藏、不销毁】。
      // 只停掉揭示与后台补建定时器，再把路径根节点置为不可见即可；块节点/几何、lastVisChunks、
      // 层滑条位置、相机视角全部保留，切回来直接复用（不重建 / 不重跑 reload / 不重扫层）。
      // 为什么只动根节点：Node.visible 沿子树继承（建根节点时就是靠 visible=false 先把整棵路径藏住的），
      // 所以「根不可见」＝「整条路径不可见」；再逐块设 visible 会与 lastVisChunks 记录的状态脱节，
      // 反而破坏「切回来按记录恢复层可见性」。
      // 注意：进入预览的首拍，模型页这边的 @StorageProp('gcodeShow') 可能还没收到新值（读到旧 false）；
      // 此时 toolpathRoot 还是 null，下面这两条都自然落空，不会误隐藏 / 误停扫层。
      if (RELEASE_GCODE_ON_LEAVE) {
        // 逃生开关（旧行为）：离开即销毁几何，回来走 reload→重建。
        if (this.toolpathRoot !== null) {
          this.cancelSweep('路径已撤下');
        }
        this.destroyToolpath();
        this.refreshRendering();
        return;
      }
      if (this.toolpathRoot !== null) {
        this.cancelSweep('路径已隐藏');
        if (this.prebuildTimer >= 0) { clearTimeout(this.prebuildTimer); this.prebuildTimer = -1; }
        this.toolpathRoot.visible = false;
      }
      this.refreshRendering();
      return;
    }
    // 【路径材质就绪闸门】角色材质是在 initScene 里异步创建的；而 gcodeShow /
    // gcodeSignals.rebuild 可能在场景初始化还没走到创建材质那一步就先到了（@StorageProp 时序竞争）。
    // 此时若照常建几何，roleMats 还是空的 → 每一段都拿不到自己的材质 → 整片回退成灰。
    // 所以这里主动让位、什么都不建；initScene 建好材质后会补一次 kickToolpath。
    if (this.roleMats.length === 0) {
      hilog.info(0x0000, 'PreviewWarn', '路径材质尚未就绪 → 暂缓建几何（待场景初始化完成后重建）');
      return;
    }
    const cur: number = this.currentGcodeLayer();
    // 【粒度已在 gcode 载入时定死】这里【不再】按 cur 切档、也【不再】有去抖/滞回 —— 块大小与
    // 「当前可见层数」彻底解耦，所以拖动（尤其回拨）期间不会有任何 destroyToolpath / 重建 / 块重排。
    // 兜底：万一本轮之前 generation 判断没走到（如首次直接进路径），这里再补一次幂等对齐。
    this.decideChunkLayersOnce();
    if (this.toolpathRoot === null) {
      const nr: Node | null = await this.factory.createNode({ name: 'toolpath' });
      if (nr === null) {
        AppLog.warn('PreviewWarn', 'createNode(toolpath) 返回空 → 本轮路径重建跳过');
        return;
      }
      nr.visible = false;
      this.pivotNode.children.append(nr);
      this.toolpathRoot = nr;
    }
    // ★【⑤ 时间基准】本轮建几何持有的路径树代次：构建全程用它校验「树没被销毁/重建」。
    const buildSeq: number = this.toolpathSeq;
    // 从进入切片路径起、到所有层建完并收敛为止，广播「渲染中」（右上角提示据此显隐）
    this.refreshRendering();
    // 分批建 + 分批揭示：每批最多 GCODE_BUILD_CHUNK 层，建完一批立刻按当前目标层走
    // applyLayerVisibility 的差值管线揭示一次（只动新增区间，绝不退回全量遍历）。
    // 于是模型「自下而上逐层长出」；批与批之间让出一帧，让已建好的层真正画出来，
    // 同时也保证中途用户拖滑条时不会被长时间占住（批间检查 gcodeDirty 即可让位）。
    //
    // ★【来源标记：揭示动画只允许「首次进入切片路径的扫层」重放】(这就是 bug 的核心闸门)
    //   sweepActive 是本轮更新的来源标记：
    //     · true  = 首次进入切片路径（GcodePreview 进页签时调 startSweep）→ 保留自下而上逐批揭示；
    //     · false = 用户拖动 / 后台补建等一切「非首次进入」的更新 → 期间【绝不逐批揭示】，
    //       只把可见性一次性落到收敛目标（下面那句无条件收敛），几何是已有的、只是可见性变化，
    //       所以不会出现「从下往上长出来」的动画。
    //   为什么能这样判：任何由用户拖动引起的更新都会先经 requestToolpath(false) → cancelSweep，
    //   把 sweepActive 置回 false —— 因此「拖动过」天然等于「不属于首次进入」。
    while (this.builtLayers < cur) {
      if (this.gcodeDirty) {
        // 用户中途操作 → 交回新一轮更新接管，避免白建
        break;
      }
      // ★【⑤ 防御】批与批之间（含上一批的 await 让帧）路径树可能已被销毁/重建 → 立即中止本轮回退。
      if (!this.toolpathAlive(buildSeq)) {
        AppLog.warn('PreviewWarn', 'updateToolpath: 路径树已失效 → 中止本轮建几何（代次=%{public}d）', buildSeq);
        return;
      }
      const step: number = Math.min(cur, this.builtLayers + GCODE_BUILD_CHUNK);
      await this.ensureLayers(step, buildSeq);
      // 收敛目标受「扫层进度 / 当前目标层」与「已建成层数」共同限制：建多少就最多揭示多少，
      // 用户把滑条拖回下方时也绝不会把上面的层重新点亮。
      // 仅扫层期间逐批揭示（见上：非首次进入的更新一律直接落定，不重放揭示动画）。
      if (this.sweepActive) {
        this.applyLayerVisibility(Math.min(this.builtLayers, this.revealTarget()));
      }
      if (this.builtLayers < cur) {
        await yieldToUi();
      }
    }
    const root: Node | null = this.toolpathRoot;
    if (root !== null) {
      root.visible = true;
    }
    // 【回归修复】无条件把可见区间落到收敛目标。
    // 上面 while 只在「还要新建层」时才跑；一旦所有层都建好（builtLayers == layerCount），
    // 用户往回拖滑条时进不了循环 → applyLayerVisibility 永不调用 → 可见性不更新，
    // 表现就是「拖动层滑条完全没反应」。这里补一次收敛，差值管线只会动变化的区间。
    this.applyLayerVisibility(Math.min(this.builtLayers, this.revealTarget()));
    // 扫层动画已到顶且几何建完 → 收尾（否则等下一拍 / 补建完成）
    this.maybeFinishSweep();
    this.refreshRendering();
    // 全部层建完 → 输出本份 gcode 的 [GcodeDiag] 诊断块（内部按 generation 去重，只输出一次）
    this.maybeEmitGcodeDiag();
  }

  // 本次「可见层数」的收敛目标：扫层进行中用扫层进度，否则用当前目标层。
  // 所有揭示都经 applyLayerVisibility（差值管线）落地，lastVisChunks 随之更新。
  private revealTarget(): number {
    return this.sweepActive ? this.sweepCur : this.currentGcodeLayer();
  }

  // ---- 扫层：进入切片路径时从底部到顶部逐块揭示（约 1.4 秒）----
  // 只负责「按拍把 applyLayerVisibility 的目标层推上去」，不做任何直接写 visible / 全量刷新，
  // 因此可见性推进天然走差值管线，不会残留。
  // 合并后可见性最小步进 = 一块（this.chunkLayers 层），所以这里【按块推进】（每拍揭示一块），
  // 视觉上就是「N 层一跳」；为避免一跳太生硬、同时保持总时长仍 ≈1.4s，每拍间隔按块数重算。
  private startSweep(): void {
    // 页面不可见（保活的隐藏态）：不启动扫层 —— 否则扫层 setInterval 会在隐藏期间空跑。
    if (this.pausedByHidden) {
      return;
    }
    const total: number = gcodeToolpath.layerCount;
    if (total <= 0) {
      return;
    }
    // 重入预览（换 gcode / 再进页签）时先清掉上一次的扫层
    this.cancelSweep('重新开始扫层');
    // 【粒度必须先定好】扫层按「块」推进、块大小又决定总块数。块大小按【总层数】一次性决定
    // （见 decideChunkLayersOnce），与用户拖到第几层无关；本方法因此不会销毁任何几何。
    this.decideChunkLayersOnce();
    this.sweepActive = true;
    this.sweepAwaitingEnd = false;
    this.sweepCur = 0;
    this.sweepChunks = 0;
    // 总块数 = ceil(总层数 / 块大小)：满层时（998 层 / 16）→ 63 块（远少于层数），若仍按 16ms/拍，
    // 总时长会掉到 ~1.0s；所以把间隔按块数重算：块数 × 间隔 ≈ SWEEP_FRAMES × SWEEP_TICK_MS ≈ 1.44s。
    this.sweepChunkTotal = Math.max(1, Math.ceil(total / this.chunkLayers));
    this.sweepIntervalMs = Math.max(SWEEP_TICK_MS,
      Math.ceil((SWEEP_FRAMES * SWEEP_TICK_MS) / this.sweepChunkTotal));
    // 先收敛到「0 层可见」，再从底部开始增长（差值管线会把上一次已可见的块全部关掉）
    this.applyLayerVisibility(0);
    gcodeSignals.sweepState(true);
    this.refreshRendering();
    this.sweepTimer = setInterval((): void => { this.sweepTick(); }, this.sweepIntervalMs);
    hilog.info(0x0000, 'LayerSlider',
      '扫层开始 总层=%{public}d 总块=%{public}d 每拍间隔=%{public}dms',
      total, this.sweepChunkTotal, this.sweepIntervalMs);
  }

  private sweepTick(): void {
    if (this.toolpathRoot === null) {
      // 几何还没开始建（重建尚未落地 / 刚被撤下）：先不动，等下一拍。
      // 这里不能按 gcodeShow 取消：进入预览的首拍，模型页这边的 @StorageProp 可能还读到旧值 false。
      return;
    }
    if (!this.gcodeShow) {
      // 几何确实挂上过、又明确切走了 → 停扫层
      this.cancelSweep('扫层途中已离开预览');
      return;
    }
    const total: number = gcodeToolpath.layerCount;
    // 每拍揭示一块（可见性最小步进 = 一块），sweepCur 换算成「已揭示的层数」供滑条 / Z 值显示
    this.sweepChunks = Math.min(this.sweepChunkTotal, this.sweepChunks + 1);
    this.sweepCur = Math.min(total, this.sweepChunks * this.chunkLayers);
    // 只会点亮新增的那些块（applyLayerVisibility 内部按 lastVisChunks 做块级差量，并夹到「已建块数」）
    this.applyLayerVisibility(this.sweepCur);
    gcodeSignals.onSweepLayer(this.sweepCur);
    this.refreshRendering();
    if (this.sweepCur >= total) {
      // 到顶：停表，剩下的交给 maybeFinishSweep（可能还要等几何补建完成）
      if (this.sweepTimer >= 0) {
        clearInterval(this.sweepTimer);
        this.sweepTimer = -1;
      }
      this.maybeFinishSweep();
    }
  }

  // 扫层到顶后是否收尾：必须「动画已到顶」且「几何全部建完」两个条件都满足。
  private maybeFinishSweep(): void {
    if (!this.sweepActive) {
      return;
    }
    const total: number = gcodeToolpath.layerCount;
    if (this.sweepCur < total) {
      // 动画还没走到顶，交给 sweepTick 继续推进
      return;
    }
    if (this.builtLayers < total) {
      // 到顶了但几何还没建完：记账，等 updateToolpath / prebuildChunk 建完那一拍再收尾
      this.sweepAwaitingEnd = true;
      return;
    }
    this.finishSweep();
  }

  private finishSweep(): void {
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    const wasActive: boolean = this.sweepActive;
    this.sweepActive = false;
    this.sweepAwaitingEnd = false;
    if (wasActive) {
      gcodeSignals.sweepState(false);
      hilog.info(0x0000, 'LayerSlider', '扫层完成 揭示到=%{public}d', this.sweepCur);
    }
    // 收尾：可见区间收敛到「已建层数 ∩ 当前目标层」（保留上一轮修残留的成果）
    this.applyLayerVisibility(Math.min(this.builtLayers, this.currentGcodeLayer()));
    this.refreshRendering();
  }

  private cancelSweep(reason: string): void {
    if (!this.sweepActive && this.sweepTimer < 0 && !this.sweepAwaitingEnd) {
      return;
    }
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    const wasActive: boolean = this.sweepActive;
    this.sweepActive = false;
    this.sweepAwaitingEnd = false;
    if (wasActive) {
      gcodeSignals.sweepState(false);
      hilog.info(0x0000, 'LayerSlider', '扫层中断（%{public}s）cur=%{public}d', reason, this.sweepCur);
    }
    this.refreshRendering();
  }

  // 「渲染中」标志：扫层动画进行中（含到顶后等几何补建的那一段）或层还在补建中 时为真，两者都结束即隐藏。
  // 为什么用 AppStorage 广播而不是回调：控制层（GcodePreview）用 @StorageProp 订阅该 key，
  // 值一变 ArkUI 必然刷新（本项目老坑正是「改了普通对象/嵌套字段，界面不刷新」，可观察存储能彻底规避）。
  // 只在状态翻转时写一次（renderFlag 去重），日志也只在「显示/隐藏」各打一条。
  private refreshRendering(): void {
    // 页面不可见（保活的隐藏态）：不广播「渲染中」—— 隐藏期间没有渲染语义，更不能把标志重新点亮。
    if (this.pausedByHidden) {
      return;
    }
    const total: number = gcodeToolpath.layerCount;
    const building: boolean = this.toolpathRoot !== null && this.builtLayers < total;
    const active: boolean = this.gcodeShow && (this.sweepActive || building);
    if (active === this.renderFlag) {
      return;
    }
    this.renderFlag = active;
    AppStorage.setOrCreate<boolean>('gcodeRendering', active);
    hilog.info(0x0000, 'LayerSlider', '渲染中标志 %{public}s built=%{public}d total=%{public}d sweep=%{public}s',
      active ? '显示' : '隐藏', this.builtLayers, total, this.sweepActive ? 'on' : 'off');
  }

  // 后台分批预建：快速滑动时就不用现场建几何了（每次让出线程，别堵住交互）
  private schedulePrebuild(): void {
    // 页面不可见（保活的隐藏态）：不排后台补建定时器（隐藏期间补建没有意义）
    if (this.pausedByHidden || this.prebuildTimer >= 0 || !this.gcodeShow || this.toolpathRoot === null) {
      return;
    }
    if (this.builtLayers >= gcodeToolpath.layerCount) {
      return;
    }
    this.prebuildTimer = setTimeout(() => {
      this.prebuildTimer = -1;
      this.prebuildChunk();
    }, 120);
  }

  private prebuildChunk(): void {
    if (!this.gcodeShow || this.toolpathRoot === null || this.gcodeBusy) {
      return;
    }
    this.gcodeBusy = true;
    const next: number = Math.min(gcodeToolpath.layerCount, this.builtLayers + 4);
    const seq: number = this.toolpathSeq;   // ⑤ 本轮补建持有的路径树代次
    this.ensureLayers(next, seq).then(() => {
      this.gcodeBusy = false;
      // 收敛口径 = min(已建成层数, 收敛目标)：目标在扫层时是扫层进度，否则是当前目标层。
      // 若只传当前层号，而当前层号小于已建成层数，后台补建的块就永远点不亮，
      // lastVisChunks 也停在旧值 → 需要用户再拖一次滑条才恢复（这正是残留的成因）。
      // 注意：只有「已收尾的块」才会被点亮（applyLayerVisibility 内部夹到已建块数），
      // 半块（还差几层）不会被提前显示 —— 保证块内层数恒为 N。
      this.applyLayerVisibility(Math.min(this.builtLayers, this.revealTarget()));
      this.refreshRendering();
      // 扫层已到顶、几何也补建完了 → 收尾（否则扫层会一直挂着「渲染中」）
      this.maybeFinishSweep();
      // 补建也可能把最后一批层补齐 → 这里同样补一次诊断块输出（内部按 generation 去重）
      this.maybeEmitGcodeDiag();
      this.schedulePrebuild();
    }).catch((e: Object) => {
      // 不吞异常：补建失败必须留痕并解锁构建泵，否则 gcodeBusy 会永久钉死。
      this.gcodeBusy = false;
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, 'PreviewWarn', '切片路径预建异常（已解锁构建泵）: %{public}s', msg);
      AppLog.warn('PreviewWarn', '切片路径预建异常（已解锁构建泵）: %{public}s', msg);
    });
  }

  // 取景：所有模型（含缩放）的最大尺寸
  private updateFit(): void {
    let m: number = 0;
    for (const inst of modelState.instances) {
      if (!this.isPlateVisible(inst.plate)) {
        continue;
      }
      const ls: Vec3 = this.localSize(inst);
      const s: Vec3 = inst.transform.scale;
      m = Math.max(m, Math.max(ls.x * s.x, Math.max(ls.y * s.y, ls.z * s.z)));
    }
    // 无模型时按盘面对角线取景
    this.lastModelMaxDim = m > 0 ? m : Math.max(this.plateW, this.plateH) * 1.414;
  }

  // 同步 AppStorage（对象列表元数据 + 选中 id + 结构版本）
  private syncStorage(): void {
    modelState.publish();
  }

  // 结构变化（对象列表里复制/删除）→ 同步场景节点
  private onModelRevision(propName: string): void {
    this.syncNodes();
    // 撤销/重做（以及任何「实例对象被整体替换」的路径）都必须在这里重写场景变换：
    // History.restore() 用克隆出来的新实例替换活动实例，而场景节点（containers/nodes）里的
    // position/rotation/scale 是自己存的一份，不会跟着新实例走 ——
    // 不重写就会出现「点撤销没反应，再点一下手柄才生效」（等下一次交互才被 applyTransform 刷到）。
    this.reassertModelVisibility();
    this.syncSelection();
    this.refreshGizmo();
    // 结构变化（删除 / 复制 / 新增）后重算悬空告警：把「需要支撑的对象」删掉时，告警必须随之消失。
    this.refreshSupportWarn('模型结构变化', '已加载');
  }

  // 外部导入（底部「导入」按钮）完成后 → 重新取景 + 重新判定越界
  private onFocusModel(propName: string): void {
    this.updateFit();
    this.resetView();
    this.updateBounds();
  }

  // 盘可见性：无盘信息（activePlate<=0）或未分盘的模型始终可见
  private isPlateVisible(plate: number): boolean {
    if (plate <= 0 || this.activePlate <= 0) {
      return true;
    }
    return plate === this.activePlate;
  }

  // 切换当前盘 → 重排可见性 + 重新取景 + 重判越界
  private onActivePlateChanged(propName: string): void {
    for (const inst of modelState.instances) {
      this.applyTransform(inst);
    }
    // 选中项若被隐藏，改选当前盘第一个模型
    const sel: ModelInstance | undefined = modelState.getSelected();
    if (sel !== undefined && !this.isPlateVisible(sel.plate)) {
      let first: ModelInstance | undefined = undefined;
      for (const inst of modelState.instances) {
        if (this.isPlateVisible(inst.plate)) {
          first = inst;
          break;
        }
      }
      modelState.select(first !== undefined ? first.id : -1);
      AppStorage.setOrCreate<number>('selectedModelId', modelState.selectedId);
    }
    this.updateFit();
    // 注意：切盘**不重置相机**（不调 resetView）。各盘共用同一块物理盘面坐标系，
    // 视角通常正是用户刚调好的观察角度；每切一次盘就跳回默认取景很打断操作。
    this.updateBounds();
    this.syncSelection();
    this.refreshGizmo();
  }

  // 把一个对象在场景里的节点/网格/材质彻底摘掉。
  // 除了「对象已删除」，**同一 id 的几何被整体替换**时也必须走这里重建：
  // syncNodes 只给「缺失的 id」建节点，不比对几何内容，不摘掉就会一直显示旧网格。
  private disposeInstanceNodes(id: number): void {
    const geo: Geometry | undefined = this.nodes.get(id);
    const container: Node | undefined = this.containers.get(id);
    // 关键：删除对象时必须把它的几何从场景里真正摘掉并销毁，而不是只让列表不显示。
    // 先解锁点与子节点的父子关系再 destroy，否则容器销毁时可能留下悬挂的网格引用，
    // 反复删/建大模型会导致显存（顶点/索引缓冲区）持续上涨。
    if (geo !== undefined) {
      const gp: Node | null = geo.parent;
      if (gp !== null) {
        gp.children.remove(geo);
      }
      try {
        geo.mesh.destroy(); // 释放 createMesh 出来的网格资源
      } catch (e) {
        hilog.warn(0x0000, 'ModelScene', 'delete: mesh release failed %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      }
      try {
        geo.destroy();
      } catch (e) {
        hilog.warn(0x0000, 'ModelScene', 'delete: geometry destroy failed %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      }
      this.nodes.delete(id);
    }
    if (container !== undefined) {
      const parent: Node | null = container.parent;
      if (parent !== null) {
        parent.children.remove(container);
      }
      container.destroy();
      this.containers.delete(id);
    }
    this.pendingIds.delete(id);
    this.nodeGeom.delete(id);
    // 该对象的专属材质也一并丢弃（随场景一起回收；几何/网格已在上方显式释放）
    this.modelMats.delete(id);
  }

  private syncNodes(): void {
    if (this.pivotNode === null) {
      return;
    }
    // 1. 移除已删除模型的节点
    const dead: number[] = [];
    this.nodes.forEach((_g: Geometry, id: number) => {
      if (modelState.get(id) === undefined) {
        dead.push(id);
      }
    });
    for (const id of dead) {
      this.disposeInstanceNodes(id);
    }
    // 1.5 几何被整体替换的（同 id 换网格：布尔 / 撤销重做 / 整理摆放回退）→ 也要重建。
    // 只比对「已建好」的 id；在途创建由 appendInstance 内部复核几何，不在这里重复处理。
    const stale: number[] = [];
    this.nodes.forEach((_g: Geometry, id: number) => {
      const inst: ModelInstance | undefined = modelState.get(id);
      if (inst !== undefined && this.nodeGeom.get(id) !== inst.geometry) {
        stale.push(id);
      }
    });
    for (const id of stale) {
      hilog.info(0x0000, 'ModelScene', '几何已替换 → 重建节点 id=%{public}d', id);
      this.disposeInstanceNodes(id);
    }
    // 改色（displayColor 变化会 bump revision -> 走本方法）在这里统一刷到各对象材质上：
    // 只写 baseColor 属性，不重建几何、不重解析网格，下一帧即变色。
    this.applyAllInstanceColors();
    // 2. 补充新增（复制产生的）模型节点
    const fresh: ModelInstance[] = [];
    for (const inst of modelState.instances) {
      if (!this.nodes.has(inst.id) && !this.pendingIds.has(inst.id)) {
        fresh.push(inst);
      }
    }
    if (fresh.length === 0) {
      this.updateFit();
      this.syncSelection();
      this.refreshGizmo();
      return;
    }
    let chain: Promise<void> = Promise.resolve();
    for (const inst of fresh) {
      chain = chain.then((): Promise<void> => this.appendInstance(inst));
    }
    chain.then(() => {
      this.updateFit();
      this.syncSelection();
      this.refreshGizmo();
    });
  }

  // 选中变化（来自对象列表点击）→ 同步编辑控件显示值
  private onSelectedChanged(propName: string): void {
    this.clearHighlight();
    this.syncSelection();
    this.refreshGizmo();
  }

  private syncSelection(): void {
    this.updateBounds();
    // 标记一次「编辑发生」：撤销栈用「持久基线 + 防抖」提交（本函数是所有变换编辑的共同收尾，
    // 拖手柄时每帧都会走到这里；一次拖拽最终只形成一步撤销，见 History.ets）。
    // 摘要里不含选中态与当前盘，所以纯点选不会产生可撤销项。
    history.mark('编辑对象');
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst !== undefined) {
      const t = inst.transform;
      const ls: Vec3 = this.localSize(inst);
      const s: Vec3 = t.scale;
      // 面板文本（Z-up 约定：Y=盘面纵向，Z=竖直高度）
      this.inScale = (s.x * 100).toFixed(0);
      this.inDimX = (ls.x * s.x).toFixed(1);
      this.inDimY = (ls.z * s.z).toFixed(1);
      this.inDimZ = (ls.y * s.y).toFixed(1);
      this.inRotX = t.rotX.toFixed(0);
      this.inRotY = t.rotY.toFixed(0);
      this.inRotZ = t.rotZ.toFixed(0);
      // 移动：底板左下角为 (0,0)，X/Y 为盘面坐标（mm），Z 为高度（原点随盘面尺寸变化）
      // content_z 与盘面 Y 反向（见 ThreeMfImport：z = −(bedY − 盘中心)），所以 Y 要取反再换算。
      this.inPosX = (t.position.x + this.plateW * 0.5).toFixed(1);
      this.inPosY = (this.plateH * 0.5 - t.position.z).toFixed(1);
      this.inPosZ = t.position.y.toFixed(1);
      this.modelInfoText = `${inst.name} · ${inst.format} · ${inst.triangles} 三角面`;
      // 左下角 HUD：实际尺寸 + 实体体积（体积按三轴缩放比例换算）
      this.hudX = (ls.x * s.x).toFixed(2);
      this.hudY = (ls.z * s.z).toFixed(2);
      this.hudZ = (ls.y * s.y).toFixed(2);
      this.hudVol = (inst.volumeMm3 * Math.abs(s.x * s.y * s.z) / 1000).toFixed(2);
      this.hudVisible = true;
    } else {
      this.hudVisible = false;
    }
  }

  // 模型在盘面坐标系下的水平包围盒（局部包围盒 8 角点 → 旋转缩放 → 平移）
  private computeFootprint(inst: ModelInstance): BoundsXZ {
    return this.footprintWithExtents(inst, inst.size.x, inst.size.y);
  }

  // 整理摆放（当前盘）：按每个对象在盘面上的**真实水平外框**做行式排布 ——
  // 从左下角开始铺、行高取该行最高件、四边留白、件间留缝；放不下的保持原位并计数。
  // 为什么用外框排布而不是内核 arrange：内核那套是多边形嵌套 + 多盘（要 3MF 往返 + 盘/实例映射），
  // 而这里要的是「一键把散落的零件摆整齐」—— computeFootprint 已经是 8 角点按真实旋转算出的外框，
  // 结果可预测、绝不重叠，也不碰内核与文档状态（撤销仍是一步）。
  private arrangeActivePlate(): void {
    const plate: number = this.activePlate > 0 ? this.activePlate : 0;
    const items: FootprintItem[] = [];
    for (const inst of modelState.instances) {
      // 只整理当前盘可见的对象；activePlate<=0（未分盘）时整理全部
      if (plate > 0 && inst.plate !== plate) {
        continue;
      }
      const b: BoundsXZ = this.computeFootprint(inst);
      const it: FootprintItem = new FootprintItem();
      it.inst = inst;
      it.w = Math.max(1, b.maxX - b.minX);
      it.d = Math.max(1, b.maxZ - b.minZ);
      it.minX = b.minX;
      it.minZ = b.minZ;
      items.push(it);
    }
    if (items.length === 0) {
      promptAction.showToast({ message: '当前打印板没有对象' });
      return;
    }
    // 深度降序（行更整齐），同深度按宽度降序
    items.sort((a: FootprintItem, b: FootprintItem): number => {
      if (Math.abs(b.d - a.d) > 0.01) {
        return b.d - a.d;
      }
      return b.w - a.w;
    });

    const margin: number = 4;   // 四边留白（mm）
    const gap: number = 3;      // 件间距（mm）
    let cursorX: number = margin;
    let cursorY: number = margin;
    let rowDepth: number = 0;
    let placed: number = 0;
    let failed: number = 0;
    for (const it of items) {
      if (cursorX + it.w > this.plateW - margin && cursorX > margin) {
        cursorX = margin;
        cursorY += rowDepth + gap;
        rowDepth = 0;
      }
      if (cursorY + it.d > this.plateH - margin) {
        failed++;
        continue;
      }
      // 盘面坐标（左下角 = 0,0）→ content 坐标（原点在盘中心）
      const targetX: number = cursorX - this.plateW * 0.5;
      const targetZ: number = cursorY - this.plateH * 0.5;
      const inst: ModelInstance | null = it.inst;
      if (inst !== null) {
        inst.transform.position.x += targetX - it.minX;
        inst.transform.position.z += targetZ - it.minZ;
        this.applyTransform(inst);
      }
      cursorX += it.w + gap;
      rowDepth = Math.max(rowDepth, it.d);
      placed++;
    }
    modelState.publish();
    // 离散操作 → 立即入栈（一次「整理摆放」= 一步撤销，而不是 350ms 防抖里的一帧）
    history.commitNow('整理摆放');
    this.syncSelection();
    this.refreshGizmo();
    promptAction.showToast({
      message: failed > 0
        ? `已摆放 ${placed} 个，${failed} 个放不下（保持原位）`
        : `已摆放 ${placed} 个`
    });
    hilog.info(0x0000, 'Arrange', '整理摆放 盘=%{public}d 摆放=%{public}d 放不下=%{public}d 板=%{public}s×%{public}s',
      plate, placed, failed, this.plateW.toFixed(0), this.plateH.toFixed(0));
  }

  // ==========================================================================
  // 网格编辑（第二层第一批）：拆分对象 / 自动定向 / 铺满打印板
  // 三项都只改「对象集合与变换」，不碰内核与零件树，因此可以先落地；
  // 布尔/切割/负零件等需要零件树的项随后再做。
  // ==========================================================================

  // 拆分到对象：按连通性把一个对象拆成多个独立对象（共享同一变换，位置不散开）。
  private splitSelected(): void {
    const sel: ModelInstance[] = this.selectedInstances();
    if (sel.length === 0) {
      promptAction.showToast({ message: '先在 3D 视图里选中要拆分的对象' });
      return;
    }
    if (sel.length > 1) {
      promptAction.showToast({ message: '一次只拆分一个对象' });
      return;
    }
    const src: ModelInstance = sel[0];
    const t0: number = Date.now();
    const parts = MeshOps.splitConnected(src.geometry);
    if (parts.length <= 1) {
      promptAction.showToast({ message: '该对象是单一连通体，无需拆分' });
      return;
    }
    const geoms: MeshGeometry[] = [];
    for (const p of parts) {
      geoms.push(p.geometry);
    }
    const ids: number[] = modelState.replaceWithSplit(src.id, geoms);
    // 拆分出来的都是新 id → 列表需要各自的缩略图（不补就只显示格式文字）
    for (let i = 0; i < ids.length; i++) {
      ensureThumbnail(ids[i], geoms[i]);
    }
    modelState.publish();
    history.commitNow('拆分对象');
    this.updateFit();
    this.syncSelection();
    this.refreshGizmo();
    promptAction.showToast({ message: `已拆分为 ${ids.length} 个对象` });
    hilog.info(0x0000, 'MeshOps', '拆分对象 id=%{public}d → %{public}d 个 耗时=%{public}dms',
      src.id, ids.length, Date.now() - t0);
  }

  // 合并对象：多选（Ctrl+点击）后合并为一个对象；以最先选中的对象为基准。
  private mergeSelected(): void {
    const sel: ModelInstance[] = this.selectedInstances();
    if (sel.length < 2) {
      promptAction.showToast({ message: '按住 Ctrl 点击选中至少两个对象再合并' });
      return;
    }
    const base: ModelInstance = sel[0];
    const parts: MergePart[] = [];
    const bp: MergePart = new MergePart();
    bp.geometry = base.geometry;
    bp.rotation = this.computeRotation(base);
    bp.position = base.transform.position;
    bp.scale = base.transform.scale;
    parts.push(bp);
    const otherIds: number[] = [];
    for (let i = 1; i < sel.length; i++) {
      const o: ModelInstance = sel[i];
      const mp: MergePart = new MergePart();
      mp.geometry = o.geometry;
      mp.rotation = this.computeRotation(o);
      mp.position = o.transform.position;
      mp.scale = o.transform.scale;
      parts.push(mp);
      otherIds.push(o.id);
    }
    const t0: number = Date.now();
    const geom: MeshGeometry = MeshOps.mergeIntoBase(parts);
    const id: number = modelState.replaceWithMerged(base.id, otherIds, geom);
    if (id < 0) {
      return;
    }
    // 基准对象的 id 没变、几何整体换了 → 必须摘掉旧节点，让 syncNodes 用新几何重建。
    // （否则画面里只显示合并前的那一块，复制/粘贴新建节点后才“突然”出现另一块。）
    this.disposeInstanceNodes(base.id);
    // 同理：缩略图按「几何指纹」判断，这里显式 ensure 一次，保证列表图立即换成合并后的形状
    ensureThumbnail(base.id, geom);
    modelState.publish();
    history.commitNow('合并对象');
    this.updateFit();
    this.syncSelection();
    this.refreshGizmo();
    promptAction.showToast({ message: `已合并 ${sel.length} 个对象` });
    hilog.info(0x0000, 'MeshOps', '合并对象 基准=%{public}d 合并=%{public}d 耗时=%{public}dms',
      base.id, sel.length, Date.now() - t0);
  }

  // 自动定向：把「接触面积最大」的轴向转到朝上（内容 Y+），再落板。
  private autoOrientSelected(): void {
    const sel: ModelInstance[] = this.selectedInstances();
    if (sel.length === 0) {
      promptAction.showToast({ message: '先选中要定向的对象' });
      return;
    }
    let n: number = 0;
    for (const inst of sel) {
      const up: Vec3 = MeshOps.bestUpAxis(inst.geometry);
      if (up.y > 0.999) {
        continue; // 已经是 +Y 朝上
      }
      inst.transform.baseRotation = fromToQuat(up, { x: 0, y: 1, z: 0 });
      inst.transform.rotX = 0;
      inst.transform.rotY = 0;
      inst.transform.rotZ = 0;
      this.dropAfterRotate(inst);
      this.applyTransform(inst);
      n++;
    }
    if (n === 0) {
      promptAction.showToast({ message: '对象已经是稳定朝向' });
      return;
    }
    modelState.publish();
    history.commitNow('自动定向');
    this.updateFit();
    this.syncSelection();
    this.refreshGizmo();
    promptAction.showToast({ message: `已自动定向 ${n} 个对象` });
    hilog.info(0x0000, 'MeshOps', '自动定向 对象=%{public}d', n);
  }

  // 铺满打印板：按选中对象的水平外框算行列，复制到铺满（默认上限 50 份，且受三角面预算约束）。
  // 上限与预算都是硬闸：百万面模型复制 50 份会直接打爆内存。
  private fillBed(): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      promptAction.showToast({ message: '先选中要铺满的对象' });
      return;
    }
    const plate: number = this.activePlate > 0 ? this.activePlate : 0;
    const b: BoundsXZ = this.computeFootprint(inst);
    const w: number = Math.max(1, b.maxX - b.minX);
    const d: number = Math.max(1, b.maxZ - b.minZ);
    const margin: number = 4;
    const gap: number = 3;
    const cols: number = Math.max(1, Math.floor((this.plateW - 2 * margin + gap) / (w + gap)));
    const rows: number = Math.max(1, Math.floor((this.plateH - 2 * margin + gap) / (d + gap)));
    const cap: number = 50;
    let total: number = cols * rows;
    if (total > cap) {
      total = cap;
    }
    const tri: number = inst.triangles > 0 ? inst.triangles : 0;
    if (tri > 0) {
      const byTri: number = Math.max(1, Math.floor(1500000 / tri));
      if (total > byTri) {
        total = byTri;
      }
    }
    if (total <= 1) {
      promptAction.showToast({ message: '当前对象已占满板面（或三角面超预算）' });
      return;
    }
    const ids: number[] = modelState.duplicateMany([inst.id], total - 1, plate > 0 ? plate : -1);
    const all: number[] = [inst.id].concat(ids);
    for (let i = 0; i < all.length; i++) {
      const t: ModelInstance | undefined = modelState.get(all[i]);
      if (t === undefined) {
        continue;
      }
      const bb: BoundsXZ = this.computeFootprint(t);
      const col: number = i % cols;
      const row: number = Math.floor(i / cols);
      const targetX: number = margin + col * (w + gap) - this.plateW * 0.5;
      const targetZ: number = margin + row * (d + gap) - this.plateH * 0.5;
      t.transform.position.x += targetX - bb.minX;
      t.transform.position.z += targetZ - bb.minZ;
      this.applyTransform(t);
    }
    modelState.select(inst.id);
    modelState.publish();
    history.commitNow('铺满打印板');
    this.syncSelection();
    this.refreshGizmo();
    promptAction.showToast({ message: `已铺满 ${all.length} 个（上限 ${cap}）` });
    hilog.info(0x0000, 'MeshOps',
      '铺满打印板 对象=%{public}d 份数=%{public}d 网格=%{public}d×%{public}d',
      inst.id, all.length, cols, rows);
  }

  // 布尔运算：选中两个对象（A 为基准，B 与 A 做差/并/交）。
  // 内核调用是同步的，先让出一帧让按钮进入「运算中」，避免界面看起来卡死。
  private applyBoolean(op: string): void {
    const sel: ModelInstance[] = this.selectedInstances();
    if (sel.length !== 2) {
      promptAction.showToast({ message: '先选中两个对象（Ctrl+点击）再做布尔' });
      return;
    }
    if (this.booleanBusy) {
      return;
    }
    const base: ModelInstance = sel[0];
    const other: ModelInstance = sel[1];
    this.booleanBusy = true;
    setTimeout(() => {
      try {
        const bpart: MergePart = new MergePart();
        bpart.geometry = base.geometry;
        bpart.rotation = this.computeRotation(base);
        bpart.position = base.transform.position;
        bpart.scale = base.transform.scale;
        const opart: MergePart = new MergePart();
        opart.geometry = other.geometry;
        opart.rotation = this.computeRotation(other);
        opart.position = other.transform.position;
        opart.scale = other.transform.scale;
        // B 换算到 A 的局部坐标系（内核只认坐标，不认实例变换）
        const bLocal: MeshGeometry = MeshOps.bakeToBase(opart, bpart);
        const t0: number = Date.now();
        const r = SlicerService.meshBoolean(base.geometry, bLocal, op);
        if (!r.ok) {
          promptAction.showToast({ message: r.message.length > 0 ? r.message : '布尔运算失败' });
          hilog.warn(0x0000, 'MeshOps', '布尔失败 op=%{public}s msg=%{public}s', op, r.message);
          return;
        }
        const geom: MeshGeometry = new MeshGeometry();
        geom.pos = r.positions;
        geom.idx = r.indices;
        if (r.triangles <= 300000) {
          repairNormals(geom);
        }
        const id: number = modelState.replaceWithMerged(base.id, [other.id], geom);
        if (id < 0) {
          return;
        }
        this.disposeInstanceNodes(base.id);
        ensureThumbnail(base.id, geom);
        modelState.publish();
        history.commitNow(op === 'union' ? '布尔并集' : (op === 'intersection' ? '布尔交集' : '布尔差集'));
        this.updateFit();
        this.syncSelection();
        this.refreshGizmo();
        promptAction.showToast({ message: `布尔完成：${r.triangles} 个三角面` });
        hilog.info(0x0000, 'MeshOps',
          '布尔 op=%{public}s 基准=%{public}d 耗时=%{public}dms 面数=%{public}d',
          op, base.id, Date.now() - t0, r.triangles);
      } finally {
        this.booleanBusy = false;
      }
    }, 40);
  }

  // 同上，但可显式指定「盘面方向的两个尺寸」（Z-up 的 X / Y，mm）。
  private footprintWithExtents(inst: ModelInstance, sizeXUp: number, sizeYUp: number): BoundsXZ {
    const s: Vec3 = inst.transform.scale;
    const q: Quaternion = this.computeRotation(inst);
    const p: Vec3 = inst.transform.position;
    const hx: number = sizeXUp * s.x * 0.5;
    const hy: number = inst.size.z * s.y; // 高度：底面 y=0 → 顶面 y=hy
    const hz: number = sizeYUp * s.z * 0.5;
    const b: BoundsXZ = new BoundsXZ();
    b.minX = 1e30;
    b.maxX = -1e30;
    b.minZ = 1e30;
    b.maxZ = -1e30;
    for (let i = 0; i < 8; i++) {
      const cx: number = (i & 1) === 0 ? -hx : hx;
      const cy: number = (i & 2) === 0 ? 0 : hy;
      const cz: number = (i & 4) === 0 ? -hz : hz;
      const r: Vec3 = rotateVecByQuat(q, { x: cx, y: cy, z: cz });
      const wx: number = p.x + r.x;
      const wz: number = p.z + r.z;
      if (wx < b.minX) { b.minX = wx; }
      if (wx > b.maxX) { b.maxX = wx; }
      if (wz < b.minZ) { b.minZ = wz; }
      if (wz > b.maxZ) { b.maxZ = wz; }
    }
    return b;
  }

  // 校验所有模型是否超出当前盘面；超界则触发红光闪烁。
  // 同一趟里按「对象 XY 包围盒 ∩ 左/右专属区矩形」判定每个对象的【区域约束】：
  //   仅左 → zoneSide='left'；仅右 → 'right'；两侧都碰 → zoneConflict（复用越界告警并阻止打印）。
  // 随后交给 FilamentGrouping 按「耗材分组 + 区域/高度/材料约束」算出最终喷嘴侧并回填。
  private updateBounds(): void {
    const pw: number = this.plateW * 0.5;
    const ph: number = this.plateH * 0.5;
    let overX: number = 0;
    let overY: number = 0;
    const sides: Map<number, string> = new Map<number, string>();
    const conflicts: Set<number> = new Set<number>();
    const heights: Map<number, number> = new Map<number, number>();
    let conflictObj: number = -1;
    for (const inst of modelState.instances) {
      if (!this.isPlateVisible(inst.plate)) {
        sides.set(inst.id, '');
        heights.set(inst.id, 0);
        continue;
      }
      const b: BoundsXZ = this.computeFootprint(inst);
      const ex: number = Math.max(-pw - b.minX, b.maxX - pw);
      const ey: number = Math.max(-ph - b.minZ, b.maxZ - ph);
      if (ex > overX) { overX = ex; }
      if (ey > overY) { overY = ey; }
      heights.set(inst.id, this.computeHeight(inst));
      // 与左/右专属区矩形求交（同一套坐标映射：区域矩形与包围盒都在内容坐标系）
      const hitL: boolean = this.rectOverlap(b, this.zoneRectL);
      const hitR: boolean = this.rectOverlap(b, this.zoneRectR);
      if (hitL && hitR) {
        conflicts.add(inst.id);
        if (conflictObj < 0) { conflictObj = inst.id; }
        sides.set(inst.id, '');
      } else if (hitL) {
        sides.set(inst.id, 'left');
      } else if (hitR) {
        sides.set(inst.id, 'right');
      } else {
        sides.set(inst.id, '');
      }
    }
    // 回填几何口径到 ModelState（只在变化时 revision++）
    const geomChanged: boolean = modelState.applyNozzleSides(sides, conflicts, heights);
    if (geomChanged) {
      this.logDualNozzleSides(sides, conflicts);
    }
    // 按「耗材→喷嘴」分组重算最终喷嘴侧（区域/高度/材料约束 + 分组模式）；AMS 用服务内缓存。
    const gChanged: boolean = FilamentGrouping.applyToState(this.platePrinter, []);
    if (geomChanged || gChanged) {
      // 广播 revision，让打印弹窗/其他页看到最新归属（收敛后不再变化 → 不会反复触发）
      modelState.publish();
    }
    // 汇总几何越界 + 区域冲突 + 分组/材料冲突，共用同一套「超出打印区域」告警文案
    const parts: string[] = [];
    if (overX > this.boundsEps) { parts.push(`X ${overX.toFixed(1)}`); }
    if (overY > this.boundsEps) { parts.push(`Y ${overY.toFixed(1)}`); }
    let text: string = parts.length > 0 ? `超出打印区域 ${parts.join(' / ')} mm` : '';
    if (conflicts.size > 0) {
      text = parts.length > 0
        ? `${text}（对象 ${conflictObj} 同时触碰左右喷嘴专属区）`
        : `超出打印区域（对象 ${conflictObj} 同时触碰左右喷嘴专属区）`;
    }
    // 材料级限制 / 耗材分组冲突（如 PPA-CF 被分到右喷、左喷 TPU 时右喷不可用）：同一套告警
    let groupErrId: number = -1;
    let groupErr: string = '';
    for (const inst of modelState.instances) {
      if (inst.sideError !== '') {
        groupErrId = inst.id;
        groupErr = inst.sideError;
        break;
      }
    }
    if (groupErr !== '') {
      text = text.length > 0
        ? `${text}（对象 ${groupErrId}：${groupErr}）`
        : `超出打印区域（对象 ${groupErrId}：${groupErr}）`;
    }
    if (text !== this.warnText) {
      this.warnText = text;
    }
    this.setOutOfBounds(text.length > 0);
  }

  // 对象世界坐标 Z 高度（8 角点 Y 极差，mm；含缩放/旋转）。用于「高度>320mm 必须右喷」判定。
  private computeHeight(inst: ModelInstance): number {
    const s: Vec3 = inst.transform.scale;
    const q: Quaternion = this.computeRotation(inst);
    const p: Vec3 = inst.transform.position;
    const hx: number = inst.size.x * s.x * 0.5;
    const hy: number = inst.size.z * s.y;
    const hz: number = inst.size.y * s.z * 0.5;
    let minY: number = 1e30;
    let maxY: number = -1e30;
    for (let i = 0; i < 8; i++) {
      const cx: number = (i & 1) === 0 ? -hx : hx;
      const cy: number = (i & 2) === 0 ? 0 : hy;
      const cz: number = (i & 4) === 0 ? -hz : hz;
      const r: Vec3 = rotateVecByQuat(q, { x: cx, y: cy, z: cz });
      const wy: number = p.y + r.y;
      if (wy < minY) { minY = wy; }
      if (wy > maxY) { maxY = wy; }
    }
    return maxY - minY;
  }

  // 对象 XY 包围盒与专属区矩形是否相交（内容坐标系；含 boundsEps 容差，刚好贴边不算）。
  private rectOverlap(b: BoundsXZ, r: BoundsXZ | null): boolean {
    if (r === null) { return false; }
    if (b.maxX < r.minX - this.boundsEps) { return false; }
    if (b.minX > r.maxX + this.boundsEps) { return false; }
    if (b.maxZ < r.minZ - this.boundsEps) { return false; }
    if (b.minZ > r.maxZ + this.boundsEps) { return false; }
    return true;
  }

  // 单喷嘴归属/两侧冲突变化时打三通道日志（tag：DualNozzle）。
  private logDualNozzleSides(sides: Map<number, string>, conflicts: Set<number>): void {
    const items: string[] = [];
    sides.forEach((side: string, id: number): void => {
      if (side !== '') { items.push(`${id}:${side}`); }
    });
    const conf: string[] = [];
    conflicts.forEach((id: number): void => { conf.push(`${id}`); });
    const line: string = `[DualNozzle] 专属区归属: 机型=${this.platePrinter.length > 0 ? this.platePrinter : '(无)'}`
      + ` 左区=${this.zoneRectL !== null ? '有' : '无'} 右区=${this.zoneRectR !== null ? '有' : '无'}`
      + ` 单侧归属=${items.length > 0 ? items.join(',') : '(无)'}`
      + ` 两侧冲突=${conf.length > 0 ? conf.join(',') : '(无)'}`;
    hilog.info(0x0000, 'DualNozzle', '%{public}s', line);
    AppLog.note('DualNozzle|归属', line);
    this.appendModelDiag('单喷嘴归属诊断', [line]);
  }

  // 越界状态切换（含红光脉冲动画启停）
  private setOutOfBounds(v: boolean): void {
    if (v === this.outOfBounds) {
      return;
    }
    this.outOfBounds = v;
    if (v) {
      this.startWarnPulse();
    } else {
      this.stopWarnPulse();
    }
  }

  // 启动越界红光脉冲（iterations:-1 的无限循环动画）
  private startWarnPulse(): void {
    this.warnAlpha = 0.25;
    this.getUIContext().animateTo({
      duration: 560,
      curve: Curve.Sharp,
      iterations: -1,
      playMode: PlayMode.Alternate,
    }, () => {
      this.warnAlpha = 0.95;
    });
  }

  // 停止越界红光脉冲（把 warnAlpha 收敛到 0）：越界解除、或页面不可见暂停空跑时都用它。
  private stopWarnPulse(): void {
    this.warnAlpha = 0;
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Sharp }, () => {
      this.warnAlpha = 0;
    });
  }

  // ===========================================================================
  // 需求 4：悬空（朝下）面启发式判定 → 右上角「需要添加支撑」黄色闪烁告警
  //
  // 检测在原生侧做（解析时一次线性扫描，见 bambu_mesh.cpp 的 weldVertices）：
  //   · 朝下悬空面 = 面法线指向下方且与「竖直向下」夹角 ≤ kOverhangAngleDeg(60°) 的三角面；
  //   · 排除贴板底面（三顶点 z < 0.2mm）——否则平底模型都会误报；
  //   · 面积占比 > kOverhangAreaRatioPct(3%) → 判定需要支撑。
  // 【如实说明】这是启发式，不是切片器级别的精确悬空分析（不看桥接/逐层/自交），只用于提醒。
  //
  // 与「已启用支撑」联动：读参数表里真实的支撑开关 enable_support；开启 → 不显示告警。
  // 【关键修正】结论按【对象】存进 ModelState；告警显隐每次都从「所有已加载模型」重算，
  //   不再只在导入那一瞬间判一次 —— 否则切页回来 / 编辑已有模型时永远不评估（用户反馈的「没效果」）。
  // ===========================================================================
  private supportEnabledFromParams(): boolean {
    const list: SliceParam[] = SliceParamStore.getParams();
    for (const p of list) {
      if (p.key === SUPPORT_ENABLE_KEY) {
        return p.value !== 0;
      }
    }
    // 参数表里没有该 key（预设未就绪）→ 按内核默认值处理（默认 0 = 关）
    return false;
  }

  // 汇总「所有已加载模型」的悬空结论：任一模型需要支撑 → 需要告警。
  // 刻意不按「当前盘」过滤：告警是针对整个打印任务的（多盘文件的每一盘都要支撑），
  // 也不做「按当前盘为空就沿用旧值」的兜底 —— 模型全删掉时告警必须随之消失。
  private aggregateOverhang(): SupportAgg {
    const agg: SupportAgg = new SupportAgg();
    for (const inst of modelState.instances) {
      if (inst.overhangNeeded) { agg.needed = true; }
      if (inst.overhangRatioPct > agg.ratio) { agg.ratio = inst.overhangRatioPct; }
      if (inst.overhangAngleDeg > agg.angle) { agg.angle = inst.overhangAngleDeg; }
      if (inst.overhangAreaPctThr > agg.threshold) { agg.threshold = inst.overhangAreaPctThr; }
    }
    return agg;
  }

  // 参数值变化后的统一入口（由 @StorageProp('paramRevSeq') 驱动）：
  // 支撑开关可能刚被打开/关闭 → 重算告警显隐。
  private onParamRevChanged(): void {
    this.refreshSupportWarn('参数变化', '已加载');
  }

  // 重算告警显隐（幂等）：任一已加载模型需要支撑 且 支撑未启用 → 显示并跑脉冲；否则收起并停动画。
  // source：'导入'（刚导入完这次）/ '已加载'（切页回来或改参数时的重算），用于自证日志。
  private refreshSupportWarn(reason: string, source: string): void {
    const agg: SupportAgg = this.aggregateOverhang();
    this.supportNeeded = agg.needed;
    this.overhangRatioPct = agg.ratio;
    this.overhangAngleDeg = agg.angle;
    this.overhangAreaPctThr = agg.threshold;
    const supportOn: boolean = this.supportEnabledFromParams();
    const show: boolean = agg.needed && !supportOn;
    this.supportWarnShow = show;
    if (show) {
      this.startSupportPulse();
    } else {
      this.stopSupportPulse();
    }
    // 只在「状态组合真的变了」时写三通道自证（否则参数面板每改一个无关参数都会写一次诊断文件）
    const state: string = `${agg.needed ? 1 : 0}|${supportOn ? 1 : 0}|${show ? 1 : 0}|${source}`;
    if (state !== this.supportLoggedState) {
      this.supportLoggedState = state;
      this.logSupportDetect(reason, supportOn, show, source);
    }
  }

  // 启动黄色脉冲：animateTo 的 iterations:-1 + Alternate 做透明度脉冲（绝不使用 .shadow()）。
  // 幂等：已在跑就直接返回（参数面板连续改值不会叠加出多条动画）。
  private startSupportPulse(): void {
    if (this.supportPulseOn) { return; }
    this.supportPulseOn = true;
    this.supportWarnAlpha = 0.35;
    this.getUIContext().animateTo({
      duration: 620,
      curve: Curve.Sharp,
      iterations: -1,
      playMode: PlayMode.Alternate,
    }, () => {
      this.supportWarnAlpha = 1.0;
    });
  }

  // 停止脉冲（告警解除 / 页面不可见）：把透明度收敛到 0 并复位标志
  private stopSupportPulse(): void {
    this.supportPulseOn = false;
    this.supportWarnAlpha = 0;
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Sharp }, () => {
      this.supportWarnAlpha = 0;
    });
  }

  // 悬空检测自证（hilog + 应用内日志 + 诊断文件三通道同写）
  private logSupportDetect(reason: string, supportOn: boolean, show: boolean, source: string): void {
    const line: string = `悬空检测 朝下面占比=${this.overhangRatioPct.toFixed(1)}% ` +
      `阈值=${this.overhangAreaPctThr.toFixed(1)}% 角度阈值=${this.overhangAngleDeg.toFixed(0)}° ` +
      `判定=${this.supportNeeded ? '需支撑' : '无需支撑'} 支撑已启用=${supportOn ? '是' : '否'} ` +
      `告警=${show ? '显示' : '隐藏'} 模型来源=${source}（${reason}）（启发式统计，非切片器级悬空分析）`;
    hilog.info(0x0000, FLOW_TAG, '%{public}s', line);
    AppLog.note('FlowSupport|悬空检测', '[' + FLOW_TAG + '] ' + line);
    this.appendModelDiag('模型诊断', [line]);
  }

  // ===========================================================================
  // 【已删除】打印板前端辅助线（喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线）
  //   这两处「黄线」（准备页预置 + 切片路径预览的「辅助线」档）已按需求整体删除：
  //   · 准备页：不再从机器预设启动 G-code 解析、也不再建任何板前几何；
  //   · 切片路径预览：GcodeParseWorker / GcodeToolpath 两个解析器都不再把
  //     「; FEATURE: Custom」的辅助挤出计入折线与 presentRoles（图例随之不再出现该档）。
  // ===========================================================================

  // 三通道自证落到 files/diag/gcode_diag.txt（与 gcode 诊断同一个文件，格式一致、追加不覆盖）
  private appendModelDiag(head: string, lines: string[]): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        AppLog.warn(FLOW_TAG, '诊断文件写入跳过：获取上下文失败');
        return;
      }
      const path: string = `${ctx.filesDir}/diag/gcode_diag.txt`;
      const block: string[] = [`----- ${head} ${new Date().toLocaleString()} -----`];
      const ok: boolean = AppLog.writeDiagFile(path, block.concat(lines));
      if (!ok) {
        hilog.warn(0x0000, FLOW_TAG, '诊断文件写入失败 %{public}s', path);
      }
    } catch (e) {
      // 不吞异常：落文件失败必须留痕（这是唯一的自证出口）
      AppLog.warn(FLOW_TAG, '诊断文件写入异常: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------------------
  // 三维操作手柄（旋转 / 缩放 / 移动）
  // ---------------------------------------------------------------------------
  private setTool(t: number): void {
    this.tool = this.tool === t ? 0 : t;
    this.deltaAxis = '';
    this.deltaText = '';
    this.refreshGizmo();
  }

  // 新增一块空打印板并切过去。
  // 为什么放在工具抽屉里：盘条要「已有 ≥1 块盘」才渲染，0 块盘时抽屉是唯一入口。
  private addEmptyPlate(): void {
    const idx: number = plateAddEmpty();
    this.activePlate = idx;
    // 第一块盘会把原有「未分盘」对象收编进来（见 ModelState.addPlate），此时不能再说是空盘
    const cnt: number = modelState.instances.filter((m: ModelInstance) => m.plate === idx).length;
    promptAction.showToast({
      message: cnt > 0
        ? `已新增打印板 ${idx}（原有对象已归入此盘）`
        : `已新增打印板 ${idx}（空盘，可把对象移过去）`
    });
  }

  private clearGizmo(): void {
    // 作废所有「正在 createNode / appendGeometry」的在途手柄创建：
    // 只清 gizmoRoot 不够 —— 在途任务完成后还会把箭头补进来，形成残影（如只剩一根向上箭头）。
    this.gizmoSeq++;
    if (this.gizmoRoot !== null && this.pivotNode !== null) {
      this.pivotNode.children.remove(this.gizmoRoot);
      this.gizmoRoot.destroy();
      this.gizmoRoot = null;
    }
  }

  // 视口背景色（随「背景发光」变化）：0 = 纯黑，1 = 默认浅蓝，2 = 近白。
  // 为什么用「分段线性」而不是直接乘再 clamp：直接乘会在 g>1.67 后三通道全部顶到 255，
  // 滑条上半段完全不动（用户反馈的「背景发光没有用」）。
  private viewBgRgb(): Vec3 {
    const g: number = Math.max(0, Math.min(2, this.glowBg));
    const b: Color = this.baseClear;
    if (g <= 1) {
      return { x: b.r * g, y: b.g * g, z: b.b * g };
    }
    const t: number = g - 1;   // 0..1：由底色向白色过渡
    return { x: b.r + (1 - b.r) * t, y: b.g + (1 - b.g) * t, z: b.b + (1 - b.b) * t };
  }

  private viewBgColor(): string {
    const c: Vec3 = this.viewBgRgb();
    return `rgb(${Math.round(c.x * 255)},${Math.round(c.y * 255)},${Math.round(c.z * 255)})`;
  }

  // 应用光感设置：背景发光（背景亮度 + 光照强弱 + 泛光）+ 手柄发光（自发光强度）
  private applyGlowSettings(): void {
    const g: number = Math.max(0, this.glowBg);
    // 光照强度：温和曲线，0 时仍保留 45%，避免整盘全黑看不见
    const lf: number = 0.45 + 0.55 * g;
    // 视口底色：直接由相机清屏色给出（不透明）。3D 渲染表面不保证把「透明清屏」透出到 ArkUI 容器，
    // 之前把底色只挂在容器 backgroundColor 上，导致「背景发光」看起来没有效果；这里改成真正生效的路径。
    // 容器 backgroundColor 仍保留（加载期/场景未就绪时兜底），颜色与这里同源（viewBgColor）。
    if (this.camera !== null) {
      const c: Vec3 = this.viewBgRgb();
      this.camera.clearColor = { r: c.x, g: c.y, b: c.z, a: 1.0 };
      // 泛光强度（光晕大小）跟随「背景发光」；是否真的有泛光/暗角则由「渲染开关」档位决定
      this.applyCameraPostProcess();
    }
    // 环境间接光
    if (this.scene !== null) {
      this.scene.environment.indirectDiffuseFactor = {
        x: this.envBase.x * lf, y: this.envBase.y * lf, z: this.envBase.z * lf, w: 1.0,
      };
    }
    // 主光 / 补光强度
    if (this.sunLight !== null) {
      this.sunLight.intensity = this.baseSun * lf;
    }
    if (this.fillLight !== null) {
      this.fillLight.intensity = this.baseFill * lf;
    }
    // 手柄：纯色亮度（0 → 实色不发光；1 → 发光泛光；>1 更亮）
    const hg: number = Math.max(0, this.glowHandle);
    const bf: number = 0.55 + 1.35 * hg;
    for (let i = 0; i < this.gizmoMats.length && i < this.gizmoHue.length; i++) {
      const m: UnlitMaterial = this.gizmoMats[i] as UnlitMaterial;
      const h: Vec3 = this.gizmoHue[i];
      m.baseColor.factor = { x: h.x * bf, y: h.y * bf, z: h.z * bf, w: 1.0 };
    }
  }

  // 应用阴影档位：samples<=0 → 关阴影；>0 → 开阴影并把「场景级」PCF 采样次数设为该档位。
  // 说明：light.shadowEnabled 控制「这盏灯是否投影」；softShadowConfig 是场景级的 PCF 参数
  // （shadowSampleCount 采样次数 / shadowSampleRadius 采样半径），场景内所有投影灯共用。
  // 「模型预览」与「切片路径」共用同一个场景，所以两套档位只能在模式切换时按需重设（见 onGcodeState）。
  // 采样次数取值范围 0~64（官方）：0 = 不做 PCF 采样（无阴影），undefined = 恢复默认 16。
  private applyShadowLevel(samples: number): void {
    const raw: number = Math.round(samples);
    if (this.appliedShadowSamples === raw) {
      return;
    }
    this.appliedShadowSamples = raw;
    const on: boolean = raw > 0;
    // 主光 / 补光统一按档位开关投影
    if (this.sunLight !== null) {
      this.sunLight.shadowEnabled = on;
    }
    if (this.fillLight !== null) {
      this.fillLight.shadowEnabled = on;
    }
    if (this.scene === null) {
      return;
    }
    try {
      const cfg: RenderConfiguration = this.scene.renderConfiguration;
      if (!on) {
        // 关闭：清掉软阴影配置 → 不再产生 PCF 采样开销
        cfg.softShadowConfig = undefined;
      } else {
        const pcf: PCFConfig = new PCFConfig();
        pcf.shadowSampleCount = raw;
        pcf.shadowSampleRadius = SHADOW_SAMPLE_RADIUS;
        cfg.softShadowConfig = pcf;
      }
      hilog.info(0x0000, 'ShadowLvl', '阴影档位 → 采样=%{public}d 半径=%{public}f（%{public}s）',
        raw, SHADOW_SAMPLE_RADIUS, on ? '开' : '关');
    } catch (e) {
      // 不吞异常：设置失败必须留痕（软阴影属新接口；失败时仍保留 shadowEnabled 的开/关语义）
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'ShadowLvl', '设置软阴影失败: %{public}s', msg);
      AppLog.warn('PreviewWarn', '设置软阴影失败: %{public}s', msg);
    }
  }

  private onGlowBgChanged(propName: string): void {
    this.applyGlowSettings();
  }

  private onGlowHandleChanged(propName: string): void {
    this.applyGlowSettings();
  }

  // ---------------------------------------------------------------------------
  // 渲染开销 A/B 开关：实时应用（MSAA / 后处理 / 角色材质背面剔除）
  // ---------------------------------------------------------------------------
  // 【作用范围】「两者都改」→ 永远生效；「仅切片路径」（默认）→ 只在切片路径态生效，
  // 模型预览一律回落到默认值（MSAA 开 / Bloom 开 / Vignette 开），从而保留模型预览的观感。
  // 默认档位 = 改动前的当前值，所以默认情况下这里算出来的值与旧代码逐字节一致。
  private tuneApplies(): boolean {
    return this.rtScopeAll || this.gcodeShow;
  }

  // 开关变化的唯一入口（面板改 AppStorage → 本页 @Watch 触发）
  private onRenderTuneChanged(propName: string): void {
    this.applyRenderTune(`改 ${propName}`);
  }

  // 把当前档位应用到场景。reason 非空时落一条 [RenderTune] 日志（面板每拨一次 = 一行日志）。
  private applyRenderTune(reason: string): void {
    const applies: boolean = this.tuneApplies();
    // 实际生效值：范围=仅切片路径 且 当前是模型预览 → 用默认（= 改动前的当前值）
    const msaa: boolean = applies ? this.rtMsaa : true;
    if (this.camera !== null) {
      try {
        // 只改 MSAA 与后处理。「渲染管线」刻意保持建相机时的 FORWARD 不动：
        // 运行期切换管线可能重建渲染表面、把已缓存的 materialOverride 冲掉（就是 RenderResume
        // 在防的「路径/打印板变灰」），那会污染 A/B 结论，所以不引入这个未要求的变量。
        // 关掉 Bloom 仍能省掉「多渲染目标 + 多次模糊」这一整段后处理开销。
        this.camera.msaa = msaa;
        this.applyCameraPostProcess();
      } catch (e) {
        // 不吞异常：设置失败必须留痕（此时画面保持上一档，不会静默半途）
        const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
        hilog.error(0x0000, 'RenderTune', '应用渲染开关失败: %{public}s', msg);
        AppLog.warn('PreviewWarn', '应用渲染开关失败: %{public}s', msg);
      }
    }
    // 剔除只作用于切片路径的角色材质与洋红兜底；打印板/网格/边框/模型材质一律不碰
    this.applyRoleCull();
    if (reason !== '') {
      this.logRenderTune(reason);
    }
  }

  // 相机后处理：按「实际生效」的泛光/暗角拼 PostProcessSettings（泛光强度继续跟随「背景发光」）。
  // 两个都关 → postProcess = null（整条后处理直接去掉，不再多渲染目标 + 多次模糊）。
  private applyCameraPostProcess(): void {
    if (this.camera === null) {
      return;
    }
    const applies: boolean = this.tuneApplies();
    const bloom: boolean = applies ? this.rtBloom : true;
    const vig: boolean = applies ? this.rtVignette : true;
    if (!bloom && !vig) {
      this.camera.postProcess = null;
      return;
    }
    const p: PostProcessSettings = {};
    if (vig) {
      p.vignette = { intensity: 0.12, roundness: 0.85 };
    }
    if (bloom) {
      const g: number = Math.max(0, this.glowBg);
      p.bloom = { thresholdHard: 0.8, thresholdSoft: 1.3, scaleFactor: 0.4 + 1.1 * g, scatter: 1.0 };
    }
    this.camera.postProcess = p;
  }

  // 角色材质背面剔除：NONE（现状，双面渲染）↔ BACK（剔除背面，填充率约减半）。
  // 【只登记在 roleMats / fallbackMat 上的材质会被改】，打印板保持引擎默认（BACK）不动：
  // 床板是封闭实体，默认 BACK 本来就对；切片路径的带条是闭合棱柱，BACK 理论上成立，
  // 但折线两端没有端盖，沿路径方向看可能露馅 —— 这是待实测风险，本开关不做几何补偿。
  private applyRoleCull(): void {
    const mode: CullMode = this.rtCullBack ? CullMode.BACK : CullMode.NONE;
    for (let i: number = 0; i < this.roleMats.length; i++) {
      const m: Material | null = this.roleMats[i];
      if (m !== null) {
        m.cullMode = mode;
      }
    }
    if (this.fallbackMat !== null) {
      this.fallbackMat.cullMode = mode;
    }
  }

  // [RenderTune] 一条日志：开关档位 + 作用范围 + 最近 1 秒 FPS + 场景规模。
  // hilog / 应用内日志 / files/diag/gcode_diag.txt 三处同写（用户不连设备也能截图自证）。
  private logRenderTune(reason: string): void {
    let batches: number = 0;
    const c: number = this.lastVisChunks;
    for (let ci: number = 0; ci < c && ci < this.chunkParts.length; ci++) {
      batches += this.chunkParts[ci];
    }
    const nodes: number = this.toolpathRoot !== null ? this.countNodesRec(this.toolpathRoot) : 0;
    const text: string =
      `[RenderTune] msaa=${this.rtMsaa ? 1 : 0} bloom=${this.rtBloom ? 1 : 0} ` +
      `vignette=${this.rtVignette ? 1 : 0} cull=${this.rtCullBack ? 'BACK' : 'NONE'} ` +
      `范围=${this.rtScopeAll ? '两者都改' : '仅切片路径'} FPS=${Math.round(this.fpsLast)} ` +
      `节点数=${nodes} 批次数=${batches} 顶点数=${this.gcodeVertCount}`;
    hilog.info(0x0000, 'RenderTune', '%{public}s（%{public}s）', text, reason);
    AppLog.push(text);
    try {
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        return;
      }
      const ok: boolean = AppLog.writeDiagFile(`${ctx.filesDir}/diag/gcode_diag.txt`,
        [`[RenderTune] ${new Date().toLocaleString()} ${text}（${reason}）`]);
      if (!ok) {
        hilog.warn(0x0000, 'RenderTune', 'RenderTune 日志落盘失败');
      }
    } catch (e) {
      // 不吞异常：落文件失败必须留痕
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'RenderTune', '落文件异常: %{public}s', msg);
    }
  }

  // ---- 真实帧率统计 ---------------------------------------------------------
  // 口径来源：displaySync（@ohos.graphics.displaySync）的 'frame' 回调 —— 每次 VSync 到达触发一次，
  // 并带 ns 时间戳，是本 SDK 上唯一能拿到的真实帧事件。ArkGraphics3D 只暴露 Scene.renderFrame()
  // （主动请求渲染）与 alwaysRender，没有「一帧渲染完成」的回调，所以这里如实以 VSync 帧率作口径，
  // 不做任何估算或伪造。拿不到（创建/订阅抛异常）时 FPS 恒为 0，面板会如实显示 0。
  private startFpsMeter(): void {
    if (this.fpsSync !== null) {
      return;
    }
    try {
      const ds: displaySync.DisplaySync = displaySync.create();
      ds.setExpectedFrameRateRange({ expected: 60, min: 0, max: 120 });
      ds.on('frame', (info: displaySync.IntervalInfo): void => { this.onVsyncFrame(info); });
      ds.start();
      this.fpsSync = ds;
      this.fpsWindowStartNs = 0;   // 下一个回调到达时重新建立基准
      this.fpsWindowFrames = 0;
      hilog.info(0x0000, 'RenderTune', 'FPS 统计已启动（displaySync VSync 回调）');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'RenderTune', '启动 FPS 统计失败: %{public}s', msg);
      AppLog.warn('PreviewWarn', '启动 FPS 统计失败: %{public}s', msg);
      this.fpsSync = null;
    }
  }

  private stopFpsMeter(): void {
    if (this.fpsSync === null) {
      return;
    }
    try {
      this.fpsSync.off('frame');
      this.fpsSync.stop();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, 'RenderTune', '停止 FPS 统计失败: %{public}s', msg);
    }
    this.fpsSync = null;
    this.fpsWindowStartNs = 0;
    this.fpsWindowFrames = 0;
  }

  // 每帧回调：按真实时间戳累计；每满 1 秒算一次平均 FPS，并发布到 AppStorage 供日志页面板显示。
  private onVsyncFrame(info: displaySync.IntervalInfo): void {
    const t: number = info.timestamp;   // 当前帧到达时刻（ns）
    if (this.fpsWindowStartNs === 0) {
      this.fpsWindowStartNs = t;
      this.fpsWindowFrames = 0;
      return;
    }
    this.fpsWindowFrames++;
    const dt: number = (t - this.fpsWindowStartNs) / 1e9;
    if (dt >= 1) {
      this.fpsLast = this.fpsWindowFrames / dt;
      AppStorage.setOrCreate<number>('rtFps', Math.round(this.fpsLast));
      this.fpsWindowStartNs = t;
      this.fpsWindowFrames = 0;
    }
  }

  // ---- 框选：拖一个矩形，把「屏幕投影包围盒与该矩形相交」的对象全部选中 ----
  //
  // 为什么不用 GPU 拾取：本页已有解析投影 projectPoint（相机固定在 (0,0,dist) 朝 -Z），
  // 每个对象的包围盒 8 个角投影到屏幕取 min/max 即可 —— O(对象数)，无需读回像素或改渲染器。
  private finishBoxSelect(): void {
    const b: number[] = this.selBox;
    const x0: number = Math.min(b[0], b[2]);
    const x1: number = Math.max(b[0], b[2]);
    const y0: number = Math.min(b[1], b[3]);
    const y1: number = Math.max(b[1], b[3]);
    if (x1 - x0 < 4 && y1 - y0 < 4) {
      return;   // 几乎没拖动：视为误触，保持现有选择不动
    }
    const ids: number[] = [];
    for (const inst of modelState.instances) {
      if (this.boxHits(inst, x0, y0, x1, y1)) {
        ids.push(inst.id);
      }
    }
    modelState.setSelection(ids);
    this.syncSelection();
    this.refreshGizmo();
    hilog.info(0x0000, 'BoxSelect', '框选命中 %{public}d 个对象（矩形 %{public}d,%{public}d-%{public}d,%{public}d）',
      ids.length, Math.round(x0), Math.round(y0), Math.round(x1), Math.round(y1));
  }

  // 对象包围盒（本地尺寸 × 缩放，按自身旋转摆到世界系）投影后是否与矩形相交
  private boxHits(inst: ModelInstance, x0: number, y0: number, x1: number, y1: number): boolean {
    const ls: Vec3 = this.localSize(inst);
    const s: Vec3 = inst.transform.scale;
    const c: Vec3 = this.instanceCenter(inst);
    const q = this.computeRotation(inst);
    let minX: number = 1e9;
    let maxX: number = -1e9;
    let minY: number = 1e9;
    let maxY: number = -1e9;
    let behind: boolean = false;
    for (let i = 0; i < 8; i++) {
      const sx: number = (i & 1) === 0 ? -0.5 : 0.5;
      const sy: number = (i & 2) === 0 ? -0.5 : 0.5;
      const sz: number = (i & 4) === 0 ? -0.5 : 0.5;
      const w: Vec3 = rotateVecByQuat(q, {
        x: sx * ls.x * s.x,
        y: sy * ls.y * s.y,
        z: sz * ls.z * s.z
      });
      const p: Vec2 = this.projectPoint(this.contentToRoot({ x: c.x + w.x, y: c.y + w.y, z: c.z + w.z }));
      // projectPoint 对视锥后方/过近的点返回 (-1e5,-1e5)：那种投影没有意义，整对象跳过
      if (p.x < -1e4) {
        behind = true;
        break;
      }
      if (p.x < minX) { minX = p.x; }
      if (p.x > maxX) { maxX = p.x; }
      if (p.y < minY) { minY = p.y; }
      if (p.y > maxY) { maxY = p.y; }
    }
    if (behind) {
      return false;
    }
    // 包围盒与矩形相交 = 非「在任一侧完全分离」
    return !(maxX < x0 || minX > x1 || maxY < y0 || minY > y1);
  }

  // 构建当前工具的三维手柄（挂在 pivot 下、位于模型中心，不随模型自转）
  private async refreshGizmo(): Promise<void> {
    // 存活代次：createNode/appendGeometry 都是 await，期间若又发生一次刷新（setTool / 落板 /
    // 删除对象 / syncSelection 等），本次创建的节点必须在每个 await 之后校验并整体丢弃 ——
    // 否则后写覆盖 gizmoRoot 引用，先建的节点成为孤儿（表现为「手柄残影」）。
    this.clearGizmo();
    const gen: number = this.gizmoSeq;
    if (this.tool === 0 || this.tool === 4) {
      return;   // 4 = 框选（选择工具），不出变换手柄
    }
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined || this.pivotNode === null || this.factory === null) {
      return;
    }
    const center: Vec3 = this.instanceCenter(inst);
    const ls: Vec3 = this.localSize(inst);
    const s: Vec3 = inst.transform.scale;
    // 臂长取模型包围球半径的 1.35 倍 → 手柄伸出模型外，避免被模型挡住
    const ex: number = ls.x * s.x, ey: number = ls.y * s.y, ez: number = ls.z * s.z;
    const r: number = 0.5 * Math.sqrt(ex * ex + ey * ey + ez * ez);
    const size: number = Math.max(28, r * 1.35);
    this.gizmoArm = size;
    const root: Node | null = await this.factory.createNode({ name: `gizmo_${gen}` });
    if (root === null) {
      AppLog.warn('PreviewWarn', 'createNode(gizmo) 返回空 → 本次手柄创建跳过');
      return;
    }
    if (gen !== this.gizmoSeq) {
      // 期间已被更新的一次刷新取代 → 丢弃本节点（否则残留）
      root.destroy();
      return;
    }
    root.position = center;
    this.pivotNode.children.append(root);
    this.gizmoRoot = root;

    const names: string[] = ['x', 'y', 'z'];
    // 手柄方向按 Z-up 约定：X 红、Y 绿（盘面纵向）、Z 蓝（竖直）
    const dirs: Vec3[] = [this.contentDir('x'), this.contentDir('y'), this.contentDir('z')];
    const zero: Vec3 = { x: 0, y: 0, z: 0 };
    const shaftR: number = Math.max(0.6, size * 0.018);
    const headR: number = Math.max(1.6, size * 0.06);
    const headLen: number = size * 0.22;
    for (let i = 0; i < 3; i++) {
      let g: MeshGeometry;
      if (this.tool === 1) {
        // 旋转：三轴圆弧环用不同半径（同心错开），避免屏幕上重叠导致选错轴
        g = buildGizmoRing(zero, dirs[i], size * this.ringFactor(names[i]), size * 0.07, size * 0.022, 72, 300);
      } else {
        // 移动(3)：圆锥箭头；缩放(2)：方块头箭头
        g = buildGizmoArrow(zero, dirs[i], size, shaftR, headR, headLen, 14, this.tool === 2);
      }
      const mat: Material | null = this.gizmoMats.length > i ? this.gizmoMats[i] : null;
      await this.appendGeometry(root, g, mat, `gz_${names[i]}`);
      // 箭头也是一次 await：期间可能已删除对象/切换工具 → 把这一轮手柄整体摘掉
      if (gen !== this.gizmoSeq) {
        const rp: Node | null = root.parent;
        if (rp !== null) {
          rp.children.remove(root);
        }
        root.destroy();
        if (this.gizmoRoot === root) {
          this.gizmoRoot = null;
        }
        return;
      }
    }
  }

  // ---------- 手柄拾取 / 拖拽（纯解析几何，不用射线拾取，避免三轴重叠歧义） ----------
  // 视场角/眼距的实际取值：近正交模式下按 orthoK 压缩（取景不变，只削弱透视收缩）。
  // 这三处是「近正交」改动面最小的关键 —— 投影/射线/相机推送全走它们，其余代码仍用 this.dist。
  private viewScaleK(): number {
    return this.orthoLike ? this.orthoK : 1;
  }

  private effFov(): number {
    return 2 * Math.atan(Math.tan(this.fovY * 0.5) * this.viewScaleK());
  }

  private effDist(): number {
    return this.dist / this.viewScaleK();
  }

  private tanHalf(): number {
    return Math.tan(this.effFov() * 0.5);
  }

  private aspect(): number {
    return this.viewW / Math.max(1, this.viewH);
  }

  // 根坐标点 → 屏幕（vp）。相机固定在 (0,0,dist)、朝 -Z，因此可解析投影
  private projectPoint(p: Vec3): Vec2 {
    const depth: number = this.effDist() - p.z;
    if (depth <= 1e-3) {
      return { x: -1e5, y: -1e5 };
    }
    const th: number = this.tanHalf();
    const ndcX: number = p.x / (depth * th * this.aspect());
    const ndcY: number = p.y / (depth * th);
    return { x: (ndcX * 0.5 + 0.5) * this.viewW, y: (1 - (ndcY * 0.5 + 0.5)) * this.viewH };
  }

  // 屏幕（vp）→ 根空间射线
  private pointerRay(sx: number, sy: number): LocalRay {
    const th: number = this.tanHalf();
    const ndcX: number = (sx / this.viewW) * 2 - 1;
    const ndcY: number = 1 - (sy / this.viewH) * 2;
    const dx: number = ndcX * th * this.aspect();
    const dy: number = ndcY * th;
    const l: number = Math.sqrt(dx * dx + dy * dy + 1);
    const r: LocalRay = new LocalRay();
    r.o = { x: 0, y: 0, z: this.effDist() };
    r.d = { x: dx / l, y: dy / l, z: -1 / l };
    return r;
  }

  // UI 轴 → content 空间方向。Z-up 约定：UI 的 Y 是盘面纵向（=content Z），UI 的 Z 是竖直（=content Y）
  private contentDir(ui: string): Vec3 {
    if (ui === 'x') {
      return { x: 1, y: 0, z: 0 };
    }
    if (ui === 'y') {
      return { x: 0, y: 0, z: 1 };
    }
    return { x: 0, y: 1, z: 0 };
  }

  // UI 轴 → content 缩放分量键（x→x, y→z, z→y）
  private contentKey(ui: string): string {
    return ui === 'x' ? 'x' : (ui === 'y' ? 'z' : 'y');
  }

  private scaleComp(s: Vec3, key: string): number {
    return key === 'x' ? s.x : (key === 'y' ? s.y : s.z);
  }

  private withScaleComp(s: Vec3, key: string, v: number): Vec3 {
    return {
      x: key === 'x' ? v : s.x,
      y: key === 'y' ? v : s.y,
      z: key === 'z' ? v : s.z,
    };
  }

  // 旋转环半径系数（三轴错开：X 最大、Z 最小）
  private ringFactor(axis: string): number {
    return axis === 'x' ? 1.0 : (axis === 'y' ? 0.86 : 0.72);
  }

  // 手柄中心（根坐标）
  private gizmoCenterRoot(inst: ModelInstance): Vec3 {
    return this.contentToRoot(this.instanceCenter(inst));
  }

  // 某轴手柄在屏幕上的折线（旋转=圆弧环；移动/缩放=中心到尖端线段），用于最近轴判定
  private axisPolyline(inst: ModelInstance, axis: string): Vec2[] {
    const center: Vec3 = this.instanceCenter(inst);
    const unit: Vec3 = this.contentDir(axis);
    const toScreen = (local: Vec3): Vec2 => {
      return this.projectPoint(this.contentToRoot(local));
    };
    const pts: Vec2[] = [];
    if (this.tool === 1) {
      const b: Vec3[] = gizmoBasis(unit);
      const radius: number = this.gizmoArm * this.ringFactor(axis);
      const arc: number = 300 * Math.PI / 180;
      const n: number = 28;
      for (let k = 0; k <= n; k++) {
        const th: number = arc * (k / n);
        const cu: number = Math.cos(th) * radius;
        const sv: number = Math.sin(th) * radius;
        pts.push(toScreen({
          x: center.x + b[0].x * cu + b[1].x * sv,
          y: center.y + b[0].y * cu + b[1].y * sv,
          z: center.z + b[0].z * cu + b[1].z * sv,
        }));
      }
    } else {
      pts.push(toScreen(center));
      pts.push(toScreen({
        x: center.x + unit.x * this.gizmoArm,
        y: center.y + unit.y * this.gizmoArm,
        z: center.z + unit.z * this.gizmoArm,
      }));
    }
    return pts;
  }

  private polylineDist(px: number, py: number, pts: Vec2[]): number {
    let best: number = 1e30;
    for (let i = 0; i + 1 < pts.length; i++) {
      const d: number = distSeg(px, py, pts[i], pts[i + 1]);
      if (d < best) {
        best = d;
      }
    }
    return best;
  }

  // 拾取：选「屏幕距离指针最近」的轴（阈值 20vp）——不依赖射线，无重叠歧义
  private pickGizmoAxis(px: number, py: number): string {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined || this.gizmoRoot === null) {
      return '';
    }
    const axes: string[] = ['x', 'y', 'z'];
    let bestAxis: string = '';
    let bestD: number = 1e30;
    for (const a of axes) {
      const d: number = this.polylineDist(px, py, this.axisPolyline(inst, a));
      if (d < bestD) {
        bestD = d;
        bestAxis = a;
      }
    }
    return bestD <= 20 ? bestAxis : '';
  }

  // 沿某轴拖拽量：指针射线与「含该轴、最正对相机」的平面求交，再投影到轴上（世界单位）
  private axisDragDistance(inst: ModelInstance, axis: string, sx: number, sy: number): number {
    return this.axisDragDistanceAt(this.gizmoCenterRoot(inst), axis, sx, sy);
  }

  // 相对**指定**参考点 cRoot 的轴上投影距离（移动拖拽要传拖拽起点，避免自反馈）
  private axisDragDistanceAt(cRoot: Vec3, axis: string, sx: number, sy: number): number {
    const R: Quaternion = this.pivotRotation();
    const aRoot: Vec3 = rotateVecByQuat(R, this.contentDir(axis));
    const f: Vec3 = { x: 0, y: 0, z: -1 }; // 视线方向
    let n: Vec3 = v3cross(aRoot, v3cross(f, aRoot));
    const nl: number = v3len(n);
    if (nl < 1e-4) {
      n = { x: 0, y: 0, z: 1 };
    } else {
      n = v3mul(n, 1 / nl);
    }
    const ray: LocalRay = this.pointerRay(sx, sy);
    const denom: number = v3dot(ray.d, n);
    if (Math.abs(denom) < 1e-6) {
      return 0;
    }
    const t: number = v3dot(v3sub(cRoot, ray.o), n) / denom;
    if (t <= 0) {
      return 0;
    }
    const hit: Vec3 = v3add(ray.o, v3mul(ray.d, t));
    return v3dot(v3sub(hit, cRoot), aRoot);
  }

  // 当前选中的对象实例（多选时 = 整组；单选时 = 那一个）。
  // 所有变换类操作统一从这里取目标，于是「多选后拖手柄 = 整组一起动」自动成立。
  private selectedInstances(): ModelInstance[] {
    const out: ModelInstance[] = [];
    for (const id of modelState.selectedIds) {
      const inst: ModelInstance | undefined = modelState.get(id);
      if (inst !== undefined) {
        out.push(inst);
      }
    }
    if (out.length === 0) {
      const one: ModelInstance | undefined = modelState.getSelected();
      if (one !== undefined) {
        out.push(one);
      }
    }
    return out;
  }

  private beginGizmoDrag(axis: string, px: number, py: number): boolean {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return false;
    }
    this.dragAxis = axis;
    this.dragPos0 = { x: inst.transform.position.x, y: inst.transform.position.y, z: inst.transform.position.z };
    this.dragRot0 = { x: inst.transform.rotX, y: inst.transform.rotY, z: inst.transform.rotZ };
    this.dragScale0 = inst.transform.scale.x;
    // 单轴缩放的固定基数：拖拽开始时该轴的分量（之后所有帧都相对它算，杜绝复利）
    this.dragComp0 = this.scaleComp(inst.transform.scale, this.contentKey(axis));
    // 固定参考点先取，再算起始投影 —— 之后所有帧都相对它算，不会自反馈
    this.dragCenter0 = this.gizmoCenterRoot(inst);
    this.dragS0 = this.axisDragDistanceAt(this.dragCenter0, axis, px, py);
    this.dragCenterScreen = this.projectPoint(this.gizmoCenterRoot(inst));
    const cdx: number = px - this.dragCenterScreen.x;
    const cdy: number = py - this.dragCenterScreen.y;
    this.dragD0 = Math.max(30, Math.sqrt(cdx * cdx + cdy * cdy)); // 起始屏幕半径（下限防过灵敏）
    this.dragPrevAngle = Math.atan2(py - this.dragCenterScreen.y, px - this.dragCenterScreen.x);
    this.dragAccAngle = 0;
    const aRoot: Vec3 = rotateVecByQuat(this.pivotRotation(), this.contentDir(axis));
    // 拖拽方向与视觉一致：轴朝向观察者时，屏幕顺时针拖拽 = 绕轴负向旋转
    this.dragRotSign = aRoot.z > 0 ? -1 : 1;
    // 多选：把整组的起始基线都记下来（拖拽时每帧由「基线 + 增量」得出绝对目标值）
    this.dragBasePos.clear();
    this.dragBaseRot.clear();
    this.dragBaseScale.clear();
    this.dragBaseComp.clear();
    for (const t of this.selectedInstances()) {
      this.dragBasePos.set(t.id, {
        x: t.transform.position.x,
        y: t.transform.position.y,
        z: t.transform.position.z
      });
      this.dragBaseRot.set(t.id, { x: t.transform.rotX, y: t.transform.rotY, z: t.transform.rotZ });
      this.dragBaseScale.set(t.id, t.transform.scale.x);
      this.dragBaseComp.set(t.id, this.scaleComp(t.transform.scale, this.contentKey(axis)));
    }
    return true;
  }

  // 合并高频指针事件：只保留最新坐标，最多每 ~16ms 更新一次（见字段注释）。
  private queueGizmoDrag(px: number, py: number): void {
    this.dragPx = px;
    this.dragPy = py;
    if (this.dragScheduled) {
      return;
    }
    this.dragScheduled = true;
    setTimeout(() => {
      this.dragScheduled = false;
      if (this.dragAxis !== '') {
        this.updateGizmoDrag(this.dragPx, this.dragPy);
      }
    }, 16);
  }

  private updateGizmoDrag(px: number, py: number): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined || this.dragAxis === '') {
      return;
    }
    const u: string = this.dragAxis;
    if (this.tool === 1) {
      // 旋转：累计指针绕屏幕中心的转角（拖动中不做落板，避免上下抖动）
      const ang: number = Math.atan2(py - this.dragCenterScreen.y, px - this.dragCenterScreen.x);
      let d: number = ang - this.dragPrevAngle;
      if (d > Math.PI) { d -= Math.PI * 2; }
      if (d < -Math.PI) { d += Math.PI * 2; }
      this.dragPrevAngle = ang;
      this.dragAccAngle += d;
      const deg: number = this.dragAccAngle * 57.29578 * this.dragRotSign;
      // 整组旋转 = 每个对象各绕**自身中心**转同样角度（保持相对摆位不变）。
      // 整组绕「共同中心公转」是另一种语义，需要把手柄画在整组质心上，此处不做。
      for (const t of this.selectedInstances()) {
        const b: Vec3 | undefined = this.dragBaseRot.get(t.id);
        const bx: number = b !== undefined ? b.x : this.dragRot0.x;
        const by: number = b !== undefined ? b.y : this.dragRot0.y;
        const bz: number = b !== undefined ? b.z : this.dragRot0.z;
        let rx: number = bx;
        let ry: number = by;
        let rz: number = bz;
        if (u === 'x') {
          rx = bx + deg;
        } else if (u === 'y') {
          ry = by + deg;
        } else {
          rz = bz + deg;
        }
        this.applyRotationAboutCenter(t, rx, ry, rz);
        this.applyTransform(t);
      }
      this.followGizmo(inst);
      return;
    }
    if (this.tool === 3) {
      // 移动：轴上世界位移
      const wd: number = this.axisDragDistanceAt(this.dragCenter0, u, px, py) - this.dragS0;
      const unit: Vec3 = this.contentDir(u);
      // 整组平移：每个对象在**各自的起始位置**上叠加同一个世界位移
      for (const t of this.selectedInstances()) {
        const b: Vec3 | undefined = this.dragBasePos.get(t.id);
        const bx: number = b !== undefined ? b.x : this.dragPos0.x;
        const by: number = b !== undefined ? b.y : this.dragPos0.y;
        const bz: number = b !== undefined ? b.z : this.dragPos0.z;
        t.transform.position = {
          x: bx + unit.x * wd,
          y: by + unit.y * wd,
          z: bz + unit.z * wd,
        };
        this.applyTransform(t);
      }
      this.followGizmo(inst);
    } else if (this.tool === 2) {
      // 缩放：改为【沿轴线性】驱动（与「移动」共用同一套轴投影）。
      // 【为什么改】原来用「指针到中心的屏幕半径 / 起始半径」(d/dragD0)：起始半径小(下限 30px)
      // 就极敏感（挪几像素就翻倍），且是**乘性**映射 —— 30→60 翻倍、100→130 只 +30%，
      // 大小不同手感完全不同（用户反馈「不线性、很难控制」）。
      // 现在：沿轴拖过「一个手柄臂长」= 缩放变化 100%（f = 1 + wd/arm），全程线性、可预测。
      const wd: number = this.axisDragDistanceAt(this.dragCenter0, u, px, py) - this.dragS0;
      const arm: number = this.gizmoArm > 1 ? this.gizmoArm : 30;
      const f: number = Math.max(0.05, Math.min(20, 1 + wd / arm));
      // 整组缩放：每个对象各绕自身中心、按同一比例缩放
      for (const t of this.selectedInstances()) {
        const bs: number = this.dragBaseScale.get(t.id) ?? this.dragScale0;
        const s: Vec3 = t.transform.scale;
        if (this.scaleLocked) {
          const k: number = Math.max(0.01, Math.min(20, bs * f));
          t.transform.scale = { x: k, y: k, z: k };
        } else {
          const ck: string = this.contentKey(u);
          // 用【拖拽起始分量】×f 得到绝对目标值（而不是「当前分量」×f → 那会每帧复利）
          const bc: number = this.dragBaseComp.get(t.id) ?? this.dragComp0;
          const k: number = Math.max(0.01, Math.min(20, bc * f));
          t.transform.scale = this.withScaleComp(s, ck, k);
        }
        this.applyTransform(t);
      }
      this.followGizmo(inst);
    }
  }

  // 拖动中让手柄跟着模型走：手柄根位置只在 refreshGizmo() 里设过一次，
  // 而 refreshGizmo() 之前只在 endGizmoDrag() 调用 → 拖动期间手柄停在原地、松手才跳。
  // 这里在每次更新模型后同步手柄根位置，实现「跟手」。
  private followGizmo(inst: ModelInstance): void {
    if (this.gizmoRoot !== null) {
      this.gizmoRoot.position = this.instanceCenter(inst);
    }
  }

  private endGizmoDrag(): void {
    if (this.dragAxis !== '') {
      if (this.tool !== 3) {
        // 整组一起落板（多选时每个对象都要落；移动不需要，所以只在旋转/缩放时做）
        for (const t of this.selectedInstances()) {
          this.dropAfterRotate(t);
          this.applyTransform(t);
        }
      }
      this.dragAxis = '';
      this.updateFit();
      this.syncSelection();
      this.refreshGizmo();
    }
  }

  // 应用手柄增量：正数加、负数减
  private applyGizmoDelta(): void {
    const v: number = Number(this.deltaText);
    const axis: string = this.deltaAxis;
    this.deltaAxis = '';
    this.deltaText = '';
    if (axis === '' || !Number.isFinite(v) || v === 0) {
      return;
    }
    // 整组生效：多选时数值输入同样作用于全部选中对象（与拖手柄一致）
    const targets: ModelInstance[] = this.selectedInstances();
    if (targets.length === 0) {
      return;
    }
    if (this.tool === 3) {
      // 移动（mm）：按 UI 轴映射到 content 方向
      const d: Vec3 = this.contentDir(axis);
      for (const inst of targets) {
        inst.transform.position = {
          x: inst.transform.position.x + d.x * v,
          y: inst.transform.position.y + d.y * v,
          z: inst.transform.position.z + d.z * v,
        };
        this.applyTransform(inst);
      }
    } else if (this.tool === 1) {
      // 旋转（度）
      for (const inst of targets) {
        if (axis === 'x') {
          inst.transform.rotX += v;
        } else if (axis === 'y') {
          inst.transform.rotY += v;
        } else {
          inst.transform.rotZ += v;
        }
        this.dropAfterRotate(inst);
        this.applyTransform(inst);
      }
    } else if (this.tool === 2) {
      // 缩放：百分比增量；锁定→等比，解锁→仅该轴
      const f: number = Math.max(0.01, Math.min(20, 1 + v / 100));
      for (const inst of targets) {
        const s: Vec3 = inst.transform.scale;
        if (this.scaleLocked) {
          const k: number = Math.max(0.01, Math.min(20, s.x * f));
          inst.transform.scale = { x: k, y: k, z: k };
        } else {
          const ck: string = this.contentKey(axis);
          const k: number = Math.max(0.01, Math.min(20, this.scaleComp(s, ck) * f));
          inst.transform.scale = this.withScaleComp(s, ck, k);
        }
        this.dropAfterRotate(inst);
        this.applyTransform(inst);
      }
      this.updateFit();
    }
    this.syncSelection();
    this.refreshGizmo();
  }

  // 模型中心（内容坐标系）
  private instanceCenter(inst: ModelInstance): Vec3 {
    const lc: Vec3 = this.localCenter(inst);
    const s: Vec3 = inst.transform.scale;
    const rc: Vec3 = rotateVecByQuat(this.computeRotation(inst),
      { x: lc.x * s.x, y: lc.y * s.y, z: lc.z * s.z });
    return {
      x: inst.transform.position.x + rc.x,
      y: inst.transform.position.y + rc.y,
      z: inst.transform.position.z + rc.z,
    };
  }

  // ---------------------------------------------------------------------------
  // 数值面板输入应用
  // ---------------------------------------------------------------------------
  private toggleScaleLock(): void {
    this.scaleLocked = !this.scaleLocked;
    if (this.scaleLocked) {
      // 重新锁定 → 以 X 为准把三轴统一
      const inst: ModelInstance | undefined = modelState.getSelected();
      if (inst !== undefined) {
        const s: number = Math.max(0.01, inst.transform.scale.x);
        inst.transform.scale = { x: s, y: s, z: s };
        this.dropAfterRotate(inst);
        this.applyTransform(inst);
        this.updateFit();
        this.syncSelection();
        this.refreshGizmo();
      }
    }
  }

  // 百分比缩放：锁定→等比；解锁→等比（百分比始终统一三轴）
  private applyScalePct(): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    const v: number = Number(this.inScale);
    if (inst === undefined || !Number.isFinite(v) || v <= 0) {
      this.syncSelection();
      return;
    }
    const k: number = Math.max(0.01, Math.min(20, v / 100));
    inst.transform.scale = { x: k, y: k, z: k };
    this.dropAfterRotate(inst);
    this.applyTransform(inst);
    this.updateFit();
    this.syncSelection();
    this.refreshGizmo();
  }

  // 输入某轴尺寸（mm）：锁定→三轴等比；解锁→仅该轴（UI 轴按 Z-up 映射到 content 轴）
  private applyDim(uiAxis: string): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return;
    }
    const raw: string = uiAxis === 'x' ? this.inDimX : (uiAxis === 'y' ? this.inDimY : this.inDimZ);
    const v: number = Number(raw);
    const ls: Vec3 = this.localSize(inst);
    const ck: string = this.contentKey(uiAxis);
    const base: number = ck === 'x' ? ls.x : (ck === 'y' ? ls.y : ls.z);
    if (!Number.isFinite(v) || v <= 0 || base <= 1e-6) {
      this.syncSelection();
      return;
    }
    const k: number = Math.max(0.01, Math.min(20, v / base));
    if (this.scaleLocked) {
      inst.transform.scale = { x: k, y: k, z: k };
    } else {
      inst.transform.scale = this.withScaleComp(inst.transform.scale, ck, k);
    }
    this.dropAfterRotate(inst);
    this.applyTransform(inst);
    this.updateFit();
    this.syncSelection();
    this.refreshGizmo();
  }

  private applyRotInput(axis: string): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return;
    }
    const raw: string = axis === 'x' ? this.inRotX : (axis === 'y' ? this.inRotY : this.inRotZ);
    const v: number = Number(raw);
    if (!Number.isFinite(v)) {
      this.syncSelection();
      return;
    }
    const rx: number = axis === 'x' ? v : inst.transform.rotX;
    const ry: number = axis === 'y' ? v : inst.transform.rotY;
    const rz: number = axis === 'z' ? v : inst.transform.rotZ;
    this.applyRotationAboutCenter(inst, rx, ry, rz); // 绕模型中心旋转
    this.dropAfterRotate(inst);
    this.applyTransform(inst);
    this.syncSelection();
    this.refreshGizmo();
  }

  // 移动输入：X/Z 为盘面坐标（底板左下角=0,0），Y 为高度
  private applyPosInput(axis: string): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return;
    }
    const raw: string = axis === 'x' ? this.inPosX : (axis === 'y' ? this.inPosY : this.inPosZ);
    const v: number = Number(raw);
    if (!Number.isFinite(v)) {
      this.syncSelection();
      return;
    }
    if (axis === 'x') {
      inst.transform.position.x = v - this.plateW * 0.5;
    } else if (axis === 'y') {
      // UI Y = 盘面纵向；content Z 与盘面 Y 反向（z = −(bedY − 盘中心)）
      inst.transform.position.z = this.plateH * 0.5 - v;
    } else {
      inst.transform.position.y = v; // UI Z = 高度（content Y）
    }
    this.applyTransform(inst);
    this.syncSelection();
    this.refreshGizmo();
  }

  // ---------------------------------------------------------------------------
  // 编辑操作（作用于选中模型）
  // ---------------------------------------------------------------------------
  // 贴底面：旋转后（当前朝向）把模型最低点落回板面
  private onDropToBed(): void {
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return;
    }
    this.dropAfterRotate(inst);
    this.applyTransform(inst);
  }

  // 切换选面模式
  private togglePickFace(): void {
    this.pickFaceMode = !this.pickFaceMode;
    if (this.pickFaceMode) {
      this.tool = 0;
      this.clearGizmo();
      this.modelInfoText = '选面模式：鼠标悬停高亮，点击面使其朝下贴板';
    } else {
      this.clearHighlight();
      this.syncSelection();
    }
  }

  // ---------------------------------------------------------------------------
  // 选面 / 悬停高亮
  // ---------------------------------------------------------------------------
  // root 空间（相机空间，raycast 的 hitPosition / projectPoint 都在这个空间）
  // ↔ content 空间（工程/世界坐标，模型 transform / 包围盒 / 手柄中心都用它）互换。
  // 变换链：root = R*(content - target)（world 外层只做平移、pivot 内层做 R 旋转）
  // 全页只有这两条公式；凡「世界坐标 ↔ 屏幕」的换算都必须走这里，
  // 否则同一份坐标在不同调用点用不同口径解读（点会「钉」在屏幕上不跟随视角）。
  private rootToContent(p: Vec3): Vec3 {
    const invR: Quaternion = quatInverse(eulerToQuaternion(this.pitch, this.yaw));
    const c: Vec3 = rotateVecByQuat(invR, p);
    return { x: c.x + this.target.x, y: c.y + this.target.y, z: c.z + this.target.z };
  }

  private contentToRoot(p: Vec3): Vec3 {
    return rotateVecByQuat(this.pivotRotation(),
      { x: p.x - this.target.x, y: p.y - this.target.y, z: p.z - this.target.z });
  }

  // 根坐标点 → 模型局部坐标
  private hitToLocal(inst: ModelInstance, p: Vec3): Vec3 {
    const content: Vec3 = this.rootToContent(p);
    const s: Vec3 = inst.transform.scale;
    const delta: Vec3 = {
      x: content.x - inst.transform.position.x,
      y: content.y - inst.transform.position.y,
      z: content.z - inst.transform.position.z,
    };
    const deltaLocal: Vec3 = rotateVecByQuat(quatInverse(this.computeRotation(inst)), delta);
    return {
      x: deltaLocal.x / (Math.abs(s.x) > 1e-6 ? s.x : 1),
      y: deltaLocal.y / (Math.abs(s.y) > 1e-6 ? s.y : 1),
      z: deltaLocal.z / (Math.abs(s.z) > 1e-6 ? s.z : 1),
    };
  }

  // 计算模型局部坐标系下的射线（origin + t*dir），原点取相机位置
  private localRay(inst: ModelInstance, hitPos: Vec3): LocalRay {
    const camRoot: Vec3 = this.camera !== null ? this.camera.position : { x: 0, y: 0, z: 0 };
    const r: LocalRay = new LocalRay();
    r.o = this.hitToLocal(inst, camRoot);
    const h: Vec3 = this.hitToLocal(inst, hitPos);
    const dx: number = h.x - r.o.x;
    const dy: number = h.y - r.o.y;
    const dz: number = h.z - r.o.z;
    const l: number = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (l < 1e-9) {
      r.d = { x: 0, y: -1, z: 0 };
    } else {
      r.d = { x: dx / l, y: dy / l, z: dz / l };
    }
    return r;
  }

  // 惰性构建面索引（按共面连通把网格归并成一个平面 = 一个面组）
  private getFaceIndex(inst: ModelInstance): FaceIndex {
    if (inst.faceIndex === null) {
      inst.faceIndex = FaceIndex.build(inst.geometry);
    }
    return inst.faceIndex;
  }

  // 射线 → 面组 id（-1 = 未命中）。用射线最先命中的三角形，边缘处比最近点更准
  private faceGroupAtRay(inst: ModelInstance, origin: Vec3, dir: Vec3): number {
    const fi: FaceIndex = this.getFaceIndex(inst);
    let ti: number = fi.rayPick(inst.geometry, origin, dir);
    if (ti < 0) {
      ti = fi.nearestTriangle(inst.geometry, origin);
    }
    if (ti < 0 || ti >= fi.triToGroup.length) {
      return -1;
    }
    return fi.triToGroup[ti];
  }

  // 命中 / 悬停拾取：把射线限定在「该模型的容器子树」内，
  // 避免被底板/网格线挡住（否则贴着底板的面无法拾取）。
  private raycastParamsFor(inst: ModelInstance): RaycastParameters {
    const container: Node | undefined = this.containers.get(inst.id);
    return container !== undefined ? { rootNode: container } : {};
  }

  // 命中的节点是否算作模型（模型网格节点 或 高亮面片节点）
  private isPickableHit(inst: ModelInstance, n: Node): boolean {
    const node: Geometry | undefined = this.nodes.get(inst.id);
    if (node !== undefined && n === node) {
      return true;
    }
    if (this.highlightNode !== null && n === this.highlightNode) {
      return true;
    }
    return false;
  }

  // 选面：点击位置（归一化屏幕坐标）→ raycast → 旋转使命中面朝下 → 落板
  private async onPickFace(viewPos: Vec2): Promise<void> {
    if (this.camera === null) {
      return;
    }
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return;
    }
    const node: Geometry | undefined = this.nodes.get(inst.id);
    if (node === undefined) {
      return;
    }
    // 先清掉高亮面片，避免射线先打到高亮层（0.25mm 偏移）
    this.clearHighlight();
    const results: RaycastResult[] = await this.camera.raycast(viewPos, this.raycastParamsFor(inst));
    if (results.length === 0) {
      return;
    }
    let hitPos: Vec3 | null = null;
    for (const r of results) {
      if (this.isPickableHit(inst, r.node)) {
        hitPos = r.hitPosition;
        break;
      }
    }
    if (hitPos === null) {
      return;
    }

    const ray: LocalRay = this.localRay(inst, hitPos);
    const gid: number = this.faceGroupAtRay(inst, ray.o, ray.d);
    if (gid < 0) {
      return;
    }
    const nrm: Vec3 = this.getFaceIndex(inst).groupNormal[gid];
    if (!isFiniteVec3(nrm)) {
      return;
    }

    // 选面基准朝向：把命中面法线转到朝下；同时清零用户欧拉角（之后调 XYZ 是叠加）
    // 保持模型中心不动（绕中心翻转）
    const lc: Vec3 = this.localCenter(inst);
    const s: Vec3 = inst.transform.scale;
    const rcOld: Vec3 = rotateVecByQuat(this.computeRotation(inst),
      { x: lc.x * s.x, y: lc.y * s.y, z: lc.z * s.z });
    const cx: number = inst.transform.position.x + rcOld.x;
    const cy: number = inst.transform.position.y + rcOld.y;
    const cz: number = inst.transform.position.z + rcOld.z;
    inst.transform.baseRotation = fromToQuat(nrm, { x: 0, y: -1, z: 0 });
    inst.transform.rotX = 0;
    inst.transform.rotY = 0;
    inst.transform.rotZ = 0;
    const rcNew: Vec3 = rotateVecByQuat(this.computeRotation(inst),
      { x: lc.x * s.x, y: lc.y * s.y, z: lc.z * s.z });
    inst.transform.position = { x: cx - rcNew.x, y: cy - rcNew.y, z: cz - rcNew.z };

    this.clearHighlight();
    this.dropAfterRotate(inst);
    this.applyTransform(inst);
    this.syncSelection();
  }

  // 悬停移动：射线拾取 → 高亮命中的三角形
  private handleHoverMove(nx: number, ny: number): void {
    if (!this.pickFaceMode || this.hoverBusy || this.camera === null) {
      return;
    }
    const inst: ModelInstance | undefined = modelState.getSelected();
    if (inst === undefined) {
      return;
    }
    const node: Geometry | undefined = this.nodes.get(inst.id);
    if (node === undefined) {
      return;
    }
    this.hoverBusy = true;
    this.camera.raycast({ x: nx, y: ny }, this.raycastParamsFor(inst)).then((results: RaycastResult[]) => {
      this.hoverBusy = false;
      let hitPos: Vec3 | null = null;
      for (const r of results) {
        if (this.isPickableHit(inst, r.node)) {
          hitPos = r.hitPosition;
          break;
        }
      }
      if (hitPos === null) {
        this.clearHighlight();
        return;
      }
      const ray: LocalRay = this.localRay(inst, hitPos);
      const gid: number = this.faceGroupAtRay(inst, ray.o, ray.d);
      if (gid < 0 || gid === this.highlightTri) {
        return;
      }
      this.highlightTri = gid;
      this.rebuildHighlight(inst, gid);
    }).catch(() => {
      this.hoverBusy = false;
    });
  }

  // 用命中的整个平面（面组）重建高亮面片（沿法线微抬，贴在模型表面）
  private async rebuildHighlight(inst: ModelInstance, gid: number): Promise<void> {
    this.destroyHighlightNode();
    if (this.highlightMat === null) {
      return;
    }
    const container: Node | undefined = this.containers.get(inst.id);
    if (container === undefined) {
      return;
    }
    const fi: FaceIndex = this.getFaceIndex(inst);
    if (gid < 0 || gid >= fi.groupTris.length) {
      return;
    }
    const tris: number[] = fi.groupTris[gid];
    const nrm: Vec3 = fi.groupNormal[gid];
    const src: MeshGeometry = inst.geometry;
    const lift: number = 0.25;
    const cap: number = 20000; // 面组过大时只高亮前 N 个三角形，避免卡顿
    const cnt: number = Math.min(tris.length, cap);
    const g: MeshGeometry = new MeshGeometry();
    const V: Vec3[] = [];
    const N: Vec3[] = [];
    const vtx: Vec3 = { x: 0, y: 0, z: 0 };
    for (let k = 0; k < cnt; k++) {
      const tri: number = tris[k];
      for (let j = 0; j < 3; j++) {
        // 索引网格按 indices 取顶点；面汤按 tri*3+j 取（两种形态都支持；大网格从 TypedArray 读）
        meshVertexAt(src, meshVertexIndex(src, tri, j), vtx);
        V.push({ x: vtx.x + nrm.x * lift, y: vtx.y + nrm.y * lift, z: vtx.z + nrm.z * lift });
        N.push(nrm);
      }
    }
    g.vertices = V;
    g.normals = N;
    this.hlSeq++;
    // 用返回值，不再从「最后一个子节点」反推（创建失败时会错拿到对象自己的网格节点）
    const geo: Geometry | null = await this.appendGeometry(container, g, this.highlightMat, `hl_${this.hlSeq}`);
    if (geo !== null) {
      geo.rotation = this.computeRotation(inst);
      const s: Vec3 = inst.transform.scale;
      geo.scale = { x: s.x, y: s.y, z: s.z };
      this.highlightNode = geo;
    }
  }

  private destroyHighlightNode(): void {
    if (this.highlightNode !== null) {
      const parent: Node | null = this.highlightNode.parent;
      if (parent !== null) {
        parent.children.remove(this.highlightNode);
      }
      this.highlightNode.destroy();
      this.highlightNode = null;
    }
  }

  private clearHighlight(): void {
    this.destroyHighlightNode();
    this.highlightTri = -1;
  }

  // 旋转后，把模型最低点落到板面（+ PLATE_LIFT_MM 防共面闪烁，见 ModelState 常量说明）
  private dropAfterRotate(inst: ModelInstance): void {
    const g: MeshGeometry = inst.geometry;
    const s: Vec3 = inst.transform.scale;
    const rot: Quaternion = this.computeRotation(inst);
    let minY: number = 1e30;
    const vc: number = g.vertexCount();
    const p: Float32Array | null = g.pos;
    const vtx: Vec3 = { x: 0, y: 0, z: 0 };
    for (let i = 0; i < vc; i++) {
      if (p !== null) {
        const k: number = i * 3;
        vtx.x = p[k]; vtx.y = p[k + 1]; vtx.z = p[k + 2];
      } else {
        const v: Vec3 = g.vertices[i];
        vtx.x = v.x; vtx.y = v.y; vtx.z = v.z;
      }
      const rv: Vec3 = rotateVecByQuat(rot, { x: vtx.x * s.x, y: vtx.y * s.y, z: vtx.z * s.z });
      if (rv.y < minY) {
        minY = rv.y;
      }
    }
    if (minY > 1e29 || !Number.isFinite(minY)) {
      return; // 顶点异常，保持原位，避免弹飞
    }
    inst.transform.position.y = PLATE_LIFT_MM - minY;
  }

  // ---------------------------------------------------------------------------
  // 视角控制（相机固定看向屏幕中心；内容整体绕锚点旋转）
  // ---------------------------------------------------------------------------
  private pivotRotation(): Quaternion {
    return eulerToQuaternion(this.pitch, this.yaw);
  }

  // 更新视角：相机固定在 (0,0,dist) 看向原点（= 屏幕中心）；
  // 内容经 pivot(R) 旋转、world(-R*target) 平移后，使 target 恰好位于原点（屏幕中心）。
  private updateView(): void {
    const R: Quaternion = this.pivotRotation();
    if (this.camera !== null) {
      // 近正交模式：眼距换成 effDist（= dist/k），fov 换成 effFov，二者同步缩放 → 取景不变
      const ed: number = this.effDist();
      this.camera.position = { x: 0, y: 0, z: ed };
      this.camera.rotation = { x: 0, y: 0, z: 0, w: 1 };
      this.camera.fov = this.effFov();
      // 眼距被推远后远裁剪面必须跟着放（否则模型被裁掉）；透视模式下 effDist ≤ 2500 →
      // max(5000, …) 恒为 5000，与改前的固定值完全一致，不改变既有行为。
      this.camera.farPlane = Math.max(5000, ed + 2000);
    }
    if (this.pivotNode !== null) {
      this.pivotNode.rotation = R;
    }
    if (this.worldNode !== null) {
      const rp: Vec3 = rotateVecByQuat(R, this.target);
      this.worldNode.position = { x: -rp.x, y: -rp.y, z: -rp.z };
    }
  }

  // 锚点 = 当前内容（模型/预设方块）中心
  private recenterTarget(): void {
    if (modelState.hasModel()) {
      let sx: number = 0, sy: number = 0, sz: number = 0, n: number = 0;
      for (const inst of modelState.instances) {
        const lc: Vec3 = this.localCenter(inst);
        const s: Vec3 = inst.transform.scale;
        const rc: Vec3 = rotateVecByQuat(this.computeRotation(inst),
          { x: lc.x * s.x, y: lc.y * s.y, z: lc.z * s.z });
        sx += inst.transform.position.x + rc.x;
        sy += inst.transform.position.y + rc.y;
        sz += inst.transform.position.z + rc.z;
        n++;
      }
      if (n > 0) {
        this.target = { x: sx / n, y: sy / n, z: sz / n };
      }
    } else {
      // 预设 20mm 立方体：底面贴板，中心在 y = PLATE_LIFT_MM + 10
      this.target = { x: 0, y: PLATE_LIFT_MM + 10, z: 0 };
    }
  }

  // 平移：内容跟随手指（屏幕平面），移动锚点 target，带边界限制
  private applyPan(dx: number, dy: number): void {
    // 近正交下眼距被放大 1/k，但屏幕→世界比例 ∝ tan(fov/2)*眼距 不变，
    // 所以这里要按用户视角的 dist 再乘回 k，否则平移手感会变快 k 倍。
    const k: number = panPerPixel(this.dist * this.viewScaleK());
    // 期望内容在根空间的位移（屏幕右=+X、上=+Y；内容跟随手指）
    const dRoot: Vec3 = { x: dx * k, y: -dy * k, z: 0 };
    // root 位移 = -R*ΔP → ΔP = -invR*dRoot
    const dP: Vec3 = rotateVecByQuat(quatInverse(this.pivotRotation()),
      { x: -dRoot.x, y: -dRoot.y, z: -dRoot.z });
    const tx: number = this.target.x + dP.x;
    const ty: number = this.target.y + dP.y;
    const tz: number = this.target.z + dP.z;
    this.target = {
      x: Math.max(-this.panLimit, Math.min(this.panLimit, tx)),
      y: Math.max(-this.panLimit, Math.min(this.panLimit, ty)),
      z: Math.max(-this.panLimit, Math.min(this.panLimit, tz)),
    };
    this.updateView();
  }

  // 二轴旋转视角（绕锚点 = 屏幕中心）
  private applyOrbit(dx: number, dy: number): void {
    // 水平方向与拖拽方向一致（反向补偿）
    this.yaw -= dx * 0.008;
    // 上限 1.55（≈88.8°）：要容纳「顶/底」视图预设（1.52），同时避开 π/2 的欧拉角奇点
    this.pitch = Math.max(-1.55, Math.min(1.55, this.pitch - dy * 0.008));
    this.updateView();
  }

  // ---- 视图预设 / 近正交（Phase 3）----
  // 预设：把 yaw/pitch 插值到目标角（200ms，easeOutCubic，16ms/帧）。
  // 为什么自己插值而不是 animateTo：animateTo 只驱动 ArkUI 属性，而这里改的是相机状态，
  // 必须每帧显式调 updateView 把 R 推给 pivot/world 节点与 camera。
  private setViewPreset(name: string): void {
    const t: ViewAngles | null = viewPresetAngles(name);
    if (t === null) {
      return;
    }
    this.animateViewTo(t.yaw, t.pitch);
  }

  private animateViewTo(yawTo: number, pitchTo: number): void {
    if (this.presetTimer !== -1) {
      clearInterval(this.presetTimer);
      this.presetTimer = -1;
    }
    // 拖拽中不抢手势：直接落位（用户手指优先）
    if (this.dragging) {
      this.yaw = yawTo;
      this.pitch = pitchTo;
      this.updateView();
      return;
    }
    const yaw0: number = this.yaw;
    const pitch0: number = this.pitch;
    // yaw 走最短弧：差值归一到 (-π, π]，避免「从左转到前」绕一大圈
    let d: number = yawTo - yaw0;
    while (d > Math.PI) { d -= 2 * Math.PI; }
    while (d < -Math.PI) { d += 2 * Math.PI; }
    const pitchD: number = pitchTo - pitch0;
    const t0: number = Date.now();
    const dur: number = 200;
    this.presetTimer = setInterval((): void => {
      const raw: number = (Date.now() - t0) / dur;
      const t: number = raw >= 1 ? 1 : raw;
      const e: number = 1 - Math.pow(1 - t, 3);
      this.yaw = yaw0 + d * e;
      this.pitch = pitch0 + pitchD * e;
      this.updateView();
      if (t >= 1 && this.presetTimer !== -1) {
        clearInterval(this.presetTimer);
        this.presetTimer = -1;
      }
    }, 16);
  }

  // 近正交切换：只换「实际送进投影的 fov/眼距」，取景与目标点都不动。
  private toggleOrtho(): void {
    this.orthoLike = !this.orthoLike;
    this.updateView();
    promptAction.showToast({
      message: this.orthoLike
        ? '近正交视图（引擎无正交相机：相机推远 + 视场角压缩近似）'
        : '透视视图'
    });
  }

  private resetView(): void {
    this.yaw = 0.7;
    this.pitch = 0.5;
    // 有模型 → 按模型尺寸取景；无模型 → 按盘面尺寸取景（比例恒定，随盘面大小缩放）
    this.dist = modelState.hasModel() ? autoFitDistance(this.lastModelMaxDim) : this.plateDistance();
    this.recenterTarget();
    this.updateView();
  }

  // 盘面总览距离：与盘面边长成比例（256mm 盘对应 480）
  private plateDistance(): number {
    return Math.max(this.plateW, this.plateH) * 1.875;
  }

  // ---------------------------------------------------------------------------
  // 模型导入（STL/STP/STEP；C++ 仅解析，渲染在本页完成）
  // ---------------------------------------------------------------------------
  private importModel(): void {
    if (this.loading) {
      return;
    }
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.fileSuffixFilters = ['.stl', '.stp', '.step'];
      docPicker.select(opts).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        this.copyAndParse(uris[0]);
      }).catch(() => {
        promptAction.showToast({ message: '选择文件取消' });
      });
    } catch (e) {
      promptAction.showToast({ message: '打开选择器失败' });
    }
  }

  private copyAndParse(uri: string): void {
    try {
      const lower: string = uri.toLowerCase();
      let ext: string = '.stl';
      if (lower.endsWith('.step')) { ext = '.step'; }
      else if (lower.endsWith('.stp')) { ext = '.stp'; }
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        promptAction.showToast({ message: '获取上下文失败' });
        return;
      }
      const dst: string = `${ctx.filesDir}/preview_model${ext}`;
      const srcFile: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const dstFile: fs.File = fs.openSync(dst,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(srcFile.fd, dstFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
      // 记下当前模型文件路径：底部「切片」会把它交给 libslic3r 内核
      AppStorage.setOrCreate<string>('sliceModelPath', dst);
      // 本次导入的「初始姿态」基线：载入收尾后的第一次 publish 会把安放完成的实例记下来。
      // 用户之后一旦旋转/缩放/移动，切片前就会据此判定「要不要把变换烘进切片输入工程」。
      modelState.resetTransformBaseline();

      this.loading = true;
      this.modelInfoText = '解析中…';

      // 打开强制载入弹窗（分段进度条 + 整行日志）。弹窗先于解析出现，避免大模型解析期间
      // 界面「毫无反应」。
      const name: string = fileNameFromUri(uri);
      const sizeBytes: number = this.safeFileSize(dst);
      this.openLoadDialog(name, ext, sizeBytes);

      // 真机 grep 用：这次 NAPI 调用到底有没有跑起来，先留一条「调用前」的锚点日志
      hilog.info(0x0000, TAG, 'meshParseWithProgress 调用前 文件=%{public}s 字节=%{public}s',
        name, sizeBytes.toString());
      // 导入 [Mem]：导入前基线（用于和「解析后 / 引擎几何建完」对照峰值）
      AppLog.mem('Import', '导入前 ' + name + ' 文件=' + fmtNum(sizeBytes) + '字节');

      testNapi.meshParseWithProgress(dst,
        (pj: string) => { this.onLoadProgress(pj); },
        (result: testNapi.MeshParseResult) => { this.onLoadDone(result, ext, name); });
    } catch (e) {
      // 异常一律打 hilog，不吞
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(0x0000, TAG, 'copyAndParse failed: %{public}s', msg);
      this.failLoad('读取文件失败');
    }
  }

  // ---- 载入弹窗：驱动 + 兜底 -------------------------------------------------

  private safeFileSize(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'stat failed: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return 0;
    }
  }

  private openLoadDialog(name: string, ext: string, sizeBytes: number): void {
    this.loadSettled = false;
    this.loadStartedMs = Date.now();
    this.loadProgressCount = 0;
    // 重置进度处理状态（保留上一轮遗留的定时器无所谓：它会读到空队列后自行跳过）
    this.appliedStage = -1;
    this.pendingNumeric = null;
    this.pendingLogs = [];
    // 上一轮可能还有排定的 flush 定时器：清掉并复位节流基准，让本轮第一条日志立刻渲染
    if (this.flushTimer !== -1) { clearTimeout(this.flushTimer); this.flushTimer = -1; }
    this.lastFlushMs = 0;
    this.logReceived = 0;
    this.logRendered = 0;
    this.logDropped = 0;
    this.statsLogged = false;
    this.dlgModel.reset();
    this.dlgModel.fileName = name;
    this.dlgModel.fileMeta = '· ' + fmtSize(sizeBytes) + ' · ' + extLabel(ext);
    this.dlgVisible = true;
    // 第一行日志用真实文件名与真实文件大小
    this.dlgModel.pushLog('打开文件 · ' + name + ' · ' + fmtSize(sizeBytes), false);
    // 这里刻意不启动任何超时计时器：载入结束只等 onLoadDone / failLoad 两个回调。
    // 弹窗底部的「已用 / 预计剩余」由弹窗自身的 100ms 时钟刷新，只是显示，不参与判定。
  }

  private stageName(stage: number): string {
    if (stage >= 0 && stage < LOAD_STAGES.length) { return LOAD_STAGES[stage]; }
    return 'stage' + stage;
  }

  private onLoadProgress(progressJson: string): void {
    // hop11：回调进入（带 t=ms）—— 证明 TSFN 这一跳通到了 JS
    hilog.info(0x0000, TAG, 'hop11 onProgress 进入 t=%{public}s json=%{public}s',
      relMs(this.loadStartedMs), truncJson(progressJson));
    const p: ProgressMsg | null = parseProgressJson(progressJson);
    if (p === null) {
      hilog.warn(0x0000, TAG, 'bad progress json: %{public}s', progressJson);
      return;
    }
    this.loadProgressCount++;
    this.logReceived++;   // 收尾统计：收到多少条（每一条都必须能对上「已渲染 + 丢弃 + 残留」）
    const t: number = (Date.now() - this.loadStartedMs) / 1000;
    const stageName: string = this.stageName(p.stage);
    const g: number = globalPercent(p.stage, p.pct);
    // 首条进度必须打（这条能证明 TSFN 通不通）
    if (this.loadProgressCount === 1) {
      hilog.info(0x0000, TAG, '首个进度事件 t=%{public}s stage=%{public}s %{public}s',
        t.toFixed(1), stageName, p.msg);
    }
    // 每条进度都打（debug 级，避免默认日志刷屏；真机排查时开 debug 即可看全量，含末条）
    hilog.debug(0x0000, TAG,
      '进度 t=%{public}s stage=%{public}s 阶段内=%{public}s 全局=%{public}s %{public}s',
      t.toFixed(1), stageName, (Math.round(p.pct) + '%'), (Math.round(g) + '%'), p.msg);
    // 每 5 条在 info 级再打一条：不开 debug 也能筛出进度节奏
    if (this.loadProgressCount % 5 === 0) {
      hilog.info(0x0000, TAG,
        '进度#%{public}s t=%{public}s stage=%{public}s 阶段内=%{public}s 全局=%{public}s',
        this.loadProgressCount.toString(), t.toFixed(1), stageName,
        (Math.round(p.pct) + '%'), (Math.round(g) + '%'));
    }
    // 注意：这里【不再】因 loadSettled 直接丢弃 —— 法线阶段的进度消息常常在 onDone 之后
    // 才被主线程腾出来送达（onDone 一进来就干重活会把它们饿死在队列里）。数值由弹窗模型
    // 的单调保证不会回退；日志一条都不能丢，所以照收（loadSettled 后只收日志、不再动数值）。
    this.acceptProgress(p);
  }

  // 收下一条 C++ 进度：数值与日志走两条独立通道。
  //   · 数值状态：只保留最新一条（pendingNumeric），用 setTimeout(0) 合并应用到弹窗模型；
  //   · 日志行：每条普通进度都推入 pendingLogs 队列，一条不丢，按批 flush；
  //   · 关键进度（阶段切换 / 阶段内 100% / 终态）：不排队、立即渲染，但先把队列里更早的
  //     普通进度按序 flush 出去，保证日志顺序不倒退、关键行不会被埋在前面。
  private acceptProgress(p: ProgressMsg): void {
    if (this.loadSettled) {
      // onDone 已到：数值不再被迟到消息改动（防止百分比/阶段回退），但日志仍逐条入队。
      this.enqueueLog(p);
      this.scheduleFlush();
      return;
    }
    const isKey: boolean = (p.stage !== this.appliedStage) || p.pct >= 100 || p.stage < 0;
    if (isKey) {
      // 先把队列里更早的普通消息按序落盘（它们本就是更早发生的事件），再立即渲染关键项。
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

  // 入队一条普通进度的日志（队满丢最老，并计入丢弃数）
  private enqueueLog(p: ProgressMsg): void {
    if (p.msg.length === 0) { return; }
    if (this.pendingLogs.length >= LOG_QUEUE_MAX) {
      this.pendingLogs.shift();
      this.logDropped++;
    }
    this.pendingLogs.push(p);
  }

  // 排一次 flush：日志渲染按「固定节奏」节流 —— 最多每 LOG_FLUSH_INTERVAL_MS 合并渲染一次。
  // 为什么按固定节奏而不是「能排就排」（原来的 setTimeout(0) + 每轮 8 条）：进度约 25 条/秒，
  // 每条各自触发一次渲染 + 一次位移动画会把 UI 线程的动画 churn 拉满（实测界面已严重落后于
  // 真实进度）。固定节奏下，这段时间累积的多行一次性加入 —— 弹窗侧因此只做一次位移动画
  // （位移 = 累计行数 × 行高）。节流只影响「渲染时机」，不影响消息入队：队列一条不丢、上限不变。
  private scheduleFlush(): void {
    // 页面不可见（切页保活期间的隐藏态）：不排渲染定时器 —— 这是纯空跑。
    // 队列照常保留（日志一条不丢），恢复可见时由 resumeHiddenWork 重新 scheduleFlush。
    if (this.pausedByHidden) { return; }
    if (this.flushTimer !== -1) { return; }   // 这一批的渲染时机已排定，不重复排定时器
    const since: number = Date.now() - this.lastFlushMs;
    const delay: number = since >= LOG_FLUSH_INTERVAL_MS ? 0 : (LOG_FLUSH_INTERVAL_MS - since);
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.lastFlushMs = Date.now();
      const num: ProgressMsg | null = this.pendingNumeric;
      this.pendingNumeric = null;
      if (num !== null) { this.applyNumericNow(num.stage, num.pct); }
      this.flushLogQueue(this.pendingLogs.length);   // 累积的多行一次性加入（供一次位移动画）
      if (this.pendingLogs.length > 0) { this.scheduleFlush(); }
    }, delay);
  }

  // 从队首取最多 maxCount 条日志逐条渲染（每条都是独立的一行，不做任何合并）
  private flushLogQueue(maxCount: number): void {
    let n: number = Math.min(maxCount, this.pendingLogs.length);
    while (n > 0) {
      const p: ProgressMsg | undefined = this.pendingLogs.shift();
      if (p === undefined) { break; }
      this.writeProgressLog(p);
      n--;
    }
  }

  // 写一条「进度来源」的日志行（计入已渲染数；行内容不可变，由 pushLog 内部 push 新对象 + 整体重赋数组）
  private writeProgressLog(p: ProgressMsg): void {
    if (p.msg.length === 0) { return; }
    this.dlgModel.pushLog(p.msg, p.stage >= 3);
    this.logRendered++;
  }

  // 数值状态应用到弹窗模型（合并后的最新值）
  private applyNumericNow(stage: number, pct: number): void {
    this.dlgModel.applyNumeric(stage, pct);
    hilog.info(0x0000, TAG, 'UI 刷新 pct=%{public}s stage=%{public}s 阶段内=%{public}s',
      Math.round(this.dlgModel.percent).toString(), this.stageName(this.dlgModel.stage),
      Math.round(this.dlgModel.stagePct).toString());
  }

  // onDone 进入 attachModel 之前，把「已送达但还没渲染」的队列显式排空一次（不依赖定时器竞态）
  private flushPendingBeforeAttach(): void {
    const num: ProgressMsg | null = this.pendingNumeric;
    this.pendingNumeric = null;
    if (num !== null) { this.applyNumericNow(num.stage, num.pct); }
    this.flushLogQueue(this.pendingLogs.length);
  }

  // 收尾统计：一眼判断日志有没有再被合并掉 —— 正常情况下 收到 = 已渲染 + 丢弃 + 残留。
  private logLoadStats(): void {
    if (this.statsLogged) { return; }
    this.statsLogged = true;
    hilog.info(0x0000, TAG,
      '日志统计 收到=%{public}s 条 已渲染=%{public}s 条 丢弃=%{public}s 条 队列残留=%{public}s',
      this.logReceived.toString(), this.logRendered.toString(),
      this.logDropped.toString(), this.pendingLogs.length.toString());
  }

  private closeLoadDialog(): void {
    // 收尾统计（只打一次）：一眼判断日志有没有又被合并成一行
    this.logLoadStats();
    this.dlgVisible = false;
    if (this.loadCloseTimer !== -1) { clearTimeout(this.loadCloseTimer); this.loadCloseTimer = -1; }
  }

  // 失败终态：日志 + toast + 关窗，一条路径都不留悬挂状态
  private failLoad(msg: string): void {
    this.loadSettled = true;
    this.loading = false;
    this.modelInfoText = '加载失败';
    const m: string = msg !== '' ? msg : '载入失败';
    this.dlgModel.pushLog('失败 · ' + m, true);
    promptAction.showToast({ message: m });
    this.closeLoadDialog();
  }

  private async onLoadDone(result: testNapi.MeshParseResult, ext: string, name: string): Promise<void> {
    // hop11：onDone 回调进入（第一行就打，证明 C++ 的 napi_call_function(onDone) 真的到了 JS）
    hilog.info(0x0000, TAG, 'hop11 onDone 进入 t=%{public}sms', relMs(this.loadStartedMs));
    // 关键顺序：onDone 一进来【先让帧】，把此前已送达但还没渲染的进度日志（尤其法线阶段 stage 2、
    // 以及 stage 3 的收尾几条）全部 flush 出去，然后再进入 attachModel 的重活。
    // 若反过来（先干重活），长同步块会长时间独占主线程，队列里的进度被饿死 —— 用户看到的就是
    // 「60% 多直接跳到模型开启」。这是现象 2、3 的直接解法。
    await yieldToUi();
    await yieldToUi();
    // onDone 到了（载入的正常结束路径）。整个函数体都包在 try 里：onDone 里任何一步抛异常都必须
    // log + failLoad，绝不允许无声失败。
    try {
      this.loadSettled = true;
      // 让帧之后再把队列显式排空一次（不依赖定时器竞态），确保已送达的进度都画出来
      this.flushPendingBeforeAttach();
      // onDone 锚点日志：顶点数取 positions 的 float 数 / 3（每顶点 3 个 float），三角面取索引数 / 3
      const t: number = (Date.now() - this.loadStartedMs) / 1000;
      const verts: number = Math.floor(result.positions.byteLength / 12);
      const tris: number = Math.floor(result.indices.byteLength / 12);
      hilog.info(0x0000, TAG, 'onDone t=%{public}s 顶点=%{public}s 三角面=%{public}s',
        t.toFixed(1), verts.toString(), tris.toString());
      const info: ParseInfo = JSON.parse(result.info) as ParseInfo;
      if (!info.ok) {
        this.failLoad(info.error !== '' ? info.error : '解析失败');
        return;
      }
      // 单位识别：模型按米建模（最大尺寸 < 1mm）时 C++ 已自动 ×1000 并把切片用的 STL 重写成毫米。
      // 这里如实告诉用户，避免「尺寸怎么突然变大了」的疑惑。
      if (info.unitScale !== undefined && info.unitScale > 1) {
        hilog.info(0x0000, TAG, '单位识别 模型单位=米 → 已 ×%{public}s 换算为毫米',
          info.unitScale.toString());
        this.dlgModel.pushLog('单位识别 · 模型按米建模，已自动 ×' + info.unitScale.toString() +
          ' 换算为毫米（切片文件同步重写）', false);
        promptAction.showToast({ message: '模型单位是米，已自动换算为毫米' });
      }
      // 日志：焊接前后的顶点数、折痕新增顶点 —— 全部是 C++ 返回结构里的真实计数
      if (info.weldInVerts > 0 && info.uniqueVerts > 0) {
        const drop: number = (1 - info.uniqueVerts / info.weldInVerts) * 100;
        this.dlgModel.pushLog('顶点 ' + fmtNum(info.weldInVerts) + ' → ' + fmtNum(info.uniqueVerts) +
          '（↓ ' + drop.toFixed(1) + '%）· 折痕新增 +' + fmtNum(info.creaseSplit), false);
      }
      // 需求 4：悬空（朝下）面启发式统计在 attachModel 里随对象一起落库并重算告警
      //（结论按对象存 → 之后切页回来 / 改参数都能重算，不只在导入瞬间判一次）。
      // 交给异步流程：分段构建渲染几何并主动让帧，界面一直推进到挂进场景。
      // attachModel 内部已兜住所有异常（catch → failLoad），这里 await 不会产生未处理的拒绝。
      await this.attachModel(result, ext, name, info);
    } catch (e) {
      // hop13：onLoadDone 抛出的异常必须「完整」打出来（消息 + 调用栈），不能只留一句笼统失败
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      const stk: string = (e instanceof Error && e.stack !== undefined) ? e.stack : '';
      hilog.error(0x0000, TAG, 'hop13 onLoadDone 抛出异常 msg=%{public}s stack=%{public}s', msg, stk);
      this.failLoad('数据解析异常');
    }
  }

  // 逐跳插桩（hop12）：attachModel 每段的「开始 / 结束」，带段号、整体已耗时与段内耗时。
  // 有了它，真机日志能精确看出「卡在哪一段的第几次 yield」。
  private logAttach(seg: number, phase: string, segT0: number): void {
    hilog.info(0x0000, TAG, 'hop12 attach 段%{public}s %{public}s t=%{public}s 段内=%{public}sms',
      seg.toString(), phase, relMs(this.loadStartedMs), (Date.now() - segT0).toString());
  }

  // 扁平缓冲（ArrayBuffer）→ 渲染几何（大网格用扁平 TypedArray 常驻）+ 挂进场景。
  // 每段之间 await yieldToUi()：既让进度真的绘制出来，也避免长时间独占 JS/UI 线程。
  private async attachModel(result: testNapi.MeshParseResult, ext: string, name: string,
                            info: ParseInfo): Promise<void> {
    try {
      // 段 1：建三个零复制视图 + 取出计数
      const s1: number = Date.now();
      this.logAttach(1, '视图构建 开始', s1);
      // 这三行都是「视图」而不是拷贝（TypedArray 直接从 C++ 的 ArrayBuffer 建，零复制）
      const posView: Float32Array = new Float32Array(result.positions);
      const nrmView: Float32Array = new Float32Array(result.normals);
      const idxView: Uint32Array = new Uint32Array(result.indices);
      const vCount: number = Math.floor(posView.length / 3);
      const triCount: number = Math.floor(idxView.length / 3);
      this.logAttach(1, '视图构建 结束', s1);
      // 导入 [Mem]：解析完成（C++ 已把几何以 ArrayBuffer 交回，此刻还没有任何 JS 对象数组）
      AppLog.mem('Import', '解析后 顶点=' + fmtNum(vCount) + ' 三角面=' + fmtNum(triCount));

      this.applyNumericNow(3, 75);
      this.dlgModel.pushLog('构建渲染几何 · ' + fmtNum(vCount) + ' 顶点 / ' +
        fmtNum(triCount) + ' 三角面', true);
      await yieldToUi();

      // 段 2：顶点 Z-up → Y-up（原地改写 adopt 进来的扁平 TypedArray）。
      // 旧实现在这里逐顶点建 Vec3[]（105 万 + 105 万个对象、508 万个 number），瞬时分配上百 MB
      // 并触发大量 GC，把主线程连续占住（叠加后面的缩略图/引擎上传 >6s）→ 系统按 THREAD_BLOCK_6S
      // 直接杀进程（真机闪退根因）。现在几何常驻形态就是扁平 TypedArray：内存约 1/3、零对象分配。
      const s2: number = Date.now();
      this.logAttach(2, '顶点缓冲 开始', s2);
      const g: MeshGeometry = new MeshGeometry();
      zUpToYUpInPlace(posView);
      g.pos = posView;
      this.logAttach(2, '顶点缓冲 结束', s2);

      // 段 3：索引直接采用 C++ 返回的 Uint32 视图（零复制、零转换、零装箱 number[]）
      const s3: number = Date.now();
      this.logAttach(3, '索引缓冲 开始', s3);
      g.idx = idxView;
      this.logAttach(3, '索引缓冲 结束', s3);

      // 段 4：法线 Z-up → Y-up（原地）。直接用 C++ 焊接时算好的平滑法线（那里已按有符号体积修过朝向）。
      const s4: number = Date.now();
      this.logAttach(4, '法线缓冲 开始', s4);
      if (nrmView.length === vCount * 3) {
        zUpToYUpInPlace(nrmView);
        g.nrm = nrmView;
      } else {
        // 兜底：没有法线数据时才按几何重算（typed 路径，全程扁平缓冲）
        repairNormals(g);
      }
      this.applyNumericNow(3, 100);
      this.dlgModel.pushLog('建立索引缓冲 · ' + fmtNum(triCount) + ' 三角面', true);
      await yieldToUi();
      this.logAttach(4, '法线缓冲 结束', s4);

      const maxDim: number = Math.max(info.sizeX, Math.max(info.sizeY, info.sizeZ));
      const fmt: string = ext === '.stl' ? 'STL' : 'STEP';

      // 段 5：入场景（阶段 4）。体积计算走扁平 TypedArray（零对象分配、更快）；缩略图改为
      // 异步后台光栅化（ensureThumbnail 立即返回），不再挂在这条同步链上 —— 旧实现这里含
      // 「105 万顶点 + 169 万面扫描线」约 3.9s 的同步块，是导入闪退的另一半根因。
      const s5: number = Date.now();
      this.logAttach(5, '入场景 开始', s5);
      const n5: number = 4;
      this.applyNumericNow(4, 20);
      this.dlgModel.pushLog('加入场景 · 1 / ' + n5 + ' · 写入模型状态 · ' +
        fmtNum(triCount) + ' 三角面', true);
      await yieldToUi();
      // 多盘工程里新导入的模型要落到「当前盘」：否则它会停在「未分盘」(plate=0)，
      // 而未分盘对象在每块盘上都可见 → 切盘看到同一批对象，像是多盘不生效。
      let plateNo: number = 0;
      let plateName: string = '';
      let plateBed: string = '';
      if (this.activePlate > 0) {
        const rec = modelState.ensurePlate(this.activePlate);
        plateNo = this.activePlate;
        plateName = rec.name;
        plateBed = rec.bed;
      }
      const id: number = modelState.add(g, maxDim, { x: info.sizeX, y: info.sizeY, z: info.sizeZ },
        name, fmt, info.triangles, plateNo, plateName);

      this.applyNumericNow(4, 40);
      this.dlgModel.pushLog('加入场景 · 2 / ' + n5 + ' · 校验对象状态', true);
      await yieldToUi();
      const inst: ModelInstance | undefined = modelState.get(id);
      if (inst === undefined) {
        hilog.error(0x0000, TAG, 'model instance missing right after add');
        this.failLoad('模型状态异常');
        return;
      }
      // 需求 4：把这次导入的悬空（朝下）面启发式统计落到该对象上（真实数字，来自 C++），
      // 再据此重算告警 —— 结论按对象存，之后切页/改参数都能复用（不只在导入瞬间判一次）。
      inst.plateBed = plateBed;
      inst.overhangNeeded = info.needsSupport;
      inst.overhangRatioPct = info.overhangRatioPct;
      inst.overhangAngleDeg = info.overhangAngleDeg;
      inst.overhangAreaPctThr = info.overhangAreaPctThreshold;
      this.refreshSupportWarn('载入完成', '导入');

      this.applyNumericNow(4, 55);
      this.dlgModel.pushLog('加入场景 · 3 / ' + n5 + ' · 生成对象缩略图（后台异步 · ' + fmtNum(vCount) +
        ' 顶点）', true);
      await yieldToUi();
      // 后台异步光栅化，立即返回（完成后经 AppStorage 'thumbSeq' 通知对象列表刷新）
      ensureThumbnail(id, inst.geometry);

      this.applyNumericNow(4, 75);
      this.dlgModel.pushLog('加入场景 · 4 / ' + n5 + ' · 贴合 · 包围盒 ' + info.sizeX.toFixed(1) +
        ' × ' + info.sizeY.toFixed(1) + ' × ' + info.sizeZ.toFixed(1) + ' mm · 贴板居中', true);
      await yieldToUi();
      this.logAttach(5, '入场景 结束', s5);

      // 收尾保险：只保「挂模型进场景」这一步（真正可能不回头的异步就在下面），
      // 不再从 onDone 一进来就计时 —— 否则几何转换期间它会把弹窗提前关掉。
      if (this.loadCloseTimer !== -1) { clearTimeout(this.loadCloseTimer); }
      this.loadCloseTimer = setTimeout(() => {
        this.loadCloseTimer = -1;
        if (this.dlgVisible) {
          hilog.warn(0x0000, TAG, 'settle timer: scene attach did not finish, force close');
          this.closeLoadDialog();
        }
      }, 2500);

      // 段 6：appendInstance（真正可能不回头的异步，2.4s 主要在 createMesh 这个长同步 NAPI）。
      // 通过 onStep 回调在内部步骤之间让帧 + 上报「应用实例 · i / 3」，队列趁让帧刷新。
      const s6: number = Date.now();
      this.logAttach(6, 'appendInstance 开始', s6);
      this.appendInstance(inst, (step: number, total: number, label: string) => {
        this.applyNumericNow(4, 75 + Math.floor(20 * step / total));
        this.dlgModel.pushLog('应用实例 · ' + step + ' / ' + total + ' · ' + label, true);
      }).then(async () => {
        this.logAttach(6, 'appendInstance 结束', s6);
        // 导入 [Mem]：引擎几何建完（createMesh 后物化数组已释放，只剩常驻 TypedArray）
        AppLog.mem('Import', '引擎几何建完');
        this.pendingIds.delete(id);
        this.updateFit();
        this.resetView();
        this.refreshGizmo();
        const used: number = (Date.now() - this.loadStartedMs) / 1000;
        this.applyNumericNow(4, 100);
        this.dlgModel.pushLog('完成 · 用时 ' + used.toFixed(1) + 's', true);
        this.loading = false;
        this.modelInfoText = '已载入 ' + name;
        // 关窗前至少让出 2 帧：真实进度可能一直领先于界面（主线程长时间抢不到时间片时），
        // 这里必须把「100% + 完成 · 用时」这最后一屏真正画出来，再走收尾延迟关窗 ——
        // 否则用户看到的就是「还没到 100% 弹窗就没了，中间那段日志根本没机会显示」。
        await yieldToUi();
        await yieldToUi();
        // 模型已经在场景里了，再关弹窗（避免闪一下空白）。收尾延迟保持不变（不缩短）。
        if (this.loadCloseTimer !== -1) { clearTimeout(this.loadCloseTimer); }
        this.loadCloseTimer = setTimeout(() => {
          this.loadCloseTimer = -1;
          this.closeLoadDialog();
        }, 260);
      }).catch((e: Error) => {
        hilog.error(0x0000, TAG, 'appendInstance failed: %{public}s', e.message);
        this.failLoad('模型入场景失败');
      });
      this.syncStorage();
      this.syncSelection();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      const stk: string = (e instanceof Error && e.stack !== undefined) ? e.stack : '';
      hilog.error(0x0000, TAG, 'hop13 attachModel 抛出异常 msg=%{public}s stack=%{public}s', msg, stk);
      this.failLoad('模型装载异常');
    }
  }

  // ===========================================================================
  // 需求 2：顶部工具抽屉（@Builder）
  // ---------------------------------------------------------------------------
  // 收纳内容：模型信息摘要 + 导入模型 + 重置视角 +（选中对象时）缩放/尺寸、旋转、移动 数值输入，
  //           以及 旋转 / 缩放 / 移动 / 贴底面 / 选面朝下 工具按钮 + 手柄增量输入。
  // 行为：默认【展开】（启动即展开，见 topDrawerOpen）→ 左上角有「拉手」胶囊 + 浮层面板；
  //       会话内可点触发条收起。展开/收起都带动画：面板「常驻挂载」，
  //       由 .opacity(0↔1) + .translate.y(-8↔0) 表达开关（animateTo 驱动，见 toggleTopDrawer）。
  //       面板浮在 3D 视口之上（父级 Stack 的浮层子节点、不参与布局）→ 视口高度始终 = 内容区高度，
  //       手机预览窗口不再被挤小；收起态 opacity 0 + hitTestBehavior(None)，既不显示也不吃手势。
  // 触屏：抽屉内按钮统一抬到 height 34（点按目标够大）。
  // ===========================================================================
  @Builder
  topToolDrawer() {
    Column() {
      // 触发条（左上角常驻）：三横线图标 + 文字；展开态仅把图标/文字点亮为品牌绿（不再整块绿填充）。
      // 这里只放「按钮 + Blank」：模型信息摘要不再塞进同一行，而是单独另起一行（见下），
      // 两者不在同一水平线上，从布局上就不可能互相重叠（需求 5）。
      Row({ space: 8 }) {
        Row({ space: 8 }) {
          // 三横线图标：不引图片资源，用 3 段短条画出来，跟主题色一致
          Column({ space: 3 }) {
            Column().width(14).height(2).borderRadius(1)
              .backgroundColor(this.topDrawerOpen ? Theme.accent : Theme.textPrimary)
            Column().width(14).height(2).borderRadius(1)
              .backgroundColor(this.topDrawerOpen ? Theme.accent : Theme.textPrimary)
            Column().width(14).height(2).borderRadius(1)
              .backgroundColor(this.topDrawerOpen ? Theme.accent : Theme.textPrimary)
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          Text(this.topDrawerOpen ? '收起' : '工具')
            .fontSize(12)
            .fontColor(this.topDrawerOpen ? Theme.accentSoft : Theme.textPrimary)
          // 收起态下若已选中对象，点一个品牌绿小圆点，提示「这里已有可用的编辑工具」
          if (this.selectedModelId !== -1 && !this.topDrawerOpen) {
            Column()
              .width(6).height(6).borderRadius(3)
              .backgroundColor(Theme.accentSoft)
          }
        }
        // 触屏点按目标：高度保持 34vp（≥34，手指可点），图标/文字清晰
        .height(34)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
        // 深色玻璃 + 描边：与抽屉内其它按钮统一，展开态不再整块品牌绿填充（用户反馈）；
        // 品牌绿只保留在 ≡ 图标与文字上（见上面的颜色），示意「已激活」。
        .backgroundColor(Theme.surfaceElevated)
        .border({ width: 1, color: Theme.border })
        .onClick(() => { this.toggleTopDrawer(); })

        Blank()
      }
      .width('100%')
      // 左上角留 12vp 边距（水平贴左、垂直贴顶）；能否贴左上角由父 Stack 的 alignContent 决定（见 build()）
      .padding({ left: 12, right: 12, top: 12 })

      // 模型信息摘要：单独一行、放在触发按钮「正下方」，与按钮错开水平线（需求 5）。
      // 只在收起态显示；限宽 + 省略号，贴左上角；常规取景下左上角为空，不压模型。
      if (!this.topDrawerOpen) {
        Row() {
          Text(this.modelInfoText)
            .fontSize(11)
            .fontColor(Theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 320 })
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor('#B20E0E12')
            .border({ width: 1, color: Theme.border })
          Blank()
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })
      }

      // 抽屉面板：浮在 3D 视口之上；不改变视口高度。
      // 外层套 Scroll：面板高度 = min(内容自然高, 视口可用高上限) → 从左上角向右下延展，绝不超出视口、
      // 不压底部工具栏；内容超出上限时可滚动查看（所有控件都能滚到）。
      // 常驻挂载（去掉原来的 `if (this.topDrawerOpen)` 条件渲染）——
      // 条件渲染会在收起瞬间销毁节点，无法播放「关闭动画」；常驻后由动画属性表达开关，
      // 打开与关闭两个方向都能过渡（见下方 opacity / translate）。
      // 收起态：opacity 0（视觉完全不可见）+ translate.y -8（向上滑出）+ hitTestBehavior(None)。
      // 它是本 Column 的最后一个孩子，且整体作为 Stack 浮层 → 常驻挂载也不会挤压上方触发条/摘要的布局。
      // 外层容器只保留「右 / 上各 12vp」内边距：左 0 让面板左缘与 3D 视口左缘【对齐】（用户要求贴左边缘），
      // 四角圆角不变（贴边那两角仍是圆角）；右 12 使面板宽 = 视口宽 − 12。
      Column() {
        Scroll() {
        Column({ space: 8 }) {
          // 顶部操作：导入模型 / 重置视角
          Row({ space: 8 }) {
            Button(this.loading ? '加载中…' : '导入模型')
              .fontSize(12).height(34).padding({ left: 14, right: 14 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.importModel(); })
            Button('重置视角')
              .fontSize(12).height(34).padding({ left: 14, right: 14 })
              .fontColor(Theme.accentSoft)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.resetView(); })
            // 整理摆放：把当前盘的对象按外框行列铺开（一键摆整齐；可撤销）
            Button('整理摆放')
              .fontSize(12).height(34).padding({ left: 14, right: 14 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.arrangeActivePlate(); })
            Blank()
          }.width('100%')

          // 网格编辑（第二层）：拆分 / 自动定向 / 铺满板。都作用在当前选中对象上，整步可撤销。
          Row({ space: 8 }) {
            Button('拆分对象')
              .fontSize(12).height(34).padding({ left: 12, right: 12 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.splitSelected(); })
            Button('合并对象')
              .fontSize(12).height(34).padding({ left: 12, right: 12 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.mergeSelected(); })
            Button('自动定向')
              .fontSize(12).height(34).padding({ left: 12, right: 12 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.autoOrientSelected(); })
            Button('铺满打印板')
              .fontSize(12).height(34).padding({ left: 12, right: 12 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.fillBed(); })
            Blank()
          }.width('100%')

          // 布尔：选中两个对象（A 为基准）。差集 = A − B，并集 = 焊成一个实体。
          Row({ space: 8 }) {
            Button(this.booleanBusy ? '布尔运算中…' : '布尔差集（A−B）')
              .fontSize(12).height(34).padding({ left: 12, right: 12 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .enabled(!this.booleanBusy)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.applyBoolean('difference'); })
            Button('布尔并集')
              .fontSize(12).height(34).padding({ left: 12, right: 12 })
              .fontColor(Theme.textPrimary)
              .backgroundColor(Theme.surfaceElevated)
              .borderRadius(8).stateEffect(true)
              .enabled(!this.booleanBusy)
              .systemMaterial(this.cardMaterial)
              .onClick(() => { this.applyBoolean('union'); })
            Blank()
          }.width('100%')

          if (this.selectedModelId === -1) {
            Text('未选中对象：在 3D 视图中点选对象后，可在此旋转 / 缩放 / 移动')
              .fontSize(11)
              .fontColor(Theme.textSecondary)
              .width('100%')
          } else {
            // 缩放：锁 = 等比（改任一尺寸三轴同步）；解锁 = 每轴独立
            Row({ space: 6 }) {
              Button(this.scaleLocked ? '锁' : '开')
                .fontSize(11).height(32).width(38).padding(0)
                .fontColor(this.scaleLocked ? Theme.accentSoft : Theme.warn)
                .backgroundColor(this.scaleLocked ? '#1F2B27' : Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.toggleScaleLock(); })
              TextInput({ text: this.inScale })
                .type(InputType.Normal).fontSize(11).height(32).width(48)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inScale = v; })
                .onSubmit(() => { this.applyScalePct(); })
                .onBlur(() => { this.applyScalePct(); })
              Text('%').fontSize(11).fontColor(Theme.textSecondary).width(14)
              Text('尺寸').fontSize(11).fontColor(Theme.textSecondary).width(30)
              TextInput({ text: this.inDimX })
                .type(InputType.Normal).fontSize(11).height(32).width(52)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inDimX = v; })
                .onSubmit(() => { this.applyDim('x'); })
                .onBlur(() => { this.applyDim('x'); })
              TextInput({ text: this.inDimY })
                .type(InputType.Normal).fontSize(11).height(32).width(52)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inDimY = v; })
                .onSubmit(() => { this.applyDim('y'); })
                .onBlur(() => { this.applyDim('y'); })
              TextInput({ text: this.inDimZ })
                .type(InputType.Normal).fontSize(11).height(32).width(52)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inDimZ = v; })
                .onSubmit(() => { this.applyDim('z'); })
                .onBlur(() => { this.applyDim('z'); })
              Text('mm').fontSize(11).fontColor(Theme.textSecondary).layoutWeight(1)
            }.width('100%')

            // 旋转 X / Y / Z（度）
            Row({ space: 6 }) {
              Text('旋转').fontSize(11).fontColor(Theme.textSecondary).width(30)
              Text('X').fontSize(11).fontColor('#F2433D').width(12)
              TextInput({ text: this.inRotX })
                .type(InputType.Normal).fontSize(11).height(32).width(50)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inRotX = v; })
                .onSubmit(() => { this.applyRotInput('x'); })
                .onBlur(() => { this.applyRotInput('x'); })
              Text('Y').fontSize(11).fontColor('#5CD44D').width(12)
              TextInput({ text: this.inRotY })
                .type(InputType.Normal).fontSize(11).height(32).width(50)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inRotY = v; })
                .onSubmit(() => { this.applyRotInput('y'); })
                .onBlur(() => { this.applyRotInput('y'); })
              Text('Z').fontSize(11).fontColor('#4D8CFA').width(12)
              TextInput({ text: this.inRotZ })
                .type(InputType.Normal).fontSize(11).height(32).width(50)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inRotZ = v; })
                .onSubmit(() => { this.applyRotInput('z'); })
                .onBlur(() => { this.applyRotInput('z'); })
              Text('°').fontSize(11).fontColor(Theme.textSecondary).layoutWeight(1)
            }.width('100%')

            // 移动 X / Y / Z（mm）；底板左下角 = (0,0)，X/Z 为盘面坐标，Y 为高度
            Row({ space: 6 }) {
              Text('移动').fontSize(11).fontColor(Theme.textSecondary).width(30)
              Text('X').fontSize(11).fontColor('#F2433D').width(12)
              TextInput({ text: this.inPosX })
                .type(InputType.Normal).fontSize(11).height(32).width(56)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inPosX = v; })
                .onSubmit(() => { this.applyPosInput('x'); })
                .onBlur(() => { this.applyPosInput('x'); })
              Text('Y').fontSize(11).fontColor('#5CD44D').width(12)
              TextInput({ text: this.inPosY })
                .type(InputType.Normal).fontSize(11).height(32).width(50)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inPosY = v; })
                .onSubmit(() => { this.applyPosInput('y'); })
                .onBlur(() => { this.applyPosInput('y'); })
              Text('Z').fontSize(11).fontColor('#4D8CFA').width(12)
              TextInput({ text: this.inPosZ })
                .type(InputType.Normal).fontSize(11).height(32).width(56)
                .backgroundColor(Theme.surfaceElevated)
                .onChange((v: string) => { this.inPosZ = v; })
                .onSubmit(() => { this.applyPosInput('z'); })
                .onBlur(() => { this.applyPosInput('z'); })
              Text('mm（X/Y 盘面 · Z 高度）').fontSize(11).fontColor(Theme.textSecondary).layoutWeight(1)
            }.width('100%')

            // 工具按钮：点击后显示对应的三维操作手柄
            Row({ space: 8 }) {
              Button('旋转')
                .fontSize(12).height(34).padding({ left: 12, right: 12 })
                .fontColor(this.tool === 1 ? Theme.accentSoft : Theme.textPrimary)
                .backgroundColor(this.tool === 1 ? '#1F2B27' : Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.setTool(1); })
              Button('缩放')
                .fontSize(12).height(34).padding({ left: 12, right: 12 })
                .fontColor(this.tool === 2 ? Theme.accentSoft : Theme.textPrimary)
                .backgroundColor(this.tool === 2 ? '#1F2B27' : Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.setTool(2); })
              Button('移动')
                .fontSize(12).height(34).padding({ left: 12, right: 12 })
                .fontColor(this.tool === 3 ? Theme.accentSoft : Theme.textPrimary)
                .backgroundColor(this.tool === 3 ? '#1F2B27' : Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.setTool(3); })
              // 框选（工具 4）：开启后在视口里拖矩形多选对象；对象列表里长按某行也可加选
              Button('框选')
                .fontSize(12).height(34).padding({ left: 12, right: 12 })
                .fontColor(this.tool === 4 ? Theme.accentSoft : Theme.textPrimary)
                .backgroundColor(this.tool === 4 ? '#1F2B27' : Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.setTool(4); })
              // 打印板：这是「0 块盘」时唯一的入口（盘条本身要 ≥1 块盘才出现），
              // 已有盘之后的增/删/改名/复制都在盘条表头的「⋯」菜单里。
              Button('新增打印板')
                .fontSize(12).height(34).padding({ left: 10, right: 10 })
                .fontColor(Theme.textPrimary)
                .backgroundColor(Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.addEmptyPlate(); })
              Button('贴底面')
                .fontSize(12).height(34).padding({ left: 10, right: 10 })
                .fontColor(Theme.textPrimary)
                .backgroundColor(Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.onDropToBed(); this.syncSelection(); this.refreshGizmo(); })
              Button(this.pickFaceMode ? '取消选面' : '选面朝下')
                .fontSize(12).height(34).padding({ left: 10, right: 10 })
                .fontColor(this.pickFaceMode ? Theme.accentSoft : Theme.textPrimary)
                .backgroundColor(this.pickFaceMode ? '#1F2B27' : Theme.surfaceElevated)
                .borderRadius(6).stateEffect(true)
                .onClick(() => { this.togglePickFace(); })
            }.width('100%')

            // 手柄增量输入（点中某个轴后出现）：正数加、负数减
            if (this.deltaAxis !== '') {
              Row({ space: 6 }) {
                Text(`轴 ${this.deltaAxis.toUpperCase()} 增量`).fontSize(12).fontColor(Theme.accentSoft).width(96)
                TextInput({ text: this.deltaText, placeholder: '正数加 / 负数减' })
                  .type(InputType.Normal).fontSize(12).height(34).layoutWeight(1)
                  .backgroundColor(Theme.surfaceElevated)
                  .onChange((v: string) => { this.deltaText = v; })
                  .onSubmit(() => { this.applyGizmoDelta(); })
                Button('确定')
                  .fontSize(12).height(34).padding({ left: 12, right: 12 })
                  // 与抽屉内其它按钮统一：深色玻璃 + 品牌绿文字，去掉整块绿填充
                  .fontColor(Theme.accentSoft).backgroundColor(Theme.surfaceElevated)
                  .border({ width: 1, color: Theme.border }).borderRadius(6)
                  .onClick(() => { this.applyGizmoDelta(); })
                Button('取消')
                  .fontSize(12).height(34).padding({ left: 12, right: 12 })
                  .fontColor(Theme.textSecondary).backgroundColor(Theme.surfaceElevated).borderRadius(6)
                  .onClick(() => { this.deltaAxis = ''; this.deltaText = ''; })
              }.width('100%')
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        // 采集内容自然高：Scroll 以主轴无界测量子节点，所以这里拿到的是「未被上限裁剪的真实内容高」。
        // 内容增减（导入 / 选中对象 / 手柄增量行出现 / 屏幕旋转）→ 立刻按同一套 animateTo 平滑调整面板高。
        .onAreaChange((_o: Area, n: Area) => {
          const nh: number = Number(n.height);
          if (nh > 0 && Math.abs(nh - this.contentNaturalH) >= 0.5) {
            this.contentNaturalH = nh;
            this.syncPanelH();
          }
        })
        }
        .width('100%')
        .align(Alignment.TopStart)
        // 面板高度 = min(内容自然高, 视口可用高上限)，由 panelH(@State) 经 animateTo(200/EaseOut) 平滑驱动。
        // 上限 = 视口高 − 88（顶部偏移 58 + 底部留白 30），取【当前真实视口高】实时重算 →
        //   导入 / 切页 / 旋转屏都正确，且面板下缘永不压到底部 SliceBar。
        // 内容超过上限时 Scroll 自带滚动 → 所有控件都能滚到、能点到（不会出现「被永久遮住」）。
        .height(this.panelH)
        // 宽度仍封顶 600vp（超宽屏不铺满）
        .constraintSize({ maxWidth: 600 })
        .scrollBar(BarState.Off)
        // 深色玻璃底 + 四角统一圆角 + 四面描边：留出四边边距后四角都圆得出来（原来只圆了下面两角）。
        .backgroundColor('#E60E1218')
        .borderRadius(12)
        .border({ width: 1, color: Theme.border })
        }
        // 面板容器边距：左 0（面板左缘与 3D 视口左缘对齐，四角圆角照旧保留）+ 右 12 + 上 12。
        // 宽度 = 容器宽（= 视口宽）扣掉右侧 12 → 面板宽 = 视口宽 − 12（左侧不再扣减）。
        // 顶部保留 12：避免与状态栏 / 触发条打架。
        .width('100%')
        // 【PC 上「抽屉仍居中」的真因】本容器是 Column，Column 的 alignItems 默认 = HorizontalAlign.Center；
        //   面板 Scroll 的宽度 = min(容器宽, constraintSize.maxWidth 600)。窄屏（手机横屏）视口窄，
        //   600 上限不会生效 → 面板≈铺满容器，居中与贴左看不出差别；宽屏（2in1）视口 > 600 时，
        //   600 上限生效、面板比容器窄，默认 Center 就把它【水平居中】了 —— 这正是 PC 上的残留居中。
        //   显式 Start：面板左缘恒与容器内容左缘对齐（左 padding 0 → 即 3D 视口左缘），宽 / 窄屏一致贴左上角。
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 0, right: 12, top: 12 })
        // 展开/收起动画属性：只驱动 opacity + 位移（克制、无阴影；不发散成弹跳/旋转）。
        // 与 toggleTopDrawer 里的 animateTo 配合 → 打开(opacity 0→1, y -8→0) 与关闭(反向) 都有过渡。
        .opacity(this.topDrawerOpen ? 1 : 0)
        .translate({ y: this.topDrawerOpen ? 0 : -8 })
        // 展开态：面板自身可点、空白处仍透传给身后 3D（Transparent）；
        // 收起态：不接收任何事件（None）→ 绝不吃 3D 视口手势（旋转/缩放/平移照常）。
        .hitTestBehavior(this.topDrawerOpen ? HitTestMode.Transparent : HitTestMode.None)
    }
    .width('100%')
    // 抽屉根节点高度 = 内容高度（wrap，不含空白），下方空白不覆盖 → 3D 手势照常。
    .align(Alignment.TopStart)
    // 自身与子节点正常响应，但不阻塞身后的 3D 视口手势（与盘列表同一套做法）
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    // 最外层 Stack：3D 视口之上叠加「大模型载入」强制弹窗。
    // alignContent 必须显式设为 TopStart：Stack 默认 alignContent = Center，
    // 而抽屉根节点高度是「内容高度」（wrap 包裹），一旦沿用默认 Center 就会被垂直摆到视口正中
    // —— 用户截图里「≡ 工具」压住模型、停在视口垂直中点，真因就是这个默认值。
    Stack({ alignContent: Alignment.TopStart }) {
    // 3D 视口铺满整个内容区：顶部工具（导入/重置视角 + 数值编辑 + 旋转/缩放/移动 工具）
    // 已收进「浮层抽屉」（见本函数末尾的 this.topToolDrawer()）。抽屉不参与布局、浮在视口之上，
    // 因此展开/收起都不改变这里的视口高度（需求 2 的核心目的：手机预览窗口不再被顶部那排挤小）。
    Column() {

      // 3D 视口（Component3D + ArkGraphics3D）
      Stack({ alignContent: Alignment.Center }) {
        if (this.sceneReady && this.scene !== null) {
          Component3D({ scene: this.scene })
            .width('100%')
            .height('100%')
        } else {
          Text(this.sceneReady ? '' : '初始化 3D 引擎…')
            .fontSize(13)
            .fontColor(Theme.textSecondary)
        }

        // 右侧：多盘文件的盘列表（点击切换当前查看/编辑的盘）
        // 切片路径态（hidePlateList）交给 Index 渲染在覆盖层之上，本页这一份隐藏，避免两份叠加。
        // ≥1 块盘就显示：盘条表头带「⋯」盘管理菜单（新增/重命名/复制/删除），
        // 只在 ≥2 时才出现的话，刚新增出第一块盘的用户反而看不到后续入口。
        if (this.plates.length >= 1 && !this.hidePlateList) {
          Column() {
            PlateList()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.End)
          .padding({ right: 14 })
          .hitTestBehavior(HitTestMode.Transparent)
        }

        // 注：单喷嘴专属区的「仅左/右侧可打印区域」文字已改为【贴在打印板上的贴图面片】
        // （见 buildNozzleZones / ensureZoneLabelMaterial），不再使用此处的视口浮层文字。


        // 越界警示：视口边缘红光脉冲（类似高德超速提醒）
        if (this.outOfBounds) {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius(10)
            .border({ width: 2, color: Theme.danger })
            .backgroundColor('#16FF3D2E')
            .radialGradient({
              center: ['50%', '50%'],
              radius: '78%',
              colors: [['#00FF3D2E', 0.45], ['#4DFF3D2E', 1.0]]
            })
            .opacity(this.warnAlpha)
            .hitTestBehavior(HitTestMode.None)
        }

        // 越界提示条（顶部居中，含超出量）
        if (this.outOfBounds) {
          Column() {
            Row({ space: 7 }) {
              Stack() {
                Text('!')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
              }
              .width(16)
              .height(16)
              .borderRadius(8)
              .backgroundColor(Theme.danger)
              Text(this.warnText)
                .fontSize(11)
                .fontColor('#FFD6D2')
            }
            .padding({ left: 8, right: 12, top: 5, bottom: 5 })
            .borderRadius(15)
            .backgroundColor('#E6290C08')
            .border({ width: 1, color: '#73FF3D2E' })
          }
          .width('100%')
          .height('100%')
          .padding({ top: 12 })
          .alignItems(HorizontalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        }

        // 需求 4：右上角「需要添加支撑」告警（黄色脉冲闪烁）。
        //   · 判定来自原生侧悬空面启发式统计；支撑开关（enable_support）打开时自动不显示；
        //   · 只在模型浏览态显示 —— 切片路径态的右上角被 GcodePreview 的「渲染中」胶囊占用，避免叠字；
        //   · 闪烁用 animateTo({iterations:-1, playMode:Alternate}) 驱动透明度（绝不使用 .shadow()）；
        //     页面不可见时由 pauseHiddenWork 停掉（隐藏页不烧 GPU），可见时由 resumeHiddenWork 恢复；
        //   · hitTestBehavior=None：绝不吃 3D 视口的手势（旋转/缩放/平移照常）。
        if (this.supportWarnShow && !this.gcodeShow) {
          Column() {
            Row({ space: 7 }) {
              Stack() {
                Text('!')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#3A2A00')
              }
              .width(16)
              .height(16)
              .borderRadius(8)
              .backgroundColor(Theme.warn)
              Text('需要添加支撑')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFE9A6')
              Text(`朝下面 ${this.overhangRatioPct.toFixed(1)}%`)
                .fontSize(10)
                .fontColor('#C9B36A')
                .fontFamily('monospace')
            }
            .padding({ left: 8, right: 12, top: 5, bottom: 5 })
            .borderRadius(15)
            .backgroundColor('#E62A2308')
            .border({ width: 1, color: '#B3FFB020' })
            .opacity(this.supportWarnAlpha)
          }
          .width('100%')
          .height('100%')
          .padding({ top: 12, right: 14 })
          .alignItems(HorizontalAlign.End)
          .hitTestBehavior(HitTestMode.None)
        }

        // 底部一条：左 = 模型信息 HUD，右 = 视图预设盘。
        // 为什么合成同一个覆盖层：①两个角不会互相压住；②少铺一层「铺满视口」的浮层 ——
        // 玻璃/毛玻璃要抓背后的画面，浮层越少，取景越干净（右上角的告警是 None 不吃手势的那类，另算）。
        if (this.hudVisible || !this.gcodeShow) {
          Row() {
            if (this.hudVisible) {
              this.modelStatsHud()
            }
            Blank()
            if (!this.gcodeShow) {
              this.viewPresetPanel()
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 14, bottom: 16 })
          .alignItems(VerticalAlign.Bottom)
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .borderRadius(10)
      .clip(true)
      .backgroundColor(this.viewBgColor())
      .onAreaChange((oldV: Area, newV: Area) => {
        const w: number = Number(newV.width);
        const h: number = Number(newV.height);
        this.viewW = w > 0 ? w : 1;
        const nh: number = h > 0 ? h : 1;
        // 视口高变化（导入 / 切页 / 旋转屏都会触发）→ 抽屉面板的高度上限必须按【新值】重算，
        // 否则面板仍按旧上限裁剪。仅当确有此变化时才同步，避免无谓重排。
        if (Math.abs(nh - this.viewH) >= 0.5) {
          this.viewH = nh;
          this.syncPanelH();
        }
      })
      // 鼠标移动：选面模式悬停高亮
      .onMouse((e: MouseEvent) => {
        if (!this.pickFaceMode) {
          return;
        }
        this.handleHoverMove(Number(e.x) / this.viewW, Number(e.y) / this.viewH);
      })
      // 触控板：双指拖动（轴事件）→ 旋转视角（与屏幕双指旋转一致）
      .onAxisEvent((e: AxisEvent) => {
        const h: number = e.getHorizontalAxisValue();
        const v: number = e.getVerticalAxisValue();
        if (h !== 0 || v !== 0) {
          this.applyOrbit(h, v);
          this.suppressTapUntil = Date.now() + 300;
        }
      })
      // 手势：
      //  - 单指 / 按住鼠标拖动 → 平移摄像机（前后左右，带边界）
      //  - 双指捏合 → 缩放
      //  - 双指拖动 → 二轴旋转视角
      //  - 选面模式下单击 → 选面（拖动结束后短暂抑制，避免松手误选）
      .gesture(
        GestureGroup(GestureMode.Parallel,
          TapGesture({ count: 1 })
            .onAction((e: GestureEvent) => {
              if (this.dragging || Date.now() < this.suppressTapUntil) {
                return;
              }
              const fi = e.fingerList[0];
              if (fi === undefined) {
                return;
              }
              const nx: number = fi.localX / this.viewW;
              const ny: number = fi.localY / this.viewH;
              if (this.pickFaceMode) {
                this.onPickFace({ x: nx, y: ny });
              } else if (this.tool !== 0) {
                // 点击手柄轴 → 弹出增量输入
                const a: string = this.pickGizmoAxis(fi.localX, fi.localY);
                if (a !== '') {
                  this.deltaText = '';
                  this.deltaAxis = a;
                }
              }
            }),
          PanGesture({ fingers: 1, distance: 2 })
            .onActionStart((e: GestureEvent) => {
              // 框选工具：按下即开始拉矩形，**不吃相机平移**（否则拖框时画面会跟着跑）
              if (this.tool === 4 && !this.pickFaceMode) {
                const fb = e.fingerList[0];
                if (fb !== undefined) {
                  this.selBox = [fb.localX, fb.localY, fb.localX, fb.localY];
                  this.selBoxOn = true;
                  this.boxDragging = true;
                  return;
                }
              }
              this.dragging = true;
              this.lastPanX = 0;
              this.lastPanY = 0;
              this.dragAxis = '';
              // 工具激活时：先判定是否按在手柄轴上（是→拖拽手柄；否→平移视角）
              if (this.tool !== 0 && !this.pickFaceMode) {
                const fi = e.fingerList[0];
                if (fi !== undefined) {
                  const a: string = this.pickGizmoAxis(fi.localX, fi.localY);
                  if (a !== '') {
                    this.beginGizmoDrag(a, fi.localX, fi.localY);
                  }
                }
              }
            })
            .onActionUpdate((e: GestureEvent) => {
              if (this.boxDragging) {
                const fb = e.fingerList[0];
                if (fb !== undefined) {
                  this.selBox = [this.selBox[0], this.selBox[1], fb.localX, fb.localY];
                }
                return;
              }
              const dx: number = e.offsetX - this.lastPanX;
              const dy: number = e.offsetY - this.lastPanY;
              this.lastPanX = e.offsetX;
              this.lastPanY = e.offsetY;
              if (this.dragAxis !== '') {
                const fi = e.fingerList[0];
                const px: number = fi !== undefined ? fi.localX : 0;
                const py: number = fi !== undefined ? fi.localY : 0;
                // 合并高频事件：一帧内只更新一次（见 queueGizmoDrag）
                this.queueGizmoDrag(px, py);
              } else {
                this.applyPan(dx, dy);
              }
            })
            .onActionEnd(() => {
              if (this.boxDragging) {
                this.boxDragging = false;
                this.selBoxOn = false;
                this.finishBoxSelect();
                this.suppressTapUntil = Date.now() + 300;
                return;
              }
              this.dragging = false;
              this.suppressTapUntil = Date.now() + 300;
              // 补上被合并掉的那一帧位移，避免「松手瞬间」少走一点
              if (this.dragScheduled && this.dragAxis !== '') {
                this.updateGizmoDrag(this.dragPx, this.dragPy);
              }
              this.endGizmoDrag();
            }),
          GestureGroup(GestureMode.Exclusive,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.lastPinchScale = 1;
              })
              .onActionUpdate((e: GestureEvent) => {
                if (this.lastPinchScale > 0.01) {
                  this.dist = Math.max(60, Math.min(2500, this.dist / (e.scale / this.lastPinchScale)));
                  this.updateView();
                }
                this.lastPinchScale = e.scale;
              }),
            PanGesture({ fingers: 2, distance: 6 })
              .onActionStart(() => {
                this.dragging = true;
                this.lastRotateX = 0;
                this.lastRotateY = 0;
              })
              .onActionUpdate((e: GestureEvent) => {
                const dx: number = e.offsetX - this.lastRotateX;
                const dy: number = e.offsetY - this.lastRotateY;
                this.lastRotateX = e.offsetX;
                this.lastRotateY = e.offsetY;
                this.applyOrbit(dx, dy);
              })
              .onActionEnd(() => {
                this.dragging = false;
                this.suppressTapUntil = Date.now() + 300;
              })
          )
        )
      )
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)

      // 框选矩形（工具 4 拖拽时显示）：纯视觉，不吃手势。
      // 坐标与手势的 fingerList.localX/Y 同源（都是视口本地 vp），所以直接 position 定位。
      if (this.selBoxOn) {
        Column()
          .width(Math.abs(this.selBox[2] - this.selBox[0]))
          .height(Math.abs(this.selBox[3] - this.selBox[1]))
          .position({
            x: Math.min(this.selBox[0], this.selBox[2]),
            y: Math.min(this.selBox[1], this.selBox[3])
          })
          .backgroundColor('#2638D6A0')
          .border({ width: 1, color: Theme.accent })
          .hitTestBehavior(HitTestMode.None)
      }

      // 需求 2：顶部工具抽屉。作为 Stack 子节点「浮」在 3D 视口之上（不参与布局 → 不挤压视口高度）；
      // 切片路径预览态（gcodeShow）不显示，与原来隐藏模型页工具栏的行为一致。
      if (!this.gcodeShow) {
        this.topToolDrawer()
      }

      // 大模型载入弹窗：强制模态（无取消 / 不可关闭），仅在载入期间存在
      if (this.dlgVisible) {
        LoadingDialog({ model: this.dlgModel })
      }
    }
    .width('100%')
    .height('100%')
  }

  // 左下角模型信息胶囊：X / Y / Z 实际尺寸 + 实体体积。
  // ---- 液态玻璃面板：暗磨砂底 + 镜面高光 + 亮发丝边 ----
  //
  // 为什么不走 systemMaterial（这里是踩过的坑）：`isImmersiveMaterialSupported()` 为 true 时，
  // 旧代码把底色设成 Transparent、模糊设成 NONE，只留系统材质 —— 但这台机器上材质覆盖
  // Component3D 表面时**什么都没画出来**，结果两块面板变成纯透明（「没有任何可视性」）。
  // 现在改为自己画：暗磨砂底（保证文字可读）→ 斜向镜面高光（玻璃的折射感）→ 四边发丝描边
  // （顶亮/侧中/底暗，把玻璃厚度立起来）→ 外阴影把它从 3D 背景里托出来。
  // 两个面板共用这一套配方，只有圆角/高度不同。
  @Builder
  modelStatsHud() {
    Row() {
      this.hudChip(0, 'X', this.hudX)
      Divider().vertical(true).height(16).strokeWidth(1).color('#2EFFFFFF')
      this.hudChip(1, 'Y', this.hudY)
      Divider().vertical(true).height(16).strokeWidth(1).color('#2EFFFFFF')
      this.hudChip(2, 'Z', this.hudZ)
      Divider().vertical(true).height(16).strokeWidth(1).color('#2EFFFFFF')
      this.hudChip(3, 'VOL', `${this.hudVol} cm³`)
    }
    .height(38)
    .padding({ left: 4, right: 4 })
    .borderRadius(19)
    // 暗磨砂底 + 高光**合成在同一道渐变里**：linearGradient 会接管底色（backgroundColor 会被盖掉），
    // 所以它每一档都必须自带不透明度 —— 掺一段全透明，就会直接透出 3D 画面（面板「看不见了」）。
    // 于是用「左上偏亮的烟灰 → 右下更暗」这一道全不透明（94%→80%）的渐变同时干两件事：
    // 保证文字底下始终够实、并让明暗过渡本身充当玻璃的受光面。
    // 不透明度取到 94%→80% 而不是更低：`backgroundBlurStyle` 的组件材质在浅色环境下会
    // 往上叠一层亮色，底子太透整体就会被提亮成灰白（实测截图），压深一档才落回「暗磨砂」。
    .linearGradient({
      angle: 145,
      colors: [['#F02B323B', 0.0], ['#E21A2028', 0.3], ['#D60E1217', 0.65], ['#CC0A0D12', 1.0]]
    })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      adaptiveColor: AdaptiveColor.AVERAGE,
      policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
    })
    .borderWidth({ top: 1, left: 1, right: 1, bottom: 1 })
    .borderColor({ top: '#40FFFFFF', left: '#1FFFFFFF', right: '#1FFFFFFF', bottom: '#12FFFFFF' })
    .shadow({ radius: 22, color: '#8C000000', offsetX: 0, offsetY: 8 })
  }

  @Builder
  hudChip(kind: number, label: string, value: string) {
    Row({ space: 6 }) {
      if (kind < 3) {
        Column()
          .width(6)
          .height(6)
          .borderRadius(1.5)
          .backgroundColor(kind === 0 ? '#FF5566' : (kind === 1 ? '#3DDC84' : '#4DA6FF'))
      }
      Text(label)
        .fontSize(10)
        .letterSpacing(1)
        .fontColor(kind === 3 ? '#7FE6C8' : '#9EA1AE')
      Text(value)
        .fontSize(13)
        .fontColor(kind === 3 ? Theme.accentSoft : Theme.textPrimary)
    }
    .height('100%')
    .padding({ left: 13, right: 13 })
    .backgroundColor(kind === 3 ? '#2400C48C' : Color.Transparent)
    .borderRadius(14)
  }

  // 视图预设 + 近正交切换（Phase 3）：贴在视口**右下角**的一小块「视图盘」。
  //
  // 视觉与左下 HUD 共用同一套「暗磨砂 + 镜面高光 + 亮发丝边」配方（见 modelStatsHud 的说明）；
  // 区别只在：这里是多格控件，所以每格给一层极淡的白（7%）当可点区域，当前生效的
  // 投影模式用品牌绿浅底 + 绿描边点亮 —— 既不堆卡片，也一眼看得出哪儿能点、哪儿是当前态。
  // 布局：4 + 3（等轴占两格）两行对齐同一栅格，发丝分隔线之下是「透视 / 近正交」模式段。
  @Builder
  viewPresetPanel() {
    Column({ space: 3 }) {
      Row({ space: 3 }) {
        this.viewPresetBtn('front', 38)
        this.viewPresetBtn('back', 38)
        this.viewPresetBtn('left', 38)
        this.viewPresetBtn('right', 38)
      }
      .width('100%')

      Row({ space: 3 }) {
        this.viewPresetBtn('top', 38)
        this.viewPresetBtn('bottom', 38)
        this.viewPresetBtn('iso', 79)
      }
      .width('100%')

      Divider().strokeWidth(1).color('#26FFFFFF').margin({ top: 1, bottom: 1 })

      Row({ space: 3 }) {
        this.viewModeSeg('透视', false)
        this.viewModeSeg('近正交', true)
      }
      .width('100%')
    }
    .width(171)
    .padding(5)
    .borderRadius(16)
    // 同 HUD：暗底与高光合成在一道全不透明的渐变里（理由与不透明度取值见 modelStatsHud 的注释）
    .linearGradient({
      angle: 145,
      colors: [['#F02B323B', 0.0], ['#E21A2028', 0.3], ['#D60E1217', 0.65], ['#CC0A0D12', 1.0]]
    })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      adaptiveColor: AdaptiveColor.AVERAGE,
      policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
    })
    .borderWidth({ top: 1, left: 1, right: 1, bottom: 1 })
    .borderColor({ top: '#40FFFFFF', left: '#1FFFFFFF', right: '#1FFFFFFF', bottom: '#12FFFFFF' })
    .shadow({ radius: 22, color: '#8C000000', offsetX: 0, offsetY: 8 })
  }

  // 视图按钮：极淡白底把可点区域画出来（宽 38 / 等轴 79，两行对齐同一栅格）
  @Builder
  viewPresetBtn(name: string, w: number) {
    Button(viewPresetLabel(name))
      .width(w)
      .height(30)
      .padding(0)
      .fontSize(11)
      .fontColor(Theme.textPrimary)
      .backgroundColor('#14FFFFFF')
      .borderRadius(9)
      .stateEffect(true)
      .onClick(() => { this.setViewPreset(name); })
  }

  // 投影模式段：当前生效的一段用品牌绿浅底 + 绿描边点亮，另一段只留发丝边
  @Builder
  viewModeSeg(label: string, ortho: boolean) {
    Row() {
      Text(label)
        .fontSize(11)
        .fontWeight(this.orthoLike === ortho ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.orthoLike === ortho ? Theme.accentSoft : '#B9BCC7')
    }
    .width(79)
    .height(26)
    .justifyContent(FlexAlign.Center)
    .borderRadius(9)
    .backgroundColor(this.orthoLike === ortho ? '#2E00C48C' : Color.Transparent)
    .border({ width: 1, color: this.orthoLike === ortho ? '#6600C48C' : '#1FFFFFFF' })
    .onClick(() => {
      if (this.orthoLike !== ortho) {
        this.toggleOrtho();
      }
    })
  }
}
