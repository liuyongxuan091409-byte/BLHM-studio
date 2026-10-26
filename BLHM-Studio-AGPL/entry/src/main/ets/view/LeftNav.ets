import { Theme } from '../common/Theme';
import { PressGlow } from '../common/Glow';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { IAP_ENTRY_VISIBLE } from '../service/IapService';

// 左侧竖向导航（对齐 Bambu Studio 主工作流：准备/预览/设备/校准）
// 图标：统一 24×24 线性矢量图标（描边 1.7，圆角端点），选中态用品牌绿
// 交互：整条栏目是一块「光晕活动区」——指针在栏内移动时，一团绿色径向光
//       跟着指针在整栏里自由游走（不是每个按钮各自一块）。见 common/Glow.ets。
@Component
export struct LeftNav {
  @Prop active: number = 0;
  onChange: (index: number) => void = () => {};
  onSettings: () => void = () => {};
  onTip: () => void = () => {};

  private tabs: string[] = ['准备', '预览', '设备', '校准'];

  // 沉浸材质：系统支持就用真·系统材质（左侧呈现透亮的玻璃质地），否则退回普通模糊。
  @State private matSupported: boolean = false;
  private material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#141A1E24'
  });

  aboutToAppear(): void {
    try {
      this.matSupported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      this.matSupported = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 上部主工作流（准备/预览/设备/校准）
        Column({ space: 2 }) {
          ForEach(this.tabs, (label: string, index: number) => {
            this.navItem(label, index)
          }, (label: string, index: number) => `${label}-${index}`)
        }
        .width('100%')
        .layoutWeight(1)

        // 日志上方的空白处：打赏（在「设置」上方）→ 设置
        // ★ 内购手续未办妥期间隐藏「打赏」入口：只是不渲染，tipItem()/TipPanel/
        //   IapService 代码全部保留，把 IapService.IAP_ENTRY_VISIBLE 改回 true 即恢复。
        if (IAP_ENTRY_VISIBLE) {
          this.tipItem()
        }
        this.settingsItem()

        // 左下角：日志
        this.navItem('日志', 4)
      }
      .width('100%')
      .height('100%')

      // 光晕层：铺满整栏；指针监听在它身上（最上层 → 一定拿得到事件），
      // 又因为 HitTestMode.Transparent，不挡下面按钮的点击。
      PressGlow({ radius: 70 })
    }
    .width(64)
    .height('100%')
    .padding({ top: 0, bottom: 8 })
    .clip(true)
    .backgroundColor(this.matSupported ? Color.Transparent : Theme.surface)
    .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1, brightness: 1.05 })
    .systemMaterial(this.matSupported ? this.material : undefined)
    .border({ width: { right: 1 }, color: Theme.border })
  }

  // 「打赏」导航项：位于「设置」上方，风格与既有导航项一致（选中态品牌绿）
  @Builder
  tipItem() {
    Column({ space: 3 }) {
      this.navIcon(6)
      Text('打赏')
        .fontSize(11)
        .fontColor(Theme.textSecondary)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.onTip(); })
  }

  @Builder
  settingsItem() {
    Column({ space: 3 }) {
      this.navIcon(5)
      Text('设置')
        .fontSize(11)
        .fontColor(Theme.textSecondary)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.onSettings(); })
  }

  @Builder
  navItem(label: string, index: number) {
    Column({ space: 3 }) {
      this.navIcon(index)
      Text(label)
        .fontSize(11)
        .fontColor(this.iconColor(index))
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.onChange(index); })
  }

  // 图标颜色：选中态用品牌绿，其余次文字色
  private iconColor(index: number): string {
    return this.active === index ? Theme.accent : Theme.textSecondary;
  }

  // 单个矢量图标（24×24 坐标系，线性描边风格）
  @Builder
  navIcon(index: number) {
    Path()
      .width(24)
      .height(24)
      .commands(this.iconPath(index))
      .fill(Color.Transparent)
      .stroke(this.iconColor(index))
      .strokeWidth(1.7)
      .strokeLineCap(LineCapStyle.Round)
      .strokeLineJoin(LineJoinStyle.Round)
  }

  // 七个功能图标的路径数据（0 准备 / 1 预览 / 2 设备 / 3 校准 / 4 日志 / 5 设置 / 6 打赏）
  private iconPath(index: number): string {
    if (index === 0) {
      // 准备：平台上的模型方块
      return 'M12 4.5 L18.5 8.2 L12 11.9 L5.5 8.2 Z M5.5 8.2 L5.5 14.2 M18.5 8.2 L18.5 14.2 ' +
        'M12 11.9 L12 17.9 M4.5 19.5 L19.5 19.5';
    }
    if (index === 1) {
      // 预览：眼睛
      return 'M3 12 C7 6.2 9.7 4.6 12 4.6 C14.3 4.6 17 6.2 21 12 C17 17.8 14.3 19.4 12 19.4 ' +
        'C9.7 19.4 7 17.8 3 12 Z M12 12 m-3.1 0 a3.1 3.1 0 1 0 6.2 0 a3.1 3.1 0 1 0 -6.2 0';
    }
    if (index === 2) {
      // 设备：打印机
      return 'M8 4 L16 4 L16 8.5 M4 8.5 L20 8.5 L20 17.5 L4 17.5 Z M7 13 L13.5 13 ' +
        'M8 17.5 L8 20 L16 20 L16 17.5';
    }
    if (index === 3) {
      // 校准：靶心 + 十字准星
      return 'M12 12 m-6.5 0 a6.5 6.5 0 1 0 13 0 a6.5 6.5 0 1 0 -13 0 ' +
        'M12 2.5 L12 5.5 M12 18.5 L12 21.5 M2.5 12 L5.5 12 M18.5 12 L21.5 12 ' +
        'M12 12 m-2 0 a2 2 0 1 0 4 0 a2 2 0 1 0 -4 0';
    }
    if (index === 4) {
      // 日志：文档
      return 'M6.5 3.5 L14 3.5 L17.5 7 L17.5 20.5 L6.5 20.5 Z M14 3.5 L14 7 L17.5 7 ' +
        'M9.5 11 L14.5 11 M9.5 14 L14.5 14 M9.5 17 L12.5 17';
    }
    if (index === 6) {
      // 打赏：爱心
      return 'M12 20.4 C12 20.4 3.6 15.1 3.6 9.3 C3.6 6.5 5.8 4.6 8.1 4.6 ' +
        'C10 4.6 11.3 5.7 12 6.9 C12.7 5.7 14 4.6 15.9 4.6 C18.2 4.6 20.4 6.5 20.4 9.3 ' +
        'C20.4 15.1 12 20.4 12 20.4 Z';
    }
    // 设置：滑杆
    return 'M3.5 6.5 L12.7 6.5 M17.3 6.5 L20.5 6.5 M15 6.5 m-2.3 0 a2.3 2.3 0 1 0 4.6 0 a2.3 2.3 0 1 0 -4.6 0 ' +
      'M3.5 12 L6.7 12 M11.3 12 L20.5 12 M9 12 m-2.3 0 a2.3 2.3 0 1 0 4.6 0 a2.3 2.3 0 1 0 -4.6 0 ' +
      'M3.5 17.5 L12.7 17.5 M17.3 17.5 L20.5 17.5 M15 17.5 m-2.3 0 a2.3 2.3 0 1 0 4.6 0 a2.3 2.3 0 1 0 -4.6 0';
  }
}
