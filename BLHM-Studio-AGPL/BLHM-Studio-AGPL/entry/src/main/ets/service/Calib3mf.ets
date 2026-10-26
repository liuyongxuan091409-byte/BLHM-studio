import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SlicerService } from './SlicerService';

const TAG: string = 'Calib3mf';

// 打印板包围盒（由内核 printerBed() 给出，取不到就按 256×256 兜底）
class BedBox {
  minX: number = 0;
  minY: number = 0;
  maxX: number = 256;
  maxY: number = 256;
}

interface BedBboxJson {
  min_x?: number;
  min_y?: number;
  max_x?: number;
  max_y?: number;
}

interface BedJson {
  bbox?: BedBboxJson;
}

// 一个 3MF 内部对象：直接顶点（可为空）+ 引用的子模型组件
interface ObjDef {
  verts: number[];      // 扁平 [x,y,z, x,y,z, ...]
  comps: CompDef[];
}

interface CompDef {
  path: string;         // 子模型文件的包内路径，如 3D/Objects/object_1.model
  objectid: string;
  transform: number[];  // 12 个数（列主序 4x3，同 3MF 规范）
}

interface ZipEntry {
  name: string;
  data: Uint8Array;
}

// 3MF 摆位归一化。
//
// 为什么需要：拓竹随包的校准 3MF 是按官方板位摆的，与本地内核的打印板/排除区不一致：
//   - 流量测试块：<item> 没有 transform，顶点在 X 0~124 / Y 0~94（板左下角）
//     → 内核报 "<object> is too close to exclusion area"
//   - 自动 PA 线：<item> 带 transform，但 Z 落在 -4.9~5.1（模型一半在板下）
//     → 内核报 "empty initial layer"
// 这都不是链路缺陷，是文件摆位问题。
//
// 做法：解开 3MF（zip）→ 解析 3D/3dmodel.model 与它的子模型，按 item×component 矩阵合成
// 真实包围盒 → 给每个 <item> 加同一个平移（XY 居中到板心、Z 抬到板面）→ 自己重新打包 3MF。
// 相对布局与旋转一点不动，只挪整体位置。
// 明确不做：不放宽 printable_area、不清空 wrapping_exclude_area —— 那是拿硬件保护换通过。
export class Calib3mf {
  // 最近一次归一化时从 3MF 自带 project_settings 读到的工艺覆盖片段（""=没有）
  private static lastOverrides: string = '';
  // 最近一次归一化解析出的「板上试块」清单（按 X 从大到小/左到右排序，name 为对象名）
  private static lastBlocks: string = '';
  // objectid → 对象名（用于把 flowrate_m20 这类试块名还原成百分比）
  private static objNames: Map<string, string> = new Map<string, string>();
  static bedBox(): BedBox {
    const b: BedBox = new BedBox();
    try {
      const raw: string = SlicerService.printerBed();
      const o: BedJson = JSON.parse(raw) as BedJson;
      const bb: BedBboxJson | undefined = o.bbox;
      if (bb !== undefined && bb.min_x !== undefined && bb.min_y !== undefined
        && bb.max_x !== undefined && bb.max_y !== undefined) {
        b.minX = bb.min_x;
        b.minY = bb.min_y;
        b.maxX = bb.max_x;
        b.maxY = bb.max_y;
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '取打印板失败，按 256×256 兜底: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    return b;
  }

  // ---------------- 矩阵（列主序 4x3：m0..m8 旋转/缩放，m9..m11 平移） ----------------

  private static identity(): number[] {
    return [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];
  }

  private static parseMatrix(s: string): number[] {
    const out: number[] = [];
    const parts: string[] = s.trim().split(new RegExp('\\s+'));
    for (const p of parts) {
      const v: number = Number.parseFloat(p);
      if (Number.isFinite(v)) {
        out.push(v);
      }
    }
    if (out.length === 9) {
      out.push(0);
      out.push(0);
      out.push(0);
    }
    return out.length === 12 ? out : Calib3mf.identity();
  }

  // a∘b（先 b 后 a）
  private static mul(a: number[], b: number[]): number[] {
    const r: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    for (let i = 0; i < 3; i++) {
      for (let j = 0; j < 3; j++) {
        let s: number = 0;
        for (let k = 0; k < 3; k++) {
          s += a[k * 3 + i] * b[j * 3 + k];
        }
        r[j * 3 + i] = s;
      }
      let t: number = 0;
      for (let k = 0; k < 3; k++) {
        t += a[k * 3 + i] * b[9 + k];
      }
      r[9 + i] = t + a[9 + i];
    }
    return r;
  }

  // ---------------- XML 解析 ----------------

  private static attr(tag: string, name: string): string {
    const re: RegExp = new RegExp(`${name}="([^"]*)"`);
    const m: RegExpExecArray | null = re.exec(tag);
    return m === null ? '' : m[1];
  }

  // 解析一个 .model 文件里的全部 <object>：id → 顶点 + 组件
  private static parseModelFile(xml: string, addTo: Map<string, ObjDef>, fileKey: string): void {
    const objRe: RegExp = new RegExp('<object\\s+([^>]*?)>([\\s\\S]*?)</object>', 'g');
    let m: RegExpExecArray | null = objRe.exec(xml);
    while (m !== null) {
      const id: string = Calib3mf.attr(m[1], 'id');
      const body: string = m[2];
      const def: ObjDef = { verts: [], comps: [] };
      const vRe: RegExp = new RegExp('<vertex([^>]*)/>', 'g');
      let vm: RegExpExecArray | null = vRe.exec(body);
      while (vm !== null) {
        const x: number = Number.parseFloat(Calib3mf.attr(vm[1], 'x'));
        const y: number = Number.parseFloat(Calib3mf.attr(vm[1], 'y'));
        const z: number = Number.parseFloat(Calib3mf.attr(vm[1], 'z'));
        if (Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z)) {
          def.verts.push(x);
          def.verts.push(y);
          def.verts.push(z);
        }
        vm = vRe.exec(body);
      }
      const cRe: RegExp = new RegExp('<component\\s+([^>]*?)/>', 'g');
      let cm: RegExpExecArray | null = cRe.exec(body);
      while (cm !== null) {
        const path: string = Calib3mf.attr(cm[1], 'path').replace(/^\//, '');
        const cid: string = Calib3mf.attr(cm[1], 'objectid');
        const tf: string = Calib3mf.attr(cm[1], 'transform');
        if (path !== '' && cid !== '') {
          def.comps.push({
            path: path,
            objectid: cid,
            transform: tf === '' ? Calib3mf.identity() : Calib3mf.parseMatrix(tf)
          });
        }
        cm = cRe.exec(body);
      }
      if (id !== '') {
        addTo.set(`${fileKey}#${id}`, def);
        const nm: string = Calib3mf.attr(m[1], 'name');
        if (nm !== '') {
          Calib3mf.objNames.set(`${fileKey}#${id}`, nm);
        }
      }
      m = objRe.exec(xml);
    }
  }

  // 递归累加一个对象在给定矩阵下的全部顶点
  private static collect(modelKey: string, objectid: string, xf: number[],
                         objs: Map<string, ObjDef>, acc: number[], depth: number): void {
    if (depth > 8) {
      return;
    }
    const def: ObjDef | undefined = objs.get(`${modelKey}#${objectid}`);
    if (def === undefined) {
      return;
    }
    const v: number[] = def.verts;
    for (let i = 0; i + 2 < v.length; i += 3) {
      const x: number = v[i];
      const y: number = v[i + 1];
      const z: number = v[i + 2];
      acc.push(xf[0] * x + xf[3] * y + xf[6] * z + xf[9]);
      acc.push(xf[1] * x + xf[4] * y + xf[7] * z + xf[10]);
      acc.push(xf[2] * x + xf[5] * y + xf[8] * z + xf[11]);
    }
    for (const c of def.comps) {
      Calib3mf.collect(c.path, c.objectid, Calib3mf.mul(xf, c.transform), objs, acc, depth + 1);
    }
  }

  // 给每个 <item> 的 transform 加上平移（纯平移左乘 = 平移分量直接相加）
  // 注意：ArkTS 静态检查不接受 String.replace(regex, 回调)，这里用 exec 游标手工拼接。
  private static applyShift(xml: string, dx: number, dy: number, dz: number): string {
    const shift: string = `1 0 0 0 1 0 0 0 1 ${dx.toFixed(3)} ${dy.toFixed(3)} ${dz.toFixed(3)}`;
    const re: RegExp = new RegExp('<item\\s+([^>]*?)/>', 'g');
    let items: number = 0;
    let out: string = '';
    let last: number = 0;
    let m: RegExpExecArray | null = re.exec(xml);
    while (m !== null) {
      const whole: string = m[0];
      const attrs: string = m[1];
      let rebuilt: string = '';
      const tr: RegExp = new RegExp('transform="([^"]*)"');
      const found: RegExpExecArray | null = tr.exec(attrs);
      if (found !== null) {
        const nums: string[] = found[1].trim().split(new RegExp('\\s+'));
        if (nums.length === 12) {
          nums[9] = (Number.parseFloat(nums[9]) + dx).toFixed(3);
          nums[10] = (Number.parseFloat(nums[10]) + dy).toFixed(3);
          nums[11] = (Number.parseFloat(nums[11]) + dz).toFixed(3);
          rebuilt = `<item ${attrs.substring(0, found.index)}transform="${nums.join(' ')}"${attrs.substring(found.index + found[0].length)}/>`;
        }
      }
      if (rebuilt === '') {
        rebuilt = `<item ${attrs} transform="${shift}"/>`;
      }
      out += xml.substring(last, m.index) + rebuilt;
      last = m.index + whole.length;
      items++;
      m = re.exec(xml);
    }
    out += xml.substring(last);
    hilog.info(0x0000, TAG, '已平移 item=%{public}d 平移=(%{public}s,%{public}s,%{public}s)',
      items, dx.toFixed(2), dy.toFixed(2), dz.toFixed(2));
    return out;
  }

  // ---------------- 修改器部件过滤 ----------------
  //
  // 拓竹的 3MF 把"参数修改器"也写成 <component>，真正的语义在 Metadata/model_settings.config：
  //   <part id="1" subtype="normal_part">   ← 要打印的实体
  //   <part id="2" subtype="modifier_part"> ← 只改该区域的线宽/速度，本身不是几何
  // 内核的 3MF 读入只认 PrusaSlicer 自己的 Slic3r_PE_model.config，不认这份文件，
  // 于是把修改器当成实体一起切：自动 PA 线就多出 4 个埋了半截的 30×10×10 方块，
  // 内核即报 "empty initial layer … Please cut the bottom or enable supports"。
  // 这里在切片前按 subtype 把非 normal_part 的 component 摘掉（不是放宽保护，是还原语义）。
  private static parsePartSubtypes(cfg: string): Map<string, string[]> {
    const out: Map<string, string[]> = new Map<string, string[]>();
    const objRe: RegExp = new RegExp('<object\\s+([^>]*?)>([\\s\\S]*?)</object>', 'g');
    let m: RegExpExecArray | null = objRe.exec(cfg);
    while (m !== null) {
      const id: string = Calib3mf.attr(m[1], 'id');
      const body: string = m[2];
      const parts: string[] = [];
      const partRe: RegExp = new RegExp('<part\\s+([^>]*?)>', 'g');
      let pm: RegExpExecArray | null = partRe.exec(body);
      while (pm !== null) {
        const sub: string = Calib3mf.attr(pm[1], 'subtype');
        parts.push(sub === '' ? 'normal_part' : sub);
        pm = partRe.exec(body);
      }
      if (id !== '' && parts.length > 0) {
        out.set(id, parts);
      }
      m = objRe.exec(cfg);
    }
    return out;
  }

  private static dropNonPrintableParts(xml: string, types: Map<string, string[]>): string {
    if (types.size === 0) {
      return xml;
    }
    const objRe: RegExp = new RegExp('<object\\s+([^>]*?)>([\\s\\S]*?)</object>', 'g');
    let out: string = '';
    let last: number = 0;
    let dropped: number = 0;
    let m: RegExpExecArray | null = objRe.exec(xml);
    while (m !== null) {
      const id: string = Calib3mf.attr(m[1], 'id');
      const body: string = m[2];
      const subs: string[] | undefined = types.get(id);
      let newBody: string = body;
      if (subs !== undefined) {
        const compBlockRe: RegExp = new RegExp('<components>([\\s\\S]*?)</components>');
        const cb: RegExpExecArray | null = compBlockRe.exec(body);
        if (cb !== null) {
          const inner: string = cb[1];
          const compRe: RegExp = new RegExp('<component\\b[^>]*/>', 'g');
          const kept: string[] = [];
          let idx: number = 0;
          let cm: RegExpExecArray | null = compRe.exec(inner);
          while (cm !== null) {
            const sub: string | undefined = idx < subs.length ? subs[idx] : undefined;
            const printable: boolean = sub === undefined || sub === 'normal_part';
            if (printable) {
              kept.push(cm[0]);
            } else {
              dropped++;
            }
            idx++;
            cm = compRe.exec(inner);
          }
          // 全被摘掉说明映射没对上，宁可不动
          if (kept.length > 0 && kept.length < idx) {
            newBody = body.substring(0, cb.index) + `<components>${kept.join('')}</components>`
              + body.substring(cb.index + cb[0].length);
          }
        }
      }
      out += xml.substring(last, m.index) + `<object ${m[1]}>${newBody}</object>`;
      last = m.index + m[0].length;
      m = objRe.exec(xml);
    }
    out += xml.substring(last);
    if (dropped > 0) {
      hilog.info(0x0000, TAG, '按 subtype 摘掉非打印部件 %{public}d 个', dropped);
    }
    return out;
  }

  // ---------------- 自写 ZIP（store-only） ----------------
  //
  // 为什么不用 zlib.compressFile：它压的是**单个文件**，传目录只会得到 0 字节，
  // 而 SDK 没有「压缩目录」的 API，3MF 又必须是带目录结构的 zip，所以这里自己写。

  private static crcTable: number[] = Calib3mf.buildCrcTable();

  private static buildCrcTable(): number[] {
    const t: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c: number = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) !== 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      t.push(c >>> 0);
    }
    return t;
  }

  private static crc32(d: Uint8Array): number {
    let c: number = 0xFFFFFFFF;
    for (let i = 0; i < d.length; i++) {
      c = (Calib3mf.crcTable[(c ^ d[i]) & 0xFF] ^ (c >>> 8)) >>> 0;
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  private static putU16(buf: Uint8Array, off: number, v: number): void {
    buf[off] = v & 0xFF;
    buf[off + 1] = (v >>> 8) & 0xFF;
  }

  private static putU32(buf: Uint8Array, off: number, v: number): void {
    buf[off] = v & 0xFF;
    buf[off + 1] = (v >>> 8) & 0xFF;
    buf[off + 2] = (v >>> 16) & 0xFF;
    buf[off + 3] = (v >>> 24) & 0xFF;
  }

  private static nameBytes(name: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(name.length);
    for (let i = 0; i < name.length; i++) {
      out[i] = name.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  private static readBytes(p: string): Uint8Array | null {
    try {
      const size: number = fs.statSync(p).size;
      const ab: ArrayBuffer = new ArrayBuffer(size);
      const f: fs.File = fs.openSync(p, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(f.fd, ab, { offset: 0 });
      } finally {
        fs.closeSync(f);
      }
      return new Uint8Array(ab);
    } catch (e) {
      hilog.error(0x0000, TAG, '读文件失败 %{public}s: %{public}s', p,
        e instanceof Error ? e.message : JSON.stringify(e));
      return null;
    }
  }

  // 把 baseDir 下的全部文件打成 store-only zip
  private static writeZip(baseDir: string, dstPath: string): number {
    const entries: ZipEntry[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(baseDir, { recursion: true });
    } catch (e) {
      hilog.error(0x0000, TAG, '列目录失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return 0;
    }
    names.sort();
    for (const rel of names) {
      const full: string = `${baseDir}/${rel}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          continue;
        }
      } catch (e) {
        continue;
      }
      const data: Uint8Array | null = Calib3mf.readBytes(full);
      if (data === null) {
        continue;
      }
      // fs.listFileSync(recursion) 的返回名带前导 "/"，直接打进 zip 会变成 "/3D/3dmodel.model"，
      // 内核按 "3D/3dmodel.model" 查找就找不到，报 "Loading of a model file failed"。
      let name: string = rel.replace(new RegExp('\\\\', 'g'), '/');
      while (name.startsWith('/')) {
        name = name.substring(1);
      }
      entries.push({ name: name, data: data });
    }
    if (entries.length === 0) {
      hilog.warn(0x0000, TAG, '临时目录里没有文件，无法打包');
      return 0;
    }
    let total: number = 22;
    for (const e of entries) {
      total += 30 + e.name.length + e.data.length + 46 + e.name.length;
    }
    const buf: Uint8Array = new Uint8Array(total);
    const crcs: number[] = [];
    const offs: number[] = [];
    let p: number = 0;
    for (const e of entries) {
      const nb: Uint8Array = Calib3mf.nameBytes(e.name);
      const crc: number = Calib3mf.crc32(e.data);
      crcs.push(crc);
      offs.push(p);
      Calib3mf.putU32(buf, p, 0x04034B50);
      Calib3mf.putU16(buf, p + 4, 20);
      Calib3mf.putU16(buf, p + 6, 0);
      Calib3mf.putU16(buf, p + 8, 0);
      Calib3mf.putU16(buf, p + 10, 0);
      Calib3mf.putU16(buf, p + 12, 0);
      Calib3mf.putU32(buf, p + 14, crc);
      Calib3mf.putU32(buf, p + 18, e.data.length);
      Calib3mf.putU32(buf, p + 22, e.data.length);
      Calib3mf.putU16(buf, p + 26, nb.length);
      Calib3mf.putU16(buf, p + 28, 0);
      p += 30;
      buf.set(nb, p);
      p += nb.length;
      buf.set(e.data, p);
      p += e.data.length;
    }
    const cdStart: number = p;
    for (let i = 0; i < entries.length; i++) {
      const e: ZipEntry = entries[i];
      const nb: Uint8Array = Calib3mf.nameBytes(e.name);
      Calib3mf.putU32(buf, p, 0x02014B50);
      Calib3mf.putU16(buf, p + 4, 20);
      Calib3mf.putU16(buf, p + 6, 20);
      Calib3mf.putU16(buf, p + 8, 0);
      Calib3mf.putU16(buf, p + 10, 0);
      Calib3mf.putU16(buf, p + 12, 0);
      Calib3mf.putU16(buf, p + 14, 0);
      Calib3mf.putU32(buf, p + 16, crcs[i]);
      Calib3mf.putU32(buf, p + 20, e.data.length);
      Calib3mf.putU32(buf, p + 24, e.data.length);
      Calib3mf.putU16(buf, p + 28, nb.length);
      Calib3mf.putU16(buf, p + 30, 0);
      Calib3mf.putU16(buf, p + 32, 0);
      Calib3mf.putU16(buf, p + 34, 0);
      Calib3mf.putU16(buf, p + 36, 0);
      Calib3mf.putU32(buf, p + 38, 0);
      Calib3mf.putU32(buf, p + 42, offs[i]);
      p += 46;
      buf.set(nb, p);
      p += nb.length;
    }
    const cdSize: number = p - cdStart;
    Calib3mf.putU32(buf, p, 0x06054B50);
    Calib3mf.putU16(buf, p + 4, 0);
    Calib3mf.putU16(buf, p + 6, 0);
    Calib3mf.putU16(buf, p + 8, entries.length);
    Calib3mf.putU16(buf, p + 10, entries.length);
    Calib3mf.putU32(buf, p + 12, cdSize);
    Calib3mf.putU32(buf, p + 16, cdStart);
    Calib3mf.putU16(buf, p + 20, 0);
    p += 22;
    try {
      const f: fs.File = fs.openSync(dstPath,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, buf.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, '写 zip 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return 0;
    }
    hilog.info(0x0000, TAG, 'zip 打包完成 文件=%{public}d 字节=%{public}d', entries.length, p);
    return p;
  }

  // 归一化：src 3mf → dst 3mf（XY 居中到板心、Z 落到板面）。失败返回空串，调用方沿用原文件。
  static async centerToBed(srcPath: string, dstPath: string): Promise<string> {
    Calib3mf.lastOverrides = '';
    Calib3mf.lastBlocks = '';
    Calib3mf.objNames = new Map<string, string>();
    const work: string = `${dstPath}.dir`;
    try {
      fs.rmdirSync(work);
    } catch (e) {
      // 目录不存在是正常路径
    }
    try {
      fs.mkdirSync(work);
    } catch (e) {
      hilog.error(0x0000, TAG, '创建临时目录失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return '';
    }
    try {
      await zlib.decompressFile(srcPath, work);
    } catch (e) {
      hilog.error(0x0000, TAG, '解包 3MF 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return '';
    }
    const rootKey: string = '3D/3dmodel.model';
    const modelPath: string = `${work}/${rootKey}`;
    let xml: string = '';
    try {
      xml = fs.readTextSync(modelPath);
    } catch (e) {
      hilog.error(0x0000, TAG, '读 model XML 失败（不是标准 3MF？）: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return '';
    }
    // 先按 model_settings.config 的 subtype 摘掉参数修改器，再算包围盒/摆位
    Calib3mf.lastOverrides = Calib3mf.readProcessOverrides(work);
    try {
      const cfgXml: string = fs.readTextSync(`${work}/Metadata/model_settings.config`);
      xml = Calib3mf.dropNonPrintableParts(xml, Calib3mf.parsePartSubtypes(cfgXml));
    } catch (e) {
      // 没有 model_settings.config（或不是拓竹包）就跳过
    }
    // 全部 .model 文件（根文件 + 子模型）→ 对象表
    const objs: Map<string, ObjDef> = new Map<string, ObjDef>();
    let models: string[] = [];
    try {
      models = fs.listFileSync(`${work}/3D`, { recursion: true });
    } catch (e) {
      models = [];
    }
    models.push('3dmodel.model');
    for (const rel of models) {
      let rel2: string = rel.replace(new RegExp('\\\\', 'g'), '/');
      while (rel2.startsWith('/')) {
        rel2 = rel2.substring(1);
      }
      const key: string = `3D/${rel2}`;
      if (!key.endsWith('.model')) {
        continue;
      }
      try {
        // 根文件用（已过滤修改器部件的）xml，子模型仍从磁盘读
        const text: string = key === rootKey ? xml : fs.readTextSync(`${work}/${key}`);
        Calib3mf.parseModelFile(text, objs, key);
      } catch (e) {
        // 子模型读失败就跳过，包围盒按已解析到的算
      }
    }
    // 按 build 的 item 合成真实包围盒
    const acc: number[] = [];
    // 每个 item 的（对象名, 板上中心 X）—— 流量试块靠它给用户排出「从左到右第几块」
    const blockNames: string[] = [];
    const blockCx: number[] = [];
    const itemRe: RegExp = new RegExp('<item\\s+([^>]*?)/>', 'g');
    let im: RegExpExecArray | null = itemRe.exec(xml);
    let itemCount: number = 0;
    while (im !== null) {
      const oid: string = Calib3mf.attr(im[1], 'objectid');
      const tf: string = Calib3mf.attr(im[1], 'transform');
      const xf: number[] = tf === '' ? Calib3mf.identity() : Calib3mf.parseMatrix(tf);
      const one: number[] = [];
      Calib3mf.collect(rootKey, oid, xf, objs, one, 0);
      for (let k = 0; k < one.length; k++) {
        acc.push(one[k]);
      }
      if (one.length >= 3) {
        let lo: number = one[0];
        let hi: number = one[0];
        for (let k = 0; k + 2 < one.length; k += 3) {
          if (one[k] < lo) { lo = one[k]; }
          if (one[k] > hi) { hi = one[k]; }
        }
        blockNames.push(Calib3mf.objNames.get(`${rootKey}#${oid}`) ?? '');
        blockCx.push((lo + hi) / 2);
      }
      itemCount++;
      im = itemRe.exec(xml);
    }
    Calib3mf.lastBlocks = Calib3mf.buildBlockList(blockNames, blockCx);
    if (acc.length < 3) {
      hilog.warn(0x0000, TAG, '没解析到几何，跳过归一化 item=%{public}d 对象=%{public}d',
        itemCount, objs.size);
      return '';
    }
    let minX: number = acc[0];
    let minY: number = acc[1];
    let minZ: number = acc[2];
    let maxX: number = acc[0];
    let maxY: number = acc[1];
    let maxZ: number = acc[2];
    for (let i = 0; i + 2 < acc.length; i += 3) {
      if (acc[i] < minX) { minX = acc[i]; }
      if (acc[i] > maxX) { maxX = acc[i]; }
      if (acc[i + 1] < minY) { minY = acc[i + 1]; }
      if (acc[i + 1] > maxY) { maxY = acc[i + 1]; }
      if (acc[i + 2] < minZ) { minZ = acc[i + 2]; }
      if (acc[i + 2] > maxZ) { maxZ = acc[i + 2]; }
    }
    const bed: BedBox = Calib3mf.bedBox();
    const cx: number = (bed.minX + bed.maxX) / 2;
    const cy: number = (bed.minY + bed.maxY) / 2;
    const dx: number = cx - (minX + maxX) / 2;
    const dy: number = cy - (minY + maxY) / 2;
    const dz: number = -minZ;
    hilog.info(0x0000, TAG,
      '摆位归一化 顶点=%{public}d 包围盒 x=[%{public}s,%{public}s] y=[%{public}s,%{public}s] z=[%{public}s,%{public}s] 平移=(%{public}s,%{public}s,%{public}s)',
      acc.length / 3, minX.toFixed(2), maxX.toFixed(2), minY.toFixed(2), maxY.toFixed(2),
      minZ.toFixed(2), maxZ.toFixed(2), dx.toFixed(2), dy.toFixed(2), dz.toFixed(2));
    const patched: string = Calib3mf.applyShift(xml, dx, dy, dz);
    try {
      const f: fs.File = fs.openSync(modelPath, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, patched);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, '写回 model XML 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return '';
    }
    const size: number = Calib3mf.writeZip(work, dstPath);
    try {
      fs.rmdirSync(work);
    } catch (e) {
      // 清理失败不影响结果
    }
    hilog.info(0x0000, TAG, '归一化完成 %{public}s size=%{public}d', dstPath, size);
    return size > 0 ? dstPath : '';
  }

  // ---------------- 3MF 自带工艺参数（project_settings.config） ----------------
  //
  // 拓竹随包校准模型是按**它自己的**工艺参数设计的（这套自动 PA 线就是
  // layer_height = 0.2 / initial_layer_print_height = 0.2，一条 0.2mm 高的线正好一整层）。
  // 用界面当前预设（0.16/0.20）去切，0.2mm 高的线落在「首层 + 一层残料」上，
  // 内核报 empty initial layer。所以校准切片必须按模型自带的工艺参数来。
  //
  // 只取**工艺**键（层高/线宽/墙数），不碰打印机、热床、耗材身份：
  // 这些模型是在 A1 上做的，把 printer_model 一起抄过来会让 X1C 用户按 A1 的参数打印。
  private static readonly PROCESS_KEYS: string[] = [
    'layer_height', 'initial_layer_print_height',
    'line_width', 'initial_layer_line_width', 'outer_wall_line_width',
    'inner_wall_line_width', 'internal_solid_infill_line_width',
    'sparse_infill_line_width', 'top_surface_line_width', 'support_line_width',
    'wall_loops', 'detect_thin_wall', 'filter_out_gap_fill'
  ];

  // 取值是枚举名的键（内核 apply_params 用 set_deserialize，认名字不认下标）
  private static readonly ENUM_KEYS: string[] = ['wall_generator'];

  // 从已解包的 3MF 目录读 project_settings.config，产出可直接并进 paramsJson 的片段。
  // 返回 '' 表示这份 3MF 没带工艺参数（用界面预设即可）。
  private static readProcessOverrides(work: string): string {
    let raw: string = '';
    try {
      raw = fs.readTextSync(`${work}/Metadata/project_settings.config`);
    } catch (e) {
      return '';
    }
    if (raw.length === 0) {
      return '';
    }
    let cfg: Record<string, Object> | null = null;
    try {
      cfg = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'project_settings.config 解析失败，按界面预设切');
      return '';
    }
    if (cfg === null) {
      return '';
    }
    let frag: string = '';
    const names: string[] = [];
    for (const key of Calib3mf.PROCESS_KEYS) {
      const v: Object | undefined = cfg[key];
      if (v === undefined || v === null) {
        continue;
      }
      let num: number = NaN;
      if (typeof v === 'number') {
        num = v as number;
      } else if (typeof v === 'string') {
        num = Number.parseFloat(v as string);
      } else {
        continue;
      }
      if (!Number.isFinite(num) || num <= 0) {
        continue;
      }
      frag += `,"${key}":${num}`;
      names.push(`${key}=${num}`);
    }
    for (const key of Calib3mf.ENUM_KEYS) {
      const v: Object | undefined = cfg[key];
      if (v !== undefined && v !== null && typeof v === 'string' && (v as string).length > 0) {
        frag += `,"${key}":"${v as string}"`;
        names.push(`${key}=${v as string}`);
      }
    }
    if (frag.length > 0) {
      hilog.info(0x0000, TAG, '模型自带工艺参数 %{public}s', names.join(' '));
    }
    return frag;
  }

  // 试块清单：按板上 X（从左到右）排序，输出 "对象名|百分比;..."。
  // 只认拓竹流量试块的命名约定 flowrate_<n> / flowrate_m<n>（m=负）：
  // pass1 是 flowrate_m20..20（±20%，5% 步进），pass2 是 flowrate_0..m9（0~-9%，1% 步进）。
  // 命名对不上（例如 PA 图案只有一个 Cube）就返回空串，界面不显示挑块。
  private static buildBlockList(names: string[], cxs: number[]): string {
    if (names.length < 2 || names.length !== cxs.length) {
      return '';
    }
    const idx: number[] = [];
    for (let i = 0; i < names.length; i++) {
      idx.push(i);
    }
    idx.sort((a: number, b: number): number => cxs[a] - cxs[b]);
    let out: string = '';
    for (const i of idx) {
      const m: RegExpMatchArray | null = names[i].match(/^flowrate_(m?)(\d+)$/);
      if (m === null) {
        return '';
      }
      const pct: number = (m[1] === 'm' ? -1 : 1) * Number.parseInt(m[2], 10);
      out += `${out === '' ? '' : ';'}${names[i]}|${pct}`;
    }
    return out;
  }

  // 归一化的完整结果：产物路径 + 该模型自带的工艺覆盖片段
  static async prepare(srcPath: string, dstPath: string): Promise<CalibPrepResult> {
    const path: string = await Calib3mf.centerToBed(srcPath, dstPath);
    return new CalibPrepResult(path, Calib3mf.lastOverrides, Calib3mf.lastBlocks);
  }
}

// 归一化结果：path 为空串表示没产出（调用方回退原文件）；overrides 为空串表示用界面预设；
// blocks 为空串表示这份模型没有可挑选的试块（不是流量校准模型）
export class CalibPrepResult {
  readonly path: string;
  readonly overrides: string;
  readonly blocks: string;

  constructor(path: string, overrides: string, blocks: string) {
    this.path = path;
    this.overrides = overrides;
    this.blocks = blocks;
  }
}
