import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLog } from './AppLog';

const DOMAIN: number = 0x0000;

//「上次使用的预设」持久化通道的日志 tag（与 hilog / 应用内日志 / 诊断文件三处同用）。
export const PRESET_PERSIST_TAG: string = 'PresetPersist';

// 上次使用的预设快照。为什么单独建类而不是用匿名对象：ArkTS 反序列化需要明确的字段类型
// （不允许 any），否则 JSON.parse 的结果没法静态取值。
//
// 耗材槽位说明：本工程的预设选择只暴露「一个活动耗材预设」（下拉 kind=2 的当前选中项），
// AMS 的多个物理槽位是设备状态、不是切片预设，因此这里只存这一个实际用到的耗材预设名。
export class PresetSnapshot {
  printer: string = '';
  process: string = '';
  filament: string = '';
  bedType: string = '';
  savedAt: string = '';
}

// 预设持久化：把「上次成功切换的预设」落到 filesDir 下的 JSON 文件，下次启动恢复。
//
// 为什么用 filesDir 下的 JSON 文件而不是 @ohos.data.preferences：
// 本工程已有 filesDir 写文件通道（见 AppLog.writeDiagFile），沿用它最省、且能把持久化日志
// 与其它诊断写进同一处 files/diag/gcode_diag.txt；preferences 需要额外拿 Context 初始化，
// 这里没有现成通道。
//
// 为什么"每次切换成功就写盘"而不是"退出时写一次"：应用被强杀 / 崩溃时退出钩子不会执行，
// 只有增量写盘才能保证不丢（写盘代价只是 4 个键，可忽略）。
export class PresetPersist {
  static filePath(filesDir: string): string {
    return `${filesDir}/preset_last.json`;
  }

  // 写盘：整体覆盖（仅 4 个键）。读写都 try/catch，失败打 hilog，绝不吞异常。
  static save(filesDir: string, snap: PresetSnapshot): boolean {
    const path: string = PresetPersist.filePath(filesDir);
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(snap));
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (e) {
      hilog.error(DOMAIN, PRESET_PERSIST_TAG, '保存预设失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return false;
    }
  }

  // 读盘：文件不存在（首次启动）/ 内容损坏都返回 undefined，由调用方走默认路径；异常留 hilog。
  static load(filesDir: string): PresetSnapshot | undefined {
    const path: string = PresetPersist.filePath(filesDir);
    try {
      // 文件不存在是首次启动的正常情况，不算错误，不刷错误日志
      if (!fs.accessSync(path)) {
        return undefined;
      }
      const text: string = fs.readTextSync(path);
      if (text.length === 0) {
        return undefined;
      }
      return JSON.parse(text) as PresetSnapshot;
    } catch (e) {
      hilog.error(DOMAIN, PRESET_PERSIST_TAG, '读取预设失败 %{public}s: %{public}s', path,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return undefined;
    }
  }

  // 自证日志：hilog + 应用内日志 + files/diag/gcode_diag.txt 三处同写（沿用现有写入通道），
  // 保证用户不连设备也能在日志页 / 诊断文件里核对保存与恢复结果。
  static log(filesDir: string, text: string): void {
    hilog.info(DOMAIN, PRESET_PERSIST_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${PRESET_PERSIST_TAG}] ${text}`);
      const ok: boolean = AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`,
        [`[${PRESET_PERSIST_TAG}] ${text}`]);
      if (!ok) {
        hilog.warn(DOMAIN, PRESET_PERSIST_TAG, '持久化日志落盘失败');
      }
    } catch (e) {
      hilog.error(DOMAIN, PRESET_PERSIST_TAG, '持久化日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }
}
