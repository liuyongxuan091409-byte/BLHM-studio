import { Theme } from '../common/Theme';
import { PressGlow } from '../common/Glow';

// 底部操作栏：左侧「撤销 / 重做 / 保存」，右侧「切片 / 打印」（对齐 Bambu Studio）
@Component
export struct SliceBar {
  onSlice: () => void = () => {};
  onPrint: () => void = () => {};
  onSave: () => void = () => {};
  onUndo: () => void = () => {};
  onRedo: () => void = () => {};
  // 可用态：**直接订阅 AppStorage**，而不是由 Index 传普通成员变量进来。
  // 原因（ArkUI 的坑）：子组件的普通成员只在初始化时赋值一次，父组件后续变化不会同步 →
  // 「按钮永远灰着」正是这个现象。@StorageLink 才是能实时更新的通道（History 每次栈变化都会写这两个键）。
  @StorageLink('historyCanUndo') canUndo: boolean = false;
  @StorageLink('historyCanRedo') canRedo: boolean = false;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
      // 撤销 / 重做：不可用时整颗按钮变暗且禁用（避免"点了没反应"）
      Button('撤销')
        .height(34)
        .padding({ left: 12, right: 12 })
        .fontSize(13)
        .fontColor(this.canUndo ? Theme.textSecondary : '#4A4A52')
        .backgroundColor(Color.Transparent)
        .borderRadius(17)
        .border({ width: 1, color: this.canUndo ? Theme.border : '#26262C' })
        .margin({ right: 6 })
        .enabled(this.canUndo)
        .stateEffect(true)
        .onClick(() => {
          this.onUndo();
        })
      Button('重做')
        .height(34)
        .padding({ left: 12, right: 12 })
        .fontSize(13)
        .fontColor(this.canRedo ? Theme.textSecondary : '#4A4A52')
        .backgroundColor(Color.Transparent)
        .borderRadius(17)
        .border({ width: 1, color: this.canRedo ? Theme.border : '#26262C' })
        .margin({ right: 6 })
        .enabled(this.canRedo)
        .stateEffect(true)
        .onClick(() => {
          this.onRedo();
        })
      // 次要操作：幽灵按钮，避免与主操作（切片）抢视觉
      // 注：原「导入」按钮已移除 —— 它的语义（打开一个 3MF 工程）现在由顶栏「工程名 ▾ → 打开工程…」承载，
      // 底部再放一个入口只会让人以为是「导入模型」（那是顶栏抽屉里的另一件事）。
      Button('保存')
        .height(34)
        .padding({ left: 18, right: 18 })
        .fontSize(13)
        .fontColor('#6B6B78')
        .backgroundColor(Color.Transparent)
        .borderRadius(17)
        .border({ width: 1, color: Theme.border })
        .stateEffect(true)
        .onClick(() => {
          this.onSave();
        })

      Blank()

      Button('切片')
        .height(36)
        .padding({ left: 24, right: 24 })
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#06281E')
        .backgroundColor(Theme.accent)
        .borderRadius(18)
        .margin({ right: 10 })
        .onClick(() => {
          this.onSlice();
        })
      Button('打印')
        .height(36)
        .padding({ left: 24, right: 24 })
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
        .backgroundColor(Theme.surfaceElevated)
        .borderRadius(18)
        .border({ width: 1, color: Theme.border })
        .onClick(() => {
          this.onPrint();
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Theme.surface)
    .border({ width: { top: 1 }, color: Theme.border })
      // 光晕层：按住指针时在底栏内亮起绿色光点
      PressGlow({ radius: 70 })
    }
    .width('100%')
    .height(52)
    .clip(true)
  }
}
