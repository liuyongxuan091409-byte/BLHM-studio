import { modelState, ModelInstance } from './ModelState';

// =============================================================================
// 应用内「对象剪贴板」
//
// 与系统剪贴板无关（系统剪贴板只用于复制日志文本，见 LogPanel）：这里是**应用内的对象暂存区**，
// 支持「复制 / 剪切 / 粘贴到当前盘」，粘贴出来的对象带着自己的**对象级参数覆盖**。
//
// 为什么存快照克隆而不是引用：剪贴板要能跨「源对象被删除」存活（剪切场景），
// 所以存的是与当前状态解耦的克隆（标量独立、几何共享引用，见 ModelState 文件头性能约定）。
// =============================================================================
class ClipEntry {
  snap: ModelInstance | null = null;
  ovKeys: string[] = [];
  ovVals: number[] = [];
}

export class ObjClipboard {
  private items: ClipEntry[] = [];
  // 连续粘贴的偏移倍数：每粘一次 +1，避免多份粘贴叠在同一位置
  private pasteCount: number = 0;

  // 复制到剪贴板（返回复制到的对象数）
  copy(ids: number[]): number {
    const next: ClipEntry[] = [];
    for (const id of ids) {
      const snap: ModelInstance | undefined = modelState.copyInstanceForClipboard(id);
      if (snap === undefined) {
        continue;
      }
      const e: ClipEntry = new ClipEntry();
      e.snap = snap;
      const bucket: Map<string, number> | undefined = modelState.getObjectOverrides().get(id);
      if (bucket !== undefined) {
        bucket.forEach((v: number, k: string): void => {
          e.ovKeys.push(k);
          e.ovVals.push(v);
        });
      }
      next.push(e);
    }
    if (next.length === 0) {
      return 0;
    }
    this.items = next;
    this.pasteCount = 0;
    this.publish();
    return next.length;
  }

  // 剪切 = 复制 + 从板上移除（返回被剪切的对象数）
  cut(ids: number[]): number {
    const n: number = this.copy(ids);
    if (n > 0) {
      for (const id of ids) {
        modelState.remove(id);
      }
      modelState.publish();
    }
    return n;
  }

  // 粘贴到指定盘（plate <= 0 = 保持各自原盘）；返回新对象 id 列表
  paste(plate: number = -1): number[] {
    const out: number[] = [];
    if (this.items.length === 0) {
      return out;
    }
    this.pasteCount++;
    for (const e of this.items) {
      const src: ModelInstance | null = e.snap;
      if (src === null) {
        continue;
      }
      const w: number = src.size.x > 0 ? src.size.x : 30;
      const dx: number = (w + 5) * this.pasteCount;
      const dstPlate: number = plate > 0 ? plate : src.plate;
      const newId: number = modelState.pasteInstance(src, ' 副本', dx, dstPlate);
      for (let i = 0; i < e.ovKeys.length; i++) {
        modelState.setObjectOverride(newId, e.ovKeys[i], e.ovVals[i]);
      }
      out.push(newId);
    }
    modelState.publish();
    return out;
  }

  has(): boolean {
    return this.items.length > 0;
  }

  count(): number {
    return this.items.length;
  }

  clear(): void {
    this.items = [];
    this.pasteCount = 0;
    this.publish();
  }

  private publish(): void {
    AppStorage.setOrCreate<number>('clipboardCount', this.items.length);
  }
}

export const objClipboard: ObjClipboard = new ObjClipboard();
