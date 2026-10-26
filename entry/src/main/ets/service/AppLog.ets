import { hilog } from '@kit.PerformanceAnalysisKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';

// 应用日志（ArkTS 侧）：给左侧「日志」页提供一份能直接在设备上查看的日志缓冲。
//
// 为什么需要它：原生日志只覆盖 C++ 侧（MQTT / 相机 / 渲染），而 gcode 解析诊断与路径告警
// 全部发生在 ArkTS 侧。用户人不在设备旁、抓不到 hilog，所以必须把这些信息搬进应用内日志页。
//
// 两类内容：
//   1) 诊断块（pushBlock）：每个 gcode 只写一块，内容是多行真实统计，允许重复（换 gcode 就再来一块）；
//   2) 告警（warn/error/alert）：按「首次出现 + 累计次数」去重，同名/同类只保留一条，
//      并就地更新次数 —— 否则材质越界 / 未识别 feature 会在每层每段重复触发，把日志页刷爆。
const DOMAIN: number = 0x0000;
const MAX_LINES: number = 400;

export class AppLog {
  private static lines: string[] = [];
  // 告警去重：key -> 该告警在 lines 里的下标 / 该关键字的累计触发次数
  private static alertIndex: Map<string, number> = new Map<string, number>();
  private static alertCount: Map<string, number> = new Map<string, number>();

  // 追加一行（供诊断块逐行写入）
  static push(text: string): void {
    AppLog.lines.push(text);
    const overflow: number = AppLog.lines.length - MAX_LINES;
    if (overflow > 0) {
      AppLog.lines.splice(0, overflow);
      // 修正被移出的告警下标：否则后续 alert() 会「就地更新」到不相干的行上，把日志改乱
      const stale: string[] = [];
      AppLog.alertIndex.forEach((idx: number, key: string): void => {
        const ni: number = idx - overflow;
        if (ni < 0) {
          stale.push(key);
        } else {
          AppLog.alertIndex.set(key, ni);
        }
      });
      for (const k of stale) {
        AppLog.alertIndex.delete(k);
      }
    }
  }

  // 追加一整个多行诊断块
  static pushBlock(blockLines: string[]): void {
    for (const l of blockLines) {
      AppLog.push(l);
    }
  }

  // 把诊断块**追加写进应用沙箱里的一个 .txt 文件**（追加，不覆盖：换一份 gcode 就多一块）。
  //
  // 为什么一定要落文件：用户人不在设备旁，抓不到 hilog；应用内「日志」页也要在现场翻。
  // 文件可以用文件管理器直接看，或下次连电脑时一次性取走 —— 这是「不连设备也能自证」的唯一出口。
  // 路径由调用方传入，必须是应用沙箱内可写目录（与 output.gcode / slice_input.3mf 同级的 filesDir）。
  // 返回是否写入成功；失败绝不静默：打 hilog.error 并返回 false。
  static writeDiagFile(filePath: string, lines: string[]): boolean {
    try {
      const slash: number = filePath.lastIndexOf('/');
      const dir: string = slash > 0 ? filePath.substring(0, slash) : '';
      if (dir.length > 0 && !fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const f: fs.File = fs.openSync(filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(f.fd, lines.join('\n') + '\n');
      } finally {
        fs.closeSync(f);
      }
      return true;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, 'AppLog', '诊断文件写入失败 %{public}s: %{public}s', filePath, msg);
      return false;
    }
  }

  // 告警（去重）：同一 key 只保留一条，并就地把它更新成最新的「共 N 次」。
  static alert(key: string, baseText: string): void {
    const n: number = (AppLog.alertCount.get(key) ?? 0) + 1;
    AppLog.alertCount.set(key, n);
    AppLog.replace(key, `${baseText}（共 ${n} 次）`);
  }

  // 已自行拼好计数的告警（去重但不再追加次数后缀）：同名只保留一条，就地更新为最新文本。
  // 用于调用方本身就是「一次调用汇总一批」的场景（未识别 feature / 材质越界），
  // 那里的次数是调用方统计的真实次数，不能再叠加触发次数。
  static note(key: string, text: string): void {
    AppLog.alertCount.set(key, (AppLog.alertCount.get(key) ?? 0) + 1);
    AppLog.replace(key, text);
  }

  private static replace(key: string, text: string): void {
    const idx: number = AppLog.alertIndex.get(key) ?? -1;
    if (idx >= 0 && idx < AppLog.lines.length) {
      AppLog.lines[idx] = text;
    } else {
      AppLog.push(text);
      AppLog.alertIndex.set(key, AppLog.lines.length - 1);
    }
  }

  // 与 hilog.warn 同用法的门面：hilog 原样输出（不删），同时把一条去重告警写进应用日志。
  // 以「tag + 格式串」作为去重 key：同一处告警无论触发多少次，应用日志里只占一条。
  // 只收 0~2 个占位参数 —— 本文件的调用点占位参数都不超过 2 个（超出的走 alert 自行拼串）。
  static warn(tag: string, fmt: string, a?: string | number, b?: string | number): void {
    if (a !== undefined && b !== undefined) {
      hilog.warn(DOMAIN, tag, fmt, a, b);
    } else if (a !== undefined) {
      hilog.warn(DOMAIN, tag, fmt, a);
    } else {
      hilog.warn(DOMAIN, tag, fmt);
    }
    AppLog.alert(`${tag}|${fmt}`, AppLog.format(fmt, a, b));
  }

  static error(tag: string, fmt: string, a?: string | number, b?: string | number): void {
    if (a !== undefined && b !== undefined) {
      hilog.error(DOMAIN, tag, fmt, a, b);
    } else if (a !== undefined) {
      hilog.error(DOMAIN, tag, fmt, a);
    } else {
      hilog.error(DOMAIN, tag, fmt);
    }
    AppLog.alert(`${tag}|${fmt}`, AppLog.format(fmt, a, b));
  }

  // 返回副本（旧 → 新）；日志页自行决定显示顺序
  static getLines(): string[] {
    return AppLog.lines.slice();
  }

  // ---- 内存快照（定位「首次切片 / 打印产出 OOM」这类峰值）----
  // 三路读数：Total Pss（进程物理内存，含 native + JS）/ native 堆已分配 / JS VM 总堆。
  // 读 /proc/{pid}/smaps_rollup 较耗时，只在低频关键点调用（切片前/后、产出含 gcode 3MF 前后）。
  // 读失败绝不静默：hilog.warn 留下原因，返回里对应项为 '?'。
  static mem(tag: string, phase: string): string {
    let pssMb: string = '?';
    let nativeMb: string = '?';
    let vmHeapMb: string = '?';
    try {
      pssMb = (Number(hidebug.getPss()) / 1024).toFixed(1);
    } catch (e) {
      hilog.warn(DOMAIN, 'Mem', 'getPss 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    try {
      nativeMb = (Number(hidebug.getNativeHeapAllocatedSize()) / (1024 * 1024)).toFixed(1);
    } catch (e) {
      hilog.warn(DOMAIN, 'Mem', 'getNativeHeapAllocatedSize 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    try {
      vmHeapMb = (Number(hidebug.getAppVMMemoryInfo().totalHeap) / 1024).toFixed(1);
    } catch (e) {
      hilog.warn(DOMAIN, 'Mem', 'getAppVMMemoryInfo 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    const text: string = `[Mem] ${tag} ${phase} TotalPss=${pssMb}MB nativeHeap=${nativeMb}MB vmHeap=${vmHeapMb}MB`;
    hilog.info(DOMAIN, 'Mem', '%{public}s', text);
    AppLog.push(text);
    return text;
  }

  // 把 hilog 的格式串（%{public}s / %{public}d …）按实参展开成纯文本，供应用日志阅读
  private static format(fmt: string, a?: string | number, b?: string | number): string {
    const args: (string | number)[] = [];
    if (a !== undefined) { args.push(a); }
    if (b !== undefined) { args.push(b); }
    let out: string = '';
    let i: number = 0;
    let ai: number = 0;
    while (i < fmt.length) {
      if (fmt.charCodeAt(i) === 37) {                 // '%'：占位符起点
        const close: number = fmt.indexOf('}', i);
        if (close >= 0 && ai < args.length) {
          let j: number = close + 1;
          // 跳过占位符的类型字母（v / s / d / f…）
          while (j < fmt.length) {
            const c: number = fmt.charCodeAt(j);
            if ((c >= 97 && c <= 122) || (c >= 65 && c <= 90)) { j++; } else { break; }
          }
          out += `${args[ai]}`;
          ai++;
          i = j;
          continue;
        }
      }
      out += fmt.charAt(i);
      i++;
    }
    return out;
  }
}
