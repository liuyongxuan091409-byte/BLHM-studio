import { modelState } from '../model/ModelState';
import { history } from '../model/History';
import { SliceParamStore } from './SliceParamStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// 打印板结构操作（跨组件复用）：新增 / 重命名 / 复制 / 删除
//
// 为什么集中：盘号是「隐式主键」—— 对象只记 `plate` 编号，任何增删都必须走
// ModelState 的 remapPlate / compactPlates 收口（见那里的说明），而且每一步都要
//   ① modelState.publish()（自增 modelRevision → 预览页重算可见性）
//   ② history.commitNow(...)（整步可撤销；盘注册表在 ModelSnapshot 里）
// 现有两处入口 —— 顶部工具抽屉的「新增打印板」、右侧盘条表头的「⋯」菜单 ——
// 语义必须完全一致，各写一份迟早会漂移（与 service/ObjActions 抽出删除是同一个理由）。
// =============================================================================

// 新增一块空盘，返回新盘号
export function plateAddEmpty(): number {
  const idx: number = modelState.addPlate();
  modelState.publish();
  history.commitNow('新增打印板');
  hilog.info(0x0000, 'PlateActions', '新增空盘 idx=%{public}d', idx);
  return idx;
}

// 重命名盘（空名视为放弃，返回 false）
export function plateRename(index: number, name: string): boolean {
  if (index <= 0) {
    return false;
  }
  const n: string = name.trim();
  if (n.length === 0) {
    return false;
  }
  modelState.renamePlate(index, n);
  modelState.publish();
  history.commitNow('重命名打印板');
  return true;
}

// 复制盘（紧随其后 + 盘内对象原样复制到新盘），返回新盘号；失败 -1
export function plateDuplicate(index: number): number {
  if (index <= 0) {
    return -1;
  }
  const n: number = modelState.duplicatePlate(index);
  if (n <= 0) {
    return -1;
  }
  modelState.publish();
  history.commitNow('复制打印板');
  hilog.info(0x0000, 'PlateActions', '复制盘 %{public}d → %{public}d', index, n);
  return n;
}

// 删除盘：盘内对象默认移到「未分盘」（安全默认，不删对象），整步可撤销
export function plateDelete(index: number): void {
  if (index <= 0) {
    return;
  }
  modelState.removePlate(index, 'move');
  modelState.publish();
  history.commitNow('删除打印板');
  hilog.info(0x0000, 'PlateActions', '删除盘 %{public}d，剩余盘数=%{public}d',
    index, modelState.collectPlateIndexes().length);
}

// 删盘后当前盘该切到哪：剩余盘的最后一块；没有剩余盘则 -1（= 显示全部/未分盘）
export function plateActiveAfterDelete(): number {
  const rest: number[] = modelState.collectPlateIndexes();
  return rest.length > 0 ? rest[rest.length - 1] : -1;
}

// =============================================================================
// 盘级床型
//
// 权威：PlateRec.bed（内核 enum 名，如 "Cool Plate"；空 = 跟随全局）。
// 全局床型来自参数 curr_bed_type（面板顶部下拉写它），盘级值只在切片/打印/导出时覆盖。
// =============================================================================

// 当前全局床型（内核 enum 名）；参数未加载时返回 ''
export function globalBedName(): string {
  const ps = SliceParamStore.getParams();
  for (const p of ps) {
    if (p.key !== 'curr_bed_type') {
      continue;
    }
    const i: number = Math.round(p.value);
    return (i >= 0 && i < p.values.length) ? p.values[i] : '';
  }
  return '';
}

// 盘自己设的床型（空串 = 跟随全局）
export function plateBedName(index: number): string {
  const rec = modelState.getPlateRec(index);
  return rec !== undefined ? rec.bed : '';
}

// 盘的有效床型：自己设了就用自己，否则跟随全局
export function effectiveBedName(index: number): string {
  const own: string = plateBedName(index);
  return own.length > 0 ? own : globalBedName();
}

// 内核床型名 → 中文标签（与参数面板同一份枚举；找不到时原样返回）
export function bedLabelOf(name: string): string {
  if (name.length === 0) {
    return '';
  }
  const ps = SliceParamStore.getParams();
  for (const p of ps) {
    if (p.key !== 'curr_bed_type') {
      continue;
    }
    const i: number = p.values.indexOf(name);
    if (i >= 0 && i < p.options.length) {
      return p.options[i];
    }
    break;
  }
  return name;
}

// 盘的有效床型在 curr_bed_type 枚举里的下标；-1 = 不覆盖（盘跟随全局 / 参数未加载）
export function plateBedEnumIndex(index: number): number {
  const own: string = plateBedName(index);
  if (own.length === 0) {
    return -1;
  }
  const ps = SliceParamStore.getParams();
  for (const p of ps) {
    if (p.key !== 'curr_bed_type') {
      continue;
    }
    const i: number = p.values.indexOf(own);
    if (i >= 0) {
      return i;
    }
    // 该床型在当前机型不可用：不覆盖，退回全局（并留痕，方便排查“为什么设了没生效”）
    hilog.warn(0x0000, 'PlateActions',
      '盘 %{public}d 的床型 %{public}s 不在当前机型枚举里 → 本次退回全局床型', index, own);
    return -1;
  }
  return -1;
}

// 床型候选：中文标签（与 bedOptionValues 同序等长）
export function bedOptionLabels(): string[] {
  const out: string[] = [];
  const ps = SliceParamStore.getParams();
  for (const p of ps) {
    if (p.key !== 'curr_bed_type') {
      continue;
    }
    for (let i = 0; i < p.values.length; i++) {
      out.push(i < p.options.length ? p.options[i] : p.values[i]);
    }
    break;
  }
  return out;
}

// 床型候选：内核 enum 名（写回 PlateRec.bed 用）
export function bedOptionValues(): string[] {
  const out: string[] = [];
  const ps = SliceParamStore.getParams();
  for (const p of ps) {
    if (p.key !== 'curr_bed_type') {
      continue;
    }
    for (const v of p.values) {
      out.push(v);
    }
    break;
  }
  return out;
}

// 设置某盘的床型（bed 为空串 = 跟随全局），整步可撤销
export function plateSetBed(index: number, bed: string): boolean {
  if (index <= 0) {
    return false;
  }
  modelState.setPlateBed(index, bed);
  modelState.publish();
  history.commitNow('设置打印板床型');
  hilog.info(0x0000, 'PlateActions', '盘 %{public}d 床型设为 %{public}s（空=跟随全局）',
    index, bed.length > 0 ? bed : '(跟随全局)');
  return true;
}
