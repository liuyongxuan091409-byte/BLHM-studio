import fs from '@ohos.file.fs';
import { util, worker } from '@kit.ArkTS';
import { MessageEvents, ErrorEvent } from '@ohos.worker';
import type { Vec3 } from '@kit.ArkGraphics3D';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLog } from '../service/AppLog';
import { MeshGeometry } from './MeshUtils';
import { GcodeParseResult, GcodeWorkerRequest, GcodeWorkerResponse } from './GcodeParseTypes';

// TypedArray → number[]（层边界这些数组很小，转成普通数组便于既有代码按 [] 访问）
function typedToNumArray(a: Int32Array | Float32Array): number[] {
  const out: number[] = [];
  for (let i: number = 0; i < a.length; i++) { out.push(a[i]); }
  return out;
}

// 让出一帧：把控制权交回 UI/事件循环，避免长时间独占主线程。
// 与项目其它模块（Index / ModelPreviewPage）用法一致，保证进度能被绘制、系统 6s 主线程
// 阻塞阈值（THREAD_BLOCK_6S）不会被触发。
function yieldToUi(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 0);
  });
}

// =============================================================================
// 切片路径几何：把 output.gcode 解析成「有真实线宽、也有真实厚度（层高）」的带条（ribbon）
//
// 为什么不做成线段：ArkGraphics3D 的 PrimitiveTopology 只有 TRIANGLE_LIST /
// TRIANGLE_STRIP，没有线段原语，所以每一段挤出都必须被三角化。
//
// 为什么从「四棱柱」改成「共享顶点的带条」：
//   CustomGeometry.vertices 只收 Vec3[]（每个顶点一个 JS 对象，没有裸 Float32Array 入口）。
//   老做法每段建一个四棱柱 = 8 顶点 + 18 索引；998 层的大手办有 83 万次挤出、
//   展开后约 150 万段，光顶点对象就上千万，必崩。
//   新做法让「一条连续折线」共享顶点：M 个点 → 4M 顶点 + 18(M-1) 索引
//   （每点上排 2 个 + 下排 2 个；两个侧面裙边复用同一批上/下排顶点，所以每点只比
//   曾经的「无厚度」带条多 2 个顶点），再配合下面的保形折线简化，顶点对象数仍比
//   四棱柱低一个数量级。
//
// 为什么不能用「层内按索引跳步」抽稀（曾经的 bug）：
//   for (k = a; k < b; k += stride) 是在一层内部隔几段取一段，会把连续的墙打断成
//   互不相连的碎线段，肉眼看到的就是「层与层断开、只剩残缺的线头」。
//   正确做法是在解析阶段做「保形折线简化」：只可能删掉共线的中间点，
//   一层内始终是一条连续折线，绝不产生断开的线头。
//
// 坐标：g-code 用板角原点（X 向右、Y 向里、Z 向上）。
// 场景内容坐标系是 Y 轴向上（glTF 风格），转换 (x,y,z) → (x, z, -y)，
// 再把盘面中心挪到原点，与模型页 buildGridLines 建的网格线同一套坐标。
//
// 厚度：层高方向 = 内容 Y。带条上表面在 y = 该层 z，下表面在 y = z - 层高 h，
// 而 h 取该层的「真实层高」（优先 gcode 的 "; LAYER_HEIGHT:"，其次「本层 z - 上一层 z」）
// → 本层底面恰好等于上一层顶面，所有层在高度方向首尾相接（层与层贴合）。
// **层高必须等于真实层高，否则相邻层之间会空出一条缝、水平看就透光。**
// 曾经的无厚度带条层与层之间空着整整一个层高，视线从缝里直接穿过去，还会同时看到下面几十层交织。
// 截面：真实挤出线的截面是圆顶/梯形（顶面窄、两侧有斜面），不是矩形。这里按「上窄下宽的
//   梯形」建：下排半宽 = 真实半线宽 hw，上排半宽 = hw × K_TOP。这样同层相邻两线即便底部
//   挨上，顶部之间也会留出一道 V 形沟（暗缝），眼睛才能把「一根一根」分开；若做成上下同宽
//   的矩形，两线顶面是同一个平面、法线都是 +Y、受光完全相同 → 视觉上溶成一片。
//   梯形截面还要补一条底面，做成「闭合棱柱」——只有顶面 + 两侧斜面的话是个开口壳，
//   从下方/水平方向能看进壳内、看到上一层顶面背面，就是「透光/看穿」（见 addRibbon 步骤 3）。
// 法线：顶面两个顶点共用 UP_NORMAL（+Y）；左右两个斜面各用一个「倾斜法线」（由斜面方向
//   算出并归一化，朝外且朝上）。注意每点只有 4 个顶点，上排 2 个同时属于「顶面」和「斜面」，
//   法线只能取其一（这里取 +Y），倾斜法线落在下排的左、右顶点上 —— 底面复用下排顶点（法线即
//   这两个倾斜法线），顶点预算受限，不做硬边拆分。
// =============================================================================

// =============================================================================
// 【切页几何保留策略：改这一个常量即可切换】——RELEASE_GCODE_ON_LEAVE
// 用户实测痛点：在「切片路径」态切到别的页面再切回来时，之前的最小改动方案会释放 gcode 几何，
// 回来必须重建 + 重跑一遍「自下而上」扫层 —— 用户看到的就是「卡一下然后重新渲染」，很烦。
// 这里把它做成可配置（默认走「保留」）：
//   · false（**新默认**）：切走一律【不销毁几何】，按去处分两种「隐藏」方式：
//       – 切到「非 3D 页」（设备 / 校准 / 日志）：整块 3D 子树不可见 →【只暂停工作】
//         （扫层定时器 / 后台补建 / 日志 flush /「渲染中」广播 / 越界脉冲 —— 这些暂停逻辑保留不变）；
//       – 切到「准备页 / 预览页的模型态」：3D 仍可见、必须显示模型 →【只把路径根置为不可见】
//         （模型与路径是同一场景里的互斥显示，靠 gcodeShow 一处开关切换），仍不销毁。
//     两种情形下几何、块节点、lastVisChunks、层滑条位置、相机视角全部保留；切回来时几何仍在 →
//     直接呈现原状态，不重跑 reload()、不重跑扫层。代价是：隐藏期间这段几何仍占内存（用内存换即时显示）。
//     【只有 gcode 本身变了（重新切片 / 换 gcode / generation 变化）才必须销毁重建】——见
//     ModelPreviewPage.updateToolpath 的注释；除它以外的切走都不该销毁。
//   · true（旧行为，保留可用）：切走一律释放几何（避免与模型网格双份占内存），回来走 reload→重建 + 扫层。
//
// 【内存代价量级（本样本：约 998 层手办，顶点约 316 万）】
//   保留几何 = 引擎侧的一整份切片路径网格常驻（与模型网格同时在场）：
//     · 顶点属性：316 万顶点 × (位置 12B + 法线 12B) ≈ 76 MB
//     · 索引：约 6 个索引/顶点 ≈ 1900 万 × 4B ≈ 76 MB
//     · 合计约 150 MB 量级（JS 侧累积几何在每块 flush 后即被回收，不算常驻）。
//   块 / 几何规模：998 层 ÷ 每块 16 层(GCODE_CHUNK_LAYERS) ≈ 63 个块节点；每块约 5~7 个角色几何
//     ≈ 300~440 个几何节点（+1 个路径根，节点总数约 400~500）。
//   —— 手机端如内存吃紧，把 RELEASE_GCODE_ON_LEAVE 改回 true 即可（其余逻辑自动跟随，无需改别处）。
// =============================================================================
export const RELEASE_GCODE_ON_LEAVE: boolean = false;

// 第 10 档「辅助线」= 机器启动 G-code 里的辅助挤出（拓竹 `; FEATURE: Custom` 标记的整段
//   machine_start_gcode：喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线）。
//   【为什么单列一档而不是复用「其他」】这些线是真实打印出来的 G-code（未导入模型时也在板前端
//   打），落进「其他」= 纯灰 #BDBDBD，与网格/底色一眼分不开；单列一档给一个高辨识度色，
//   图例与切片预览都能看清。色相取 #C6FF00(73°)，与既有 42°/122° 两档各差 ≥30°，不撞色。
export const ROLE_LABEL: string[] = ['外壁', '内壁', '稀疏填充', '实心填充', '顶面', '底面', '桥接', '支撑', '间隙填充', '其他', '辅助线'];

// 「辅助线」档下标（= ROLE_LABEL 末位）：机器起始 G-code 的辅助挤出统一归到这一档。
export const ROLE_AUX_LINE: number = 10;
// 熨烫（ironing_type=top）：**并入「顶面」而不是丢弃**。
// 它是在顶面之上再跑一遍的收尾走线，与 Top surface **同 Z、同区域**：
//   · 若单独一档（曾归「实心填充」）→ 红/青交替 + 共面闪烁；
//   · 若整档丢弃 → 顶层丢掉 7 成以上的走线（实测 L13: ironing 4283mm vs top 1482mm），
//     预览里顶层变得坑坑洼洼、还能透出下一层，看起来就是「红白交错/零零碎碎」。
// 合成同一档后两点都消失：同色叠画即使有深度冲突也看不出来，顶层仍是一整片顶面。
// （拓竹桌面版同样把熨烫画在顶面里，只是预览按角色着色时看起来是同一片红。）

// ===== 配色表：**唯一一份**（图例与渲染都由它派生）=====
// 【为什么必须单源】图例（GcodePreview 画圆点）以前读 ROLE_COLOR_HEX，而模型渲染
// （ModelPreviewPage 建角色材质）读另一张各自硬编码的 ROLE_RGB。两张表一旦漂移，就会
// 出现「图例是蓝/橙/黄、模型却是另一套色甚至发灰」—— 而这条路上**下标合法、数组长度也对、
// 不触发任何越界告警**，只能靠肉眼发现。这正是「多个不同角色一起变灰却没有任何告警」唯一
// 可能的成因。所以这里把渲染色改成由 hex 表派生（hex/255），两张表物理上不可能再分叉，
// 编号语义也只剩一套：role ∈ [0,9] → slot = role + 1 → 材质下标 = role。
//
// 色相要求：除第 9 档「其他」外，任何一档都不允许再是灰。
//   曾经 7「支撑」/8「间隙填充」用的是灰褐 #8D6E63 / 灰蓝 #78909C，HSL 饱和度只有
//   ~23%/30%，3D 视图里肉眼就是「灰」；而真实 gcode（998 层手办）里「间隙填充」几乎每层
//   都有、「支撑/辅助结构」也可能大面积出现，于是被当成「其他」那档灰。
//   现取色相环上仅剩的两段空隙（231° 与 340°），与 0~6 档色相夹角都 ≥21°，
//   饱和度 ≥82%、明度 ≥52%，与「其他」的纯灰 #BDBDBD 一眼可分。
export const ROLE_COLOR_HEX: string[] = ['#FFB300', '#FF7043', '#4FC3F7', '#26A69A', '#EF5350', '#AB47BC', '#66BB6A', '#536DFE', '#E91E63', '#BDBDBD', '#C6FF00'];

export const GHOST_RGB: number[] = [0.30, 0.33, 0.38];

// hex（'#RRGGBB'）第 from 位起的两位 → 0..1
function hexChannel(hex: string, from: number): number {
  const v: number = Number.parseInt(hex.substring(from, from + 2), 16);
  return Number.isNaN(v) ? 0 : v / 255;
}

// 材质基色（0..1）：**由 ROLE_COLOR_HEX 派生**，不再另手写一张表（防止两套表漂移）。
function buildRoleRgb(): number[][] {
  const out: number[][] = [];
  for (let r: number = 0; r < ROLE_COLOR_HEX.length; r++) {
    out.push([hexChannel(ROLE_COLOR_HEX[r], 1), hexChannel(ROLE_COLOR_HEX[r], 3), hexChannel(ROLE_COLOR_HEX[r], 5)]);
  }
  return out;
}
export const ROLE_RGB: number[][] = buildRoleRgb();

// 配色表自检：返回所有「不合法」的说明，长度 0 = 全部通过。
// 检查项：
//   1) 三张表长度必须一致（固定档位 + 固定配色，绝不做「按实际出现的角色压缩」，
//      压缩会把「颜色表第 N 档」错位到别的角色上，且下标仍在范围内 → 不告警的串色/变灰）；
//   2) 每个 hex 必须是 '#RRGGBB'；
//   3) 除第 9 档「其他」外，任何一档都不允许是灰（通道极差 < 0.06 视为无彩度）。
// 供场景初始化与诊断块调用：谁再把某档改灰，会立刻在 hilog / 应用日志 / 诊断文件里被点名。
export function paletteProblems(): string[] {
  const bad: string[] = [];
  if (ROLE_COLOR_HEX.length !== ROLE_LABEL.length || ROLE_RGB.length !== ROLE_LABEL.length) {
    bad.push(`配色表长度不一致：label=${ROLE_LABEL.length} hex=${ROLE_COLOR_HEX.length} rgb=${ROLE_RGB.length}`);
  }
  for (let r: number = 0; r < ROLE_COLOR_HEX.length; r++) {
    const h: string = ROLE_COLOR_HEX[r];
    if (h.length !== 7 || h.charCodeAt(0) !== 35) {
      bad.push(`第 ${r} 档 hex 非法：「${h}」`);
      continue;
    }
    if (r >= ROLE_RGB.length || ROLE_RGB[r].length !== 3) {
      bad.push(`第 ${r} 档 rgb 非法`);
      continue;
    }
    const rgb: number[] = ROLE_RGB[r];
    const mx: number = Math.max(rgb[0], Math.max(rgb[1], rgb[2]));
    const mn: number = Math.min(rgb[0], Math.min(rgb[1], rgb[2]));
    if (r !== 9 && (mx - mn) < 0.06) {
      bad.push(`第 ${r} 档「${ROLE_LABEL[r]}」是灰色(${h})，只有「其他」允许是灰`);
    }
  }
  return bad;
}

// 折线简化容差（mm）：中间点 B 到它前后两个「保留点」A、C 连线的垂距 < 该值就丢弃 B。
// 这是「保形简化」，不是「抽稀」：只可能删掉共线的中间点，折线的首点、末点以及
// 一层内的连通性一定保持，绝不会把一层打断成碎线。
const SIMPLIFY_TOL_MM: number = 0.01;

// 端点连续性容差（mm）：上一段终点与当前段起点不重合（超过该值）就另起一条折线。
const CONTIG_TOL_MM: number = 0.001;

// 线宽变化阈值：同一条折线内两次 LINE_WIDTH 相对差超过 5% 就断开，保证每条折线的线宽正确。
const WIDTH_CHANGE_RATIO: number = 0.05;

// 单层顶点预算兜底：ArkGraphics3D 的 vertices 是「每顶点一个 JS 对象」，
// 单层顶点数异常巨大时只能整层取舍（整层跳过），绝不允许层内挑段
// ——层内挑段会打断连通性，就是老 bug 的成因。
// 带条每点 4 个顶点（上排 2 + 下排 2），所以 800000 顶点 = 单层 20 万个点。
// 依据：加厚度前是「每点 2 顶点 / 400000 顶点 = 单层 20 万个点」，这里按每点 4 顶点
// 同比例放大，保证正常模型的预算（20 万点/层）完全不变，不会因为顶点翻倍而误触发整层跳过。
const MAX_VERTS_PER_LAYER: number = 800000;

const MAX_LAYERS: number = 4000;

// 斜接（miter）长度上限系数：真斜接的偏移长度 = hw / |cos θ|（θ 为角平分线法向与
// 相邻段法向的夹角），急转弯处 θ→90° 时长度趋于无穷，会在尖角射出长刺并自交出
// 扇形重叠（叠出一片并不存在的填充）。把系数夹在该值以内（超过就截断）。
// 收到 1.2：锯齿填充两端是 180° 折返，那里真斜接长度趋于无穷、会被夹到上限，
// 夹得越松鼓包越大（几十个鼓包叠在一起就是「糊」）；1.2 只允许很轻微的放大，
// 急转弯处几乎退化成等宽偏移，不再鼓包。
// 现取 1.5：90° 直角的真斜接系数是 1/|cos45°|≈1.414 > 1.2 → 原来直角会被截断出小缺口；
// 放到 1.5 刚好让直角恢复成精确斜接（更连贯、少缝），同时仍是有限值，
// 180° 折返处只鼓 0.5×半线宽（≈0.21mm），不足以糊。
const MITER_LIMIT: number = 1.5;

// 挤出线截面：顶面宽度 / 真实线宽。真实挤出线的截面是圆顶/梯形（顶面窄、两侧有斜面），
// 不是矩形；把上排（顶面）顶点往内收到该比例，同层相邻两线即便底部挨上，顶部之间也会
// 留出一道 V 形暗缝（底部仍相接、不透光），眼睛才能把「一根一根」分开。
// 现取 0.80（原 0.55）：0.55 的顶面收窄过多 → 侧看时层与层之间那道 V 形暗缝偏深，
// 视觉上就是「路径太薄、侧看透光」。收到 0.80 后沟变浅、侧面看着更实，同时仍保留分线感。
const K_TOP: number = 0.80;

// 折返判定阈值：相邻两段的单位方向向量点积小于该值时，认为该点「近似 180° 折返」
// （锯齿填充的两端就是这种情形）。此时角平分线退化、真斜接长度趋于无穷，
// 必须改用「段法向、偏移长度不放大」的回退，否则每个折返点都会鼓出一个包。
const REVERSE_DOT: number = -0.9;


// 顶面（上排）两个顶点共用的法线：所有顶面顶点复用这一个常量对象，不逐顶点新建。
const UP_NORMAL: Vec3 = { x: 0, y: 1, z: 0 };

export class GcodeMeshPart {
  // slot = 角色下标 + 1（role ∈ [0, 10] → slot ∈ [1, 11]）。
  // 模型页据此取共享材质 roleMats[slot - 1]（下标 = role），0 保留给「当前层以上」的暗灰。
  slot: number = 0;
  geom: MeshGeometry = new MeshGeometry();

  constructor(slot: number, geom: MeshGeometry) {
    this.slot = slot;
    this.geom = geom;
  }
}

// 机器起始 G-code 辅助线（喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线）的真实统计。
// 全部由真实数据算出（切片 gcode 里 role=10 的折线，或机器预设启动 g-code 解析结果），
// 不含任何按板尺寸推导/占位值；无法解析到就是 has=false，绝不填估算数。
export class AuxLineStats {
  has: boolean = false;
  runCount: number = 0;   // 折线条数
  segCount: number = 0;   // 挤出段数
  xMin: number = 0;       // 真实 X 范围（mm，gcode 坐标）
  xMax: number = 0;
  yMin: number = 0;       // 真实 Y 范围（mm）
  yMax: number = 0;
}

// 把辅助线统计格式化成一行日志/诊断文本（三通道共用同一份措辞）。
// src 说明来源（"切片 gcode" 或 "机器预设启动 gcode"）。
export function formatAuxStats(st: AuxLineStats, src: string): string {
  if (!st.has) {
    return `辅助线 来源=${src} 无（未解析到挤出线）`;
  }
  return `辅助线 来源=${src} 折线=${st.runCount} 段=${st.segCount} ` +
    `X=${st.xMin.toFixed(1)}~${st.xMax.toFixed(1)}mm Y=${st.yMin.toFixed(1)}~${st.yMax.toFixed(1)}mm`;
}

// 在 [from,to) 内查找字面量（不用 indexOf，避免越过行尾把后续整段都扫一遍）
function findIn(s: string, from: number, to: number, lit: string): number {
  const last: number = to - lit.length;
  for (let i = from; i <= last; i++) {
    let ok: boolean = true;
    for (let k = 0; k < lit.length; k++) {
      if (s.charCodeAt(i + k) !== lit.charCodeAt(k)) { ok = false; break; }
    }
    if (ok) { return i; }
  }
  return -1;
}

// 判断 s[at..end) 是否以字面量 lit 开头（不产生子串）
function matchAt(s: string, at: number, end: number, lit: string): boolean {
  if (at + lit.length > end) { return false; }
  for (let i = 0; i < lit.length; i++) {
    if (s.charCodeAt(at + i) !== lit.charCodeAt(i)) { return false; }
  }
  return true;
}

// 解析 s[a..b) 的十进制数（纯字符扫描，不产生子串）
function numAt(s: string, a: number, b: number): number {
  let i: number = a;
  let neg: boolean = false;
  if (i < b) {
    const c: number = s.charCodeAt(i);
    if (c === 45) { neg = true; i++; } else if (c === 43) { i++; }
  }
  let v: number = 0;
  while (i < b) {
    const c: number = s.charCodeAt(i);
    if (c < 48 || c > 57) { break; }
    v = v * 10 + (c - 48);
    i++;
  }
  if (i < b && s.charCodeAt(i) === 46) {
    i++;
    let f: number = 0.1;
    while (i < b) {
      const c: number = s.charCodeAt(i);
      if (c < 48 || c > 57) { break; }
      v += (c - 48) * f;
      f *= 0.1;
      i++;
    }
  }
  if (i < b) {
    const c: number = s.charCodeAt(i);
    if (c === 101 || c === 69) {          // e / E
      let j: number = i + 1;
      let eneg: boolean = false;
      if (j < b) {
        const c2: number = s.charCodeAt(j);
        if (c2 === 45) { eneg = true; j++; } else if (c2 === 43) { j++; }
      }
      let ev: number = 0;
      while (j < b) {
        const c2: number = s.charCodeAt(j);
        if (c2 < 48 || c2 > 57) { break; }
        ev = ev * 10 + (c2 - 48);
        j++;
      }
      v *= Math.pow(10, eneg ? -ev : ev);
    }
  }
  return neg ? -v : v;
}

// "; FEATURE: xxx" 后面的名字 -> 角色下标（0..10，见 ROLE_LABEL）；返回 -1 表示「未识别」，
// 由调用方暂归「其他」并汇总告警。
// 名字全集来自 libslic3r 的 ExtrusionEntity::role_to_string（g-code 里 "; FEATURE:" 后面
// 写的就是它，ExtrusionEntity.cpp 里 L(s) 是恒等宏、不做本地化，所以就是下面这些英文）。
// 有歧义的名字不拍脑袋，按 libslic3r 自身的分类助手归类：
//   is_perimeter()    -> 外壁（Overhang wall 是外轮廓的一部分）
//   is_solid_infill() -> 实心填充（Floating vertical shell、Ironing 都属于实心填充）
function roleOfName(text: string, at: number, end: number): number {
  if (matchAt(text, at, end, 'Outer wall')) { return 0; }
  // 悬垂墙：BBS 里是独立 feature，但它属 is_perimeter（外轮廓），归「外壁」
  if (matchAt(text, at, end, 'Overhang wall')) { return 0; }
  if (matchAt(text, at, end, 'Inner wall')) { return 1; }
  if (matchAt(text, at, end, 'Sparse infill')) { return 2; }
  if (matchAt(text, at, end, 'Internal solid infill')) { return 3; }
  // 悬垂区垂直外壳：libslic3r 把它算作 is_solid_infill（不是墙），归「实心填充」
  if (matchAt(text, at, end, 'Floating vertical shell')) { return 3; }
  if (matchAt(text, at, end, 'Top surface')) { return 4; }
  // 熨烫并进「顶面」（见 ROLE_LABEL 上方的说明：单独成档会红青交替，直接丢弃会让顶层残缺）
  if (matchAt(text, at, end, 'Ironing')) { return 4; }
  if (matchAt(text, at, end, 'Bottom surface')) { return 5; }
  if (matchAt(text, at, end, 'Bridge')) { return 6; }
  // Support / Support interface / Support transition / Support ironing 都以 Support 打头
  if (matchAt(text, at, end, 'Support')) { return 7; }
  if (matchAt(text, at, end, 'Gap infill')) { return 8; }
  // 床面附着与换料辅助结构（非模型本体）：统一归到辅助色（「支撑」这一档）
  if (matchAt(text, at, end, 'Skirt')) { return 7; }
  if (matchAt(text, at, end, 'Brim')) { return 7; }
  if (matchAt(text, at, end, 'Prime tower')) { return 7; }
  if (matchAt(text, at, end, 'Flush')) { return 7; }
  // 机器启动/结束 G-code 整段被 libslic3r 标成 `; FEATURE: Custom`（真实 name，不猜）。
  // 里面就是喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线 —— 真实打印出来的辅助挤出，
  // 单列一档「辅助线」（见 ROLE_LABEL 注释），不再落进「其他」的灰色。
  if (matchAt(text, at, end, 'Custom')) { return ROLE_AUX_LINE; }
  // 已知但语义上本就「无具体几何类别」的名字：显式归「其他」，不算未识别、不告警
  if (matchAt(text, at, end, 'Multiple')) { return 9; }
  if (matchAt(text, at, end, 'Undefined')) { return 9; }
  return -1;
}

export class GcodeToolpathStore {
  // 折线存储（已是简化后的结果）：
  //   ptXY 存所有折线的点，x,y 交替；第 r 条折线 = ptXY 中
  //   [runStart[r], runStart[r]+runLen[r]) 这些点（runLen >= 2）。
  //   用扁平 TypedArray 而不是逐点建对象：百万级点也只占几 MB。
  private ptXY: Float32Array = new Float32Array(0);
  private ptCount: number = 0;
  private ptCap: number = 0;
  private runStart: Int32Array = new Int32Array(0);    // run -> 首点在 ptXY 中的「点下标」
  private runLen: Int32Array = new Int32Array(0);      // run -> 点数
  private runRole: Uint8Array = new Uint8Array(0);     // run -> 角色下标
  private runW: Float32Array = new Float32Array(0);    // run -> 线宽 mm
  private runCount: number = 0;
  private runCap: number = 0;
  private layRunStart: number[] = [];                  // 层 -> 首个 run 下标（末尾多一个 = runCount）
  private layZ: number[] = [];                         // 层 -> z
  private layH: number[] = [];                         // 层 -> 最终层高（见 updateBudgets；0 表示未知）
  // 层 -> 本层 "; LAYER_HEIGHT:" 的原始值（0 = 该层没解析到标记）。
  // 它是切片器算好的「真实层高」，优先于「相邻层 Z 差值」——见 updateBudgets 的说明。
  private layHMark: number[] = [];
  private segCount: number = 0;                        // 简化后的段数（runLen-1 之和）
  // 每个角色的「简化后段数」（下标 = role 0..10，见 ROLE_LABEL），只用于 [GcodeDiag] 角色分布统计。
  // 为什么单独记：presentRoles 只记「有没有出现过」，看不出某一档是不是被大量归到了「其他」，
  // 而「其他」段数偏多正是「feature 未识别 → 全落灰色」的直接证据。
  private roleSegCount: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  // ---- 解析中滚动的「当前折线」状态 ----
  // polyPts 是正在累积的一条折线的点序列（x,y 交替），且已经过共线简化；
  // 它始终至少保留首点与末点，因此一层内的连通性不会被简化破坏。
  private polyPts: number[] = [];
  private polyOn: boolean = false;
  private polyRole: number = 9;
  private polyW: number = 0.42;

  // ---- 分段解析的滚动状态（原 parse() 里的局部变量提成字段）----
  // 为什么要提成字段：解析改成分段执行（每个数据块处理完就 await 让帧），局部变量在一次
  // processLine 调用结束后就丢了，跨块的行首/角色/坐标必须持续保留。
  private pRole: number = 9;          // 当前 FEATURE 角色
  private pCurW: number = 0.42;        // 当前 LINE_WIDTH（mm）
  private pX: number = 0;              // 上一个运动终点 X
  private pY: number = 0;              // 上一个运动终点 Y
  private pHasPos: boolean = false;    // 是否已有首个坐标（首个 G1 只定位、不挤出）
  private pRel: boolean = false;       // G91 相对定位（默认 G90 绝对）；与 Worker 解析器同一口径
  private pCond: number = 0;           // M622 … M623 条件宏嵌套深度（>0 = 整块跳过）
  private pUsed: boolean[] = [];       // 每个角色是否出现过（role -> bool）
  private pLayerIdx: number = 0;       // 当前层下标
  private pStartMerged: boolean = false; // 起始 G-code 段是否已与模型第 1 层合并
  // load 序号：新的一次 load 会自增，正在跑的分段循环据此判断「自己是否已被取代」并主动中止。
  private loadSeq: number = 0;
  // 分段「单块最长耗时」：用于真机日志自证「任何单次连续执行都远小于 1s」。
  private maxSegMs: number = 0;

  // ---- 生成几何时复用的暂存缓冲（避免每条折线都新建数组）----
  private sx: Float32Array = new Float32Array(0);      // 去重后的点 x
  private sy: Float32Array = new Float32Array(0);      // 去重后的点 y
  private nx: Float32Array = new Float32Array(0);      // 逐点平面内法向 x
  private ny: Float32Array = new Float32Array(0);      // 逐点平面内法向 y

  loaded: boolean = false;
  statText: string = '';
  presentRoles: number[] = [];
  // 简化前的挤出段数（仅用于日志/统计回报）
  rawSegCount: number = 0;
  // 未识别 feature 的去重汇总（名称 + 出现次数）。解析中只累加，解析结束统一告警：
  // 同一个未知名称只打一条日志，且带真实出现次数。
  private unknownNames: string[] = [];
  private unknownCounts: number[] = [];
  // 当前查看层（1 起）。刻意不做成 ArkUI 状态：它一变就要重建几何，
  // 若挂在 @StorageProp 上会让整个模型页（两千多行）跟着重渲染并闪烁。
  currentLayer: number = 1;
  // 每解析一次 +1：模型页据此判断「几何是不是换了」，需要整棵树重建
  generation: number = 0;

  // ---- 读取 + 解析 ----
  // 【为什么必须把解析搬离主线程】老实现用 fs.readTextSync 把整份 ~50MB gcode 一次性读成 JS 字符串，
  // 再在主线程里逐行同步解析完 —— 大模型（鸣人1.stl 84.6MB → 约 50MB gcode / 832~999 层）时这一段
  // 连续占用主线程远超系统 6s 阈值，直接触发 THREAD_BLOCK_6S → AppFreeze 被系统杀进程。
  // 实测「主线程分段 + setTimeout 让帧」也不够：真机上主线程仍被高负载占满（单块最长 ~186ms，但整段
  // ~10s 期间几乎没有空闲），AppFreeze 看门狗拿不到心跳仍会判 THREAD_BLOCK。
  // 【最终方案】把「读文件 + 逐行解析」整体交给独立线程（GcodeParseWorker），产出紧凑的层边界 + 扁平
  // 几何缓冲（Float32Array / Int32Array / Uint8Array），主线程只做「接收 + 轻量收尾」，全程不阻塞。
  // Worker 不可用时退化为「主线程分块 + 让帧」解析（保底：不丢任何能力，最坏退化为旧行为）。
  // progress(pct, msg)：pct<0 表示「不确定进度」的文案（由 UI 决定怎么显示）。
  async load(path: string, progress?: (pct: number, msg: string) => void): Promise<boolean> {
    const seq: number = ++this.loadSeq;
    this.resetParseState();
    try {
      if (!fs.accessSync(path)) { return false; }
      const code: number = await this.loadViaWorker(path, seq, progress);
      if (code === 0) {
        this.loaded = this.layZ.length > 0;
        return this.loaded;
      }
      if (code === 1) {
        this.loaded = false;
        return false;
      }
      // code === 2：Worker 不可用 → 兜底走主线程分块解析
      return await this.loadOnMainThread(path, seq, progress);
    } catch (e) {
      this.loaded = false;
      return false;
    }
  }

  // 用独立 Worker 解析。返回：0=成功 / 1=解析失败(文件坏) / 2=Worker 不可用（调用方回退主线程）。
  private loadViaWorker(path: string, seq: number,
                        progress?: (pct: number, msg: string) => void): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      let w: worker.ThreadWorker | null = null;
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (code: number): void => {
        if (settled) { return; }
        settled = true;
        if (timer !== -1) { clearTimeout(timer); timer = -1; }
        if (w !== null) {
          try { w.terminate(); } catch (e) { /* 已退出 */ }
        }
        resolve(code);
      };
      try {
        w = new worker.ThreadWorker('entry/ets/workers/GcodeParseWorker.ets');
      } catch (e) {
        hilog.error(0x0000, 'GcodeToolpath', 'Worker 创建失败 → 回退主线程解析: %{public}s',
          e instanceof Error ? e.message : JSON.stringify(e));
        finish(2);
        return;
      }
      w.onmessage = (e: MessageEvents): void => {
        if (seq !== this.loadSeq) { finish(2); return; }
        const resp: GcodeWorkerResponse = e.data as GcodeWorkerResponse;
        if (resp.error.length > 0) {
          hilog.error(0x0000, 'GcodeToolpath', 'Worker 解析异常 → 回退主线程: %{public}s', resp.error);
          finish(2);
          return;
        }
        this.applyParsed(resp.result);
        finish(0);
      };
      w.onerror = (err: ErrorEvent): void => {
        hilog.error(0x0000, 'GcodeToolpath', 'Worker onerror → 回退主线程: %{public}s', err.message);
        finish(2);
      };
      // 兜底超时：Worker 万一卡死（不应发生）也不能让 UI 无限等
      timer = setTimeout((): void => {
        hilog.error(0x0000, 'GcodeToolpath', 'Worker 解析超时 → 回退主线程');
        finish(2);
      }, 60000);
      if (progress !== undefined) { progress(-1, '正在解析切片路径…'); }
      const req: GcodeWorkerRequest = { seq: seq, path: path };
      w.postMessage(req);
    });
  }

  // 把 Worker 返回的紧凑结果落到本对象（主线程只做拷贝/转换，量级很小）。
  private applyParsed(r: GcodeParseResult): void {
    this.ptXY = r.ptXY;
    this.ptCount = r.ptCount;
    this.ptCap = r.ptCount;
    this.runStart = r.runStart;
    this.runLen = r.runLen;
    this.runRole = r.runRole;
    this.runW = r.runW;
    this.runCount = r.runCount;
    this.runCap = r.runCount;
    this.segCount = r.segCount;
    this.rawSegCount = r.rawSegCount;
    this.layRunStart = typedToNumArray(r.layRunStart);
    this.layZ = typedToNumArray(r.layZ);
    this.layHMark = typedToNumArray(r.layHMark);
    this.statText = r.statText;
    this.presentRoles = r.presentRoles;
    this.roleSegCount = r.roleSegCount;
    this.unknownNames = r.unknownNames;
    this.unknownCounts = r.unknownCounts;
    // 与旧 load() 收尾一致：未识别 feature 告警 + 顶点预算核算 + 辅助线自证日志
    this.reportUnknownFeatures();
    this.updateBudgets();
    this.logAuxLines();
    hilog.info(0x0000, 'GcodeToolpath',
      'gcode Worker 解析完成：层数=%{public}d 段=%{public}d raw=%{public}d',
      this.layZ.length, this.segCount, this.rawSegCount);
  }

  // 兜底：主线程分块读取 + 分段让帧解析（Worker 不可用时才走）。
  private async loadOnMainThread(path: string, seq: number,
                                 progress?: (pct: number, msg: string) => void): Promise<boolean> {
    const size: number = fs.statSync(path).size;
    if (size <= 0) { return false; }
    const CHUNK: number = 512 * 1024;
    const buf: ArrayBuffer = new ArrayBuffer(CHUNK);
    const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let headerDone: boolean = false;
    let carry: string = '';
    let pos: number = 0;
    this.beginParse();
    try {
      while (pos < size) {
        if (seq !== this.loadSeq) { return false; }
        const want: number = Math.min(CHUNK, size - pos);
        const n: number = fs.readSync(f.fd, buf, { offset: pos, length: want });
        if (n <= 0) { break; }
        pos += n;
        const segT0: number = Date.now();
        const chunk: string = dec.decodeToString(new Uint8Array(buf, 0, n), { stream: true });
        if (!headerDone) {
          this.parseHeader(chunk.substring(0, Math.min(6000, chunk.length)));
          headerDone = true;
        }
        const text: string = carry.length > 0 ? carry + chunk : chunk;
        const remStart: number = this.parseCompleteLines(text);
        carry = text.substring(remStart);
        const segMs: number = Date.now() - segT0;
        if (segMs > this.maxSegMs) { this.maxSegMs = segMs; }
        if (progress !== undefined) {
          progress(Math.min(99, Math.floor(pos * 100 / size)), '正在解析切片路径…');
        }
        await yieldToUi();
      }
      if (carry.length > 0) { this.processLine(carry, 0, carry.length); }
    } finally {
      fs.closeSync(f);
    }
    if (seq !== this.loadSeq) { return false; }
    this.endParse();
    this.reportUnknownFeatures();
    this.updateBudgets();
    this.logAuxLines();
    this.loaded = this.layZ.length > 0;
    hilog.info(0x0000, 'GcodeToolpath',
      'gcode 主线程兜底解析完成：单块最长 %{public}dms · 层数=%{public}d', this.maxSegMs, this.layZ.length);
    return this.loaded;
  }

  // 复位所有解析产物（load 开始时调用）。与旧 load() 开头的复位完全一致。
  private resetParseState(): void {
    this.generation++;
    this.loaded = false;
    this.segCount = 0;
    this.ptCount = 0;
    this.runCount = 0;
    this.ptCap = 0;
    this.runCap = 0;
    this.ptXY = new Float32Array(0);
    this.runStart = new Int32Array(0);
    this.runLen = new Int32Array(0);
    this.runRole = new Uint8Array(0);
    this.runW = new Float32Array(0);
    this.layRunStart = [];
    this.layZ = [];
    this.layH = [];
    this.layHMark = [];
    this.statText = '';
    this.presentRoles = [];
    this.rawSegCount = 0;
    this.roleSegCount = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    this.polyOn = false;
    this.polyPts = [];
    this.unknownNames = [];
    this.unknownCounts = [];
    this.maxSegMs = 0;
  }

  // 解析完成后的统计 + 单层顶点预算核算：算出哪几层顶点数超过 MAX_VERTS_PER_LAYER
  // （这些层在 buildLayer 里整层跳过）。同时把「简化后段数 / 是否有整层跳过」写回
  // statText，供控制层顶栏显示。
  private updateBudgets(): void {
    let over: number = 0;
    for (let li: number = 0; li + 1 < this.layRunStart.length; li++) {
      const r0: number = this.layRunStart[li];
      const r1: number = this.layRunStart[li + 1];
      let pts: number = 0;
      for (let r: number = r0; r < r1; r++) { pts += this.runLen[r]; }
      // 每点 4 个顶点（上排 2 + 下排 2），与 buildLayer 的核算口径一致
      if (pts * 4 > MAX_VERTS_PER_LAYER) { over++; }
    }
    // 每层层厚 = 该层的「真实层高」：带条的上表面在 y = z、下表面在 y = z − h，
    // 只要 h 取真实层高，本层底面 (z − h) 就恰好落在上一层顶面，层与层在高度方向首尾相接
    // （贴合）→ 平行/水平视角不再从缝里透光。**层高必须等于真实层高，否则水平看会透光。**
    // 取值优先级：
    //   1) gcode 的 "; LAYER_HEIGHT:"（切片器算好的真实层高，自适应层高也准确；实测本样本
    //      998 层各一条 = 0.2mm）；
    //   2) 本层 z − 上一层 z（层高标记缺失时的等价推算，实测也等于 0.2mm）；
    //   3) 都没有（第 0 层无上一层可参照 / z ≤ 0）留 0，由 addRibbon 回退到默认层高。
    //   —— 这两条都直接来自切片结果，所以「准备」页改了层高再切片，这里会跟着变。
    const lh: number[] = [];
    for (let i: number = 0; i < this.layZ.length; i++) {
      let d: number = 0;
      const mk: number = i < this.layHMark.length ? this.layHMark[i] : 0;
      if (mk > 0) {
        d = mk;
      } else if (i > 0 && this.layZ[i] > 0 && this.layZ[i - 1] > 0) {
        const dv: number = this.layZ[i] - this.layZ[i - 1];
        if (dv > 0) { d = dv; }
      }
      lh.push(d);
    }
    this.layH = lh;
    hilog.info(0x0000, 'GcodeToolpath',
      'toolpath: %{public}d raw segs -> %{public}d pts / %{public}d segs (runs %{public}d, over-budget layers %{public}d)',
      this.rawSegCount, this.ptCount, this.segCount, this.runCount, over);
    // 整层跳过是真实告警（这些层根本不显示，既不是灰也不是缺色），也搬进应用日志便于真机查看
    if (over > 0) {
      AppLog.note('GcodeToolpath|layerSkip',
        `顶点超预算被整层跳过：${over} 层（整层不显示，与「变灰」是两回事）`);
    }
    let extra: string = `${(this.segCount / 10000).toFixed(1)}万段`;
    if (over > 0) { extra += ` · ${over}层超限跳过`; }
    this.statText = this.statText.length > 0 ? `${this.statText} · ${extra}` : extra;
  }

  private parseHeader(text: string): void {
    let layers: number = 0;
    let filament: string = '';
    let time: string = '';
    const cut: number = Math.min(text.length, 6000);
    let p: number = 0;
    while (p < cut) {
      let e: number = text.indexOf('\n', p);
      if (e < 0 || e > cut) { e = cut; }
      const line: string = text.substring(p, e).trim();
      if (line.indexOf('total layer number:') >= 0) {
        const v: number = Number.parseInt(line.substring(line.indexOf(':') + 1).trim(), 10);
        layers = Number.isNaN(v) ? 0 : v;
      } else if (line.indexOf('total filament length [mm]') >= 0) {
        filament = line.substring(line.lastIndexOf(':') + 1).trim();
      } else if (line.indexOf('printing time') >= 0) {
        time = line.substring(line.lastIndexOf('=') + 1).trim();
        if (time.length === 0) { time = line.substring(line.lastIndexOf(':') + 1).trim(); }
      }
      p = e + 1;
    }
    let s: string = '';
    if (layers > 0) { s += `${layers} 层`; }
    if (filament.length > 0) { s += (s.length > 0 ? ' · ' : '') + `${filament} mm`; }
    if (time.length > 0) { s += (s.length > 0 ? ' · ' : '') + time; }
    this.statText = s;
  }

  // 解析开始前的初始化：把原 parse() 里的「局部变量」与「起始层」一次设置好。
  private beginParse(): void {
    this.pRole = 9;
    this.pCurW = 0.42;
    this.pX = 0;
    this.pY = 0;
    this.pHasPos = false;
    this.pRel = false;
    this.pCond = 0;
    this.pUsed = [];
    for (let i: number = 0; i < ROLE_LABEL.length; i++) { this.pUsed.push(false); }
    // 起始 G-code 层：拓竹在模型第一个 "; CHANGE_LAYER" 之前，会先打印整段 machine_start_gcode
    // （喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线；整段被 libslic3r 标成 "; FEATURE: Custom"）。
    // 这些线都是第一层高度（Z≈0.2）的真实挤出，未导入模型、只切片时也在板前端打出来。
    // 现改为：解析一开始就开一层；起始段挤出直接归入这一层，待第一个 CHANGE_LAYER 到来时与
    // 模型第 1 层【合并】（两者物理同层）。
    this.pLayerIdx = 0;
    this.pStartMerged = false;
    this.layRunStart.push(this.runCount);
    this.layZ.push(0);
    this.layHMark.push(0);
  }

  // 处理 text 中所有以 '\n' 结尾的「完整行」；返回「未处理完的尾部」在 text 中的起点（作为跨块 carry）。
  // 逐行按下标扫描：不 split、不建临时行对象；角色/坐标/层状态跨块保留在 pXxx 字段里。
  private parseCompleteLines(text: string): number {
    let lineStart: number = 0;
    while (true) {
      const nl: number = text.indexOf('\n', lineStart);
      if (nl < 0) { break; }
      this.processLine(text, lineStart, nl);
      lineStart = nl + 1;
    }
    return lineStart;
  }

  // 处理一行（text[lineS, lineE) 为行内容，不含结尾换行）。逻辑与旧 parse() 的行体逐字节一致：
  // 只是把「整份文本里的绝对下标」换成「本行在 text 里的下标」——所有搜索/取数依旧严格限定在本行内，
  // 因此逐行处理与一次性扫全文的结果完全相同。
  private processLine(text: string, lineS: number, lineE: number): void {
    let s: number = lineS;
    while (s < lineE) {
      const c: number = text.charCodeAt(s);
      if (c === 32 || c === 9 || c === 13) { s++; } else { break; }
    }
    let t: number = lineE;
    while (t > s) {
      const c: number = text.charCodeAt(t - 1);
      if (c === 32 || c === 9 || c === 13) { t--; } else { break; }
    }
    if (s >= t) { return; }

    const c0: number = text.charCodeAt(s);
    // M622 … M623 条件宏：整块跳过（与 GcodeParseWorker 同一处判定，两个解析器行为必须一致）。
    // 条件为假时机器不执行块内移动，而紧随其后的 G2/G3 的 I/J 仍按真实起点计算 ——
    // 起点被挪走会画出巨大的假圆弧（真机表现为路径预览里多出半圆）。
    if (c0 === 77) {   // 'M'
      const is622: boolean = matchAt(text, s, t, 'M622')
        && !(s + 4 < t && text.charCodeAt(s + 4) === 46);   // 排除 M622.1
      const is623: boolean = matchAt(text, s, t, 'M623');
      if (this.pCond > 0) {
        if (is622) { this.pCond++; } else if (is623) { this.pCond--; }
        return;
      }
      if (is622) {
        this.pCond = 1;
        return;
      }
    }
    if (this.pCond > 0) { return; }
    if (c0 === 59) {                       // ';' 注释
      if (findIn(text, s, t, 'CHANGE_LAYER') >= 0) {
        // 换层边界：先把上一层的折线收尾（禁止跨层合并成一条折线）
        this.flushRun();
        if (!this.pStartMerged) {
          // 起始 G-code 段与模型第 1 层物理同层（都在 Z≈0.2）：直接合并进已开的第 0 层，
          // 不新开一层（否则总层数会比 gcode 头里的 "total layer number" 多 1，层滑条对不上）。
          this.pStartMerged = true;
        } else if (this.layZ.length < MAX_LAYERS) {
          this.layRunStart.push(this.runCount);
          this.layZ.push(0);
          this.layHMark.push(0);
          this.pLayerIdx = this.layZ.length - 1;
        } else {
          this.pLayerIdx = -1;
        }
      } else {
        const az = findIn(text, s, t, 'Z_HEIGHT:');
        if (az >= 0 && this.pLayerIdx >= 0 && this.layZ[this.pLayerIdx] === 0) {
          let q: number = az + 9;
          while (q < t && text.charCodeAt(q) === 32) { q++; }
          const v: number = numAt(text, q, t);
          if (v > 0) { this.layZ[this.pLayerIdx] = v; }
        } else {
          // 层高标记：Bambu 在每个 CHANGE_LAYER 之后紧跟 "; Z_HEIGHT: <顶面 z>" 与
          // "; LAYER_HEIGHT: <本层层高>"（实测 998 层各一条，另有约 340 条散落在多挤出机/
          // 分段打印处）。层高必须等于真实层高，否则相邻层在高度方向留缝、水平看就透光，
          // 所以这里优先采用切片器给出的真实层高；只取「本层第一条」（紧跟 Z_HEIGHT 的那条），
          // 同层后续重复出现的一律忽略，避免把中途层高误当整层层高。
          const ah: number = findIn(text, s, t, 'LAYER_HEIGHT:');
          if (ah >= 0) {
            if (this.pLayerIdx >= 0 && this.layHMark[this.pLayerIdx] === 0) {
              let q: number = ah + 13;                       // 'LAYER_HEIGHT:' 共 13 字符
              while (q < t && text.charCodeAt(q) === 32) { q++; }
              const v: number = numAt(text, q, t);
              if (v > 0.01 && v < 5) { this.layHMark[this.pLayerIdx] = v; }
            }
          } else {
            const aw: number = findIn(text, s, t, 'LINE_WIDTH:');
            if (aw >= 0) {
              let q: number = aw + 11;
              while (q < t && text.charCodeAt(q) === 32) { q++; }
              const v: number = numAt(text, q, t);
              if (v > 0.05 && v < 3) { this.pCurW = v; }
            } else {
              const af: number = findIn(text, s, t, 'FEATURE:');
              if (af >= 0) {
                let q: number = af + 8;
                while (q < t && text.charCodeAt(q) === 32) { q++; }
                const r: number = roleOfName(text, q, t);
                if (r < 0) {
                  // 未识别的 feature：暂归「其他」，并记名去重，解析结束后统一告警。
                  // 绝不静默归零/吞掉——否则又变成"靠猜"，以后日志能直接点名。
                  this.pRole = 9;
                  this.noteUnknownFeature(text.substring(q, t));
                } else {
                  this.pRole = r;
                }
              }
            }
          }
        }
      }
    } else if (c0 === 71 && s + 2 < t) {   // 'G'
      const c1: number = text.charCodeAt(s + 1);
      const c2: number = text.charCodeAt(s + 2);
      if (c1 === 57 && (c2 === 48 || c2 === 49)) {   // G90 绝对 / G91 相对
        this.pRel = (c2 === 49);
        return;
      }
      // G0 与 G1 在本 gcode flavor（marlin/Bambu，见 gcode_flavor=marlin）里是等价的直线运动：
      // 是否挤出只看有没有正的 E。起始 G-code 段（Custom 辅助线）大量用 G0 写挤出
      // （如 "G0 X240 E15"、"G0 X185.000 E9.35441"），若只认 G1，喷嘴载入线/擦拭线会整条漏掉，
      // 因此这里把 G0 与 G1 同等对待；G2/G3 仍是圆弧。
      if ((c1 === 48 || c1 === 49 || c1 === 50 || c1 === 51) && c2 === 32 && this.pLayerIdx >= 0) {
        const isArc: boolean = (c1 === 50 || c1 === 51);
        const isCw: boolean = (c1 === 50);
        let hasX: boolean = false;
        let hasY: boolean = false;
        let hasI: boolean = false;
        let nx: number = 0;
        let ny: number = 0;
        let ni: number = 0;
        let nj: number = 0;
        let hasE: boolean = false;
        let ePos: boolean = false;

        let i: number = s + 3;
        while (i < t) {
          while (i < t && text.charCodeAt(i) === 32) { i++; }
          if (i >= t) { break; }
          const letter: number = text.charCodeAt(i);
          let j: number = i + 1;
          while (j < t && text.charCodeAt(j) !== 32) { j++; }
          if (j > i + 1) {
            if (letter === 88) { nx = numAt(text, i + 1, j); hasX = true; }
            else if (letter === 89) { ny = numAt(text, i + 1, j); hasY = true; }
            else if (letter === 73) { ni = numAt(text, i + 1, j); hasI = true; }
            else if (letter === 74) { nj = numAt(text, i + 1, j); }
            else if (letter === 69) {
              hasE = true;
              if (numAt(text, i + 1, j) > 0) { ePos = true; }
            }
          }
          i = j;
        }

        if (hasX || hasY) {
          // G91 相对模式下 X/Y 是增量（起始 G-code 的擦嘴/刷板段整个是相对坐标）
          const tx: number = hasX ? (this.pRel ? this.pX + nx : nx) : this.pX;
          const ty: number = hasY ? (this.pRel ? this.pY + ny : ny) : this.pY;
          if (!this.pHasPos) {
            this.pX = tx; this.pY = ty; this.pHasPos = true;
          } else {
            if (hasE && ePos) {
              // ★「辅助线」档已按需求整体删除（与 GcodeParseWorker 同一处判定，两个解析器
              //   行为必须一致）：机器启动 G-code 的辅助挤出（; FEATURE: Custom —— 喷嘴载入线 /
              //   动态流量校准线 / 擦嘴清洗线）不进几何、不进 pUsed（图例据此不显示该档）。
              //   熨烫已并入「顶面」档（同一颜色），不再需要在这里排除。
              if (this.pRole !== ROLE_AUX_LINE) {
                if (isArc && hasI) {
                  this.pushArc(this.pX, this.pY, tx, ty, ni, nj, this.pRole, this.pCurW, isCw);
                } else {
                  this.emitSeg(this.pX, this.pY, tx, ty, this.pRole, this.pCurW);
                }
                this.pUsed[this.pRole] = true;
              }
            } else {
              // 空驶（只动 XY、不挤出）：路径在这里断开，当前连续折线必须收尾
              this.flushRun();
            }
            this.pX = tx;
            this.pY = ty;
          }
        } else if (hasE && !ePos) {
          // 纯回抽（只改 E 且为负，不移动）：同样断开当前折线
          this.flushRun();
        }
      }
    }
  }

  // 解析收尾：文件末尾收尾当前折线、补上末尾层边界、汇总「出现过的角色」。
  private endParse(): void {
    this.flushRun();                       // 文件末尾：把最后一条折线收尾
    this.layRunStart.push(this.runCount);
    const present: number[] = [];
    for (let r: number = 0; r < ROLE_LABEL.length; r++) {
      if (this.pUsed[r]) { present.push(r); }
    }
    this.presentRoles = present;
  }

  // 记一条未识别的 feature 名（去重累加次数；未知名一般只有个位数，线性扫足够）
  private noteUnknownFeature(name: string): void {
    for (let i: number = 0; i < this.unknownNames.length; i++) {
      if (this.unknownNames[i] === name) {
        this.unknownCounts[i] = this.unknownCounts[i] + 1;
        return;
      }
    }
    this.unknownNames.push(name);
    this.unknownCounts.push(1);
  }

  // 解析结束后，把未识别的 feature 名逐条告警（tag: GcodeFeature）。
  // 例：未识别 feature: "Some new wall" 已出现 37 次 → 暂归其他
  // 同时写一份到「应用日志」页（用户在设备上直接可见）；按名字去重，同名只占一条并累计次数。
  private reportUnknownFeatures(): void {
    for (let i: number = 0; i < this.unknownNames.length; i++) {
      hilog.warn(0x0000, 'GcodeFeature',
        '未识别 feature: "%{public}s" 已出现 %{public}d 次 → 暂归其他',
        this.unknownNames[i], this.unknownCounts[i]);
      AppLog.note(`GcodeFeature|${this.unknownNames[i]}`,
        `未识别 feature: "${this.unknownNames[i]}" 已出现 ${this.unknownCounts[i]} 次 → 暂归其他`);
    }
  }

  // 切片 gcode 辅助线自证（hilog + AppLog）：写明 来源=切片gcode 与实测条数/坐标范围。
  // 每解析一份 gcode 只报一条，便于直接断案「板前端那些线到底有没有进几何」。
  private logAuxLines(): void {
    const text: string = formatAuxStats(this.auxLineStats(), '切片gcode');
    hilog.info(0x0000, 'GcodeAuxLine', '%{public}s', text);
    AppLog.note('GcodeAuxLine', text);
  }

  // 切片 gcode 里辅助线（role=10）的真实统计：折线条数、挤出段数、X/Y 范围。
  // 全部从解析结果（runRole/runLen/ptXY）实测，不做任何估算；没有就是 has=false。
  auxLineStats(): AuxLineStats {
    const st: AuxLineStats = new AuxLineStats();
    let first: boolean = true;
    for (let r: number = 0; r < this.runCount; r++) {
      if (this.runRole[r] !== ROLE_AUX_LINE) { continue; }
      st.has = true;
      st.runCount++;
      st.segCount += this.runLen[r] - 1;
      const base: number = this.runStart[r];
      for (let i: number = 0; i < this.runLen[r]; i++) {
        const px: number = this.ptXY[(base + i) * 2];
        const py: number = this.ptXY[(base + i) * 2 + 1];
        if (first) {
          st.xMin = px; st.xMax = px; st.yMin = py; st.yMax = py; first = false;
        } else {
          if (px < st.xMin) { st.xMin = px; } else if (px > st.xMax) { st.xMax = px; }
          if (py < st.yMin) { st.yMin = py; } else if (py > st.yMax) { st.yMax = py; }
        }
      }
    }
    return st;
  }

  // 生成 [GcodeDiag] 诊断块的前三行（层数/段数、角色分布、未识别 feature）。
  // 所有数字都是解析时的真实计数（绝不估算），用来把「灰」的两种成因区分开：
  //   · 「其他」段数偏多  → feature 映射问题（未识别被兜到「其他」）；
  //   · 「其他」段数很少  → 更像配色表/下标问题（另见调用方的配色表与材质越界两行）。
  diagLines(): string[] {
    const lines: string[] = [];
    lines.push(`[GcodeDiag] 层数=${this.layZ.length} 段数=${this.segCount}`);
    let dist: string = '';
    for (let r: number = 0; r < ROLE_LABEL.length; r++) {
      dist += `${ROLE_LABEL[r]} ${this.roleSegCount[r]}`;
      if (r + 1 < ROLE_LABEL.length) { dist += ' / '; }
    }
    lines.push(`[GcodeDiag] 角色分布：${dist}`);
    let unk: string = '无';
    if (this.unknownNames.length > 0) {
      unk = '';
      for (let i: number = 0; i < this.unknownNames.length; i++) {
        unk += `${this.unknownNames[i]}×${this.unknownCounts[i]}`;
        if (i + 1 < this.unknownNames.length) { unk += '，'; }
      }
    }
    lines.push(`[GcodeDiag] 未识别 feature：${unk}`);
    // 机器起始 G-code 辅助线（role=10）的真实统计：证明这些线确实被解析进来了，
    // 而不是「按板尺寸推导」——条数/段数/坐标范围全部实测自本份 gcode。
    lines.push(`[GcodeDiag] ${formatAuxStats(this.auxLineStats(), '切片gcode')}`);
    // 配色表 + 「实际用于渲染的材质下标」：一条线把 role → 图例 hex → slot → roleMats 下标 →
    // 线性 rgb 全摆出来。图例读 hex、渲染读 roleMats，两者都由同一张 ROLE_COLOR_HEX 派生；
    // 只要这里某一档的 rgb 与 hex 对不上、或非「其他」档呈现灰色，就是「下标合法却取到错色」
    // 的直接证据，无需连设备抓帧。
    let pal: string = '';
    for (let r: number = 0; r < ROLE_LABEL.length; r++) {
      pal += `${r} 「${ROLE_LABEL[r]}」 hex=${ROLE_COLOR_HEX[r]} slot=${r + 1} mats[${r}] rgb=`;
      if (r < ROLE_RGB.length && ROLE_RGB[r].length === 3) {
        pal += `${ROLE_RGB[r][0].toFixed(2)},${ROLE_RGB[r][1].toFixed(2)},${ROLE_RGB[r][2].toFixed(2)}`;
      } else {
        pal += '?';
      }
      if (r + 1 < ROLE_LABEL.length) { pal += ' | '; }
    }
    lines.push(`[GcodeDiag] 配色表/渲染材质下标：${pal}`);
    const probs: string[] = paletteProblems();
    lines.push(`[GcodeDiag] 配色表自检：${probs.length === 0 ? '通过（除「其他」外无灰档，图例与渲染同源）' : probs.join('；')}`);
    return lines;
  }

  // G2/G3：圆心相对起点 (I,J)
  private pushArc(x0: number, y0: number, x1: number, y1: number, i: number, j: number,
                 role: number, w: number, cw: boolean): void {
    const cx: number = x0 + i;
    const cy: number = y0 + j;
    const r: number = Math.sqrt(i * i + j * j);
    if (r < 0.0001) {
      this.emitSeg(x0, y0, x1, y1, role, w);
      return;
    }
    // 自洽性闸门：I/J 是相对起点的圆心偏移，终点也必须落在同一个圆上。
    // 端点偏离圆（>1% 或 >0.05mm）说明起点不可信 —— 按 2π 归一插值会画出巨大的假圆弧
    // （真机表现：路径预览里多出莫名其妙的半圆）。此时退化成直线段，绝不臆造。
    const r1: number = Math.sqrt((x1 - cx) * (x1 - cx) + (y1 - cy) * (y1 - cy));
    if (Math.abs(r1 - r) > Math.max(0.05, r * 0.01)) {
      this.emitSeg(x0, y0, x1, y1, role, w);
      return;
    }
    let a0: number = Math.atan2(y0 - cy, x0 - cx);
    let a1: number = Math.atan2(y1 - cy, x1 - cx);
    const full: boolean = Math.abs(x1 - x0) < 1e-6 && Math.abs(y1 - y0) < 1e-6;
    if (full) {
      a1 = a0 + (cw ? -2 * Math.PI : 2 * Math.PI);
    } else if (cw) {
      while (a1 > a0) { a1 -= 2 * Math.PI; }
    } else {
      while (a1 < a0) { a1 += 2 * Math.PI; }
    }
    const steps: number = Math.max(2, Math.min(24, Math.ceil(Math.abs(a1 - a0) * r * 2)));
    let px: number = x0;
    let py: number = y0;
    for (let s = 1; s <= steps; s++) {
      const a: number = a0 + (a1 - a0) * (s / steps);
      const qx: number = cx + r * Math.cos(a);
      const qy: number = cy + r * Math.sin(a);
      this.emitSeg(px, py, qx, qy, role, w);
      px = qx;
      py = qy;
    }
  }

  // ---- 在线「保形折线简化」+ 累积 ----
  // 一次挤出移动 (x0,y0)→(x1,y1) 到来时：
  //   1) 角色变化 / 线宽变化 / 与前一段不接续 → 当前折线收尾，从 (x0,y0) 另起一条；
  //   2) 否则把新点 (x1,y1) 并进当前折线，并在并入时做共线简化。
  // 折线的首点与末点永远保留，所以一层内的连通性不会被简化破坏（不会出现断开的线头）。
  private emitSeg(x0: number, y0: number, x1: number, y1: number, role: number, w: number): void {
    this.rawSegCount++;
    const n2: number = this.polyPts.length;
    if (this.polyOn && role === this.polyRole && this.widthSame(w) && n2 >= 4
        && Math.abs(x0 - this.polyPts[n2 - 2]) <= CONTIG_TOL_MM
        && Math.abs(y0 - this.polyPts[n2 - 1]) <= CONTIG_TOL_MM) {
      this.addPoint(x1, y1);
      return;
    }
    this.flushRun();
    this.polyOn = true;
    this.polyRole = role;
    this.polyW = w;
    this.polyPts.push(x0, y0, x1, y1);
  }

  // 线宽与当前折线是否算「同一条」（相对差 ≤ WIDTH_CHANGE_RATIO）；差太多就断开分别建，
  // 保证每条折线只用它自己的线宽。
  private widthSame(w: number): boolean {
    if (this.polyW <= 0) { return true; }
    return Math.abs(w - this.polyW) <= WIDTH_CHANGE_RATIO * this.polyW;
  }

  // 并入一个新点，并做「保形共线简化」：
  // 若当前末尾点 B 到它前一个保留点 A 与新点 C 连线的垂距 < SIMPLIFY_TOL_MM，
  // 就丢弃 B（A→B→C 合成 A→C）；可连续丢多个中间点，但折线至少保留首点与末点。
  private addPoint(px: number, py: number): void {
    while (this.polyPts.length >= 4) {
      const n2: number = this.polyPts.length;
      const bx: number = this.polyPts[n2 - 2];
      const by: number = this.polyPts[n2 - 1];
      const ax: number = this.polyPts[n2 - 4];
      const ay: number = this.polyPts[n2 - 3];
      if (!this.perpTol(ax, ay, bx, by, px, py)) { break; }
      this.polyPts.pop();
      this.polyPts.pop();
    }
    this.polyPts.push(px, py);
  }

  // 点 B 到直线 A→C 的垂距是否 < 容差（A≈C 退化时按点距判）
  private perpTol(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): boolean {
    const vx: number = cx - ax;
    const vy: number = cy - ay;
    const l2: number = vx * vx + vy * vy;
    if (l2 < 1e-12) {
      const dx: number = bx - ax;
      const dy: number = by - ay;
      return Math.sqrt(dx * dx + dy * dy) < SIMPLIFY_TOL_MM;
    }
    const cross: number = vx * (by - ay) - vy * (bx - ax);
    return Math.abs(cross) < SIMPLIFY_TOL_MM * Math.sqrt(l2);
  }

  // 把当前折线固化成一个 run（写入扁平存储），然后清空滚动状态。
  // 几何不在这里建：解析阶段只做简化与统计（presentRoles / segCount 都以简化后为准），
  // buildLayer 再按层取 run 建带状面片。
  private flushRun(): void {
    if (!this.polyOn) {
      this.polyPts = [];
      return;
    }
    const np: number = this.polyPts.length >> 1;
    this.polyOn = false;
    if (np >= 2) {
      this.pushRun(this.polyPts, np, this.polyRole, this.polyW);
    }
    this.polyPts = [];
  }

  // 把一条折线的点追加进扁平存储（ptXY + run 元数据），并把它的段数计入 segCount
  private pushRun(pts: number[], np: number, role: number, w: number): void {
    if (this.ptCount + np > this.ptCap) { this.growPts(this.ptCount + np); }
    if (this.runCount >= this.runCap) { this.growRuns(); }
    const base: number = this.ptCount;
    for (let i: number = 0; i < np; i++) {
      this.ptXY[(base + i) * 2] = pts[i * 2];
      this.ptXY[(base + i) * 2 + 1] = pts[i * 2 + 1];
    }
    this.ptCount += np;
    this.runStart[this.runCount] = base;
    this.runLen[this.runCount] = np;
    this.runRole[this.runCount] = role;
    this.runW[this.runCount] = w;
    this.runCount++;
    this.segCount += np - 1;
    // 角色分布的真实计数：只累计「简化后的段数」，与 segCount 同口径（两者对得上才算统计可信）
    if (role >= 0 && role < this.roleSegCount.length) {
      this.roleSegCount[role] += np - 1;
    }
  }

  private growPts(need: number): void {
    let nc: number = this.ptCap === 0 ? 65536 : this.ptCap;
    while (nc < need) { nc *= 2; }
    const xy: Float32Array = new Float32Array(nc * 2);
    xy.set(this.ptXY.subarray(0, this.ptCount * 2));
    this.ptXY = xy;
    this.ptCap = nc;
  }

  private growRuns(): void {
    const nc: number = this.runCap === 0 ? 8192 : this.runCap * 2;
    const rs: Int32Array = new Int32Array(nc);
    rs.set(this.runStart.subarray(0, this.runCount));
    this.runStart = rs;
    const rl: Int32Array = new Int32Array(nc);
    rl.set(this.runLen.subarray(0, this.runCount));
    this.runLen = rl;
    const rr: Uint8Array = new Uint8Array(nc);
    rr.set(this.runRole.subarray(0, this.runCount));
    this.runRole = rr;
    const rw: Float32Array = new Float32Array(nc);
    rw.set(this.runW.subarray(0, this.runCount));
    this.runW = rw;
    this.runCap = nc;
  }

  get layerCount(): number { return this.layZ.length; }
  get totalSegments(): number { return this.segCount; }

  layerZAt(i: number): number {
    if (i < 0 || i >= this.layZ.length) { return 0; }
    return this.layZ[i];
  }

  // ---- 生成带状面片网格 ----
  // 只建「某一层」的网格，按「角色」分成若干块（slot = role + 1）。
  // 刻意不提供「一次建到当前层」：滑层要实时，几何必须每层只建一次、之后靠切可见性，
  // 每动一格就重建两万段几何是不可能实时的（而且新旧几何重合还会闪）。
  buildLayer(li: number, plateW: number, plateH: number): GcodeMeshPart[] {
    const out: GcodeMeshPart[] = [];
    if (this.runCount === 0 || this.layRunStart.length < 2) { return out; }
    if (li < 0 || li >= this.layZ.length) { return out; }

    const r0: number = this.layRunStart[li];
    const r1: number = this.layRunStart[li + 1];
    if (r1 <= r0) { return out; }

    // 顶点预算兜底：单层顶点数异常巨大时「整层跳过」。
    // 绝不按索引在层内挑段——层内挑段会把连续的墙打断成碎线（这正是老 bug 的成因）。
    // 每点 4 个顶点（上排 2 + 下排 2），与 updateBudgets 的核算口径一致。
    let pts: number = 0;
    for (let r: number = r0; r < r1; r++) { pts += this.runLen[r]; }
    if (pts * 4 > MAX_VERTS_PER_LAYER) {
      hilog.warn(0x0000, 'GcodeToolpath',
        'layer %{public}d skipped: %{public}d verts over layer budget %{public}d',
        li, pts * 4, MAX_VERTS_PER_LAYER);
      return out;
    }

    const ox: number = plateW * 0.5;
    const oy: number = plateH * 0.5;
    const z: number = this.layZ[li];
    const h: number = this.layH.length > li ? this.layH[li] : 0;

    // 槽位 = 角色 + 1：同层同角色合成一块网格；下标 = slot - 1 = role。
    const buckets: (MeshGeometry | null)[] = [];
    for (let i: number = 0; i < ROLE_LABEL.length; i++) { buckets.push(null); }
    // 每一层都按全分辨率整层建：解析阶段已做保形折线简化（层内仍是连续折线），这里不再挑段
    for (let r: number = r0; r < r1; r++) {
      const slot: number = this.runRole[r] + 1;
      let g: MeshGeometry | null = buckets[slot - 1];
      if (g === null) {
        g = new MeshGeometry();
        buckets[slot - 1] = g;
      }
      this.addRibbon(g, this.runStart[r], this.runLen[r], this.runW[r], z, h, ox, oy);
    }

    for (let s = 0; s < buckets.length; s++) {
      const g: MeshGeometry | null = buckets[s];
      if (g !== null && g.vertices.length > 0) { out.push(new GcodeMeshPart(s + 1, g)); }
    }
    return out;
  }

  // 一条折线 → 有厚度的带条（顶点共享）：
  //   M 个有效点 → 4M 顶点 + 18(M-1) 索引；相邻段共用 4 个一组的顶点，
  //   相比老的四棱柱「8 顶点 + 18 索引 / 段」仍是数量级的下降。
  //   每个点 P_i 的偏移方向 = 角平分线法向（入向与出向单位向量之和再转 90°）；
  //   偏移长度按真斜接放大到 hw/|cos θ| 并夹在 MITER_LIMIT 以内；近似 180° 折返时
  //   改用段法向、长度不放大（见步骤 2 注释）。
  //   每点 4 个顶点：上排 2 个（y = z，顶面、半宽收窄到 hw×K_TOP）+ 下排 2 个
  //   （y = z - h，层底面、半宽 = hw），构成「上窄下宽的梯形」截面（见步骤 3 注释）。
  //   h = 该层层高，且 h 取「本层 z − 上一层 z」→ 本层底面恰好等于上一层顶面，
  //   所有层贴合，平行视角下没有整层高的缝（不透光）。
  //   顶面法线共用 UP_NORMAL；左右斜面各用倾斜法线 nLeft / nRight。
  private addRibbon(g: MeshGeometry, base: number, np: number, w: number,
                    z: number, h: number, ox: number, oy: number): void {
    // 层高兜底：第 0 层（没有上一层可参照）或异常值一律按 0.2mm
    if (!(h > 0)) { h = 0.2; }
    // 1) 去重：丢弃长度 ≈ 0 的退化段（< 1e-4mm），把有效点收进复用缓冲
    if (this.sx.length < np) {
      this.sx = new Float32Array(np);
      this.sy = new Float32Array(np);
      this.nx = new Float32Array(np);
      this.ny = new Float32Array(np);
    }
    let m: number = 0;
    for (let i: number = 0; i < np; i++) {
      const px: number = this.ptXY[(base + i) * 2];
      const py: number = this.ptXY[(base + i) * 2 + 1];
      if (m > 0) {
        const dx: number = px - this.sx[m - 1];
        const dy: number = py - this.sy[m - 1];
        if (dx * dx + dy * dy < 1e-8) { continue; }
      }
      this.sx[m] = px;
      this.sy[m] = py;
      m++;
    }
    if (m < 2) { return; }

    // 2) 逐点求平面内偏移向量：方向取角平分线法向，长度按真斜接缩放后夹取。
    //    但「近似 180° 折返」处角平分线退化、真斜接趋于无穷，必须走回退分支。
    const hw: number = w * 0.5;
    for (let i: number = 0; i < m; i++) {
      // 入向（i-1→i）与出向（i→i+1）的单位向量
      let dix: number = 0;
      let diy: number = 0;
      let hasIn: boolean = false;
      if (i > 0) {
        const ax: number = this.sx[i] - this.sx[i - 1];
        const ay: number = this.sy[i] - this.sy[i - 1];
        const al: number = Math.sqrt(ax * ax + ay * ay);
        if (al > 1e-9) { dix = ax / al; diy = ay / al; hasIn = true; }
      }
      let dox: number = 0;
      let doy: number = 0;
      let hasOut: boolean = false;
      if (i + 1 < m) {
        const bx: number = this.sx[i + 1] - this.sx[i];
        const by: number = this.sy[i + 1] - this.sy[i];
        const bl: number = Math.sqrt(bx * bx + by * by);
        if (bl > 1e-9) { dox = bx / bl; doy = by / bl; hasOut = true; }
      }

      let ux: number = 0;
      let uy: number = 0;
      if (hasIn && hasOut && (dix * dox + diy * doy) < REVERSE_DOT) {
        // 近似 180° 折返（锯齿填充两端就是这种）：角平分线退化、真斜接长度趋于无穷，
        // 照常做斜接会在每个折返点鼓出一个包（几十个包叠起来就是「糊」）。
        // 直接改用「出向」的垂直方向、偏移长度不放大，回退成普通等宽偏移，不再鼓包。
        ux = -doy;
        uy = dox;
      } else {
        let tax: number = 0;
        let tay: number = 0;
        if (hasIn) { tax += dix; tay += diy; }
        if (hasOut) { tax += dox; tay += doy; }
        const tl: number = Math.sqrt(tax * tax + tay * tay);
        if (tl < 1e-9) {
          // 完全退化（两端方向抵消）：用能拿到的那个方向的垂直方向，长度不放大
          if (hasOut) { ux = -doy; uy = dox; }
          else if (hasIn) { ux = -diy; uy = dix; }
          else { this.nx[i] = 0; this.ny[i] = 0; continue; }
        } else {
          // 角平分线的单位法向 N = rot90(T) = (-Ty, Tx)
          ux = -tay / tl;
          uy = tax / tl;
          // 真斜接（miter）：只沿 N 偏移 hw 只能保证「垂直于角平分线」处的宽度，
          // 急转弯时相邻两段的中心线在转角处靠得太近 → 面片折返自交、叠出一片本不存在的
          // 填充（正是"糊"的来源之一）。把偏移长度放大到 hw / |cos θ|（θ 为 N 与相邻段
          // 法向的夹角）即为相邻两段严格等距的真斜接；但 θ→90°（急转弯）时 1/|cos θ|→∞，
          // 会在尖角射出长刺，因此夹在 MITER_LIMIT 以内（超过就截断，牺牲一点点接缝）。
          const rx: number = hasOut ? dox : dix;   // 相邻段的单位走向（已是单位向量）
          const ry: number = hasOut ? doy : diy;
          if (rx * rx + ry * ry > 1e-18) {
            const snx: number = -ry;               // 相邻段的平面内法向
            const sny: number = rx;
            let cs: number = Math.abs(ux * snx + uy * sny);   // |cos θ|
            if (cs < 1e-6) { cs = 1e-6; }
            let k: number = 1 / cs;
            if (k > MITER_LIMIT) { k = MITER_LIMIT; }
            ux *= k;
            uy *= k;
          }
        }
      }
      this.nx[i] = ux;
      this.ny[i] = uy;
    }

    // 3) 顶点共享 + 索引：每点 4 个顶点（上排 2 + 下排 2），每段 4 个四边形 = 24 索引。
    //    截面是「上窄下宽的梯形」：下排半宽 = hw（真实线宽），上排半宽 = hwTop = hw × K_TOP。
    //    点 i 的顶点基址 p = vbase + i*4：
    //      p+0 上排左、p+1 上排右、p+2 下排左、p+3 下排右
    //    坐标：内容 x = 平面 x - ox；内容 z = -(平面 y - oy)；层高方向是内容 y。
    //    顶面在 y = z，底面在 y = z - h。
    //    【为什么必须补底面（闭合棱柱）：截面若只有顶面 + 两个斜面、没有底面，就是个开口壳，
    //      从下方/水平方向能看进壳内（还能看到上一层顶面的背面）→ 就是「透光/看穿」。
    //      补上底面后每段是一个闭合棱柱（实体），任何角度看都被不透明面挡住，不再穿透。】
    //    【省的做法：底面直接复用下排那 4 个顶点（p+2/p+3/q+2/q+3），不新增顶点，
    //      所以顶点数完全不变（仍是每点 4 个），只有索引由 18 → 24（+33%），
    //      GPU 压力几乎不涨——绝不能为了给底单独法线而把顶点数翻倍。】
    //    绕序（右手系交叉积 = 面法线，已用「沿内容 +x 的直段、h=1、hw=1、hwTop=0.55」验算：
    //      横向 L = (0,0,-1)；四个面的交叉积分别为 顶面 (0,+1.1,0)、左斜面 (0,+0.45,-1)、
    //      右斜面 (0,+0.45,+1)、底面 (0,-2hw*dx,0)，与各自期望法向一致）：
    //      顶面    (p0, p1, q0) / (q0, p1, q1)          → 法线 +y（朝上）
    //      左斜面  (p0, q0, p2) / (q0, q2, p2)          → 法线 = nLeft（朝 +L 且朝上）
    //      右斜面  (p1, p3, q1) / (q1, p3, q3)          → 法线 = nRight（朝 -L 且朝上）
    //      底面    (p2, q2, p3) / (p3, q2, q3)          → 法线 -y（朝下，共用下排顶点的斜面法线）
    //    其中 q = p + 4 是下一个点。
    const vbase: number = g.vertices.length;
    const zBot: number = z - h;
    const hwTop: number = hw * K_TOP;   // 上排（顶面）半宽：比真实半线宽窄
    const dTop: number = hw - hwTop;    // 斜面在横向上的「收进量」（> 0）
    for (let i: number = 0; i < m; i++) {
      const cx: number = this.sx[i] - ox;
      const cz: number = -(this.sy[i] - oy);
      const offx: number = this.nx[i] * hw;         // 下排：真实半线宽
      const offz: number = -this.ny[i] * hw;
      const offxTop: number = this.nx[i] * hwTop;   // 上排：收窄后的半宽
      const offzTop: number = -this.ny[i] * hwTop;
      // 平面内走向法向 (nx, ny) 归一化后在内容空间是 (lx, 0, -ny)：
      const nl: number = Math.sqrt(this.nx[i] * this.nx[i] + this.ny[i] * this.ny[i]);
      const inv: number = nl > 1e-9 ? 1 / nl : 1;
      const lx: number = this.nx[i] * inv;
      const lz: number = -this.ny[i] * inv;
      // 倾斜法线：斜面在「横向 L 与层高 Y」张成的平面内，其切线 = -dTop*L + h*Y，
      // 与它垂直、且朝外(+L)朝上(+Y)的方向就是 h*L + dTop*Y（已用上面的直段验算：
      // h*L + dTop*Y = (0,0,-1)*1 + (0,1,0)*0.45 = (0,0.45,-1)，与三角面法向一致）。
      // 每个点只新建 2 个 Vec3（左/右斜面各一），不做逐顶点新建；顶面复用 UP_NORMAL。
      const nxv: number = h * lx;
      const nyv: number = dTop;
      const nzv: number = h * lz;
      const sl: number = Math.sqrt(nxv * nxv + nyv * nyv + nzv * nzv);
      const sinv: number = sl > 1e-9 ? 1 / sl : 1;
      const nLeft: Vec3 = { x: nxv * sinv, y: nyv * sinv, z: nzv * sinv };
      const nRight: Vec3 = { x: -nxv * sinv, y: nyv * sinv, z: -nzv * sinv };
      g.vertices.push({ x: cx + offxTop, y: z, z: cz + offzTop },
                      { x: cx - offxTop, y: z, z: cz - offzTop },
                      { x: cx + offx, y: zBot, z: cz + offz },
                      { x: cx - offx, y: zBot, z: cz - offz });
      g.normals.push(UP_NORMAL, UP_NORMAL, nLeft, nRight);
    }
    for (let i: number = 0; i + 1 < m; i++) {
      const p: number = vbase + i * 4;
      const q: number = p + 4;
      g.indices.push(
        p, p + 1, q, q, p + 1, q + 1,             // 顶面
        p, q, p + 2, q, q + 2, p + 2,             // 左斜面（+L 侧）
        p + 1, p + 3, q + 1, q + 1, p + 3, q + 3, // 右斜面（-L 侧）
        p + 2, q + 2, p + 3, p + 3, q + 2, q + 3  // 底面（闭合！复用下排顶点，法线朝 -y）
      );
    }
  }
}

export const gcodeToolpath: GcodeToolpathStore = new GcodeToolpathStore();

// 组件间信号：模型页把自己的「重建路径 / 适应视图 / 视角操作」注册进来，控制层直接调用。
// 用回调而不是 AppStorage 状态变量，是因为滑块每动一格都改状态会让模型页整体重渲染。
// 视角操作也走这里：切片路径页是一层覆盖在场景上的 UI，覆盖层自己接管手势再转发，
// 不去赌 hitTestBehavior 能不能把手势穿透给下面的 Component3D。
export class GcodeSignals {
  rebuild: () => void = (): void => {};
  // 控制层（GcodePreview）进入切片路径时调用：请求模型页「自下而上逐层揭示」扫层动画。
  startSweep: () => void = (): void => {};
  fit: () => void = (): void => {};
  pan: (dx: number, dy: number) => void = (dx: number, dy: number): void => {};
  orbit: (dx: number, dy: number) => void = (dx: number, dy: number): void => {};
  zoom: (factor: number) => void = (factor: number): void => {};
  // 模型页 → 控制层：扫层进行中（含到顶后等几何补建的那一段）
  sweepState: (sweeping: boolean) => void = (sweeping: boolean): void => {};
  // 模型页 → 控制层：扫层当前揭示到第几层（让滑条跟着走）
  onSweepLayer: (layer: number) => void = (layer: number): void => {};
  // 控制层（GcodePreview）从「保活隐藏」切回来时调用（含两种隐藏：切到非 3D 页，或切到准备页 /
  // 预览页的模型态）：请求模型页确认切片路径几何是否仍在场。
  // 在 → 只恢复可见性（root.visible=true + 按 lastVisChunks 恢复层可见性，不重建、不重扫）；
  // 不在 → 自动降级为重建（绝不出现空白页）。
  // 注意：这里【不】按 gcodeShow 判定 —— 切回切片路径时控制层已把 gcodeShow 置回 true，语义上就该显示。
  resumeKeepAlive: () => void = (): void => {};
  // 右侧竖排盘列表（PlateList）在【切片路径态】被点击时转发到这里 → 控制层（GcodePreview）走既有
  // switchPlate(n)：写 AppStorage['activePlate']（准备页盘列表 / 模型页可见性据此同步）+ 直接 reload() 重载该盘几何。
  // 为什么绕一圈信号：切片路径页的盘列表渲染在覆盖层之上（PlateList 组件），而 switchPlate 是控制层的私有方法，
  // 用回调而不是让 PlateList 自己写 activePlate —— 后者不会触发控制层 reload，会出现「标签变了路径还是上一盘」。
  switchPlate: (n: number) => void = (n: number): void => {};
}

export const gcodeSignals: GcodeSignals = new GcodeSignals();

// =============================================================================
// 准备页：把「当前机器预设的启动 G-code」解析成板面辅助线几何（真值，不推导）
//
// 数据源：SlicerService.configSnapshot() 里的 machine_start_gcode（= 当前选中机型预设里
//   include 进来的 machine_start_gcode 模板原文，拓竹机器预设确实带这个字段，例如
//   "Bambu Lab X1 Carbon 0.4 nozzle template machine_start_gcode.json"）。
//
// 为什么要它：拓竹在打印前会在打印板最前端（Y 最小侧）打印喷嘴载入线 / 动态流量校准线 /
//   擦嘴清洗线；整段在 gcode 里被标成 "; FEATURE: Custom"，第一个 "; CHANGE_LAYER" 之前。
//   未导入模型时看不到模型层，但这段线是机器启动流程，任何一次打印都会打。
//
// 只取 X/Y/Z 的字面数字：模板占位符只出现在 E/F 值里（如 {outer_wall_volumetric_speed/(...)}），
//   X/Y 坐标全是字面值，所以这里无需（也不允许）给模板求值；取不到数字的量一律不参与。
// 与切片预览同一套判定：G0/G1 直线运动，只有「同时有 X 或 Y」且「E 为正」才算挤出段；
//   空驶 / 回抽 / 纯挤出（无 XY）都断开当前折线。
// 坐标口径与切片路径完全一致（见 addRibbon）：内容 X = gcode x − plateW/2，
//   内容 Z = −(gcode y − plateH/2)，高度方向为内容 Y（这里用该段真实 Z，兜底 0.09 防与网格 z-fighting）。
// =============================================================================

// 【为什么需要反转义】机器预设的 machine_start_gcode 是从内核 config 快照里取来的，而内核
// ConfigOptionString::serialize() = escape_string_cstyle()：换行被写成「反斜杠 + n」两个字面字符
// （\\ 与 \" 同理）。若直接拿去按行解析（indexOf('\n')），整段 gcode 在 JS 里没有任何真实换行 →
// 被当成「一整行」→ 一条 G0/G1 都解析不出来，现象就是「准备页辅助线恒为『无』，但图例里有这一档」
// （切片预览那份来自 output.gcode 文件、本身就是真换行，所以不受影响）。
// 这里按 C 风格规则逐字符反转义：\n→换行、\r→回车、\"→"、\\→\、其余 \x→x（与内核
// unescape_string_cstyle 的语义一致）。对本来就是真换行的字符串是幂等的（gcode 里没有反斜杠）。
export function unescapeCstyle(s: string): string {
  if (s.indexOf('\\') < 0) { return s; }
  let out: string = '';
  const n: number = s.length;
  for (let i: number = 0; i < n; i++) {
    const c: number = s.charCodeAt(i);
    if (c === 92 && i + 1 < n) {          // '\\'：与后一个字符组成转义序列
      i++;
      const d: number = s.charCodeAt(i);
      if (d === 110) { out += '\n'; }      // 'n' → 换行
      else if (d === 114) { out += '\r'; } // 'r' → 回车
      else { out += s.charAt(i); }         // '"' / '\\' / 其它 → 取原字符
    } else {
      out += s.charAt(i);
    }
  }
  return out;
}

// 板面细长条面片（X/Z 平面，法线朝上 +Y），与 buildGridLines 的 addBar 同一画法。
function addAuxBar(g: MeshGeometry, x0: number, z0: number, x1: number, z1: number,
                   w: number, yy: number): void {
  const dx: number = x1 - x0;
  const dz: number = z1 - z0;
  const l: number = Math.sqrt(dx * dx + dz * dz);
  if (l < 1e-6) { return; }
  const ux: number = dx / l;
  const uz: number = dz / l;
  const px: number = -uz * w * 0.5;
  const pz: number = ux * w * 0.5;
  const s: number = g.vertices.length;
  g.vertices.push(
    { x: x0 - px, y: yy, z: z0 - pz },
    { x: x1 - px, y: yy, z: z1 - pz },
    { x: x1 + px, y: yy, z: z1 + pz },
    { x: x0 + px, y: yy, z: z0 + pz }
  );
  for (let i: number = 0; i < 4; i++) { g.normals.push(UP_NORMAL); }
  g.indices.push(s, s + 1, s + 2, s, s + 2, s + 3);
}

export function buildStartGcodeLines(startGcodeRaw: string, plateW: number, plateH: number,
                                     st: AuxLineStats): MeshGeometry {
  const g: MeshGeometry = new MeshGeometry();
  // 【必须先反转义】内核 config 快照里的字符串是 C 风格转义（见 unescapeCstyle 注释）；
  // 不反转义 → 整段被当成一行 → 解析出 0 条挤出线（这就是准备页辅助线一直「无」的真因）。
  const startGcode: string = unescapeCstyle(startGcodeRaw);
  st.has = false;
  st.runCount = 0;
  st.segCount = 0;
  const ox: number = plateW * 0.5;
  const oy: number = plateH * 0.5;
  // 起始 G-code 段没有 "; LINE_WIDTH:" 标记 → 用 Bambu 标称线宽 0.42（与解析器默认一致）
  const W: number = 0.42;

  let x: number = 0;
  let y: number = 0;
  let z: number = 0.2;             // 该段真实 Z（未出现 Z 字时沿用上一个）
  let hasPos: boolean = false;
  let runX: number[] = [];
  let runY: number[] = [];
  let runZ: number = 0.2;
  let firstPt: boolean = true;

  const pushPt = (px: number, py: number): void => {
    runX.push(px);
    runY.push(py);
    if (firstPt) {
      st.xMin = px; st.xMax = px; st.yMin = py; st.yMax = py; firstPt = false;
      return;
    }
    if (px < st.xMin) { st.xMin = px; } else if (px > st.xMax) { st.xMax = px; }
    if (py < st.yMin) { st.yMin = py; } else if (py > st.yMax) { st.yMax = py; }
  };
  const flush = (): void => {
    if (runX.length >= 2) {
      st.has = true;
      st.runCount++;
      st.segCount += runX.length - 1;
      const yy: number = Math.max(0.09, runZ);
      for (let i: number = 0; i + 1 < runX.length; i++) {
        addAuxBar(g, runX[i] - ox, -(runY[i] - oy), runX[i + 1] - ox, -(runY[i + 1] - oy), W, yy);
      }
    }
    runX = [];
    runY = [];
  };

  const n: number = startGcode.length;
  let p: number = 0;
  while (p < n) {
    let e: number = startGcode.indexOf('\n', p);
    if (e < 0) { e = n; }
    // 行尾注释（';' 之后）不参与解析；模板占位符所在的分号注释放行尾时也不影响坐标
    const semi: number = startGcode.indexOf(';', p);
    let t: number = (semi >= 0 && semi < e) ? semi : e;
    let s: number = p;
    while (s < t) {
      const c: number = startGcode.charCodeAt(s);
      if (c === 32 || c === 9 || c === 13) { s++; } else { break; }
    }
    while (t > s) {
      const c: number = startGcode.charCodeAt(t - 1);
      if (c === 32 || c === 9 || c === 13) { t--; } else { break; }
    }
    if (s < t && startGcode.charCodeAt(s) === 71 && s + 2 < t) {   // 'G'
      const c1: number = startGcode.charCodeAt(s + 1);
      const c2: number = startGcode.charCodeAt(s + 2);
      if ((c1 === 48 || c1 === 49) && c2 === 32) {                 // G0 / G1（marlin 下等价直线运动）
        let nx: number = 0;
        let ny: number = 0;
        let nz: number = 0;
        let hasX: boolean = false;
        let hasY: boolean = false;
        let hasZ: boolean = false;
        let hasE: boolean = false;
        let ePos: boolean = false;
        let i: number = s + 3;
        while (i < t) {
          while (i < t && startGcode.charCodeAt(i) === 32) { i++; }
          if (i >= t) { break; }
          const letter: number = startGcode.charCodeAt(i);
          let j: number = i + 1;
          while (j < t && startGcode.charCodeAt(j) !== 32) { j++; }
          if (j > i + 1) {
            if (letter === 88) { nx = numAt(startGcode, i + 1, j); hasX = true; }
            else if (letter === 89) { ny = numAt(startGcode, i + 1, j); hasY = true; }
            else if (letter === 90) { nz = numAt(startGcode, i + 1, j); hasZ = true; }
            else if (letter === 69) {
              hasE = true;
              if (numAt(startGcode, i + 1, j) > 0) { ePos = true; }
            }
          }
          i = j;
        }
        if (hasZ && nz > 0) { z = nz; }
        if (hasX || hasY) {
          const tx: number = hasX ? nx : x;
          const ty: number = hasY ? ny : y;
          if (!hasPos) {
            x = tx; y = ty; hasPos = true;
          } else {
            if (hasE && ePos) {
              runZ = z;
              if (runX.length === 0) { pushPt(x, y); }
              pushPt(tx, ty);
            } else {
              flush();      // 空驶：断开当前折线
            }
            x = tx;
            y = ty;
          }
        } else if (hasE && !ePos) {
          flush();            // 纯回抽
        }
      }
    }
    p = e + 1;
  }
  flush();
  return g;
}
