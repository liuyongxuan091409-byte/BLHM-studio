import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Theme } from '../common/Theme';
import { CalibAssets, CalibItem } from '../service/CalibAssets';
import { Calib3mf, CalibPrepResult } from '../service/Calib3mf';
import { CalibRun, CalibRunStore } from '../service/CalibRunStore';
import { SlicerService } from '../service/SlicerService';
import { SliceParamStore } from '../service/SliceParamStore';
import { AppLog } from '../service/AppLog';
import { promptAction } from '@kit.ArkUI';
import { PresetIndexSelectResult, PresetOptions } from '../model/SliceModels';
import { PresetPersist, PresetSnapshot } from '../service/PresetPersist';
import { MqttService } from '../service/MqttService';
import { KProfileEntry, KProfileParse, KProfileTable } from '../service/KProfileParse';

const TAG: string = 'CalibRun';

// 切片进度（C++ worker 线程投递，见 SlicerService.sliceJsonWithProgress）
interface CalibProgressJson {
  stage?: string;
  pct?: number;
  msg?: string;
}

// 切片结果（与 Index.ets 读的是同一份字段）
interface CalibSliceResultJson {
  ok?: boolean;
  layers?: number;
  filamentUsedG?: number;
  estimatedPrintTime?: string;
  message?: string;
}

// 校准页：选一种校准 → 把随包模型落到沙箱 → 用当前预设切片 → 显示层数/耗材/时长。
// 切完还能录入打印效果（挑试块 / 填 K 值），把结论写进当前耗材预设。
// 设备侧下发与 K 值回写要连打印机，见页面说明。
@Component
export struct CalibrationPanel {
  // 结果放在模块级台账里：切完会跳到预览，回来时本组件重建，@State 会归零
  @State private results: CalibRun[] = CalibRunStore.all().slice();
  @State private running: boolean = false;
  @State private curId: string = '';
  @State private pct: number = 0;
  @State private stageMsg: string = '';
  @State private errText: string = '';
  // 结果录入：当前挑中的试块（"<itemId>|<对象名>"）、PA 手工输入的 K、应用后的说明
  @State private pickedBlock: string = '';
  @State private paText: string = '';
  @State private applyNote: string = '';
  @State private noteItem: string = '';

  // 校准作用域：结果与写回都归属「哪一支耗材预设」。试块印记（流量%/PA K）只对切片时
  // 用的那支耗材成立，换预设后材料/温度/挤出特性都变了，把旧结果当新预设的结果用就是张冠李戴。
  @StorageLink('globalFilamentName') @Watch('onCurFilChange') curFilament: string = '';
  @State private calibFil: string = '';

  // 右上角耗材选择器（与准备页同源同步）：
  // 候选来自内核 kind=2 候选表（顺序即内核下标顺序），选中后**按索引下发给内核**，
  // 所以「在校准页换耗材」就是「在准备页换耗材」——同一份内核配置、同一份持久化快照，
  // 回到准备页时参数面板重建后按内核 selectedIndex 回填，天然一致。
  @State private filMenuShown: boolean = false;
  @State private filCandidates: string[] = [];

  // 设备侧 K 值表（只读）：向打印机要它自己的 K 值表看一眼，**不写任何东西**。
  // 协议形状还没定案（没有 extrusion_cali_get 的应答原文），所以这里只做「取原文 → 解析 → 展示」，
  // 认不出来就如实说认不出来，不猜、不假装读到了。
  @State private devKBusy: boolean = false;
  @State private devKEntries: KProfileEntry[] = [];
  @State private devKNote: string = '';

  // 切成功后的回调：由 Index 注入，负责切到「预览 · 切片路径」
  onShowSlicePath: () => void = () => {};

  private items: CalibItem[] = CalibAssets.items();

  // 当前作用域：用户没在顶部耗材条里另外指一支，就跟随参数面板选中的耗材
  private scopeFil(): string {
    return this.calibFil !== '' ? this.calibFil : this.curFilament;
  }

  // 参数面板换了耗材：作用域跟着走，避免停留在上一支上（旧结果仍在台账里，可点回看）
  private onCurFilChange(): void {
    this.calibFil = '';
    this.pickedBlock = '';
    this.noteItem = '';
    this.applyNote = '';
  }

  // 作用域候选：当前耗材 + 台账里出现过的耗材（别的预设的结果仍可回看/补写）
  private filamentNames(): string[] {
    const out: string[] = [];
    if (this.curFilament !== '') {
      out.push(this.curFilament);
    }
    const seen: string[] = CalibRunStore.filaments();
    for (let i = 0; i < seen.length; i++) {
      if (out.indexOf(seen[i]) < 0) {
        out.push(seen[i]);
      }
    }
    return out;
  }

  // 预设全名很长（"Bambu PLA Basic @BBL A1 mini"），条上只留材料段
  private shortFil(name: string): string {
    const at: number = name.indexOf('@');
    const s: number = at > 0 ? at : name.length;
    return name.substring(0, s).trim();
  }

  // 进页面先用内核真值校正一次「当前耗材」：参数面板发布的是它保存时的值，
  // 若本次会话在别处（准备页）换过耗材，这里以内核为准，避免选择器显示旧名。
  aboutToAppear(): void {
    // 解析器自检：不需要打印机，进页面就把夹具结果写进日志，方便排查"为什么没认出 K 值"
    const selfTest: string = KProfileParse.selfTest();
    hilog.info(0x0000, TAG, '%{public}s', selfTest);
    AppLog.push(`[校准] ${selfTest}`);
    const opts: PresetOptions | undefined = this.fetchFilOptions();
    if (opts === undefined) {
      return;
    }
    if (opts.selectedName !== '' && opts.selectedName !== this.curFilament) {
      hilog.info(0x0000, TAG, '校准页校正当前耗材 发布值=%{public}s 内核=%{public}s',
        this.curFilament, opts.selectedName);
      AppStorage.setOrCreate<string>('globalFilamentName', opts.selectedName);
      const fd: string = this.filesDir();
      if (fd !== '') {
        SliceParamStore.ensureFilamentOverrides(fd, opts.selectedName);
      }
    }
  }

  // 取内核耗材候选表（kind=2）。解析或内核失败返回 undefined（不吞异常、不编造列表）。
  private fetchFilOptions(): PresetOptions | undefined {
    try {
      const opts: PresetOptions = JSON.parse(SlicerService.presetOptions(2)) as PresetOptions;
      if (!opts.ok) {
        hilog.warn(0x0000, TAG, '耗材候选表内核返回失败: %{public}s', opts.message);
        return undefined;
      }
      return opts;
    } catch (e) {
      hilog.error(0x0000, TAG, '耗材候选表解析失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return undefined;
    }
  }

  // 打开耗材菜单：每次打开都重新取候选（内核会随机型变），只展示名字、下发只用下标。
  // 用 bindMenu 的**受控**重载：本机实测「点击隐式触发 bindMenu」不响应（见 TopBar 同处注释）。
  private openFilMenu(): void {
    const opts: PresetOptions | undefined = this.fetchFilOptions();
    if (opts === undefined || opts.items.length === 0) {
      promptAction.showToast({ message: '耗材候选还没就绪，请稍后再试' });
      return;
    }
    const names: string[] = [];
    for (let i = 0; i < opts.items.length; i++) {
      names.push(opts.items[i].name);
    }
    this.filCandidates = names;
    // 外部点空白关掉菜单后 isShow 仍为 true，直接置 true 会“点不开”：先 false 再下一拍 true
    this.filMenuShown = false;
    setTimeout(() => { this.filMenuShown = true; }, 16);
  }

  // 在最新候选表里按名定位下标；不在了返回 -1（菜单是异步关闭的，期间候选可能换代，绝不用旧下标下发）
  private indexOfFil(opts: PresetOptions, name: string): number {
    for (let i = 0; i < opts.items.length; i++) {
      if (opts.items[i].name === name) {
        return i;
      }
    }
    return -1;
  }

  // 选中一支耗材：按索引切内核 → 成功才同步覆盖桶/持久化快照/全局发布
  private pickFilament(name: string): void {
    this.filMenuShown = false;
    if (name === '' || name === this.curFilament) {
      return;
    }
    const opts: PresetOptions | undefined = this.fetchFilOptions();
    if (opts === undefined) {
      promptAction.showToast({ message: '耗材候选表不可用' });
      return;
    }
    const idx: number = this.indexOfFil(opts, name);
    if (idx < 0) {
      promptAction.showToast({ message: `「${this.shortFil(name)}」不适用于当前机型` });
      return;
    }
    try {
      const res: PresetIndexSelectResult =
        JSON.parse(SlicerService.selectPresetByIndex(2, idx)) as PresetIndexSelectResult;
      if (!res.ok) {
        hilog.error(0x0000, TAG, '耗材切换未被内核接受: %{public}s', res.message);
        promptAction.showToast({
          message: res.rolledBack ? '该耗材不适用于当前机型' : `切换耗材失败：${res.message}`
        });
        return;
      }
      // 内核回读的真实选中写回内存目录（打印弹窗/机型对照读的就是它）
      SlicerService.updateSelected(res.selected.printer, res.selected.process, res.selected.filament);
      this.applyFilamentSwitch(res.selected.filament);
    } catch (e) {
      hilog.error(0x0000, TAG, '切换耗材异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      promptAction.showToast({ message: '切换耗材失败（返回解析异常）' });
    }
  }

  // 内核已切成功后的收尾：覆盖桶指向新耗材、持久化快照改写、全局发布。
  // 为什么必须改快照：参数面板回到准备页会重建并 restorePresetState()，
  // 若快照里还是旧耗材，它会把内核刚切好的耗材又改回去（看起来“校准页选完没生效”）。
  private applyFilamentSwitch(name: string): void {
    const fd: string = this.filesDir();
    if (fd !== '') {
      SliceParamStore.ensureFilamentOverrides(fd, name);
      const snap: PresetSnapshot | undefined = PresetPersist.load(fd);
      if (snap !== undefined) {
        snap.filament = name;
        snap.savedAt = new Date().toLocaleString();
        if (PresetPersist.save(fd, snap)) {
          PresetPersist.log(fd, `校准页切耗材 耗=${name}（快照已改写，准备页重建后一致）`);
        }
      } else {
        PresetPersist.log(fd, `校准页切耗材 耗=${name}（无历史快照，跳过快照改写）`);
      }
    }
    AppStorage.setOrCreate<string>('globalFilamentName', name);
    // 换耗材 = 结果归属跟着换：清掉上一支的录入中间态
    this.calibFil = '';
    this.pickedBlock = '';
    this.noteItem = '';
    this.applyNote = '';
    this.errText = '';
    hilog.info(0x0000, TAG, '校准页已切换切片耗材 -> %{public}s（与准备页同源）', name);
  }

  // 从打印机读一次设备侧 K 值表（**只读**）。
  // 流程：发请求（原生侧连发两次做热身）→ 等应答落进留存缓冲 → 取原文 → ArkTS 侧解析。
  // 为什么要等 1.2s：MQTT 是异步的，立刻取只会拿到空数组，那样 UI 会把"还没回"误报成"没有 K 值"。
  private readDeviceK(): void {
    if (this.devKBusy) {
      return;
    }
    this.devKBusy = true;
    this.devKEntries = [];
    this.devKNote = '已发送只读查询，等待打印机应答…';
    MqttService.requestKProfiles().then((r: string) => {
      let ok: boolean = false;
      try {
        const o: Record<string, Object> = JSON.parse(r) as Record<string, Object>;
        ok = o['ok'] === true;
      } catch (e) {
        ok = false;
      }
      if (!ok) {
        this.devKBusy = false;
        this.devKNote = '请求没发出去：先连上打印机（设备页），并确认打印机已开 LAN 模式 / 开发者模式';
        return;
      }
      setTimeout(() => {
        MqttService.getCaliRaw().then((raw: string) => {
          const table: KProfileTable = KProfileParse.parseRawList(raw);
          this.devKEntries = table.entries;
          if (table.entries.length > 0) {
            this.devKNote = `收到 ${table.reports} 条校准报文，解析出 ${table.entries.length} 条 K 值`
              + (table.nozzles.length > 0 ? `（喷嘴 ${table.nozzles.join(' / ')}）` : '');
          } else if (table.reports > 0) {
            this.devKNote = `收到 ${table.reports} 条校准报文，但结构还没认出来（原文已存日志，可用于定案）`;
          } else {
            this.devKNote = '没收到校准应答：打印机未连接 / 旧固件不支持该命令 / 未开开发者模式';
          }
          hilog.info(0x0000, TAG, '设备侧K值 报文=%{public}d 条目=%{public}d',
            table.reports, table.entries.length);
          AppLog.push(`[校准] 设备侧K值 报文=${table.reports} 条目=${table.entries.length}`);
          this.devKBusy = false;
        }).catch((e: Object) => {
          this.devKBusy = false;
          this.devKNote = '取原始报文失败（原生侧异常）';
          hilog.error(0x0000, TAG, '取校准原文失败: %{public}s', JSON.stringify(e));
        });
      }, 1200);
    }).catch((e: Object) => {
      this.devKBusy = false;
      this.devKNote = '请求失败（原生侧异常）';
      hilog.error(0x0000, TAG, '请求K值表失败: %{public}s', JSON.stringify(e));
    });
  }

  private filesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx === undefined ? '' : ctx.filesDir;
  }

  // 只看当前作用域耗材名下的结果：别的预设的结果不在这里显形
  private resultOf(id: string): CalibRun | undefined {
    const scope: string = this.scopeFil();
    for (let i = 0; i < this.results.length; i++) {
      if (this.results[i].id === id && this.results[i].filament === scope) {
        return this.results[i];
      }
    }
    return undefined;
  }

  private statusOf(item: CalibItem): string {
    if (!item.available) {
      return '未开放';
    }
    const r: CalibRun | undefined = this.resultOf(item.id);
    if (r === undefined) {
      return this.running && this.curId === item.id ? `切片中 ${this.pct}%` : '待校准';
    }
    if (!r.ok) {
      return '失败';
    }
    return `${r.layers} 层 · ${r.grams.toFixed(1)} g`;
  }

  // 一次校准：落地模型 → 取当前参数 → 切片 → 落结果。全程只读写沙箱，不连打印机。
  private run(item: CalibItem): void {
    if (this.running || !item.available) {
      return;
    }
    const fd: string = this.filesDir();
    if (fd === '') {
      this.errText = '拿不到应用沙箱目录，无法落地校准模型';
      return;
    }
    // 切片读的是「当前选中耗材」的工艺参数。若结果归属被指到别的预设，切出来的是 A 的参数，
    // 记到 B 名下就是张冠李戴 —— 直接拦下，让用户先去参数面板把耗材切过来。
    const scope: string = this.scopeFil();
    if (scope !== '' && this.curFilament !== '' && scope !== this.curFilament) {
      this.errText = `切片用的是当前耗材「${this.curFilament}」。要校准「${scope}」，`
        + '请先在参数面板的耗材下拉切到它，再回来重切（否则参数与结果对不上）。';
      promptAction.showToast({ message: '耗材对不上：请先把参数面板的耗材切成目标耗材' });
      return;
    }
    this.running = true;
    this.curId = item.id;
    this.pct = 0;
    this.stageMsg = '准备模型…';
    this.errText = '';
    hilog.info(0x0000, TAG, '开始校准 id=%{public}s 模型=%{public}s', item.id, item.file);

    this.prepareAndSlice(item, fd).catch((e: Error) => {
      this.finish(item, false, '校准流程异常: ' + e.message, 0);
    });
  }

  // 落模型 → 摆位归一化 → 切片（把回调式切片包成 Promise，便于串行）
  private async prepareAndSlice(item: CalibItem, fd: string): Promise<void> {
    const ready: boolean = await SlicerService.ensurePresets(fd);
    if (!ready) {
      hilog.warn(0x0000, TAG, '预设未就绪，本次用内核默认参数 id=%{public}s', item.id);
    }
    const modelPath: string = CalibAssets.ensureModel(item, fd);
    if (modelPath === '') {
      this.finish(item, false, '模型落地失败（rawfile 读取或写沙箱失败）', 0);
      return;
    }
    // 摆位归一化：拓竹这套校准 3MF 摆在打印板左下角，直接切会被排除区校验拒掉
    this.stageMsg = '摆位归一化…';
    this.pct = 2;
    const prep: CalibPrepResult = await Calib3mf.prepare(modelPath, `${fd}/calib/n_${item.id}.3mf`);
    const slicePath: string = prep.path !== '' ? prep.path : modelPath;
    if (prep.path === '') {
      hilog.warn(0x0000, TAG, '归一化未产出，回退原始文件 id=%{public}s', item.id);
    }
    // 工艺参数按模型自带的 project_settings（层高/线宽/墙生成器）：这份自动 PA 线是
    // 0.2mm 高的 0.4mm 细线，只有 arachne 变线宽 + 0.2 层高才切得出来（用界面预设的
    // 0.16 层高 + 经典墙生成器，内核报 empty initial layer）
    let paramsJson: string = SliceParamStore.collectParamsJson();
    paramsJson = SliceParamStore.mergeExtra(paramsJson, prep.overrides);
    const outPath: string = `${fd}/calib/out_${item.id}.gcode`;
    this.stageMsg = '切片中…';
    const t0: number = Date.now();
    const rj: string = await new Promise<string>((resolve: (v: string) => void) => {
      SlicerService.sliceJsonWithProgress(slicePath, paramsJson, outPath,
        (pj: string) => { this.onProgress(pj); },
        (r: string) => { resolve(r); });
    });
    this.onSliceDone(item, rj, Date.now() - t0, outPath, slicePath, prep.blocks);
  }

  private onProgress(pj: string): void {
    try {
      const p: CalibProgressJson = JSON.parse(pj) as CalibProgressJson;
      if (p.pct !== undefined) {
        this.pct = Math.floor(p.pct);
      }
      const stage: string = p.stage !== undefined ? p.stage : '';
      const msg: string = p.msg !== undefined ? p.msg : '';
      this.stageMsg = msg !== '' ? msg : stage;
    } catch (e) {
      hilog.warn(0x0000, TAG, '进度解析失败: %{public}s', pj);
    }
  }

  private onSliceDone(item: CalibItem, rj: string, ms: number,
                      outPath: string, modelPath: string, blocks: string): void {
    try {
      const r: CalibSliceResultJson = JSON.parse(rj) as CalibSliceResultJson;
      const ok: boolean = r.ok === true;
      const layers: number = r.layers !== undefined ? r.layers : 0;
      const grams: number = r.filamentUsedG !== undefined ? r.filamentUsedG : 0;
      const est: string = r.estimatedPrintTime !== undefined ? r.estimatedPrintTime : '';
      const msg: string = r.message !== undefined ? r.message : '';
      this.finish(item, ok, msg, ms, layers, grams, est, blocks);
      if (ok) {
        this.showSlicePath(outPath, modelPath);
      }
    } catch (e) {
      this.finish(item, false, '结果解析失败: ' + rj, ms);
    }
  }

  // 切成功后：把产物提升为「当前切片路径」（预览页固定读 filesDir/output.gcode），
  // 自增 gcodeRevision 让预览重新加载，再请 Index 切到「预览 · 切片路径」。
  private showSlicePath(gcodePath: string, modelPath: string): void {
    const fd: string = this.filesDir();
    if (fd === '') {
      return;
    }
    try {
      fs.copyFileSync(gcodePath, `${fd}/output.gcode`);
    } catch (e) {
      hilog.error(0x0000, TAG, '提升为 output.gcode 失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return;
    }
    AppStorage.setOrCreate<string>('sliceModelPath', modelPath);
    // 校准产物也能直接打印：output.gcode 正是这次切出来的试块，模型文件就是校准 3MF。
    // 打印入口（Index.openPrintDialog / ThreeMfExport 打印包）原本以「准备页有对象」为前提，
    // 校准页没有对象 —— 用这个标记放行，并在下一次正常切片时清掉（见 Index.startSlice）。
    AppStorage.setOrCreate<boolean>('calibPrintReady', true);
    hilog.info(0x0000, TAG, '已标记校准产物可打印 model=%{public}s', modelPath);
    const rev: number = AppStorage.get<number>('gcodeRevision') ?? 0;
    AppStorage.setOrCreate<number>('gcodeRevision', rev + 1);
    hilog.info(0x0000, TAG, '已切到切片路径预览 model=%{public}s', modelPath);
    this.onShowSlicePath();
  }

  private finish(item: CalibItem, ok: boolean, msg: string, ms: number,
                layers: number = 0, grams: number = 0, est: string = '', blocks: string = ''): void {
    const r: CalibRun = new CalibRun(item.id, ok, layers, grams, est, msg, ms, blocks, this.scopeFil());
    CalibRunStore.put(r);
    // 台账是唯一真值：按 (校准项, 耗材) 覆盖后整份取回，面板里不再另维护一份过滤规则
    this.results = CalibRunStore.all().slice();
    this.running = false;
    this.curId = '';
    this.pct = 0;
    this.stageMsg = '';
    if (!ok) {
      this.errText = msg !== '' ? msg : '切片失败（内核未返回原因）';
    }
    hilog.info(0x0000, TAG,
      '校准结束 id=%{public}s ok=%{public}s 层=%{public}d 耗材=%{public}sg 用时=%{public}dms msg=%{public}s',
      item.id, ok ? 'true' : 'false', layers, grams.toFixed(1), ms, msg);
    this.writeDiag(item, r);
  }

  // 三通道之一：落一份可被 hdc 拉走的诊断文件（与既有 gcode_diag 同目录）
  private writeDiag(item: CalibItem, r: CalibRun): void {
    const fd: string = this.filesDir();
    if (fd === '') {
      return;
    }
    const lines: string[] = [];
    lines.push(`[calib] id=${item.id} file=${item.file} ok=${r.ok}`);
    lines.push(`[calib] layers=${r.layers} grams=${r.grams.toFixed(2)} est=${r.est} ms=${r.ms}`);
    if (r.msg !== '') {
      lines.push(`[calib] message=${r.msg}`);
    }
    AppLog.writeDiagFile(`${fd}/diag/calib_diag.txt`, lines);
  }

  // ---------------- 结果录入：把「打印后看到的效果」变成耗材预设里的数值 ----------------
  // 校准真正完成不在切片，而在打印之后：挑出最平整的那一块 / 读出最顺的那条 PA 线，
  // 把结论写进耗材预设（下一刀即生效）。写回打印机（K 值下发）是设备侧，本机未接。

  private blockEntries(r: CalibRun): string[] {
    return r.blocks === '' ? [] : r.blocks.split(';');
  }

  private pctOf(entry: string): number {
    const i: number = entry.indexOf('|');
    if (i < 0) {
      return 0;
    }
    const v: number = Number.parseInt(entry.substring(i + 1), 10);
    return Number.isFinite(v) ? v : 0;
  }

  private labelOf(entry: string): string {
    const p: number = this.pctOf(entry);
    return p > 0 ? `+${p}%` : `${p}%`;
  }

  // 读「当前作用域耗材」的覆盖值；作用域为空时退回内核当前激活桶（尚未选定预设的冷启动）
  private ovOf(key: string): string[] | undefined {
    const scope: string = this.scopeFil();
    return scope === '' ? SliceParamStore.getFilamentOverride(key)
                        : SliceParamStore.getOverrideFor(scope, key);
  }

  // 当前作用域耗材的流量比例：优先取已写入的覆盖值；没有就按 1.00 算（并在结论里标明）
  private flowBase(): number {
    const ov: string[] | undefined = this.ovOf('filament_flow_ratio');
    if (ov !== undefined && ov.length > 0) {
      const v: number = Number.parseFloat(ov[0]);
      if (Number.isFinite(v) && v > 0.5 && v < 1.5) {
        return v;
      }
    }
    return 1.0;
  }

  private bumpEdit(): void {
    const cur: number = AppStorage.get<number>('filamentEditSeq') ?? 0;
    AppStorage.setOrCreate<number>('filamentEditSeq', cur + 1);
  }

  // 流量：当前流量比例 × 选中试块的系数（试块名就是系数，flowrate_m20 = -20% = 0.80）
  private applyFlow(item: CalibItem, entry: string): void {
    this.noteItem = item.id;
    const fd: string = this.filesDir();
    if (fd === '') {
      this.applyNote = '拿不到应用沙箱目录，未写入';
      return;
    }
    const preset: string = this.scopeFil();
    if (preset === '') {
      this.applyNote = '没取到当前耗材预设名，未写入（请先在参数面板选定耗材）';
      return;
    }
    const pct: number = this.pctOf(entry);
    const base: number = this.flowBase();
    const next: number = base * (1 + pct / 100);
    SliceParamStore.setOverrideFor(preset, 'filament_flow_ratio', [next.toFixed(3)]);
    const ok: boolean = SliceParamStore.saveFilamentOverrides(fd);
    this.bumpEdit();
    this.applyNote = ok
      ? `${item.name}：${base.toFixed(3)} × ${(1 + pct / 100).toFixed(2)} = 流量比例 ${next.toFixed(3)}，已写入耗材「${preset}」`
      : '写入失败：无法写应用目录';
    hilog.info(0x0000, TAG, '流量结果写入 ok=%{public}s base=%{public}s pct=%{public}d -> %{public}s',
      ok ? 'true' : 'false', base.toFixed(3), pct, next.toFixed(3));
  }

  // PA：K 值写入耗材预设的 pressure_advance（并打开 enable_pressure_advance）
  private applyPa(item: CalibItem): void {
    this.noteItem = item.id;
    const fd: string = this.filesDir();
    if (fd === '') {
      this.applyNote = '拿不到应用沙箱目录，未写入';
      return;
    }
    const k: number = Number.parseFloat(this.paText);
    if (!Number.isFinite(k) || k < 0 || k > 0.2) {
      this.applyNote = 'K 值应在 0 ~ 0.2 之间（拓竹机型常见 0 ~ 0.08）';
      return;
    }
    const preset: string = this.scopeFil();
    if (preset === '') {
      this.applyNote = '没取到当前耗材预设名，未写入（请先在参数面板选定耗材）';
      return;
    }
    SliceParamStore.setOverrideFor(preset, 'pressure_advance', [k.toFixed(3)]);
    SliceParamStore.setOverrideFor(preset, 'enable_pressure_advance', ['1']);
    const ok: boolean = SliceParamStore.saveFilamentOverrides(fd);
    this.bumpEdit();
    this.applyNote = ok
      ? `压力提前 K = ${k.toFixed(3)}，已写入耗材「${preset}」（写回打印机需连接设备，未接入）`
      : '写入失败：无法写应用目录';
    hilog.info(0x0000, TAG, 'PA 写入 ok=%{public}s k=%{public}s', ok ? 'true' : 'false', k.toFixed(3));
  }

  private blocksOf(item: CalibItem): string[] {
    const r: CalibRun | undefined = this.resultOf(item.id);
    if (r === undefined || !r.ok) {
      return [];
    }
    // 按系数升序排：试块从左到右就是系数从小到大，与打印板上的实际顺序对得上
    const list: string[] = this.blockEntries(r);
    list.sort((a: string, b: string): number => this.pctOf(a) - this.pctOf(b));
    return list;
  }

  private isPicked(item: CalibItem, entry: string): boolean {
    return this.pickedBlock === `${item.id}|${entry}`;
  }

  @Builder
  resultInput(item: CalibItem) {
    Column({ space: 6 }) {
      if (this.blocksOf(item).length > 0) {
        Text('打印完对照试块的平整度，从左到右挑最合适的一块，再点「应用该块」')
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.blocksOf(item), (e: string) => {
            Text(this.labelOf(e))
              .fontSize(12)
              .fontColor(this.isPicked(item, e) ? '#06281E' : Theme.textPrimary)
              .backgroundColor(this.isPicked(item, e) ? Theme.accent : Theme.surface)
              .borderRadius(6)
              .border({ width: 1, color: this.isPicked(item, e) ? Theme.accent : Theme.border })
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ right: 6, bottom: 6 })
              .onClick(() => { this.pickedBlock = `${item.id}|${e}`; })
          }, (e: string) => `${item.id}|${e}`)
        }
        .width('100%')
        Row() {
          Blank()
          Button('应用该块')
            .height(30)
            .fontSize(12)
            .fontColor('#06281E')
            .backgroundColor(Theme.accent)
            .borderRadius(8)
            .enabled(this.pickedBlock.startsWith(`${item.id}|`))
            .onClick(() => {
              this.applyFlow(item, this.pickedBlock.substring(item.id.length + 1));
            })
        }
        .width('100%')
      }
      if (item.id === 'pa') {
        Text('打印完对照 PA 图案，把最顺那条线的 K 值填进来（常见 0 ~ 0.08，步长 0.005）')
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .width('100%')
        Row({ space: 8 }) {
          TextInput({ text: this.paText, placeholder: '例如 0.020' })
            .type(InputType.NUMBER_DECIMAL)
            .height(32)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor(Theme.surface)
            .borderRadius(8)
            .onChange((v: string) => { this.paText = v; })
          Button('应用 K 值')
            .height(30)
            .fontSize(12)
            .fontColor('#06281E')
            .backgroundColor(Theme.accent)
            .borderRadius(8)
            .onClick(() => { this.applyPa(item); })
        }
        .width('100%')
      }
      if (item.id === 'pa_auto_s' || item.id === 'pa_auto_d') {
        Text('自动 PA 由打印机在机内跑完并回写 K 值，本机未接入设备侧，暂不能录入结果。')
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .width('100%')
      }
      if (this.applyNote !== '' && this.noteItem === item.id) {
        Text(this.applyNote)
          .fontSize(11)
          .fontColor(Theme.accent)
          .lineHeight(16)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 4 })
  }

  // 耗材作用域条：结果与写回都只作用于选中的这一支耗材预设
  @Builder
  filChip(name: string) {
    Row({ space: 4 }) {
      Text(this.shortFil(name))
        .fontSize(11)
        .fontColor(this.scopeFil() === name ? '#06281E' : Theme.textSecondary)
      if (name === this.curFilament) {
        Text('当前')
          .fontSize(9)
          .fontColor(this.scopeFil() === name ? '#06281E' : Theme.accent)
      }
    }
    .padding({ left: 9, right: 9, top: 4, bottom: 4 })
    .borderRadius(11)
    .backgroundColor(this.scopeFil() === name ? Theme.accent : Theme.surfaceElevated)
    .border({ width: 1, color: this.scopeFil() === name ? Theme.accent : Theme.border })
    .onClick(() => {
      // 只切「结果归属/写回目标」，不动参数面板里真正参与切片的耗材
      this.calibFil = name;
      this.pickedBlock = '';
      this.noteItem = '';
      this.applyNote = '';
    })
  }

  // 耗材菜单内容（受控 bindMenu 的自定义 builder）：点哪支就把内核真的切到那支
  @Builder
  filMenu() {
    Scroll() {
      Column({ space: 2 }) {
        ForEach(this.filCandidates, (name: string) => {
          Row({ space: 6 }) {
            Text(this.shortFil(name))
              .fontSize(13)
              .fontColor(name === this.curFilament ? Theme.accent : Theme.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (name === this.curFilament) {
              Text('当前')
                .fontSize(9)
                .fontColor(Theme.accent)
            }
            Blank()
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .backgroundColor(name === this.curFilament ? '#14FFFFFF' : Color.Transparent)
          .onClick(() => { this.pickFilament(name); })
        }, (name: string) => name)
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })
    }
    .constraintSize({ maxHeight: 360 })
    .width(260)
    .backgroundColor(Theme.surface)
    .borderRadius(10)
    .border({ width: 1, color: Theme.border })
    .scrollBar(BarState.Off)
  }

  // 设备侧 K 值（只读）。放在列表最底部：它是"看一眼打印机里有什么"，不属于任何一项校准流程。
  // 文案必须如实——只查不写，写回要等"set 后 get 读回比对"在真机上验证过。
  @Builder
  deviceKBlock() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('设备侧 K 值（只读）')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
        Blank()
        Button(this.devKBusy ? '读取中…' : '从打印机读取')
          .fontSize(12)
          .height(30)
          .padding({ left: 12, right: 12 })
          .backgroundColor(Theme.surfaceElevated)
          .fontColor(Theme.textPrimary)
          .enabled(!this.devKBusy)
          .onClick(() => { this.readDeviceK(); })
      }
      .width('100%')

      Text('只用 extrusion_cali_get 查询打印机自己的 K 值表，不写入任何数据；写回设备尚未接入。')
        .fontSize(11)
        .fontColor(Theme.textSecondary)
        .lineHeight(16)
        .width('100%')

      if (this.devKNote !== '') {
        Text(this.devKNote)
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .lineHeight(16)
          .width('100%')
      }

      if (this.devKEntries.length > 0) {
        ForEach(this.devKEntries, (e: KProfileEntry) => {
          Row({ space: 8 }) {
            Text(e.nozzleDiameter !== '' ? `Φ${e.nozzleDiameter}` : 'Φ?')
              .fontSize(11)
              .fontColor(Theme.textSecondary)
            Text(e.name)
              .fontSize(12)
              .fontColor(Theme.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(`K=${e.kValue}`)
              .fontSize(12)
              .fontColor(Theme.accent)
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }, (e: KProfileEntry) => e.key())
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(Theme.surface)
    .border({ width: 1, color: Theme.border })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('校准')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Blank()
        if (this.running) {
          Text('运行中')
            .fontSize(11)
            .fontColor(Theme.accent)
        }
        // 右上角：切片耗材选择器。它切的是**内核**的耗材预设（按索引下发），
        // 所以与准备页参数面板里那支是同一个选择，两边永远一致。
        Row({ space: 5 }) {
          Text(this.curFilament !== '' ? this.shortFil(this.curFilament) : '选择耗材')
            .fontSize(12)
            .fontColor(Theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 140 })
          Text('▾')
            .fontSize(9)
            .fontColor(Theme.textSecondary)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(8)
        .backgroundColor(Theme.surfaceElevated)
        .border({ width: 1, color: Theme.border })
        .onClick(() => { this.openFilMenu(); })
        .bindMenu(this.filMenuShown, this.filMenu(), {
          placement: Placement.BottomRight,
          enableArrow: false,
          offset: { x: 0, y: 4 },
          backgroundColor: Color.Transparent
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Text('本版可做：把随包的校准模型用当前预设切出来（本地，不连打印机）；切完对照打印效果挑块/填 K 值，写进所选耗材预设。结果按耗材预设隔离存放，换预设不会串；设备侧自动校准（机内跑并写回 K 值）尚未接入——目前只能「只读」查询打印机自己的 K 值表（见列表底部「设备侧 K 值（只读）」）。')
        .fontSize(12)
        .fontColor(Theme.textSecondary)
        .lineHeight(18)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      // 耗材作用域条：只在「台账里有多支耗材」时才出现。
      // 只有一支时它和右上角选择器重复、纯占地方；多支时它的作用是挑「看哪支的结果」。
      if (this.filamentNames().length > 1) {
        Row({ space: 8 }) {
          Text('结果归属')
            .fontSize(11)
            .fontColor(Theme.textSecondary)
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.filamentNames(), (name: string) => {
                this.filChip(name)
              }, (name: string) => name)
            }
          }
          .layoutWeight(1)
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }

      if (this.errText !== '') {
        Text(this.errText)
          .fontSize(12)
          .fontColor('#F26D6D')
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      if (this.running) {
        Row({ space: 8 }) {
          Text(`${this.stageMsg}`)
            .fontSize(12)
            .fontColor(Theme.textSecondary)
          Blank()
          Text(`${this.pct}%`)
            .fontSize(12)
            .fontColor(Theme.accent)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 6 })

        Progress({ value: this.pct, total: 100, type: ProgressType.Linear })
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.items, (item: CalibItem) => {
            this.row(item)
          }, (item: CalibItem) => item.id)
          this.deviceKBlock()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  row(item: CalibItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(item.name)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(item.available ? Theme.textPrimary : Theme.textSecondary)
        if (item.deviceSide) {
          Text('设备侧')
            .fontSize(10)
            .fontColor(Theme.accent)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .border({ width: 1, color: Theme.accent })
            .borderRadius(4)
        }
        Blank()
        Text(this.statusOf(item))
          .fontSize(12)
          .fontColor(Theme.accent)
      }
      .width('100%')

      Text(item.desc)
        .fontSize(12)
        .fontColor(Theme.textSecondary)
        .lineHeight(17)
        .width('100%')

      if (this.resultOf(item.id) !== undefined && (this.resultOf(item.id) as CalibRun).ok) {
        this.resultInput(item);
      }

      Row() {
        Blank()
        Button(item.available ? '生成并切片' : '未开放')
          .height(34)
          .fontSize(13)
          .fontColor(item.available ? '#06281E' : Theme.textSecondary)
          .backgroundColor(item.available ? Theme.accent : Theme.surfaceElevated)
          .borderRadius(8)
          .enabled(item.available && !this.running)
          .onClick(() => { this.run(item); })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.surfaceElevated)
    .borderRadius(10)
    .border({ width: 1, color: Theme.border })
  }
}
