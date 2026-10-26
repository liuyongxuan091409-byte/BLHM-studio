import fs from '@ohos.file.fs';
import { worker } from '@kit.ArkTS';
import { MessageEvents } from '@ohos.worker';
import { GcodeParseResult, GcodeWorkerRequest, GcodeWorkerResponse } from '../model/GcodeParseTypes';

// =============================================================================
// gcode 解析 Worker（独立线程）
//
// 【为什么必须开线程而不是在主线程分段】**主线程分段 + setTimeout 让帧仍然会被系统判为
// THREAD_BLOCK**：真机（9030s）实测，49.6MB / 约 170 万行的 gcode 在主线程上即使每 512KB 让帧，
// 主线程仍被高负载占满（单块最长 186ms，但整段 ~10s 期间几乎无空闲），AppFreeze 看门狗拿不到
// 心跳 → THREAD_BLOCK_3S/6S → 进程被杀。唯一稳的办法是把这份「读文件 + 逐行解析」整体搬离主线程。
//
// 本 Worker 在【独立线程】里：readTextSync 读整份文本 + 单遍逐行解析 → 产出「紧凑的层边界 +
// 扁平几何缓冲」（Float32Array / Int32Array / Uint8Array，避免在 JS 堆里建百万级小对象）→
// 用 transferable 零拷贝把缓冲交回主线程。主线程只做「接收 + 轻量收尾」，全程不阻塞。
//
// 解析逻辑与 model/GcodeToolpath.ets 的旧实现逐字节一致（同样的 FEATURE 角色映射、Z_HEIGHT /
// LAYER_HEIGHT / LINE_WIDTH、G0/G1/G2/G3、共线简化、折线收尾规则），只是状态从实例字段换成局部变量。
// =============================================================================

// 「辅助线」档（= ROLE_LABEL 末位）。该档已按需求删除（不再进几何/图例），
// 这里保留常量只为在角色映射处识别出它并丢弃对应段。
const ROLE_AUX_LINE: number = 10;
// 熨烫（ironing_type=top）：**并入「顶面」而不是丢弃**。
// 它与 Top surface 同一 Z、同一区域：单独成档会红/青交替 + 共面闪烁；
// 整档丢弃则会丢掉顶层 7 成以上的走线（实测 L13: ironing 4283mm vs top 1482mm），
// 预览里顶层变得坑坑洼洼、还能透出下一层 —— 看起来就是「红白交错 / 零零碎碎」。
const SIMPLIFY_TOL_MM: number = 0.01;   // 共线简化容差
const CONTIG_TOL_MM: number = 0.001;    // 折线连续性容差
const WIDTH_CHANGE_RATIO: number = 0.05; // 线宽变化阈值
const MAX_LAYERS: number = 4000;
const ROLE_COUNT: number = 11;

type NumberArray = number[];

// ---- 纯函数（与 GcodeToolpath 的同名实现逐字节一致）----
function findIn(s: string, from: number, to: number, lit: string): number {
  const last: number = to - lit.length;
  for (let i: number = from; i <= last; i++) {
    let ok: boolean = true;
    for (let k: number = 0; k < lit.length; k++) {
      if (s.charCodeAt(i + k) !== lit.charCodeAt(k)) { ok = false; break; }
    }
    if (ok) { return i; }
  }
  return -1;
}

function matchAt(s: string, at: number, end: number, lit: string): boolean {
  if (at + lit.length > end) { return false; }
  for (let i: number = 0; i < lit.length; i++) {
    if (s.charCodeAt(at + i) !== lit.charCodeAt(i)) { return false; }
  }
  return true;
}

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
    if (c === 101 || c === 69) {
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

function roleOfName(text: string, at: number, end: number): number {
  if (matchAt(text, at, end, 'Outer wall')) { return 0; }
  if (matchAt(text, at, end, 'Overhang wall')) { return 0; }
  if (matchAt(text, at, end, 'Inner wall')) { return 1; }
  if (matchAt(text, at, end, 'Sparse infill')) { return 2; }
  if (matchAt(text, at, end, 'Internal solid infill')) { return 3; }
  if (matchAt(text, at, end, 'Floating vertical shell')) { return 3; }
  if (matchAt(text, at, end, 'Top surface')) { return 4; }
  // 熨烫并进「顶面」（同一颜色）：单独成档会红青交替，整档丢弃会让顶层残缺。
  if (matchAt(text, at, end, 'Ironing')) { return 4; }
  if (matchAt(text, at, end, 'Bottom surface')) { return 5; }
  if (matchAt(text, at, end, 'Bridge')) { return 6; }
  if (matchAt(text, at, end, 'Support')) { return 7; }
  if (matchAt(text, at, end, 'Gap infill')) { return 8; }
  if (matchAt(text, at, end, 'Skirt')) { return 7; }
  if (matchAt(text, at, end, 'Brim')) { return 7; }
  if (matchAt(text, at, end, 'Prime tower')) { return 7; }
  if (matchAt(text, at, end, 'Flush')) { return 7; }
  if (matchAt(text, at, end, 'Custom')) { return ROLE_AUX_LINE; }
  if (matchAt(text, at, end, 'Multiple')) { return 9; }
  if (matchAt(text, at, end, 'Undefined')) { return 9; }
  return -1;
}

function parseHeader(text: string): string {
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
  return s;
}

// 单遍解析整份 gcode 文本 → 紧凑缓冲。逻辑与主线程旧 parse() 完全一致。
function parseAllText(text: string): GcodeParseResult {
  const n: number = text.length;

  // 扁平存储（先动态 grow，最后收敛成精确长度）
  let ptXY: Float32Array = new Float32Array(65536 * 2);
  let ptCap: number = 65536;
  let ptCount: number = 0;
  let runStart: Int32Array = new Int32Array(8192);
  let runLen: Int32Array = new Int32Array(8192);
  let runRole: Uint8Array = new Uint8Array(8192);
  let runW: Float32Array = new Float32Array(8192);
  let runCap: number = 8192;
  let runCount: number = 0;
  let segCount: number = 0;
  let rawSegCount: number = 0;
  const roleSegCount: NumberArray = new Array<number>(ROLE_COUNT).fill(0);
  const used: boolean[] = new Array<boolean>(ROLE_COUNT).fill(false);

  const layRunStartN: NumberArray = [];
  const layZN: NumberArray = [];
  const layHMarkN: NumberArray = [];

  // ---- 滚动状态（原实例字段 → 局部变量）----
  let polyPts: NumberArray = [];
  let polyOn: boolean = false;
  let polyRole: number = 9;
  let polyW: number = 0.42;

  let role: number = 9;
  let curW: number = 0.42;
  let x: number = 0;
  let y: number = 0;
  let hasPos: boolean = false;
  // 模态定位：G90 绝对（默认）/ G91 相对。不跟踪相对模式的话，起始 G-code 里的
  // 相对擦嘴/刷板移动会被当成绝对坐标，之后的位置全是错的。
  let relPos: boolean = false;
  // M622 … M623 条件宏的嵌套深度（>0 = 整块跳过，见行处理处的说明）。
  let condDepth: number = 0;
  let layerIdx: number = 0;
  let startLayerMerged: boolean = false;
  const unknownNames: string[] = [];
  const unknownCounts: NumberArray = [];

  const widthSame = (w: number): boolean => {
    if (polyW <= 0) { return true; }
    return Math.abs(w - polyW) <= WIDTH_CHANGE_RATIO * polyW;
  };

  const perpTol = (ax: number, ay: number, bx: number, by: number, cx: number, cy: number): boolean => {
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
  };

  const addPoint = (px: number, py: number): void => {
    while (polyPts.length >= 4) {
      const n2: number = polyPts.length;
      const bx: number = polyPts[n2 - 2];
      const by: number = polyPts[n2 - 1];
      const ax: number = polyPts[n2 - 4];
      const ay: number = polyPts[n2 - 3];
      if (!perpTol(ax, ay, bx, by, px, py)) { break; }
      polyPts.pop();
      polyPts.pop();
    }
    polyPts.push(px, py);
  };

  const pushRun = (pts: NumberArray, np: number, rl: number, w: number): void => {
    if (ptCount + np > ptCap) {
      let nc: number = ptCap;
      while (nc < ptCount + np) { nc *= 2; }
      const xy: Float32Array = new Float32Array(nc * 2);
      xy.set(ptXY.subarray(0, ptCount * 2));
      ptXY = xy;
      ptCap = nc;
    }
    if (runCount >= runCap) {
      const nc: number = runCap * 2;
      const rs: Int32Array = new Int32Array(nc); rs.set(runStart.subarray(0, runCount)); runStart = rs;
      const rl2: Int32Array = new Int32Array(nc); rl2.set(runLen.subarray(0, runCount)); runLen = rl2;
      const rr: Uint8Array = new Uint8Array(nc); rr.set(runRole.subarray(0, runCount)); runRole = rr;
      const rw: Float32Array = new Float32Array(nc); rw.set(runW.subarray(0, runCount)); runW = rw;
      runCap = nc;
    }
    const base: number = ptCount;
    for (let i: number = 0; i < np; i++) {
      ptXY[(base + i) * 2] = pts[i * 2];
      ptXY[(base + i) * 2 + 1] = pts[i * 2 + 1];
    }
    ptCount += np;
    runStart[runCount] = base;
    runLen[runCount] = np;
    runRole[runCount] = rl;
    runW[runCount] = w;
    runCount++;
    segCount += np - 1;
    if (rl >= 0 && rl < ROLE_COUNT) { roleSegCount[rl] += np - 1; }
  };

  const flushRun = (): void => {
    if (!polyOn) { polyPts = []; return; }
    const np: number = polyPts.length >> 1;
    polyOn = false;
    if (np >= 2) { pushRun(polyPts, np, polyRole, polyW); }
    polyPts = [];
  };

  const emitSeg = (x0: number, y0: number, x1: number, y1: number, rl: number, w: number): void => {
    rawSegCount++;
    const n2: number = polyPts.length;
    if (polyOn && rl === polyRole && widthSame(w) && n2 >= 4
        && Math.abs(x0 - polyPts[n2 - 2]) <= CONTIG_TOL_MM
        && Math.abs(y0 - polyPts[n2 - 1]) <= CONTIG_TOL_MM) {
      addPoint(x1, y1);
      return;
    }
    flushRun();
    polyOn = true;
    polyRole = rl;
    polyW = w;
    polyPts = [x0, y0, x1, y1];
  };

  const pushArc = (x0: number, y0: number, x1: number, y1: number, i: number, j: number,
                   rl: number, w: number, cw: boolean): void => {
    const cx: number = x0 + i;
    const cy: number = y0 + j;
    const rad: number = Math.sqrt(i * i + j * j);
    if (rad < 0.0001) {
      emitSeg(x0, y0, x1, y1, rl, w);
      return;
    }
    // 自洽性闸门：I/J 是相对**起点**的圆心偏移，所以终点必须也落在同一个圆上。
    // 端点偏离圆（>1% 或 >0.05mm）说明起点是错的（典型：条件宏里的移动被跳过/被执行不一致，
    // 而 G2/G3 的 I/J 仍按真实起点算）—— 这时按 2π 归一插值会凭空画出巨大的圆弧，
    // 真机表现就是「路径预览里多出莫名其妙的半圆」。退化成一个直线段，绝不臆造。
    const rad1: number = Math.sqrt((x1 - cx) * (x1 - cx) + (y1 - cy) * (y1 - cy));
    if (Math.abs(rad1 - rad) > Math.max(0.05, rad * 0.01)) {
      emitSeg(x0, y0, x1, y1, rl, w);
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
    const steps: number = Math.max(2, Math.min(24, Math.ceil(Math.abs(a1 - a0) * rad * 2)));
    let px: number = x0;
    let py: number = y0;
    for (let s: number = 1; s <= steps; s++) {
      const a: number = a0 + (a1 - a0) * (s / steps);
      const qx: number = cx + rad * Math.cos(a);
      const qy: number = cy + rad * Math.sin(a);
      emitSeg(px, py, qx, qy, rl, w);
      px = qx;
      py = qy;
    }
  };

  const noteUnknownFeature = (name: string): void => {
    for (let i: number = 0; i < unknownNames.length; i++) {
      if (unknownNames[i] === name) { unknownCounts[i] = unknownCounts[i] + 1; return; }
    }
    unknownNames.push(name);
    unknownCounts.push(1);
  };

  // 起始层（与旧实现一致：先开一层，第一个 CHANGE_LAYER 与它合并）
  layRunStartN.push(runCount);
  layZN.push(0);
  layHMarkN.push(0);

  let p: number = 0;
  while (p < n) {
    let e: number = text.indexOf('\n', p);
    if (e < 0) { e = n; }
    let st: number = p;
    while (st < e) {
      const c: number = text.charCodeAt(st);
      if (c === 32 || c === 9 || c === 13) { st++; } else { break; }
    }
    let t: number = e;
    while (t > st) {
      const c: number = text.charCodeAt(t - 1);
      if (c === 32 || c === 9 || c === 13) { t--; } else { break; }
    }

    if (st < t) {
      const c0: number = text.charCodeAt(st);
      // ---- M622 … M623 条件宏：整块跳过（含嵌套）----
      // 拓竹在层间插入 `M622 J1 … M623`（时间流逝拍照 / 流量校准 / 调平等）。条件为假时
      // 机器不执行这些移动，但预览解析是无条件逐行读的：例如时间流逝块会把喷嘴移到 (0,90)
      // 再拍照，随后那条 G3 的 I/J 仍是按**真实起点**算的 —— 起点被挪走后半径对不上，
      // 按 2π 归一就画出一个横跨半张板的大弧（用户反馈的「莫名其妙的半圆」正来自这里）。
      // 条件真假取决于机器运行时状态，离线无法判定；这些块里也没有模型走线，整块跳过最稳。
      if (c0 === 77) {   // 'M'
        const is622: boolean = matchAt(text, st, t, 'M622')
          && !(st + 4 < t && text.charCodeAt(st + 4) === 46);   // 排除 M622.1（不是条件块起止）
        const is623: boolean = matchAt(text, st, t, 'M623');
        if (condDepth > 0) {
          if (is622) { condDepth++; } else if (is623) { condDepth--; }
          p = e + 1;
          continue;
        }
        if (is622) {
          condDepth = 1;
          p = e + 1;
          continue;
        }
      }
      if (condDepth > 0) {
        p = e + 1;
        continue;
      }
      if (c0 === 59) {
        if (findIn(text, st, t, 'CHANGE_LAYER') >= 0) {
          flushRun();
          if (!startLayerMerged) {
            startLayerMerged = true;
          } else if (layZN.length < MAX_LAYERS) {
            layRunStartN.push(runCount);
            layZN.push(0);
            layHMarkN.push(0);
            layerIdx = layZN.length - 1;
          } else {
            layerIdx = -1;
          }
        } else {
          const az = findIn(text, st, t, 'Z_HEIGHT:');
          if (az >= 0 && layerIdx >= 0 && layZN[layerIdx] === 0) {
            let q: number = az + 9;
            while (q < t && text.charCodeAt(q) === 32) { q++; }
            const v: number = numAt(text, q, t);
            if (v > 0) { layZN[layerIdx] = v; }
          } else {
            const ah: number = findIn(text, st, t, 'LAYER_HEIGHT:');
            if (ah >= 0) {
              if (layerIdx >= 0 && layHMarkN[layerIdx] === 0) {
                let q: number = ah + 13;
                while (q < t && text.charCodeAt(q) === 32) { q++; }
                const v: number = numAt(text, q, t);
                if (v > 0.01 && v < 5) { layHMarkN[layerIdx] = v; }
              }
            } else {
              const aw: number = findIn(text, st, t, 'LINE_WIDTH:');
              if (aw >= 0) {
                let q: number = aw + 11;
                while (q < t && text.charCodeAt(q) === 32) { q++; }
                const v: number = numAt(text, q, t);
                if (v > 0.05 && v < 3) { curW = v; }
              } else {
                const af: number = findIn(text, st, t, 'FEATURE:');
                if (af >= 0) {
                  let q: number = af + 8;
                  while (q < t && text.charCodeAt(q) === 32) { q++; }
                  const rr: number = roleOfName(text, q, t);
                  if (rr < 0) {
                    role = 9;
                    noteUnknownFeature(text.substring(q, t));
                  } else {
                    role = rr;
                  }
                }
              }
            }
          }
        }
      } else if (c0 === 71 && st + 2 < t) {
        const c1: number = text.charCodeAt(st + 1);
        const c2: number = text.charCodeAt(st + 2);
        if (c1 === 57 && (c2 === 48 || c2 === 49)) {   // G90 绝对 / G91 相对
          relPos = (c2 === 49);
        } else if ((c1 === 48 || c1 === 49 || c1 === 50 || c1 === 51) && c2 === 32 && layerIdx >= 0) {
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

          let i: number = st + 3;
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
            // G91 相对模式下 X/Y 是增量（起始 G-code 的擦嘴/刷板段整个是相对坐标）。
            const tx: number = hasX ? (relPos ? x + nx : nx) : x;
            const ty: number = hasY ? (relPos ? y + ny : ny) : y;
            if (!hasPos) {
              x = tx; y = ty; hasPos = true;
            } else {
              if (hasE && ePos) {
                // ★「辅助线」档已按需求整体删除：机器启动 G-code 里的辅助挤出
                //   （; FEATURE: Custom —— 喷嘴载入线 / 动态流量校准线 / 擦嘴清洗线）
                //   既不进几何、也不进 presentRoles（图例读它 → 图例里也不会再出现这一档）。
                //   这里刻意不调 flushRun()：与「只动 XY 不挤出的空驶」同样的处理，
                //   这些段本来就不与别的段接续，flush 与否都不影响已累积的折线。
                //   熨烫已并入「顶面」档（同一颜色），不再需要在这里排除。
                if (role !== ROLE_AUX_LINE) {
                  if (isArc && hasI) {
                    pushArc(x, y, tx, ty, ni, nj, role, curW, isCw);
                  } else {
                    emitSeg(x, y, tx, ty, role, curW);
                  }
                  used[role] = true;
                }
              } else {
                flushRun();
              }
              x = tx;
              y = ty;
            }
          } else if (hasE && !ePos) {
            flushRun();
          }
        }
      }
    }
    p = e + 1;
  }

  flushRun();
  layRunStartN.push(runCount);

  const present: NumberArray = [];
  for (let rr: number = 0; rr < ROLE_COUNT; rr++) {
    if (used[rr]) { present.push(rr); }
  }

  const result: GcodeParseResult = {
    ok: layZN.length > 0,
    error: '',
    rawSegCount: rawSegCount,
    segCount: segCount,
    ptCount: ptCount,
    runCount: runCount,
    statText: parseHeader(text),
    presentRoles: present,
    roleSegCount: roleSegCount,
    unknownNames: unknownNames,
    unknownCounts: unknownCounts,
    // 收敛成精确长度
    ptXY: ptXY.slice(0, ptCount * 2),
    runStart: runStart.slice(0, runCount),
    runLen: runLen.slice(0, runCount),
    runRole: runRole.slice(0, runCount),
    runW: runW.slice(0, runCount),
    layRunStart: Int32Array.from(layRunStartN),
    layZ: Float32Array.from(layZN),
    layHMark: Float32Array.from(layHMarkN)
  };
  return result;
}

const workerPort = worker.workerPort;
workerPort.onmessage = (e: MessageEvents): void => {
  const req: GcodeWorkerRequest = e.data as GcodeWorkerRequest;
  try {
    const text: string = fs.readTextSync(req.path);
    const res: GcodeParseResult = parseAllText(text);
    const resp: GcodeWorkerResponse = { seq: req.seq, error: '', result: res };
    workerPort.postMessage(resp);
  } catch (err) {
    const msg: string = err instanceof Error ? err.message : JSON.stringify(err);
    const empty: GcodeParseResult = {
      ok: false, error: msg, rawSegCount: 0, segCount: 0, ptCount: 0, runCount: 0, statText: '',
      presentRoles: [], roleSegCount: [], unknownNames: [], unknownCounts: [],
      ptXY: new Float32Array(0), runStart: new Int32Array(0), runLen: new Int32Array(0),
      runRole: new Uint8Array(0), runW: new Float32Array(0),
      layRunStart: new Int32Array(0), layZ: new Float32Array(0), layHMark: new Float32Array(0)
    };
    const resp: GcodeWorkerResponse = { seq: req.seq, error: msg, result: empty };
    workerPort.postMessage(resp);
  }
};
