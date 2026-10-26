import { Theme } from '../common/Theme';
import { TIP_PRODUCTS, TipProduct, IapService } from '../service/IapService';
import promptAction from '@ohos.promptAction';

// 打赏页（UI 原型）：内容区普通页面，左侧导航栏常驻可见 —— 与「设置」页同一模式，非全屏浮层。
// 本轮仅 UI + 调用桩：点「确认打赏」只弹提示 + 打日志（tag Tip），绝不发起任何真实支付/网络请求。
//
// 两处半透明色为既有主题色的 alpha 叠加（不新造色板）：
//   选中态底色 = Theme.accent(00C48C) ~10% 不透明度；橙色小标底色/描边 = Theme.modified(FF8C1A) 的 8% / 40%。
const TIP_SEL_BG: string = '#1A00C48C';
const TIP_CHIP_BG: string = '#14FF8C1A';
const TIP_CHIP_BORDER: string = '#66FF8C1A';

@Component
export struct TipPanel {
  @State private selectedAmount: number = 0;

  private filesDir(): string {
    const ctx = this.getUIContext().getHostContext();
    return ctx === undefined ? '' : ctx.filesDir;
  }

  // 金额卡片：再点一次取消（selectedAmount 归零 → 确认按钮置灰）
  private pick(amount: number): void {
    this.selectedAmount = this.selectedAmount === amount ? 0 : amount;
  }

  // 确认：本轮仅「桩」—— 弹提示 + 打日志，绝不发起真实支付 / 网络请求
  private confirm(): void {
    if (this.selectedAmount <= 0) {
      return;
    }
    const productId: string = `tip_${this.selectedAmount}`;
    promptAction.showToast({ message: '支付未接入（原型）', duration: 2000 });
    IapService.createPurchase(this.filesDir(), productId);
  }

  // 单个金额卡片：等宽数字 + 「元」；选中态 = 品牌绿描边 + 浅绿底 + 右上角对勾
  @Builder
  amountCard(p: TipProduct) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Text(`${p.amount}`)
          .fontSize(23)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .fontColor(this.selectedAmount === p.amount ? Theme.accent : Theme.textPrimary)
        Text('元')
          .fontSize(11)
          .fontColor(this.selectedAmount === p.amount ? Theme.accentSoft : Theme.textSecondary)
          .margin({ top: 2 })
      }
      .width(132)
      .height(78)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.selectedAmount === p.amount ? TIP_SEL_BG : Theme.surface)
      .border({ width: 1, color: this.selectedAmount === p.amount ? Theme.accent : Theme.border })

      if (this.selectedAmount === p.amount) {
        Text('✓')
          .fontSize(13)
          .fontColor(Theme.accent)
          .margin({ top: 8, right: 10 })
      }
    }
    .width(132)
    .height(78)
    .margin({ right: 12, bottom: 12 })
    .onClick(() => { this.pick(p.amount); })
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          // 标题 + 橙色小标
          Row({ space: 10 }) {
            Text('打赏')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary)
            Text('当前为 UI 原型 · 尚未接入支付')
              .fontSize(11)
              .fontColor(Theme.modified)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(999)
              .backgroundColor(TIP_CHIP_BG)
              .border({ width: 1, color: TIP_CHIP_BORDER })
          }
          .width('100%')

          Text('支持开发者继续维护 BLHM studio')
            .fontSize(12)
            .fontColor(Theme.textSecondary)
            .margin({ top: 6, bottom: 20 })

          // 感谢语卡片（深色玻璃卡 + 圆角 12）
          Column({ space: 10 }) {
            Text('谢谢你愿意支持这个项目。')
              .fontSize(13.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary)
            Text('BLHM studio 是我利用业余时间一点点做出来的：从切片预览的性能、到双喷嘴的区域判定、' +
              '再到每一处崩溃的排查，基本都是反复在真机上磨出来的。它不含任何厂商闭源组件，' +
              '切片内核来自开源的 libslic3r。')
              .fontSize(13.5)
              .fontColor(Theme.textPrimary)
              .lineHeight(24)
            Text() {
              Span('如果你觉得它帮到了你的工作或兴趣，可以在这里随意打赏一笔 —— ')
                .fontSize(13.5)
                .fontColor(Theme.textPrimary)
              Span('金额不影响任何功能')
                .fontSize(13.5)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary)
              Span('，只是让我知道有人在用、并愿意继续投入。无论打不打赏，功能都是完整的。')
                .fontSize(13.5)
                .fontColor(Theme.textPrimary)
            }
            .lineHeight(24)
            .width('100%')
            Text('—— 姜鹏')
              .fontSize(12)
              .fontColor(Theme.textSecondary)
          }
          .width('100%')
          .padding({ left: 22, right: 22, top: 20, bottom: 20 })
          .borderRadius(12)
          .backgroundColor(Theme.surface)
          .border({ width: 1, color: Theme.border })
          .alignItems(HorizontalAlign.Start)

          // 选择金额
          Text('选择金额')
            .fontSize(13)
            .fontColor(Theme.textSecondary)
            .margin({ top: 24, bottom: 10 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(TIP_PRODUCTS, (p: TipProduct) => {
              this.amountCard(p)
            }, (p: TipProduct) => p.productId)
          }
          .width('100%')

          // 底部：确认按钮 + 说明
          Row({ space: 16 }) {
            Button('确认打赏')
              .height(40)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .borderRadius(10)
              .padding({ left: 30, right: 30 })
              .enabled(this.selectedAmount > 0)
              .backgroundColor(this.selectedAmount > 0 ? Theme.accent : Theme.surfaceElevated)
              .fontColor(this.selectedAmount > 0 ? Theme.bg : Theme.textSecondary)
              .border({ width: 1, color: this.selectedAmount > 0 ? Theme.accent : Theme.border })
              .onClick(() => { this.confirm(); })

            Column() {
              Text() {
                Span('将通过 ')
                  .fontSize(12)
                  .fontColor(Theme.textSecondary)
                Span('华为应用内支付')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textSecondary)
                Span(' 完成，仅用于支持开发，不涉及任何功能解锁。')
                  .fontSize(12)
                  .fontColor(Theme.textSecondary)
              }
              .lineHeight(18)
              .width('100%')
              Text(this.selectedAmount > 0
                ? `已选择 ¥${this.selectedAmount}.00（productId 待定：tip_${this.selectedAmount}）`
                : '未选择金额')
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor(Theme.textSecondary)
                .margin({ top: 4 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 18 })
          .margin({ top: 26 })
          .border({ width: { top: 1 }, color: Theme.border })
        }
        .width('100%')
        .padding({ left: 28, right: 28, top: 26, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
