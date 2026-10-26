import image from '@ohos.multimedia.image';
import type { Vec3 } from '@kit.ArkGraphics3D';
import { MeshGeometry, meshTriCount } from './MeshUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// 对象列表缩略图：CPU 端等轴测投影 + Z-Buffer 光栅化，直接输出 PixelMap。
// 纯几何计算，不依赖 3D 渲染上下文；结果按模型 id 缓存，避免重复光栅化。
//
// 【大模型（百万面）为什么不再同步做】
//   实测 169 万面模型：旧实现把「105 万顶点包围盒 + 105 万顶点视图变换 + 169 万面扫描线」
//   一口气同步做完，单块约 3.9s。导入时叠在其它同步块上把主线程连续占住 >6s →
//   系统按 THREAD_BLOCK_6S 直接杀进程。现在改为：① 顶点/索引从扁平 TypedArray 读（无对象解引用）；
//   ② 三角面循环【分块让帧】（每 CHUNK 面 await 一次）；③ ensureThumbnail 异步后台完成，
//   不再挂在导入的同步链上。就绪后通过 AppStorage 'thumbSeq' 通知对象列表刷新。
// =============================================================================

const SS: number = 2; // 超采样倍数（2×2 盒式降采样，抗锯齿）
const BASE_R: number = 0.80;
const BASE_G: number = 0.82;
const BASE_B: number = 0.86;
// 每光栅化 CHUNK 个三角面让出一帧（避免百万面时单个同步块过长触发 AppFreeze）
const TRI_CHUNK: number = 65536;

function clamp01(v: number): number {
  return v < 0 ? 0 : (v > 1 ? 1 : v);
}

function yieldToUi(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => { resolve(); }, 0);
  });
}

// 渲染单个模型的缩略图（outSize 为最终边长，单位 px）。异步分块：大模型不会长时间独占主线程。
export async function renderThumbnail(g: MeshGeometry, outSize: number): Promise<image.PixelMap | undefined> {
  const triCount: number = meshTriCount(g); // 索引网格用 indices，面汤退回 vertices.length/3
  if (triCount <= 0 || outSize <= 0) {
    return undefined;
  }
  const vCount: number = g.vertexCount();
  const pos: Float32Array | null = g.pos;
  const verts: Vec3[] = g.vertices;

  // 1. 包围盒中心（用于把模型摆到画面中央）
  let loX: number = 1e30, loY: number = 1e30, loZ: number = 1e30;
  let hiX: number = -1e30, hiY: number = -1e30, hiZ: number = -1e30;
  if (pos !== null) {
    for (let i = 0; i + 2 < pos.length; i += 3) {
      const x: number = pos[i], y: number = pos[i + 1], z: number = pos[i + 2];
      if (x < loX) { loX = x; }
      if (y < loY) { loY = y; }
      if (z < loZ) { loZ = z; }
      if (x > hiX) { hiX = x; }
      if (y > hiY) { hiY = y; }
      if (z > hiZ) { hiZ = z; }
    }
  } else {
    for (let i = 0; i < vCount; i++) {
      const p: Vec3 = verts[i];
      if (p.x < loX) { loX = p.x; }
      if (p.y < loY) { loY = p.y; }
      if (p.z < loZ) { loZ = p.z; }
      if (p.x > hiX) { hiX = p.x; }
      if (p.y > hiY) { hiY = p.y; }
      if (p.z > hiZ) { hiZ = p.z; }
    }
  }
  const cx: number = (loX + hiX) * 0.5;
  const cy: number = (loY + hiY) * 0.5;
  const cz: number = (loZ + hiZ) * 0.5;

  // 2. 视图变换：绕 Y 偏航 -35°，绕 X 俯仰 20°
  //    视图空间：+X 右、+Y 上、+Z 朝相机（z 越大越近）
  const ay: number = -35 * Math.PI / 180;
  const ax: number = 20 * Math.PI / 180;
  const cA: number = Math.cos(ay);
  const sA: number = Math.sin(ay);
  const cB: number = Math.cos(ax);
  const sB: number = Math.sin(ax);

  const n: number = vCount;
  const vx: Float32Array = new Float32Array(n);
  const vy: Float32Array = new Float32Array(n);
  const vz: Float32Array = new Float32Array(n);
  let tMinX: number = 1e30, tMaxX: number = -1e30;
  let tMinY: number = 1e30, tMaxY: number = -1e30;
  for (let i = 0; i < n; i++) {
    let px: number;
    let py: number;
    let pz: number;
    if (pos !== null) {
      const k: number = i * 3;
      px = pos[k] - cx; py = pos[k + 1] - cy; pz = pos[k + 2] - cz;
    } else {
      const p: Vec3 = verts[i];
      px = p.x - cx; py = p.y - cy; pz = p.z - cz;
    }
    const x1: number = px * cA - pz * sA;
    const z1: number = px * sA + pz * cA;
    const y2: number = py * cB - z1 * sB;
    const z2: number = py * sB + z1 * cB;
    vx[i] = x1;
    vy[i] = y2;
    vz[i] = z2;
    if (x1 < tMinX) { tMinX = x1; }
    if (x1 > tMaxX) { tMaxX = x1; }
    if (y2 < tMinY) { tMinY = y2; }
    if (y2 > tMaxY) { tMaxY = y2; }
  }

  const spanW: number = Math.max(1e-4, tMaxX - tMinX);
  const spanH: number = Math.max(1e-4, tMaxY - tMinY);
  const span: number = Math.max(spanW, spanH);
  const target: number = outSize * SS;
  const pad: number = target * 0.12;
  const sc: number = (target - pad * 2) / span;
  const offX: number = (target - spanW * sc) * 0.5 - tMinX * sc;
  const offY: number = (target - spanH * sc) * 0.5 + tMaxY * sc; // 屏幕 y 向下

  const zbuf: Float32Array = new Float32Array(target * target);
  const cbuf: Float32Array = new Float32Array(target * target * 4);
  for (let i = 0; i < zbuf.length; i++) {
    zbuf[i] = -1e30;
  }

  // 3. 光照（视图空间，左上前方）
  let lx: number = -0.42, ly: number = 0.62, lz: number = 0.66;
  const ll: number = Math.sqrt(lx * lx + ly * ly + lz * lz);
  lx /= ll; ly /= ll; lz /= ll;

  // 索引统一为 Uint32Array（大网格直接用其 idx；小网格物化一次，规模很小）
  let I: Uint32Array = new Uint32Array(0);
  let hasIdx: boolean = false;
  if (g.idx !== null && g.idx.length > 0) {
    I = g.idx; hasIdx = true;
  } else if (g.indices.length > 0) {
    const s: number[] = g.indices;
    I = new Uint32Array(s.length);
    for (let i = 0; i < s.length; i++) { I[i] = s[i]; }
    hasIdx = true;
  }

  for (let t = 0; t < triCount; t++) {
    const i0: number = hasIdx ? I[t * 3] : t * 3;
    const i1: number = hasIdx ? I[t * 3 + 1] : t * 3 + 1;
    const i2: number = hasIdx ? I[t * 3 + 2] : t * 3 + 2;

    const z0: number = vz[i0];
    const z1: number = vz[i1];
    const z2: number = vz[i2];
    const X0: number = vx[i0] * sc + offX;
    const Y0: number = offY - vy[i0] * sc;
    const X1: number = vx[i1] * sc + offX;
    const Y1: number = offY - vy[i1] * sc;
    const X2: number = vx[i2] * sc + offX;
    const Y2: number = offY - vy[i2] * sc;

    // 有符号面积 = 边函数 E01(v2)
    const area: number = (X1 - X0) * (Y2 - Y0) - (X2 - X0) * (Y1 - Y0);
    if (area > -1e-6 && area < 1e-6) {
      continue;
    }
    const invA: number = 1 / area;

    let bx0: number = Math.floor(Math.min(X0, Math.min(X1, X2)));
    let bx1: number = Math.ceil(Math.max(X0, Math.max(X1, X2)));
    let by0: number = Math.floor(Math.min(Y0, Math.min(Y1, Y2)));
    let by1: number = Math.ceil(Math.max(Y0, Math.max(Y1, Y2)));
    if (bx0 < 0) { bx0 = 0; }
    if (by0 < 0) { by0 = 0; }
    if (bx1 > target - 1) { bx1 = target - 1; }
    if (by1 > target - 1) { by1 = target - 1; }
    if (bx0 > bx1 || by0 > by1) {
      continue;
    }

    // 面法线（视图空间），统一朝向相机后做 Lambert 着色
    const e1x: number = vx[i1] - vx[i0];
    const e1y: number = vy[i1] - vy[i0];
    const e1z: number = vz[i1] - vz[i0];
    const e2x: number = vx[i2] - vx[i0];
    const e2y: number = vy[i2] - vy[i0];
    const e2z: number = vz[i2] - vz[i0];
    let nx: number = e1y * e2z - e1z * e2y;
    let ny: number = e1z * e2x - e1x * e2z;
    let nz: number = e1x * e2y - e1y * e2x;
    const nl: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-9) {
      continue;
    }
    nx /= nl; ny /= nl; nz /= nl;
    if (nz < 0) { nx = -nx; ny = -ny; nz = -nz; }
    let lam: number = nx * lx + ny * ly + nz * lz;
    if (lam < 0) { lam = 0; }
    const shade: number = clamp01(0.30 + 0.60 * lam + 0.12 * nz);
    const cr: number = BASE_R * shade;
    const cg: number = BASE_G * shade;
    const cb: number = BASE_B * shade;

    for (let y = by0; y <= by1; y++) {
      const row: number = y * target;
      for (let x = bx0; x <= bx1; x++) {
        const w0: number = ((X2 - X1) * (y - Y1) - (x - X1) * (Y2 - Y1)) * invA;
        if (w0 < -1e-4) { continue; }
        const w1: number = ((X0 - X2) * (y - Y2) - (x - X2) * (Y0 - Y2)) * invA;
        if (w1 < -1e-4) { continue; }
        const w2: number = 1 - w0 - w1;
        if (w2 < -1e-4) { continue; }
        const depth: number = w0 * z0 + w1 * z1 + w2 * z2;
        const idx: number = row + x;
        if (depth > zbuf[idx]) {
          zbuf[idx] = depth;
          const o: number = idx * 4;
          cbuf[o] = cr;
          cbuf[o + 1] = cg;
          cbuf[o + 2] = cb;
          cbuf[o + 3] = 1;
        }
      }
    }

    // 分块让帧：每 CHUNK 个三角面让出一次，避免百万面时单个同步块过长
    if (((t + 1) % TRI_CHUNK) === 0) {
      await yieldToUi();
    }
  }

  // 4. 降采样（预乘 alpha）→ PixelMap
  const out: ArrayBuffer = new ArrayBuffer(outSize * outSize * 4);
  const ob: Uint8Array = new Uint8Array(out);
  const cnt: number = SS * SS;
  for (let y = 0; y < outSize; y++) {
    for (let x = 0; x < outSize; x++) {
      let rs: number = 0, gs: number = 0, bs: number = 0, as: number = 0;
      for (let dy = 0; dy < SS; dy++) {
        const sy: number = y * SS + dy;
        for (let dx = 0; dx < SS; dx++) {
          const si: number = (sy * target + (x * SS + dx)) * 4;
          const al: number = cbuf[si + 3];
          rs += cbuf[si] * al;
          gs += cbuf[si + 1] * al;
          bs += cbuf[si + 2] * al;
          as += al;
        }
      }
      const oi: number = (y * outSize + x) * 4;
      ob[oi] = Math.round(clamp01(rs / cnt) * 255);
      ob[oi + 1] = Math.round(clamp01(gs / cnt) * 255);
      ob[oi + 2] = Math.round(clamp01(bs / cnt) * 255);
      ob[oi + 3] = Math.round(clamp01(as / cnt) * 255);
    }
  }

  const sz: image.Size = { width: outSize, height: outSize };
  const opts: image.InitializationOptions = {
    size: sz,
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    alphaType: image.AlphaType.PREMUL,
    editable: false,
  };
  try {
    return image.createPixelMapSync(out, opts);
  } catch (e) {
    // 缩略图失败不该拖垮流程，但也不能静默：留一条日志方便定位
    hilog.warn(0x0000, 'Thumbnail', 'render: createPixelMapSync failed %{public}s',
      e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    return undefined;
  }
}

// ---- 缓存：按模型 id 存取缩略图 ----
const cache: Map<number, image.PixelMap> = new Map<number, image.PixelMap>();
// 正在后台光栅化的 id（防止同一模型被并发光栅化多次）
const pending: Set<number> = new Set<number>();
// 缓存对应的几何指纹：同一个 id 的几何被整体替换（合并/拆分/布尔/切割/撤销重做）后，
// 仅靠 cache.has(id) 会一直返回旧图 —— 这正是「对象渲染图不更新」的根因。
const sigOf: Map<number, string> = new Map<number, string>();
// 光栅化代次：同一 id 连续换几何时，只允许最后一次结果落缓存（旧结果直接释放）。
const genOf: Map<number, number> = new Map<number, number>();

// 几何指纹：只取 O(1) 的规模 + 首尾顶点，足够区分「换了几何」，
// 又不会在百万面模型上产生额外遍历开销。
function geomSignature(g: MeshGeometry): string {
  const vc: number = g.vertexCount();
  const tc: number = (g.idx !== null && g.idx.length > 0)
    ? Math.floor(g.idx.length / 3)
    : Math.floor((g.pos !== null ? g.pos.length : 0) / 9);
  let s: string = `${vc}/${tc}`;
  const p: Float32Array | null = g.pos;
  if (p !== null && p.length >= 3) {
    s += `/${p[0].toFixed(2)},${p[1].toFixed(2)},${p[2].toFixed(2)}`;
    const k: number = p.length - 3;
    s += `,${p[k].toFixed(2)},${p[k + 1].toFixed(2)},${p[k + 2].toFixed(2)}`;
  }
  return s;
}

export function getThumbnail(id: number): image.PixelMap | undefined {
  return cache.get(id);
}

// 异步确保缩略图：几何没变且已缓存/进行中直接返回；几何变了则重新光栅化。
// 注意：本函数【立即返回】，不再占用导入的同步链 —— 百万面缩略图的光栅化不再卡住导入流程。
// 超过该面数就不生成缩略图：光栅化要三份 Float32Array（vx/vy/vz，576 万顶点=69MB/份）
// + 逐三角形填充，实测 192 万面时把 JS 堆顶到 425MB → OOM 闪退。
// 跳过是安全的：对象列表会自动退回显示「格式文字」（见 ObjectList.thumbReady）。
const HUGE_MESH_TRIS: number = 300000;

export function ensureThumbnail(id: number, g: MeshGeometry): void {
  const sig: string = geomSignature(g);
  // 几何没变、且已有缓存或正在画 → 直接复用
  if (sigOf.get(id) === sig && (cache.has(id) || pending.has(id))) {
    return;
  }
  const tris: number = (g.idx !== null && g.idx.length > 0)
    ? g.idx.length / 3
    : Math.floor((g.pos !== null ? g.pos.length : 0) / 9);
  if (tris > HUGE_MESH_TRIS) {
    hilog.info(0x0000, 'Thumbnail', '面数=%{public}d 超过阈值 %{public}d → 跳过缩略图（省内存）',
      tris, HUGE_MESH_TRIS);
    return;
  }
  const gen: number = (genOf.get(id) ?? 0) + 1;
  genOf.set(id, gen);
  sigOf.set(id, sig);
  pending.add(id);
  renderThumbnail(g, 64).then((pm: image.PixelMap | undefined) => {
    // 同一 id 在绘制期间又换了几何：丢弃这次旧结果
    if (genOf.get(id) !== gen) {
      if (pm !== undefined) {
        try { pm.release(); } catch (e) {
          hilog.warn(0x0000, 'Thumbnail', 'ensure: stale release failed id=%{public}d', id);
        }
      }
      return;
    }
    pending.delete(id);
    if (pm !== undefined) {
      const old: image.PixelMap | undefined = cache.get(id);
      if (old !== undefined) {
        try { old.release(); } catch (e) {
          hilog.warn(0x0000, 'Thumbnail', 'ensure: old release failed id=%{public}d', id);
        }
      }
      cache.set(id, pm);
      // 通知订阅者（对象列表按 thumbSeq 订阅）重新读取缩略图
      AppStorage.setOrCreate<number>('thumbSeq', (AppStorage.get<number>('thumbSeq') ?? 0) + 1);
    }
  }).catch((e: Error) => {
    if (genOf.get(id) === gen) {
      pending.delete(id);
    }
    hilog.warn(0x0000, 'Thumbnail', 'ensure: 光栅化失败 id=%{public}d %{public}s', id, e.message);
  });
}

export function dropThumbnail(id: number): void {
  // 作废在途光栅化（否则它完成后会把已删除对象的图又写回缓存）
  genOf.set(id, (genOf.get(id) ?? 0) + 1);
  pending.delete(id);
  sigOf.delete(id);
  const pm: image.PixelMap | undefined = cache.get(id);
  if (pm !== undefined) {
    try {
      pm.release();
    } catch (e) {
      // 释放失败也要留痕（对象已从列表/场景移除，这里失败只影响内存回收）
      hilog.warn(0x0000, 'Thumbnail', 'drop: PixelMap release failed id=%{public}d %{public}s',
        id, e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    cache.delete(id);
  }
}
