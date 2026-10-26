import { Theme } from '../common/Theme';

// 预览页：gcode 分层预览（占位，真实切片数据后续接入）
@Component
export struct PreviewPanel {
  @State currentLayer: number = 0;
  @State totalLayers: number = 248;
  @State showType: boolean = true; // 按特征类型着色

  private legend: string[] = ['外壁', '内壁', '填充', '支撑', '顶面', '桥接'];
  private legendColors: string[] = ['#E53935', '#1E88E5', '#43A047', '#FB8C00', '#8E24AA', '#00ACC1'];

  build() {
    Column() {
      // 顶部：层滑块 + 视图切换
      Row() {
        Text(`第 ${this.currentLayer} / ${this.totalLayers} 层`)
          .fontSize(13)
          .fontColor(Theme.textPrimary)
          .width(150)
        Slider({ value: this.currentLayer, min: 0, max: this.totalLayers, step: 1 })
          .selectedColor(Theme.accent)
          .trackColor(Theme.border)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })

      // 图例
      Row({ space: 14 }) {
        ForEach(this.legend, (name: string, index: number) => {
          Row({ space: 4 }) {
            Column()
              .width(10)
              .height(10)
              .borderRadius(2)
              .backgroundColor(this.legendColors[index])
            Text(name)
              .fontSize(11)
              .fontColor(Theme.textSecondary)
          }
        }, (name: string, index: number) => `${name}-${index}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      // 预览占位区
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('80%')
          .height('60%')
          .backgroundColor('#1A1A22')
          .borderRadius(8)
          .border({ width: 1, color: Theme.border })
        Text('G-code 分层预览占位')
          .fontSize(13)
          .fontColor(Theme.textSecondary)
      }
      .width('100%')
      .layoutWeight(1)

      // 底部摘要
      Row({ space: 20 }) {
        this.summaryItem('打印时间', '1h 42m')
        this.summaryItem('耗材用量', '18.4 g')
        this.summaryItem('总层数', `${this.totalLayers}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  summaryItem(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
      Text(label)
        .fontSize(11)
        .fontColor(Theme.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
  }
}
