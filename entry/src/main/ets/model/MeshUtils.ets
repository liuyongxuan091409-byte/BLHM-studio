import type { Vec3, Vec2, Quaternion } from '@kit.ArkGraphics3D';

// =============================================================================
// 3D 预览纯逻辑工具（无 ArkUI/渲染运行时依赖，可本地单元测试）：
// 坐标转换 / 四元数 / 底板网格生成 / 视口自适应
// 坐标约定：解析层输出 Z 轴向上；渲染层（ArkGraphics3D，glTF 风格）Y 轴向上
// =============================================================================

// 自定义几何数据（CustomGeometry 的纯数据形态）。
//
// 【两种互斥存储形态】同一份 MeshGeometry 只会用其中一种：
//  · 程序化小网格（板面/网格线/边框/单喷嘴区/文字面片/手柄/切片路径棱柱/内置板）：
//    用对象数组 vertices/normals/indices/uvs —— 规模很小（几十~几千顶点），对象数组直观、
//    便于增量 push 构建，内存可忽略。
//  · 大网格（导入的 STL/STEP 模型）：用扁平 TypedArray pos/nrm/idx ——
//    实测 169 万面 → 105 万顶点：若逐顶点建 JS 对象（Vec3[]）会瞬时分配上百 MB 并触发
//    大量 GC，主线程被连续占住 >6s → 系统按 THREAD_BLOCK_6S 直接杀进程（真机闪退根因）。
//    扁平 Float32Array/Uint32Array 内存仅约对象数组的 1/3，遍历无对象解引用、无 GC 压力。
//    这类网格【不再常驻】Vec3[]/number[]；只在必须交给引擎时（CustomGeometry 只收
//    Vec3[]/number[]）才物化，用完立即释放（见 materializeVertices/Normals/Indices）。
export class MeshGeometry {
  // —— 程序化小网格（对象数组形态）——
  vertices: Vec3[] = [];
  indices: number[] = [];
  normals: Vec3[] = [];
  // 顶点 UV（可选）：只有走「材质贴图」的面片（如单喷嘴区文字）才会填，
  // 其余网格留空 → toCustomGeometry 不传 uvs，行为与以前完全一致。
  uvs: Vec2[] = [];

  // —— 大网格（扁平 TypedArray 形态，与上面的对象数组互斥）——
  pos: Float32Array | null = null;   // 顶点 XYZ 扁平（长度 = 顶点数 × 3）
  nrm: Float32Array | null = null;   // 顶点法线 XYZ 扁平
  idx: Uint32Array | null = null;    // 三角索引（每 3 个 = 一个面；空 = 无索引面汤）

  // 是否为大网格（TypedArray）形态
  isTyped(): boolean { return this.pos !== null; }
  // 顶点数（两种形态统一口径）
  vertexCount(): number { return this.pos !== null ? Math.floor(this.pos.length / 3) : this.vertices.length; }
  // 三角面数：优先索引；无索引退回面汤（每顶点 3 个 = 一面）
  triCount(): number {
    if (this.idx !== null) { return Math.floor(this.idx.length / 3); }
    if (this.pos !== null) { return Math.floor(this.pos.length / 9); }
    return this.indices.length > 0 ? Math.floor(this.indices.length / 3) : Math.floor(this.vertices.length / 3);
  }
  // 是否有索引（两种形态统一）
  hasIndices(): boolean { return this.indices.length > 0 || (this.idx !== null && this.idx.length > 0); }
  // 是否有法线（两种形态统一）
  hasNormals(): boolean { return this.normals.length > 0 || (this.nrm !== null && this.nrm.length > 0); }
}

// Z-up → Y-up：绕 X 轴 -90°，(x, y, z) → (x, z, -y)（对象数组形态，用于小网格如内置打印板）
export function zUpToYUp(f: Float32Array): Vec3[] {
  const out: Vec3[] = [];
  const n = f.length - (f.length % 3);
  for (let i = 0; i < n; i += 3) {
    out.push({ x: f[i], y: f[i + 2], z: -f[i + 1] });
  }
  return out;
}

// Z-up → Y-up（原地，扁平 Float32Array 形态）：直接改写传入缓冲，零额外分配。
// 大网格导入专用（对象数组形态用上面的 zUpToYUp）。
export function zUpToYUpInPlace(f: Float32Array): void {
  const n = f.length - (f.length % 3);
  for (let i = 0; i < n; i += 3) {
    const y = f[i + 2];
    const z = -f[i + 1];
    f[i + 2] = z;
    f[i + 1] = y;
  }
}

// ---- 大网格（TypedArray）→ 引擎对象数组的物化（仅 createMesh 前调用；用完立即释放）----
// CustomGeometry 只收 Vec3[]/number[]，所以必须物化，但绝不能把它常驻（那正是闪退根因）。
// 这里【分块物化 + 每块让帧】：百万顶点/千万索引不会被一口气同步打完，主线程始终能响应，
// 避免单个同步块过长触发系统的 AppFreeze（THREAD_BLOCK）判定。
function yieldFrame(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => { resolve(); }, 16);
  });
}

// Float32 顶点/法线扁平数组 → Vec3[]（分块让帧）
export async function materializeVerticesChunked(arr: Float32Array): Promise<Vec3[]> {
  const vc: number = Math.floor(arr.length / 3);
  const out: Vec3[] = new Array<Vec3>(vc);
  const CH: number = 32768;
  for (let i = 0; i < vc; i++) {
    const k: number = i * 3;
    out[i] = { x: arr[k], y: arr[k + 1], z: arr[k + 2] };
    if (((i + 1) % CH) === 0) { await yieldFrame(); }
  }
  await yieldFrame();
  return out;
}

// Uint32 索引扁平数组 → number[]（分块让帧）
export async function materializeIndicesChunked(arr: Uint32Array): Promise<number[]> {
  const n: number = arr.length;
  const out: number[] = new Array<number>(n);
  const CH: number = 65536;
  for (let i = 0; i < n; i++) {
    out[i] = arr[i];
    if (((i + 1) % CH) === 0) { await yieldFrame(); }
  }
  await yieldFrame();
  return out;
}

// 四元数乘法（先应用 b 再应用 a）：(w1w2 - v1·v2, w1v2 + w2v1 + v1×v2)
export function multiplyQuaternion(a: Quaternion, b: Quaternion): Quaternion {
  return {
    x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  };
}

// 转台式视角旋转：水平拖动 = yaw（绕 Y），垂直拖动 = pitch（绕 X）
// 组合顺序：先 yaw 后 pitch（M = Rx(pitch)·Ry(yaw)），与轨道相机视觉一致
export function eulerToQuaternion(pitch: number, yaw: number): Quaternion {
  const hp = pitch * 0.5;
  const hy = yaw * 0.5;
  const qPitch: Quaternion = { x: Math.sin(hp), y: 0, z: 0, w: Math.cos(hp) };
  const qYaw: Quaternion = { x: 0, y: Math.sin(hy), z: 0, w: Math.cos(hy) };
  return multiplyQuaternion(qPitch, qYaw);
}

// 方向 → 四元数：把节点默认朝向 -Z 旋转到指向 dir（用于平行光）
export function dirToQuaternion(dx: number, dy: number, dz: number): Quaternion {
  const l = Math.sqrt(dx * dx + dy * dy + dz * dz);
  if (l < 1e-9) {
    return { x: 0, y: 0, z: 0, w: 1 };
  }
  const d: Vec3 = { x: dx / l, y: dy / l, z: dz / l };
  // 目标基：z' = -d（局部 -Z 指向 d），x' = up × z'，y' = z' × x'
  const zx = -d.x, zy = -d.y, zz = -d.z;
  // up 取 (0,1,0)；与 z' 平行时回退 (1,0,0)
  let xx = zz, xy = 0, xz = -zx; // (0,1,0) × (zx,zy,zz) = (zz, 0, -zx)
  let xl = Math.sqrt(xx * xx + xy * xy + xz * xz);
  if (xl < 1e-6) {
    xx = 1; xy = 0; xz = 0; // 回退 (1,0,0) × z'
    const t = zy; // (1,0,0)×(zx,zy,zz) = (0*zz-0*zy, 0*zx-1*zz, 1*zy-0*zx)
    xy = -zz;
    xz = t;
    xl = Math.sqrt(xx * xx + xy * xy + xz * xz);
  }
  xx /= xl; xy /= xl; xz /= xl;
  const yx = zy * xz - zz * xy;
  const yy = zz * xx - zx * xz;
  const yz = zx * xy - zy * xx;
  // 旋转矩阵（列 = x'/y'/z'）→ 四元数（Shepperd 法）
  const m00 = xx, m10 = xy, m20 = xz;
  const m01 = yx, m11 = yy, m21 = yz;
  const m02 = zx, m12 = zy, m22 = zz;
  const tr = m00 + m11 + m22;
  if (tr > 0) {
    const s = Math.sqrt(tr + 1) * 2;
    return { x: (m21 - m12) / s, y: (m02 - m20) / s, z: (m10 - m01) / s, w: s * 0.25 };
  }
  if (m00 > m11 && m00 > m22) {
    const s = Math.sqrt(1 + m00 - m11 - m22) * 2;
    return { x: s * 0.25, y: (m01 + m10) / s, z: (m02 + m20) / s, w: (m21 - m12) / s };
  }
  if (m11 > m22) {
    const s = Math.sqrt(1 + m11 - m00 - m22) * 2;
    return { x: (m01 + m10) / s, y: s * 0.25, z: (m12 + m21) / s, w: (m02 - m20) / s };
  }
  const s = Math.sqrt(1 + m22 - m00 - m11) * 2;
  return { x: (m02 + m20) / s, y: (m12 + m21) / s, z: s * 0.25, w: (m10 - m01) / s };
}

// 单位四元数的逆（即共轭）
export function quatInverse(q: Quaternion): Quaternion {
  return { x: -q.x, y: -q.y, z: -q.z, w: q.w };
}

// 欧拉角（弧度，X→Y→Z 顺序）→ 四元数
export function eulerXYZToQuaternion(rx: number, ry: number, rz: number): Quaternion {
  const qx: Quaternion = { x: Math.sin(rx * 0.5), y: 0, z: 0, w: Math.cos(rx * 0.5) };
  const qy: Quaternion = { x: 0, y: Math.sin(ry * 0.5), z: 0, w: Math.cos(ry * 0.5) };
  const qz: Quaternion = { x: 0, y: 0, z: Math.sin(rz * 0.5), w: Math.cos(rz * 0.5) };
  return multiplyQuaternion(multiplyQuaternion(qx, qy), qz);
}

// 用四元数旋转向量 v（含非有限值保护）
export function rotateVecByQuat(q: Quaternion, v: Vec3): Vec3 {
  const qx = q.x, qy = q.y, qz = q.z, qw = q.w;
  const tx = 2 * (qy * v.z - qz * v.y);
  const ty = 2 * (qz * v.x - qx * v.z);
  const tz = 2 * (qx * v.y - qy * v.x);
  return {
    x: v.x + qw * tx + (qy * tz - qz * ty),
    y: v.y + qw * ty + (qz * tx - qx * tz),
    z: v.z + qw * tz + (qx * ty - qy * tx),
  };
}

// 判断向量各分量是否有限（防止 NaN/Inf 污染变换导致模型消失）
export function isFiniteVec3(v: Vec3): boolean {
  return Number.isFinite(v.x) && Number.isFinite(v.y) && Number.isFinite(v.z);
}

// 由三点算单位法线（退化时返回 +Y）
export function triangleNormal(a: Vec3, b: Vec3, c: Vec3): Vec3 {
  const ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z;
  const vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z;
  let nx = uy * vz - uz * vy;
  let ny = uz * vx - ux * vz;
  let nz = ux * vy - uy * vx;
  const l = Math.sqrt(nx * nx + ny * ny + nz * nz);
  if (l < 1e-12) {
    return { x: 0, y: 1, z: 0 };
  }
  return { x: nx / l, y: ny / l, z: nz / l };
}

// 三角面数：优先用索引（每 3 个 = 一个面），indices 为空时退回无索引面汤（vertices.length/3）
export function meshTriCount(g: MeshGeometry): number {
  return g.triCount();
}

// 取第 tri 个三角面的第 corner 个角点在 vertices 中的下标（索引网格 / 面汤统一；两种存储形态统一）
export function meshVertexIndex(g: MeshGeometry, tri: number, corner: number): number {
  if (g.idx !== null && g.idx.length > 0) { return g.idx[tri * 3 + corner]; }
  if (g.indices.length > 0) { return g.indices[tri * 3 + corner]; }
  return tri * 3 + corner;
}

// 读第 i 个顶点到一个复用的 Vec3（两种存储形态统一；大网格热路径请直接读 g.pos 以避免分配）
export function meshVertexAt(g: MeshGeometry, i: number, out: Vec3): Vec3 {
  if (g.pos !== null) {
    const k = i * 3;
    out.x = g.pos[k];
    out.y = g.pos[k + 1];
    out.z = g.pos[k + 2];
  } else {
    const v: Vec3 = g.vertices[i];
    out.x = v.x; out.y = v.y; out.z = v.z;
  }
  return out;
}

// 重算面法线并统一朝外（相对包围盒中心）。
// 修正源文件里「法线朝内/绕序反了」的面：否则该面会渲染发暗、选面零旋转、高亮埋进模型里。
// 索引感知：索引网格按唯一顶点累加得到平滑法线；面汤（indices 为空）等价于逐面法线，结果不变。
// 两种存储形态都支持：大网格（TypedArray）全程用扁平缓冲，零 per-vertex 对象分配。
export function repairNormals(g: MeshGeometry): void {
  const triCount: number = meshTriCount(g);
  if (triCount <= 0) {
    return;
  }
  const vCount: number = g.vertexCount();

  // 顶点坐标 + 索引统一到扁平缓冲（大网格直接用其 pos/idx；小网格物化一次，规模很小）
  let P: Float32Array;
  if (g.pos !== null) {
    P = g.pos;
  } else {
    const v: Vec3[] = g.vertices;
    P = new Float32Array(v.length * 3);
    for (let i = 0; i < v.length; i++) {
      const q: Vec3 = v[i];
      P[i * 3] = q.x; P[i * 3 + 1] = q.y; P[i * 3 + 2] = q.z;
    }
  }
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

  // 包围盒中心（用于法线朝外判定）
  let loX: number = 1e30, loY: number = 1e30, loZ: number = 1e30;
  let hiX: number = -1e30, hiY: number = -1e30, hiZ: number = -1e30;
  for (let i = 0; i + 2 < P.length; i += 3) {
    const x: number = P[i], y: number = P[i + 1], z: number = P[i + 2];
    if (x < loX) { loX = x; }
    if (y < loY) { loY = y; }
    if (z < loZ) { loZ = z; }
    if (x > hiX) { hiX = x; }
    if (y > hiY) { hiY = y; }
    if (z > hiZ) { hiZ = z; }
  }
  const cx: number = (loX + hiX) * 0.5;
  const cy: number = (loY + hiY) * 0.5;
  const cz: number = (loZ + hiZ) * 0.5;

  // 逐顶点累加面法线（扁平 Float64 缓冲，避免为每个顶点建临时对象）
  const accX: Float64Array = new Float64Array(vCount);
  const accY: Float64Array = new Float64Array(vCount);
  const accZ: Float64Array = new Float64Array(vCount);
  for (let i = 0; i < triCount; i++) {
    const ia: number = hasIdx ? I[i * 3] : i * 3;
    const ib: number = hasIdx ? I[i * 3 + 1] : i * 3 + 1;
    const ic: number = hasIdx ? I[i * 3 + 2] : i * 3 + 2;
    const a3: number = ia * 3, b3: number = ib * 3, c3: number = ic * 3;
    const ax: number = P[a3], ay: number = P[a3 + 1], az: number = P[a3 + 2];
    const bx: number = P[b3], by: number = P[b3 + 1], bz: number = P[b3 + 2];
    const cxx: number = P[c3], cyy: number = P[c3 + 1], czz: number = P[c3 + 2];
    // 面法线 = (b-a)×(c-a)，退化时取 +Y（与 triangleNormal 一致）
    let nx: number = (by - ay) * (czz - az) - (bz - az) * (cyy - ay);
    let ny: number = (bz - az) * (cxx - ax) - (bx - ax) * (czz - az);
    let nz: number = (bx - ax) * (cyy - ay) - (by - ay) * (cxx - ax);
    const nl: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-12) { nx = 0; ny = 1; nz = 0; } else { nx /= nl; ny /= nl; nz /= nl; }
    const dx: number = (ax + bx + cxx) / 3 - cx;
    const dy: number = (ay + by + cyy) / 3 - cy;
    const dz: number = (az + bz + czz) / 3 - cz;
    if (nx * dx + ny * dy + nz * dz < 0) {
      nx = -nx; ny = -ny; nz = -nz; // 朝内 → 翻转朝外
    }
    accX[ia] += nx; accY[ia] += ny; accZ[ia] += nz;
    accX[ib] += nx; accY[ib] += ny; accZ[ib] += nz;
    accX[ic] += nx; accY[ic] += ny; accZ[ic] += nz;
  }

  // 归一化输出（大网格写回扁平 nrm，小网格写回 Vec3[]）
  if (g.pos !== null) {
    const out: Float32Array = new Float32Array(vCount * 3);
    for (let i = 0; i < vCount; i++) {
      const nx: number = accX[i];
      const ny: number = accY[i];
      const nz: number = accZ[i];
      const l: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
      const k: number = i * 3;
      if (l > 1e-12) { out[k] = nx / l; out[k + 1] = ny / l; out[k + 2] = nz / l; }
      else { out[k] = 0; out[k + 1] = 1; out[k + 2] = 0; }
    }
    g.nrm = out;
  } else {
    const out: Vec3[] = new Array<Vec3>(vCount);
    for (let i = 0; i < vCount; i++) {
      const nx: number = accX[i];
      const ny: number = accY[i];
      const nz: number = accZ[i];
      const l: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
      out[i] = l > 1e-12 ? { x: nx / l, y: ny / l, z: nz / l } : { x: 0, y: 1, z: 0 };
    }
    g.normals = out;
  }
}

// 点到三角形的最短距离平方（Ericson 算法）
function distSqPointTriangle(p: Vec3, a: Vec3, b: Vec3, c: Vec3): number {
  const abx = b.x - a.x, aby = b.y - a.y, abz = b.z - a.z;
  const acx = c.x - a.x, acy = c.y - a.y, acz = c.z - a.z;
  const apx = p.x - a.x, apy = p.y - a.y, apz = p.z - a.z;
  const d1 = abx * apx + aby * apy + abz * apz;
  const d2 = acx * apx + acy * apy + acz * apz;
  if (d1 <= 0 && d2 <= 0) {
    return apx * apx + apy * apy + apz * apz;
  }
  const bpx = p.x - b.x, bpy = p.y - b.y, bpz = p.z - b.z;
  const d3 = abx * bpx + aby * bpy + abz * bpz;
  const d4 = acx * bpx + acy * bpy + acz * bpz;
  if (d3 >= 0 && d4 <= d3) {
    return bpx * bpx + bpy * bpy + bpz * bpz;
  }
  const vc = d1 * d4 - d3 * d2;
  if (vc <= 0 && d1 >= 0 && d3 <= 0) {
    const v = d1 / (d1 - d3);
    const qx = apx - abx * v, qy = apy - aby * v, qz = apz - abz * v;
    return qx * qx + qy * qy + qz * qz;
  }
  const cpx = p.x - c.x, cpy = p.y - c.y, cpz = p.z - c.z;
  const d5 = abx * cpx + aby * cpy + abz * cpz;
  const d6 = acx * cpx + acy * cpy + acz * cpz;
  if (d6 >= 0 && d5 <= d6) {
    return cpx * cpx + cpy * cpy + cpz * cpz;
  }
  const vb = d5 * d2 - d1 * d6;
  if (vb <= 0 && d2 >= 0 && d6 <= 0) {
    const w = d2 / (d2 - d6);
    const qx = apx - acx * w, qy = apy - acy * w, qz = apz - acz * w;
    return qx * qx + qy * qy + qz * qz;
  }
  const va = d3 * d6 - d5 * d4;
  if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
    const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    const qx = bpx + (c.x - b.x) * w;
    const qy = bpy + (c.y - b.y) * w;
    const qz = bpz + (c.z - b.z) * w;
    return qx * qx + qy * qy + qz * qz;
  }
  // 内部：点到平面距离
  const denom = 1.0 / (va + vb + vc);
  const v = vb * denom;
  const w = vc * denom;
  const qx = apx - (abx * v + acx * w);
  const qy = apy - (aby * v + acy * w);
  const qz = apz - (abz * v + acz * w);
  return qx * qx + qy * qy + qz * qz;
}

// 射线-三角形求交（Möller–Trumbore，不做背面剔除）：返回沿射线的 t（<0 表示不交）
function rayTriangleT(o: Vec3, d: Vec3, a: Vec3, b: Vec3, c: Vec3): number {
  const e1x = b.x - a.x, e1y = b.y - a.y, e1z = b.z - a.z;
  const e2x = c.x - a.x, e2y = c.y - a.y, e2z = c.z - a.z;
  const px = d.y * e2z - d.z * e2y;
  const py = d.z * e2x - d.x * e2z;
  const pz = d.x * e2y - d.y * e2x;
  const det = e1x * px + e1y * py + e1z * pz;
  if (Math.abs(det) < 1e-12) {
    return -1;
  }
  const inv = 1.0 / det;
  const tx = o.x - a.x, ty = o.y - a.y, tz = o.z - a.z;
  const u = (tx * px + ty * py + tz * pz) * inv;
  if (u < -1e-6 || u > 1 + 1e-6) {
    return -1;
  }
  const qx = ty * e1z - tz * e1y;
  const qy = tz * e1x - tx * e1z;
  const qz = tx * e1y - ty * e1x;
  const v = (d.x * qx + d.y * qy + d.z * qz) * inv;
  if (v < -1e-6 || u + v > 1 + 1e-6) {
    return -1;
  }
  return (e2x * qx + e2y * qy + e2z * qz) * inv;
}

// 面索引：把网格按「共面连通的三角形」归并为逻辑面（一个平面 = 一个面）。
// 用于选面：避免把一个平面被识别成很多零碎的小三角面。
export class FaceIndex {
  triToGroup: number[] = [];     // 三角形 → 面组 id
  groupNormal: Vec3[] = [];      // 面组法线
  groupTris: number[][] = [];    // 面组包含的三角形索引
  triCount: number = 0;

  static build(g: MeshGeometry): FaceIndex {
    const fi = new FaceIndex();
    const hasIdx: boolean = g.hasIndices();
    const triCount: number = meshTriCount(g);
    fi.triCount = triCount;

    // 复用的坐标暂存（两种存储形态统一读；避免每个角点都分配一个 Vec3）
    const av: Vec3 = { x: 0, y: 0, z: 0 };
    const bv: Vec3 = { x: 0, y: 0, z: 0 };
    const cv: Vec3 = { x: 0, y: 0, z: 0 };
    const triNormalAt = (ti: number): Vec3 => {
      meshVertexAt(g, meshVertexIndex(g, ti, 0), av);
      meshVertexAt(g, meshVertexIndex(g, ti, 1), bv);
      meshVertexAt(g, meshVertexIndex(g, ti, 2), cv);
      return triangleNormal(av, bv, cv);
    };

    // 面法线：面汤优先用已存法线（与旧行为一致）；索引网格的 normals 是逐顶点平滑法线，
    // 不能当作面法线用，故一律由三点叉积算几何面法线。
    const nrmOf = (ti: number): Vec3 => {
      if (!hasIdx) {
        const idx: number = ti * 3;
        if (g.normals.length > idx && isFiniteVec3(g.normals[idx])) {
          return g.normals[idx];
        }
      }
      return triNormalAt(ti);
    };

    // 并查集
    const parent: number[] = new Array<number>(triCount);
    for (let i = 0; i < triCount; i++) { parent[i] = i; }
    const find = (x: number): number => {
      let r: number = x;
      while (parent[r] !== r) { r = parent[r]; }
      while (parent[x] !== r) { const n: number = parent[x]; parent[x] = r; x = n; }
      return r;
    };
    const union = (a: number, b: number): void => {
      const ra: number = find(a); const rb: number = find(b);
      if (ra !== rb) { parent[ra] = rb; }
    };

    // 顶点 → 三角形
    const vmap: Map<string, number[]> = new Map<string, number[]>();
    for (let i = 0; i < triCount; i++) {
      for (let k = 0; k < 3; k++) {
        meshVertexAt(g, meshVertexIndex(g, i, k), av);
        const key: string = `${av.x.toFixed(4)},${av.y.toFixed(4)},${av.z.toFixed(4)}`;
        let arr: number[] | undefined = vmap.get(key);
        if (arr === undefined) { arr = []; vmap.set(key, arr); }
        arr.push(i);
      }
    }

    // 共享顶点 + 法线近似 + 共面 → 归并
    vmap.forEach((arr: number[]) => {
      for (let x = 0; x < arr.length; x++) {
        for (let y = x + 1; y < arr.length; y++) {
          const t1: number = arr[x];
          const t2: number = arr[y];
          if (find(t1) === find(t2)) { continue; }
          const n1: Vec3 = nrmOf(t1);
          const n2: Vec3 = nrmOf(t2);
          const d: number = n1.x * n2.x + n1.y * n2.y + n1.z * n2.z;
          if (d > 0.9995) {
            meshVertexAt(g, meshVertexIndex(g, t1, 0), av);
            meshVertexAt(g, meshVertexIndex(g, t2, 0), bv);
            const off: number = n1.x * (bv.x - av.x) + n1.y * (bv.y - av.y) + n1.z * (bv.z - av.z);
            if (Math.abs(off) < 0.02) { union(t1, t2); }
          }
        }
      }
    });

    // 生成面组
    const groupMap: Map<number, number> = new Map<number, number>();
    fi.triToGroup = new Array<number>(triCount);
    for (let i = 0; i < triCount; i++) {
      const r: number = find(i);
      let gid: number | undefined = groupMap.get(r);
      if (gid === undefined) {
        gid = fi.groupNormal.length;
        groupMap.set(r, gid);
        fi.groupNormal.push(nrmOf(i));
        fi.groupTris.push([]);
      }
      fi.triToGroup[i] = gid;
      fi.groupTris[gid].push(i);
    }
    return fi;
  }

  // 精确定位：返回距点最近的三角形索引（点到三角形距离最小）
  nearestTriangle(g: MeshGeometry, p: Vec3): number {
    const triCount: number = meshTriCount(g);
    const a: Vec3 = { x: 0, y: 0, z: 0 };
    const b: Vec3 = { x: 0, y: 0, z: 0 };
    const c: Vec3 = { x: 0, y: 0, z: 0 };
    let best: number = -1;
    let bestD: number = 1e30;
    for (let i = 0; i < triCount; i++) {
      meshVertexAt(g, meshVertexIndex(g, i, 0), a);
      meshVertexAt(g, meshVertexIndex(g, i, 1), b);
      meshVertexAt(g, meshVertexIndex(g, i, 2), c);
      const d: number = distSqPointTriangle(p, a, b, c);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  // 射线拾取：返回沿射线（origin + t*dir）最先命中的三角形索引（-1 未命中）。
  // 边缘处比「最近点距离」更准：相邻两面共边时按射线先后（t 最小）判定。
  rayPick(g: MeshGeometry, origin: Vec3, dir: Vec3): number {
    const triCount: number = meshTriCount(g);
    const a: Vec3 = { x: 0, y: 0, z: 0 };
    const b: Vec3 = { x: 0, y: 0, z: 0 };
    const c: Vec3 = { x: 0, y: 0, z: 0 };
    let best: number = -1;
    let bestT: number = 1e30;
    for (let i = 0; i < triCount; i++) {
      meshVertexAt(g, meshVertexIndex(g, i, 0), a);
      meshVertexAt(g, meshVertexIndex(g, i, 1), b);
      meshVertexAt(g, meshVertexIndex(g, i, 2), c);
      const t: number = rayTriangleT(origin, dir, a, b, c);
      if (t > 1e-6 && t < bestT) {
        bestT = t;
        best = i;
      }
    }
    return best;
  }
}

// 从单位向量 a 旋转到单位向量 b 的四元数（最短弧）
export function fromToQuat(a: Vec3, b: Vec3): Quaternion {
  const la = Math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
  const lb = Math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z);
  if (la < 1e-9 || lb < 1e-9) {
    return { x: 0, y: 0, z: 0, w: 1 };
  }
  const ax = a.x / la, ay = a.y / la, az = a.z / la;
  const bx = b.x / lb, by = b.y / lb, bz = b.z / lb;
  const d = ax * bx + ay * by + az * bz;
  if (d > 0.999999) {
    return { x: 0, y: 0, z: 0, w: 1 };
  }
  if (d < -0.999999) {
    // 反平行：绕任意与 a 垂直的轴旋转 180°
    let ux = 1, uy = 0, uz = 0;
    if (Math.abs(ax) > 0.9) { ux = 0; uy = 1; }
    let cx = ay * uz - az * uy;
    let cy = az * ux - ax * uz;
    let cz = ax * uy - ay * ux;
    const cl = Math.sqrt(cx * cx + cy * cy + cz * cz);
    if (cl < 1e-9) { cx = 0; cy = 1; cz = 0; } else { cx /= cl; cy /= cl; cz /= cl; }
    return { x: cx, y: cy, z: cz, w: 0 };
  }
  const cx = ay * bz - az * by;
  const cy = az * bx - ax * bz;
  const cz = ax * by - ay * bx;
  const w = 1 + d;
  const l = Math.sqrt(cx * cx + cy * cy + cz * cz + w * w);
  return { x: cx / l, y: cy / l, z: cz / l, w: w / l };
}

// 构建打印底板（Y-up，XZ 平面为板面，中心在原点）。
// 按颜色分三组几何（板面/网格线/边框），由页面分别配 Unlit 材质实现确定性着色。
// plateSize 平台边长 mm，step 网格间距 mm

// 细长条面片（贴在板面上方 0.05mm 防 z-fighting）；yy 可覆盖贴板高度（校准线略高一点，避免与网格重叠闪烁）
function addBar(g: MeshGeometry, x0: number, z0: number, x1: number, z1: number, w: number, yy: number = 0.05): void {
  const dx = x1 - x0;
  const dz = z1 - z0;
  const l = Math.sqrt(dx * dx + dz * dz);
  if (l < 1e-6) { return; }
  const ux = dx / l, uz = dz / l;
  const px = -uz * w * 0.5, pz = ux * w * 0.5; // 垂直方向半宽
  const s = g.vertices.length;
  g.vertices.push(
    { x: x0 - px, y: yy, z: z0 - pz },
    { x: x1 - px, y: yy, z: z1 - pz },
    { x: x1 + px, y: yy, z: z1 + pz },
    { x: x0 + px, y: yy, z: z0 + pz }
  );
  for (let i = 0; i < 4; i++) { g.normals.push({ x: 0, y: 1, z: 0 }); }
  g.indices.push(s, s + 1, s + 2, s, s + 2, s + 3);
}

// 板面（单块四边形，深色）
export function buildPlate(plateSize: number): MeshGeometry {
  const g = new MeshGeometry();
  const h = plateSize / 2;
  g.vertices.push({ x: -h, y: 0, z: -h }, { x: h, y: 0, z: -h }, { x: h, y: 0, z: h }, { x: -h, y: 0, z: h });
  for (let i = 0; i < 4; i++) { g.normals.push({ x: 0, y: 1, z: 0 }); }
  g.indices.push(0, 1, 2, 0, 2, 3);
  return g;
}

// 网格线（细长条面片组，浅色）；plateW/plateH 为盘面尺寸 mm
export function buildGridLines(plateW: number, plateH: number, step: number): MeshGeometry {
  const g = new MeshGeometry();
  const hx = plateW / 2;
  const hz = plateH / 2;
  const nx = Math.floor(plateW / step);
  const nz = Math.floor(plateH / step);
  const w = 0.2;
  for (let i = 0; i <= nx; i++) {
    const p = -hx + i * step;
    addBar(g, p, -hz, p, hz, w); // 沿 Z 的线
  }
  for (let i = 0; i <= nz; i++) {
    const p = -hz + i * step;
    addBar(g, -hx, p, hx, p, w); // 沿 X 的线
  }
  return g;
}

// 边框（较粗的四条边，主题绿）；plateW/plateH 为盘面尺寸 mm
export function buildPlateBorder(plateW: number, plateH: number): MeshGeometry {
  const g = new MeshGeometry();
  const hx = plateW / 2;
  const hz = plateH / 2;
  const bw = 1.4;
  addBar(g, -hx, -hz, hx, -hz, bw);
  addBar(g, -hx, hz, hx, hz, bw);
  addBar(g, -hx, -hz, -hx, hz, bw);
  addBar(g, hx, -hz, hx, hz, bw);
  return g;
}

// 单喷嘴专属可打印区（如 H2D/H2C 左/右「仅 X 喷嘴可打印区域」、X2 左侧）。
// 渲染成一个【矩形面片】，贴板面略上方；材质侧开 alpha 混合 → 区域呈半透明，
// 可透出板面网格/底色（不再是纯色实心块）。区块内部不再有额外条纹/网格线。
// 入参用「盘面坐标」mm：x ∈ [minX, maxX]，z ∈ [minZ, maxZ]（与 buildGridLines 同口径，中心为 0）。
export function buildNozzleRegion(minX: number, maxX: number, minZ: number, maxZ: number): MeshGeometry {
  const g = new MeshGeometry();
  const w: number = maxX - minX;
  const d: number = maxZ - minZ;
  if (w <= 0 || d <= 0) {
    return g;
  }
  // 贴板高度：高于网格线（addBar 默认 0.05）与边框（buildPlateBorder 0.05），
  // 使半透明填充整片盖在网格之上（透明度由材质控制，网格仍可透出）。
  const yy = 0.16;
  const s = g.vertices.length;
  g.vertices.push(
    { x: minX, y: yy, z: minZ },
    { x: maxX, y: yy, z: minZ },
    { x: maxX, y: yy, z: maxZ },
    { x: minX, y: yy, z: maxZ }
  );
  for (let i = 0; i < 4; i++) { g.normals.push({ x: 0, y: 1, z: 0 }); }
  g.indices.push(s, s + 1, s + 2, s, s + 2, s + 3);
  return g;
}

// 单喷嘴专属可打印区的清晰边框（四条细边，略高于实心填充面，避免与填充面 z-fighting）。
// 与填充分开成独立几何 → 可用更亮的品牌绿描边，让「实心块 + 清晰边框」一眼可辨。
export function buildNozzleBorder(minX: number, maxX: number, minZ: number, maxZ: number): MeshGeometry {
  const g = new MeshGeometry();
  const w: number = maxX - minX;
  const d: number = maxZ - minZ;
  if (w <= 0 || d <= 0) {
    return g;
  }
  const yy = 0.18;
  const bw = 0.7;
  addBar(g, minX, minZ, maxX, minZ, bw, yy);
  addBar(g, minX, maxZ, maxX, maxZ, bw, yy);
  addBar(g, minX, minZ, minX, maxZ, bw, yy);
  addBar(g, maxX, minZ, maxX, maxZ, bw, yy);
  return g;
}

// 单喷嘴专属区【文字贴图】面片（贴板面的四边形，略高于填充/边框，避免 z-fighting）。
// 贴图内是「横排」文字，这里把 UV 旋转 90°：贴图 U 轴（文字阅读方向）→ 内容 +Z，
// V 轴（字高方向）→ 内容 +X，于是文字在板面上呈「沿带方向（Z）的竖排」，
// 且随板节点一起透视/倾斜——与拓竹的贴图同思路。
// 镜像修正（根因）：贴图 PNG 的 V 随「行号向下」增大（glTF/图像约定），此时「不镜像」要求
// ∂P/∂u × ∂P/∂v = −面法线（面法线 = +Y）。旧代码取 v 沿 +X → u×v = +Z×+X = +Y = +法线，
// 正好反号 → 文字左右镜像且上下颠倒。改为 v 取「−X 方向」（v=1 落在 minX、v=0 落在 maxX），
// 则 u×v = +Z×(−X) = −Y = −法线 → 文字读向正确、不镜像（俯视与旋转视角都正确）。
// 左右两条带共用本函数、顶点顺序相同（x0<x1、zc0<zc1），故同一处修正对两侧同时生效。
// 入参同 buildNozzleRegion（盘面坐标 mm）。
export function buildZoneLabelQuad(minX: number, maxX: number, minZ: number, maxZ: number): MeshGeometry {
  const g = new MeshGeometry();
  const w: number = maxX - minX;
  const d: number = maxZ - minZ;
  if (w <= 0 || d <= 0) {
    return g;
  }
  const yy = 0.22;
  g.vertices.push(
    { x: minX, y: yy, z: minZ },
    { x: maxX, y: yy, z: minZ },
    { x: maxX, y: yy, z: maxZ },
    { x: minX, y: yy, z: maxZ }
  );
  for (let i = 0; i < 4; i++) { g.normals.push({ x: 0, y: 1, z: 0 }); }
  g.uvs.push(
    { x: 0, y: 1 }, // (minX,minZ)  v 取反转：minX → v=1
    { x: 0, y: 0 }, // (maxX,minZ)  maxX → v=0
    { x: 1, y: 0 }, // (maxX,maxZ)
    { x: 1, y: 1 }  // (minX,maxZ)
  );
  g.indices.push(0, 1, 2, 0, 2, 3);
  return g;
}

// 网格实体体积（mm³）：散度定理逐三角面累加（闭合曲面与坐标系原点无关），取绝对值。
// 注：与包围盒体积不同，这是模型真实体积。
// 大网格（TypedArray）走扁平路径：全程只读 pos/idx，零 per-vertex 对象分配（旧版逐面取 Vec3
// 对象在百万面模型上会明显拖慢主线程，是导入卡顿/AppFreeze 的一个来源）。
export function meshVolume(g: MeshGeometry): number {
  const triCount: number = meshTriCount(g);
  let sum: number = 0;
  if (g.pos !== null) {
    const p: Float32Array = g.pos;
    let ix: Uint32Array = new Uint32Array(0);
    let hasIdx: boolean = false;
    if (g.idx !== null && g.idx.length > 0) { ix = g.idx; hasIdx = true; }
    for (let i = 0; i < triCount; i++) {
      const ia: number = (hasIdx ? ix[i * 3] : i * 3) * 3;
      const ib: number = (hasIdx ? ix[i * 3 + 1] : i * 3 + 1) * 3;
      const ic: number = (hasIdx ? ix[i * 3 + 2] : i * 3 + 2) * 3;
      const ax: number = p[ia], ay: number = p[ia + 1], az: number = p[ia + 2];
      const bx: number = p[ib], by: number = p[ib + 1], bz: number = p[ib + 2];
      const cx: number = p[ic], cy: number = p[ic + 1], cz: number = p[ic + 2];
      // a · (b × c)
      const qx: number = by * cz - bz * cy;
      const qy: number = bz * cx - bx * cz;
      const qz: number = bx * cy - by * cx;
      sum += ax * qx + ay * qy + az * qz;
    }
    return Math.abs(sum) / 6;
  }
  const v: Vec3[] = g.vertices;
  for (let i = 0; i < triCount; i++) {
    const a: Vec3 = v[meshVertexIndex(g, i, 0)];
    const b: Vec3 = v[meshVertexIndex(g, i, 1)];
    const c: Vec3 = v[meshVertexIndex(g, i, 2)];
    // a · (b × c)
    const cx: number = b.y * c.z - b.z * c.y;
    const cy: number = b.z * c.x - b.x * c.z;
    const cz: number = b.x * c.y - b.y * c.x;
    sum += a.x * cx + a.y * cy + a.z * cz;
  }
  return Math.abs(sum) / 6;
}

// ---------- 三维操作手柄（gizmo）网格 ----------
// 与方向 d 垂直的正交基：[u, v, d(单位)]
export function gizmoBasis(d: Vec3): Vec3[] {
  const l: number = Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  const dl: number = l > 1e-9 ? l : 1;
  const dz: Vec3 = { x: d.x / dl, y: d.y / dl, z: d.z / dl };
  const ref: Vec3 = Math.abs(dz.y) < 0.9 ? { x: 0, y: 1, z: 0 } : { x: 1, y: 0, z: 0 };
  let ux: number = ref.y * dz.z - ref.z * dz.y;
  let uy: number = ref.z * dz.x - ref.x * dz.z;
  let uz: number = ref.x * dz.y - ref.y * dz.x;
  const uu: number = Math.sqrt(ux * ux + uy * uy + uz * uz);
  const ul: number = uu > 1e-9 ? uu : 1;
  ux /= ul; uy /= ul; uz /= ul;
  const vx: number = dz.y * uz - dz.z * uy;
  const vy: number = dz.z * ux - dz.x * uz;
  const vz: number = dz.x * uy - dz.y * ux;
  return [{ x: ux, y: uy, z: uz }, { x: vx, y: vy, z: vz }, dz];
}

function gizmoTri(g: MeshGeometry, a: Vec3, b: Vec3, c: Vec3): void {
  const n: Vec3 = triangleNormal(a, b, c);
  const s: number = g.vertices.length;
  g.vertices.push(a, b, c);
  g.normals.push(n, n, n);
  g.indices.push(s, s + 1, s + 2);
}

function gizmoQuad(g: MeshGeometry, a: Vec3, b: Vec3, c: Vec3, d: Vec3): void {
  gizmoTri(g, a, b, c);
  gizmoTri(g, a, c, d);
}

// 手柄箭头：从 origin 沿 dir 画一根杆 + 箭头（boxHead=true 时箭头为方块，用于缩放）
export function buildGizmoArrow(origin: Vec3, dir: Vec3, len: number, shaftR: number,
                                headR: number, headLen: number, seg: number, boxHead: boolean): MeshGeometry {
  const g: MeshGeometry = new MeshGeometry();
  const b: Vec3[] = gizmoBasis(dir);
  const u: Vec3 = b[0], v: Vec3 = b[1], d: Vec3 = b[2];
  const shaftLen: number = Math.max(0.001, len - headLen);
  const neck: Vec3 = { x: origin.x + d.x * shaftLen, y: origin.y + d.y * shaftLen, z: origin.z + d.z * shaftLen };
  const tip: Vec3 = { x: origin.x + d.x * len, y: origin.y + d.y * len, z: origin.z + d.z * len };
  const corner = (c: Vec3, su: number, sv: number): Vec3 => ({
    x: c.x + u.x * su + v.x * sv, y: c.y + u.y * su + v.y * sv, z: c.z + u.z * su + v.z * sv
  });
  // 杆（四棱柱）
  const a0: Vec3 = corner(origin, -shaftR, -shaftR);
  const a1: Vec3 = corner(origin, shaftR, -shaftR);
  const a2: Vec3 = corner(origin, shaftR, shaftR);
  const a3: Vec3 = corner(origin, -shaftR, shaftR);
  const b0: Vec3 = corner(neck, -shaftR, -shaftR);
  const b1: Vec3 = corner(neck, shaftR, -shaftR);
  const b2: Vec3 = corner(neck, shaftR, shaftR);
  const b3: Vec3 = corner(neck, -shaftR, shaftR);
  gizmoQuad(g, a0, a1, b1, b0);
  gizmoQuad(g, a1, a2, b2, b1);
  gizmoQuad(g, a2, a3, b3, b2);
  gizmoQuad(g, a3, a0, b0, b3);
  gizmoQuad(g, a3, a2, a1, a0); // 底盖
  if (boxHead) {
    const c0: Vec3 = corner(neck, -headR, -headR);
    const c1: Vec3 = corner(neck, headR, -headR);
    const c2: Vec3 = corner(neck, headR, headR);
    const c3: Vec3 = corner(neck, -headR, headR);
    const e0: Vec3 = corner(tip, -headR, -headR);
    const e1: Vec3 = corner(tip, headR, -headR);
    const e2: Vec3 = corner(tip, headR, headR);
    const e3: Vec3 = corner(tip, -headR, headR);
    gizmoQuad(g, c0, c1, e1, e0);
    gizmoQuad(g, c1, c2, e2, e1);
    gizmoQuad(g, c2, c3, e3, e2);
    gizmoQuad(g, c3, c0, e0, e3);
    gizmoQuad(g, e3, e2, e1, e0); // 顶端
    gizmoQuad(g, c0, c3, c2, c1); // 底端
  } else {
    // 圆锥头
    const ring: Vec3[] = [];
    for (let i = 0; i < seg; i++) {
      const th: number = i / seg * Math.PI * 2;
      ring.push(corner(neck, Math.cos(th) * headR, Math.sin(th) * headR));
    }
    for (let i = 0; i < seg; i++) {
      const j: number = (i + 1) % seg;
      gizmoTri(g, ring[i], ring[j], tip);
      gizmoTri(g, neck, ring[j], ring[i]); // 底盖
    }
  }
  return g;
}

// 手柄圆弧环（旋转盘）：在垂直 axis 的平面内、以 center 为圆心画一段环带
export function buildGizmoRing(center: Vec3, axis: Vec3, radius: number, band: number,
                               thick: number, seg: number, arcDeg: number): MeshGeometry {
  const g: MeshGeometry = new MeshGeometry();
  const b: Vec3[] = gizmoBasis(axis);
  const u: Vec3 = b[0], v: Vec3 = b[1], d: Vec3 = b[2];
  const steps: number = Math.max(3, Math.round(seg * (arcDeg / 360)));
  const rIn: number = radius - band * 0.5;
  const rOut: number = radius + band * 0.5;
  const pt = (r: number, th: number, off: number): Vec3 => {
    const c: number = Math.cos(th) * r;
    const s: number = Math.sin(th) * r;
    return {
      x: center.x + u.x * c + v.x * s + d.x * off,
      y: center.y + u.y * c + v.y * s + d.y * off,
      z: center.z + u.z * c + v.z * s + d.z * off,
    };
  };
  const arc: number = arcDeg * Math.PI / 180;
  const ht: number = thick * 0.5;
  for (let i = 0; i < steps; i++) {
    const t0: number = arc * (i / steps);
    const t1: number = arc * ((i + 1) / steps);
    const iIn0: Vec3 = pt(rIn, t0, 0), iOut0: Vec3 = pt(rOut, t0, 0);
    const iIn1: Vec3 = pt(rIn, t1, 0), iOut1: Vec3 = pt(rOut, t1, 0);
    const oIn0: Vec3 = pt(rIn, t0, ht), oOut0: Vec3 = pt(rOut, t0, ht);
    const oIn1: Vec3 = pt(rIn, t1, ht), oOut1: Vec3 = pt(rOut, t1, ht);
    const mIn0: Vec3 = pt(rIn, t0, -ht), mOut0: Vec3 = pt(rOut, t0, -ht);
    const mIn1: Vec3 = pt(rIn, t1, -ht), mOut1: Vec3 = pt(rOut, t1, -ht);
    gizmoQuad(g, oOut0, oOut1, iOut1, iOut0);   // 上表面
    gizmoQuad(g, mIn0, mIn1, iIn1, iIn0);       // 下表面
    gizmoQuad(g, iOut0, iOut1, mOut1, mOut0);   // 外壁
    gizmoQuad(g, mIn0, mIn1, oIn1, oIn0);       // 内壁
  }
  // 两端封口
  const a0: Vec3 = pt(rIn, 0, -ht), a1: Vec3 = pt(rOut, 0, -ht), a2: Vec3 = pt(rOut, 0, ht), a3: Vec3 = pt(rIn, 0, ht);
  gizmoQuad(g, a0, a1, a2, a3);
  const b0: Vec3 = pt(rIn, arc, -ht), b1: Vec3 = pt(rOut, arc, -ht), b2: Vec3 = pt(rOut, arc, ht), b3: Vec3 = pt(rIn, arc, ht);
  gizmoQuad(g, b0, b3, b2, b1);
  return g;
}

// 自动适配视口：按模型最大边长估算相机距离
export function autoFitDistance(maxDim: number): number {
  if (maxDim <= 0) {
    return 300;
  }
  return Math.max(180, maxDim * 2.4);
}

// 拖动像素 → 平移量换算（随相机距离缩放）
export function panPerPixel(dist: number): number {
  return Math.max(0.05, dist * 0.0016);
}
