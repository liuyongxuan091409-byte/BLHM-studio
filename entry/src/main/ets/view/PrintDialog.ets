import { Theme } from '../common/Theme';
import { hilog } from '@kit.PerformanceAnalysisKit';
import promptAction from '@ohos.promptAction';
import { modelState, ModelInstance } from '../model/ModelState';
import { AmsSlot, PrintOptionsSnapshot, EXTERNAL_AMS_ID } from '../service/PrintOptions';
import { FilamentGrouping } from '../service/FilamentGrouping';
import { AppLog } from '../service/AppLog';

// =============================================================================
// 打印弹窗：对象颜色 ⇄ AMS 槽位映射 + 三个打印开关。
// 视觉对齐原型 mockups/print-dialog.html（深色玻璃 / 单一品牌绿强调 / 橙色表"未指定" / 不用 .shadow()）。
//
// 交互规则（产品已确认）：
//   ① 允许同一 AMS 槽位映射多个对象；
//   ② 未映射完成时禁止打印（开始打印禁用 + 显示「N 个对象待映射」）；
//   ③ 三个开关默认全开；
//   ④ 点对象行选中 → 点槽位行映射（再点一次取消）→ 映射后自动跳到下一个未映射对象；
//   ⑤ 无 AMS：整列隐藏，改为一句"直接使用当前装载耗材打印，无需指定槽位"，左列不再要求映射。
//
// 动效（与原型一致的三处）：弹窗入场、两列方向的阶梯入场、开关/选中反馈。
// 入场用 animIn 一个开关驱动：初始值 → 目标值，配 .animation({delay}) 形成阶梯；
// 交互引起的重建（rows/slotRows 重新赋值）只会重建 key 变化的行，不会重放入场动画。
// =============================================================================

// 原型调色（深色玻璃 + 单一品牌绿）
const C_SURFACE2: string = '#1D1D25';
const C_LINE: string = '#282833';
const C_LINE2: string = '#33333F';
const C_TEXT: string = '#ECECF0';
const C_DIM: string = '#8E8E9C';
const C_WARN: string = '#FFB020';
const C_ACCENT: string = Theme.accent;          // 单一品牌绿
const C_ACCENT_BG: string = '#1200C48C';        // rgba(0,196,140,.07)
const C_ACCENT_LINE: string = '#5C00C48C';      // rgba(0,196,140,.36)
const C_WARN_BG: string = '#12FFB020';
const C_WARN_LINE: string = '#5CFFB020';
const C_INACTIVE: string = '#8A8A92';           // 对象未设显示色时的兜底色

// 校准试块的「伪对象 id」。
// 校准切片不吃场景里的模型对象（Instances=0），但打印弹窗的左列是按对象建的 ——
// 没有行就没有「先点对象再点槽位」这一步，AMS 槽位永远选不了。
// 所以校准场景下补一行虚拟对象，让映射流程照常走；它只参与 UI 与映射串，
// 不会被写进模型场景（modelState 里查不到 -1 就是「无侧/全局耗材」）。
const CALIB_OBJ_ID: number = -1;

// 打印开关的药丸。做成独立 @Component + @Prop：
//   @Prop 在父组件每次重绘时一定会拿到新值并重绘子组件，是这里唯一可靠的刷新路径。
//   【踩过的坑】之前用 @Builder(on: boolean) 把布尔按值传进去 —— ArkUI 的 @Builder 按值传参
//   不会刷新（父组件重绘时 builder 节点复用、参数不再求值），于是点了开关值确实写进了 opts、
//   打印结果也变，但药丸/底色一直不动，看起来就是「按钮没反应」。
@Component
struct PrintOptPill {
  @Prop on: boolean = false;

  build() {
    Row() {
      Column()
        .width(16)
        .height(16)
        .borderRadius(8)
        .backgroundColor(this.on ? C_ACCENT : '#6C6C7C')
        .translate({ x: this.on ? 16 : 0 })
        .animation({ duration: 240, curve: Curve.Friction })
    }
    .width(38)
    .height(22)
    .borderRadius(11)
    .padding({ left: 2, right: 2 })
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.on ? '#1B4E3C' : '#2C2C38')
    .border({ width: 1, color: this.on ? C_ACCENT_LINE : C_LINE })
    .animation({ duration: 220, curve: Curve.EaseOut })
  }
}

// 渲染行（快照）：key 里编进会影响渲染的动态量（映射/选中/占用数），
// 这样 ForEach 才能靠 key 变化重建「真正变了」的那一行（ArkUI 的 ForEach 不重建 key 不变的行）。
class ObjRow {
  key: string = '';
  id: number = 0;
  name: string = '';
  meta: string = '';
  color: string = C_INACTIVE;
  slot: string = '';      // 已映射的槽位号，空 = 未指定
  active: boolean = false;
  side: string = '';      // 喷嘴侧归属：'' 共用区 / 'left' 左专属 / 'right' 右专属
  filament: string = '';  // 该对象所用耗材（分组依据，展示用）
}

class SlotRow {
  key: string = '';
  slotId: string = '';
  color: string = '#808080';
  material: string = '';
  used: number = 0;
  picked: boolean = false;
  disabled: boolean = false;      // 按喷嘴/配对过滤或异侧占用 → 当前对象不可选
  disabledReason: string = '';
  disabledTag: string = '';       // 行内短标签：未配对 / 异侧 / 已占用
}

// 一个 AMS 单元（或外挂料盘）分组：单元标题 + 该单元下的槽位行
class AmsUnitRow {
  key: string = '';
  unitId: number = 0;       // 真实 ams.id（外挂料盘 = EXTERNAL_AMS_ID）
  title: string = '';       // 如 "AMS 1" / "AMS 2" / "外挂料盘"
  slots: SlotRow[] = [];
}

@Component
export struct PrintDialog {
  // 真实 AMS 槽位（无 AMS 时为空数组）
  slots: AmsSlot[] = [];
  // 顶栏右侧的打印机文案（如 "01P00A5000001 · 已连接"）
  printerText: string = '';
  // 机型对照（非阻塞提示用）：切片所用机型预设 vs 当前已连接打印机机型。
  // 任一为空则不提示（以实际存在的字段为准，绝不编造机型）。
  slicePrinter: string = '';
  connectedPrinter: string = '';
  // 开关记忆初值（由页面从 print_options.json 读入）
  initialOptions: PrintOptionsSnapshot = new PrintOptionsSnapshot();
  onCancel: () => void = () => {};
  // 确认：回传开关状态、映射串、已映射数、未映射数
  onConfirm: (opts: PrintOptionsSnapshot, mappingPairs: string, mapped: number, unmapped: number) => void =
    () => {};
  // 上传（FTPS，只上传不打印）：把本地包 PUT 到打印机 /cache/。不关弹窗、不发送任何打印命令。
  onUpload: (opts: PrintOptionsSnapshot, mappingPairs: string, mapped: number, unmapped: number) => void =
    () => {};

  @State private activeId: number = -1;
  @State private rows: ObjRow[] = [];
  @State private slotRows: SlotRow[] = [];
  // 按 AMS 单元/外挂料盘分组的槽位行（渲染用；顺序：AMS0..AMSn，外挂料盘最后）
  @State private unitRows: AmsUnitRow[] = [];
  @State private opts: PrintOptionsSnapshot = new PrintOptionsSnapshot();
  // 三个开关的渲染源：@State 必须是**顶层标量**才会触发重绘。
  // 直接改 this.opts.timelapse 这种「@State 对象的字段」ArkUI 不会重绘 —— 实测点了没反应，
  // 但值确实写进了 plan（打印结果有变化）。这里与 opts 保持同步：状态驱动 UI，opts 供打印使用。
  @State private optTimelapse: boolean = true;
  @State private optBedLeveling: boolean = true;
  @State private optFlowCali: boolean = true;
  @State private animIn: boolean = false;

  // 对象 id → 槽位号（仅内存，不跨次记忆：对象每次都会变）
  private assign: Map<number, string> = new Map<number, string>();

  aboutToAppear(): void {
    this.opts = this.initialOptions;
    this.optTimelapse = this.opts.timelapse;
    this.optBedLeveling = this.opts.bedLeveling;
    this.optFlowCali = this.opts.flowCali;
    this.assign = new Map<number, string>();
    const list: ModelInstance[] = modelState.instances;
    // 校准试块没有场景对象：默认选中那行虚拟对象（CALIB_OBJ_ID），
    // 这样一进弹窗就能直接点 AMS 槽位，不必先"找对象"。
    if (list.length > 0) {
      this.activeId = list[0].id;
    } else {
      this.activeId = this.isCalibPrint() ? CALIB_OBJ_ID : -1;
    }
    this.rebuild();
    // 入场动画：下一拍把 animIn 置真，属性从初值缓动到目标值（阶梯靠各行自身的 delay）
    setTimeout(() => { this.animIn = true; }, 16);
  }

  // 本次打印的是校准试块吗？（校准切片不产生场景对象，但确实有可打印的产物）
  // 判据与 Index.openPrintDialog / ThreeMfExport 同源：calibPrintReady 由 CalibrationPanel 写入。
  private isCalibPrint(): boolean {
    return AppStorage.get<boolean>('calibPrintReady') === true && modelState.instances.length === 0;
  }

  // 对象 id → 最终喷嘴侧（'' | 'left' | 'right'）；对象已不在场景则视为 ''。
  // 该侧由「耗材分组 + 区域/高度/材料约束」计算（见 FilamentGrouping），不再只是区域归属。
  private sideOf(id: number): string {
    const inst: ModelInstance | undefined = modelState.get(id);
    return inst !== undefined ? inst.nozzleSide : '';
  }

  // 对象所用耗材（对象覆盖优先，否则全局；全局名由参数面板发布到 AppStorage）
  private filamentOf(id: number): string {
    const inst: ModelInstance | undefined = modelState.get(id);
    if (inst !== undefined && inst.filamentName !== '') { return inst.filamentName; }
    return AppStorage.get<string>('globalFilamentName') ?? '';
  }

  private sideLabel(side: string): string {
    if (side === 'left') { return '仅左喷嘴'; }
    if (side === 'right') { return '仅右喷嘴'; }
    return '';
  }

  // 槽位号 → 所属 AMS 单元 id（外挂 = EXTERNAL_AMS_ID）
  private amsIdOf(slotId: string): number {
    for (const s of this.slots) {
      if (s.slotId === slotId) { return s.amsId; }
    }
    return 0;
  }

  private hasAms(): boolean {
    return this.slots.length > 0;
  }

  private unmappedCount(): number {
    let n: number = 0;
    for (const r of this.rows) {
      if (r.slot === '') { n++; }
    }
    return n;
  }

  private mappingPairs(): string {
    const parts: string[] = [];
    this.assign.forEach((slot: string, objId: number): void => {
      parts.push(`${objId}→${slot}`);
    });
    return parts.length > 0 ? parts.join(',') : '-';
  }

  // 重建两列渲染快照
  private rebuild(): void {
    const objs: ObjRow[] = [];
    const list: ModelInstance[] = modelState.instances;
    for (const inst of list) {
      const r: ObjRow = new ObjRow();
      r.id = inst.id;
      r.name = inst.name;
      const ft: string = FilamentGrouping.materialType(this.filamentOf(inst.id));
      r.meta = `${inst.format !== '' ? inst.format : '3MF'} · ${inst.triangles} 面${ft !== '' ? ' · ' + ft : ''}`;
      r.color = inst.displayColor !== '' ? inst.displayColor : C_INACTIVE;
      const s: string = this.assign.get(inst.id) ?? '';
      r.slot = s;
      r.active = inst.id === this.activeId;
      r.side = inst.nozzleSide;
      r.filament = this.filamentOf(inst.id);
      r.key = `${inst.id}_${s}_${r.active ? '1' : '0'}_${r.side}`;
      objs.push(r);
    }
    // 校准试块：场景里没有对象，但打印包是真实存在的单耗材包 —— 补一行虚拟对象，
    // 否则左列空白、点不了「对象」，AMS 槽位也就永远选不了。
    // 它不进 modelState：sideOf/filamentOf 查不到 id 时分别退化成「共用侧 / 全局耗材」，正是我们要的。
    if (objs.length === 0 && this.isCalibPrint()) {
      const cr: ObjRow = new ObjRow();
      cr.id = CALIB_OBJ_ID;
      cr.name = '校准试块';
      // 把耗材名带上：用户要据此决定映射到哪个 AMS 槽，只写「单耗材」等于让他猜。
      const cft: string = this.filamentOf(CALIB_OBJ_ID);
      cr.meta = `校准模型 · 单耗材${cft !== '' ? ' · ' + cft : ''}`;
      cr.color = C_INACTIVE;
      const cs: string = this.assign.get(CALIB_OBJ_ID) ?? '';
      cr.slot = cs;
      cr.active = CALIB_OBJ_ID === this.activeId;
      cr.side = '';
      cr.filament = this.filamentOf(CALIB_OBJ_ID);
      cr.key = `${CALIB_OBJ_ID}_${cs}_${cr.active ? '1' : '0'}_`;
      objs.push(cr);
    }
    this.rows = objs;

    const activeSlot: string = this.assign.get(this.activeId) ?? '';
    // 平铺槽位行（供计数/日志）+ 按单元分组的渲染行
    const srs: SlotRow[] = [];
    const units: AmsUnitRow[] = [];
    for (const s of this.slots) {
      const sr: SlotRow = new SlotRow();
      let used: number = 0;
      this.assign.forEach((v: string): void => {
        if (v === s.slotId) { used++; }
      });
      sr.slotId = s.slotId;
      sr.color = s.color;
      sr.material = s.material !== '' ? s.material : '空槽位';
      sr.used = used;
      sr.picked = activeSlot === s.slotId;
      sr.disabledReason = this.slotDisabledReason(s.slotId);
      sr.disabled = sr.disabledReason !== '';
      sr.disabledTag = this.disabledTagOf(sr.disabledReason);
      sr.key = `${s.slotId}_${used}_${sr.picked ? '1' : '0'}_${sr.disabled ? '1' : '0'}_${sr.disabledTag}`;
      srs.push(sr);
      // 分组：外挂料盘（amsId<0）单独一项，其余按 ams.id 分组（顺序按首次出现）
      const unitId: number = s.amsId;
      let unit: AmsUnitRow | undefined = undefined;
      for (const u of units) {
        if (u.unitId === unitId) { unit = u; break; }
      }
      if (unit === undefined) {
        unit = new AmsUnitRow();
        unit.unitId = unitId;
        unit.title = unitId === EXTERNAL_AMS_ID ? '外挂料盘' : `AMS ${unitId + 1}`;
        unit.key = `unit_${unitId}`;
        units.push(unit);
      }
      unit.slots.push(sr);
    }
    this.slotRows = srs;
    this.unitRows = units;
    this.logSlots();
  }

  // 槽位可选性（结合【耗材分组】+【AMS↔喷嘴配对】）：
  // 返回非空字符串 = 禁用并给出说明；空串 = 可选。
  //   ① 中性对象（两侧共用，side=''）：不按配对过滤，也不占槽位。
  //   ② 有侧对象：只允许选【配对到同侧】的 AMS 单元/外挂；单元未配对 → 明确提示「未配对」。
  //   ③ 跨侧互斥：某槽位已被【不同喷嘴侧】的对象占用 → 当前对象不可再选（同类可共用）。
  private slotDisabledReason(slotId: string): string {
    const mySide: string = this.sideOf(this.activeId);
    if (mySide === '') { return ''; }
    // ② AMS↔喷嘴配对过滤
    const amsId: number = this.amsIdOf(slotId);
    const unitSide: string = FilamentGrouping.pairingSide(amsId);
    const myLabel: string = mySide === 'left' ? '左' : '右';
    if (unitSide === '') {
      return `该 AMS 单元未配对到喷嘴侧（对象为${myLabel}喷；请在 设置·双喷嘴 配对）`;
    }
    if (unitSide !== mySide) {
      return `该 AMS 已配对到${unitSide === 'left' ? '左' : '右'}喷嘴，与对象${myLabel}喷不一致`;
    }
    // ③ 跨侧占用
    let claimSide: string = '';
    let claimObj: number = -1;
    this.assign.forEach((sid: string, objId: number): void => {
      if (sid !== slotId || objId === this.activeId) { return; }
      const os: string = this.sideOf(objId);
      if (os !== '' && os !== mySide) {
        claimSide = os;
        claimObj = objId;
      }
    });
    if (claimSide !== '') {
      return `该槽位已分配给${claimSide === 'left' ? '左' : '右'}喷头的对象 ${claimObj}`;
    }
    return '';
  }

  // 禁用原因 → 行内短标签
  private disabledTagOf(reason: string): string {
    if (reason.indexOf('未配对') >= 0) { return '未配对'; }
    if (reason.indexOf('不一致') >= 0) { return '异侧'; }
    if (reason.indexOf('已分配') >= 0) { return '已占用'; }
    return '不可选';
  }

  // 是否存在「未配对」的 AMS 单元（用于弹窗顶部提示，不瞎猜归属）
  // 单喷嘴机型不参与分组/配对 → 这条提示也不该出现（否则会让人以为必须左右配对）。
  private hasUnpairedUnit(): boolean {
    if (!FilamentGrouping.isDualNozzle()) { return false; }
    for (const s of this.slots) {
      if (FilamentGrouping.pairingSide(s.amsId) === '') { return true; }
    }
    return false;
  }

  // 槽位/对象映射三通道日志（tag: AmsSlots）：单元数、各槽位占用、异类禁用情况
  private logSlots(): void {
    const us: string[] = [];
    for (const u of this.unitRows) {
      us.push(`${u.title}(${u.slots.length})`);
    }
    const occ: string[] = [];
    this.assign.forEach((sid: string, objId: number): void => {
      occ.push(`${objId}[${this.sideOf(objId) || '共用'}]→${sid}`);
    });
    const disabled: string[] = [];
    for (const r of this.unitRows) {
      for (const s of r.slots) {
        if (s.disabled) { disabled.push(s.slotId); }
      }
    }
    const line: string = `[AmsSlots] 打印弹窗槽位: 源数=${this.slots.length} 单元=[${us.join(',')}]`
      + ` 当前对象=${this.activeId}(侧=${this.sideOf(this.activeId) || '共用'})`
      + ` 占用=${occ.length > 0 ? occ.join(' ') : '(无)'}`
      + ` 禁用槽位=${disabled.length > 0 ? disabled.join(',') : '(无)'}`
      + ` 外挂料盘=${this.slots.some((s: AmsSlot) => s.amsId === EXTERNAL_AMS_ID) ? '有' : '无'}`;
    hilog.info(0x0000, 'AmsSlots', '%{public}s', line);
    AppLog.note('AmsSlots|槽位', line);
  }

  // 点对象行：只切换选中
  private pickObject(id: number): void {
    this.activeId = id;
    this.rebuild();
  }

  // 点槽位行：异类槽位禁用不可选（给说明）；否则映射 / 再点取消 → 自动跳到下一个未映射对象
  private pickSlot(slotId: string): void {
    // 用「有没有可映射的行」做门，而不是 activeId >= 0：
    // 校准试块的虚拟对象 id 就是 -1，用旧判据会把它当成"没选对象"直接 return。
    if (this.rows.length === 0) {
      return;
    }
    const reason: string = this.slotDisabledReason(slotId);
    if (reason !== '') {
      hilog.warn(0x0000, 'AmsSlots', '槽位%{public}s 被禁用：%{public}s', slotId, reason);
      AppLog.push(`[AmsSlots] 拒绝选择 槽位${slotId}：${reason}`);
      promptAction.showToast({ message: reason });
      return;
    }
    const cur: string = this.assign.get(this.activeId) ?? '';
    if (cur === slotId) {
      this.assign.delete(this.activeId);
      this.logSameSideShare(slotId, '取消');
    } else {
      this.logSameSideShare(slotId, '选择');
      this.assign.set(this.activeId, slotId);
    }
    const next: number = this.nextUnmapped();
    if (next >= 0) {
      this.activeId = next;
    }
    this.rebuild();
  }

  // 同类对象共用同一槽位：官方未给出明确禁止（同喷嘴的耗材本就共用一条料路），按「允许并记日志」处理。
  private logSameSideShare(slotId: string, action: string): void {
    let share: number = 0;
    this.assign.forEach((sid: string, objId: number): void => {
      if (sid === slotId && objId !== this.activeId) { share++; }
    });
    if (share > 0) {
      const line: string = `[AmsSlots] 同类共用槽位 动作=${action} 槽位=${slotId} 已有${share}个同侧对象占用（官方未明确禁止→允许）`;
      hilog.info(0x0000, 'AmsSlots', '%{public}s', line);
      AppLog.push(line);
    }
  }

  private nextUnmapped(): number {
    // 按渲染行找（含校准试块的虚拟对象行），不能只扫 modelState —— 那样校准场景永远找不到下一行
    for (const r of this.rows) {
      if ((this.assign.get(r.id) ?? '') === '') { return r.id; }
    }
    return -1;
  }

  private toggleOpt(kind: number): void {
    if (kind === 0) {
      this.optTimelapse = !this.optTimelapse;
      this.opts.timelapse = this.optTimelapse;
    } else if (kind === 1) {
      this.optBedLeveling = !this.optBedLeveling;
      this.opts.bedLeveling = this.optBedLeveling;
    } else {
      this.optFlowCali = !this.optFlowCali;
      this.opts.flowCali = this.optFlowCali;
    }
  }

  private canPrint(): boolean {
    return !this.hasAms() || this.unmappedCount() === 0;
  }

  // 机型名归一：小写、去 "bambu lab" 前缀、去掉尾部喷嘴口径（"0.4 nozzle" 里的 "0.4"）。
  // 目的：把切片预设名（如 "Bambu Lab H2C 0.4 nozzle"）与 SSDP 友好机型名（如 "P2S"）放到同一口径比较。
  private modelBase(name: string): string {
    let s: string = name.toLowerCase().trim();
    s = s.replace('bambu lab', '').trim();
    const ni: number = s.indexOf('nozzle');
    if (ni >= 0) {
      s = s.substring(0, ni).trim();
    }
    const parts: string[] = s.split(' ');
    while (parts.length > 1) {
      const last: string = parts[parts.length - 1];
      if (last.length > 0 && !Number.isNaN(Number(last))) {
        parts.pop();
      } else {
        break;
      }
    }
    return parts.join(' ').trim();
  }

  // 机型是否不一致：任一为空 → 不提示；互为子串（A1 ↔ A1 mini 等）→ 视为一致，不提示。
  private modelMismatch(): boolean {
    const a: string = this.modelBase(this.slicePrinter);
    const b: string = this.modelBase(this.connectedPrinter);
    if (a === '' || b === '') { return false; }
    if (a === b || a.includes(b) || b.includes(a)) { return false; }
    return true;
  }

  private mismatchText(): string {
    return `当前切片使用的是 ${this.slicePrinter}，连接的是 ${this.connectedPrinter}，` +
      '打印结果可能不正确，建议切换机型后重新切片';
  }

  // ---------------------------------------------------------------------------
  // 开关（自绘 pill + knob）已抽成独立组件 PrintOptPill（文件顶部）：
  // 那里用 @Prop 接收布尔，父组件重绘时一定会同步；@Builder 按值传参做不到。
  // ---------------------------------------------------------------------------

  @Builder
  colHead(title: string, count: string) {
    Row() {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(1.4)
        .fontColor(C_DIM)
      Text(count)
        .fontSize(11)
        .fontFamily('monospace')
        .fontColor(C_DIM)
        .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 14 })
  }

  @Builder
  panel() {
    Column() {
      // ---- 头部 ----
      Row() {
        Text('打印')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
        Blank()
        Row() {
          Column()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(C_ACCENT)
          Text(this.printerText)
            .fontSize(11.5)
            .fontFamily('monospace')
            .fontColor(C_DIM)
            .margin({ left: 8 })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(60)
      .padding({ left: 22, right: 22 })
      .border({ width: { bottom: 1 }, color: C_LINE })

      // ---- 机型不匹配：非阻塞黄色提示（不禁用按钮、不改用户已选参数）----
      if (this.modelMismatch()) {
        Row() {
          Column()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(C_WARN)
            .margin({ right: 8 })
          Text(this.mismatchText())
            .fontSize(12)
            .fontColor(C_WARN)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 22, right: 22, top: 10, bottom: 10 })
        .backgroundColor(C_WARN_BG)
        .border({ width: { bottom: 1 }, color: C_WARN_LINE })
        .alignItems(VerticalAlign.Center)
      }

      // ---- 主体两列 ----
      Row() {
        // 左列：对象颜色
        Column() {
          this.colHead('对象颜色', `${this.rows.length} 个对象`)
          ForEach(this.rows, (r: ObjRow, i: number) => {
            Row() {
              Column()
                .width(14)
                .height(14)
                .borderRadius(4)
                .backgroundColor(r.color)
                .border({ width: 1, color: '#24FFFFFF' })
              Column() {
                Text(r.name)
                  .fontSize(13.5)
                  .fontColor(C_TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(r.meta)
                  .fontSize(10.5)
                  .fontFamily('monospace')
                  .fontColor(C_DIM)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })
              // 喷嘴侧归属标签：仅触碰单侧专属区的对象显示（提示它只能选对应侧的槽位）
              if (r.side !== '') {
                Text(this.sideLabel(r.side))
                  .fontSize(10)
                  .fontFamily('monospace')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(999)
                  .fontColor(C_ACCENT)
                  .border({ width: 1, color: C_ACCENT_LINE })
                  .backgroundColor(C_ACCENT_BG)
                  .margin({ right: 6 })
              }
              Text(r.slot !== '' ? r.slot : '未指定')
                .fontSize(11)
                .fontFamily('monospace')
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .borderRadius(999)
                .fontColor(r.slot !== '' ? C_ACCENT : C_WARN)
                .border({
                  width: 1,
                  color: r.slot !== '' ? C_ACCENT_LINE : C_WARN_LINE
                })
                .backgroundColor(r.slot !== '' ? C_ACCENT_BG : C_WARN_BG)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 11, bottom: 11 })
            .borderRadius(10)
            .border({ width: 1, color: r.active ? C_LINE2 : Color.Transparent })
            .backgroundColor(r.active ? C_SURFACE2 : Color.Transparent)
            .margin({ bottom: 4 })
            .opacity(this.animIn ? 1 : 0)
            .translate({ x: this.animIn ? 0 : -6 })
            .animation({ duration: 340, curve: Curve.EaseOut, delay: 140 + i * 60 })
            .onClick(() => { this.pickObject(r.id); })
          }, (r: ObjRow) => r.key)

          Text(this.hasAms()
            ? '选择对象后，在右侧指定它使用的 AMS 槽位。'
            : '未检测到 AMS · 无需指定槽位，将直接使用当前装载耗材打印。')
            .fontSize(11.5)
            .fontColor(C_DIM)
            .width('100%')
            .margin({ top: 12 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 22, right: 22, top: 18, bottom: 18 })

        // 右列：AMS 槽位（无 AMS 时整列隐藏，改为一句提示）
        Column() {
          if (this.hasAms()) {
            this.colHead('AMS 槽位', `${this.slotRows.length} 个槽位 · ${this.unitRows.length} 组`)
            // AMS↔喷嘴配对缺失提示：有侧对象必须选「配对到同侧」的单元，未配对单元不可选（不瞎猜）
            if (this.hasUnpairedUnit()) {
              Text('部分 AMS 未配对喷嘴侧：有喷嘴归属的对象需先到「设置·双喷嘴」为各 AMS 指定左/右，否则该单元不可选。')
                .fontSize(11)
                .fontColor(C_WARN)
                .width('100%')
                .margin({ bottom: 10 })
            }
            // 按连接后读到的真实数据分组：每个 AMS 单元（ams.id）一组，外挂料盘单独一项。
            // 取不到外挂料盘数据时该组不存在（不造数据、不显示空项）。
            ForEach(this.unitRows, (u: AmsUnitRow) => {
              Column() {
                Row() {
                  Text(u.title)
                    .fontSize(11.5)
                    .fontWeight(FontWeight.Bold)
                    .letterSpacing(0.6)
                    .fontColor(u.unitId === EXTERNAL_AMS_ID ? C_WARN : C_DIM)
                  Blank()
                  Text(`${u.slots.length} 槽`)
                    .fontSize(10.5)
                    .fontFamily('monospace')
                    .fontColor(C_DIM)
                }
                .width('100%')
                .margin({ bottom: 6 })

                ForEach(u.slots, (s: SlotRow, i: number) => {
                  Row() {
                    Text(s.slotId)
                      .width(34)
                      .fontSize(11)
                      .fontFamily('monospace')
                      .fontColor(C_DIM)
                    Row() {
                      Column()
                        .width(14)
                        .height(14)
                        .borderRadius(4)
                        .backgroundColor(s.color)
                        .border({ width: 1, color: '#24FFFFFF' })
                        .opacity(s.disabled ? 0.4 : 1)
                      Text(s.material)
                        .fontSize(13.5)
                        .fontColor(s.disabled ? C_DIM : C_TEXT)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ left: 9 })
                    }
                    .layoutWeight(1)
                    .alignItems(VerticalAlign.Center)
                    if (s.disabled) {
                      Text(s.disabledTag)
                        .fontSize(10.5)
                        .fontFamily('monospace')
                        .fontColor(C_WARN)
                    } else {
                      Text(s.used > 0 ? `已用 ${s.used}` : '空闲')
                        .fontSize(10.5)
                        .fontFamily('monospace')
                        .fontColor(s.used > 0 ? C_ACCENT : C_DIM)
                    }
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 11, bottom: 11 })
                  .borderRadius(10)
                  .backgroundColor(s.picked ? C_ACCENT_BG : C_SURFACE2)
                  .border({ width: 1, color: s.disabled ? C_LINE : (s.picked ? C_ACCENT : C_LINE) })
                  .opacity(s.disabled ? 0.55 : (this.animIn ? 1 : 0))
                  .translate({ x: this.animIn ? 0 : 6 })
                  .animation({ duration: 340, curve: Curve.EaseOut, delay: 180 + i * 55 })
                  .onClick(() => { this.pickSlot(s.slotId); })
                }, (s: SlotRow) => s.key)
              }
              .width('100%')
              .margin({ bottom: 10 })
              .opacity(this.animIn ? 1 : 0)
              .translate({ x: this.animIn ? 0 : 6 })
              .animation({ duration: 340, curve: Curve.EaseOut, delay: 180 })
            }, (u: AmsUnitRow) => u.key)

            Text(FilamentGrouping.isDualNozzle()
              ? '未指定槽位的对象将以当前耗材打印。喷嘴归属按「耗材分组」计算；异侧喷嘴的对象不能共用同一槽位。'
              : '未指定槽位的对象将以当前耗材打印。单喷嘴机型：多色只需对应 AMS 槽位，不涉及左右喷嘴。')
              .fontSize(11.5)
              .fontColor(C_DIM)
              .width('100%')
              .margin({ top: 12 })
          } else {
            Column() {
              Text('未检测到 AMS')
                .fontSize(15)
                .fontColor(C_TEXT)
                .margin({ bottom: 6 })
              Text('直接使用当前装载耗材打印，无需指定槽位。')
                .fontSize(13)
                .fontColor(C_DIM)
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .opacity(this.animIn ? 1 : 0)
            .animation({ duration: 340, curve: Curve.EaseOut, delay: 180 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 22, right: 22, top: 18, bottom: 18 })
        .border({ width: { left: 1 }, color: C_LINE })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ---- 三个开关 ----
      // 注意：不要抽成 @Builder(on: boolean) —— 按值传参不会刷新（见 PrintOptPill 的注释）。
      Row() {
        Row() {
          PrintOptPill({ on: this.optTimelapse })
          Column() {
            Text('延时摄影').fontSize(13.5).fontColor(C_TEXT)
            Text('TIMELAPSE').fontSize(10.5).fontFamily('monospace').fontColor(C_DIM).margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(10)
        .border({ width: 1, color: this.optTimelapse ? C_ACCENT_LINE : Color.Transparent })
        .backgroundColor(this.optTimelapse ? C_ACCENT_BG : Color.Transparent)
        .animation({ duration: 180, curve: Curve.EaseOut })
        .onClick(() => { this.toggleOpt(0); })

        Row() {
          PrintOptPill({ on: this.optBedLeveling })
          Column() {
            Text('打印板调平').fontSize(13.5).fontColor(C_TEXT)
            Text('BED LEVELING').fontSize(10.5).fontFamily('monospace').fontColor(C_DIM).margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(10)
        .border({ width: 1, color: this.optBedLeveling ? C_ACCENT_LINE : Color.Transparent })
        .backgroundColor(this.optBedLeveling ? C_ACCENT_BG : Color.Transparent)
        .animation({ duration: 180, curve: Curve.EaseOut })
        .onClick(() => { this.toggleOpt(1); })

        Row() {
          PrintOptPill({ on: this.optFlowCali })
          Column() {
            Text('动态流量调整').fontSize(13.5).fontColor(C_TEXT)
            Text('FLOW DYNAMICS').fontSize(10.5).fontFamily('monospace').fontColor(C_DIM).margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(10)
        .border({ width: 1, color: this.optFlowCali ? C_ACCENT_LINE : Color.Transparent })
        .backgroundColor(this.optFlowCali ? C_ACCENT_BG : Color.Transparent)
        .animation({ duration: 180, curve: Curve.EaseOut })
        .onClick(() => { this.toggleOpt(2); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 14, bottom: 14 })
      .border({ width: { top: 1 }, color: C_LINE })
      .alignItems(VerticalAlign.Top)

      // ---- 底部 ----
      Row() {
        Text(this.hasAms()
          ? (this.unmappedCount() > 0 ? `${this.unmappedCount()} 个对象待映射` : '全部已映射 · 可以开始')
          : '未检测到 AMS · 可直接打印')
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(this.hasAms() && this.unmappedCount() > 0 ? C_WARN : C_DIM)
          .layoutWeight(1)
        // 上传（FTPS）：只把文件 PUT 到打印机 /cache/，**不发送任何打印命令**。
        Button('上传·不打印')
          .height(40)
          .padding({ left: 16, right: 16 })
          .fontSize(13)
          .fontColor(C_TEXT)
          .backgroundColor(Color.Transparent)
          .borderRadius(11)
          .border({ width: 1, color: C_LINE })
          .margin({ right: 12 })
          .onClick(() => {
            this.onUpload(this.opts, this.mappingPairs(),
              this.rows.length - this.unmappedCount(), this.unmappedCount());
          })
        Button('取消')
          .height(40)
          .padding({ left: 22, right: 22 })
          .fontSize(14)
          .fontColor(C_TEXT)
          .backgroundColor(Color.Transparent)
          .borderRadius(11)
          .border({ width: 1, color: C_LINE })
          .onClick(() => { this.onCancel(); })
        Button('开始打印')
          .height(40)
          .padding({ left: 22, right: 22 })
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.canPrint() ? '#052E1E' : '#5A5A68')
          .backgroundColor(this.canPrint() ? C_ACCENT : '#23232C')
          .borderRadius(11)
          .margin({ left: 12 })
          .enabled(this.canPrint())
          .onClick(() => {
            if (!this.canPrint()) { return; }
            this.onConfirm(this.opts, this.mappingPairs(),
              this.rows.length - this.unmappedCount(), this.unmappedCount());
          })
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 16, bottom: 20 })
      .border({ width: { top: 1 }, color: C_LINE })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：淡入 + 拦截全部手势（点空白 = 取消）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#B8060609')
        .opacity(this.animIn ? 1 : 0)
        .animation({ duration: 280, curve: Curve.EaseOut })
        .onClick(() => { this.onCancel(); })

      // 弹窗主体：向上浮现 + 轻微放大（原型 enter 动效）
      Scroll() {
        this.panel()
      }
      .width('92%')
      .constraintSize({ maxWidth: 880, maxHeight: '92%' })
      .borderRadius(16)
      .border({ width: 1, color: C_LINE2 })
      .backgroundColor(Theme.surface)
      .clip(true)
      .scrollBar(BarState.Off)
      .opacity(this.animIn ? 1 : 0)
      .translate({ y: this.animIn ? 0 : 14 })
      .scale({ x: this.animIn ? 1 : 0.985, y: this.animIn ? 1 : 0.985 })
      .animation({ duration: 420, curve: Curve.Friction, delay: 60 })
      // 弹窗本体不吃点击穿透（点它不应触发遮罩的"点空白取消"）
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
  }
}
