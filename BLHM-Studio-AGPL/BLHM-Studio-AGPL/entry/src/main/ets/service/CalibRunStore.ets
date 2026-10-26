// 校准结果的内存台账。
//
// 为什么需要：切成功后页面会跳到「预览 · 切片路径」，回来时 CalibrationPanel 会被重建，
// 组件内的 @State 全部归零 —— 用户就看不到刚切完的那一项，也进不了结果录入（挑块/填 K）。
// 把结果放进模块级单例，面板重建时再读回来。
//
// 【按耗材预设隔离】试块印记（流量%/PA K）只对「切片时用的那支耗材」成立：换预设后
// 材料/温度/挤出特性都变了，旧结果不能当成新预设的结果用，否则写回就是张冠李戴。
// 所以台账主键是 (校准项 id, 耗材预设名) 两元组，面板按当前选中的耗材取用。
//
// 只存本次运行的结果，不落盘：重启后重切一次即可（切片本身只要 0.1~0.6 秒）。
export class CalibRun {
  id: string = '';
  ok: boolean = false;
  layers: number = 0;
  grams: number = 0;
  est: string = '';
  msg: string = '';
  ms: number = 0;
  // 该模型板上的试块（"对象名|百分比;..."，空串=不是挑块类校准）
  blocks: string = '';
  // 切片时用的耗材预设名（空串=当时还没拿到预设名）
  filament: string = '';

  constructor(id: string, ok: boolean, layers: number, grams: number, est: string, msg: string, ms: number,
              blocks: string = '', filament: string = '') {
    this.id = id;
    this.ok = ok;
    this.layers = layers;
    this.grams = grams;
    this.est = est;
    this.msg = msg;
    this.ms = ms;
    this.blocks = blocks;
    this.filament = filament;
  }
}

export class CalibRunStore {
  private static list: CalibRun[] = [];

  static all(): CalibRun[] {
    return CalibRunStore.list;
  }

  // 某一支耗材名下的全部结果（面板按选中耗材过滤用）
  static allFor(filament: string): CalibRun[] {
    const out: CalibRun[] = [];
    for (let i = 0; i < CalibRunStore.list.length; i++) {
      if (CalibRunStore.list[i].filament === filament) {
        out.push(CalibRunStore.list[i]);
      }
    }
    return out;
  }

  // 台账里出现过的耗材预设名（去重、保持加入顺序；不含空名）
  static filaments(): string[] {
    const out: string[] = [];
    for (let i = 0; i < CalibRunStore.list.length; i++) {
      const f: string = CalibRunStore.list[i].filament;
      if (f === '') { continue; }
      if (out.indexOf(f) < 0) { out.push(f); }
    }
    return out;
  }

  // 按 (校准项 id, 耗材预设名) 取：同一项在不同耗材下各存一份
  static get(id: string, filament: string): CalibRun | undefined {
    for (let i = 0; i < CalibRunStore.list.length; i++) {
      const r: CalibRun = CalibRunStore.list[i];
      if (r.id === id && r.filament === filament) {
        return r;
      }
    }
    return undefined;
  }

  // 同一项同一耗材重切时覆盖旧结果（保留顺序：新结果排在最后）
  static put(r: CalibRun): void {
    const next: CalibRun[] = [];
    for (let i = 0; i < CalibRunStore.list.length; i++) {
      const old: CalibRun = CalibRunStore.list[i];
      if (!(old.id === r.id && old.filament === r.filament)) {
        next.push(old);
      }
    }
    next.push(r);
    CalibRunStore.list = next;
  }
}
