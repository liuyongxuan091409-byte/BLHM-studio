import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { SliceParam } from '../model/SliceModels';
import { ModelInstance, modelState } from '../model/ModelState';

// 耗材编辑覆盖值的落盘文件（与 panel_width.json / preset_last.json 同级 filesDir）
const FILAMENT_OVERRIDES_FILE: string = 'filament_overrides.json';
// 用户手改切片参数的落盘文件（让「改了参数重启就没了」这件事不再发生）
const PARAM_OVERRIDES_FILE: string = 'param_overrides.json';
// 上次使用的预设定值（PresetPersist 写的同一份）：用来判断落盘的参数覆盖属于哪个工艺预设
const PRESET_LAST_FILE: string = 'preset_last.json';
// 参数面板视图档位（0 简易 / 1 高级）的落盘文件
const PARAM_VIEW_FILE: string = 'param_view.json';

// 对象未设显示色时用的默认显示色。**这是耗材槽位键的一部分**：
// 切片侧（multicolorFragment）与分组侧（FilamentGrouping 的喷嘴分组）都用它，
// 保证「未设色」与「显式设为该色」的对象落到同一槽位（同一套口径）。
export const DISPLAY_COLOR_DEFAULT: string = '#F2F2F0';

// 切片参数存储：动态表单与切片流程之间共享当前参数值
export class SliceParamStore {
  private static params: SliceParam[] = [];

  // ---- 用户手改值：跨页面（组件销毁重建）与跨重启存活 ----
  // 【为什么必须放在模块级单例】DynamicParamsPanel 随 activeTab 切换被销毁重建（Index 里是
  //   `if (activeTab === 0) { DynamicParamsPanel() }`）：组件内的 @State allParams 与私有 Map
  //   会随实例一起消失。而内核里只保存「预设基准值」，重建时 loadSchema() 又用内核 config 快照
  //   覆盖每一项 —— 用户手改过的值因此被"重置"。把覆盖值提升到这里（随进程存活），重建面板时由
  //   loadSchema() 回放，即可修掉「切页回来参数重置」。
  //   【跨重启】再落一份 param_overrides.json（见下方 loadParamOverrides/saveParamOverrides）：
  //   覆盖值是「钉在当前工艺预设上的补丁」，所以文件里带预设名标签，换过预设就丢弃。
  //   key 用参数名（不是下标），对象覆盖用对象 id + 参数名，语义与面板一致。
  private static userOverrides: Map<string, number> = new Map<string, number>();

  // 落盘上下文（由 loadParamOverrides 填；未填时不落盘，例如启动极早期）
  private static persistDir: string = '';
  private static persistPreset: string = '';
  private static paramOverridesLoaded: boolean = false;

  static setParams(p: SliceParam[]): void {
    SliceParamStore.params = p;
  }

  static getParams(): SliceParam[] {
    return SliceParamStore.params;
  }

  // 记录一个全局用户覆盖值（切换预设时应先 clearUserOverrides，避免旧预设的覆盖串到新预设）
  static setUserOverride(key: string, value: number): void {
    SliceParamStore.userOverrides.set(key, value);
    SliceParamStore.saveParamOverrides();
  }

  // 移除一个全局覆盖值（用户把值改回预设默认值时调用，避免留下"看起来没改其实被钉死"的钉子）
  static removeUserOverride(key: string): void {
    SliceParamStore.userOverrides.delete(key);
    SliceParamStore.saveParamOverrides();
  }

  // 清空全局覆盖值（换预设 / 重试初始化时调用）。落盘同步写空表 ——
  // 这样「换预设后立刻重启」不会把上一个预设的覆盖捡回来。
  static clearUserOverrides(): void {
    SliceParamStore.userOverrides.clear();
    SliceParamStore.saveParamOverrides();
  }

  static userOverrideCount(): number {
    return SliceParamStore.userOverrides.size;
  }

  // ---- 全局参数覆盖的快照 / 还原（撤销栈用：让「改参数」也能撤销）----
  // 复制一份当前覆盖表（含副本，不能把内部 Map 交出去）
  static snapshotUserOverrides(): Map<string, number> {
    const out: Map<string, number> = new Map<string, number>();
    SliceParamStore.userOverrides.forEach((v: number, k: string): void => {
      out.set(k, v);
    });
    return out;
  }

  // 用快照整体替换覆盖表（并把结果落盘：撤销/重做后的状态同样要能跨重启）
  static restoreUserOverrides(m: Map<string, number>): void {
    SliceParamStore.userOverrides.clear();
    m.forEach((v: number, k: string): void => {
      SliceParamStore.userOverrides.set(k, v);
    });
    SliceParamStore.saveParamOverrides();
  }

  // 把用户覆盖值回放到参数表（重建面板时调用，必须在「预设基准」采集之后）。
  // 返回回放条数（供日志自证）。
  static applyUserOverrides(params: SliceParam[]): number {
    let n: number = 0;
    for (const p of params) {
      const v: number | undefined = SliceParamStore.userOverrides.get(p.key);
      if (v !== undefined) {
        p.value = v;
        n++;
      }
    }
    return n;
  }

  // 把「当前耗材预设这一桶」的覆盖值叠到参数表上（只认数值/布尔项；枚举/文本不碰）。
  // 用途：右侧参数面板与「打印板」旁的床温摘要必须与耗材编辑保持一致 —— 否则在耗材编辑里
  // 把温度改成 220，面板仍显示预设出厂值（用户反馈的正是这一条）。
  // 与 collectParamsJson 的下发顺序一致：耗材桶写在进程参数之后（同名键以耗材级为准）。
  static applyFilamentOverridesToParams(params: SliceParam[]): number {
    const bucket: Map<string, string[]> | undefined = SliceParamStore.activeBucket();
    if (bucket === undefined || bucket.size === 0) {
      return 0;
    }
    let n: number = 0;
    for (const p of params) {
      const v: string[] | undefined = bucket.get(p.key);
      if (v === undefined || v.length === 0) {
        continue;
      }
      // 枚举项：value 是下标、覆盖表里存的是内核名/文本，语义不同，绝不硬套。
      if (p.type === 4) {
        continue;
      }
      const num: number = Number.parseFloat(v[0]);
      if (!Number.isFinite(num)) {
        continue;
      }
      const nv: number = p.type === 3 ? (num !== 0 ? 1 : 0) : num;
      if (p.value !== nv) {
        p.value = nv;
      }
      n++;
    }
    return n;
  }

  // ---- 用户手改值的落盘 / 读回（修「改了参数一重启就回到预设」）----
  // 文件结构：{"preset": "<工艺预设名>", "values": {"<参数名>": <数值>}}
  // 为什么带 preset 标签：覆盖值是「钉在当前预设上的补丁」，只按 key 落盘的话，
  // 换过预设再重启会把上一个预设的覆盖串到新预设上（面板换预设时 clearUserOverrides 正是为此）。
  // 读盘只认「与 preset_last.json 里当前工艺预设同名」的那一份，不同名直接丢弃（文件保留）。
  //
  // 调用时机：EntryAbility.onCreate 里、loadContent 之前调用一次（保证参数面板首帧就是恢复后的值）。
  // 返回回放的条数（供日志自证）。
  static loadParamOverrides(filesDir: string): number {
    if (SliceParamStore.paramOverridesLoaded || filesDir.length === 0) {
      return 0;
    }
    SliceParamStore.paramOverridesLoaded = true;
    SliceParamStore.persistDir = filesDir;
    SliceParamStore.persistPreset = SliceParamStore.readLastProcessPreset(filesDir);
    const path: string = `${filesDir}/${PARAM_OVERRIDES_FILE}`;
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
      const txt: string = fs.readTextSync(path);
      if (txt.length === 0) {
        return 0;
      }
      const raw: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const tagObj: Object | undefined = raw['preset'];
      const tag: string = tagObj === undefined || tagObj === null ? '' : tagObj.toString();
      if (tag !== SliceParamStore.persistPreset) {
        return 0;
      }
      const values: Object | undefined = raw['values'];
      if (values === undefined || values === null) {
        return 0;
      }
      const vm: Record<string, Object> = values as Record<string, Object>;
      let n: number = 0;
      for (const k of Object.keys(vm)) {
        const v: Object | undefined = vm[k];
        if (v === undefined || v === null) {
          continue;
        }
        const num: number = Number.parseFloat(v.toString());
        if (Number.isFinite(num)) {
          SliceParamStore.userOverrides.set(k, num);
          n++;
        }
      }
      return n;
    } catch (e) {
      // 读失败：当作没有覆盖（不影响任何流程）
      return 0;
    }
  }

  // 落盘（覆盖写）。没有 filesDir 时静默跳过并返回 false。
  static saveParamOverrides(): boolean {
    if (SliceParamStore.persistDir.length === 0) {
      return false;
    }
    const path: string = `${SliceParamStore.persistDir}/${PARAM_OVERRIDES_FILE}`;
    try {
      let out: string = '{"preset":' + JSON.stringify(SliceParamStore.persistPreset) + ',"values":{';
      let first: boolean = true;
      SliceParamStore.userOverrides.forEach((v: number, k: string): void => {
        if (!first) {
          out += ',';
        }
        first = false;
        out += JSON.stringify(k) + ':' + `${v}`;
      });
      out += '}}';
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, out);
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // 从 preset_last.json 读「当前工艺预设名」（只读 process 字段；读不到返回空串 = 跳过标签校验）
  private static readLastProcessPreset(filesDir: string): string {
    try {
      const p: string = `${filesDir}/${PRESET_LAST_FILE}`;
      if (!fs.accessSync(p)) {
        return '';
      }
      const t: string = fs.readTextSync(p);
      if (t.length === 0) {
        return '';
      }
      const o: Record<string, Object> = JSON.parse(t) as Record<string, Object>;
      const proc: Object | undefined = o['process'];
      return proc === undefined || proc === null ? '' : proc.toString();
    } catch (e) {
      return '';
    }
  }

  // 对象级覆盖表：**真身在 ModelState**（对象状态的生命周期归它管：删除自动清理、复制自动跟随、
  // 快照/还原一起回滚）。这里只做门面转发，对外签名与行为对调用方完全不变 ——
  // DynamicParamsPanel 持有的仍是「同一张表的同一实例」，写入即跨页面存活。
  static getObjectOverrides(): Map<number, Map<string, number>> {
    return modelState.getObjectOverrides();
  }

  static setObjectOverride(id: number, key: string, value: number): void {
    modelState.setObjectOverride(id, key, value);
  }

  // 清除某个对象的全部参数覆盖（对象级「复位」用；对象本身保留）
  static clearObjectOverrides(id: number): void {
    modelState.clearObjectOverrides(id);
  }

  // ---- 参数面板视图档位（0 简易 / 1 高级）----
  // 为什么必须落盘：面板随 activeTab 切换被销毁重建，档位若只在内存，用户切一次页签就被重置回「简易」。
  // 简易 = 只显示 kSchema 里 mode=0 的常用项；高级 = 显示全部（含 mode=1 的进阶项）。
  private static viewModeCache: number = -1; // -1 = 尚未读盘

  static getParamViewMode(): number {
    if (SliceParamStore.viewModeCache >= 0) {
      return SliceParamStore.viewModeCache;
    }
    SliceParamStore.viewModeCache = 0;
    if (SliceParamStore.persistDir.length === 0) {
      return 0;
    }
    try {
      const p: string = `${SliceParamStore.persistDir}/${PARAM_VIEW_FILE}`;
      if (!fs.accessSync(p)) {
        return 0;
      }
      const t: string = fs.readTextSync(p);
      if (t.length === 0) {
        return 0;
      }
      const o: Record<string, Object> = JSON.parse(t) as Record<string, Object>;
      const m: Object | undefined = o['mode'];
      const n: number = m === undefined || m === null ? 0 : Number.parseInt(m.toString());
      SliceParamStore.viewModeCache = Number.isFinite(n) && n > 0 ? 1 : 0;
    } catch (e) {
      // 读失败按「简易」处理（不影响任何流程）
    }
    return SliceParamStore.viewModeCache;
  }

  static setParamViewMode(mode: number): void {
    SliceParamStore.viewModeCache = mode > 0 ? 1 : 0;
    if (SliceParamStore.persistDir.length === 0) {
      return;
    }
    try {
      const p: string = `${SliceParamStore.persistDir}/${PARAM_VIEW_FILE}`;
      const f: fs.File = fs.openSync(p,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, `{"mode":${SliceParamStore.viewModeCache}}`);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      // 写失败只影响「档位记忆」，不影响本次会话的显示（内存值已更新）
    }
  }

  // 收集全部参数为 key->value JSON（传给切片 NAPI）
  //
  // 必须按类型给出正确的 JSON 形态（内核 apply_params 是按 JSON 类型分派再转字符串的）：
  //   * 布尔 -> JSON true/false：内核 ConfigOptionBool::deserialize 只认 "1"/"0"，
  //     若一律用 toFixed(4) 发 "1.0000" 会被判为非法整项丢弃 —— 开关点了不生效就是这个原因；
  //   * 枚举 -> 数字下标（内核按 PrintConfigDef 的 enum_values 转成枚举名）；
  //   * 数值 -> 数字（用 Number 的原生最短表示，避免 toFixed(4) 把极小值截成 0）。
  static collectParamsJson(): string {
    let out: string = '{';
    const n: number = SliceParamStore.params.length;
    for (let i = 0; i < n; i++) {
      const p: SliceParam = SliceParamStore.params[i];
      if (i > 0) {
        out += ',';
      }
      out += '"' + p.key + '":' + SliceParamStore.encodeValue(p);
    }
    // 耗材编辑的覆盖值（**当前预设这一桶**）：向量按数组整段写，同名键在进程参数之后 → 以后者为准。
    const bucket: Map<string, string[]> | undefined = SliceParamStore.activeBucket();
    let first: boolean = (n === 0);
    if (bucket !== undefined) {
      bucket.forEach((vals: string[], key: string): void => {
        if (!first) {
          out += ',';
        }
        first = false;
        out += '"' + key + '":[';
        for (let j = 0; j < vals.length; j++) {
          if (j > 0) {
            out += ',';
          }
          // 数值/字符串都走 JSON 字符串元素：内核 deserialize 对两者都能解析
          out += JSON.stringify(vals[j]);
        }
        out += ']';
      });
    }
    out += '}';
    return out;
  }

  private static encodeValue(p: SliceParam): string {
    if (p.type === 3) {
      return p.value === 1 ? 'true' : 'false';
    }
    if (p.type === 4 || p.type === 1) {
      return `${Math.round(p.value)}`;
    }
    return `${p.value}`;
  }

  // ===========================================================================
  // 「对象颜色 → 耗材槽位」请求（多耗材切片）
  //
  // 把「同类型但不同颜色的对象」拆成多个耗材槽位，让内核按对象分挤出机，切出多耗材 gcode。
  //   · 槽位的唯一标识 = (预览显示色, 材料类型)：两个对象颜色相同且材料类型相同 → 同一个槽位；
  //   · 槽位顺序 = 对象在入参里的首次出现顺序（0 基），切片产物 ; filament 的槽位号与它同序；
  //   · N <= 1（所有对象同色同料）时返回空串，切片退回原单耗材行为。
  // 返回的片段直接并进 params_json（键名 __bbs_ 前缀，内核 apply_params 会静默跳过、由切片流程单独消费）。
  static multicolorFragment(insts: ModelInstance[]): string {
    const globalFil: string = AppStorage.get<string>('globalFilamentName') ?? '';
    const keys: string[] = [];
    const colours: string[] = [];
    const types: string[] = [];
    const objSlot: number[] = [];
    // 组合件分组：导入多色工程时，同一件的不同耗材 part 会被拆成多个显示对象，
    // 名字形如「<原名> · 耗材N」。切片时把同名的标成一组，内核据此合并回
    // 「一个对象 + 多个 part」再分层 —— 内核只对同一对象内的 part 裁剪重叠，
    // 不合并的话白底与红 logo 会在重叠区域各打一遍（预览/打印上的「红白交错」）。
    const asmBases: string[] = [];
    const asmGroup: number[] = [];
    for (const inst of insts) {
      const col: string = inst.displayColor !== '' ? inst.displayColor : DISPLAY_COLOR_DEFAULT;
      const fil: string = inst.filamentName !== '' ? inst.filamentName : globalFil;
      const typ: string = SliceParamStore.materialType(fil);
      const key: string = SliceParamStore.slotKey(col, typ);
      let idx: number = keys.indexOf(key);
      if (idx < 0) {
        idx = keys.length;
        keys.push(key);
        colours.push(col);
        types.push(typ);
      }
      objSlot.push(idx);
      // 「 · 耗材N」后缀判定（N 为纯数字才算；手动改过名字的对象不合并）
      let grp: number = -1;
      const SUFFIX: string = ' · 耗材';   // 5 个字符：空格 · 空格 耗 材
      const sep: number = inst.name.lastIndexOf(SUFFIX);
      if (sep > 0) {
        const tail: string = inst.name.substring(sep + SUFFIX.length);
        let digits: boolean = tail.length > 0;
        for (let c = 0; c < tail.length; c++) {
          const code: number = tail.charCodeAt(c);
          if (code < 48 || code > 57) { digits = false; break; }
        }
        if (digits) {
          const base: string = inst.name.substring(0, sep);
          grp = asmBases.indexOf(base);
          if (grp < 0) {
            grp = asmBases.length;
            asmBases.push(base);
          }
        }
      }
      asmGroup.push(grp);
    }
    {
      const nm: string[] = [];
      for (const inst of insts) { nm.push(inst.name); }
      hilog.info(0x0000, 'AsmGroup', '组合件分组=%{public}s 对象名=%{public}s',
        asmGroup.join(','), nm.join(' | '));
    }
    const n: number = keys.length;
    if (n <= 1) {
      return '';
    }
    let frag: string = ',"__bbs_filament_count":' + n + ',"__bbs_filaments":[';
    for (let i = 0; i < n; i++) {
      if (i > 0) { frag += ','; }
      frag += '{"colour":' + JSON.stringify(colours[i]) + ',"type":' + JSON.stringify(types[i]) + '}';
    }
    frag += '],"__bbs_object_filament":[' + objSlot.join(',') + ']';
    frag += ',"__bbs_assembly":[' + asmGroup.join(',') + ']';
    return frag;
  }

  // 耗材槽位键（同一套口径的唯一来源）：显示色 | 材料类型。
  // 切片侧（multicolorFragment）与分组侧（FilamentGrouping）都调用它，避免两处口径漂移。
  static slotKey(colour: string, type: string): string {
    return `${colour}|${type}`;
  }

  // 把 multicolorFragment 的片段并进 collectParamsJson 的 JSON 对象（去掉尾部 '}' 再补回）。
  static mergeExtra(paramsJson: string, extra: string): string {
    if (extra.length === 0) {
      return paramsJson;
    }
    const t: string = (paramsJson.length > 0 && paramsJson.charCodeAt(paramsJson.length - 1) === 125)
      ? paramsJson.substring(0, paramsJson.length - 1) : paramsJson;
    return t + extra + '}';
  }

  // 打印板名（中文标签）→ curr_bed_type 枚举下标；-1 = 参数表还没就绪/名字不匹配。
  // 用途：参数面板尚未初始化时，参数表里的 curr_bed_type 还是内核兜底值（例如 High Temp），
  // 直接下发会把 A1 mini 的「纹理 PEI」切成高温板 —— 板温 75/65 而不是 60/60，
  // 首层会被压塌/堆料。持久化的 PresetPersist.bedType 才是界面当前选择。
  static bedTypeIndexOf(name: string): number {
    if (name.length === 0) {
      return -1;
    }
    for (const p of SliceParamStore.params) {
      if (p.key !== 'curr_bed_type') {
        continue;
      }
      for (let i = 0; i < p.options.length; i++) {
        if (p.options[i] === name) {
          return i;
        }
      }
    }
    return -1;
  }

  // 用盘级床型覆盖 params JSON 里的 curr_bed_type（枚举下标）。
  // bedIndex < 0 = 不覆盖（该盘跟随全局）。只替换数字，不重排/不改其它键。
  static withBedType(paramsJson: string, bedIndex: number): string {
    if (bedIndex < 0) {
      return paramsJson;
    }
    const key: string = '"curr_bed_type":';
    const at: number = paramsJson.indexOf(key);
    if (at < 0) {
      const t: string = (paramsJson.length > 0 && paramsJson.charCodeAt(paramsJson.length - 1) === 125)
        ? paramsJson.substring(0, paramsJson.length - 1) : paramsJson;
      return t + ',' + key + bedIndex + '}';
    }
    let start: number = at + key.length;
    let end: number = start;
    while (end < paramsJson.length) {
      const c: number = paramsJson.charCodeAt(end);
      if (c < 48 || c > 57) {
        break;
      }
      end++;
    }
    if (end === start) {
      return paramsJson;
    }
    return paramsJson.substring(0, start) + bedIndex + paramsJson.substring(end);
  }

  // 材料类型：取 "Bambu PLA Basic @BBL X1C" -> "PLA"（与 FilamentGrouping.materialType 同一口径，
  // 此处内联一份避免 SliceParamStore 反向依赖分组服务造成循环 import）。
  private static materialType(name: string): string {
    let s: string = name;
    const at: number = s.indexOf('@');
    if (at >= 0) { s = s.substring(0, at); }
    s = s.replace('Bambu Lab', '').replace('Bambu', '').replace('Generic', '').trim();
    const sp: number = s.indexOf(' ');
    if (sp > 0) { s = s.substring(0, sp); }
    return s.toUpperCase().trim();
  }

  // ---- 耗材编辑（FilamentEditor）的覆盖值 ----
  // 【按耗材预设名分桶】覆盖值必须按「耗材预设名」隔离，否则换到别的耗材会张冠李戴（用户要求"不要和别的预设冲突"）。
  // 【落盘】用户要求"下次使用该预设就能用修改过的"，所以整张表写到 filesDir/filament_overrides.json。
  // 结构：{ "<耗材预设名>": { "<内核配置项名>": ["70"], ... }, ... }
  // 下发通道与进程参数同一条：collectParamsJson 把**当前预设这一桶**并进去，
  // 向量按数组整段写（内核 apply_params 的「数组 → 整段写入」分支）。
  private static filamentActivePreset: string = '';
  private static filamentByPreset: Map<string, Map<string, string[]>> =
    new Map<string, Map<string, string[]>>();
  private static filamentLoaded: boolean = false;
  // 耗材覆盖表的落盘目录（与上面的 persistDir 分开：那个是「参数覆盖」的上下文，
  // 复用它会让「先读耗材表」影响参数覆盖的落盘判断）
  private static filamentDir: string = '';

  static setFilamentPreset(name: string): void {
    if (name !== '') {
      if (name !== SliceParamStore.filamentActivePreset) {
        hilog.info(0x0000, 'SliceParam', '耗材覆盖桶 -> %{public}s', name);
      }
      SliceParamStore.filamentActivePreset = name;
    }
  }

  static filamentPresetName(): string {
    return SliceParamStore.filamentActivePreset;
  }

  private static activeBucket(): Map<string, string[]> | undefined {
    return SliceParamStore.filamentByPreset.get(SliceParamStore.filamentActivePreset);
  }

  // 读盘（幂等；读失败按"没有覆盖"处理，不阻断任何流程）
  static loadFilamentOverrides(filesDir: string): void {
    if (SliceParamStore.filamentLoaded || filesDir.length === 0) { return; }
    SliceParamStore.filamentLoaded = true;
    // 记住目录：后续 ensureFilamentOverrides 传空目录（例如面板里拿不到 HostContext）时
    // 仍能保证「覆盖表已读盘」，不会因为一个空串把整张表当成不存在。
    SliceParamStore.filamentDir = filesDir;
    const path: string = `${filesDir}/${FILAMENT_OVERRIDES_FILE}`;
    try {
      const exists: boolean = fs.accessSync(path);
      hilog.info(0x0000, 'SliceParam', '耗材覆盖读盘 dir=%{public}s 文件=%{public}s',
        filesDir, exists ? '有' : '无');
      if (!exists) { return; }
      const txt0: string = fs.readTextSync(path);
      // 容忍 UTF-8 BOM：带 BOM 的 JSON 会让 JSON.parse 抛 "Unexpected Text"，整张覆盖表
      // 静默失效（排查时表现为「改了温度但面板/切片全是出厂值」）。
      const txt: string = (txt0.length > 0 && txt0.charCodeAt(0) === 0xFEFF) ? txt0.substring(1) : txt0;
      if (txt.length === 0) { return; }
      const raw: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      hilog.info(0x0000, 'SliceParam', '耗材覆盖读盘 预设桶=%{public}d',
        Object.keys(raw).length);
      for (const name of Object.keys(raw)) {
        const one: Object = raw[name];
        if (one === null || one === undefined || Array.isArray(one)) { continue; }
        const oneMap: Record<string, Object> = one as Record<string, Object>;
        const m: Map<string, string[]> = new Map<string, string[]>();
        for (const k of Object.keys(oneMap)) {
          const v: Object = oneMap[k];
          const list: string[] = [];
          if (Array.isArray(v)) {
            const arr: Object[] = v as Object[];
            for (const e of arr) { list.push(e === null || e === undefined ? '' : e.toString()); }
          } else {
            list.push(v === null || v === undefined ? '' : v.toString());
          }
          m.set(k, list);
        }
        SliceParamStore.filamentByPreset.set(name, m);
      }
    } catch (e) {
      // 读失败：当作没有覆盖（不影响切片）
      hilog.error(0x0000, 'SliceParam', '耗材覆盖读盘失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 写盘（返回是否成功；调用方据此提示）
  static saveFilamentOverrides(filesDir: string): boolean {
    if (filesDir.length === 0) { return false; }
    const path: string = `${filesDir}/${FILAMENT_OVERRIDES_FILE}`;
    try {
      let out: string = '{';
      let firstN: boolean = true;
      SliceParamStore.filamentByPreset.forEach((m: Map<string, string[]>, name: string): void => {
        if (m.size === 0) { return; }
        if (!firstN) { out += ','; }
        firstN = false;
        out += JSON.stringify(name) + ':{';
        let firstK: boolean = true;
        m.forEach((vals: string[], key: string): void => {
          if (!firstK) { out += ','; }
          firstK = false;
          out += JSON.stringify(key) + ':[';
          for (let i = 0; i < vals.length; i++) {
            if (i > 0) { out += ','; }
            out += JSON.stringify(vals[i]);
          }
          out += ']';
        });
        out += '}';
      });
      out += '}';
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, out);
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  static getFilamentOverride(key: string): string[] | undefined {
    const m: Map<string, string[]> | undefined = SliceParamStore.activeBucket();
    return m === undefined ? undefined : m.get(key);
  }

  static setFilamentOverride(key: string, values: string[]): void {
    let m: Map<string, string[]> | undefined = SliceParamStore.activeBucket();
    if (m === undefined) {
      m = new Map<string, string[]>();
      SliceParamStore.filamentByPreset.set(SliceParamStore.filamentActivePreset, m);
    }
    m.set(key, values);
  }

  // ---- 按「耗材预设名」直接读写 ----
  // 与上面的 get/setFilamentOverride 的区别：那两个只作用于「当前激活桶」，而校准结果
  // 可能属于用户正在看、但此刻并未选中的那支耗材（换预设后回看/补写都属这种情形）。
  static getOverrideFor(preset: string, key: string): string[] | undefined {
    const m: Map<string, string[]> | undefined = SliceParamStore.filamentByPreset.get(preset);
    return m === undefined ? undefined : m.get(key);
  }

  static setOverrideFor(preset: string, key: string, values: string[]): void {
    let m: Map<string, string[]> | undefined = SliceParamStore.filamentByPreset.get(preset);
    if (m === undefined) {
      m = new Map<string, string[]>();
      SliceParamStore.filamentByPreset.set(preset, m);
    }
    m.set(key, values);
  }

  static hasBucket(preset: string): boolean {
    return SliceParamStore.filamentByPreset.has(preset);
  }

  static removeFilamentOverride(key: string): void {
    const m: Map<string, string[]> | undefined = SliceParamStore.activeBucket();
    if (m !== undefined) { m.delete(key); }
  }

  static filamentOverrideCount(): number {
    const m: Map<string, string[]> | undefined = SliceParamStore.activeBucket();
    return m === undefined ? 0 : m.size;
  }

  // 「重置」：清掉当前预设这一桶（内存 + 由调用方落盘）
  static clearFilamentOverrides(): void {
    SliceParamStore.filamentByPreset.delete(SliceParamStore.filamentActivePreset);
  }

  // 切片/导出前调用：保证覆盖表已读盘，且当前预设桶已指向内核真正选中的耗材
  static ensureFilamentOverrides(filesDir: string, presetName: string): void {
    // 目录为空时退回上次读盘/落盘用过的目录（面板的 loadSchema 在某些时机拿不到 HostContext）
    SliceParamStore.loadFilamentOverrides(
      filesDir.length > 0 ? filesDir : SliceParamStore.filamentDir);
    SliceParamStore.setFilamentPreset(presetName);
  }
}
