import { Theme } from '../common/Theme';
import { MqttService } from '../service/MqttService';
import { AppLog } from '../service/AppLog';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';

// 日志页：显示两类日志，供真机直接查看（用户人在外面、抓不了 hilog，全靠这一页）
//   1) AppLog（ArkTS 侧）：[GcodeDiag] 诊断块 + 去重告警（未识别 feature / 材质越界 / 资源创建失败…）；
//   2) 原生 C++ 侧 MQTT 运行日志（连接/订阅/数据解析）。
// 另加一个小巧的「渲染开关（调试）」区块：做渲染开销 A/B 试验时在设备上直接拨开关、看画面与 FPS。
@Component
export struct LogPanel {
  @State logs: string[] = [];
  private pollTimer: number = -1;

  // ---- 渲染开关（调试）------------------------------------------------------
  // 全部走 AppStorage：常驻的 3D 场景页（ModelPreviewPage）用 @StorageLink 订阅同一批 key，
  // 值一变立即把档位应用到相机/材质 —— 所以这里改完即生效，不需要重启或重进页面。
  // 【默认值刻意等于改动前的当前值】（MSAA 开 / Bloom 开 / Vignette 开 / 剔除 NONE）：
  // 装上后画面与行为和旧版完全一致，A/B 由用户自己拨。
  @StorageLink('rtMsaa') rtMsaa: boolean = true;
  @StorageLink('rtBloom') rtBloom: boolean = true;
  @StorageLink('rtVignette') rtVignette: boolean = true;
  @StorageLink('rtCullBack') rtCullBack: boolean = false;
  @StorageLink('rtScopeAll') rtScopeAll: boolean = false;
  // 当前是否处于切片路径态（面板上要如实告诉用户：这一档现在作用于谁）
  @StorageProp('gcodeShow') gcodeShow: boolean = false;
  // 最近 1 秒平均 FPS（由 3D 场景页统计后写进 AppStorage('rtFps')，本页轮询读取）
  @State fps: number = 0;
  // 折叠状态：默认展开（用户是专门来做试验的），但窄屏/只想看日志时可一键收起
  @State rtOpen: boolean = true;

  aboutToAppear(): void {
    // 兜底：若本页先于 3D 场景页被创建，先把开关默认值写进 AppStorage（值存在则绝不覆盖）。
    if (AppStorage.get<boolean>('rtMsaa') === undefined) { AppStorage.setOrCreate<boolean>('rtMsaa', true); }
    if (AppStorage.get<boolean>('rtBloom') === undefined) { AppStorage.setOrCreate<boolean>('rtBloom', true); }
    if (AppStorage.get<boolean>('rtVignette') === undefined) { AppStorage.setOrCreate<boolean>('rtVignette', true); }
    if (AppStorage.get<boolean>('rtCullBack') === undefined) { AppStorage.setOrCreate<boolean>('rtCullBack', false); }
    if (AppStorage.get<boolean>('rtScopeAll') === undefined) { AppStorage.setOrCreate<boolean>('rtScopeAll', false); }
    this.refresh();
    this.pollTimer = setInterval(() => {
      this.refresh();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private refresh(): void {
    // FPS：3D 场景页每满 1 秒写一次；本页随 1 秒轮询一起读，保证面板上的数字跟得上
    const f: number | undefined = AppStorage.get<number>('rtFps');
    this.fps = f !== undefined ? f : 0;
    let native: string[] = [];
    try {
      const raw: string = MqttService.getLogs();
      const arr: string[] = JSON.parse(raw) as string[];
      native = arr.reverse(); // 最新日志置顶
    } catch (e) {
      // 忽略解析失败
    }
    // 三通道：把新增的原生 MQTT 日志（含 MqttConn 连接诊断、断线重连）追加写进 files/diag/gcode_diag.txt
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        MqttService.flushLogsToDiag(`${ctx.filesDir}/diag/gcode_diag.txt`);
      }
    } catch (e) {
      // 忽略：诊断落盘失败不影响日志页显示
    }
    // 应用日志（ArkTS 侧，含 [GcodeDiag] 诊断块与去重告警）接在原生日志之前：
    // 它们更新更频繁、与当前排查也最相关，置顶更便于截图。原生 MQTT 日志内容与格式不变。
    this.logs = AppLog.getLines().reverse().concat(native);
  }

  private copyLogs(): void {
    if (this.logs.length === 0) {
      promptAction.showToast({ message: '暂无日志' });
      return;
    }
    // 还原为正序（旧 → 新）再拼接
    const text: string = this.logs.slice().reverse().join('\n');
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '已复制到剪贴板' });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('日志')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Blank()
        Text(`${this.logs.length} 条`)
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .margin({ right: 10 })
        Button('复制')
          .height(28)
          .fontSize(11)
          .fontColor(Theme.textPrimary)
          .backgroundColor(Theme.surfaceElevated)
          .borderRadius(6)
          .onClick(() => { this.copyLogs(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 8 })
      .border({ width: { bottom: 1 }, color: Theme.border })

      // ---- 渲染开关（调试）：克制的小区块，可折叠；每一项都是「当前值 + 点一下切换」----
      Column({ space: 6 }) {
        Row() {
          Text('渲染开关（调试）')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary)
          Blank()
          Text(this.rtOpen ? '收起' : '展开')
            .fontSize(11)
            .fontColor(Theme.accentSoft)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.surfaceElevated)
            .borderRadius(6)
            .onClick(() => { this.rtOpen = !this.rtOpen; })
        }
        .width('100%')

        if (this.rtOpen) {
          // Flex 自动换行：窄屏（手机）下按钮会折行，不会把面板挤出屏幕
          Flex({ wrap: FlexWrap.Wrap }) {
            Button(`MSAA：${this.rtMsaa ? '开' : '关'}`)
              .fontSize(11).height(26).padding({ left: 10, right: 10 }).margin({ right: 8, bottom: 8 })
              .backgroundColor(this.rtMsaa ? Theme.accent : Theme.surfaceElevated)
              .fontColor(this.rtMsaa ? Theme.bg : Theme.textPrimary)
              .onClick(() => { this.rtMsaa = !this.rtMsaa; })
            Button(`Bloom：${this.rtBloom ? '开' : '关'}`)
              .fontSize(11).height(26).padding({ left: 10, right: 10 }).margin({ right: 8, bottom: 8 })
              .backgroundColor(this.rtBloom ? Theme.accent : Theme.surfaceElevated)
              .fontColor(this.rtBloom ? Theme.bg : Theme.textPrimary)
              .onClick(() => { this.rtBloom = !this.rtBloom; })
            Button(`Vignette：${this.rtVignette ? '开' : '关'}`)
              .fontSize(11).height(26).padding({ left: 10, right: 10 }).margin({ right: 8, bottom: 8 })
              .backgroundColor(this.rtVignette ? Theme.accent : Theme.surfaceElevated)
              .fontColor(this.rtVignette ? Theme.bg : Theme.textPrimary)
              .onClick(() => { this.rtVignette = !this.rtVignette; })
            Button(`剔除：${this.rtCullBack ? 'BACK' : 'NONE'}`)
              .fontSize(11).height(26).padding({ left: 10, right: 10 }).margin({ right: 8, bottom: 8 })
              .backgroundColor(this.rtCullBack ? Theme.accent : Theme.surfaceElevated)
              .fontColor(this.rtCullBack ? Theme.bg : Theme.textPrimary)
              .onClick(() => { this.rtCullBack = !this.rtCullBack; })
            Button(`范围：${this.rtScopeAll ? '两者都改' : '仅切片路径'}`)
              .fontSize(11).height(26).padding({ left: 10, right: 10 }).margin({ right: 8, bottom: 8 })
              .backgroundColor(this.rtScopeAll ? Theme.accent : Theme.surfaceElevated)
              .fontColor(this.rtScopeAll ? Theme.bg : Theme.textPrimary)
              .onClick(() => { this.rtScopeAll = !this.rtScopeAll; })
          }
          .width('100%')

          Text(`最近 1 秒 FPS：${this.fps}`)
            .fontSize(11)
            .fontColor(Theme.accentSoft)
            .fontFamily('monospace')
            .width('100%')
          // 如实告诉用户：这一档现在作用在谁身上
          Text(`作用范围：${this.rtScopeAll ? '模型预览 + 切片路径' : '仅切片路径（模型预览保持默认后处理）'}` +
            ` · 切片路径当前${this.gcodeShow ? '显示中' : '未显示'}`)
            .fontSize(10)
            .fontColor(Theme.textSecondary)
            .width('100%')
          Text('默认 = 现状（MSAA 开 / Bloom 开 / Vignette 开 / 剔除 NONE）；每拨一次实时生效并落一条 [RenderTune] 日志')
            .fontSize(10)
            .fontColor(Theme.textSecondary)
            .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .border({ width: { bottom: 1 }, color: Theme.border })

      Scroll() {
        Column({ space: 1 }) {
          if (this.logs.length === 0) {
            Text('暂无日志')
              .fontSize(12)
              .fontColor(Theme.textSecondary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 48 })
          }
          ForEach(this.logs, (line: string, index: number) => {
            Text(line)
              .fontSize(11)
              .fontColor(Theme.textPrimary)
              .width('100%')
              .padding({ left: 16, right: 16, top: 3, bottom: 3 })
          }, (line: string, index: number) => `${index}-${line}`)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.On)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
