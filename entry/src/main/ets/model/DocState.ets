import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { modelState } from './ModelState';

// =============================================================================
// 「当前工程」文档状态（Phase 4：工程保存 / 打开 / 另存 + 最近文件）
//
// 解决什么问题：以前每次「保存」都必须弹路径选择器，应用里没有「当前文件」概念 ——
// 于是没有覆盖保存、没有最近文件、顶栏永远写着「未命名项目」。
// 这里把「当前工程是谁 / 存到哪 / 有没有未保存改动」收敛成一个单例 + 两份 JSON：
//   · doc_state.json   当前工程的路径、显示名、上次保存时间、保存时的结构摘要
//   · recent_docs.json 最近打开/保存过的文件（最多 RECENT_MAX 条，倒序、同路径去重）
//
// 【脏标记为什么用结构摘要比对】不能用「编辑过就脏」：用户撤销回上次保存的状态时，
// 标记应该自己消失。摘要由 History 在每次入栈/撤销/重做后送来 —— 它本来就算了这个摘要
// （digest），所以这里不额外付任何成本；而「保存/打开」时记一份基准，之后比对即可。
// =============================================================================

const TAG: string = 'DocState';
// 从未保存过时的显示名（与内核工程包里写的标题一致）
export const DOC_DEFAULT_NAME: string = '未命名项目.3mf';
const RECENT_MAX: number = 10;
// 最近文件的**副本**策略上限：单个超过 40MB 就不拷副本（工程 3MF 可能几十 MB，
// 每次保存都拷一份代价太大）；副本总量上限 200MB，超了就只留条目不留副本。
const COPY_MAX_BYTES: number = 40 * 1024 * 1024;
const COPY_TOTAL_MAX: number = 200 * 1024 * 1024;

// 最近文件条目（也是 AppStorage 里给顶栏菜单渲染的类型）
export class RecentDoc {
  path: string = '';
  name: string = '';
  at: number = 0;
  // 沙箱里的副本路径（原文件被移走/删除后仍能打开）；空 = 没做副本
  copyPath: string = '';
  // 文件大小（字节，写条目时记录）
  size: number = 0;
}

// doc_state.json 的形状
interface DocStateJson {
  path: string;
  name: string;
  lastSavedAt: number;
  savedDigest: string;
  dirty: boolean;
}

// recent_docs.json 的形状
interface RecentJson {
  items: RecentDoc[];
}

function errText(e: Object): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
}

// 从路径/URI 取显示名（与 ThreeMfExport.shortName 同一口径，这里独立一份避免模型层依赖服务层）
export function shortName(pathOrUri: string): string {
  let s: string = pathOrUri;
  const q: number = s.indexOf('?');
  if (q >= 0) {
    s = s.substring(0, q);
  }
  const i: number = s.lastIndexOf('/');
  const n: string = i >= 0 ? s.substring(i + 1) : s;
  try {
    return decodeURIComponent(n);
  } catch (e) {
    return n;
  }
}

// 路径 → 8 位十六进制短标签（最近文件副本命名用）。
// 用简单字符串哈希即可：目的只是「不同路径的同名文件不要互相覆盖」，不涉及安全。
function pathTag(p: string): string {
  let h: number = 0;
  for (let i = 0; i < p.length; i++) {
    h = (h * 31 + p.charCodeAt(i)) | 0;
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

export class DocState {
  // 当前工程已保存到的位置（沙箱路径或 picker URI）；空 = 从未保存
  path: string = '';
  // 显示名（不含路径）；空 = 用 DOC_DEFAULT_NAME
  name: string = '';
  // 是否有未保存改动（= 当前结构摘要 ≠ 保存时的摘要）
  dirty: boolean = false;
  lastSavedAt: number = 0;
  // 上次保存/打开时的结构摘要（History.digest 那个口径）
  private savedDigest: string = '';
  private recentsList: RecentDoc[] = [];
  private dir: string = '';

  // ---- 生命周期 ----
  load(filesDir: string): void {
    this.dir = filesDir;
    const st: DocStateJson | null = this.readJson<DocStateJson>(`${filesDir}/doc_state.json`);
    if (st !== null) {
      this.path = st.path !== undefined ? st.path : '';
      this.name = st.name !== undefined ? st.name : '';
      this.lastSavedAt = st.lastSavedAt !== undefined ? st.lastSavedAt : 0;
      this.savedDigest = st.savedDigest !== undefined ? st.savedDigest : '';
      this.dirty = st.dirty === true;
    }
    // 启动瞬间场景是空的：文件内容并不会被自动恢复（恢复只发生在崩溃恢复弹窗里，且走导入）。
    // 此时「当前文件」不能沿用上次的 —— 否则顶栏显示上次打开的文件名、却没有任何内容，
    // 更危险的是按 Ctrl+S 会把空工程直接覆盖回那个文件。这里清掉关联（最近文件列表不动）。
    if (modelState.instances.length === 0) {
      this.path = '';
      this.name = '';
      this.lastSavedAt = 0;
      this.savedDigest = '';
    }
    // 没关联文件时脏标记按「有没有值得保存的内容」重算：启动瞬间还没有模型 → 不该显示未保存
    if (this.path.length === 0) {
      this.dirty = modelState.instances.length > 0;
    }
    const rc: RecentJson | null = this.readJson<RecentJson>(`${filesDir}/recent_docs.json`);
    if (rc !== null && rc.items !== undefined && rc.items.length > 0) {
      const list: RecentDoc[] = [];
      for (const it of rc.items) {
        const r: RecentDoc = new RecentDoc();
        r.path = it.path !== undefined ? it.path : '';
        r.name = it.name !== undefined ? it.name : '';
        r.at = it.at !== undefined ? it.at : 0;
        r.copyPath = it.copyPath !== undefined ? it.copyPath : '';
        r.size = it.size !== undefined ? it.size : 0;
        if (r.path.length > 0) {
          list.push(r);
        }
      }
      this.recentsList = list;
    }
    hilog.info(0x0000, TAG, '载入文档状态: name=%{public}s path=%{public}s dirty=%{public}s 最近=%{public}d',
      this.displayName(), this.path, this.dirty ? 'true' : 'false', this.recentsList.length);
    this.publish();
  }

  // ---- 展示 ----
  displayName(): string {
    return this.name.length > 0 ? this.name : DOC_DEFAULT_NAME;
  }

  recents(): RecentDoc[] {
    return this.recentsList;
  }

  // ---- 保存 / 打开 ----
  // 保存成功：记住落到哪个路径，并把「当前摘要」记成基准（于是 dirty 立刻变 false）
  noteSaved(path: string, digest: string, sizeBytes: number = 0): void {
    this.path = path;
    this.name = shortName(path);
    this.lastSavedAt = Date.now();
    this.savedDigest = digest;
    this.dirty = false;
    this.addRecent(path, this.name, sizeBytes);
    this.persist();
    this.publish();
    hilog.info(0x0000, TAG, '已保存: name=%{public}s path=%{public}s', this.name, path);
  }

  // 打开工程：当前文件就是它 —— 不脏、路径记下来，之后「保存」直接覆盖它
  noteOpened(path: string, digest: string, sizeBytes: number = 0): void {
    this.path = path;
    this.name = shortName(path);
    this.lastSavedAt = 0;
    this.savedDigest = digest;
    this.dirty = false;
    this.addRecent(path, this.name, sizeBytes);
    this.persist();
    this.publish();
    hilog.info(0x0000, TAG, '已打开: name=%{public}s path=%{public}s', this.name, path);
  }

  // 不关联任何文件（新建工程 / 导入非工程文件）。
  // 脏标记与 computeDirty 同一口径：**有对象才算有内容要保存**。
  // 不能写死 true —— 「新建工程」清空后是空文档，写死就会立刻亮「未保存」，
  // 关窗时还会为一个空工程弹「要先保存吗」（实测踩到）。
  noteUntitled(): void {
    this.path = '';
    this.name = '';
    this.lastSavedAt = 0;
    this.savedDigest = '';
    this.dirty = modelState.instances.length > 0;
    this.persist();
    this.publish();
  }

  // History 每次入栈/撤销/重做后送来的「当前结构摘要」。
  // 判脏规则（两条，缺一条就会出现假阳性）：
  //   · 已关联文件 → 比摘要：与保存时一致就不脏（撤销回保存点会自动清掉标记）
  //   · 还没关联文件 → 看有没有「值得保存的内容」（有没有对象）。
  //     为什么不是比摘要：启动时参数/预设初始化也会产生一次「编辑落定」（摘要 ≠ 空的基准），
  //     照摘要比就会一开app就亮「未保存」，而空工程其实没什么可保存的。
  noteChange(digest: string): void {
    const d: boolean = this.computeDirty(digest);
    if (d === this.dirty) {
      return;
    }
    this.dirty = d;
    this.persist();
    this.publish();
    hilog.info(0x0000, TAG, '脏标记变化: dirty=%{public}s（有文件=%{public}s 对象=%{public}d）',
      d ? 'true' : 'false', this.path.length > 0 ? 'true' : 'false', modelState.instances.length);
  }

  private computeDirty(digest: string): boolean {
    if (this.path.length === 0) {
      return modelState.instances.length > 0;
    }
    return digest !== this.savedDigest;
  }

  // 重算一次（界面重建/启动读盘后用，规则同上）
  refreshDirty(): void {
    this.noteChange('');
  }

  // ---- 最近文件 ----
  //
  // 【为什么还要在沙箱里放副本】最近文件只记原路径的话，用户把原文件移走/改名/删掉之后，
  // 点「最近打开」就是一个打不开的死条目。这里在 `${filesDir}/recent/` 放一份副本，
  // 打开时**优先用副本** —— 原文件怎么动都不影响。
  // 代价是沙箱会多占空间，所以有两条上限（见文件头的 COPY_MAX_BYTES / COPY_TOTAL_MAX）：
  //   · 单个文件 > 40MB 不拷（工程 3MF 可能几十 MB，每次保存都拷一份不划算）；
  //   · 副本总量 > 200MB 时新条目不再拷（老副本保留，条目照记）。
  // 条目被挤出/移除/清空时，连带删掉它的副本，避免沙箱里堆垃圾。
  private recentsDir(): string {
    return `${this.dir}/recent`;
  }

  private ensureRecentsDir(): boolean {
    if (this.dir.length === 0) {
      return false;
    }
    const d: string = this.recentsDir();
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d);
      }
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, '创建 recent 目录失败: %{public}s', errText(e));
      return false;
    }
  }

  // 副本文件名：路径哈希前缀 + 净化过的文件名（避免不同目录下的同名文件互相覆盖）
  private copyPathFor(path: string, name: string): string {
    const safe: string = name.replace(/[\\/:*?"<>|]/g, '_');
    return `${this.recentsDir()}/${pathTag(path)}_${safe}`;
  }

  private copyTotalBytes(): number {
    let sum: number = 0;
    for (const r of this.recentsList) {
      if (r.copyPath.length > 0) {
        sum += r.size;
      }
    }
    return sum;
  }

  private addRecent(path: string, name: string, sizeBytes: number): void {
    const kept: RecentDoc[] = [];
    for (const r of this.recentsList) {
      if (r.path !== path) {
        kept.push(r);
      }
    }
    const head: RecentDoc = new RecentDoc();
    head.path = path;
    head.name = name;
    head.at = Date.now();
    head.size = sizeBytes > 0 ? sizeBytes : this.fileSize(path);
    head.copyPath = this.makeRecentCopy(path, name, head.size);
    kept.unshift(head);
    // 超出上限的条目连同它的副本一起丢掉
    const dropped: RecentDoc[] = kept.slice(RECENT_MAX);
    this.recentsList = kept.slice(0, RECENT_MAX);
    for (const d of dropped) {
      this.deleteCopy(d);
    }
    this.persistRecents();
  }

  // 做副本；不需要/失败都返回空串（调用方据此回落原路径）
  private makeRecentCopy(path: string, name: string, sizeBytes: number): string {
    if (sizeBytes <= 0 || sizeBytes > COPY_MAX_BYTES) {
      hilog.info(0x0000, TAG, '跳过最近文件副本（大小=%{public}d 超限或未知）: %{public}s',
        sizeBytes, name);
      return '';
    }
    if (this.copyTotalBytes() + sizeBytes > COPY_TOTAL_MAX) {
      hilog.warn(0x0000, TAG, '跳过最近文件副本（副本总量将超 200MB）: %{public}s', name);
      return '';
    }
    if (!this.ensureRecentsDir()) {
      return '';
    }
    const dst: string = this.copyPathFor(path, name);
    try {
      fs.copyFileSync(path, dst);
      hilog.info(0x0000, TAG, '最近文件副本已就绪: %{public}s（%{public}d 字节）', dst, sizeBytes);
      return dst;
    } catch (e) {
      hilog.warn(0x0000, TAG, '最近文件副本失败 %{public}s: %{public}s', name, errText(e));
      return '';
    }
  }

  private deleteCopy(r: RecentDoc): void {
    if (r.copyPath.length === 0) {
      return;
    }
    try {
      if (fs.accessSync(r.copyPath)) {
        fs.unlinkSync(r.copyPath);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, '删除副本失败 %{public}s: %{public}s', r.copyPath, errText(e));
    }
  }

  private fileSize(path: string): number {
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  // 打开该最近条目时应该用哪个路径：优先副本（原文件被移走也能开），副本不存在再回落原路径
  openPathFor(r: RecentDoc): string {
    if (r.copyPath.length > 0) {
      try {
        if (fs.accessSync(r.copyPath)) {
          return r.copyPath;
        }
      } catch (e) {
        // 回落原路径
      }
    }
    return r.path;
  }

  removeRecent(path: string): void {
    const kept: RecentDoc[] = [];
    for (const r of this.recentsList) {
      if (r.path === path) {
        this.deleteCopy(r);
      } else {
        kept.push(r);
      }
    }
    this.recentsList = kept;
    this.persistRecents();
    this.publish();
  }

  clearRecents(): void {
    for (const r of this.recentsList) {
      this.deleteCopy(r);
    }
    this.recentsList = [];
    this.persistRecents();
    this.publish();
    hilog.info(0x0000, TAG, '已清空最近文件（含副本）');
  }

  // ---- 落盘 / 广播 ----
  private persist(): void {
    if (this.dir.length === 0) {
      return;
    }
    const j: DocStateJson = {
      path: this.path,
      name: this.name,
      lastSavedAt: this.lastSavedAt,
      savedDigest: this.savedDigest,
      dirty: this.dirty
    };
    this.writeJson(`${this.dir}/doc_state.json`, JSON.stringify(j));
  }

  private persistRecents(): void {
    if (this.dir.length === 0) {
      return;
    }
    const j: RecentJson = { items: this.recentsList };
    this.writeJson(`${this.dir}/recent_docs.json`, JSON.stringify(j));
  }

  // 顶栏（名称 + 脏标记）与文档菜单（最近文件）都从这里取，避免各自持一份状态
  publish(): void {
    AppStorage.setOrCreate<string>('docName', this.displayName());
    AppStorage.setOrCreate<string>('docPath', this.path);
    AppStorage.setOrCreate<boolean>('docDirty', this.dirty);
    AppStorage.setOrCreate<RecentDoc[]>('docRecents', this.recentsList);
  }

  private readJson<T>(path: string): T | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const text: string = fs.readTextSync(path);
      if (text.length === 0) {
        return null;
      }
      return JSON.parse(text) as T;
    } catch (e) {
      hilog.warn(0x0000, TAG, '读取失败 %{public}s: %{public}s', path, errText(e));
      return null;
    }
  }

  private writeJson(path: string, text: string): void {
    try {
      const f: fs.File = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, '写入失败 %{public}s: %{public}s', path, errText(e));
    }
  }
}

export const docState: DocState = new DocState();
