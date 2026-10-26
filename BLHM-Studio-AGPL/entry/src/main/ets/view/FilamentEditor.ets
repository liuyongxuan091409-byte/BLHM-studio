import { Theme } from '../common/Theme';
import { SlicerService } from '../service/SlicerService';
import { SliceParamStore } from '../service/SliceParamStore';

// =============================================================================
// 耗材编辑弹窗
//
// 【字段结构严格对齐拓竹】BambuStudio `src/slic3r/GUI/Tab.cpp` 的 `TabFilament::build()`
//   （参考本机 BambuStudio 源码：`src/slic3r/GUI/Tab.cpp:4701+`）。
//   拓竹的页面顺序：耗材丝 / 冷却模式 / 参数覆盖 / 高级 / 注释 / 多材料。
//   本弹窗实现与切片**直接相关**的三页：
//     · 耗材丝：基础信息 / 打印温度 / 喷嘴与流量（Tab.cpp:4708 / 4780 / 后续喷嘴段）
//     · 冷却模式：部件风扇 / 辅助风扇 / 排气扇（Tab.cpp:4877-4959）
//     · 高级：耗材丝起始/结束 G-code（Tab.cpp:4971+）
//   未实现：参数覆盖（Tab.cpp:4536，需要按对象/按耗材的覆盖表）、注释（纯文本备注）、
//   多材料（单挤出机流程用不到）—— 不做假页，避免"看起来有其实无效"。
//
// 【值从哪来、写到哪去】
//   · 读：内核 `slicer_filament_snapshot()`（新增）——**含向量型**（板温/喷嘴温度/风扇等
//     在内核里都是「按耗材分档的数组」）。旧的 `slicer_config_snapshot()` 刻意把向量压成
//     第一档，编辑器拿不到整条数组，这正是"改了不管用"的根因。
//   · 写：改动进 SliceParamStore 的耗材覆盖表 → 并进 collectParamsJson → 切片/导出时由内核
//     `apply_params` 的「数组 → 整段写入」分支落进 config。与动态表单同一条通道。
//
// 【为什么热床温度在这里而不是「工艺参数」面板】板温在拓竹里是**耗材级**设置
//   （每个耗材一份，见 Tab.cpp:4784-4807 的五组板温），所以正主就是本弹窗。
// =============================================================================

// 字段控件类型：0=数值 1=开关 2=文本
const FK_NUM: number = 0;
const FK_BOOL: number = 1;
const FK_TEXT: number = 2;

class FField {
  key: string = '';
  label: string = '';
  unit: string = '';
  kind: number = FK_NUM;
  step: number = 1;
  hint: string = '';

  constructor(key: string, label: string, unit: string, kind: number = FK_NUM,
    step: number = 1, hint: string = '') {
    this.key = key;
    this.label = label;
    this.unit = unit;
    this.kind = kind;
    this.step = step;
    this.hint = hint;
  }
}

class FGroup {
  title: string = '';
  fields: FField[] = [];

  constructor(title: string, fields: FField[]) {
    this.title = title;
    this.fields = fields;
  }
}

// 页签 = 拓竹的 page
class FPage {
  title: string = '';
  groups: FGroup[] = [];

  constructor(title: string, groups: FGroup[]) {
    this.title = title;
    this.groups = groups;
  }
}

// 内核返回的取值容器：key -> 值（向量统一成字符串数组；标量也存成长度 1 的数组）
class FSnapshot {
  ok: boolean = false;
  name: string = '';
  printer: string = '';
  message: string = '';
  // 向量保持原长度；标量固定长度 1
  vals: Map<string, string[]> = new Map<string, string[]>();
  fromKernel: Set<string> = new Set<string>();

  static parse(json: string): FSnapshot {
    const out: FSnapshot = new FSnapshot();
    let raw: Record<string, Object>;
    try {
      raw = JSON.parse(json) as Record<string, Object>;
    } catch (e) {
      out.message = '快照解析失败';
      return out;
    }
    out.ok = raw['ok'] === true;
    out.name = typeof raw['name'] === 'string' ? raw['name'] as string : '';
    out.printer = typeof raw['printer'] === 'string' ? raw['printer'] as string : '';
    out.message = typeof raw['message'] === 'string' ? raw['message'] as string : '';
    const values: Object | undefined = raw['values'];
    if (values === undefined || values === null) {
      return out;
    }
    const vmap: Record<string, Object> = values as Record<string, Object>;
    for (const k of Object.keys(vmap)) {
      const v: Object = vmap[k];
      const list: string[] = [];
      if (Array.isArray(v)) {
        const arr: Object[] = v as Object[];
        for (const e of arr) {
          list.push(typeof e === 'string' ? e as string : (e === null ? '' : e.toString()));
        }
      } else if (typeof v === 'boolean') {
        list.push((v as boolean) ? '1' : '0');
      } else if (typeof v === 'string') {
        list.push(v as string);
      } else {
        list.push(`${v}`);
      }
      out.vals.set(k, list);
      out.fromKernel.add(k);
    }
    return out;
  }
}

// 拓竹 TabFilament 的「耗材丝 → 基础信息 / 打印温度 / 喷嘴与流量」段
function buildFilamentPage(): FPage {
  return new FPage('耗材丝', [
    new FGroup('基础信息', [
      new FField('filament_type', '类型', '', FK_TEXT),
      new FField('filament_vendor', '供应商', '', FK_TEXT),
      new FField('filament_diameter', '直径', 'mm', FK_NUM, 0.01),
      new FField('filament_density', '密度', 'g/cm³', FK_NUM, 0.01),
      new FField('filament_flow_ratio', '流量比例', '', FK_NUM, 0.01),
      new FField('filament_cost', '价格', '', FK_NUM, 1),
      new FField('filament_shrink', '收缩', '%', FK_NUM, 1),
      new FField('temperature_vitrification', '软化温度', '℃', FK_NUM, 5),
      new FField('filament_velocity_adaptation_factor', '速度适应系数', '', FK_NUM, 0.01),
      new FField('filament_soluble', '可溶解', '', FK_BOOL),
      new FField('filament_is_support', '支撑材料', '', FK_BOOL),
      new FField('filament_metal_stickiness', '对金属磁性', '', FK_BOOL),
    ]),
    new FGroup('打印温度', [
      new FField('nozzle_temperature_initial_layer', '喷嘴温度（首层）', '℃', FK_NUM, 5),
      new FField('nozzle_temperature', '喷嘴温度（其他层）', '℃', FK_NUM, 5),
      new FField('nozzle_temperature_range_low', '推荐喷嘴温度下限', '℃', FK_NUM, 5),
      new FField('nozzle_temperature_range_high', '推荐喷嘴温度上限', '℃', FK_NUM, 5),
      new FField('hot_plate_temp_initial_layer', '光面PEI/高温打印板（首层）', '℃', FK_NUM, 5),
      new FField('hot_plate_temp', '光面PEI/高温打印板（其他层）', '℃', FK_NUM, 5),
      new FField('cool_plate_temp_initial_layer', '低温打印板（首层）', '℃', FK_NUM, 5),
      new FField('cool_plate_temp', '低温打印板（其他层）', '℃', FK_NUM, 5),
      new FField('eng_plate_temp_initial_layer', '工程材料打印板（首层）', '℃', FK_NUM, 5),
      new FField('eng_plate_temp', '工程材料打印板（其他层）', '℃', FK_NUM, 5),
      new FField('textured_plate_temp_initial_layer', '纹理PEI打印板（首层）', '℃', FK_NUM, 5),
      new FField('textured_plate_temp', '纹理PEI打印板（其他层）', '℃', FK_NUM, 5),
      new FField('supertack_plate_temp_initial_layer', 'Cool Plate SuperTack（首层）', '℃', FK_NUM, 5),
      new FField('supertack_plate_temp', 'Cool Plate SuperTack（其他层）', '℃', FK_NUM, 5),
      new FField('chamber_temperatures', '腔体温度', '℃', FK_NUM, 5),
    ]),
    new FGroup('喷嘴与流量', [
      // 键名必须用内核真实键：BBS 里是 filament_max_volumetric_speed（不是 max_volumetric_speed）。
      // 之前写错导致切片审计报「内核无此项」，该字段的修改也一直落不进配置。
      new FField('filament_max_volumetric_speed', '最大体积速度', 'mm³/s', FK_NUM, 1),
      new FField('enable_pressure_advance', '启用压力提前', '', FK_BOOL),
      new FField('pressure_advance', '压力提前值', '', FK_NUM, 0.001),
    ]),
  ]);
}

// 拓竹 TabFilament 的「冷却模式」页（Tab.cpp:4877-4959）
function buildCoolingPage(): FPage {
  return new FPage('冷却模式', [
    new FGroup('部件风扇', [
      new FField('close_fan_the_first_x_layers', '首层关闭风扇的层数', '层', FK_NUM, 1),
      new FField('first_x_layer_part_fan_speed', '首层风扇速度', '%', FK_NUM, 5),
      new FField('full_fan_speed_layer', '线性升到满速的层', '层', FK_NUM, 1),
      new FField('fan_min_speed', '最小风扇速度阈值', '%', FK_NUM, 5),
      new FField('fan_cooling_layer_time', '最小层时间阈值', 's', FK_NUM, 0.5),
      new FField('fan_max_speed', '最大风扇速度阈值', '%', FK_NUM, 5),
      new FField('slow_down_layer_time', '最大层时间阈值', 's', FK_NUM, 0.5),
      new FField('reduce_fan_stop_start_freq', '降低风扇启停频率', '', FK_BOOL),
      new FField('slow_down_for_layer_cooling', '为更好冷却而降速', '', FK_BOOL),
      new FField('cooling_perimeter_transition_distance', '降速过渡距离', 'mm', FK_NUM, 1),
      new FField('slow_down_min_speed', '降速下限', 'mm/s', FK_NUM, 1),
      new FField('enable_overhang_bridge_fan', '悬垂/桥接强制冷却', '', FK_BOOL),
      new FField('overhang_fan_speed', '悬垂风扇速度', '%', FK_NUM, 5),
      new FField('pre_start_fan_time', '提前开启风扇时间', 's', FK_NUM, 1),
      new FField('ironing_fan_speed', '熨烫风扇速度', '%', FK_NUM, 5),
    ]),
    new FGroup('辅助风扇', [
      new FField('close_additional_fan_first_x_layers', '首层关闭辅助风扇的层数', '层', FK_NUM, 1),
      new FField('first_x_layer_fan_speed', '首层辅助风扇速度', '%', FK_NUM, 5),
      new FField('additional_fan_full_speed_layer', '辅助风扇升到满速的层', '层', FK_NUM, 1),
      new FField('additional_cooling_fan_speed', '辅助风扇目标速度', '%', FK_NUM, 5),
    ]),
    new FGroup('排气扇', [
      new FField('activate_air_filtration', '启用空气过滤', '', FK_BOOL),
      new FField('during_print_exhaust_fan_speed', '打印期间排气扇速度', '%', FK_NUM, 5),
      new FField('complete_print_exhaust_fan_speed', '打印完成排气扇速度', '%', FK_NUM, 5),
    ]),
  ]);
}

// 拓竹「高级」页的耗材丝 G-code 段（Tab.cpp:4971+）
function buildAdvancedPage(): FPage {
  return new FPage('高级', [
    new FGroup('耗材丝 G-code', [
      new FField('filament_start_gcode', '耗材丝起始 G-code', '', FK_TEXT),
      new FField('filament_end_gcode', '耗材丝结束 G-code', '', FK_TEXT),
    ]),
  ]);
}

@Component
export struct FilamentEditor {
  onClose: () => void = () => {};

  private pages: FPage[] = [buildFilamentPage(), buildCoolingPage(), buildAdvancedPage()];

  @State private pageIndex: number = 0;
  @State private snapName: string = '';
  @State private snapPrinter: string = '';
  @State private loadNote: string = '';
  // 已改项数（只用于标题右侧的计数显示）。
  // 注意：**不要**用"每次改值都自增的代次"去做 ForEach 的 key —— 那会让每敲一个字符就把整页
  // 行全部销毁重建（表现为极卡 + 光标只能输入第一个字符 + TextInput 失焦）。
  // 这里只在"改了第几项"这个数量真的变化时才更新一次，打字过程中不再重绘。
  @State private editedCountNum: number = 0;
  @State private vals: Map<string, string[]> = new Map<string, string[]>();
  @State private note: string = '';
  // 内核原始值（未叠加覆盖）：判定"本项被改过 → 标橙"的基准。
  // 标橙状态不额外存盘 —— 它由"覆盖表里有没有这一项"直接推出，所以关弹窗/重启后依然成立。
  private base: Map<string, string[]> = new Map<string, string[]>();
  private fromKernel: Set<string> = new Set<string>();
  // 用户真正点进过（获得焦点）的输入框 key。
  // 为什么必须有它：TextInput 在**创建/重绘**时也会触发 onChange，且 `InputType.Number` 可能把
  // 值规范化成另一种字符串（实测 `1.26` 变成 `126`）—— 单靠"值没变就不写"拦不住，
  // 会把 filament_density 这类项写成 126 这种错值。只认"用户碰过"的字段。
  private touched: Set<string> = new Set<string>();

  private filesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx ? ctx.filesDir : '';
  }

  // 取初值：内核耗材快照（含向量）。快照缺的键退回进程参数快照（标量）→ 再退硬编码提示。
  private loadValues(): void {
    let snap: FSnapshot = new FSnapshot();
    try {
      snap = FSnapshot.parse(SlicerService.filamentSnapshot());
    } catch (e) {
      snap.message = e instanceof Error ? e.message : '调用异常';
    }
    // 基准 = 内核原始值（含向量型），「标橙」判定要用它
    this.base = new Map<string, string[]>();
    snap.vals.forEach((v: string[], k: string): void => { this.base.set(k, v.slice()); });
    this.fromKernel = snap.fromKernel;
    this.snapName = snap.name !== '' ? snap.name : '（未取到耗材预设名）';
    this.snapPrinter = snap.printer;
    this.loadNote = snap.ok ? '' : (snap.message !== '' ? snap.message : '内核未返回耗材快照');
    // 退回进程参数快照（它是合成后的完整配置，可补上耗材预设里没显式写的标量项）
    if (this.loadNote === '') {
      try {
        const cfgRaw: Record<string, Object> =
          JSON.parse(SlicerService.configSnapshot()) as Record<string, Object>;
        for (const k of Object.keys(cfgRaw)) {
          if (this.vals.has(k)) { continue; }
          const v: Object = cfgRaw[k];
          const list: string[] = [];
          if (Array.isArray(v)) {
            const arr: Object[] = v as Object[];
            for (const e of arr) { list.push(e === null ? '' : e.toString()); }
          } else if (typeof v === 'boolean') {
            list.push((v as boolean) ? '1' : '0');
          } else if (typeof v === 'string') {
            list.push(v as string);
          } else {
            list.push(`${v}`);
          }
          this.base.set(k, list);
        }
      } catch (e) {
        // 兜底失败不影响主流程（编辑器对缺失项显示 `--`）
      }
    }
    // 覆盖表按「本份耗材预设名」分桶，并读盘（幂等）——
    // 分桶保证不与别的耗材预设冲突；读盘保证关软件再打开依然生效。
    SliceParamStore.setFilamentPreset(snap.name);
    SliceParamStore.loadFilamentOverrides(this.filesDir());
    // 编辑用值 = 基准的副本；再把已保存的覆盖值叠上去（叠加结果同时决定"标橙"）
    this.vals = new Map<string, string[]>();
    this.base.forEach((v: string[], k: string): void => { this.vals.set(k, v.slice()); });
    // 叠加用户已改过的覆盖值（关弹窗/重启后依然生效）
    for (const p of this.pages) {
      for (const g of p.groups) {
        for (const f of g.fields) {
          const ov: string[] | undefined = SliceParamStore.getFilamentOverride(f.key);
          if (ov !== undefined) { this.vals.set(f.key, ov); }
        }
      }
    }
    this.editedCountNum = SliceParamStore.filamentOverrideCount();
  }

  aboutToAppear(): void {
    this.loadValues();
  }

  private raw(f: FField): string[] {
    return this.vals.get(f.key) ?? [];
  }

  private shown(f: FField): string {
    const v: string[] = this.raw(f);
    if (v.length === 0) { return '--'; }
    if (f.kind === FK_BOOL) { return v[0] === '1' ? '开' : '关'; }
    return v[0];
  }

  private isOn(f: FField): boolean {
    const v: string[] = this.raw(f);
    return v.length > 0 && v[0] === '1';
  }

  // 写入：**只改弹窗本地编辑态**。
  // 关键语义（用户要求）：点「关闭」= 丢弃未保存的改动；只有点「保存」才写进
  // SliceParamStore 并落盘。所以这里一个字节都不进 store，也不影响切片。
  // 保持原数组长度（向量型按耗材分档，长度不能变），把每个元素设为同一个值。
  private write(f: FField, value: string): void {
    const old: string[] = this.raw(f);
    if (old.length > 0 && old[0] === value) { return; }
    const len: number = old.length > 0 ? old.length : 1;
    const list: string[] = [];
    for (let i = 0; i < len; i++) { list.push(value); }
    this.vals.set(f.key, list);
    this.recountModified();
  }

  // 统计"被改过的项"（当前值 ≠ 内核基准）：标题计数 = 未保存的改动数，
  // 也是"点保存会写几项"的预告。
  private recountModified(): void {
    let n: number = 0;
    for (const p of this.pages) {
      for (const g of p.groups) {
        for (const f of g.fields) {
          if (this.isModified(f)) { n++; }
        }
      }
    }
    if (n !== this.editedCountNum) { this.editedCountNum = n; }
  }

  // 数值输入：只有解析成有限数才写入（中途的空串/非法串不写，避免把空值下发内核）。
  // 写入的是「用户原样输入的文本」，这样小数（如 0.9）在输入过程中不会被吃掉。
  private writeNum(f: FField, text: string): void {
    const t: string = text.trim();
    if (t === '') { return; }
    if (!Number.isFinite(Number(t))) { return; }
    this.write(f, t);
  }

  private editedCount(): number {
    return this.editedCountNum;
  }

  // 本项是否被改过（当前值 ≠ 内核基准）→ 标橙。
  // 标橙状态不单独存盘：它由「值 vs 基准」直接推出，而值来自已落盘的覆盖表，
  // 所以关弹窗 / 关软件再打开都保持被标记。
  private isModified(f: FField): boolean {
    const b: string[] = this.base.get(f.key) ?? [];
    const v: string[] = this.raw(f);
    if (b.length === 0 && v.length === 0) { return false; }
    if (b.length !== v.length) { return true; }
    for (let i = 0; i < b.length; i++) {
      if (b[i] !== v[i]) { return true; }
    }
    return false;
  }

  // 「保存」：把**被改过的项**写进覆盖表并整表落盘（按耗材预设名分桶 → 不与其他预设冲突）。
  // 只有这一步会进 store：所以"关闭"能真正丢弃改动。
  private saveAll(): void {
    let saved: number = 0;
    for (const p of this.pages) {
      for (const g of p.groups) {
        for (const f of g.fields) {
          if (this.isModified(f)) {
            const v: string[] = this.vals.get(f.key) ?? [];
            if (v.length > 0) {
              SliceParamStore.setFilamentOverride(f.key, v.slice());
              saved++;
            }
          } else {
            // 改回等于基准 → 不留下"看起来没改其实被钉死"的钉子
            SliceParamStore.removeFilamentOverride(f.key);
          }
        }
      }
    }
    const ok: boolean = SliceParamStore.saveFilamentOverrides(this.filesDir());
    this.note = ok
      ? `已保存：${this.snapName} · ${saved} 项（下次用该预设自动生效）`
      : '保存失败：无法写入应用目录';
    this.notifyEdited();
  }

  // 通知右侧参数面板重新对齐（面板监听 AppStorage 的序号；否则它仍亮出厂预设值）
  private notifyEdited(): void {
    const cur: number = AppStorage.get<number>('filamentEditSeq') ?? 0;
    AppStorage.setOrCreate<number>('filamentEditSeq', cur + 1);
  }

  // 「重置」：清掉本预设的覆盖值并落盘；界面回到内核基准值
  private resetAll(): void {
    SliceParamStore.clearFilamentOverrides();
    this.vals = new Map<string, string[]>();
    this.base.forEach((v: string[], k: string): void => { this.vals.set(k, v.slice()); });
    this.editedCountNum = 0;
    const ok: boolean = SliceParamStore.saveFilamentOverrides(this.filesDir());
    this.note = ok ? `已重置为预设默认：${this.snapName}` : '已重置，但落盘失败';
    this.notifyEdited();
  }

  build() {
    Column() {
      // ── 标题栏 ────────────────────────────────────────────────
      Row() {
        Text('耗材设置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Text(this.snapName)
          .fontSize(12)
          .fontColor(Theme.accentSoft)
          .margin({ left: 12 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.editedCount() > 0 ? `已改 ${this.editedCount()} 项` : '')
          .fontSize(11)
          .fontColor(Theme.accent)
          .margin({ right: 12 })
        Text('✕')
          .fontSize(15)
          .fontColor(Theme.textSecondary)
          .padding({ left: 8, right: 4, top: 2, bottom: 2 })
          .onClick(() => { this.onClose(); })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 10 })

      // ── 页签（对齐拓竹 TabFilament 的 page 顺序）─────────────
      Row() {
        ForEach(this.pages, (p: FPage, index: number) => {
          Text(p.title)
            .fontSize(13)
            .fontWeight(this.pageIndex === index ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.pageIndex === index ? Theme.accent : Theme.textSecondary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .border({ width: { bottom: this.pageIndex === index ? 2 : 0 }, color: Theme.accent })
            .onClick(() => { this.pageIndex = index; })
        }, (p: FPage, index: number) => `${p.title}-${index}`)
        Blank()
      }
      .width('100%')
      .padding({ left: 16 })
      .border({ width: { bottom: 1 }, color: Theme.border })

      if (this.loadNote !== '') {
        Text(this.loadNote)
          .fontSize(12)
          .fontColor('#FF7A1A')
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
      }

      // ── 内容 ──────────────────────────────────────────────────
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.pages[this.pageIndex].groups, (g: FGroup) => {
            Text(g.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary)
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 4 })
            ForEach(g.fields, (f: FField) => {
              this.row(f)
            }, (f: FField) => `${this.pageIndex}-${f.key}`)
          }, (g: FGroup, index: number) => `${this.pageIndex}-${g.title}-${index}`)
        }
        .width('100%')
        .padding({ top: 4, bottom: 20 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      // ── 底栏：保存 / 重置 / 关闭 ───────────────────────────────
      Column({ space: 8 }) {
        Row() {
          Text(this.note !== ''
            ? this.note
            : (this.snapPrinter !== '' ? `机型 ${this.snapPrinter}` : ''))
            .fontSize(11)
            .fontColor(this.note !== '' ? Theme.accent : Theme.textSecondary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row({ space: 8 }) {
          Button('重置')
            .fontSize(13)
            .fontColor('#FF7A1A')
            .backgroundColor(Theme.surfaceElevated)
            .borderRadius(8)
            .height(34)
            .onClick(() => { this.resetAll(); })
          Blank()
          Button('关闭')
            .fontSize(13)
            .fontColor(Theme.textPrimary)
            .backgroundColor(Theme.surfaceElevated)
            .borderRadius(8)
            .height(34)
            .onClick(() => { this.onClose(); })
          Button('保存')
            .fontSize(13)
            .fontColor(Theme.bg)
            .backgroundColor(Theme.accent)
            .borderRadius(8)
            .height(34)
            .onClick(() => { this.saveAll(); })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      .border({ width: { top: 1 }, color: Theme.border })
    }
    // 宽度：百分比 + 上限，而不是写死 980 —— 手机上（手机被强制横屏，窗口宽约 780vp）写死
    // 980 会宽出屏幕，卡片左右边缘被裁掉。96% 相对本组件的父容器解析（Index.ets 里是铺满的
    // Stack，即窗口尺寸），横竖屏/窗口缩放都自适应；桌面宽屏仍由 maxWidth=980 保持原观感。
    // 高度仍用确定值（不是自适应）：自适应高度下内层 Scroll 的命中区域会退化成 0 高度 ——
    // 表现为"能滚不能点、连关闭都点不动"。PrintDialog 用的是确定尺寸卡片，真机上可点，这里与它对齐。
    .width('96%')
    .constraintSize({ maxWidth: 980 })
    .height('88%')
    .backgroundColor(Theme.surface)
    .borderRadius(14)
    .border({ width: 1, color: Theme.border })
    .clip(true)
  }

  @Builder
  row(f: FField) {
    Row() {
      Column() {
        Text(f.label)
          .fontSize(13)
          // 被改过的项标橙（与「工艺参数」面板同一套橙色语义）
          .fontColor(this.isModified(f) ? '#FF7A1A' : Theme.textPrimary)
          .width('100%')
        if (f.key !== '' && !this.fromKernel.has(f.key) && this.raw(f).length === 0) {
          Text('该预设未包含此项')
            .fontSize(10)
            .fontColor(Theme.textSecondary)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Blank()

      if (this.raw(f).length === 0) {
        Text('--')
          .fontSize(13)
          .fontColor(Theme.textSecondary)
          .width(120)
          .textAlign(TextAlign.End)
      } else if (f.kind === FK_BOOL) {
        Toggle({ type: ToggleType.Switch, isOn: this.isOn(f) })
          .selectedColor(this.isModified(f) ? '#FF7A1A' : Theme.accent)
          .onChange((on: boolean) => { this.write(f, on ? '1' : '0'); })
      } else {
        // 数值 / 文本一律用输入框（不用加/减）：直接键入，改完即写入覆盖表
        Row({ space: 6 }) {
          TextInput({ text: this.shown(f) === '--' ? '' : this.shown(f) })
            // 数值项用「可带小数点」的键盘/过滤（NumberDecimal）：密度 1.26、流量比 0.98 这类
            // 必须能打小数点；纯 InputType.Number 会把小数点过滤掉。
            .type(f.kind === FK_NUM ? InputType.NUMBER_DECIMAL : InputType.Normal)
            .fontSize(12)
            .fontColor(this.isModified(f) ? '#FF7A1A' : Theme.accentSoft)
            .backgroundColor(Theme.surfaceElevated)
            .width(200)
            .height(34)
            .onFocus(() => { this.touched.add(f.key); })
            .onChange((v: string) => {
              // 只认"用户碰过这个框"之后的输入：初始化/重绘触发的 onChange 一律忽略
              // （否则会把整页字段误标为已改，并把规范化后的错值写进覆盖表）
              if (!this.touched.has(f.key)) { return; }
              if (f.kind === FK_NUM) {
                this.writeNum(f, v);
              } else {
                this.write(f, v);
              }
            })
          Text(f.unit)
            .fontSize(11)
            .fontColor(Theme.textSecondary)
            .width(56)
        }
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: '#1F1F27' })
  }
}
