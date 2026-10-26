import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLog } from './AppLog';
import { AmsSlot } from './PrintOptions';
import { modelState, ModelInstance } from '../model/ModelState';
import { SliceParamStore, DISPLAY_COLOR_DEFAULT } from './SliceParamStore';

// =============================================================================
// 双喷嘴「耗材分组 / AMS↔喷嘴配对 / 材料级限制」服务（对齐官方双喷嘴工作流）。
//
// 规格来源（第 0 步官方原文）：
//   [A] https://wiki.bambulab.com/en/h2/manual/printable-range-for-dual-nozzles
//   [B] https://wiki.bambulab.com/en/software/bambu-studio/manual/dual-nozzles-slicing-filament-grouping
//
// 核心语义（官方原文见报告）：
//   1) 分组三模式：省料模式（默认）/ 便携模式 / 自定义模式。用户可在切片按钮浮窗切换。
//   2) 喷嘴归属以【耗材槽位分组】为准：某个耗材槽位被分到哪一侧喷嘴，用它的对象就在哪一侧。
//      槽位键 =「显示色 | 材料类型」（与切片侧 SliceParamStore.multicolorFragment 同一口径）：
//      同材料不同色 → 不同槽位（可分别归到左右喷嘴）；同材料同色 → 同一槽位。
//   3) 「对象落在仅左/仅右区 → 强制该侧」「高度>320mm → 必须右喷」是硬约束；
//      材料级限制（PPA-CF/PPS-CF 只能左喷；TPU 规则）按【材料类型】判定、优先级最高（High），
//      不随颜色变化。约束之间冲突（同一槽位既被要求左、又被要求右）→ 报错（复用「超出打印区域」告警）。
//   4) AMS↔喷嘴配对：把某个 AMS 单元指定给左/右喷嘴；未配对时按「未配对」处理并明确提示。
//
// 口径说明（与本机实现）：
//   · 本工程内核（libslic3r FilamentGroupUtils / MultiNozzleUtils）里有官方分组算法，但本任务
//     不重编静态库；这里在 ETS 层按官方语义复刻，供 UI（打印弹窗/告警）使用。
//   · 省料模式的「最小化换料量」官方依赖逐层耗材/冲刷量矩阵（切片后才定）；切片前本层用
//     「按用量从多到少交替分到左右两侧」作为文档化的近似（把用量最大的耗材尽量拆到不同喷嘴）。
//   · 便携模式按 AMS 实装耗材匹配（材料类型 + 颜色 ΔE 近似，RGB 距离）。
// =============================================================================

const TAG: string = 'FilamentGroup';
const GROUP_FILE: string = 'filament_grouping.json';
const DOMAIN: number = 0x0000;

// 喷嘴侧
export const SIDE_LEFT: string = 'left';
export const SIDE_RIGHT: string = 'right';
export const SIDE_NONE: string = '';

// 分组模式
export const MODE_SAVING: string = 'saving';           // 省料（官方默认）
export const MODE_CONVENIENCE: string = 'convenience'; // 便携
export const MODE_CUSTOM: string = 'custom';           // 自定义

// 左喷嘴最大可打印高度（官方 [B] 3 节：>320mm 必须放右喷区）
const LEFT_NOZZLE_MAX_HEIGHT: number = 320;

// 持久化：AMS↔喷嘴配对的一项
export class PairEntry {
  amsId: number = 0;   // 真实 ams.id；外挂料盘 = EXTERNAL_AMS_ID(-1)
  side: string = '';   // 'left' | 'right' | ''（'' = 明确不配对/取消）
}

// 持久化：自定义模式下某个耗材的指定侧
export class CustomEntry {
  filament: string = '';
  side: string = '';
}

// 持久化快照（整份 JSON）
export class GroupingSnapshot {
  mode: string = MODE_SAVING;
  custom: CustomEntry[] = [];
  pairing: PairEntry[] = [];
}

// 单个耗材的分组结论
export class FilamentSide {
  filament: string = '';
  side: string = SIDE_NONE;
  reason: string = '';      // 归属依据（材料限制/区域约束/分组算法…）
  forced: boolean = false;  // 是否被硬约束（材料/区域/高度）强制
}

// 整盘分组结果
export class GroupingResult {
  filamentSide: Map<string, string> = new Map<string, string>(); // 耗材 -> 侧
  objSide: Map<number, string> = new Map<number, string>();      // 对象 id -> 侧
  objError: Map<number, string> = new Map<number, string>();     // 对象 id -> 阻止打印原因（非空=冲突）
}

// 材料级限制规则
export class MaterialRule {
  forceSide: string = SIDE_NONE;   // 强制某侧（左/右）；空=无
  forbidLeft: boolean = false;
  forbidRight: boolean = false;
  reason: string = '';
}

// 单个对象的聚合输入（内联给 recompute 用，避免服务反向依赖面板）
export class ObjGroupInput {
  id: number = 0;
  filament: string = '';
  color: string = '';              // 预览显示色（'' = 未设色 → 用 DISPLAY_COLOR_DEFAULT）
  zoneSide: string = SIDE_NONE;    // 仅左/仅右区强制（'' = 中间共用区）
  zoneConflict: boolean = false;   // 同时触碰左右
  heightMm: number = 0;            // 对象 Z 高度
}

export class FilamentGrouping {
  private static snap_: GroupingSnapshot = new GroupingSnapshot();
  private static loaded_: boolean = false;
  // 最近一次已知的真实 AMS 槽位（便携模式匹配用）。打印入口读到真实 AMS 后写入缓存；
  // 3D 页重算时也用这份缓存，避免「有 AMS / 无 AMS」两处算法互相翻面导致抖动。
  private static cachedSlots: AmsSlot[] = [];

  static setAmsSlots(slots: AmsSlot[]): void {
    if (slots.length > 0) { FilamentGrouping.cachedSlots = slots; }
  }

  // 读当前内存快照（未 load 时是默认：省料模式 + 无配对）
  static snap(): GroupingSnapshot {
    return FilamentGrouping.snap_;
  }

  static isLoaded(): boolean {
    return FilamentGrouping.loaded_;
  }

  // 读盘（无文件 → 默认省料模式；不编造配对）
  static load(filesDir: string): void {
    FilamentGrouping.snap_ = new GroupingSnapshot();
    FilamentGrouping.loaded_ = true;
    if (filesDir.length === 0) {
      FilamentGrouping.publishRev();
      return;
    }
    const path: string = `${filesDir}/${GROUP_FILE}`;
    try {
      if (fs.accessSync(path)) {
        const text: string = fs.readTextSync(path);
        if (text.length > 0) {
          const raw: GroupingSnapshot = JSON.parse(text) as GroupingSnapshot;
          const s: GroupingSnapshot = new GroupingSnapshot();
          s.mode = (raw.mode === MODE_CONVENIENCE || raw.mode === MODE_CUSTOM) ? raw.mode : MODE_SAVING;
          const cu: CustomEntry[] = raw.custom !== undefined ? raw.custom : [];
          for (const e of cu) { s.custom.push(e); }
          const pa: PairEntry[] = raw.pairing !== undefined ? raw.pairing : [];
          for (const e of pa) { s.pairing.push(e); }
          FilamentGrouping.snap_ = s;
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '读分组设置失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    hilog.info(DOMAIN, TAG, '分组设置就绪: 模式=%{public}s 配对=%{public}d 自定义=%{public}d',
      FilamentGrouping.snap_.mode, FilamentGrouping.snap_.pairing.length, FilamentGrouping.snap_.custom.length);
    FilamentGrouping.publishRev();
  }

  // 落盘
  static save(filesDir: string): void {
    if (filesDir.length === 0) { return; }
    const path: string = `${filesDir}/${GROUP_FILE}`;
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(FilamentGrouping.snap_));
      } finally {
        fs.closeSync(f);
      }
      AppLog.note('DualNozzle|分组设置',
        `保存 模式=${FilamentGrouping.snap_.mode} 配对=${FilamentGrouping.snap_.pairing.length} 自定义=${FilamentGrouping.snap_.custom.length}`);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '保存分组设置失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  private static publishRev(): void {
    const rev: number = AppStorage.get<number>('groupingRev') ?? 0;
    AppStorage.setOrCreate<number>('groupingRev', rev + 1);
    AppStorage.setOrCreate<string>('groupingMode', FilamentGrouping.snap_.mode);
  }

  static setMode(mode: string): void {
    FilamentGrouping.snap_.mode = mode;
    FilamentGrouping.publishRev();
    hilog.info(DOMAIN, TAG, '切换分组模式: %{public}s', mode);
    AppLog.push(`[DualNozzle] 切换耗材分组模式=${mode}`);
  }

  // AMS 单元 -> 喷嘴侧（'' = 未配对 / 取消配对）
  static pairingSide(amsId: number): string {
    for (const p of FilamentGrouping.snap_.pairing) {
      if (p.amsId === amsId) { return p.side; }
    }
    return SIDE_NONE;
  }

  static setPairing(amsId: number, side: string): void {
    let found: boolean = false;
    for (const p of FilamentGrouping.snap_.pairing) {
      if (p.amsId === amsId) { p.side = side; found = true; }
    }
    if (!found) {
      const e: PairEntry = new PairEntry();
      e.amsId = amsId;
      e.side = side;
      FilamentGrouping.snap_.pairing.push(e);
    }
    FilamentGrouping.publishRev();
    AppLog.push(`[DualNozzle] AMS↔喷嘴配对: 单元=${amsId} 侧=${side !== '' ? side : '未配对'}`);
  }

  static customSide(filament: string): string {
    for (const c of FilamentGrouping.snap_.custom) {
      if (c.filament === filament) { return c.side; }
    }
    return SIDE_NONE;
  }

  static setCustom(filament: string, side: string): void {
    let found: boolean = false;
    for (const c of FilamentGrouping.snap_.custom) {
      if (c.filament === filament) { c.side = side; found = true; }
    }
    if (!found) {
      const e: CustomEntry = new CustomEntry();
      e.filament = filament;
      e.side = side;
      FilamentGrouping.snap_.custom.push(e);
    }
    FilamentGrouping.publishRev();
    AppLog.push(`[DualNozzle] 自定义分组: 耗材=${filament} 侧=${side !== '' ? side : '未指定'}`);
  }

  static modeLabel(mode: string): string {
    if (mode === MODE_CONVENIENCE) { return '便携'; }
    if (mode === MODE_CUSTOM) { return '自定义'; }
    return '省料';
  }

  static sideLabel(side: string): string {
    if (side === SIDE_LEFT) { return '左喷'; }
    if (side === SIDE_RIGHT) { return '右喷'; }
    return '未定';
  }

  // ---- 耗材名解析 -----------------------------------------------------------
  // 材料类型：取 "Bambu PLA Basic @BBL X1C" -> "PLA"。用于材料限制与便携匹配。
  static materialType(name: string): string {
    let s: string = name;
    const at: number = s.indexOf('@');
    if (at >= 0) { s = s.substring(0, at); }
    s = s.replace('Bambu Lab', '').replace('Bambu', '').replace('Generic', '').trim();
    const sp: number = s.indexOf(' ');
    if (sp > 0) { s = s.substring(0, sp); }
    return s.toUpperCase().trim();
  }

  // 材料级限制（官方 [B] 3 节 Group restrictions 清单）。
  // H2C 左喷暂不支持 TPU；PPA-CF/PPS-CF 只能左喷。
  static materialRule(filament: string, printer: string): MaterialRule {
    const r: MaterialRule = new MaterialRule();
    const type: string = FilamentGrouping.materialType(filament);
    const low: string = filament.toUpperCase();
    const pm: string = printer.toUpperCase();
    if (type.indexOf('PPA') >= 0 || type.indexOf('PPS') >= 0 ||
        low.indexOf('PPA-CF') >= 0 || low.indexOf('PPS-CF') >= 0) {
      r.forceSide = SIDE_LEFT;
      r.forbidRight = true;
      r.reason = 'PPA-CF/PPS-CF 只能左喷嘴';
      return r;
    }
    if (type.indexOf('TPU') >= 0) {
      // H2C 左喷暂不支持 TPU → 只能右喷
      if (pm.indexOf('H2C') >= 0) {
        r.forceSide = SIDE_RIGHT;
        r.forbidLeft = true;
        r.reason = 'H2C 左喷嘴暂不支持 TPU（只能右喷嘴）';
      } else {
        r.reason = 'TPU（左喷打 TPU 时右喷不可用）';
      }
      return r;
    }
    return r;
  }

  private static isTpu(filament: string): boolean {
    return FilamentGrouping.materialType(filament).indexOf('TPU') >= 0;
  }

  // ---- 分组计算 -------------------------------------------------------------
  // 输入：本盘全部对象（含各自耗材/显示色/区域约束/高度）
  // 输出：耗材槽位 -> 侧、对象 -> 侧、对象 -> 阻止原因
  // 优先级（官方 [B] 4 节降序 + 3 节优先级）：材料不可打 > 区域/高度强制 > AMS 容量 > 省料 > ΔE
  static compute(objs: ObjGroupInput[], printer: string, amsSlots: AmsSlot[]): GroupingResult {
    const res: GroupingResult = new GroupingResult();
    const mode: string = FilamentGrouping.snap_.mode;

    // 1) 按【耗材槽位】聚合对象（槽位键 = 显示色 | 材料类型，与切片侧 multicolorFragment 同一口径）。
    //    同材料不同色 → 不同槽位（可分别归到左右喷嘴，修复「同料异色被误判越界」）；
    //    同材料同色   → 同一槽位（被同时要求左右两侧时仍是真冲突，必须保留）。
    const bySlot: Map<string, ObjGroupInput[]> = new Map<string, ObjGroupInput[]>();
    const slotFilament: Map<string, string> = new Map<string, string>(); // 槽位 -> 代表耗材预设名（材料规则/自定义查找用）
    const slotColor: Map<string, string> = new Map<string, string>();    // 槽位 -> 显示色（便携匹配用）
    for (const o of objs) {
      const key: string = FilamentGrouping.slotKeyOf(o);
      let arr: ObjGroupInput[] | undefined = bySlot.get(key);
      if (arr === undefined) {
        arr = [];
        bySlot.set(key, arr);
        slotFilament.set(key, o.filament);
        slotColor.set(key, o.color);
      }
      arr.push(o);
    }

    // 2) 逐槽位确定允许侧（约束交集）
    const decided: Map<string, FilamentSide> = new Map<string, FilamentSide>();
    const conflictFil: Map<string, string> = new Map<string, string>();
    const undetermined: string[] = [];
    bySlot.forEach((arr: ObjGroupInput[], key: string): void => {
      const fil: string = slotFilament.get(key) ?? key; // 代表耗材名：供材料级限制/自定义查找（限制按材料类型判定）
      const fs: FilamentSide = new FilamentSide();
      fs.filament = key;
      let allowL: boolean = true;
      let allowR: boolean = true;
      let reason: string = '';
      let forced: boolean = false;
      // 2a) 材料限制（最高优先；按【材料类型】判定，同一材料类型的各颜色槽位一致生效）
      const mat: MaterialRule = FilamentGrouping.materialRule(fil, printer);
      if (mat.forceSide === SIDE_LEFT) { allowR = false; reason = mat.reason; forced = true; }
      if (mat.forceSide === SIDE_RIGHT) { allowL = false; reason = mat.reason; forced = true; }
      // 2b) 区域约束（仅左/仅右）—— 同一槽位若被要求两侧 → 冲突
      let zoneL: boolean = false;
      let zoneR: boolean = false;
      let zoneConflict: boolean = false;
      let heightR: boolean = false;
      for (const o of arr) {
        if (o.zoneConflict) { zoneConflict = true; }
        if (o.zoneSide === SIDE_LEFT) { zoneL = true; }
        if (o.zoneSide === SIDE_RIGHT) { zoneR = true; }
        if (o.heightMm > LEFT_NOZZLE_MAX_HEIGHT) { heightR = true; }
      }
      if (zoneConflict) {
        conflictFil.set(key, '对象同时触碰左右喷嘴专属区');
        return;
      }
      if (zoneL && zoneR) {
        conflictFil.set(key, '同色同料的喷嘴槽位被同时要求左右两侧');
        return;
      }
      if (zoneL) { allowR = false; forced = true; reason = reason !== '' ? reason : '对象在仅左喷嘴专属区'; }
      if (zoneR) { allowL = false; forced = true; reason = reason !== '' ? reason : '对象在仅右喷嘴专属区'; }
      if (heightR) {
        // 高度 >320mm → 只能右喷（Z 方向，比水平绿带更进一步）
        if (allowL && !allowR) {
          conflictFil.set(key, `对象高度>${LEFT_NOZZLE_MAX_HEIGHT}mm 但被约束到左喷嘴`);
          return;
        }
        allowL = false;
        forced = true;
        reason = reason !== '' ? reason : `对象高度>${LEFT_NOZZLE_MAX_HEIGHT}mm 必须右喷`;
      }
      if (!allowL && !allowR) {
        conflictFil.set(key, reason !== '' ? reason : '材料/区域约束冲突');
        return;
      }
      if (allowL && !allowR) { fs.side = SIDE_LEFT; fs.forced = forced; fs.reason = reason; decided.set(key, fs); return; }
      if (!allowL && allowR) { fs.side = SIDE_RIGHT; fs.forced = forced; fs.reason = reason; decided.set(key, fs); return; }
      // 两侧都可以 → 交给分组模式
      undetermined.push(key);
    });

    // 3) 未定槽位按模式分配
    if (mode === MODE_CUSTOM) {
      // 逐槽位按其代表耗材用用户自定义侧；未指定的槽位保持「未定」（后续日志/提示），不瞎猜
      for (const key of undetermined) {
        const fil: string = slotFilament.get(key) ?? '';
        const cs: string = FilamentGrouping.customSide(fil);
        if (cs !== SIDE_NONE) {
          const f: FilamentSide = new FilamentSide();
          f.filament = key;
          f.side = cs;
          f.reason = '自定义分组（用户指定）';
          decided.set(key, f);
        }
      }
    } else if (mode === MODE_CONVENIENCE) {
      // 按 AMS 实装耗材匹配（材料类型一致 + 颜色最近）→ 取该 AMS 单元的配对侧
      for (const key of undetermined) {
        const fil: string = slotFilament.get(key) ?? '';
        const unit: number = FilamentGrouping.matchAmsUnit(fil, slotColor.get(key) ?? '', amsSlots);
        const side: string = unit >= 0 ? FilamentGrouping.pairingSide(unit) : SIDE_NONE;
        if (side !== SIDE_NONE) {
          const f: FilamentSide = new FilamentSide();
          f.filament = key;
          f.side = side;
          f.reason = `便携：AMS 单元 ${unit} 已配对到该侧`;
          decided.set(key, f);
        }
      }
    } else {
      // 省料：按用量从多到少交替分到左右（近似「把用量大的耗材尽量拆到不同喷嘴」）
      const usage: Map<string, number> = new Map<string, number>();
      for (const o of objs) {
        const key: string = FilamentGrouping.slotKeyOf(o);
        if (FilamentGrouping.hasUndecided(undetermined, key)) {
          usage.set(key, (usage.get(key) ?? 0) + 1);
        }
      }
      const sorted: string[] = undetermined.slice();
      sorted.sort((a: string, b: string): number => (usage.get(b) ?? 0) - (usage.get(a) ?? 0));
      let ledger: number = 0; // 偶数->左，奇数->右（左右交替，尽量拆开）
      const leftCount: number = FilamentGrouping.countSide(decided, SIDE_LEFT);
      const rightCount: number = FilamentGrouping.countSide(decided, SIDE_RIGHT);
      let lc: number = leftCount;
      let rc: number = rightCount;
      for (const key of sorted) {
        let side: string;
        if (lc < rc) { side = SIDE_LEFT; lc++; } else if (rc < lc) { side = SIDE_RIGHT; rc++; }
        else { side = (ledger % 2 === 0) ? SIDE_LEFT : SIDE_RIGHT; if (side === SIDE_LEFT) { lc++; } else { rc++; } }
        ledger++;
        const f: FilamentSide = new FilamentSide();
        f.filament = key;
        f.side = side;
        f.reason = '省料：按用量交替均衡分组';
        decided.set(key, f);
      }
    }

    // 4) TPU 全局约束：左喷打 TPU → 右喷不可用
    let tpuOnLeft: boolean = false;
    decided.forEach((f: FilamentSide, key: string): void => {
      if (f.side === SIDE_LEFT && FilamentGrouping.isTpu(slotFilament.get(key) ?? '')) { tpuOnLeft = true; }
    });
    if (tpuOnLeft) {
      decided.forEach((f: FilamentSide, key: string): void => {
        if (f.side === SIDE_RIGHT && !f.forced) {
          conflictFil.set(key, '左喷嘴打 TPU 时右喷嘴不可用');
        }
      });
    }

    // 5) 汇总：槽位 -> 侧；对象 -> 侧/错误
    decided.forEach((f: FilamentSide, key: string): void => {
      res.filamentSide.set(key, f.side);
    });
    for (const o of objs) {
      const key: string = FilamentGrouping.slotKeyOf(o);
      const cf: string | undefined = conflictFil.get(key);
      if (cf !== undefined) {
        res.objError.set(o.id, cf);
        res.objSide.set(o.id, SIDE_NONE);
        continue;
      }
      const side: string = res.filamentSide.get(key) ?? SIDE_NONE;
      res.objSide.set(o.id, side);
    }
    return res;
  }

  // 耗材槽位键：与切片侧 SliceParamStore.multicolorFragment 同一口径（显示色 | 材料类型）。
  // 未设色对象用默认显示色（DISPLAY_COLOR_DEFAULT），保证与切片侧「未设色」判定一致。
  private static slotKeyOf(o: ObjGroupInput): string {
    const col: string = o.color !== '' ? o.color : DISPLAY_COLOR_DEFAULT;
    const typ: string = FilamentGrouping.materialType(o.filament);
    return SliceParamStore.slotKey(col, typ);
  }

  private static hasUndecided(list: string[], fil: string): boolean {
    for (const s of list) { if (s === fil) { return true; } }
    return false;
  }

  private static countSide(decided: Map<string, FilamentSide>, side: string): number {
    let n: number = 0;
    decided.forEach((f: FilamentSide): void => { if (f.side === side) { n++; } });
    return n;
  }

  // 便携匹配：材料类型一致的 AMS 槽位里，取颜色最接近的 → 返回其 AMS 单元 id（找不到 -1）
  // color：该槽位的显示色（对象未设色时为空 → 退回按材料类型取第一个）。
  private static matchAmsUnit(filament: string, color: string, slots: AmsSlot[]): number {
    const type: string = FilamentGrouping.materialType(filament);
    const target: string = color !== '' ? color : FilamentGrouping.filamentColorHex(filament);
    let bestUnit: number = -1;
    let bestD: number = 1e18;
    for (const s of slots) {
      const st: string = FilamentGrouping.materialType(s.material);
      if (st === '' || (type !== '' && st !== type)) { continue; }
      if (type === '' && s.material === '') { continue; }
      const d: number = FilamentGrouping.colorDist(target, s.color);
      if (d < bestD) { bestD = d; bestUnit = s.amsId; }
    }
    return bestUnit;
  }

  // 耗材名里没有颜色信息 → 返回空串（纯显示色差异不影响匹配：此时按材料类型取第一个）
  private static filamentColorHex(_name: string): string { return ''; }

  // RGB 欧氏距离（ΔE 的简化近似）
  private static colorDist(a: string, b: string): number {
    if (a === '' || b === '') { return 0; }
    const ca: number[] = FilamentGrouping.hexToRgb(a);
    const cb: number[] = FilamentGrouping.hexToRgb(b);
    const dr: number = ca[0] - cb[0];
    const dg: number = ca[1] - cb[1];
    const db: number = ca[2] - cb[2];
    return dr * dr + dg * dg + db * db;
  }

  private static hexToRgb(hex: string): number[] {
    let s: string = hex;
    if (s.length > 0 && s.charAt(0) === '#') { s = s.substring(1); }
    // 兼容 RRGGBB / RRGGBBAA（Bambu 上报为 8 位，前 6 位是 RGB）
    if (s.length === 8) { s = s.substring(0, 6); }
    if (s.length === 6) {
      const r: number = parseInt(s.substring(0, 2), 16);
      const g: number = parseInt(s.substring(2, 4), 16);
      const b: number = parseInt(s.substring(4, 6), 16);
      return [Number.isNaN(r) ? 0 : r, Number.isNaN(g) ? 0 : g, Number.isNaN(b) ? 0 : b];
    }
    return [0, 0, 0];
  }

  // ---- 绑定到全局状态：读 modelState 现况 → 计算 → 回填 nozzleSide/sideError ----
  // 返回是否发生变化。调用方：3D 页几何更新后、耗材/配对/模式变更后、打印入口。
  //
  // 前置闸门：**单喷嘴机型没有任何「左右喷嘴」概念**。
  //   plateZones 由参数面板按内核预设的 extruder_printable_area 真值算得：
  //   空串 = 该机型 <2 个喷嘴可达区（X1/P1/A1 全系）→ 不分组、不指定侧、不报错。
  //   否则打印弹窗会把「两种颜色」硬要求成「一个左喷一个右喷」，而机器只有一个喷嘴（X1C 实测）。
  //   只有真正存在仅单喷嘴区（H2D/H2C/X2 这类双头机）时，才做分组/配对约束。
  static isDualNozzle(): boolean {
    const zones: string = AppStorage.get<string>('plateZones') ?? '';
    return zones.length > 0;
  }

  static applyToState(printer: string, amsSlots: AmsSlot[]): boolean {
    FilamentGrouping.setAmsSlots(amsSlots);
    if (!FilamentGrouping.isDualNozzle()) {
      const cleared: boolean = modelState.setGroupSides(new Map<number, string>(), new Map<number, string>());
      if (cleared) {
        modelState.revision++;
        AppLog.note('DualNozzle|单喷嘴', '当前机型无单喷嘴专属区（单喷嘴机）→ 不做左右分组，已清空喷嘴归属');
      }
      return cleared;
    }
    const slots: AmsSlot[] = FilamentGrouping.cachedSlots;
    const globalFil: string = AppStorage.get<string>('globalFilamentName') ?? '';
    const objs: ObjGroupInput[] = [];
    const list: ModelInstance[] = modelState.instances;
    for (const inst of list) {
      const o: ObjGroupInput = new ObjGroupInput();
      o.id = inst.id;
      // 对象有效耗材：对象覆盖优先，否则全局耗材名（决定材料类型）
      o.filament = inst.filamentName !== '' ? inst.filamentName : (globalFil !== '' ? globalFil : '(全局耗材)');
      // 槽位键的另一半：显示色。同材料不同色的对象 → 不同槽位（可分别归到左右喷嘴）。
      o.color = inst.displayColor;
      o.zoneSide = inst.zoneSide;
      o.zoneConflict = inst.zoneConflict;
      o.heightMm = inst.heightMm;
      objs.push(o);
    }
    const res: GroupingResult = FilamentGrouping.compute(objs, printer, slots);
    const changed: boolean = modelState.setGroupSides(res.objSide, res.objError);
    if (changed) {
      modelState.revision++;
      FilamentGrouping.logState(res);
    }
    return changed;
  }

  private static logState(res: GroupingResult): void {
    const fl: string[] = [];
    res.filamentSide.forEach((side: string, fil: string): void => { fl.push(`${fil}→${side}`); });
    const errs: string[] = [];
    res.objError.forEach((e: string, id: number): void => { errs.push(`${id}:${e}`); });
    const line: string = `[DualNozzle] 分组结果: 模式=${FilamentGrouping.modeLabel(FilamentGrouping.snap_.mode)}`
      + ` 耗材=${fl.length > 0 ? fl.join(' ') : '(无)'}`
      + ` 冲突=${errs.length > 0 ? errs.join(' ') : '(无)'}`;
    hilog.info(DOMAIN, 'DualNozzle', '%{public}s', line);
    AppLog.note('DualNozzle|分组', line);
  }
}
