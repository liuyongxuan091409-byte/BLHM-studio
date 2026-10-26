import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CalibAssets';

// 一项校准：模型随包放在 rawfile/calib/，运行时拷到沙箱再交给切片内核。
// 只收 .3mf：内核 slicerSlice 直接按路径加载，.stl/.step 需要先转网格，
// 因此 STL/STEP 类（温度塔/回抽塔/VFA/体积速度）本版标记为未开放，不假装可用。
export class CalibItem {
  id: string = '';
  name: string = '';
  desc: string = '';
  file: string = '';
  // 设备侧校准（拓竹机型可在机内自动跑并回写 K 值）：本版只做本地切出模型，
  // 下发与结果回收等接打印机时再做，界面上如实标注。
  deviceSide: boolean = false;
  available: boolean = false;

  constructor(id: string, name: string, desc: string, file: string,
              deviceSide: boolean, available: boolean) {
    this.id = id;
    this.name = name;
    this.desc = desc;
    this.file = file;
    this.deviceSide = deviceSide;
    this.available = available;
  }
}

// 校准模型资源管理：与 HmsTable 同一套路（EntryAbility 里注入 resourceManager）。
export class CalibAssets {
  private static mgr: resourceManager.ResourceManager | undefined = undefined;

  static init(mgr: resourceManager.ResourceManager): void {
    CalibAssets.mgr = mgr;
    hilog.info(0x0000, TAG, 'resourceManager 已注入，校准模型可用=%{public}d 项',
      CalibAssets.items().filter((i: CalibItem) => i.available).length);
  }

  // 已随包的 5 个 3MF + 4 个待支持项（列表固定，界面按顺序渲染）
  static items(): CalibItem[] {
    return [
      new CalibItem('flow1', '流量比例校准 · 第 1 遍',
        '打印流量测试块，第一遍粗测。切完可在预览里看各块的实际线宽。',
        'flowrate-test-pass1.3mf', true, true),
      new CalibItem('flow2', '流量比例校准 · 第 2 遍',
        '按第 1 遍结果收窄区间后精测，得到最终流量比例。',
        'flowrate-test-pass2.3mf', true, true),
      new CalibItem('pa', '动态流量校准 · 图案',
        'PA 图案测试，用于判断该耗材的压力提前量是否合适。',
        'pa_pattern.3mf', true, true),
      new CalibItem('pa_auto_s', '动态流量 · 自动线（单喷嘴）',
        '单喷嘴机型的自动 PA 线，机内可自动判定。',
        'auto_pa_line_single.3mf', true, true),
      new CalibItem('pa_auto_d', '动态流量 · 自动线（双喷嘴）',
        '双喷嘴机型（H2D 这一类）的自动 PA 线。',
        'auto_pa_line_dual.3mf', true, true),
      new CalibItem('temp', '温度塔', '需要先把 STL 转成 3MF，本版未开放。', '', false, false),
      new CalibItem('retract', '回抽塔', '需要先把 STL 转成 3MF，本版未开放。', '', false, false),
      new CalibItem('vfa', 'VFA 速度测试', '需要先把 STL 转成 3MF，本版未开放。', '', false, false),
      new CalibItem('vol', '体积速度测试（STEP）', '需要 CAD 网格化后再切，本版未开放。', '', false, false)
    ];
  }

  // 把 rawfile 里的校准模型拷到沙箱，返回可直接切片的路径；失败返回空串。
  // 已存在且非空则直接复用（避免每次校准都重写几百 KB）。
  static ensureModel(item: CalibItem, filesDir: string): string {
    if (!item.available || item.file === '') {
      hilog.warn(0x0000, TAG, '模型未开放 id=%{public}s', item.id);
      return '';
    }
    if (filesDir === '') {
      hilog.error(0x0000, TAG, 'filesDir 为空，无法落地校准模型 id=%{public}s', item.id);
      return '';
    }
    const dir: string = `${filesDir}/calib`;
    const dst: string = `${dir}/${item.file}`;
    try {
      fs.mkdirSync(dir);
    } catch (e) {
      // 目录已存在是正常路径，不当作失败
    }
    let size: number = 0;
    try {
      size = fs.statSync(dst).size;
    } catch (e) {
      size = 0;
    }
    if (size > 0) {
      hilog.info(0x0000, TAG, '复用已落地模型 %{public}s size=%{public}d', item.file, size);
      return dst;
    }
    const mgr: resourceManager.ResourceManager | undefined = CalibAssets.mgr;
    if (mgr === undefined) {
      hilog.error(0x0000, TAG, 'resourceManager 未注入，无法读取 rawfile/calib/%{public}s', item.file);
      return '';
    }
    try {
      const buf: Uint8Array = mgr.getRawFileContentSync(`calib/${item.file}`);
      const fd: fs.File = fs.openSync(dst,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(fd.fd, buf.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(fd);
      }
      const written: number = fs.statSync(dst).size;
      hilog.info(0x0000, TAG, '已落地模型 %{public}s raw=%{public}d 写入=%{public}d',
        item.file, buf.length, written);
      return written > 0 ? dst : '';
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(0x0000, TAG, '落地模型失败 %{public}s: %{public}s', item.file, msg);
      return '';
    }
  }
}
