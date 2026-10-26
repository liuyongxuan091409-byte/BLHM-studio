import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// 「视觉」光感设置（背景发光 / 手柄发光）持久化。
//
// 背景：这两个值此前只存在 AppStorage（纯内存），重启即丢。这里把它们落到应用沙箱
// filesDir/ui_glow.json，启动时读回并写进 AppStorage —— AppStorage 仍是唯一的共享通道，
// ModelPreviewPage 的 @StorageLink + @Watch 实时链路不变，这里只补「落盘 / 读回」。
//
// 只负责这两个值，不碰其它设置。
// =============================================================================
const TAG: string = 'GlowSettings';
const DOMAIN: number = 0x0000;
const FILE_NAME: string = 'ui_glow.json';

export const GLOW_BG_KEY: string = 'glowBg';
export const GLOW_HANDLE_KEY: string = 'glowHandle';
export const GLOW_DEFAULT: number = 1.0;
const GLOW_MIN: number = 0.0;
const GLOW_MAX: number = 2.0;

// 落盘结构：{"glowBg":1.2,"glowHandle":0.8}
class GlowSnapshot {
  glowBg: number = GLOW_DEFAULT;
  glowHandle: number = GLOW_DEFAULT;
}

export class GlowSettings {
  // 值规范化：非数值 / NaN / 越界（合法范围 0~2）一律回落默认 1.0。
  private static clamp(v: number): number {
    if (typeof v !== 'number' || Number.isNaN(v)) { return GLOW_DEFAULT; }
    if (v < GLOW_MIN) { return GLOW_MIN; }
    if (v > GLOW_MAX) { return GLOW_MAX; }
    return v;
  }

  // 读盘并写进 AppStorage。文件不存在 / 解析失败 / 值越界 → 用默认 1.0，且绝不抛异常中断启动。
  static load(filesDir: string): void {
    let bg: number = GLOW_DEFAULT;
    let handle: number = GLOW_DEFAULT;
    if (filesDir.length > 0) {
      const path: string = `${filesDir}/${FILE_NAME}`;
      try {
        if (fs.accessSync(path)) {
          const text: string = fs.readTextSync(path);
          if (text.length > 0) {
            const raw: GlowSnapshot = JSON.parse(text) as GlowSnapshot;
            bg = GlowSettings.clamp(raw.glowBg);
            handle = GlowSettings.clamp(raw.glowHandle);
          }
        }
      } catch (e) {
        // 解析失败不中断启动：如实记日志，退回默认值
        hilog.error(DOMAIN, TAG, '读光感设置失败，用默认值: %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      }
    }
    AppStorage.setOrCreate<number>(GLOW_BG_KEY, bg);
    AppStorage.setOrCreate<number>(GLOW_HANDLE_KEY, handle);
    hilog.info(DOMAIN, TAG, '光感设置就绪: 背景发光=%{public}f 手柄发光=%{public}f', bg, handle);
  }

  // 落盘两个值（写失败只记日志，不影响实时生效）。
  static save(filesDir: string, glowBg: number, glowHandle: number): void {
    if (filesDir.length === 0) { return; }
    const path: string = `${filesDir}/${FILE_NAME}`;
    try {
      const snap: GlowSnapshot = new GlowSnapshot();
      snap.glowBg = GlowSettings.clamp(glowBg);
      snap.glowHandle = GlowSettings.clamp(glowHandle);
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(snap));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '保存光感设置失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }
}
