import { Theme } from '../common/Theme';
import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import { AppMeta } from '../common/AppMeta';
import { FilamentGrouping, MODE_SAVING, MODE_CONVENIENCE, MODE_CUSTOM, SIDE_LEFT, SIDE_RIGHT, SIDE_NONE } from '../service/FilamentGrouping';
import { PrintOptions, PrintDeviceInfo, EXTERNAL_AMS_ID } from '../service/PrintOptions';
import { GlowSettings } from '../service/GlowSettings';
import { modelState } from '../model/ModelState';

// 设置页：顶部标签页导航 + 「视觉」标签（背景发光 / 手柄发光）+ 「双喷嘴」标签
// （耗材分组模式 + AMS↔喷嘴配对）+ 「关于」标签（版本 / 开源声明 / 开发者）+ 「开源许可」标签（AGPL 全文）。
// 光感通过 AppStorage 的 glowBg / glowHandle 共享给 3D 场景，实时生效。
const TAG: string = 'SettingsPanel';

// 切片内核版本标识：唯一来源是 libslic3r 顶层 CMakeLists.txt 的 SLIC3R_VERSION（"02.08.02.61"）。
// 该值是编译期常量、运行时不可查询，故此处只做「展示用」的静态文本，与源码保持一字不差。
const KERNEL_VERSION: string = 'v02.08.02.61';

// 双喷嘴设置页：AMS↔喷嘴配对的一行（AMS 单元 + 当前配对侧）
class PairRowUI {
  amsId: number = 0;
  title: string = '';
  live: boolean = false;  // 该单元是否在真实设备上被检测到
  side: string = SIDE_NONE;
  key: string = '';
}

// 自定义分组的一行（耗材 + 指定侧）
class CustomRowUI {
  filament: string = '';
  side: string = SIDE_NONE;
  key: string = '';
}

// AMS 单元的候选编号（本工程 DevicePanel 用 M620 R{amsId*4+slotId} 表达取料，amsId 0..3）
const KNOWN_AMS_IDS: number[] = [0, 1, 2, 3];

@Component
export struct SettingsPanel {
  @State tab: number = 0;
  // 应用版本：从 bundle 配置（AppScope/app.json5 的 versionName / versionCode）运行时读取，不写死
  @State versionText: string = '';
  // 开源许可全文（切到「开源许可」标签时从 rawfile 惰性读取）
  @State private licenseText: string = '';
  @State private licenseBusy: boolean = false;
  @StorageLink('glowBg') glowBg: number = 1.0;
  @StorageLink('glowHandle') glowHandle: number = 1.0;
  // 光感落盘节流：拖动中最多每 250ms 写一次，松手（End/Click）立即写最终值。
  private glowSaveTimer: number = -1;
  // 双喷嘴：当前分组模式 + 配对/自定义行 + AMS 检测提示
  @State private gMode: string = MODE_SAVING;
  @State private pairRows: PairRowUI[] = [];
  @State private customRows: CustomRowUI[] = [];
  @State private amsHint: string = '';

  aboutToAppear(): void {
    if (AppStorage.get<number>('glowBg') === undefined) {
      AppStorage.setOrCreate<number>('glowBg', 1.0);
    }
    if (AppStorage.get<number>('glowHandle') === undefined) {
      AppStorage.setOrCreate<number>('glowHandle', 1.0);
    }
    this.loadAppVersion();
    this.ensureGroupingLoaded();
    this.refreshDualNozzle();
  }

  private filesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx === undefined ? '' : ctx.filesDir;
  }

  // 光感落盘：force=true（松手/点击）立即写最终值；拖动中节流为最多每 250ms 一次。
  // 只落盘，不改 AppStorage —— 实时生效仍由 @StorageLink 驱动（本方法不参与渲染链路）。
  private persistGlow(force: boolean): void {
    if (force) {
      if (this.glowSaveTimer >= 0) {
        clearTimeout(this.glowSaveTimer);
        this.glowSaveTimer = -1;
      }
      GlowSettings.save(this.filesDir(), this.glowBg, this.glowHandle);
      return;
    }
    if (this.glowSaveTimer >= 0) { return; }  // 已有排队的写入 → 本次合并丢弃
    this.glowSaveTimer = setTimeout(() => {
      this.glowSaveTimer = -1;
      GlowSettings.save(this.filesDir(), this.glowBg, this.glowHandle);
    }, 250);
  }

  private ensureGroupingLoaded(): void {
    if (!FilamentGrouping.isLoaded()) {
      FilamentGrouping.load(this.filesDir());
    }
    this.gMode = FilamentGrouping.snap().mode;
  }

  // 刷新双喷嘴设置页数据：AMS 单元（含真实检测）+ 自定义耗材行
  private refreshDualNozzle(): void {
    this.gMode = FilamentGrouping.snap().mode;
    PrintOptions.fetch().then((info: PrintDeviceInfo) => {
      const liveIds: number[] = [];
      for (const s of info.slots) {
        if (liveIds.indexOf(s.amsId) < 0) { liveIds.push(s.amsId); }
      }
      this.amsHint = info.connected
        ? (info.slots.length > 0 ? `已连接：检测到 ${liveIds.length} 个 AMS 单元` : '已连接：未检测到 AMS 单元')
        : '未连接打印机：下方为可预配置的 AMS 单元（连接并同步后自动核对）';
      // 单元集合 = 已知编号(AMS1..4) ∪ 外挂 ∪ 真实检测到的单元 ∪ 已保存配对的单元
      const ids: number[] = [];
      for (const i of KNOWN_AMS_IDS) { ids.push(i); }
      ids.push(EXTERNAL_AMS_ID);
      for (const i of liveIds) { if (ids.indexOf(i) < 0) { ids.push(i); } }
      for (const p of FilamentGrouping.snap().pairing) { if (ids.indexOf(p.amsId) < 0) { ids.push(p.amsId); } }
      const rows: PairRowUI[] = [];
      for (const id of ids) {
        const r: PairRowUI = new PairRowUI();
        r.amsId = id;
        r.title = id === EXTERNAL_AMS_ID ? '外挂料盘' : `AMS ${id + 1}`;
        r.live = liveIds.indexOf(id) >= 0;
        r.side = FilamentGrouping.pairingSide(id);
        r.key = `p_${id}_${r.side}`;
        rows.push(r);
      }
      this.pairRows = rows;
      this.rebuildCustomRows();
    }).catch((e: Error) => {
      this.amsHint = '读取设备状态失败：' + e.message;
      this.rebuildCustomRows();
    });
  }

  // 自定义模式：列出本盘实际使用的耗材（对象有效耗材 + 全局耗材），供逐耗材指定左/右
  private rebuildCustomRows(): void {
    const seen: string[] = [];
    const rows: CustomRowUI[] = [];
    for (const inst of modelState.instances) {
      const f: string = inst.filamentName !== ''
        ? inst.filamentName
        : (AppStorage.get<string>('globalFilamentName') ?? '');
      if (f === '' || seen.indexOf(f) >= 0) { continue; }
      seen.push(f);
      const r: CustomRowUI = new CustomRowUI();
      r.filament = f;
      r.side = FilamentGrouping.customSide(f);
      r.key = `c_${f}_${r.side}`;
      rows.push(r);
    }
    this.customRows = rows;
  }

  // 切换分组模式（默认省料）→ 落盘 + 重算喷嘴归属
  private pickMode(mode: string): void {
    FilamentGrouping.setMode(mode);
    FilamentGrouping.save(this.filesDir());
    this.gMode = mode;
    this.applyGroupingAndPublish();
    this.rebuildCustomRows();
  }

  // 设置 AMS↔喷嘴配对 → 落盘 + 重算
  private pickPair(amsId: number, side: string): void {
    FilamentGrouping.setPairing(amsId, side);
    FilamentGrouping.save(this.filesDir());
    for (const r of this.pairRows) {
      if (r.amsId === amsId) { r.side = side; r.key = `p_${amsId}_${side}`; }
    }
    this.pairRows = this.pairRows.slice();
    this.applyGroupingAndPublish();
  }

  // 自定义模式：逐耗材指定侧 → 落盘 + 重算
  private pickCustom(filament: string, side: string): void {
    FilamentGrouping.setCustom(filament, side);
    FilamentGrouping.save(this.filesDir());
    for (const r of this.customRows) {
      if (r.filament === filament) { r.side = side; r.key = `c_${filament}_${side}`; }
    }
    this.customRows = this.customRows.slice();
    this.applyGroupingAndPublish();
  }

  private applyGroupingAndPublish(): void {
    const printer: string = AppStorage.get<string>('platePrinter') ?? '';
    if (FilamentGrouping.applyToState(printer, [])) {
      modelState.publish();
    }
  }

  // 读取自身 bundle 信息：versionName / versionCode 由 app.json5 编译进 bundle，取到的即真实值
  private loadAppVersion(): void {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const name: string = info.versionName;
      const code: number = info.versionCode;
      this.versionText = `${name} (${code})`;
    } catch (e) {
      // 不吞异常：读取失败如实打 hilog，界面上退化为「未知」，不影响其它功能
      hilog.error(0x0000, TAG, '读取应用版本失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      this.versionText = '未知';
    }
  }

  // 复制源码地址：AGPL §6 的「源码在哪」，让用户能带走而不是只能看
  private copySourceUrl(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, AppMeta.SOURCE_URL);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '源码地址已复制' });
      }).catch((e: Object) => {
        hilog.warn(0x0000, TAG, '复制源码地址失败: %{public}s', JSON.stringify(e));
        promptAction.showToast({ message: '复制失败，请手动选中文本复制' });
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, '复制源码地址异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 打开源码仓库：走系统浏览器；失败则复制地址兜底（离线/无浏览器时不静默失败）
  private openSource(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.copySourceUrl();
      return;
    }
    (ctx as common.UIAbilityContext).openLink(AppMeta.SOURCE_URL).catch((e: Object) => {
      hilog.warn(0x0000, TAG, '打开源码地址失败: %{public}s', JSON.stringify(e));
      this.copySourceUrl();
      promptAction.showToast({ message: '没能打开浏览器，源码地址已复制' });
    });
  }

  // 读取随包的 AGPL 全文（rawfile，离线可读）：只在切到「开源许可」标签时读一次
  private loadLicense(): void {
    if (this.licenseText !== '' || this.licenseBusy) {
      return;
    }
    this.licenseBusy = true;
    try {
      const ctx = this.getUIContext().getHostContext();
      const mgr: resourceManager.ResourceManager | undefined = ctx === undefined ? undefined : ctx.resourceManager;
      if (mgr === undefined) {
        throw new Error('resourceManager 不可用');
      }
      const buf: Uint8Array = mgr.getRawFileContentSync(AppMeta.LICENSE_RAW);
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      this.licenseText = dec.decodeToString(buf);
    } catch (e) {
      hilog.error(0x0000, TAG, '读取许可证全文失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      this.licenseText = `读取失败：许可证全文随包放在 rawfile/${AppMeta.LICENSE_RAW}，等价文本见仓库根 LICENSE 文件。`;
    } finally {
      this.licenseBusy = false;
    }
  }

  // 模式说明文案（官方语义）
  private modeDesc(): string {
    if (this.gMode === MODE_CONVENIENCE) {
      return '便携：完全按 AMS 实装耗材分组（材料类型 + 颜色最接近），尽量少改动料位；适合远程发起、不方便手动调位。';
    }
    if (this.gMode === MODE_CUSTOM) {
      return '自定义：由你逐耗材指定左/右喷嘴（方案 2 节官方原文）。未指定的耗材保持「未定」，不瞎猜。';
    }
    return '省料（官方默认）：优先减少同喷嘴换料次数，把用量大的耗材尽量拆到不同喷嘴；再按 AMS 容量、颜色 ΔE 排序。';
  }

  @Builder
  chip(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(12.5)
      .fontColor(active ? Theme.accentSoft : Theme.textSecondary)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor(active ? Theme.surfaceElevated : '#00000000')
      .borderRadius(6)
      .border({ width: 1, color: active ? Theme.accent : Theme.border })
      .onClick(action)
  }

  // AMS↔喷嘴配对一行：单元标题 + 左/右/未配对
  @Builder
  pairRowUI(r: PairRowUI) {
    Row() {
      Column() {
        Text(r.title)
          .fontSize(13)
          .fontColor(Theme.textPrimary)
        Text(r.live ? '已检测到' : '未检测到（可预配置）')
          .fontSize(10.5)
          .fontColor(r.live ? Theme.accentSoft : Theme.textSecondary)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Row({ space: 6 }) {
        this.chip('左喷', r.side === SIDE_LEFT, () => { this.pickPair(r.amsId, SIDE_LEFT); })
        this.chip('右喷', r.side === SIDE_RIGHT, () => { this.pickPair(r.amsId, SIDE_RIGHT); })
        this.chip('未配对', r.side === SIDE_NONE, () => { this.pickPair(r.amsId, SIDE_NONE); })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: Theme.border })
    .alignItems(VerticalAlign.Center)
  }

  // 自定义分组一行：耗材名 + 左/右
  @Builder
  customRowUI(r: CustomRowUI) {
    Row() {
      Text(r.filament)
        .fontSize(12.5)
        .fontColor(Theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Row({ space: 6 }) {
        this.chip('左喷', r.side === SIDE_LEFT, () => { this.pickCustom(r.filament, SIDE_LEFT); })
        this.chip('右喷', r.side === SIDE_RIGHT, () => { this.pickCustom(r.filament, SIDE_RIGHT); })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: Theme.border })
    .alignItems(VerticalAlign.Center)
  }

  // 「双喷嘴」标签内容：分组模式 + 自定义 + AMS↔喷嘴配对
  @Builder
  dualPanel() {
    Scroll() {
      Column({ space: 18 }) {
        // 单喷嘴机型提示：没有左右喷嘴，下面的分组/配对只是预配置，不参与打印校验。
        if (!FilamentGrouping.isDualNozzle()) {
          Text('当前打印机为单喷嘴（无「仅单喷嘴区」）：不会要求把耗材分到左右喷嘴，下面的分组/配对不参与打印校验；换双喷嘴机型后可直接复用。')
            .fontSize(11.5)
            .fontColor(Theme.accentSoft)
            .lineHeight(17)
            .width('100%')
        }
        // ---- 分组模式 ----
        Column({ space: 8 }) {
          Text('耗材分组模式')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.accentSoft)
          Text('喷嘴归属以「耗材分组」为准：对象喷嘴侧 = 其耗材所在分组的喷嘴。官方默认「省料」模式。')
            .fontSize(11.5)
            .fontColor(Theme.textSecondary)
            .lineHeight(17)
          Row({ space: 8 }) {
            this.chip('省料', this.gMode === MODE_SAVING, () => { this.pickMode(MODE_SAVING); })
            this.chip('便携', this.gMode === MODE_CONVENIENCE, () => { this.pickMode(MODE_CONVENIENCE); })
            this.chip('自定义', this.gMode === MODE_CUSTOM, () => { this.pickMode(MODE_CUSTOM); })
          }
          .width('100%')
          Text(this.modeDesc())
            .fontSize(11.5)
            .fontColor(Theme.textSecondary)
            .lineHeight(17)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ---- 自定义：逐耗材指定 ----
        if (this.gMode === MODE_CUSTOM) {
          Column({ space: 8 }) {
            Text('自定义分组 · 逐耗材指定喷嘴')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.accentSoft)
            if (this.customRows.length === 0) {
              Text('当前没有可指定的耗材（请先在「准备」页导入模型并选择耗材）。')
                .fontSize(11.5)
                .fontColor(Theme.textSecondary)
            } else {
              ForEach(this.customRows, (r: CustomRowUI) => { this.customRowUI(r) }, (r: CustomRowUI) => r.key)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // ---- AMS ↔ 喷嘴配对 ----
        Column({ space: 8 }) {
          Text('AMS ↔ 左右喷嘴配对')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.accentSoft)
          Text(this.amsHint)
            .fontSize(11.5)
            .fontColor(Theme.textSecondary)
            .lineHeight(17)
          Text('把某个 AMS 单元/外挂指定给左或右喷嘴。有喷嘴归属的对象在打印弹窗里只能选「配对到同侧」的单元；未配对的单元按「未配对」处理并明确提示（不瞎猜）。')
            .fontSize(11.5)
            .fontColor(Theme.textSecondary)
            .lineHeight(17)
          ForEach(this.pairRows, (r: PairRowUI) => { this.pairRowUI(r) }, (r: PairRowUI) => r.key)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
  }

  build() {
    Column() {
      // 顶部标签页导航
      Row({ space: 8 }) {
        Text('视觉')
          .fontSize(13)
          .fontWeight(this.tab === 0 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.tab === 0 ? Theme.accentSoft : Theme.textSecondary)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.tab === 0 ? Theme.surfaceElevated : '#00000000')
          .borderRadius(6)
          .onClick(() => { this.tab = 0; })
        Text('双喷嘴')
          .fontSize(13)
          .fontWeight(this.tab === 2 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.tab === 2 ? Theme.accentSoft : Theme.textSecondary)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.tab === 2 ? Theme.surfaceElevated : '#00000000')
          .borderRadius(6)
          .onClick(() => { this.tab = 2; this.refreshDualNozzle(); })
        Text('关于')
          .fontSize(13)
          .fontWeight(this.tab === 1 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.tab === 1 ? Theme.accentSoft : Theme.textSecondary)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.tab === 1 ? Theme.surfaceElevated : '#00000000')
          .borderRadius(6)
          .onClick(() => { this.tab = 1; })
        Text('开源许可')
          .fontSize(13)
          .fontWeight(this.tab === 3 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.tab === 3 ? Theme.accentSoft : Theme.textSecondary)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.tab === 3 ? Theme.surfaceElevated : '#00000000')
          .borderRadius(6)
          .onClick(() => { this.tab = 3; this.loadLicense(); })
      }
      .width('100%')
      // 顶部内边距与设备/日志等页保持一致（此前 62 是为全屏浮层的「关闭」按钮让位；
      // 设置页现已改为内容区普通页面，不再有浮层按钮，故收回到 10）。
      .padding({ left: 16, right: 16, top: 10, bottom: 8 })
      .border({ width: { bottom: 1 }, color: Theme.border })

      if (this.tab === 0) {
        Column({ space: 18 }) {
          // 背景发光
          Column({ space: 6 }) {
            Row() {
              Text('背景发光')
                .fontSize(13)
                .fontColor(Theme.textPrimary)
              Blank()
              Text(`${Math.round(this.glowBg * 100)}%`)
                .fontSize(12)
                .fontColor(Theme.accentSoft)
            }
            .width('100%')
            Slider({ value: this.glowBg, min: 0, max: 2, step: 0.01, style: SliderStyle.OutSet })
              .width('100%')
              .selectedColor(Theme.accent).trackColor(Theme.surfaceElevated)
              .onChange((v: number, mode: SliderChangeMode) => {
                this.glowBg = v;
                this.persistGlow(mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
              })
          }
          .width('100%')

          // 手柄发光
          Column({ space: 6 }) {
            Row() {
              Text('手柄发光')
                .fontSize(13)
                .fontColor(Theme.textPrimary)
              Blank()
              Text(`${Math.round(this.glowHandle * 100)}%`)
                .fontSize(12)
                .fontColor(Theme.accentSoft)
            }
            .width('100%')
            Slider({ value: this.glowHandle, min: 0, max: 2, step: 0.01, style: SliderStyle.OutSet })
              .width('100%')
              .selectedColor(Theme.accent).trackColor(Theme.surfaceElevated)
              .onChange((v: number, mode: SliderChangeMode) => {
                this.glowHandle = v;
                this.persistGlow(mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
      } else if (this.tab === 2) {
        this.dualPanel()
      } else if (this.tab === 1) {
        // 「关于」：窄屏/长文本用 Scroll 承载，避免溢出；文字均可选中复制
        Scroll() {
          Column({ space: 16 }) {
            // 应用名与版本
            Column({ space: 4 }) {
              Text('BLHM studio')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary)
                .copyOption(CopyOptions.LocalDevice)
              Text(`版本 ${this.versionText}`)
                .fontSize(12)
                .fontColor(Theme.textSecondary)
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 开源声明
            Column({ space: 8 }) {
              Text('开源声明')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.accentSoft)
              Text(AppMeta.agplStatement())
                .fontSize(12)
                .fontColor(Theme.textPrimary)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
              Text(`许可证：${AppMeta.LICENSE_NAME}`)
                .fontSize(12)
                .fontColor(Theme.textSecondary)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
              Text(`切片内核版本：${KERNEL_VERSION}`)
                .fontSize(12)
                .fontColor(Theme.textSecondary)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
              Text('切片预设（机器 / 工艺 / 耗材）来自 Bambu Studio 官方 profiles 资源。')
                .fontSize(12)
                .fontColor(Theme.textPrimary)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
              Text('本应用为独立开发，不包含厂商闭源组件。')
                .fontSize(12)
                .fontColor(Theme.textPrimary)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 源码获取入口（AGPL-3.0 §6：拿到二进制的人有权获得对应源码）
            Column({ space: 8 }) {
              Text('获取源代码')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.accentSoft)
              Text(AppMeta.sourceHint())
                .fontSize(12)
                .fontColor(Theme.textPrimary)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
              Text(AppMeta.SOURCE_URL)
                .fontSize(12)
                .fontColor(Theme.info)
                .lineHeight(18)
                .copyOption(CopyOptions.LocalDevice)
              if (!AppMeta.isSourceConfigured()) {
                Text('※ 该地址仍是占位值，发布前须改成真实仓库地址（common/AppMeta.ets 的 SOURCE_URL）。')
                  .fontSize(11.5)
                  .fontColor(Theme.warn)
                  .lineHeight(17)
              }
              Row({ space: 10 }) {
                Text('获取源码')
                  .fontSize(12.5)
                  .fontColor(Theme.accentSoft)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(6)
                  .border({ width: 1, color: Theme.accent })
                  .onClick(() => { this.openSource(); })
                Text('复制地址')
                  .fontSize(12.5)
                  .fontColor(Theme.textSecondary)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(6)
                  .border({ width: 1, color: Theme.border })
                  .onClick(() => { this.copySourceUrl(); })
                Text('GPL 全文')
                  .fontSize(12.5)
                  .fontColor(Theme.textSecondary)
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(6)
                  .border({ width: 1, color: Theme.border })
                  .onClick(() => { this.tab = 3; this.loadLicense(); })
              }
              .width('100%')
            }
            .width('100%')
            .padding({ top: 4 })
            .border({ width: { top: 1 }, color: Theme.border })
            .alignItems(HorizontalAlign.Start)

            // 软件开发者
            // 整体靠左：Row 默认即是主轴起点对齐；去掉 Blank()（它会把「姜鹏」推到行尾），
            // 改用固定 space:10 让 label 与值紧凑相邻。宽度仍占满，仅用于铺满上边的分隔线。
            Row({ space: 10 }) {
              Text('软件开发者')
                .fontSize(13)
                .fontColor(Theme.textSecondary)
              Text('姜鹏')
                .fontSize(13)
                .fontColor(Theme.textPrimary)
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .padding({ top: 4 })
            .border({ width: { top: 1 }, color: Theme.border })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      } else {
        // 「开源许可」：随包的 AGPL-3.0 全文（rawfile 离线读取），可滚动、可选词复制
        Scroll() {
          Column({ space: 10 }) {
            Text(AppMeta.LICENSE_NAME)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.accentSoft)
              .copyOption(CopyOptions.LocalDevice)
            Text(this.licenseBusy ? '正在读取…'
              : (this.licenseText === '' ? '许可证全文随包提供，点上方「开源许可」标签即可读取。' : this.licenseText))
              .fontSize(11.5)
              .fontColor(Theme.textSecondary)
              .lineHeight(17)
              .copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
