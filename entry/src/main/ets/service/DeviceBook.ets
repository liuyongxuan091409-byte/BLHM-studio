import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';

// =============================================================================
// 「我的打印机」设备簿（P1-10：记住打印机 + 设备列表）
//
// 解决什么问题：MQTT 的访问码只活在内存里，应用一重启（或重装）就得重新扫描 / 手填 IP + 访问码。
// 这里把「连过的打印机」连同访问码落盘，下次进来一键直连，不必再输入。
//
// 【访问码为什么也存】Bambu 的局域网访问码是连接凭据，不存就无法"一键连接"（桌面版同样存在
// 自己的配置里）。文件落在应用沙箱 `${filesDir}/devices.json`，只有本应用可读；
// 用户可从设备列表里删除某台（连带删掉它的访问码）。
//
// 与 SSDP 的关系：SSDP 发现的是"此刻在网上的机器"，设备簿记的是"我用过的机器"——
// 后者在机器离线/换网段时仍然能列出来（连接失败会给出原生侧的具体原因），
// 也能让用户给它起别名（默认显示机型名）。
// =============================================================================

const TAG: string = 'DeviceBook';
const MAX_DEVICES: number = 8;

export class KnownDevice {
  serial: string = '';
  ip: string = '';
  // SSDP 报的机型友好名（如 "X1"）；空 = 未知
  model: string = '';
  // 用户起的别名（空 = 用机型名）
  alias: string = '';
  // 局域网访问码（一键连接要用）
  accessCode: string = '';
  lastConnectedAt: number = 0;
}

class BookJson {
  items: KnownDevice[] = [];
}

function errText(e: Object): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
}

export class DeviceBook {
  private dir: string = '';
  private items: KnownDevice[] = [];

  load(filesDir: string): void {
    this.dir = filesDir;
    this.items = [];
    if (filesDir.length === 0) {
      return;
    }
    const p: string = this.path();
    try {
      if (!fs.accessSync(p)) {
        return;
      }
      const text: string = fs.readTextSync(p);
      if (text.length === 0) {
        return;
      }
      const j: BookJson = JSON.parse(text) as BookJson;
      if (j.items === undefined) {
        return;
      }
      for (const it of j.items) {
        const d: KnownDevice = new KnownDevice();
        d.serial = it.serial ?? '';
        d.ip = it.ip ?? '';
        d.model = it.model ?? '';
        d.alias = it.alias ?? '';
        d.accessCode = it.accessCode ?? '';
        d.lastConnectedAt = it.lastConnectedAt ?? 0;
        if (d.serial.length > 0 && d.ip.length > 0) {
          this.items.push(d);
        }
      }
      hilog.info(0x0000, TAG, '设备簿已载入 %{public}d 台', this.items.length);
    } catch (e) {
      hilog.warn(0x0000, TAG, '设备簿读取失败（按空处理）: %{public}s', errText(e));
    }
  }

  list(): KnownDevice[] {
    return this.items;
  }

  // 最近连接的那台（启动/回页自动重连用）；没有则 null
  last(): KnownDevice | null {
    let best: KnownDevice | null = null;
    for (const d of this.items) {
      if (best === null || d.lastConnectedAt > best.lastConnectedAt) {
        best = d;
      }
    }
    return best;
  }

  // 显示名：别名 > 机型 > 序列号（绝不显示空串）
  displayName(d: KnownDevice): string {
    if (d.alias.length > 0) { return d.alias; }
    if (d.model.length > 0) { return d.model; }
    return d.serial;
  }

  // 连接成功后调用：按 serial upsert，刷新 ip/机型/访问码/时间，并按时间倒序
  remember(ip: string, serial: string, model: string, accessCode: string): void {
    if (serial.length === 0 || ip.length === 0 || accessCode.length === 0) {
      return;      // 缺关键信息不记（记了也连不上）
    }
    let hit: KnownDevice | null = null;
    for (const d of this.items) {
      if (d.serial === serial) {
        hit = d;
        break;
      }
    }
    if (hit === null) {
      hit = new KnownDevice();
      hit.serial = serial;
      this.items.push(hit);
    }
    hit.ip = ip;
    // 机型偶尔取不到（SSDP 没回）→ 保留上次已知的，别用空串覆盖
    if (model.length > 0) {
      hit.model = model;
    }
    hit.accessCode = accessCode;
    hit.lastConnectedAt = Date.now();
    // 时间倒序 + 上限（超出丢最旧）
    this.items.sort((a: KnownDevice, b: KnownDevice): number => b.lastConnectedAt - a.lastConnectedAt);
    if (this.items.length > MAX_DEVICES) {
      this.items = this.items.slice(0, MAX_DEVICES);
    }
    this.persist();
    hilog.info(0x0000, TAG, '设备簿已记住 %{public}s（%{public}s）共 %{public}d 台',
      serial, ip, this.items.length);
  }

  rename(serial: string, alias: string): void {
    for (const d of this.items) {
      if (d.serial === serial) {
        d.alias = alias;
        this.persist();
        return;
      }
    }
  }

  // 删除某台（连带它的访问码）；删的是当前连接的那台也不主动断开 —— 断开与否由用户决定
  remove(serial: string): void {
    const kept: KnownDevice[] = [];
    for (const d of this.items) {
      if (d.serial !== serial) {
        kept.push(d);
      }
    }
    this.items = kept;
    this.persist();
  }

  private path(): string {
    return `${this.dir}/devices.json`;
  }

  private persist(): void {
    if (this.dir.length === 0) {
      return;
    }
    try {
      const j: BookJson = new BookJson();
      j.items = this.items;
      const f: fs.File = fs.openSync(this.path(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(j));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, '设备簿写入失败: %{public}s', errText(e));
    }
  }
}

export const deviceBook: DeviceBook = new DeviceBook();
