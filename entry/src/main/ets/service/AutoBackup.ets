import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// 自动备份 / 崩溃恢复（Phase 4 最后一项）
//
// 两个机制放在一起，因为它们共用同一个目录 `${filesDir}/backup/`：
//
//   ① **会话锁**：启动时「先探测、再打锁」。探测到旧锁 = 上次不是正常退出
//      （进程被杀 / 被系统回收 / force-stop 都不会走到清理逻辑）。
//      正常退出要清锁，且**两条路径都要清**：onDestroy 与「允许关闭窗口」
//      （实测「关闭窗口」不一定会走 onDestroy，只清 onDestroy 会每次正常关窗都误报崩溃）。
//
//   ② **自动备份**：最后一次结构性变更后**空闲 IDLE_MS** 才落一份
//      `backup/autosave_<slot>.3mf`，槽位轮转 SLOT_COUNT 个 —— 占用上限天然是
//      「N 份工程大小」，不需要额外的空间清理逻辑。只在「有未保存改动」且「有对象」时备份。
//
// 【为什么「真正执行备份」是注入的回调（perform）】备份必须走内核 store_bbs_3mf 导出链路，
// 而那条链路的入口在页面层（要 UIContext / 参数快照 / 多色映射）。本模块只做机制
//（会话锁、防抖、槽位轮转、备份文件探测），不反向依赖 model/ 与页面 ——
// 于是 `History.flush()` 可以放心调 `arm()`，不会形成 model → service → model 的环。
//
// 【为什么不上「定时轮询」】轮询会在空闲时也空转导出（大工程秒级、纯浪费）；
// 「变更后防抖」既把连续编辑合并成一次，也保证备份内容总是最新的那一版。
// =============================================================================

const TAG: string = 'AutoBackup';
const LOCK_FILE: string = 'session.lock';
const BACKUP_DIR: string = 'backup';
// 备份槽位数（轮转）。占用上限 ≈ SLOT_COUNT × 单份工程大小。
const SLOT_COUNT: number = 3;
// 备份输入临时文件（与保存链路用的 project_input.tmp.3mf 分开，避免两条链路互相踩）
const INPUT_TMP: string = 'backup_input.tmp.3mf';
// 最后一次结构性变更后空闲多久开始备份。取 30s：既能把连续编辑合并成一次（少写大文件），
// 又不至于让崩溃丢掉太多工作。
const IDLE_MS: number = 30000;
// 单份备份的字节上限（按**产出的工程 3MF** 判）：超过就删掉这份、这轮不备。
// 目的是防「超大工程 × 3 槽位」把沙箱撑爆 —— 那种情况用户本就应该手动保存。
// 注意别按「导出前的通用 3MF 输入」判：那个输入比工程 3MF 大一个数量级
//（实测导入 84MB 的 STL，通用 3MF 输入 311MB，而工程 3MF 产出只有 21MB），
// 按它判会把正常工程误杀成「不备份」（实测踩到）。
export const BACKUP_MAX_BYTES: number = 300 * 1024 * 1024;

// 会话锁内容（只用于人工排查；判据是「文件在不在」）
class SessionLock {
  at: number = 0;
}

// 一份可用备份的信息
export class BackupInfo {
  path: string = '';
  size: number = 0;
  // 毫秒时间戳
  at: number = 0;
}

function errText(e: Object): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
}

export class AutoBackup {
  private dir: string = '';
  private timer: number = -1;
  // 初始为「最后一个槽位」→ 第一次备份写 autosave_0
  private slot: number = SLOT_COUNT - 1;
  // 上一份还在写：跳过这次触发（写完后的下一次变更会再排一次），避免并发导出
  private running: boolean = false;
  private abnormal: boolean = false;

  // 页面注入：跳过判据（无未保存改动 / 空文档）与真正的执行体（返回产出字节数，<=0 = 没备成）
  skip: () => boolean = (): boolean => true;
  perform: () => Promise<number> = async (): Promise<number> => 0;

  // ---- 会话锁 ----
  // 返回 true = 上次是异常退出（旧锁还在）
  beginSession(filesDir: string): boolean {
    this.dir = filesDir;
    this.abnormal = this.lockExists();
    try {
      this.ensureDir();
      const lk: SessionLock = new SessionLock();
      lk.at = Date.now();
      this.writeText(this.lockPath(), JSON.stringify(lk));
      hilog.info(0x0000, TAG, '会话锁已打上 上次异常退出=%{public}s',
        this.abnormal ? 'true' : 'false');
    } catch (e) {
      hilog.warn(0x0000, TAG, '写会话锁失败: %{public}s', errText(e));
    }
    return this.abnormal;
  }

  // 正常退出清锁。**不清的后果**：下次启动把这次正常关软件误判成崩溃、弹恢复框。
  endSession(): void {
    try {
      if (fs.accessSync(this.lockPath())) {
        fs.unlinkSync(this.lockPath());
        hilog.info(0x0000, TAG, '会话锁已清除（正常退出）');
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '清会话锁失败: %{public}s', errText(e));
    }
  }

  // 上次是否异常退出（供页面决定要不要弹恢复框）
  abnormalExit(): boolean {
    return this.abnormal;
  }

  // ---- 备份 ----
  backupDir(): string {
    return `${this.dir}/${BACKUP_DIR}`;
  }

  // 备份输入临时文件的完整路径（页面用它写内核的输入）
  inputTmpPath(): string {
    return `${this.dir}/${INPUT_TMP}`;
  }

  // 取下一个轮转槽位的落点（内核直接把项目 3MF 写到这里，省一次「沙箱产出 → 拷贝」，
  // 也避免与保存链路争同一个沙箱产出路径）
  nextSlotPath(): string {
    this.slot = (this.slot + 1) % SLOT_COUNT;
    try {
      this.ensureDir();
    } catch (e) {
      hilog.warn(0x0000, TAG, '创建备份目录失败: %{public}s', errText(e));
    }
    const p: string = `${this.backupDir()}/autosave_${this.slot}.3mf`;
    hilog.info(0x0000, TAG, '本次备份落点 %{public}s', p);
    return p;
  }

  // 丢掉一份产出（超出单份上限时用）
  drop(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '删除超限备份失败 %{public}s: %{public}s', path, errText(e));
    }
  }

  // 找「最新的一份」备份（按文件 mtime）；没有可用备份返回 null
  latest(): BackupInfo | null {
    let best: BackupInfo | null = null;
    if (this.dir.length === 0) {
      return null;
    }
    try {
      const d: string = this.backupDir();
      if (!fs.accessSync(d)) {
        return null;
      }
      for (const nm of fs.listFileSync(d)) {
        if (!/^autosave_\d+\.3mf$/.test(nm)) {
          continue;
        }
        const p: string = `${d}/${nm}`;
        try {
          const st = fs.statSync(p);
          const info: BackupInfo = new BackupInfo();
          info.path = p;
          info.size = st.size;
          info.at = Math.floor(st.mtime * 1000);
          if (best === null || info.at > best.at) {
            best = info;
          }
        } catch (e) {
          // 单个文件读不到（正在写 / 已删）就跳过，不影响其余槽位
          hilog.warn(0x0000, TAG, '读取备份信息失败 %{public}s: %{public}s', p, errText(e));
        }
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '列备份目录失败: %{public}s', errText(e));
    }
    return best;
  }

  // 标记「内容变了」：重置防抖计时（可高频调用，只碰计时器不做 I/O）
  arm(): void {
    if (this.dir.length === 0) {
      return;      // 目录还没准备好（页面未挂载）：忽略，不要排出无意义的定时器
    }
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout((): void => {
      this.timer = -1;
      this.tryBackup();
    }, IDLE_MS);
  }

  private tryBackup(): void {
    if (this.running) {
      // 上一份还在写：等它写完，再排一次（这次变更不能丢）
      hilog.info(0x0000, TAG, '上一份备份未完成，本次推迟');
      this.arm();
      return;
    }
    if (this.skip()) {
      hilog.info(0x0000, TAG, '跳过自动备份（无未保存改动或空文档）');
      return;
    }
    this.running = true;
    const t0: number = Date.now();
    this.perform().then((n: number): void => {
      this.running = false;
      if (n > 0) {
        hilog.info(0x0000, TAG, '自动备份完成 字节=%{public}d 耗时=%{public}dms',
          n, Date.now() - t0);
      } else {
        hilog.warn(0x0000, TAG, '自动备份未产出（已跳过或失败，原因见上方日志）');
      }
    }).catch((e: Object): void => {
      this.running = false;
      hilog.error(0x0000, TAG, '自动备份异常: %{public}s', errText(e));
    });
  }

  // ---- 文件小工具 ----
  private lockPath(): string {
    return `${this.backupDir()}/${LOCK_FILE}`;
  }

  private lockExists(): boolean {
    if (this.dir.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(this.lockPath());
    } catch (e) {
      return false;
    }
  }

  private ensureDir(): void {
    const d: string = this.backupDir();
    if (!fs.accessSync(d)) {
      fs.mkdirSync(d);
    }
  }

  private writeText(path: string, text: string): void {
    const f: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, text);
    } finally {
      fs.closeSync(f);
    }
  }
}

export const autoBackup: AutoBackup = new AutoBackup();
