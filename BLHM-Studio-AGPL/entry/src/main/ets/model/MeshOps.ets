import {
  MeshGeometry, meshVertexIndex, meshVertexAt, meshTriCount, repairNormals,
  quatInverse, rotateVecByQuat
} from './MeshUtils';
import type { Vec3, Quaternion } from '@kit.ArkGraphics3D';

// =============================================================================
// 网格级编辑的最小工具集（纯 ETS，不依赖内核）：
//   · splitConnected —— 按「共享顶点连通」把网格拆成多个连通体（拆分到对象）
//   · bestUpAxis     —— 自动定向：选「接触面积最大」的轴向作为朝下方向
//
// 为什么先放 ETS：这两项只读几何、不改几何，放主线程即可完成；
// 内核的 split/orient 留到后续（需要 3MF 往返与零件树）再替换，接口保持不变。
// =============================================================================

export class SplitPart {
  geometry: MeshGeometry = new MeshGeometry();
  triangles: number = 0;
}

// 合并输入：几何 + 它在内容坐标系里的世界变换。
// 第一个元素是「基准对象」，其余对象会换算到基准对象的局部坐标系后再拼接。
export class MergePart {
  geometry: MeshGeometry = new MeshGeometry();
  rotation: Quaternion = { x: 0, y: 0, z: 0, w: 1 };
  position: Vec3 = { x: 0, y: 0, z: 0 };
  scale: Vec3 = { x: 1, y: 1, z: 1 };
}

// 交给内核的索引网格（统一 Float32 顶点 + Uint32 索引）
export class IndexedArrays {
  positions: Float32Array = new Float32Array(0);
  indices: Uint32Array = new Uint32Array(0);
}

export class MeshOps {
  // 按连通性拆分：三角形之间只要有共享顶点就属于同一块。
  // 输出按三角形数降序（第一块通常是主体）。单一连通体时返回 1 个元素。
  static splitConnected(g: MeshGeometry): SplitPart[] {
    const triCount: number = meshTriCount(g);
    if (triCount <= 0) {
      return [];
    }
    const parent: Int32Array = new Int32Array(triCount);
    for (let i = 0; i < triCount; i++) {
      parent[i] = i;
    }
    const find = (x: number): number => {
      let r: number = x;
      while (parent[r] !== r) {
        r = parent[r];
      }
      while (parent[x] !== r) {
        const n: number = parent[x];
        parent[x] = r;
        x = n;
      }
      return r;
    };
    const union = (a: number, b: number): void => {
      const ra: number = find(a);
      const rb: number = find(b);
      if (ra !== rb) {
        parent[ra] = rb;
      }
    };

    // 顶点键：索引网格直接用顶点下标；三角形汤按坐标焊（1e-3 mm 精度）。
    const hasIdx: boolean = g.hasIndices();
    const firstOfVertex: Map<string, number> = new Map<string, number>();
    const p: Vec3 = { x: 0, y: 0, z: 0 };
    const keyOfCorner = (ti: number, k: number): string => {
      const vi: number = meshVertexIndex(g, ti, k);
      if (hasIdx) {
        return `i${vi}`;
      }
      meshVertexAt(g, vi, p);
      return `${p.x.toFixed(3)},${p.y.toFixed(3)},${p.z.toFixed(3)}`;
    };
    for (let ti = 0; ti < triCount; ti++) {
      for (let k = 0; k < 3; k++) {
        const key: string = keyOfCorner(ti, k);
        const prev: number | undefined = firstOfVertex.get(key);
        if (prev === undefined) {
          firstOfVertex.set(key, ti);
        } else {
          union(prev, ti);
        }
      }
    }

    const groups: Map<number, number[]> = new Map<number, number[]>();
    for (let ti = 0; ti < triCount; ti++) {
      const r: number = find(ti);
      let arr: number[] | undefined = groups.get(r);
      if (arr === undefined) {
        arr = [];
        groups.set(r, arr);
      }
      arr.push(ti);
    }

    const out: SplitPart[] = [];
    groups.forEach((tris: number[]) => {
      const remap: Map<string, number> = new Map<string, number>();
      const pos: number[] = [];
      const idx: number[] = [];
      for (const ti of tris) {
        for (let k = 0; k < 3; k++) {
          const key: string = keyOfCorner(ti, k);
          let vi: number | undefined = remap.get(key);
          if (vi === undefined) {
            vi = pos.length / 3;
            remap.set(key, vi);
            meshVertexAt(g, meshVertexIndex(g, ti, k), p);
            pos.push(p.x, p.y, p.z);
          }
          idx.push(vi);
        }
      }
      const geo: MeshGeometry = new MeshGeometry();
      geo.pos = new Float32Array(pos);
      geo.idx = new Uint32Array(idx);
      // 大网格跳过法线修复（与导入路径同一口径：>30 万面会带来秒级开销）
      if (tris.length <= 300000) {
        repairNormals(geo);
      }
      const part: SplitPart = new SplitPart();
      part.geometry = geo;
      part.triangles = tris.length;
      out.push(part);
    });

    out.sort((a: SplitPart, b: SplitPart): number => b.triangles - a.triangles);
    return out;
  }

  // 合并多个对象为一个网格：以第一个为基准，其余对象先按世界变换换算到基准局部坐标，再拼接。
  // 公式：local = inv(qBase) * ((qPart * (v * sPart) + pPart) - pBase) / sBase
  static mergeIntoBase(parts: MergePart[]): MeshGeometry {
    const out: MeshGeometry = new MeshGeometry();
    if (parts.length === 0) {
      return out;
    }
    const base: MergePart = parts[0];
    const invBase: Quaternion = quatInverse(base.rotation);
    const bsx: number = Math.abs(base.scale.x) < 1e-9 ? 1 : base.scale.x;
    const bsy: number = Math.abs(base.scale.y) < 1e-9 ? 1 : base.scale.y;
    const bsz: number = Math.abs(base.scale.z) < 1e-9 ? 1 : base.scale.z;
    const pos: number[] = [];
    const idx: number[] = [];
    let vertexOffset: number = 0;
    const p: Vec3 = { x: 0, y: 0, z: 0 };
    for (let pi = 0; pi < parts.length; pi++) {
      const part: MergePart = parts[pi];
      const g: MeshGeometry = part.geometry;
      const vc: number = g.vertexCount();
      if (pi === 0) {
        // 基准对象：顶点已是基准局部坐标，原样拷贝
        if (g.pos !== null) {
          const src: Float32Array = g.pos;
          for (let i = 0; i < src.length; i++) {
            pos.push(src[i]);
          }
        } else {
          for (const v of g.vertices) {
            pos.push(v.x, v.y, v.z);
          }
        }
      } else {
        for (let i = 0; i < vc; i++) {
          meshVertexAt(g, i, p);
          const sv: Vec3 = {
            x: p.x * part.scale.x,
            y: p.y * part.scale.y,
            z: p.z * part.scale.z
          };
          const rv: Vec3 = rotateVecByQuat(part.rotation, sv);
          const wx: number = (rv.x + part.position.x - base.position.x) / bsx;
          const wy: number = (rv.y + part.position.y - base.position.y) / bsy;
          const wz: number = (rv.z + part.position.z - base.position.z) / bsz;
          const lv: Vec3 = rotateVecByQuat(invBase, { x: wx, y: wy, z: wz });
          pos.push(lv.x, lv.y, lv.z);
        }
      }
      if (g.idx !== null) {
        const si: Uint32Array = g.idx;
        for (let i = 0; i < si.length; i++) {
          idx.push(si[i] + vertexOffset);
        }
      } else if (g.indices.length > 0) {
        for (const i of g.indices) {
          idx.push(i + vertexOffset);
        }
      } else {
        for (let i = 0; i < vc; i++) {
          idx.push(i + vertexOffset);
        }
      }
      vertexOffset += vc;
    }
    out.pos = new Float32Array(pos);
    out.idx = new Uint32Array(idx);
    if (idx.length / 3 <= 300000) {
      repairNormals(out);
    }
    return out;
  }

  // 统一成内核可消费的索引网格（对象数组 / 无索引面汤都展开成显式索引）。
  static toIndexed(g: MeshGeometry): IndexedArrays {
    const out: IndexedArrays = new IndexedArrays();
    const vc: number = g.vertexCount();
    const pos: Float32Array = new Float32Array(vc * 3);
    if (g.pos !== null) {
      const n: number = Math.min(g.pos.length, vc * 3);
      for (let i = 0; i < n; i++) {
        pos[i] = g.pos[i];
      }
    } else {
      for (let i = 0; i < vc; i++) {
        const v: Vec3 = g.vertices[i];
        pos[i * 3] = v.x;
        pos[i * 3 + 1] = v.y;
        pos[i * 3 + 2] = v.z;
      }
    }
    const tc: number = meshTriCount(g);
    const idx: Uint32Array = new Uint32Array(tc * 3);
    if (g.idx !== null) {
      const n: number = Math.min(g.idx.length, tc * 3);
      for (let i = 0; i < n; i++) {
        idx[i] = g.idx[i];
      }
    } else if (g.indices.length > 0) {
      const n: number = Math.min(g.indices.length, tc * 3);
      for (let i = 0; i < n; i++) {
        idx[i] = g.indices[i];
      }
    } else {
      for (let i = 0; i < tc * 3; i++) {
        idx[i] = i;
      }
    }
    out.positions = pos;
    out.indices = idx;
    return out;
  }

  // 把 part 的几何换算到 base 的局部坐标系（布尔运算前把两个对象拉到同一空间）。
  static bakeToBase(part: MergePart, base: MergePart): MeshGeometry {
    const g: MeshGeometry = part.geometry;
    const vc: number = g.vertexCount();
    const pos: Float32Array = new Float32Array(vc * 3);
    const invBase: Quaternion = quatInverse(base.rotation);
    const bsx: number = Math.abs(base.scale.x) < 1e-9 ? 1 : base.scale.x;
    const bsy: number = Math.abs(base.scale.y) < 1e-9 ? 1 : base.scale.y;
    const bsz: number = Math.abs(base.scale.z) < 1e-9 ? 1 : base.scale.z;
    const p: Vec3 = { x: 0, y: 0, z: 0 };
    for (let i = 0; i < vc; i++) {
      meshVertexAt(g, i, p);
      const sv: Vec3 = { x: p.x * part.scale.x, y: p.y * part.scale.y, z: p.z * part.scale.z };
      const rv: Vec3 = rotateVecByQuat(part.rotation, sv);
      const wx: number = (rv.x + part.position.x - base.position.x) / bsx;
      const wy: number = (rv.y + part.position.y - base.position.y) / bsy;
      const wz: number = (rv.z + part.position.z - base.position.z) / bsz;
      const lv: Vec3 = rotateVecByQuat(invBase, { x: wx, y: wy, z: wz });
      pos[i * 3] = lv.x;
      pos[i * 3 + 1] = lv.y;
      pos[i * 3 + 2] = lv.z;
    }
    const out: MeshGeometry = new MeshGeometry();
    out.pos = pos;
    const tc: number = meshTriCount(g);
    const idx: Uint32Array = new Uint32Array(tc * 3);
    if (g.idx !== null) {
      const n: number = Math.min(g.idx.length, tc * 3);
      for (let i = 0; i < n; i++) {
        idx[i] = g.idx[i];
      }
    } else if (g.indices.length > 0) {
      const n: number = Math.min(g.indices.length, tc * 3);
      for (let i = 0; i < n; i++) {
        idx[i] = g.indices[i];
      }
    } else {
      for (let i = 0; i < tc * 3; i++) {
        idx[i] = i;
      }
    }
    out.idx = idx;
    return out;
  }

  // 自动定向：找「法线朝 -axis 的总面积」最大的轴，把该轴转到 +Y（内容坐标系）。
  // 对盒子/零件类模型效果好；球体等各向同性时返回 +Y（保持不动）。
  static bestUpAxis(g: MeshGeometry): Vec3 {
    const triCount: number = meshTriCount(g);
    const areaPos: number[] = [0, 0, 0];
    const areaNeg: number[] = [0, 0, 0];
    const a: Vec3 = { x: 0, y: 0, z: 0 };
    const b: Vec3 = { x: 0, y: 0, z: 0 };
    const c: Vec3 = { x: 0, y: 0, z: 0 };
    for (let ti = 0; ti < triCount; ti++) {
      meshVertexAt(g, meshVertexIndex(g, ti, 0), a);
      meshVertexAt(g, meshVertexIndex(g, ti, 1), b);
      meshVertexAt(g, meshVertexIndex(g, ti, 2), c);
      const ux: number = b.x - a.x;
      const uy: number = b.y - a.y;
      const uz: number = b.z - a.z;
      const vx: number = c.x - a.x;
      const vy: number = c.y - a.y;
      const vz: number = c.z - a.z;
      let nx: number = uy * vz - uz * vy;
      let ny: number = uz * vx - ux * vz;
      let nz: number = ux * vy - uy * vx;
      const len: number = Math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len < 1e-9) {
        continue;
      }
      const area: number = len * 0.5;
      nx /= len;
      ny /= len;
      nz /= len;
      const ax: number = Math.abs(nx);
      const ay: number = Math.abs(ny);
      const az: number = Math.abs(nz);
      if (ax > 0.9 && ax >= ay && ax >= az) {
        if (nx > 0) { areaPos[0] += area; } else { areaNeg[0] += area; }
      } else if (ay > 0.9 && ay >= az) {
        if (ny > 0) { areaPos[1] += area; } else { areaNeg[1] += area; }
      } else if (az > 0.9) {
        if (nz > 0) { areaPos[2] += area; } else { areaNeg[2] += area; }
      }
    }
    // 候选「朝上轴」：+X/-X/+Y/-Y/+Z/-Z；其接触面积 = 相反方向法线的面积和
    let bestScore: number = 0;
    let bestIndex: number = 2; // 默认 +Y
    for (let axis = 0; axis < 3; axis++) {
      if (areaNeg[axis] > bestScore) {
        bestScore = areaNeg[axis];
        bestIndex = axis * 2;      // 正轴朝上
      }
      if (areaPos[axis] > bestScore) {
        bestScore = areaPos[axis];
        bestIndex = axis * 2 + 1;  // 负轴朝上
      }
    }
    if (bestScore < 1) {
      return { x: 0, y: 1, z: 0 };
    }
    if (bestIndex === 0) { return { x: 1, y: 0, z: 0 }; }
    if (bestIndex === 1) { return { x: -1, y: 0, z: 0 }; }
    if (bestIndex === 2) { return { x: 0, y: 1, z: 0 }; }
    if (bestIndex === 3) { return { x: 0, y: -1, z: 0 }; }
    if (bestIndex === 4) { return { x: 0, y: 0, z: 1 }; }
    return { x: 0, y: 0, z: -1 };
  }
}
