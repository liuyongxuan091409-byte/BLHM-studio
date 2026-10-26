import { util } from '@kit.ArkTS';
import type { Vec3 } from '@kit.ArkGraphics3D';

// =============================================================================
// 3MF（通用 OPC/zip，STORE 不压缩）字节写入器 —— **纯函数、不依赖任何界面/模型状态**。
//
// 为什么单独抽一个文件：按盘切片时要为每盘生成一份「只含该盘对象」的输入工程，而这份 XML
// 序列化在真机上是重活（盘1 约 42 万面 / 74MB XML，主线程上要几十秒 → AppFreeze THREAD_BLOCK）。
// 唯一可靠的做法是把整份构建搬到独立线程（ThreadWorker）。Worker 里不能访问主线程的 modelState，
// 所以写入器必须只吃「纯数据 job」，因此独立成模块：主线程与 Worker 共用同一份实现，绝不两份。
//
// 调用方（主线程 ThreeMfExport.build / Worker Mf3mfBuildWorker）各自把几何整理成 Mf3mfJob 后调用。
// =============================================================================

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

const MF_CORE_NS: string = 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02';

export const MF3MF_DEFAULT_TITLE: string = '未命名项目';

function xmlEscape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function meta(name: string, value: string): string {
  return `<metadata name="${xmlEscape(name)}">${xmlEscape(value)}</metadata>\n`;
}

// 每份「按盘切片输入工程」要格式化上百万次坐标，旧实现用正则去尾零是热点；改成一次字符扫描。
export function fmtNum(v: number, digits: number): string {
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
        out.push(0xEF, 0xBF, 0xBD);
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
    nb.set(this.buf.subarray(0, this.len));   // 原生 memcpy（逐字节 JS 拷贝在几十 MB 时是大头）
    this.buf = nb;
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
    this.buf.set(a, this.len);   // 原生 memcpy
    this.len += a.length;
  }

  // 原生 UTF-8 编码（旧实现逐字符 JS 判位写字节：74MB XML 要 ~41s；原生编码把它降了一个量级）。
  str(s: string): void {
    const n: number = s.length;
    if (n === 0) { return; }
    this.ensure(n * 3 + 4);
    const res = this.enc.encodeIntoUint8Array(s, this.buf.subarray(this.len));
    this.len += res.written;
  }

  length(): number {
    return this.len;
  }

  toBytes(): Uint8Array {
    return this.buf.slice(0, this.len);
  }

  // ---------------- 直写 ASCII（去掉热点路径上的中间字符串） ----------------
  // 旧的顶点/三角行写法是「fmtNum → 值字符串 → 整行模板字符串 → encodeInto」：
  // 每个顶点要产生 ~9 个小字符串 + 一次原生编码调用。盘1（~40 万顶点）实测 XML 段 6.7s，
  // 其中顶点段 5.2s —— 瓶颈就是这些海量小字符串分配 + GC。
  // 下面三个方法把「常量片段 / 数字 / 整数」直接按 ASCII 字节写进缓冲，不再产生整行字符串。

  // 纯 ASCII 常量片段直写（顶点/三角行的标签、引号、斜杠等）。
  lit(s: string): void {
    const n: number = s.length;
    if (n === 0) { return; }
    this.ensure(n);
    const b: Uint8Array = this.buf;
    const w: number = this.len;
    for (let i = 0; i < n; i++) { b[w + i] = s.charCodeAt(i) & 0xFF; }
    this.len = w + n;
  }

  // 数字直写：语义与 fmtNum(v, digits) **逐字符一致**（同样的 toFixed(digits) + 去小数尾零 + '-0' → '0'），
  // 只是把结果直接写成字节，不再返回中间字符串、不再拼整行模板。
  num(v: number, digits: number): void {
    if (!Number.isFinite(v)) {
      this.ensure(1);
      this.buf[this.len] = 48; this.len++;
      return;
    }
    const s: string = v.toFixed(digits);
    const n: number = s.length;
    let end: number = n;
    let hasDot: boolean = false;
    for (let i = 0; i < n; i++) {
      if (s.charCodeAt(i) === 46) { hasDot = true; break; }
    }
    if (hasDot) {
      while (end > 0 && s.charCodeAt(end - 1) === 48) { end--; }
      if (end > 0 && s.charCodeAt(end - 1) === 46) { end--; }
    }
    // '' 或 '-0' → '0'（与 fmtNum 的收尾判定一致）
    if (end === 0 || (end === 2 && s.charCodeAt(0) === 45 && s.charCodeAt(1) === 48)) {
      this.ensure(1);
      this.buf[this.len] = 48; this.len++;
      return;
    }
    this.ensure(end);
    const b: Uint8Array = this.buf;
    const w: number = this.len;
    for (let i = 0; i < end; i++) { b[w + i] = s.charCodeAt(i) & 0xFF; }
    this.len = w + end;
  }

  // 非负整数直写（三角形索引 v1/v2/v3）。
  uInt(v: number): void {
    if (v <= 0) {
      this.ensure(1);
      this.buf[this.len] = 48; this.len++;
      return;
    }
    this.ensure(11);
    const b: Uint8Array = this.buf;
    const start: number = this.len;
    let n: number = v;
    while (n > 0) {
      b[this.len] = 48 + (n % 10);
      this.len++;
      n = (n / 10) | 0;
    }
    let i: number = start;
    let j: number = this.len - 1;
    while (i < j) {
      const t: number = b[i]; b[i] = b[j]; b[j] = t;
      i++; j--;
    }
  }
}

// ---------------- CRC32（zip 校验） ----------------
// 旧实现逐字节查表（1 字节 1 次循环）：盘1 的 23MB 模型要 2.8s —— 占整份构建的 ~30%。
// 改成分片查表（slicing-by-4，一次吃 4 字节）+ Uint32Array 表：循环次数降到 1/4，
// 表项是定长整数数组（比 number[] 快）。CRC32 与逐字节版逐位等价（下方自证：产物字节保持一致）。
let CRC_TABLES: Uint32Array | null = null;

function crcTables(): Uint32Array {
  if (CRC_TABLES !== null) {
    return CRC_TABLES;
  }
  // 布局：[t0 | t1 | t2 | t3]，每张 256 项。
  const t: Uint32Array = new Uint32Array(256 * 4);
  for (let n = 0; n < 256; n++) {
    let c: number = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) !== 0 ? ((0xEDB88320 ^ (c >>> 1)) >>> 0) : (c >>> 1);
    }
    t[n] = c >>> 0;
  }
  for (let n = 0; n < 256; n++) {
    let c: number = t[n];
    for (let i = 1; i < 4; i++) {
      c = ((t[c & 0xFF] ^ (c >>> 8)) >>> 0);
      t[i * 256 + n] = c;
    }
  }
  CRC_TABLES = t;
  return t;
}

function crc32(data: Uint8Array): number {
  const t: Uint32Array = crcTables();
  let c: number = 0xFFFFFFFF;
  const n: number = data.length;
  let i: number = 0;
  const lim: number = n - (n % 4);
  while (i < lim) {
    // 小端读入 4 字节与当前余数异或，再一次性消掉 4 字节
    const x: number = (c ^ (data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24))) >>> 0;
    c = (t[3 * 256 + (x & 0xFF)] ^ t[2 * 256 + ((x >>> 8) & 0xFF)] ^
         t[1 * 256 + ((x >>> 16) & 0xFF)] ^ t[(x >>> 24) & 0xFF]) >>> 0;
    i += 4;
  }
  while (i < n) {
    c = ((t[(c ^ data[i]) & 0xFF] ^ (c >>> 8)) >>> 0);
    i++;
  }
  return (c ^ 0xFFFFFFFF) >>> 0;
}

// ---------------- 最小 zip（STORE） ----------------
class ZipEntry {
  name: string = '';
  data: Uint8Array = new Uint8Array(0);
}

function buildZip(entries: ZipEntry[]): Uint8Array {
  const w: ByteWriter = new ByteWriter();
  const offsets: number[] = [];
  const crcs: number[] = [];

  for (const e of entries) {
    const nameBytes: Uint8Array = utf8Encode(e.name);
    const crc: number = crc32(e.data);
    offsets.push(w.length());
    crcs.push(crc);
    w.u32(0x04034b50);
    w.u16(20);
    w.u16(0);
    w.u16(0);
    w.u16(0);
    w.u16(0);
    w.u32(crc);
    w.u32(e.data.length);
    w.u32(e.data.length);
    w.u16(nameBytes.length);
    w.u16(0);
    w.bytes(nameBytes);
    w.bytes(e.data);
  }

  const cdStart: number = w.length();
  for (let i = 0; i < entries.length; i++) {
    const e: ZipEntry = entries[i];
    const nameBytes: Uint8Array = utf8Encode(e.name);
    w.u32(0x02014b50);
    w.u16(20);
    w.u16(20);
    w.u16(0);
    w.u16(0);
    w.u16(0);
    w.u16(0);
    w.u32(crcs[i]);
    w.u32(e.data.length);
    w.u32(e.data.length);
    w.u16(nameBytes.length);
    w.u16(0);
    w.u16(0);
    w.u16(0);
    w.u16(0);
    w.u32(0);
    w.u32(offsets[i]);
    w.bytes(nameBytes);
  }
  const cdSize: number = w.length() - cdStart;

  w.u32(0x06054b50);
  w.u16(0);
  w.u16(0);
  w.u16(entries.length);
  w.u16(entries.length);
  w.u32(cdSize);
  w.u32(cdStart);
  w.u16(0);

  return w.toBytes();
}

// ---------------- 坐标工具 ----------------
// content(Y-up) → 3MF 世界(Z-up)
export function contentToZup(v: Vec3): Vec3 {
  return { x: v.x, y: -v.z, z: v.y };
}

// 3MF 世界(Z-up) 基向量 → content(Y-up)
export function zupToContent2(x: number, y: number, z: number): Vec3 {
  return { x: x, y: z, z: -y };
}

// ---------------- job 结构（纯数据，可跨 Worker 传递） ----------------
// item 变换矩阵（4 个向量：三列 + 平移）；由主线程用 ThreeMfExport.itemMatrixOf 算好后传入。
export class Mf3mfMat {
  c0: Vec3 = { x: 1, y: 0, z: 0 };
  c1: Vec3 = { x: 0, y: 1, z: 0 };
  c2: Vec3 = { x: 0, y: 0, z: 1 };
  t: Vec3 = { x: 0, y: 0, z: 0 };
}

// 一个待写入 3MF 的对象：几何保持「常驻形态」（大数据走扁平 TypedArray，程序化小网格走对象数组）
export class Mf3mfObj {
  name: string = '';
  pos: Float32Array | null = null;
  idx: Uint32Array | null = null;
  verts: Vec3[] = [];
  indices: number[] = [];
  vcount: number = 0;
  triCount: number = 0;
  mtx: Mf3mfMat = new Mf3mfMat();
  // 所属盘号（1 基；0 = 未分盘）。**只在「整包（项目保存/备份）」写 plate 块时使用**；
  // 逐盘切片输入不写 plate 块（内核按单盘处理，产物固定 plate_1.gcode）。
  plate: number = 0;
  // 逐对象参数覆盖（内核键 → 已按内核语义序列化的字符串），写成 Metadata/model_settings.config 里
  // <object id="N"> 下的 <metadata key=".." value=".."/>。依据内核源码 bbs_3mf.cpp:2242-2249：
  // object 下除 name/module 外的每个 metadata 都会被 set_deserialize 进该对象的 config。
  // 序列化规则见 ThreeMfExport.serializeOverride（枚举必须发内核枚举名、布尔发 "1"/"0"）。
  ovKeys: string[] = [];
  ovVals: string[] = [];
}

// 一个盘块（写进 Metadata/model_settings.config 的 <plate>）。
// 内核 bbs_3mf.cpp 按 <plate> 恢复「盘号 / 盘名 / 床型 / 盘内对象」——
// 不写它，保存后的多盘工程再打开会被内核合并成单盘（盘归属与盘级床型都会丢）。
export class Mf3mfPlate {
  index: number = 1;
  name: string = '';
  bed: string = ''; // 内核 enum 名（如 "Cool Plate"）；空 = 不写（跟随全局）
}

export class Mf3mfJob {
  objs: Mf3mfObj[] = [];
  title: string = MF3MF_DEFAULT_TITLE;
  printer: string = '';
  bedType: string = '';
  // 整包模式（项目保存/自动备份）才填：盘号 / 盘名 / 盘级床型，写成 model_settings.config 的 <plate>。
  plates: Mf3mfPlate[] = [];
}

export class Mf3mfResult {
  bytes: Uint8Array = new Uint8Array(0);
  objectCount: number = 0;
  triangleCount: number = 0;
  bboxMin: Vec3 = { x: 0, y: 0, z: 0 };
  bboxMax: Vec3 = { x: 0, y: 0, z: 0 };
  // ---- 逐段耗时自证（ms）----
  // 把「构建」这件事拆成可观测的几段，避免再凭感觉猜瓶颈：
  //   vertCount 顶点总数、xmlMs = 整份模型 XML 序列化、vMs/ triMs = 其中的顶点段/ 三角段、
  //   zipMs = 最小 zip 打包（CRC + 头 + 复制）。
  // 主线程 build 路径只用 bytes/个数，这几项仅供日志（不影响产物）。
  // 逐段耗时自证（ms）
  vertCount: number = 0;
  xmlMs: number = 0;
  vMs: number = 0;
  triMs: number = 0;
  zipMs: number = 0;
  // 带对象级参数覆盖的对象个数（>0 时包里才有 Metadata/model_settings.config；供日志自证）
  overrideCount: number = 0;
}

function applyItem(m: Mf3mfMat, p: Vec3): Vec3 {
  return {
    x: m.c0.x * p.x + m.c1.x * p.y + m.c2.x * p.z + m.t.x,
    y: m.c0.y * p.x + m.c1.y * p.y + m.c2.y * p.z + m.t.y,
    z: m.c0.z * p.x + m.c1.z * p.y + m.c2.z * p.z + m.t.z,
  };
}

// 3MF transform 属性：4×3 行主序
function transformAttr(m: Mf3mfMat): string {
  const n: string[] = [
    fmtNum(m.c0.x, 6), fmtNum(m.c0.y, 6), fmtNum(m.c0.z, 6),
    fmtNum(m.c1.x, 6), fmtNum(m.c1.y, 6), fmtNum(m.c1.z, 6),
    fmtNum(m.c2.x, 6), fmtNum(m.c2.y, 6), fmtNum(m.c2.z, 6),
    fmtNum(m.t.x, 6), fmtNum(m.t.y, 6), fmtNum(m.t.z, 6),
  ];
  return n.join(' ');
}

// 把 job 写成完整的 .3mf 字节（模型 XML + 最小 zip 包）。纯同步实现，主线程 / Worker 通用。
export function writeModel3mf(job: Mf3mfJob): Mf3mfResult {
  const insts: Mf3mfObj[] = job.objs;
  const w: ByteWriter = new ByteWriter();
  // ---- 逐段计时（自证用；不影响产物）----
  const tXml0: number = Date.now();
  let vMs: number = 0;
  let triMs: number = 0;
  w.str('<?xml version="1.0" encoding="UTF-8"?>\n');
  w.str(`<model unit="millimeter" xml:lang="en-US" xmlns="${MF_CORE_NS}">\n`);
  w.str(meta('Title', job.title));
  w.str(meta('Application', 'BLHM studio'));
  if (job.printer.length > 0) {
    w.str(meta('PrinterModel', job.printer));
  }
  if (job.bedType.length > 0) {
    w.str(meta('PrintPlateType', job.bedType));
  }

  const lo: Vec3 = { x: 1e30, y: 1e30, z: 1e30 };
  const hi: Vec3 = { x: -1e30, y: -1e30, z: -1e30 };
  let triTotal: number = 0;
  let vertTotal: number = 0;

  w.str('<resources>\n');
  const items: string[] = [];
  // 逐对象参数覆盖攒在这里，最后合成 Metadata/model_settings.config（没有覆盖时该文件不写）
  const cfgObjs: string[] = [];
  for (let oi = 0; oi < insts.length; oi++) {
    const inst: Mf3mfObj = insts[oi];
    const objId: number = oi + 1;
    const mtx: Mf3mfMat = inst.mtx;
    const pos: Float32Array | null = inst.pos;
    const idxU: Uint32Array | null = inst.idx;
    const verts: Vec3[] = inst.verts;
    const idx: number[] = inst.indices;
    const vcount: number = inst.vcount;
    triTotal += inst.triCount;
    vertTotal += vcount;

    w.str(`<object id="${objId}" type="model" name="${xmlEscape(inst.name)}">\n<mesh>\n<vertices>\n`);
    const tV0: number = Date.now();
    // 矩阵列向量提到循环外（旧实现 applyItem 每顶点建一个 Vec3，加上 contentToZup 每顶点再建一个：
    // 40 万顶点 → 80 万个短命对象，GC 是顶点段耗时的隐藏大头）。
    const c0x: number = mtx.c0.x; const c0y: number = mtx.c0.y; const c0z: number = mtx.c0.z;
    const c1x: number = mtx.c1.x; const c1y: number = mtx.c1.y; const c1z: number = mtx.c1.z;
    const c2x: number = mtx.c2.x; const c2y: number = mtx.c2.y; const c2z: number = mtx.c2.z;
    const tx: number = mtx.t.x; const ty: number = mtx.t.y; const tz: number = mtx.t.z;
    if (pos !== null) {
      for (let i = 0; i < vcount; i++) {
        const k: number = i * 3;
        // contentToZup(v) = (v.x, -v.z, v.y)，再 applyItem；全程标量，不建中间 Vec3。
        const zx: number = pos[k];
        const zy: number = -pos[k + 2];
        const zz: number = pos[k + 1];
        const wx: number = c0x * zx + c1x * zy + c2x * zz + tx;
        const wy: number = c0y * zx + c1y * zy + c2y * zz + ty;
        const wz: number = c0z * zx + c1z * zy + c2z * zz + tz;
        if (wx < lo.x) { lo.x = wx; }
        if (wy < lo.y) { lo.y = wy; }
        if (wz < lo.z) { lo.z = wz; }
        if (wx > hi.x) { hi.x = wx; }
        if (wy > hi.y) { hi.y = wy; }
        if (wz > hi.z) { hi.z = wz; }
        w.lit('<vertex x="'); w.num(zx, 4);
        w.lit('" y="'); w.num(zy, 4);
        w.lit('" z="'); w.num(zz, 4);
        w.lit('"/>');
      }
    } else {
      for (let i = 0; i < verts.length; i++) {
        const vv: Vec3 = verts[i];
        const zx: number = vv.x;
        const zy: number = -vv.z;
        const zz: number = vv.y;
        const wx: number = c0x * zx + c1x * zy + c2x * zz + tx;
        const wy: number = c0y * zx + c1y * zy + c2y * zz + ty;
        const wz: number = c0z * zx + c1z * zy + c2z * zz + tz;
        if (wx < lo.x) { lo.x = wx; }
        if (wy < lo.y) { lo.y = wy; }
        if (wz < lo.z) { lo.z = wz; }
        if (wx > hi.x) { hi.x = wx; }
        if (wy > hi.y) { hi.y = wy; }
        if (wz > hi.z) { hi.z = wz; }
        w.lit('<vertex x="'); w.num(zx, 4);
        w.lit('" y="'); w.num(zy, 4);
        w.lit('" z="'); w.num(zz, 4);
        w.lit('"/>');
      }
    }
    vMs += Date.now() - tV0;
    w.str('\n</vertices>\n<triangles>\n');
    const tT0: number = Date.now();
    if (idxU !== null) {
      const n: number = idxU.length;
      for (let i = 0; i + 2 < n; i += 3) {
        const a: number = idxU[i];
        const b: number = idxU[i + 1];
        const c: number = idxU[i + 2];
        if (a < 0 || b < 0 || c < 0 || a >= vcount || b >= vcount || c >= vcount) {
          continue;
        }
        w.lit('<triangle v1="'); w.uInt(a);
        w.lit('" v2="'); w.uInt(b);
        w.lit('" v3="'); w.uInt(c);
        w.lit('"/>');
      }
    } else if (idx.length > 0) {
      for (let i = 0; i + 2 < idx.length; i += 3) {
        const a: number = idx[i];
        const b: number = idx[i + 1];
        const c: number = idx[i + 2];
        if (a < 0 || b < 0 || c < 0 || a >= vcount || b >= vcount || c >= vcount) {
          continue;
        }
        w.lit('<triangle v1="'); w.uInt(a);
        w.lit('" v2="'); w.uInt(b);
        w.lit('" v3="'); w.uInt(c);
        w.lit('"/>');
      }
    } else {
      for (let i = 0; i + 2 < vcount; i += 3) {
        w.lit('<triangle v1="'); w.uInt(i);
        w.lit('" v2="'); w.uInt(i + 1);
        w.lit('" v3="'); w.uInt(i + 2);
        w.lit('"/>');
      }
    }
    triMs += Date.now() - tT0;
    w.str('\n</triangles>\n</mesh>\n</object>\n');

    // 逐对象参数覆盖 → model_settings.config 的 <object id=N> 块（id 与上面 3dmodel.model 的
    // object id 必须一致，内核靠它把配置挂回对应的 ModelObject）。
    // 不写 name：对象名已由 3dmodel.model 的 object name 属性带过去了，写重复反而会覆盖名字。
    if (inst.ovKeys.length > 0) {
      let blk: string = `  <object id="${objId}">\n`;
      const n: number = inst.ovKeys.length;
      for (let k = 0; k < n; k++) {
        blk += `    <metadata key="${xmlEscape(inst.ovKeys[k])}" value="${xmlEscape(inst.ovVals[k])}"/>\n`;
      }
      blk += '  </object>\n';
      cfgObjs.push(blk);
    }

    items.push(`<item objectid="${objId}" transform="${transformAttr(mtx)}"/>`);
  }
  w.str('</resources>\n<build>\n');
  for (const it of items) {
    w.str(it);
    w.str('\n');
  }
  w.str('</build>\n</model>\n');

  // 盘块（整包模式）：盘号 / 盘名 / 盘级床型 + 盘内对象。
  // 必须与上面 3dmodel.model 的 object id 对齐（objId = 数组下标 + 1）。
  const cfgPlates: string[] = [];
  if (job.plates.length > 0) {
    for (const p of job.plates) {
      let blk: string = '  <plate>\n';
      blk += `    <metadata key="plater_id" value="${p.index}"/>\n`;
      if (p.name.length > 0) {
        blk += `    <metadata key="plater_name" value="${xmlEscape(p.name)}"/>\n`;
      }
      if (p.bed.length > 0) {
        blk += `    <metadata key="bed_type" value="${xmlEscape(p.bed)}"/>\n`;
      }
      let any: boolean = false;
      for (let oi = 0; oi < insts.length; oi++) {
        if (insts[oi].plate !== p.index) {
          continue;
        }
        blk += '    <model_instance>\n';
        blk += `      <metadata key="object_id" value="${oi + 1}"/>\n`;
        blk += '      <metadata key="instance_id" value="0"/>\n';
        // identify_id 必须唯一：内核加载时把它写进 ModelInstance::loaded_id，
        // 再靠它把「盘内成员」反查回具体对象。全 0 会让盘归属整体落空（盘被并成一块）。
        blk += `      <metadata key="identify_id" value="${oi + 1}"/>\n`;
        blk += '    </model_instance>\n';
        any = true;
      }
      blk += '  </plate>\n';
      if (any) {
        cfgPlates.push(blk);
      }
    }
  }

  const modelBytes: Uint8Array = w.toBytes();
  const xmlMs: number = Date.now() - tXml0;

  // model_settings.config：逐对象参数覆盖 和/或 盘块。
  // 都没有时不写 —— 产物与改造前逐字节一致（零回归）。
  let cfgBytes: Uint8Array | null = null;
  if (cfgObjs.length > 0 || cfgPlates.length > 0) {
    let cx: string = '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n';
    for (const b of cfgObjs) {
      cx += b;
    }
    for (const b of cfgPlates) {
      cx += b;
    }
    cx += '</config>\n';
    cfgBytes = utf8Encode(cx);
  }

  const zip: ZipEntry[] = [];
  const e1: ZipEntry = new ZipEntry();
  e1.name = '[Content_Types].xml';
  e1.data = utf8Encode(CONTENT_TYPES_XML);
  zip.push(e1);
  const e2: ZipEntry = new ZipEntry();
  e2.name = '_rels/.rels';
  e2.data = utf8Encode(RELS_XML);
  zip.push(e2);
  const e3: ZipEntry = new ZipEntry();
  e3.name = '3D/3dmodel.model';
  e3.data = modelBytes;
  zip.push(e3);
  if (cfgBytes !== null) {
    const e4: ZipEntry = new ZipEntry();
    e4.name = 'Metadata/model_settings.config';
    e4.data = cfgBytes;
    zip.push(e4);
  }

  const tZip0: number = Date.now();
  const r: Mf3mfResult = new Mf3mfResult();
  r.bytes = buildZip(zip);
  r.objectCount = insts.length;
  r.overrideCount = cfgObjs.length;
  r.triangleCount = triTotal;
  r.bboxMin = lo;
  r.bboxMax = hi;
  r.vertCount = vertTotal;
  r.xmlMs = xmlMs;
  r.vMs = vMs;
  r.triMs = triMs;
  r.zipMs = Date.now() - tZip0;
  return r;
}
