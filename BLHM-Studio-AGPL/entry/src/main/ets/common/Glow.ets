import { Theme } from './Theme';

// 光标「绿色点光晕」：指针所在的位置渲染一团绿色径向光，随光标移动。
//
// 自包含：自己在图层内跟踪指针位置与显隐，父组件只要把它叠在最上层即可。
// 显隐策略：**按住才亮、松手即灭**（按下/拖动点亮，抬起熄灭）。不用 onHover —— 实测
// 平台在鼠标移动后会补发 hover 离开，用 hover 控显隐会让普通移动瞬间被关掉。
@Component
export struct PressGlow {
  @Prop radius: number = 70;        // 光晕半径（vp）
  @Prop strength: number = 0.7;     // 最大不透明度
  @Prop corner: number = 0;         // 圆角

  @State private cx: number = 50;   // 光点中心 x（百分比）
  @State private cy: number = 50;   // 光点中心 y（百分比）
  @State private lit: boolean = false;
  @State private w: number = 0;
  @State private h: number = 0;

  private move(x: number, y: number): void {
    if (this.w > 0) {
      this.cx = Math.max(0, Math.min(100, (x / this.w) * 100));
    }
    if (this.h > 0) {
      this.cy = Math.max(0, Math.min(100, (y / this.h) * 100));
    }
  }

  build() {
    Column()
      .width('100%')
      .height('100%')
      .borderRadius(this.corner)
      // 注意：center 必须给「百分比字符串」——给纯数字会被当成 vp 长度，
      // 于是中心恒定在左上角附近（表现为光晕卡在栏目顶部、不跟光标）。
      .radialGradient({
        center: [`${this.cx}%`, `${this.cy}%`],
        radius: this.radius,
        colors: [[Theme.glowHalo, 0.0], [Theme.glowTint, 0.45], ['#00000000', 1.0]]
      })
      .opacity(this.lit ? this.strength : 0)
      .animation({ duration: 140, curve: Curve.EaseOut })
      // 最上层且 Transparent：一定拿得到指针事件，又不挡下面按钮的点击
      .hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((_old: Area, now: Area) => {
        this.w = now.width as number;
        this.h = now.height as number;
      })
      .onMouse((e: MouseEvent) => {
        this.move(e.x, e.y);
        if (e.action === MouseAction.Press) {
          this.lit = true;
        } else if (e.action === MouseAction.Release) {
          this.lit = false;
        }
      })
      .onTouch((e: TouchEvent) => {
        const t = e.touches[0];
        if (t !== undefined) {
          this.move(t.x, t.y);
        }
        if (e.type === TouchType.Down || e.type === TouchType.Move) {
          this.lit = true;
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.lit = false;
        }
      })
  }
}
