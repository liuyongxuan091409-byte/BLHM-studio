import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MqttService } from './MqttService';

// =============================================================================
// 打印机存储（SD 卡 / 内建存储）的文件浏览 / 下载 / 删除
//
// 数据来源：FTPS LIST（隐式 990，与上传同一条链路）返回的 **Unix `ls -l` 文本行**，实测形如：
//   -rw-r--r--    1 1002     1002      8815077 Oct 29  2025 1029 车灯改.gcode.3mf
//   drwxr-xr-x    2 1002     1002        16384 Oct 02 18:28 cache
// 解析要点：字段依次是 权限/链接数/uid/gid/大小/月/日/(年 或 时:分)，**之后整段都是文件名**
//（文件名里可能带空格、中文、括号），所以第 8 个字段之后必须原样取剩余串，不能按空格切。
//
// 时间刻意只保留原文（如 "Oct 29  2025" / "Oct 02 18:28"）：服务器时区未知，
// 自行拼成时间戳会错；展示原文反而不会误导。
// =============================================================================

const TAG: string = 'PrinterFiles';
// 单个文件下载上限：打印机上的 .gcode.3mf 常见几十 MB，这里给一个足够宽松但仍有界的上限，
// 避免误点一个超大文件把沙箱撑爆（原生侧超限会中止并删掉半截文件）。
export const DOWNLOAD_MAX_BYTES: number = 512 * 1024 * 1024;

export class RemoteFile {
  name: string = '';
  size: number = 0;
  isDir: boolean = false;
  // LIST 里的时间原文（不转时间戳：服务器时区未知）
  timeText: string = '';
  // 完整远端路径（去掉尾部 '/' 的目录 + 名字），删除/下载直接用
  path: string = '';
}

export class FileListResult {
  ok: boolean = false;
  message: string = '';
  dir: string = '';
  files: RemoteFile[] = [];
}

export class OpResult {
  ok: boolean = false;
  message: string = '';
  // 下载成功时：沙箱里的落点（页面再把它另存到用户选择的位置）
  localPath: string = '';
}

function errText(e: Object): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
}

export class PrinterFiles {
  // 目录 + 文件名 → 完整远端路径（dir 为 '/' 时不产生重复斜杠）
  private static join(dir: string, name: string): string {
    if (dir === '/' || dir.length === 0) {
      return `/${name}`;
    }
    const base: string = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    return `${base}/${name}`;
  }

  // Unix `ls -l` 一行 → RemoteFile；解析不出（total 行、空行、非权限开头）返回 null
  static parseLine(line: string, dir: string): RemoteFile | null {
    const s: string = line.trim();
    if (s.length === 0 || s.startsWith('total ')) {
      return null;
    }
    if (s.charAt(0) !== '-' && s.charAt(0) !== 'd') {
      return null;
    }
    // 取前 8 个字段（权限/链接/uid/gid/大小/月/日/年或时:分），剩下的原样当文件名
    const toks: string[] = [];
    let i: number = 0;
    while (i < s.length && toks.length < 8) {
      while (i < s.length && s.charAt(i) === ' ') {
        i++;
      }
      const start: number = i;
      while (i < s.length && s.charAt(i) !== ' ') {
        i++;
      }
      if (i > start) {
        toks.push(s.substring(start, i));
      }
    }
    if (toks.length < 8) {
      return null;
    }
    while (i < s.length && s.charAt(i) === ' ') {
      i++;
    }
    const name: string = s.substring(i);
    if (name.length === 0) {
      return null;
    }
    const rf: RemoteFile = new RemoteFile();
    rf.name = name;
    rf.isDir = s.charAt(0) === 'd';
    const sz: number = parseInt(toks[4], 10);
    rf.size = isNaN(sz) ? 0 : sz;
    rf.timeText = `${toks[5]} ${toks[6]} ${toks[7]}`;
    rf.path = PrinterFiles.join(dir, name);
    return rf;
  }

  // 列目录：目录在前、文件在后，各自按名字排序（中文/英文混排时按本地比较）
  static async list(dir: string): Promise<FileListResult> {
    const res: FileListResult = new FileListResult();
    res.dir = dir;
    try {
      const json: string = await MqttService.ftpsList(dir);
      const r: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      res.ok = r['ok'] === true;
      const msg: Object = r['message'];
      res.message = typeof msg === 'string' ? msg as string : '';
      const entries: Object = r['entries'];
      if (Array.isArray(entries)) {
        for (const e of entries as Object[]) {
          if (typeof e !== 'string') {
            continue;
          }
          const rf: RemoteFile | null = PrinterFiles.parseLine(e as string, dir);
          if (rf !== null) {
            res.files.push(rf);
          }
        }
      }
      res.files.sort((a: RemoteFile, b: RemoteFile): number => {
        if (a.isDir !== b.isDir) {
          return a.isDir ? -1 : 1;
        }
        return a.name.localeCompare(b.name);
      });
      hilog.info(0x0000, TAG, '列目录 %{public}s ok=%{public}s 条目=%{public}d',
        dir, res.ok ? 'true' : 'false', res.files.length);
    } catch (e) {
      res.ok = false;
      res.message = errText(e);
      hilog.warn(0x0000, TAG, '列目录异常 %{public}s: %{public}s', dir, res.message);
    }
    return res;
  }

  static async remove(path: string): Promise<OpResult> {
    const res: OpResult = new OpResult();
    try {
      const json: string = await MqttService.ftpsRemove(path);
      const r: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      res.ok = r['ok'] === true;
      const msg: Object = r['message'];
      res.message = typeof msg === 'string' ? msg as string : '';
      hilog.info(0x0000, TAG, '删除 %{public}s ok=%{public}s', path, res.ok ? 'true' : 'false');
    } catch (e) {
      res.message = errText(e);
      hilog.warn(0x0000, TAG, '删除异常 %{public}s: %{public}s', path, res.message);
    }
    return res;
  }

  // 下载到 `${filesDir}/downloads/<name>`（**先落沙箱**：原生按路径写文件，
  // 用户选择的目标 URI 拿到的只是 fd，原生侧不认；再由页面用「另存为」把它复制过去）。
  static async download(filesDir: string, remotePath: string, name: string): Promise<OpResult> {
    const res: OpResult = new OpResult();
    if (filesDir.length === 0) {
      res.message = '拿不到应用沙箱目录';
      return res;
    }
    const dir: string = `${filesDir}/downloads`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const safe: string = name.replace(/[\\/:*?"<>|]/g, '_');
      const dest: string = `${dir}/${safe}`;
      const json: string = await MqttService.ftpsDownload(remotePath, dest, DOWNLOAD_MAX_BYTES);
      const r: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      res.ok = r['ok'] === true;
      const msg: Object = r['message'];
      const bytes: Object = r['bytes'];
      const n: number = typeof bytes === 'number' ? bytes as number : 0;
      if (res.ok) {
        res.localPath = dest;
        res.message = `已下载 ${safe}（${Math.round(n / 1024)} KB）`;
      } else {
        res.message = typeof msg === 'string' ? msg as string : '下载失败';
      }
      hilog.info(0x0000, TAG, '下载 %{public}s ok=%{public}s 字节=%{public}d',
        remotePath, res.ok ? 'true' : 'false', n);
    } catch (e) {
      res.message = errText(e);
      hilog.warn(0x0000, TAG, '下载异常 %{public}s: %{public}s', remotePath, res.message);
    }
    return res;
  }
}
