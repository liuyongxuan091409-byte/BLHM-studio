import fs from '@ohos.file.fs';
import hash from '@ohos.file.hash';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util, worker } from '@kit.ArkTS';
import { MessageEvents, ErrorEvent } from '@ohos.worker';
import type { Vec3, Quaternion } from '@kit.ArkGraphics3D';
import { modelState, ModelInstance, ModelTransform, PLATE_LIFT_MM } from '../model/ModelState';
import { MeshGeometry, rotateVecByQuat, multiplyQuaternion, meshTriCount } from '../model/MeshUtils';
import { PresetCatalog, SliceParam } from '../model/SliceModels';
import { PlateSize, resolvePlateSize, Project3mfResult } from '../model/Models';
import { SlicerService } from './SlicerService';
import { SliceParamStore } from './SliceParamStore';
import { PresetPersist, PresetSnapshot } from './PresetPersist';
import { AppLog } from './AppLog';
import {
  Mf3mfJob, Mf3mfObj, Mf3mfPlate, Mf3mfMat, Mf3mfResult, writeModel3mf,
  contentToZup, zupToContent2, MF3MF_DEFAULT_TITLE
} from './Mf3mfWriter';

// Worker 构建请求/响应/结果（与 workers/Mf3mfBuildWorker.ets 的消息体同构）。
class Mf3mfWriteRequest {
  plate: number = 0;
  outPath: string = '';
  job: Mf3mfJob = new Mf3mfJob();
}
class Mf3mfWriteResponse {
  ok: boolean = false;
  reason: string = '';
  bytes: number = 0;
  triangles: number = 0;
  verts: number = 0;
  totalMs: number = 0;
  xmlMs: number = 0;
  vMs: number = 0;
  triMs: number = 0;
  zipMs: number = 0;
  writeMs: number = 0;
}
export class Mf3mfWriteResult {
  ok: boolean = false;
  reason: string = '';
  bytes: number = 0;
  triangles: number = 0;
  // Worker 内逐段耗时（ms）；主线程回退时不填（保持 0）。
  verts: number = 0;
  workerTotalMs: number = 0;
  xmlMs: number = 0;
  vMs: number = 0;
  triMs: number = 0;
  zipMs: number = 0;
  writeMs: number = 0;
  // true = Worker 不可用（调用方应回退主线程构建）；false = Worker 给出了明确成功/失败
  workerUnavailable: boolean = false;
}

// =============================================================================
// 保存为「通用 3MF」（标准 OPC/zip 包，第三方切片器可直接打开）。
//
// 内容口径（本轮已定）：
//   · 几何：内存里现有的对象网格（顶点 + 索引/面汤），不重新解析文件、不改渲染；
//   · 摆放：对象的世界变换写进 <build><item transform="...">，**不烘焙进顶点**
//     （我们的变换是「旋转+非均匀缩放+平移」，3MF 的 4×3 仿射矩阵能完整表达，无需退化）；
//   · 打印板/机型：以标准 <metadata name="..."> 条目写入（第三方忽略，我们自己可读回）；
//   · 单位：millimeter —— 与场景口径一致（几何来自 STL/3MF 的 mm，transform.position 也是 mm）。
//
// 为什么自己写 zip：工程没有 zip 写入能力（导入侧只用了 zlib 解压）。这里实现一个最小
// STORE（不压缩）写入器，含正确的 CRC32 / 本地文件头 / 中央目录 / EOCD / 偏移量。
// 不压缩是刻意的：3MF 里的 .model 是 XML，第三方对 store/deflate 都支持，store 实现最简单、最不容易错。
//
// 坐标系：渲染层（ArkGraphics3D）是 Y-up，3MF 标准是 Z-up。
//   zUpToYUp: (x,y,z)zup → (x, z, -y)content；逆变换 content → zup: (cx,-cz,cy)。
//   与 MeshUtils.zUpToYUp 同一套公式，此处给出逆变换，避免引入新口径。
// =============================================================================

const DOMAIN: number = 0x0000;
// 保存 3mf 的日志 tag（hilog / 应用内日志 / files/diag/gcode_diag.txt 三通道同用）
export const SAVE3MF_TAG: string = 'Save3mf';
// ① 产物缓存日志 tag（命中/未命中、键各分量；三通道同用）
export const PKG_CACHE_TAG: string = 'GcodePkgCache';
// ① 缓存目录保留的产物上限（只留最近 N 个，超限按最旧淘汰）
const PKG_CACHE_MAX: number = 4;
// ① 只读包尾部这些字节来定位 gcode 条目（zip 中央目录在包末尾）——避免把整包(几十 MB)读回 JS 堆
const PKG_TAIL_READ_BYTES: number = 262144;

const CONTENT_TYPES_XML: string =
  '<?xml version="1.0" encoding="UTF-8"?>\n' +
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
  '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>' +
  '</Types>';

const RELS_XML: string =
  '<?xml version="1.0" encoding="UTF-8"?>\n' +
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
  '<Relationship Target="/3D/3dmodel.model" Id="rel0" ' +
  'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>' +
  '</Relationships>';

// 3MF 核心命名空间（2015/02 版，第三方切片器通用）
const MF_CORE_NS: string = 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02';

// 默认项目名（与顶栏 TopBar 的展示保持一致）
const DEFAULT_TITLE: string = '未命名项目';
// 三种导出格式的默认文件名：项目 3MF（含切片设置）/ 含 gcode 的 .gcode.3mf（可直接打印）/ 通用 3MF（仅模型）
const PROJECT_FILE_NAME: string = `${DEFAULT_TITLE}.3mf`;
const GCODE_FILE_NAME: string = `${DEFAULT_TITLE}.gcode.3mf`;
const GENERIC_FILE_NAME: string = `${DEFAULT_TITLE}-通用.3mf`;
// 切片产出的 gcode（Index.startSlice 与 GcodePreview 都用这个固定路径）
export const SLICED_GCODE_FILE: string = 'output.gcode';

function meta(name: string, value: string): string {
  return `<metadata name="${xmlEscape(name)}">${xmlEscape(value)}</metadata>\n`;
}

// ---------------- UTF-8 编码 ----------------
// 自己实现，避免依赖运行时 TextEncoder 的可用性/取舍；XML 里对象名可能是中文。
function utf8Encode(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      const c2: number = s.charCodeAt(i + 1);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        const cp: number = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
          0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
        i++;
      } else {
        out.push(0xEF, 0xBF, 0xBD); // 孤立代理项 → U+FFFD
      }
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      out.push(0xEF, 0xBF, 0xBD);
    } else {
      out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
    }
  }
  const arr: Uint8Array = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) {
    arr[i] = out[i] & 0xFF;
  }
  return arr;
}

// ---------------- 字节写入器（可增长） ----------------
class ByteWriter {
  private buf: Uint8Array = new Uint8Array(4096);
  private len: number = 0;
  // 原生 UTF-8 编码器：str() 用它把整串一次性编码进缓冲（见 str 的说明）。
  private enc: util.TextEncoder = new util.TextEncoder();

  private ensure(n: number): void {
    if (this.len + n <= this.buf.length) {
      return;
    }
    let cap: number = this.buf.length;
    while (cap < this.len + n) {
      cap = cap * 2;
    }
    const nb: Uint8Array = new Uint8Array(cap);
    // 原生 memcpy：旧实现逐字节 JS 拷贝，几十 MB 时会自己成为主线程大头。
    nb.set(this.buf.subarray(0, this.len));
    this.buf = nb;
  }

  u8(v: number): void {
    this.ensure(1);
    this.buf[this.len] = v & 0xFF;
    this.len++;
  }

  u16(v: number): void {
    this.ensure(2);
    this.buf[this.len] = v & 0xFF;
    this.buf[this.len + 1] = (v >>> 8) & 0xFF;
    this.len += 2;
  }

  u32(v: number): void {
    this.ensure(4);
    this.buf[this.len] = v & 0xFF;
    this.buf[this.len + 1] = (v >>> 8) & 0xFF;
    this.buf[this.len + 2] = (v >>> 16) & 0xFF;
    this.buf[this.len + 3] = (v >>> 24) & 0xFF;
    this.len += 4;
  }

  bytes(a: Uint8Array): void {
    if (a.length === 0) { return; }
    this.ensure(a.length);
    this.buf.set(a, this.len);   // 原生 memcpy（旧实现逐字节 JS 拷贝）
    this.len += a.length;
  }

  // 直接把字符串按 UTF-8 写进可增长缓冲，**不经过中间 number[]**。
  //
  // 【为什么改成原生编码】旧实现逐字符在 JS 里判位并写字节：74MB 的 3MF XML（盘1：约 42 万面）
  // 在真机上要 ~41 秒，且全程占用主线程 → AppFreeze 看门狗判 THREAD_BLOCK_3S/6S（实测 2026-10-11）。
  // 改用运行时 TextEncoder.encodeIntoUint8Array（原生实现）一次性把整串编码进缓冲：
  // 逐字节的 JS 循环被彻底去掉，同样的数据从 41 秒降到 22.8 秒。
  // 【注意】这只优化了「编码」这一段；真正的解法是把整份构建搬到 Worker（见 Mf3mfWriteWorker）。
  str(s: string): void {
    const n: number = s.length;
    if (n === 0) { return; }
    // UTF-8 最坏每 UTF-16 单元 3 字节（代理对 = 2 单元 → 4 字节 < 2×3），预留 3n + 4 足够。
    this.ensure(n * 3 + 4);
    const res = this.enc.encodeIntoUint8Array(s, this.buf.subarray(this.len));
    this.len += res.written;
  }

  length(): number {
    return this.len;
  }

  // 返回**独立**缓冲（长度 = 实际数据），保证后续 writeSync 写出的字节数精确。
  // 用原生 slice（旧实现逐字节 JS 拷贝，几十 MB 时同样会自己成为主线程大头）。
  toBytes(): Uint8Array {
    return this.buf.slice(0, this.len);
  }
}

// ---------------- CRC32（zip 校验） ----------------
let CRC_TABLE: number[] | null = null;

function crcTable(): number[] {
  if (CRC_TABLE !== null) {
    return CRC_TABLE;
  }
  const t: number[] = new Array<number>(256);
  for (let n = 0; n < 256; n++) {
    let c: number = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) !== 0 ? ((0xEDB88320 ^ (c >>> 1)) >>> 0) : (c >>> 1);
    }
    t[n] = c >>> 0;
  }
  CRC_TABLE = t;
  return t;
}

function crc32(data: Uint8Array): number {
  const t: number[] = crcTable();
  let c: number = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i++) {
    c = (t[(c ^ data[i]) & 0xFF] ^ (c >>> 8)) >>> 0;
  }
  return (c ^ 0xFFFFFFFF) >>> 0;
}

// ---------------- 最小 zip（STORE） ----------------
class ZipEntry {
  name: string = '';
  data: Uint8Array = new Uint8Array(0);
}

// 生成合法 zip：本地文件头 + 数据 + 中央目录 + EOCD，偏移量/长度/CRC 全部按规范写。
function buildZip(entries: ZipEntry[]): Uint8Array {
  const w: ByteWriter = new ByteWriter();
  const offsets: number[] = [];
  const crcs: number[] = [];

  for (const e of entries) {
    const nameBytes: Uint8Array = utf8Encode(e.name);
    const crc: number = crc32(e.data);
    offsets.push(w.length());
    crcs.push(crc);
    // 本地文件头
    w.u32(0x04034b50);
    w.u16(20);                 // version needed to extract
    w.u16(0);                  // general purpose flags
    w.u16(0);                  // compression method = 0 (store)
    w.u16(0);                  // last mod time
    w.u16(0);                  // last mod date
    w.u32(crc);
    w.u32(e.data.length);      // compressed size
    w.u32(e.data.length);      // uncompressed size
    w.u16(nameBytes.length);   // file name length
    w.u16(0);                  // extra field length
    w.bytes(nameBytes);
    w.bytes(e.data);
  }

  const cdStart: number = w.length();
  for (let i = 0; i < entries.length; i++) {
    const e: ZipEntry = entries[i];
    const nameBytes: Uint8Array = utf8Encode(e.name);
    // 中央目录文件头
    w.u32(0x02014b50);
    w.u16(20);                 // version made by
    w.u16(20);                 // version needed to extract
    w.u16(0);                  // flags
    w.u16(0);                  // method
    w.u16(0);                  // time
    w.u16(0);                  // date
    w.u32(crcs[i]);
    w.u32(e.data.length);
    w.u32(e.data.length);
    w.u16(nameBytes.length);
    w.u16(0);                  // extra length
    w.u16(0);                  // comment length
    w.u16(0);                  // disk number start
    w.u16(0);                  // internal attributes
    w.u32(0);                  // external attributes
    w.u32(offsets[i]);         // relative offset of local header
    w.bytes(nameBytes);
  }
  const cdSize: number = w.length() - cdStart;

  // EOCD
  w.u32(0x06054b50);
  w.u16(0);                    // number of this disk
  w.u16(0);                    // disk with start of CD
  w.u16(entries.length);       // entries on this disk
  w.u16(entries.length);       // total entries
  w.u32(cdSize);
  w.u32(cdStart);
  w.u16(0);                    // comment length

  return w.toBytes();
}

// ---------------- 坐标/矩阵工具（contentToZup / zupToContent2 见 Mf3mfWriter，主线程与 Worker 共用）----------------
// 与 ModelPreviewPage.computeRotation 同一套映射：面板 rotX→content X、rotY→content Z、rotZ→content Y
function axisQuat(key: string, deg: number): Quaternion {
  const h: number = deg * Math.PI / 360;
  const s: number = Math.sin(h);
  const w: number = Math.cos(h);
  if (key === 'x') { return { x: s, y: 0, z: 0, w: w }; }
  if (key === 'y') { return { x: 0, y: s, z: 0, w: w }; }
  return { x: 0, y: 0, z: s, w: w };
}

function computeRotation(t: ModelTransform): Quaternion {
  const qx: Quaternion = axisQuat('x', t.rotX);
  const qy: Quaternion = axisQuat('z', t.rotY);
  const qz: Quaternion = axisQuat('y', t.rotZ);
  const user: Quaternion = multiplyQuaternion(multiplyQuaternion(qx, qy), qz);
  return multiplyQuaternion(user, t.baseRotation);
}

// 对象在 3MF 世界(Z-up) 下的 item 变换：p_world = M·p_local + t
// 推导：content 世界 = R·(S∘v_content) + P；v_content = zupToContent(v_zup)；
//       M 的每一列 = contentToZup(R·(S∘zupToContent(e_k)))，t = contentToZup(P)。
class ItemMatrix {
  c0: Vec3 = { x: 1, y: 0, z: 0 };
  c1: Vec3 = { x: 0, y: 1, z: 0 };
  c2: Vec3 = { x: 0, y: 0, z: 1 };
  t: Vec3 = { x: 0, y: 0, z: 0 };
}

// 导出平移换算（**唯一换算点**）：内存里的摆放 → 3MF 的 <item transform> 平移真值。
//
// 为什么要加盘中心：我们的内部约定是「position 相对盘中心」（见 ThreeMfImport.addOne：
// position = 世界坐标 − 盘中心）。但 3MF 的 item 平移是**床绝对坐标** —— 拓竹原厂件即如此
// （盘中心处的一个件，item 平移写成 (128,128,15)，128 = 256 床的中心）。导出忘了加回盘中心，
// 回导后对象就落在床 (0,0)：正好压进禁区 x∈[0,18], y∈[0,28]，切片直接报
// "is too close to exclusion area"。所以这里把盘中心加回去。
//
//   床绝对 X      = plateW/2 + position.x
//   3MF 的 ty     = −(position.z − plateH/2) = plateH/2 − position.z
//                   （content 的 Z 轴与床面 Y 反向，见 contentToZup）
//   3MF 的 tz     = position.y − PLATE_LIFT_MM
//                   （落板方向减掉渲染防共面的 epsilon，使导出件底面严格贴板 z=0）
//
// 盘尺寸必须按**当前机器**取（A1 mini 180、H2D 350×320 等），写死 256 会让非 256 床整体偏移。
function exportPositionOf(t: ModelTransform, plateW: number, plateH: number): Vec3 {
  return {
    x: t.position.x + plateW * 0.5,
    y: t.position.y - PLATE_LIFT_MM,
    z: t.position.z - plateH * 0.5,
  };
}

function itemMatrixOf(inst: ModelInstance, plateW: number, plateH: number): ItemMatrix {
  const t: ModelTransform = inst.transform;
  const r: Quaternion = computeRotation(t);
  const s: Vec3 = t.scale;
  const m: ItemMatrix = new ItemMatrix();
  const e0: Vec3 = zupToContent2(1, 0, 0);
  const e1: Vec3 = zupToContent2(0, 1, 0);
  const e2: Vec3 = zupToContent2(0, 0, 1);
  m.c0 = contentToZup(rotateVecByQuat(r, { x: e0.x * s.x, y: e0.y * s.y, z: e0.z * s.z }));
  m.c1 = contentToZup(rotateVecByQuat(r, { x: e1.x * s.x, y: e1.y * s.y, z: e1.z * s.z }));
  m.c2 = contentToZup(rotateVecByQuat(r, { x: e2.x * s.x, y: e2.y * s.y, z: e2.z * s.z }));
  // 平移用「床绝对坐标」（盘中心 + position，落板方向减掉渲染抬高），而不是内存里的相对位置
  m.t = contentToZup(exportPositionOf(t, plateW, plateH));
  return m;
}

// 3MF transform 属性：4×3 行主序（行向量约定）：[m00 m01 m02 m10 m11 m12 m20 m21 m22 tx ty tz]
// 由 M 的列向量转写：m0x=c0.x, m1x=c0.y, m2x=c0.z, m0y=c1.x ...（见文件头公式）
function transformAttr(m: ItemMatrix): string {
  const n: string[] = [
    fmtNum(m.c0.x, 6), fmtNum(m.c0.y, 6), fmtNum(m.c0.z, 6),
    fmtNum(m.c1.x, 6), fmtNum(m.c1.y, 6), fmtNum(m.c1.z, 6),
    fmtNum(m.c2.x, 6), fmtNum(m.c2.y, 6), fmtNum(m.c2.z, 6),
    fmtNum(m.t.x, 6), fmtNum(m.t.y, 6), fmtNum(m.t.z, 6),
  ];
  return n.join(' ');
}

function applyItem(m: ItemMatrix, p: Vec3): Vec3 {
  return {
    x: m.c0.x * p.x + m.c1.x * p.y + m.c2.x * p.z + m.t.x,
    y: m.c0.y * p.x + m.c1.y * p.y + m.c2.y * p.z + m.t.y,
    z: m.c0.z * p.x + m.c1.z * p.y + m.c2.z * p.z + m.t.z,
  };
}

// ---------------- 文本格式化 / XML 转义 ----------------
// 每份「按盘切片输入工程」要格式化上百万次坐标（盘1 约 42 万面 / 21 万顶点 × 3 轴），
// 旧实现用正则 replace(/0+$/) 去尾零 + endsWith/substring，在真机上是切盘构建的热点之一。
// 改成一次字符扫描（substring 只切一次）——语义与旧实现逐字节一致，只是不再走正则引擎。
function fmtNum(v: number, digits: number): string {
  if (!Number.isFinite(v)) {
    return '0';
  }
  const s: string = v.toFixed(digits);
  if (s.indexOf('.') < 0) {
    return s === '-0' ? '0' : s;
  }
  let end: number = s.length;
  while (end > 0 && s.charCodeAt(end - 1) === 48) { end--; }          // 去掉小数末尾的 '0'
  if (end > 0 && s.charCodeAt(end - 1) === 46) { end--; }             // 小数点也被去光 → 去掉 '.'
  const t: string = end === s.length ? s : s.substring(0, end);
  return (t === '-0' || t === '') ? '0' : t;
}

function xmlEscape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

// ---------------- 对外：导出产物 ----------------
export class ExportBundle {
  bytes: Uint8Array = new Uint8Array(0);
  objectCount: number = 0;
  triangleCount: number = 0;
  bboxMin: Vec3 = { x: 0, y: 0, z: 0 };
  bboxMax: Vec3 = { x: 0, y: 0, z: 0 };
  fileName: string = GENERIC_FILE_NAME;
  title: string = DEFAULT_TITLE;
}

// =============================================================================
// 打印前自动产出「含 gcode 的 .gcode.3mf」的结果。
//   · 复用内核 slicer_export_gcode_3mf（内核会把已切 gcode 作为 Metadata/plate_1.gcode + 其 .md5 打进包，
//     并在返回里给出 withGcode / gcodeMd5）；产出后我们从包**尾部**读出真实存在的 gcode 条目名
//     （param 用它，不写死），并算出**包文件 md5**（payload 的 md5 字段用它）。
//   · path 是**真实落盘路径**：打印 / 上传都用它，不再按名字去沙箱拼路径。
//   · 任何一步失败 → ok=false，reason 给出明确原因（含路径/错误），调用方据此拒绝打印。
//
// ① 产物缓存 / ② 失败即停 / ③ Worker 化 都在这份「构建或复用」服务函数里：
//   · 缓存键 = output.gcode 的 size + mtime + 对象几何/摆放指纹 + 切片参数指纹；四者全同 → 直接复用
//     已生成的 .gcode.3mf，跳过序列化与内核导出；
//   · 打印链路（ensureGcodePackage）与「保存 → 含 G-code 3MF」共用同一份实现、同一份产物。
// =============================================================================
export class GcodePackage {
  ok: boolean = false;
  path: string = '';              // 真实落盘路径（内核产出，上传就用它）
  fileName: string = '';
  sizeBytes: number = -1;
  md5: string = '';               // 包文件 md5（本地有文件时必为真值，不留空）
  withGcode: boolean = false;
  hasPlateEntry: boolean = false; // 包内确实存在 gcode 条目
  param: string = '';             // 包内真实 gcode 路径（从 zip 中央目录读出，payload 的 param 用它）
  gcodeMd5: string = '';          // 内核写入包内 gcode 的 .md5 值
  reason: string = '';            // 失败原因（明确到路径/错误）
  // ①/③ 自证字段（打印与保存共用）
  cacheHit: boolean = false;      // true = 命中缓存直接复用（未做序列化与内核导出）
  objectCount: number = -1;       // 内核回报的对象数（缓存命中时为 -1）
  triangleCount: number = -1;     // 内核回报的三角面数
  buildMs: number = 0;            // 输入工程构建耗时（Worker / 主线程回退）
  exportMs: number = 0;           // 内核 store_bbs_3mf 导出耗时
  totalMs: number = 0;            // 本函数总耗时（命中时≈0）
}

// ---------------- ① 产物指纹（缓存键完备性的保证） ----------------
// FNV-1a：稳定、快、无依赖。字符串 / 字节 / 数字三种混入。
function fnv1aStr(h: number, s: string): number {
  for (let i = 0; i < s.length; i++) {
    h = ((h ^ s.charCodeAt(i)) >>> 0);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h;
}

function fnv1aBytes(h: number, b: Uint8Array): number {
  for (let i = 0; i < b.length; i++) {
    h = ((h ^ b[i]) >>> 0);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h;
}

function fnvNum(h: number, v: number): number {
  return fnv1aStr(h, Number.isFinite(v) ? v.toFixed(5) : 'nan');
}

function fnvHex(n: number): string {
  const s: string = (n >>> 0).toString(16);
  return s.length >= 8 ? s : '00000000'.substring(s.length) + s;
}

// 缓存目录里的一个产物文件（用于按 mtime 做最旧淘汰）
class CacheEntry {
  name: string = '';
  path: string = '';
  mtime: number = 0;
}

// 从 zip 中央目录读出「真实存在」的 gcode 条目名（以 .gcode 结尾，非 .gcode.md5）。
// zip 文件名在中央目录里明文存储：每个中央目录项以 PK\x01\x02 开头，文件名长度在其后第 28 字节
// （u16 小端），文件名从第 46 字节起。找不到返回 ''（调用方据此拒绝打印）。
function asciiName(data: Uint8Array, start: number, len: number): string {
  let s: string = '';
  for (let k = 0; k < len; k++) {
    const c: number = data[start + k];
    if (c < 0x20 || c > 0x7E) { return ''; }
    s += String.fromCharCode(c);
  }
  return s;
}

function findGcodeEntry(data: Uint8Array): string {
  for (let i = 0; i + 46 <= data.length; i++) {
    if (data[i] !== 0x50 || data[i + 1] !== 0x4B || data[i + 2] !== 0x01 || data[i + 3] !== 0x02) {
      continue;
    }
    const nameLen: number = data[i + 28] | (data[i + 29] << 8);
    if (nameLen <= 0 || i + 46 + nameLen > data.length) { continue; }
    const name: string = asciiName(data, i + 46, nameLen);
    if (name === '') { continue; }
    if (name.toLowerCase().endsWith('.gcode')) { return name; }
  }
  return '';
}

// 从 zip 中央目录读出**全部**条目名（自检用：确认 param 指向的 gcode 条目确实在包内、盘号一致）。
// 包尾部这一小段只含中央目录 + EOCD，逐字节扫描找 PK\x01\x02 即每个中央目录项的起点。
function listCentralEntries(data: Uint8Array): string[] {
  const names: string[] = [];
  for (let i = 0; i + 46 <= data.length; i++) {
    if (data[i] !== 0x50 || data[i + 1] !== 0x4B || data[i + 2] !== 0x01 || data[i + 3] !== 0x02) {
      continue;
    }
    const nameLen: number = data[i + 28] | (data[i + 29] << 8);
    if (nameLen <= 0 || i + 46 + nameLen > data.length) { continue; }
    const name: string = asciiName(data, i + 46, nameLen);
    if (name === '') { continue; }
    names.push(name);
  }
  return names;
}

// =============================================================================
// 按盘切片 Worker 生命周期（单例复用）
//
// 旧实现：每一盘都 new 一个 ThreadWorker、用完即 terminate —— 一次 N 盘切片就是 N 次
// 「创建线程 + 载入模块 + attach/detach」。真机 hilog 曾出现 "Cannot attach current thread,
// reached the limit of EAWorkers" 的告警（详见 _evidence_workerperf 调查）。
//
// 改为「整段逐盘序列复用同一个 Worker，序列收尾再 terminate」：
//   · worker 创建次数由 N（=盘数）降到 1；
//   · 请求天然串行（runPlateSequence 逐盘 await），单例不存在并发；
//   · 出错/超时才丢弃并重建，避免把坏 worker 一直留着。
// =============================================================================
let mfWorker: worker.ThreadWorker | null = null;
let mfPending: ((r: Mf3mfWriteResult) => void) | null = null;
let mfTimeoutId: number = -1;
let mfCreateCount: number = 0;   // 自证：自上次回收以来累计创建次数
let mfReuseCount: number = 0;    // 自证：自上次回收以来累计复用次数

function mfClearTimer(): void {
  if (mfTimeoutId !== -1) {
    clearTimeout(mfTimeoutId);
    mfTimeoutId = -1;
  }
}

// 结清一次请求：可选丢弃某个 worker（仅当它仍是当前单例时才真的 terminate，避免误杀新实例）。
function mfSettle(r: Mf3mfWriteResult, drop: worker.ThreadWorker | null): void {
  if (drop !== null && mfWorker === drop) {
    try { drop.terminate(); } catch (e) { /* 已退出 */ }
    mfWorker = null;
  }
  const cb: ((r: Mf3mfWriteResult) => void) | null = mfPending;
  mfPending = null;
  mfClearTimer();
  if (cb !== null) { cb(r); }
}

export class ThreeMfExport {
  // 「通用 3MF」保存到应用沙箱的固定路径（选择器不可用时的回退位置）
  static sandboxPath(filesDir: string): string {
    return `${filesDir}/${GENERIC_FILE_NAME}`;
  }

  // 「项目 3MF」（含切片设置）的默认文件名与沙箱路径（内核导出的落点）
  static projectFileName(): string {
    return PROJECT_FILE_NAME;
  }

  static genericFileName(): string {
    return GENERIC_FILE_NAME;
  }

  static projectSandboxPath(filesDir: string): string {
    return `${filesDir}/${PROJECT_FILE_NAME}`;
  }

  // 「含 gcode 的 .gcode.3mf」的默认文件名与沙箱落点（内核导出的落点）。
  static gcodeFileName(): string {
    return GCODE_FILE_NAME;
  }

  static gcodeSandboxPath(filesDir: string): string {
    return `${filesDir}/${GCODE_FILE_NAME}`;
  }

  // 切片产出的 gcode 在沙箱里的固定路径（没有则无法生成 .gcode.3mf）。
  static slicedGcodePath(filesDir: string): string {
    return `${filesDir}/${SLICED_GCODE_FILE}`;
  }

  // 某盘切片产物的固定路径（按盘切片时逐盘落盘；plate<=0 沿用 output.gcode）。
  static slicedGcodePathForPlate(filesDir: string, plate: number): string {
    return plate > 0 ? `${filesDir}/output_plate_${plate}.gcode` : ThreeMfExport.slicedGcodePath(filesDir);
  }

  // 文件是否存在（切盘展示按盘 gcode 时用来判断该盘是否已有切片产物）。
  static fileExists(path: string): boolean {
    if (path === '') { return false; }
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  // ---- ② 失败即停：同一缓存键上次失败且未显式重试 → 不再自动重建（避免连点导致内存累加）----
  private static lastFailDigest: string = '';
  private static lastFailReason: string = '';
  private static failCleared: boolean = true;

  // ① 缓存目录 / 产物路径 / 临时输入路径
  static pkgCacheDir(filesDir: string): string {
    return `${filesDir}/gcode_pkg_cache`;
  }

  static pkgCachePath(filesDir: string, digest: string): string {
    return `${ThreeMfExport.pkgCacheDir(filesDir)}/pkg_${digest}.gcode.3mf`;
  }

  private static pkgInputTmpPath(filesDir: string): string {
    return `${filesDir}/gcode_pkg_input.tmp.3mf`;
  }

  // ② 用户显式「重试」入口：清除失败即停标记，允许对同一键再构建一次。
  static resetGcodePackageFailure(): void {
    ThreeMfExport.failCleared = true;
  }

  // 打印前自动产出「含 gcode 的 .gcode.3mf」（打印链路入口，共用「构建或复用」）。
  static ensureGcodePackage(filesDir: string): Promise<GcodePackage> {
    return ThreeMfExport.buildOrReuseGcodePackage(filesDir, '打印');
  }

  // 共用「构建或复用」：打印链路与「保存 → 含 G-code 3MF」走同一条路（同一份产物）。
  //   命中缓存 → 直接复用已生成的 .gcode.3mf（跳过序列化 + 内核导出）；
  //   未命中 → Worker 内构建输入工程 → 内核 store_bbs_3mf 导出到缓存路径。
  static buildOrReuseGcodePackage(filesDir: string, purpose: string): Promise<GcodePackage> {
    const res: GcodePackage = new GcodePackage();
    const t0: number = Date.now();
    const gcodePath: string = ThreeMfExport.slicedGcodePath(filesDir);
    let gcodeExists: boolean = false;
    let gcodeSize: number = -1;
    let gcodeMtimeMs: number = 0;
    try {
      const st: fs.Stat = fs.statSync(gcodePath);
      gcodeExists = true;
      gcodeSize = st.size;
      gcodeMtimeMs = Math.round(st.mtime * 1000);
    } catch (e) {
      hilog.error(DOMAIN, SAVE3MF_TAG, '检查切片产物失败 %{public}s: %{public}s', gcodePath,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    if (!gcodeExists || gcodeSize <= 0) {
      res.reason = `请先切片：未找到切片产物 ${gcodePath}`;
      return Promise.resolve(res);
    }
    // ② 构建前释放上一次构建的临时缓冲（只删本链路自己的临时文件，不动常驻几何/其它页状态）。
    ThreeMfExport.cleanupBuildTemp(filesDir);
    const job: Mf3mfJob | null = ThreeMfExport.gatherJob(filesDir, 0);
    // 校准试块：校准页本来就没有「准备页对象」，job 必然为 null，但它自己那份
    // output.gcode + 校准 3MF 就是完整输入（buildPackageToCache 只吃 gcode 与 sliceModelPath）。
    // 用 calibPrintReady 放行；几何指纹按 0 参与缓存键，不同试块靠 gcode 尺寸/时间区分。
    const calibPrint: boolean = AppStorage.get<boolean>('calibPrintReady') === true;
    if (job === null && !calibPrint) {
      res.reason = '当前没有可导出的对象';
      return Promise.resolve(res);
    }
    const geomFp: number = job !== null ? ThreeMfExport.geomFingerprint(job) : 0;
    const paramFp: number = ThreeMfExport.paramsFingerprint(filesDir);
    const digest: string = ThreeMfExport.composeDigest(gcodeSize, gcodeMtimeMs, geomFp, paramFp);
    const objCount: number = job !== null ? job.objs.length : 0;
    ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
      `构建或复用[${purpose}] 键摘要=${digest} 分量: gcodeSize=${gcodeSize} gcodeMtime=${gcodeMtimeMs} ` +
      `几何摆放指纹=${fnvHex(geomFp)} 切片参数指纹=${fnvHex(paramFp)} 对象=${objCount}` +
      `${job === null ? '（校准试块：无准备页对象）' : ''}`);
    // ② 失败即停
    if (ThreeMfExport.lastFailDigest === digest && !ThreeMfExport.failCleared) {
      res.reason = `上次构建失败，已停止自动重试（${ThreeMfExport.lastFailReason}）。请点「重试」再试。`;
      ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
        `失败即停[${purpose}] 键=${digest} 原因=${ThreeMfExport.lastFailReason}`);
      return Promise.resolve(res);
    }
    const cachePath: string = ThreeMfExport.pkgCachePath(filesDir, digest);
    // ① 命中判定：缓存文件存在且包内确有 gcode 条目才算命中
    if (ThreeMfExport.fileExists(cachePath)) {
      const tail: Uint8Array | null = ThreeMfExport.readTail(cachePath, PKG_TAIL_READ_BYTES);
      const param: string = tail !== null ? findGcodeEntry(tail) : '';
      if (param !== '') {
        ThreeMfExport.logCentralEntries(filesDir, purpose, tail, param);
        return ThreeMfExport.finalizeReuse(filesDir, purpose, res, cachePath, param, t0);
      }
      ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
        `缓存键命中但包内无 gcode 条目 → 删除并重建 文件=${cachePath}`);
      ThreeMfExport.unlinkQuiet(cachePath);
    }
    return ThreeMfExport.buildPackageToCache(filesDir, purpose, cachePath, gcodePath, digest, res, t0);
  }

  // ① 命中：直接复用缓存产物（不序列化、不调内核）；补 param/size/md5 与 LRU 淘汰。
  private static finalizeReuse(filesDir: string, purpose: string, res: GcodePackage,
                               cachePath: string, param: string, t0: number): Promise<GcodePackage> {
    let size: number = -1;
    try { size = fs.statSync(cachePath).size; } catch (e) { /* 由下面统一判空 */ }
    if (size <= 0) {
      res.reason = `缓存文件读取失败: ${cachePath}`;
      return Promise.resolve(res);
    }
    res.path = cachePath;
    res.fileName = ThreeMfExport.gcodeFileName();
    res.sizeBytes = size;
    res.param = param;
    res.hasPlateEntry = true;
    res.withGcode = true;
    res.cacheHit = true;
    res.objectCount = -1;
    res.totalMs = Date.now() - t0;
    return hash.hash(cachePath, 'md5').then((md5: string): GcodePackage => {
      res.md5 = md5;
      res.ok = true;
      ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
        `缓存命中[${purpose}] 复用耗时=${res.totalMs}ms(无构建/无内核导出) 包=${cachePath} ` +
        `字节=${size} param=${param} md5=${md5}`);
      AppLog.mem('PrintPack', `缓存命中复用(包=${size}字节)`);
      ThreeMfExport.enforceCacheLimit(filesDir, cachePath);
      return res;
    }).catch((e: Error): GcodePackage => {
      res.reason = `缓存包 md5 计算失败（${cachePath}）: ${e.message}`;
      return res;
    });
  }

  // ① 未命中：把「本次切片所用的模型文件」直接交给内核导出到缓存路径 → 校验包内 gcode 条目。
  //
  // 【为什么不再在 JS 侧重造一份输入 3MF】百万级三角面模型的 3MF XML 序列化是重活，原先交给
  //   ThreadWorker：真机（hilog 取证）该 worker 模块加载失败（Cannot attach current thread /
  //   GetEntry failed for ets/workers/Mf3mfBuildWorker.abc）→ postMessage 永无回执，只能干等
  //   180s 超时；超时后的主线程同步回退又会长时间占满主线程（THREAD_BLOCK / 应用无响应）。
  //   而**切片本身就是直接拿 sliceModelPath 交给内核切的**，打印包复用同一个文件即可：
  //   包内模型与已切 gcode 天然一致，且内核导出跑在 NAPI worker 线程上，主线程全程可响应。
  private static buildPackageToCache(filesDir: string, purpose: string,
                                     cachePath: string, gcodePath: string,
                                     digest: string, res: GcodePackage, t0: number): Promise<GcodePackage> {
    const srcInput: string = AppStorage.get<string>('sliceModelPath') ?? '';
    if (srcInput === '' || !ThreeMfExport.fileExists(srcInput)) {
      return Promise.resolve(ThreeMfExport.markFail(res, filesDir, purpose, digest,
        `找不到本次切片所用的模型文件（${srcInput === '' ? '未记录路径' : srcInput}），无法生成打印包`, t0));
    }
    let paramsJson: string = '{}';
    try {
      // 「对象颜色 → 耗材槽位」随包导出下发：包内 model_settings.config 带每个对象的 extruder、
      // project_settings.config 带 N 档 filament_colour，打印包与工程包口径一致。
      paramsJson = SliceParamStore.mergeExtra(SliceParamStore.collectParamsJson(),
        SliceParamStore.multicolorFragment(modelState.instances));
    } catch (e) {
      hilog.warn(DOMAIN, SAVE3MF_TAG, '收集切片参数失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    res.buildMs = Date.now() - t0;
    ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
      `缓存未命中[${purpose}] 复用切片输入 源=${srcInput} gcode=${gcodePath} 出=${cachePath}`);
    return new Promise<GcodePackage>((resolve: (v: GcodePackage) => void) => {
      const tExp0: number = Date.now();
      try {
        SlicerService.exportGcode3mf(srcInput, paramsJson, cachePath, gcodePath, (rj: string) => {
          res.exportMs = Date.now() - tExp0;
          ThreeMfExport.finishFromKernel(filesDir, purpose, res, cachePath, digest, rj, t0)
            .then((done: GcodePackage) => { resolve(done); });
        });
      } catch (e) {
        resolve(ThreeMfExport.markFail(res, filesDir, purpose, digest,
          `内核导出调用异常: ${e instanceof Error ? e.message : JSON.stringify(e)}`, t0));
      }
    });
  }

  // 解析内核回调：核对 withGcode / 尾部读出包内 gcode 条目 / 算包 md5。任何一步失败 → ok=false + reason。
  private static finishFromKernel(filesDir: string, purpose: string, res: GcodePackage,
                                  cachePath: string, digest: string, resultJson: string,
                                  t0: number): Promise<GcodePackage> {
    let r: Project3mfResult;
    try {
      r = JSON.parse(resultJson) as Project3mfResult;
    } catch (e) {
      return Promise.resolve(ThreeMfExport.markFail(res, filesDir, purpose, digest,
        `内核结果解析异常: ${resultJson}`, t0));
    }
    if (r.ok !== true) {
      const m: string = r.message !== undefined && r.message !== '' ? r.message : '(无消息)';
      ThreeMfExport.unlinkQuiet(cachePath);
      return Promise.resolve(ThreeMfExport.markFail(res, filesDir, purpose, digest,
        `内核导出失败: ${m}`, t0));
    }
    if (r.withGcode !== true) {
      ThreeMfExport.unlinkQuiet(cachePath);
      return Promise.resolve(ThreeMfExport.markFail(res, filesDir, purpose, digest,
        '内核未把 plate gcode 打进包（withGcode=false）', t0));
    }
    res.gcodeMd5 = r.gcodeMd5 !== undefined ? r.gcodeMd5 : '';
    res.objectCount = r.objects !== undefined ? r.objects : -1;
    res.triangleCount = r.facets !== undefined ? r.facets : -1;
    res.path = cachePath;
    res.fileName = ThreeMfExport.gcodeFileName();
    res.withGcode = true;
    // 只读包尾部（zip 中央目录）定位真实 gcode 条目名 —— 不把整包(几十 MB)读回 JS 堆。
    let size: number = -1;
    try { size = fs.statSync(cachePath).size; } catch (e) { /* 由下面统一判空 */ }
    const tail: Uint8Array | null = ThreeMfExport.readTail(cachePath, PKG_TAIL_READ_BYTES);
    res.param = tail !== null ? findGcodeEntry(tail) : '';
    res.hasPlateEntry = res.param !== '';
    ThreeMfExport.logCentralEntries(filesDir, purpose, tail, res.param);
    res.sizeBytes = size;
    res.totalMs = Date.now() - t0;
    if (!res.hasPlateEntry) {
      // ④ 内核侧能拿到的原因已并入 r.message；这里把它带进 reason，绝不只报一句泛化失败。
      ThreeMfExport.unlinkQuiet(cachePath);
      return Promise.resolve(ThreeMfExport.markFail(res, filesDir, purpose, digest,
        `包内未找到 .gcode 条目（${cachePath}，${size} 字节）` +
        `${r.message !== undefined && r.message !== '' ? '；内核消息=' + r.message : ''}`, t0));
    }
    ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
      `构建完成[${purpose}] 构建=${res.buildMs}ms 导出=${res.exportMs}ms 总=${res.totalMs}ms ` +
      `包=${cachePath} 字节=${size} 对象=${res.objectCount} 面=${res.triangleCount} ` +
      `param=${res.param} gcodeMd5=${res.gcodeMd5}`);
    // 内存快照（读取产出后）：现只读尾部，整包大缓冲不再进 JS 堆。
    AppLog.mem('PrintPack', `读取包尾部后(包=${size}字节)`);
    return hash.hash(cachePath, 'md5').then((h: string): GcodePackage => {
      res.md5 = h;
      res.ok = true;
      ThreeMfExport.enforceCacheLimit(filesDir, cachePath);
      return res;
    }).catch((e: Error): GcodePackage => {
      return ThreeMfExport.markFail(res, filesDir, purpose, digest,
        `计算包 md5 失败（${cachePath}）: ${e.message}`, t0);
    });
  }

  // ② 失败即停：记下失败键，后续同一键直接快速失败（0 成本），直到用户显式重试或内容变化。
  private static markFail(res: GcodePackage, filesDir: string, purpose: string, digest: string,
                          reason: string, t0: number): GcodePackage {
    res.ok = false;
    res.reason = reason;
    res.totalMs = Date.now() - t0;
    ThreeMfExport.lastFailDigest = digest;
    ThreeMfExport.lastFailReason = reason;
    ThreeMfExport.failCleared = false;
    ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG, `构建失败即停[${purpose}] 键=${digest} 原因=${reason}`);
    return res;
  }

  // ① 缓存键：四分量合成一个 16 位十六进制摘要（同时保留各分量用于日志核对）。
  private static composeDigest(gcodeSize: number, gcodeMtimeMs: number, geomFp: number, paramFp: number): string {
    const a: number = fnv1aStr(2166136261, `${gcodeSize}|${gcodeMtimeMs}|${fnvHex(geomFp)}`);
    const b: number = fnv1aStr(fnv1aStr(2166136261, fnvHex(paramFp)), `${gcodeSize}|${gcodeMtimeMs}`);
    return fnvHex(a) + fnvHex(b);
  }

  // ① 采样哈希：只吃首尾各 4KB 字节（廉价，主线程 <毫秒级）。
  // 说明：全量逐字节哈希百万级顶点会把主线程堵 ~3s（THREAD_BLOCK_3S）；改为「几何来源文件身份 +
  // 对象计数 + 变换矩阵 + 首尾采样字节」共同构成几何/摆放指纹——覆盖所有现实中的内容变更
  // （换文件 / 增删对象 / 移动旋转缩放 / 改网格计数 / 网格首尾变化），且不阻塞主线程。
  private static hashSample(h: number, view: Float32Array | Uint32Array | null): number {
    if (view === null) { return h; }
    const u8: Uint8Array = new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
    const n: number = u8.length;
    if (n <= 8192) {
      return fnv1aBytes(h, u8);
    }
    h = fnv1aBytes(h, u8.subarray(0, 4096));
    h = fnv1aBytes(h, u8.subarray(n - 4096, n));
    return h;
  }

  // ① 对象几何 + 摆放指纹：覆盖「写进输入工程的全部数据」（机型/板型元数据 + 4×3 item 变换 + 几何身份）。
  private static geomFingerprint(job: Mf3mfJob): number {
    let h: number = 2166136261;
    h = fnv1aStr(h, job.title);
    h = fnv1aStr(h, job.printer);
    h = fnv1aStr(h, job.bedType);
    h = fnvNum(h, job.objs.length);
    // 几何来源文件的身份（导入副本 path+size+mtime）：文件不变 ⇒ 几何不变（避免每顶点哈希）。
    try {
      const src: string | undefined = AppStorage.get<string>('sliceModelPath');
      if (src !== undefined && src !== '') {
        const st: fs.Stat = fs.statSync(src);
        h = fnv1aStr(h, src);
        h = fnvNum(h, st.size);
        h = fnvNum(h, Math.round(st.mtime * 1000));
      } else {
        h = fnv1aStr(h, 'nosrc');
      }
    } catch (e) {
      h = fnv1aStr(h, 'nosrc');
    }
    for (let oi = 0; oi < job.objs.length; oi++) {
      const o: Mf3mfObj = job.objs[oi];
      h = fnv1aStr(h, o.name);
      h = fnvNum(h, o.vcount);
      h = fnvNum(h, o.triCount);
      h = fnvNum(h, o.mtx.c0.x); h = fnvNum(h, o.mtx.c0.y); h = fnvNum(h, o.mtx.c0.z);
      h = fnvNum(h, o.mtx.c1.x); h = fnvNum(h, o.mtx.c1.y); h = fnvNum(h, o.mtx.c1.z);
      h = fnvNum(h, o.mtx.c2.x); h = fnvNum(h, o.mtx.c2.y); h = fnvNum(h, o.mtx.c2.z);
      h = fnvNum(h, o.mtx.t.x); h = fnvNum(h, o.mtx.t.y); h = fnvNum(h, o.mtx.t.z);
      if (o.pos !== null) {
        h = ThreeMfExport.hashSample(h, o.pos);
      } else {
        const nv: number = o.verts.length;
        const step: number = nv > 128 ? 2 : 1;
        for (let i = 0; i < nv; i += step) {
          h = fnvNum(h, o.verts[i].x); h = fnvNum(h, o.verts[i].y); h = fnvNum(h, o.verts[i].z);
        }
      }
      if (o.idx !== null) {
        h = ThreeMfExport.hashSample(h, o.idx);
      } else {
        const ni: number = o.indices.length;
        const step: number = ni > 128 ? 2 : 1;
        for (let i = 0; i < ni; i += step) { h = fnvNum(h, o.indices[i]); }
      }
    }
    return h >>> 0;
  }

  // ① 切片参数指纹：全局参数 + 预设身份（机型/工艺/耗材；影响内核 config 与包里元数据）+ 对象级覆盖。
  // 「宁可多失效」：任何不确定项都并入本指纹，不明确即视为未命中。
  private static paramsFingerprint(filesDir: string): number {
    let h: number = 2166136261;
    try {
      h = fnv1aStr(h, SliceParamStore.collectParamsJson());
      // 颜色/耗材槽位请求也进指纹：改对象颜色后必须失效旧包（否则会复用旧色的 .gcode.3mf）。
      h = fnv1aStr(h, SliceParamStore.multicolorFragment(modelState.instances));
    } catch (e) {
      h = fnv1aStr(h, 'paramsErr');
    }
    const snap: PresetSnapshot | undefined = PresetPersist.load(filesDir);
    if (snap !== undefined) {
      h = fnv1aStr(h, snap.printer);
      h = fnv1aStr(h, snap.bedType);
    }
    const cat: PresetCatalog | undefined = SlicerService.getCatalog();
    if (cat !== undefined) {
      h = fnv1aStr(h, cat.selected.printer);
      h = fnv1aStr(h, cat.selected.process);
      h = fnv1aStr(h, cat.selected.filament);
    }
    const objOv: Map<number, Map<string, number>> = SliceParamStore.getObjectOverrides();
    const ids: number[] = [];
    objOv.forEach((_v: Map<string, number>, id: number): void => { ids.push(id); });
    ids.sort((a: number, b: number): number => a - b);
    for (let i = 0; i < ids.length; i++) {
      h = fnvNum(h, ids[i]);
      const m: Map<string, number> | undefined = objOv.get(ids[i]);
      if (m !== undefined) {
        const ks: string[] = [];
        m.forEach((_vv: number, k: string): void => { ks.push(k); });
        ks.sort();
        for (let j = 0; j < ks.length; j++) {
          h = fnv1aStr(h, ks[j]);
          h = fnvNum(h, m.get(ks[j]) ?? 0);
        }
      }
    }
    return h >>> 0;
  }

  // ① 只读包头之外的一小段尾部（zip 中央目录在包末尾），用于定位 gcode 条目名。
  static readTail(path: string, n: number): Uint8Array | null {
    try {
      const size: number = fs.statSync(path).size;
      if (size <= 0) { return null; }
      const len: number = size > n ? n : size;
      const start: number = size - len;
      const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(len);
        // ReadOptions.offset 是「文件内偏移」（filePointer + offset），不是缓冲内偏移：
        // filePointer 初始为 0，因此 offset=start 即从文件 start 处读 len 字节。
        const read: number = fs.readSync(f.fd, buf, { offset: start, length: len });
        if (read === len) { return new Uint8Array(buf, 0, len); }
        return new Uint8Array(buf.slice(0, read));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(DOMAIN, SAVE3MF_TAG, '读取包尾失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return null;
    }
  }

  // 包内条目自检（产出/复用包时都打印）：列出中央目录里的全部条目名，并确认 param 指向的条目确实在包内。
  // 这一步不需要打印机，能直接验证「param 与包内实际 gcode 条目一致、盘号一致」。
  private static logCentralEntries(filesDir: string, purpose: string, tail: Uint8Array | null, param: string): void {
    if (tail === null) {
      ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG, `包内条目自检[${purpose}] 读包尾失败，无法列出条目`);
      return;
    }
    const names: string[] = listCentralEntries(tail);
    ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG,
      `包内条目自检[${purpose}] 条目数=${names.length} param=${param} 参数在包内=${param !== '' && names.indexOf(param) >= 0 ? '是' : '否'}`);
    for (const n of names) {
      ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG, `包内条目| ${n}`);
    }
  }

  // ① 缓存上限：只保留最近 PKG_CACHE_MAX 个产物，超限按 mtime 最旧淘汰（跳过本次使用的 keepPath）。
  private static enforceCacheLimit(filesDir: string, keepPath: string): void {
    const dir: string = ThreeMfExport.pkgCacheDir(filesDir);
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return;
    }
    const list: CacheEntry[] = [];
    for (const nm of names) {
      if (nm.indexOf('pkg_') !== 0 || !nm.endsWith('.gcode.3mf')) { continue; }
      const p: string = `${dir}/${nm}`;
      let mt: number = 0;
      try { mt = fs.statSync(p).mtime; } catch (e) { continue; }
      const ce: CacheEntry = new CacheEntry();
      ce.name = nm; ce.path = p; ce.mtime = mt;
      list.push(ce);
    }
    if (list.length <= PKG_CACHE_MAX) { return; }
    list.sort((a: CacheEntry, b: CacheEntry): number => a.mtime - b.mtime);   // 最旧在前
    let over: number = list.length - PKG_CACHE_MAX;
    for (const ce of list) {
      if (over <= 0) { break; }
      if (ce.path === keepPath) { continue; }
      try {
        fs.unlinkSync(ce.path);
        over--;
        ThreeMfExport.logTag(filesDir, PKG_CACHE_TAG, `缓存超上限 淘汰最旧=${ce.name}`);
      } catch (e) { /* 淘汰失败不影响主流程 */ }
    }
  }

  // ② 释放本次构建链路自己的临时文件（绝不触碰常驻几何/保活几何/其它页状态）。
  private static cleanupBuildTemp(filesDir: string): void {
    ThreeMfExport.cleanupTempFile(`${filesDir}/print_input.tmp.3mf`);
    ThreeMfExport.cleanupTempFile(`${filesDir}/gcode_input.tmp.3mf`);
    ThreeMfExport.cleanupTempFile(ThreeMfExport.pkgInputTmpPath(filesDir));
  }

  private static cleanupTempFile(path: string): void {
    try {
      if (fs.accessSync(path)) { fs.unlinkSync(path); }
    } catch (e) { /* 不存在即无需释放 */ }
  }

  private static unlinkQuiet(path: string): void {
    try {
      if (fs.accessSync(path)) { fs.unlinkSync(path); }
    } catch (e) { /* 忽略 */ }
  }

  // 用 fd→fd 复制（不把几十 MB 包读进 JS 堆）：选择器保存 / 沙箱回退共用。
  static copyFile(srcPath: string, dst: string): boolean {
    let src: fs.File | null = null;
    let dstF: fs.File | null = null;
    try {
      src = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      dstF = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(src.fd, dstF.fd);
      fs.closeSync(src);
      fs.closeSync(dstF);
      return true;
    } catch (e) {
      if (src !== null) { try { fs.closeSync(src); } catch (e2) { /* ignore */ } }
      if (dstF !== null) { try { fs.closeSync(dstF); } catch (e3) { /* ignore */ } }
      hilog.error(DOMAIN, SAVE3MF_TAG, '复制包失败 %{public}s → %{public}s: %{public}s', srcPath, dst,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return false;
    }
  }

  // 三通道日志（hilog + 应用内日志 + files/diag/gcode_diag.txt）；tag 用于区分 Save3mf / GcodePkgCache。
  static logTag(filesDir: string, tag: string, text: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', text);
    try {
      AppLog.push(`[${tag}] ${text}`);
      if (filesDir.length > 0) {
        if (!AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`, [`[${tag}] ${text}`])) {
          hilog.warn(DOMAIN, tag, '日志落盘失败');
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, tag, '日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 读整个文件为字节（把内核写出的项目 3MF 复制到用户选择的位置时用）。
  // 失败打 hilog 并返回 null（不静默）。
  static readFileBytes(path: string): Uint8Array | null {
    try {
      const stat: fs.Stat = fs.statSync(path);
      const size: number = stat.size;
      if (size <= 0) {
        hilog.error(DOMAIN, SAVE3MF_TAG, '读取 3mf 失败（空文件）: %{public}s', path);
        return null;
      }
      const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(size);
        const n: number = fs.readSync(f.fd, buf);
        if (n === size) {
          // 【避免双份大缓冲】读到与文件等长时用「视图」而不是 slice 复制：大 .gcode.3mf 有几十 MB，
          // 旧写法 new Uint8Array(buf.slice(0,n)) 会在 JS 堆里同时留「原缓冲 + 整份副本」两份，
          // 在打印链路（紧接着还要 md5 / 上传）上直接抬高内存峰值。视图的底层 buffer 长度恰好 == size，
          // 因此 bytes.buffer 仍可安全用于 writeFile（fs.writeSync(fd, bytes.buffer)）。
          return new Uint8Array(buf, 0, n);
        }
        // 读到不足（异常/文件被并发改动）：退回精确长度复制，保证返回缓冲长度 == 实际数据长度
        return new Uint8Array(buf.slice(0, n));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(DOMAIN, SAVE3MF_TAG, '读取 3mf 失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return null;
    }
  }

  // 选择器返回的 uri 太长：取最后一段便于 toast 展示
  static shortName(uri: string): string {
    let s: string = uri;
    const q: number = s.indexOf('?');
    if (q >= 0) { s = s.substring(0, q); }
    const i: number = s.lastIndexOf('/');
    let n: string = i >= 0 ? s.substring(i + 1) : s;
    try {
      n = decodeURIComponent(n);
    } catch (e) {
      // 保留原串
    }
    return n.length > 0 ? n : uri;
  }

  // 把「某盘（plateIndex>0）或全部（<=0）对象」整理成 3MF 写入 job（**纯数据**）。
  // 主线程同步构建（build）与 Worker 异步构建（buildToFileViaWorker）共用这一份装配逻辑，
  // 保证两条路产出的 XML 逐字节一致。
  static gatherJob(filesDir: string, plateIndex: number): Mf3mfJob | null {
    const insts: ModelInstance[] = plateIndex > 0
      ? modelState.instances.filter((m: ModelInstance) => m.plate === plateIndex)
      : modelState.instances;
    if (insts.length === 0) {
      return null;
    }
    // 机型 / 打印板：以「上次成功切换的预设快照」为准（与界面下拉一致），快照缺失时退回内核 catalog。
    let printer: string = '';
    let bedType: string = '';
    const snap: PresetSnapshot | undefined = PresetPersist.load(filesDir);
    if (snap !== undefined) {
      printer = snap.printer;
      bedType = snap.bedType;
    }
    if (printer === '') {
      const cat: PresetCatalog | undefined = SlicerService.getCatalog();
      if (cat !== undefined) {
        printer = cat.selected.printer;
      }
    }
    // 打印板尺寸（当前机器）：item 平移写成「床绝对坐标 = 盘中心 + position」，盘中心按这块板算。
    const plate: PlateSize = resolvePlateSize(printer);
    ThreeMfExport.log(filesDir,
      `保存3mf item 平移基准 盘尺寸=${plate.w}x${plate.h} 盘中心=(${(plate.w * 0.5).toFixed(1)},` +
      `${(plate.h * 0.5).toFixed(1)}) 对象=${insts.length}`);

    const job: Mf3mfJob = new Mf3mfJob();
    job.title = MF3MF_DEFAULT_TITLE;
    job.printer = printer;
    job.bedType = bedType;
    const objs: Mf3mfObj[] = [];
    for (let oi = 0; oi < insts.length; oi++) {
      const inst: ModelInstance = insts[oi];
      const g: MeshGeometry = inst.geometry;
      const o: Mf3mfObj = new Mf3mfObj();
      o.name = inst.name;
      o.pos = g.pos;
      o.idx = g.idx;
      o.verts = g.vertices;
      o.indices = g.indices;
      o.vcount = g.vertexCount();
      o.triCount = meshTriCount(g);
      o.plate = inst.plate;
      o.mtx = ThreeMfExport.toMf3mfMat(itemMatrixOf(inst, plate.w, plate.h));
      // 逐对象参数覆盖 → 随对象写进 3MF（内核加载时挂到该对象的 config，切片即按对象生效）。
      // 这是「对象级参数真正生效」的关键一步：此前覆盖只存在内存里，既不进 3MF 也不进切片 payload。
      const ov: Map<string, number> | undefined = modelState.getObjectOverrides().get(inst.id);
      if (ov !== undefined && ov.size > 0) {
        const keys: string[] = [];
        const vals: string[] = [];
        ov.forEach((v: number, k: string) => {
          const s: string = ThreeMfExport.serializeOverride(k, v);
          if (s.length > 0) {
            keys.push(k);
            vals.push(s);
          }
        });
        o.ovKeys = keys;
        o.ovVals = vals;
      }
      objs.push(o);
    }
    job.objs = objs;
    // 整包（项目保存 / 自动备份）：把盘结构 + 盘级床型写进 model_settings.config。
    // 逐盘切片输入（plateIndex > 0）不写 —— 那份输入必须被内核当成「单盘」，产物固定 plate_1.gcode。
    if (plateIndex <= 0) {
      const plates: Mf3mfPlate[] = [];
      for (const pi of modelState.collectPlateIndexes()) {
        let has: boolean = false;
        for (const m of insts) {
          if (m.plate === pi) {
            has = true;
            break;
          }
        }
        if (!has) {
          continue;
        }
        const rec = modelState.getPlateRec(pi);
        const p: Mf3mfPlate = new Mf3mfPlate();
        p.index = pi;
        p.name = rec !== undefined ? rec.name : '';
        p.bed = rec !== undefined ? rec.bed : '';
        plates.push(p);
      }
      job.plates = plates;
    }
    return job;
  }

  // 对象级覆盖的键 → 参数元信息（当前 schema 表），用于按类型正确序列化
  private static paramMeta(key: string): SliceParam | undefined {
    const arr: SliceParam[] = SliceParamStore.getParams();
    for (const p of arr) {
      if (p.key === key) {
        return p;
      }
    }
    return undefined;
  }

  // 把对象级覆盖的**数值形态**序列化为内核 set_deserialize 认的字符串。
  // 规则与内核 ConfigOption 的解析语义一致（依据同 SliceParamStore.encodeValue 的注释）：
  //   · 布尔 -> "1"/"0"（ConfigOptionBool 只认这两个；发 "1.0000" 会被判非法、整项丢弃）
  //   · 枚举 -> **内核枚举名**（取自 schema 的 values，与 options 同序；发下标内核读不懂）
  //   · 整数 -> 整数串；浮点/百分比 -> Number 的最短表示（禁 toFixed(4)：会把极小值截成 0）
  // 取不到元信息（键不在当前 schema）或枚举下标越界 -> 返回空串、调用方跳过该键：
  // 宁可少下发一个键，也不发一个内核读不懂的值（后者会静默变成「参数没生效」）。
  // curr_bed_type 直接跳过：板型是「盘/整机」级选择，逐对象写没有意义。
  static serializeOverride(key: string, v: number): string {
    if (key === 'curr_bed_type') {
      return '';
    }
    const p: SliceParam | undefined = ThreeMfExport.paramMeta(key);
    if (p === undefined) {
      return `${v}`;
    }
    if (p.type === 3) {
      return v === 1 ? '1' : '0';
    }
    if (p.type === 4) {
      const idx: number = Math.round(v);
      if (idx < 0 || idx >= p.values.length) {
        return '';
      }
      return p.values[idx];
    }
    if (p.type === 1) {
      return `${Math.round(v)}`;
    }
    return `${v}`;
  }

  // ItemMatrix（本文件的内部表示）→ Mf3mfMat（写入器/Worker 共用的纯数据结构）。
  private static toMf3mfMat(m: ItemMatrix): Mf3mfMat {
    const out: Mf3mfMat = new Mf3mfMat();
    out.c0 = m.c0;
    out.c1 = m.c1;
    out.c2 = m.c2;
    out.t = m.t;
    return out;
  }

  // 把内存里的对象网格 + 变换序列化成标准 3MF（zip 字节）。
  // 无可保存对象返回 null；构建过程中的异常不吞，交给调用方 hilog + 提示。
  static build(filesDir: string, plateIndex: number = 0): ExportBundle | null {
    const job: Mf3mfJob | null = ThreeMfExport.gatherJob(filesDir, plateIndex);
    if (job === null) {
      return null;
    }
    const r: Mf3mfResult = writeModel3mf(job);
    const bundle: ExportBundle = new ExportBundle();
    bundle.bytes = r.bytes;
    bundle.objectCount = r.objectCount;
    // 自证：逐对象参数覆盖是否真的写进包（>0 才意味着包里有 Metadata/model_settings.config，
    // 内核据此把参数挂到对应对象的 config 上；为 0 时产物与改造前逐字节一致）。
    if (r.overrideCount > 0) {
      ThreeMfExport.log(filesDir,
        `逐对象参数覆盖 已写包 对象数=${r.overrideCount}（包内 Metadata/model_settings.config）`);
    }
    bundle.triangleCount = r.triangleCount;
    bundle.bboxMin = r.bboxMin;
    bundle.bboxMax = r.bboxMax;
    bundle.fileName = GENERIC_FILE_NAME;
    bundle.title = DEFAULT_TITLE;
    return bundle;
  }

  // 【按盘切片专用】在独立线程（ThreadWorker）里构建「只含该盘对象」的输入工程并落盘。
  // 为什么必须开线程：这份 XML 序列化在真机上是重活（盘1 约 42 万面 / 74MB XML），放在主线程上
  // 实测要 22.8~41 秒的连续占用 → AppFreeze 看门狗判 THREAD_BLOCK_3S/6S（界面卡死 + 系统无响应弹窗）。
  // 主线程只负责「装配 job + 收结果」，构建全程不占主线程；Worker 不可用时返回 false 由调用方回退。
  //
  // Worker 为**单例复用**（见文件上方 mfWorker 说明）：整个逐盘序列共用一个线程，
  // 序列收尾由调用方调 disposeMf3mfWorker() 释放。
  static buildToFileViaWorker(filesDir: string, plateIndex: number, outPath: string): Promise<Mf3mfWriteResult> {
    return new Promise<Mf3mfWriteResult>((resolve: (v: Mf3mfWriteResult) => void) => {
      const job: Mf3mfJob | null = ThreeMfExport.gatherJob(filesDir, plateIndex);
      if (job === null) {
        const r: Mf3mfWriteResult = new Mf3mfWriteResult();
        r.ok = false;
        r.reason = '该盘无对象';
        r.workerUnavailable = false;
        resolve(r);
        return;
      }
      if (mfWorker === null) {
        let w: worker.ThreadWorker | null = null;
        try {
          mfCreateCount++;
          w = new worker.ThreadWorker('entry/ets/workers/Mf3mfBuildWorker.ets');
        } catch (e) {
          hilog.error(DOMAIN, SAVE3MF_TAG, 'Worker 创建失败 → 回退主线程构建: %{public}s',
            e instanceof Error ? e.message : JSON.stringify(e));
          mfWorker = null;
          const r: Mf3mfWriteResult = new Mf3mfWriteResult();
          r.ok = false;
          r.reason = 'Worker 不可用';
          r.workerUnavailable = true;
          resolve(r);
          return;
        }
        const bound: worker.ThreadWorker = w;
        w.onmessage = (e: MessageEvents): void => {
          const resp: Mf3mfWriteResponse = e.data as Mf3mfWriteResponse;
          const r: Mf3mfWriteResult = new Mf3mfWriteResult();
          r.ok = resp.ok;
          r.reason = resp.reason;
          r.bytes = resp.bytes;
          r.triangles = resp.triangles;
          r.verts = resp.verts;
          r.workerTotalMs = resp.totalMs;
          r.xmlMs = resp.xmlMs;
          r.vMs = resp.vMs;
          r.triMs = resp.triMs;
          r.zipMs = resp.zipMs;
          r.writeMs = resp.writeMs;
          r.workerUnavailable = false;
          mfSettle(r, null);
        };
        w.onerror = (err: ErrorEvent): void => {
          hilog.error(DOMAIN, SAVE3MF_TAG, 'Worker onerror → 回退主线程构建: %{public}s', err.message);
          const r: Mf3mfWriteResult = new Mf3mfWriteResult();
          r.ok = false;
          r.reason = 'Worker onerror: ' + err.message;
          r.workerUnavailable = true;
          mfSettle(r, bound);
        };
        mfWorker = w;
      } else {
        mfReuseCount++;
      }
      const w: worker.ThreadWorker = mfWorker;
      mfPending = resolve;
      // 兜底超时：单例一旦卡死会拖住整段序列（正常不应发生）
      mfTimeoutId = setTimeout((): void => {
        hilog.error(DOMAIN, SAVE3MF_TAG, 'Worker 构建超时 → 丢弃单例并回退主线程构建');
        const r: Mf3mfWriteResult = new Mf3mfWriteResult();
        r.ok = false;
        r.reason = 'Worker 构建超时';
        r.workerUnavailable = true;
        mfSettle(r, w);
      }, 180000);
      const req: Mf3mfWriteRequest = new Mf3mfWriteRequest();
      req.plate = plateIndex;
      req.outPath = outPath;
      req.job = job;
      w.postMessage(req);
    });
  }

  // 逐盘序列收尾：释放复用的单例 Worker，并汇报本段「创建/复用」次数（自证：改前=盘数, 改后=1）。
  static disposeMf3mfWorker(reason: string): void {
    if (mfWorker !== null) {
      try { mfWorker.terminate(); } catch (e) { /* 已退出 */ }
      mfWorker = null;
    }
    mfPending = null;
    mfClearTimer();
    hilog.info(DOMAIN, SAVE3MF_TAG,
      'Worker 单例回收(%{public}s) 本段创建=%{public}d 复用=%{public}d', reason, mfCreateCount, mfReuseCount);
    mfCreateCount = 0;
    mfReuseCount = 0;
  }

  // 写入任意路径/uri（选择器结果或沙箱回退）。失败打 hilog 并返回 false（不静默）。
  static writeFile(path: string, bytes: Uint8Array): boolean {
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, bytes.buffer);
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (e) {
      hilog.error(DOMAIN, SAVE3MF_TAG, '写入 3mf 失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return false;
    }
  }

  // 三通道日志：hilog + 应用内日志 + files/diag/gcode_diag.txt（沿用现有写入通道）
  static log(filesDir: string, text: string): void {
    hilog.info(DOMAIN, SAVE3MF_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${SAVE3MF_TAG}] ${text}`);
      if (filesDir.length > 0) {
        if (!AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`, [`[${SAVE3MF_TAG}] ${text}`])) {
          hilog.warn(DOMAIN, SAVE3MF_TAG, '保存日志落盘失败');
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, SAVE3MF_TAG, '保存日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }
}
