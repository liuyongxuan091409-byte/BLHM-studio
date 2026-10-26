import { resourceManager } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// HMS 故障码 → 中文文案（离线码表，功能 12）
//
// 数据来源：桌面版 Bambu Studio 自带的 `resources/hms/hms_zh-CN_<设备类型码>.json`
// （已拷进 `entry/src/main/resources/rawfile/hms/`）。结构：
//   { ver, data: { device_error: {"zh-cn":[{ecode,intro}...]},
//                  device_hms:   {"zh-cn":[{ecode,intro}...]} } }
//
// 【两套键，别搞混】（实测自 2026-10-17 的桌面版资源）
//   · `device_hms` 的键是 **16 位十六进制** = %08X(attr) + %08X(code)，
//     对应上报里的 `print.hms[] = [{attr, code}]`（attr 是模块，code 的高 16 位是等级、低 16 位是码）。
//     反证：16 位键的「后 8 位」只有 92 个不同值、且形如 00010001/00020002（等级+码），
//     而「前 8 位」有 797 个不同值（模块）—— 顺序确实是 attr 在前。
//   · `device_error` 的键是 **8 位十六进制** = 十进制 `print.print_error` 的十六进制写法
//     （如 117669906 = 0x07038012 就在表里）。所以打印报单码故障时用这条链路。
//
// 【为什么不放 C++】码表是 rawfile 资源：换语言/更新码表不该重编原生库；
// 而且这里要处理「两套键 + 兜底」，放在 ETS 侧更好调试。C++ 只负责把 `hms` 数组原样透传。
//
// 【什么时候加载】HMS 是低频事件（机器健康时是空数组），所以**惰性加载**：
// 第一次真出现故障才逐个读文件，并且**命中即停**（通常第一个文件就命中）。
// 不做启动预热 —— 8 个文件约 7MB，为罕见事件付启动成本不值。
// =============================================================================

const TAG: string = 'HmsTable';

// 加载顺序：先桌面版运行时按本机机型 OTA 下来的那份（00M），再补其余设备类型码。
// 实测各机型码表**互不包含**（00M 2045 条 / 26A 4319 条，各自都有对方没有的键），
// 所以全部带上、按上报命中，不做「机型 → 码表」映射（那个映射没有静态定义文件，不猜）。
const HMS_FILES: string[] = [
  'hms/hms_zh-cn_00M.json',
  'hms/hms_zh-cn_26A.json',
  'hms/hms_zh-cn_239.json',
  'hms/hms_zh-cn_093.json',
  'hms/hms_zh-cn_094.json',
  'hms/hms_zh-cn_20P.json',
  'hms/hms_zh-cn_22E.json',
  'hms/hms_zh-cn_31B.json'
];

// 上报里的 hms 数组元素
export class HmsItem {
  attr: number = 0;
  code: number = 0;
}

// 查询结果（给 UI 用）
export class HmsHit {
  // 展示用的码（16 位 = attr+code；8 位 = print_error）。表里没有文案时也要能把它显示出来 —— 
  // 用户拿这个码能去官方文档/支持渠道查，比"什么都不显示"强。
  ecode: string = '';
  // 码表文案；空串 = 表里没有这条（不编造，UI 只显示码）
  intro: string = '';
  // code 的高 16 位（1/2/3，数值越小越严重；仅用于配色，不编造等级中文名）
  level: number = 0;
}

interface HmsEntryJson {
  ecode?: string;
  intro?: string;
}

// 语言键在资源里是 `zh-CN`、在运行时 OTA 文件里是 `zh-cn` —— 两种都认。
// 用 Record 而不是带引号键的 interface：ArkTS 禁止对 interface 字段做下标访问
//（arkts-no-props-by-index），Record 才允许 `sec['zh-cn']`。
type HmsLangJson = Record<string, HmsEntryJson[]>;

interface HmsDataJson {
  device_error?: HmsLangJson;
  device_hms?: HmsLangJson;
}

interface HmsFileJson {
  ver?: string;
  data?: HmsDataJson;
}

function errText(e: Object): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
}

// 32 位整数 → 8 位大写十六进制（JS 的位运算按 32 位处理，>>>0 保证按无符号解释）
function hex8(n: number): string {
  return (n >>> 0).toString(16).toUpperCase().padStart(8, '0');
}

export class HmsTable {
  private mgr: resourceManager.ResourceManager | undefined = undefined;
  // ecode → intro（已合并进来的文件）
  private index: Map<string, string> = new Map<string, string>();
  // 已尝试加载的文件数（惰性递进：查不到就继续读下一个文件）
  private loadedFiles: number = 0;
  private entryCount: number = 0;

  init(mgr: resourceManager.ResourceManager): void {
    this.mgr = mgr;
  }

  // attr/code（print.hms[] 的元素）→ 文案
  lookup(attr: number, code: number): HmsHit {
    const hit: HmsHit = new HmsHit();
    const key16: string = hex8(attr) + hex8(code);
    hit.level = (code >>> 16) & 0xFFFF;
    if (this.ensureForKey(key16)) {
      hit.ecode = key16;
      hit.intro = this.index.get(key16) ?? '';
      return hit;
    }
    // 兜底：少数固件把 16 位码塞在低 16 位里上报（attr/code 都只有 2 字节有效）
    const key8: string = hex8(attr).substring(4) + hex8(code).substring(4);
    if (this.ensureForKey(key8)) {
      hit.ecode = key8;
      hit.intro = this.index.get(key8) ?? '';
      hit.level = 0;
      hilog.info(0x0000, TAG, '按 8 位键兜底命中: %{public}s（attr=%{public}d code=%{public}d）',
        key8, attr, code);
      return hit;
    }
    hit.ecode = key16;
    hit.intro = '';
    return hit;
  }

  // print_error（十进制整数）→ 文案（device_error 表，键是它的十六进制写法）
  lookupPrintError(printError: number): HmsHit {
    const hit: HmsHit = new HmsHit();
    if (printError === 0) {
      return hit;
    }
    const key: string = hex8(printError);
    hit.ecode = key;
    if (this.ensureForKey(key)) {
      hit.intro = this.index.get(key) ?? '';
    }
    return hit;
  }

  // 码表状态（自证/日志用）
  statusText(): string {
    return `文件=${this.loadedFiles}/${HMS_FILES.length} 条目=${this.entryCount}`;
  }

  testLoaded(): boolean {
    return this.entryCount > 0;
  }

  // ---- 惰性加载：命中即停，未命中就把剩下的文件继续读完（供下次查询）----
  private ensureForKey(key: string): boolean {
    if (this.index.has(key)) {
      return true;
    }
    while (this.loadedFiles < HMS_FILES.length) {
      const name: string = HMS_FILES[this.loadedFiles];
      this.loadedFiles++;
      this.mergeFile(name);
      if (this.index.has(key)) {
        return true;
      }
    }
    return false;
  }

  private mergeFile(name: string): void {
    const mgr: resourceManager.ResourceManager | undefined = this.mgr;
    if (mgr === undefined) {
      hilog.warn(0x0000, TAG, '未注入 resourceManager，跳过 %{public}s', name);
      return;
    }
    const t0: number = Date.now();
    try {
      const buf: Uint8Array = mgr.getRawFileContentSync(name);
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = dec.decodeToString(buf);
      const root: HmsFileJson = JSON.parse(text) as HmsFileJson;
      let added: number = 0;
      if (root.data !== undefined) {
        added += this.mergeSection(root.data.device_error, false);
        added += this.mergeSection(root.data.device_hms, true);
      }
      // 有的条目有码没文案（intro 为空）—— 那种不放进索引，UI 会退化成"只显示码"，语义一致
      hilog.info(0x0000, TAG, '码表已载入 %{public}s ver=%{public}s +%{public}d 条 总%{public}d 条 %{public}dms',
        name, root.ver !== undefined ? root.ver : '?', added, this.entryCount, Date.now() - t0);
    } catch (e) {
      hilog.warn(0x0000, TAG, '码表载入失败 %{public}s: %{public}s', name, errText(e));
    }
  }

  private mergeSection(sec: HmsLangJson | undefined, isHms: boolean): number {
    if (sec === undefined) {
      return 0;
    }
    const list: HmsEntryJson[] | undefined = sec['zh-cn'] ?? sec['zh-CN'];
    if (list === undefined) {
      return 0;
    }
    let added: number = 0;
    for (const it of list) {
      const code: string = it.ecode !== undefined ? it.ecode : '';
      const intro: string = it.intro !== undefined ? it.intro : '';
      if (code.length === 0 || intro.length === 0) {
        continue;
      }
      // 先到先得：不同设备类型码表若有同键，以先加载的那份为准（顺序见 HMS_FILES）
      if (!this.index.has(code)) {
        this.index.set(code, intro);
        this.entryCount++;
        added++;
      }
    }
    return added;
  }

  // ---- 启动自测（真机跑一次，结果进 hilog 与 diag 文件）----
  // 自测能覆盖什么、不能覆盖什么，说清楚：
  //   ✅ 码表文件能被 rawfile 读到、JSON 解析成功、条目进了索引；
  //   ✅ 「attr/code → 16 位键」的组合规则与真实键**自洽**（取表里前若干条反推再拼回去，必须相等）；
  //   ✅ 真实条目能查到文案（打印若干条样本供肉眼核对）。
  //   ❌ 无法证明打印机真实上报的 attr/code 就长这样 —— 那需要真机触发一次 HMS，
  //      所以 lookup() 里还留了 8 位键兜底，并把命中方式打进日志。
  selfTest(): string {
    let out: string = '=== HMS 码表 单元自测（离线，不连打印机）===\n';
    if (this.mgr === undefined) {
      out += '[FAIL] resourceManager 未注入\n';
      return out;
    }
    // 先把 8 个文件全部读进来（自测要全量统计，不用"命中即停"）
    while (this.loadedFiles < HMS_FILES.length) {
      const name: string = HMS_FILES[this.loadedFiles];
      this.loadedFiles++;
      this.mergeFile(name);
    }
    out += `码表状态: ${this.statusText()}\n`;
    if (this.entryCount === 0) {
      out += '[FAIL] 一条都没载入（rawfile 路径不对或 JSON 结构变了）\n';
      return out;
    }
    out += `[PASS] 码表已载入 ${this.entryCount} 条\n`;

    // 组合规则自洽性：取 16 位键的那些条目，反推 attr/code 再拼回键，必须与原键一致
    let checked: number = 0;
    let mismatch: number = 0;
    let samples: string = '';
    this.index.forEach((intro: string, code: string): void => {
      if (code.length !== 16) {
        return;
      }
      if (checked < 200) {
        const attr: number = parseInt(code.substring(0, 8), 16);
        const c: number = parseInt(code.substring(8, 16), 16);
        const back: string = hex8(attr) + hex8(c);
        if (back !== code) {
          mismatch++;
        }
        checked++;
      }
      if (samples.length === 0) {
        const hit: HmsHit = this.lookup(parseInt(code.substring(0, 8), 16), parseInt(code.substring(8, 16), 16));
        samples = `样本: ecode=${hit.ecode} level=${hit.level} 文案=${hit.intro.substring(0, 60)}\n`;
      }
    });
    out += `[${mismatch === 0 ? 'PASS' : 'FAIL'}] attr/code → 16 位键 组合自洽（抽查 ${checked} 条，不一致 ${mismatch} 条）\n`;
    out += samples;
    out += `=== 结果: 载入 ${this.entryCount} 条 / 抽查 ${checked} 条 ===\n`;
    return out;
  }
}

export const hmsTable: HmsTable = new HmsTable();
