import { Theme } from '../common/Theme';
import { PressGlow } from '../common/Glow';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { RecentDoc } from '../model/DocState';

// 最近文件条目的「时间 · 大小」副标题。
// 为什么自己格式化而不是引库：只需要 MM-DD HH:mm 与 KB/MB 两档，二十行能搞定的事不值得加依赖。
function fmtTime(at: number): string {
  if (at <= 0) {
    return '';
  }
  const d: Date = new Date(at);
  const p2 = (v: number): string => v < 10 ? `0${v}` : `${v}`;
  return `${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`;
}

function fmtSize(b: number): string {
  if (b <= 0) {
    return '';
  }
  if (b < 1024) {
    return `${b} B`;
  }
  if (b < 1024 * 1024) {
    return `${(b / 1024).toFixed(0)} KB`;
  }
  return `${(b / 1024 / 1024).toFixed(1)} MB`;
}

// 顶栏：Logo + 当前工程名（带未保存标记）+ 文档菜单。
// 右上角留给系统自绘的三大键（最小化/最大化/关闭），故右侧预留内边距
// 注：「耗材编辑」入口已移到右侧参数面板「耗材」选择器正下方（见 DynamicParamsPanel）
//
// 【为什么菜单挂在工程名上】文件级操作（保存/另存为/打开/最近）在桌面软件里就长在标题上；
// 放在这里既不占额外按钮，也符合「点文件名 = 管这个文件」的直觉。
// 具体实现都在 Index（那里才有 UIContext 与导出/导入链路），这里只发回调。
@Component
export struct TopBar {
  // 当前工程名与脏标记（由 model/DocState 发布）
  @StorageLink('docName') docName: string = '未命名项目.3mf';
  @StorageLink('docDirty') docDirty: boolean = false;
  @StorageLink('docRecents') recents: RecentDoc[] = [];

  onNewDoc: () => void = (): void => {};
  onSaveDoc: () => void = (): void => {};
  onSaveAsDoc: () => void = (): void => {};
  onOpenDoc: () => void = (): void => {};
  onOpenRecent: (path: string) => void = (path: string): void => {};
  onRemoveRecent: (path: string) => void = (path: string): void => {};
  onClearRecents: () => void = (): void => {};

  // 受控菜单开关：用 bindMenu(isShow, …) 的**受控**重载，而不是隐式触发 ——
  // 实测这台机器上「点击触发 bindMenu」不响应（触摸点击打开不了菜单）。
  @State private menuShown: boolean = false;

  // 沉浸材质：系统支持就用真·系统材质（顶栏呈现玻璃质地），否则退回纯色底。
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
      Row() {
      Text('BLHM')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary)
      Text('studio')
        .fontSize(11)
        .fontColor(Theme.accent)
        .margin({ left: 6, top: 4 })
      Divider()
        .vertical(true)
        .height(20)
        .color(Theme.border)
        .margin({ left: 14, right: 14 })

      // 工程名 + 未保存标记（●）+ 菜单指示（▾）；点它开文档菜单
      Row({ space: 5 }) {
        Text(this.docName)
          .fontSize(13)
          .fontColor(Theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 240 })
        if (this.docDirty) {
          Text('●')
            .fontSize(9)
            .fontColor(Theme.modified)
        }
        Text('▾')
          .fontSize(9)
          .fontColor(Theme.textSecondary)
      }
      .padding({ left: 8, right: 8, top: 5, bottom: 5 })
      .borderRadius(6)
      .backgroundColor('#14FFFFFF')
      .onClick(() => { this.openDocMenu(); })
      .bindMenu(this.menuShown, this.docMenu(), {
        placement: Placement.BottomLeft,
        enableArrow: false,
        offset: { x: 0, y: 4 },
        backgroundColor: Color.Transparent
      })

      Blank()
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 140 })
      .backgroundColor(this.matSupported ? Color.Transparent : Theme.surface)
      .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1, brightness: 1.05 })
      .systemMaterial(this.matSupported ? this.material : undefined)
      .border({ width: { bottom: 1 }, color: Theme.border })
      // 光晕层：按住指针时在顶栏内亮起绿色光点
      PressGlow({ radius: 70 })
    }
    .width('100%')
    .height(44)
    .clip(true)
  }

  // 打开文档菜单：先置 false 再在下一拍置 true。
  // 为什么不是简单取反：受控 `isShow` 与「点外部自动关闭」不同步 —— 菜单被外部关掉后
  // menuShown 仍是 true，此时再点标题若只是取反就会变成 false（看起来「点不开」）。
  private openDocMenu(): void {
    this.menuShown = false;
    setTimeout(() => { this.menuShown = true; }, 16);
  }

  // 文档菜单：保存 / 另存为 / 打开工程 / 最近打开
  @Builder
  docMenu() {
    Column() {
      this.docMenuItem('新建工程', 'new')
      this.docMenuItem('保存', 'save')
      this.docMenuItem('另存为…', 'saveas')
      this.docMenuItem('打开工程…', 'open')
      if (this.recents.length > 0) {
        Divider().strokeWidth(1).color('#1FFFFFFF').margin({ top: 4, bottom: 4 })
        Row() {
          Text('最近打开')
            .fontSize(10)
            .fontColor(Theme.textSecondary)
          Blank()
          Text('清空')
            .fontSize(10)
            .fontColor(Theme.accent)
            .padding({ left: 6, right: 2, top: 2, bottom: 2 })
            .onClick(() => { this.menuShown = false; this.onClearRecents(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 2, bottom: 4 })

        ForEach(this.recents, (r: RecentDoc) => {
          Row({ space: 6 }) {
            Column({ space: 1 }) {
              Text(r.name)
                .fontSize(12)
                .fontColor(Theme.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${fmtTime(r.at)}${fmtSize(r.size).length > 0 ? ' · ' + fmtSize(r.size) : ''}`)
                .fontSize(9)
                .fontColor(Theme.textSecondary)
                .maxLines(1)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 移除单个条目（连同沙箱里的副本一起删）
            Text('✕')
              .fontSize(10)
              .fontColor(Theme.textSecondary)
              .padding({ left: 6, right: 2, top: 4, bottom: 4 })
              .onClick(() => { this.onRemoveRecent(r.path); })
          }
          .width('100%')
          .padding({ left: 12, right: 10, top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.menuShown = false; this.onOpenRecent(r.path); })
        }, (r: RecentDoc) => `recent-${r.path}-${r.at}`)
      }
    }
    .width(260)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.matSupported ? Color.Transparent : '#E616161C')
    .systemMaterial(this.matSupported ? this.material : undefined)
  }

  @Builder
  docMenuItem(label: string, kind: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Theme.textPrimary)
    }
    .width('100%')
    .height(36)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.menuShown = false;   // 受控菜单：自己负责收起
      if (kind === 'new') {
        this.onNewDoc();
      } else if (kind === 'save') {
        this.onSaveDoc();
      } else if (kind === 'saveas') {
        this.onSaveAsDoc();
      } else {
        this.onOpenDoc();
      }
    })
  }
}
