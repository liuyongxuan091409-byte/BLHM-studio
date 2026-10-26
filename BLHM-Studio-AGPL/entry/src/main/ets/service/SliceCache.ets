import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 切片产物 / 打包缓存的清理。
//
// 为什么需要：这些文件此前**只写不删** —— 关软件、导入新文件后仍堆在沙箱里
// （实测 files/ 已达 425MB：output.gcode、output_plate_N.gcode、slice_plate_N.3mf、
//  126MB 的 project_input.tmp.3mf、gcode_pkg_cache/*、slice_tmp/*，以及被删剩下的
//  *.stage / *.debug.json 兄弟文件）。
//
// 刻意**不删**：
//   · 用户工程与配置：未命名项目.3mf、preset_last.json、param_overrides.json 等；
//   · 机器资源与诊断：bambu_res/、diag/。
const TAG: string = 'SliceCache';

export class SliceCache {
  // 固定文件名的切片产物
  private static readonly FILES: string[] = [
    'output.gcode',
    'output.gcode.stage',
    'output.gcode.debug.json',
    'preview_model.stl',
    'slice_input.3mf',
    // 含当前变换的切片输入工程（用户改过旋转/缩放/移动时由 Index.startSlice 写出）
    'slice_baked.3mf',
    'project_input.tmp.3mf',
    // 自动备份的输入临时文件（见 service/AutoBackup：与保存链路分开，避免两条链路互相踩）
    'backup_input.tmp.3mf'
  ];
  // 内核 / 打包临时目录（整目录递归删除）
  private static readonly DIRS: string[] = ['gcode_pkg_cache', 'slice_tmp'];

  private static unlink(p: string): boolean {
    try {
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
        return true;
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '删除失败 %{public}s: %{public}s', p,
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    return false;
  }

  private static rmdir(p: string): boolean {
    try {
      if (fs.accessSync(p)) {
        fs.rmdirSync(p);
        return true;
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '删目录失败 %{public}s: %{public}s', p,
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    return false;
  }

  /**
   * 清掉「上一批切片」的全部产物与临时目录（幂等；失败只记日志，不抛）。
   * 调用时机：导入新文件前、应用退出时。
   */
  static clearAll(filesDir: string, why: string): void {
    let n: number = 0;
    for (const f of SliceCache.FILES) {
      if (SliceCache.unlink(`${filesDir}/${f}`)) {
        n++;
      }
    }
    for (const d of SliceCache.DIRS) {
      if (SliceCache.rmdir(`${filesDir}/${d}`)) {
        n++;
      }
    }
    n += SliceCache.clearPlateGcodes(filesDir, false);
    try {
      const names: string[] = fs.listFileSync(filesDir);
      for (const nm of names) {
        if (/^slice_plate_\d+\.3mf$/.test(nm)) {
          if (SliceCache.unlink(`${filesDir}/${nm}`)) {
            n++;
          }
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '列目录失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    hilog.info(0x0000, TAG, '清切片缓存(%{public}s) 删除 %{public}d 项', why, n);
  }

  /**
   * 只清「逐盘切片产物」output_plate_<N>.gcode（含 .stage / .debug.json 兄弟文件）。
   * 为什么单独提供：多盘切片前要**一次清空所有盘号**的旧产物 —— 只按本次盘号删的话，
   * 下次导入「盘数更少」的文件时，旧盘号的 output_plate_<N>.gcode 会永久残留，
   * 还可能在预览里被张冠李戴地当成结果。
   */
  static clearPlateGcodes(filesDir: string, logIt: boolean): number {
    let n: number = 0;
    try {
      const names: string[] = fs.listFileSync(filesDir);
      for (const nm of names) {
        if (/^output_plate_\d+\.gcode(\.stage|\.debug\.json)?$/.test(nm)) {
          if (SliceCache.unlink(`${filesDir}/${nm}`)) {
            n++;
          }
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '列目录失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    if (logIt) {
      hilog.info(0x0000, TAG, '清逐盘产物 删除 %{public}d 项', n);
    }
    return n;
  }
}
