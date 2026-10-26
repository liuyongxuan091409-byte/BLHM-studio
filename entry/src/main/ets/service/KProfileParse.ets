// 设备侧 K 值表解析（**只读**）。
//
// 为什么写成"宽进"解析：拓竹的 extrusion_cali_get 应答在社区实现里没有原文样例
// （真机只抓到过 extrusion_cali_set 的 {"result":"fail","reason":"invalid tray_id"} 一例，
// 而且那次写入其实生效了）。外层结构（print.cali / 顶层 cali 数组 / 直接对象）都不确定，
// 所以这里递归扫 JSON：凡是含 k_value 的对象就当一条记录，字段缺失一律留空或 -1，
// 任何解析异常都吞掉返回空表——宁可少识别，也不能因为结构猜错把校准页搞崩。
//
// 解析放在 ArkTS 侧而不是 C++ 侧，是为了能用固定夹具做单测（selfTest()），
// 没有打印机也能验证解析器不崩、能认出真实 ack 的形状。

const DEPTH_MAX: number = 6;

export class KProfileEntry {
  nozzleDiameter: string = '';
  name: string = '';
  kValue: string = '';
  filamentId: string = '';
  settingId: string = '';
  amsId: number = -1;
  trayId: number = -1;
  slotId: number = -1;

  key(): string {
    return `${this.nozzleDiameter}|${this.settingId}|${this.name}|${this.kValue}`;
  }
}

export class KProfileTable {
  entries: KProfileEntry[] = [];
  // 应答里出现过的喷嘴直径（一次应答通常只覆盖一个直径，多喷嘴机型要合并多份）
  nozzles: string[] = [];
  // 命中的"校准相关报文"条数（>0 而 entries=0 说明收到了应答但结构没认出来）
  reports: number = 0;
}

function textOf(v: Object | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number') {
    return `${v as number}`;
  }
  if (typeof v === 'boolean') {
    return (v as boolean) ? 'true' : 'false';
  }
  return '';
}

function numOf(v: Object | undefined): number {
  if (v === undefined || v === null) {
    return -1;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const n: number = parseInt(v as string, 10);
    return isNaN(n) ? -1 : n;
  }
  return -1;
}

function pick(rec: Record<string, Object>, snake: string, camel: string): Object | undefined {
  const a: Object | undefined = rec[snake];
  if (a !== undefined) {
    return a;
  }
  return rec[camel];
}

export class KProfileParse {
  // 解析原生侧留存的原始报文数组（JSON 字符串数组）。
  static parseRawList(rawJsonArray: string): KProfileTable {
    const table: KProfileTable = new KProfileTable();
    if (rawJsonArray === undefined || rawJsonArray === null || rawJsonArray.length === 0) {
      return table;
    }
    let list: Object[] = [];
    try {
      const parsed: Object = JSON.parse(rawJsonArray) as Object;
      if (Array.isArray(parsed)) {
        list = parsed as Object[];
      } else {
        list = [parsed];
      }
    } catch (e) {
      return table; // 原生侧保证是 JSON；走到这里说明缓冲异常，直接放弃
    }
    for (const payload of list) {
      if (typeof payload !== 'string') {
        continue;
      }
      const one: KProfileTable = KProfileParse.parseOne(payload as string);
      table.reports += one.reports;
      for (const e of one.entries) {
        KProfileParse.addEntry(table, e);
      }
    }
    return table;
  }

  // 解析单条报文。命中关键字（extrusion_cali / k_value / cali_idx / kprofile）才算一条相关报文。
  static parseOne(payload: string): KProfileTable {
    const out: KProfileTable = new KProfileTable();
    if (payload === undefined || payload === null || payload.length === 0) {
      return out;
    }
    if (payload.indexOf('extrusion_cali') < 0 && payload.indexOf('k_value') < 0 &&
      payload.indexOf('kValue') < 0 && payload.indexOf('cali_idx') < 0 &&
      payload.indexOf('caliIdx') < 0 && payload.indexOf('kprofile') < 0) {
      return out;
    }
    out.reports = 1;
    let node: Object | null = null;
    try {
      node = JSON.parse(payload) as Object;
    } catch (e) {
      return out; // 报文被截断/非 JSON：算一条相关报文，但解析不出条目
    }
    KProfileParse.scan(node, 0, out);
    return out;
  }

  private static scan(node: Object | null, depth: number, out: KProfileTable): void {
    if (node === null || node === undefined || depth > DEPTH_MAX) {
      return;
    }
    if (Array.isArray(node)) {
      const arr: Object[] = node as Object[];
      for (const it of arr) {
        KProfileParse.scan(it, depth, out);
      }
      return;
    }
    if (typeof node !== 'object') {
      return;
    }
    const rec: Record<string, Object> = node as Record<string, Object>;
    KProfileParse.collect(rec, out);
    for (const key of Object.keys(rec)) {
      KProfileParse.scan(rec[key], depth + 1, out);
    }
  }

  private static collect(rec: Record<string, Object>, out: KProfileTable): void {
    const kv: Object | undefined = pick(rec, 'k_value', 'kValue');
    if (kv === undefined) {
      return;
    }
    const e: KProfileEntry = new KProfileEntry();
    e.kValue = textOf(kv);
    e.nozzleDiameter = textOf(pick(rec, 'nozzle_diameter', 'nozzleDiameter'));
    e.name = textOf(pick(rec, 'name', 'name'));
    e.filamentId = textOf(pick(rec, 'filament_id', 'filamentId'));
    e.settingId = textOf(pick(rec, 'setting_id', 'settingId'));
    e.amsId = numOf(pick(rec, 'ams_id', 'amsId'));
    e.trayId = numOf(pick(rec, 'tray_id', 'trayId'));
    e.slotId = numOf(pick(rec, 'slot_id', 'slotId'));
    if (e.name.length === 0 && e.filamentId.length > 0) {
      e.name = e.filamentId;
    }
    if (e.nozzleDiameter.length > 0 && out.nozzles.indexOf(e.nozzleDiameter) < 0) {
      out.nozzles.push(e.nozzleDiameter);
    }
    KProfileParse.addEntry(out, e);
  }

  private static addEntry(table: KProfileTable, e: KProfileEntry): void {
    const k: string = e.key();
    for (const old of table.entries) {
      if (old.key() === k) {
        return; // 热身重发的两次请求常拿到同一份表，去重
      }
    }
    table.entries.push(e);
  }

  // 夹具自检（不需要打印机）：验证"认得出正常形状" + "遇到真机 ack / 垃圾 / 深层结构不崩"。
  static selfTest(): string {
    // ① 常见形状：printer 把表放在 cali 数组里
    const f1: string = '{"print":{"command":"extrusion_cali_get","sequence_id":"1","result":"success"},' +
      '"cali":[{"nozzle_diameter":"0.4","name":"Bambu PLA Basic","k_value":"0.020000",' +
      '"filament_id":"GFA00","setting_id":"GFSL99_01","ams_id":0,"tray_id":0,"slot_id":1}]}';
    // ② 数字型 k_value + 驼峰字段
    const f2: string = '{"kValue":0.025,"nozzleDiameter":"0.6","settingId":"GFSL99_02"}';
    // ③ 真机抓到的 set ack（result=fail，实际已生效）：必须 0 条且不抛
    const f3: string = '{"print":{"command":"extrusion_cali_set","nozzle_diameter":"0.6",' +
      '"reason":"invalid tray_id","result":"fail","sequence_id":"8001"}}';
    // ④ 非 JSON
    const f4: string = 'not json at all';
    // ⑤ 深层嵌套（验证递归能进去）
    const f5: string = '{"a":{"b":{"c":{"payloads":[{"k_value":"0.1","nozzle_diameter":"0.2"}]}}}}';

    let pass: number = 0;
    const detail: string[] = [];

    const t1: KProfileTable = KProfileParse.parseOne(f1);
    if (t1.entries.length === 1 && t1.entries[0].kValue === '0.020000' &&
      t1.entries[0].nozzleDiameter === '0.4' && t1.nozzles.length === 1) {
      pass++;
      detail.push('①形状=OK');
    } else {
      detail.push(`①形状=FAIL(条目=${t1.entries.length})`);
    }

    const t2: KProfileTable = KProfileParse.parseOne(f2);
    if (t2.entries.length === 1 && t2.entries[0].kValue === '0.025' && t2.entries[0].nozzleDiameter === '0.6') {
      pass++;
      detail.push('②数字型=OK');
    } else {
      detail.push(`②数字型=FAIL(条目=${t2.entries.length})`);
    }

    const t3: KProfileTable = KProfileParse.parseOne(f3);
    if (t3.entries.length === 0 && t3.reports === 1) {
      pass++;
      detail.push('③set-ack=OK');
    } else {
      detail.push(`③set-ack=FAIL(条目=${t3.entries.length} 报文=${t3.reports})`);
    }

    const t4: KProfileTable = KProfileParse.parseOne(f4);
    if (t4.entries.length === 0) {
      pass++;
      detail.push('④非JSON=OK');
    } else {
      detail.push('④非JSON=FAIL');
    }

    const t5: KProfileTable = KProfileParse.parseOne(f5);
    if (t5.entries.length === 1) {
      pass++;
      detail.push('⑤深层=OK');
    } else {
      detail.push(`⑤深层=FAIL(条目=${t5.entries.length})`);
    }

    // ⑥ 数组入口也要能用（原生侧返回的是字符串数组）
    const t6: KProfileTable = KProfileParse.parseRawList(`[${JSON.stringify(f1)},${JSON.stringify(f3)}]`);
    if (t6.entries.length === 1 && t6.reports === 2) {
      pass++;
      detail.push('⑥数组=OK');
    } else {
      detail.push(`⑥数组=FAIL(条目=${t6.entries.length} 报文=${t6.reports})`);
    }

    return `KProfileParse 自检 ${pass}/6 ${detail.join(' ')}`;
  }
}
