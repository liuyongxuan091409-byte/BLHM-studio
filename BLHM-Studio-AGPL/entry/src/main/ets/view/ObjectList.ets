import { Theme } from '../common/Theme';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { PressGlow } from '../common/Glow';
import { ModelFile, PlateMeta } from '../model/Models';
import { modelState } from '../model/ModelState';
import { getThumbnail, ensureThumbnail, dropThumbnail } from '../model/Thumbnail';
import { history } from '../model/History';
import { objClipboard } from '../model/ObjClipboard';
import { confirmDeleteObjects } from '../service/ObjActions';
import image from '@ohos.multimedia.image';
import promptAction from '@ohos.promptAction';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 左侧面板：准备页下的对象列表（对齐 Bambu Studio 左侧对象列表）
// 对象数据来自 AppStorage('modelObjects')（轻量元数据），网格数据在 ModelState 单例
// 每行：左侧模型渲染缩略图 + 文件名 / 格式信息，右侧「两点」圆形按钮弹出操作菜单（复制 / 删除）
@Component
export struct ObjectList {
  @StorageLink('modelObjects') objects: ModelFile[] = [];
  @StorageLink('selectedModelId') selectedId: number = -1;
  // 剪贴板里的对象数：>0 时右键菜单才显示「粘贴到本盘」（避免空粘贴点了没反应）
  @StorageLink('clipboardCount') clipboardCount: number = 0;
  // 当前选中的对象集合（ModelState 多选模型发布到 AppStorage）：用于「多选高亮」与「组操作」
  @StorageLink('selectedModelIds') selectedIds: number[] = [];

  // 行是否属于当前选中集合（多选高亮用；单选时它就是唯一那行）
  private isRowSelected(id: number): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  // 组操作的目标集合：该行在选中集合里 → 作用于整组（桌面语义）；否则只作用于该行
  private targetsFor(id: number): number[] {
    const sel: number[] = modelState.selectedIds;
    return sel.indexOf(id) >= 0 ? sel.slice() : [id];
  }
  @StorageLink('modelPlates') plates: PlateMeta[] = [];
  @StorageLink('activePlate') activePlate: number = -1;
  // 后台缩略图就绪计数（见 Thumbnail.ensureThumbnail）：大模型缩略图异步生成，
  // 完成后 bump 此值 → 本组件重渲染 → 图标出现（不再像旧实现那样同步阻塞导入）。
  @StorageLink('thumbSeq') thumbSeq: number = 0;

  // 沉浸材质：系统支持就用真·系统材质（面板与延伸菜单呈现玻璃质地），否则退回普通模糊/纯色。
  @State private matSupported: boolean = false;
  private material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#141A1E24'
  });

  // 缩略图是否已就绪：读取 this.thumbSeq 让本组件订阅其变化（异步就绪后重新渲染）。
  private thumbReady(id: number): boolean {
    return this.thumbSeq >= 0 && getThumbnail(id) !== undefined;
  }

  // 按当前盘过滤（未分盘的模型始终显示；无盘信息时不过滤）
  private visibleObjects(): ModelFile[] {
    if (this.activePlate <= 0) {
      return this.objects;
    }
    const out: ModelFile[] = [];
    for (const o of this.objects) {
      if (o.plate <= 0 || o.plate === this.activePlate) {
        out.push(o);
      }
    }
    return out;
  }

  aboutToAppear(): void {
    try {
      this.matSupported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      this.matSupported = false;
    }
    if (AppStorage.get<ModelFile[]>('modelObjects') === undefined) {
      AppStorage.setOrCreate<ModelFile[]>('modelObjects', []);
    }
    if (AppStorage.get<number>('selectedModelId') === undefined) {
      AppStorage.setOrCreate<number>('selectedModelId', -1);
    }
    // 补齐已有对象的缩略图（页面重挂载时）
    for (const obj of this.objects) {
      const inst = modelState.get(obj.id);
      if (inst !== undefined) {
        ensureThumbnail(obj.id, inst.geometry);
      }
    }
  }

  // 复制对象 → **只进剪贴板**（不在板上立刻产生副本）：
  // 与桌面版 Ctrl+C 的语义一致；用户明确要求「复制后不要立刻多一个副本，粘贴时才出现」。
  // 注意：这一步没有改变工程内容，所以**不记撤销**。
  private doCopy(id: number): void {
    const n: number = objClipboard.copy(this.targetsFor(id));
    if (n === 0) {
      promptAction.showToast({ message: '复制失败：对象不存在' });
      return;
    }
    promptAction.showToast({ message: `已复制 ${n} 个对象到剪贴板（空白处右键或菜单里的「粘贴」放回板上）` });
  }

  // 剪切：进剪贴板 + 从板上移除（整步可撤销；该行属于多选集合时作用于整组）
  private doCut(id: number): void {
    const ids: number[] = this.targetsFor(id);
    const n: number = objClipboard.cut(ids);
    if (n === 0) {
      promptAction.showToast({ message: '剪切失败：对象不存在' });
      return;
    }
    for (const cid of ids) {
      dropThumbnail(cid);
    }
    if (modelState.instances.length === 0) {
      AppStorage.setOrCreate<string>('sliceModelPath', '');
    }
    history.commitNow('剪切对象');
    promptAction.showToast({ message: `已剪切 ${n} 个对象到剪贴板` });
  }

  // 粘贴到指定盘（plate <= 0 = 保持各对象原盘）；缩略图要重建（剪贴板里是克隆）
  private pasteTo(plate: number): void {
    const ids: number[] = objClipboard.paste(plate);
    if (ids.length === 0) {
      promptAction.showToast({ message: '剪贴板为空' });
      return;
    }
    for (const nid of ids) {
      const o = modelState.get(nid);
      if (o !== undefined) {
        ensureThumbnail(nid, o.geometry);
      }
    }
    history.commitNow('粘贴对象');
    promptAction.showToast({ message: `已粘贴 ${ids.length} 个对象` });
  }

  // 对象行菜单「粘贴到本盘」：目标盘 = 该行对象所在的盘
  private doPaste(id: number): void {
    const inst = modelState.get(id);
    this.pasteTo(inst !== undefined ? inst.plate : -1);
  }

  // 空白处菜单「粘贴到当前盘」：目标盘 = 当前选中的盘（没有选中盘则保持对象原盘）
  private doPasteHere(): void {
    this.pasteTo(this.activePlate > 0 ? this.activePlate : -1);
  }

  // 删除前确认。
  // 为什么不用全局 promptAction.showDialog：该接口自 API 18 起废弃，官方文档明确它依赖一个
  // “隐式 UI 上下文（ambiguous UI context）”，在多窗口/新版本上可能落到错误的实例甚至直接 reject。
  // 旧代码把 reject 静默 catch 掉，表现就是“点删除没有任何反应”。
  // 具体实现（含整组与撤销）在 service/ObjActions，与 PC 上的 Delete 快捷键共用同一套语义。
  private confirmDelete(id: number): void {
    confirmDeleteObjects(this.getUIContext(), this.targetsFor(id));
  }

  // 该对象**可移动到的**其它盘号（排除它当前所在的那块盘）。
  // 盘号来自盘注册表派生的 PlateMeta 列表：只有真的存在的盘才会出现在菜单里。
  private otherPlates(obj: ModelFile): number[] {
    const out: number[] = [];
    for (const p of this.plates) {
      if (p.index !== obj.plate) {
        out.push(p.index);
      }
    }
    return out;
  }

  // 把对象（选中集合整体）移到指定盘；plate=0 = 移出打印板（回到「未分盘」）。
  // 走 ModelState.moveObjectsToPlate（盘号口径的唯一实现）+ publish（3D 侧按盘过滤可见性）
  // + 一步撤销 —— 三件事缺一个都会出现「切了盘但画面/撤销不对」。
  private doMoveToPlate(id: number, plate: number): void {
    const ids: number[] = this.targetsFor(id);
    modelState.moveObjectsToPlate(ids, plate);
    modelState.publish();
    history.commitNow('移动到打印板');
    promptAction.showToast({
      message: plate > 0
        ? `已把 ${ids.length} 个对象移到打印板 ${plate}`
        : `已把 ${ids.length} 个对象移出打印板`
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      // ---- 盘列表（最小实现）：有几个盘、每盘床型与含哪些对象 ----
      // 说明：数据来自 ModelState.publish() 汇总出的 PlateMeta（导入时由内核 3MF 加载器给出）。
      // 单盘时只有一行，不突兀；无盘时整块不渲染。
      if (this.plates.length >= 1) {
        Column({ space: 4 }) {
          Row({ space: 5 }) {
            Column()
              .width(5)
              .height(5)
              .borderRadius(2.5)
              .backgroundColor(Theme.accent)
            Text('盘')
              .fontSize(10)
              .letterSpacing(1)
              .fontColor(Theme.textSecondary)
            Blank()
            Text(`${this.plates.length}`)
              .fontSize(10)
              .fontColor('#5D6270')
          }
          .width('100%')
          .padding({ left: 2 })

          ForEach(this.plates, (p: PlateMeta) => {
            this.plateRow(p)
          }, (p: PlateMeta) => `plate-${p.index}`)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 6, bottom: 8 })
      }

      Row({ space: 8 }) {
        Text('对象')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        if (this.plates.length >= 2 && this.activePlate > 0) {
          Text(`盘 ${this.activePlate}`)
            .fontSize(10)
            .fontColor(Theme.accentSoft)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
            .backgroundColor('#1F2B27')
        }
        Blank()
        Text(`${this.visibleObjects().length}`)
          .fontSize(12)
          .fontColor(Theme.textSecondary)
      }
      .width('100%')
      .padding(10)

      // 多选入口提示（与参数面板「长按看说明」同一风格）
      Text('提示：Ctrl+点击或长按对象行加选/减选，Ctrl+A 全选；多选后可整组拖动、删除、复制')
        .fontSize(10)
        .fontColor(Theme.textSecondary)
        .width('100%')
        .padding({ left: 10, right: 10, bottom: 6 })

      if (this.visibleObjects().length === 0) {
        Column({ space: 6 }) {
          Text('尚未导入模型')
            .fontSize(12)
            .fontColor(Theme.textSecondary)
          Text('点击中间「导入模型」添加')
            .fontSize(11)
            .fontColor(Theme.textSecondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 4 }) {
          ForEach(this.visibleObjects(), (obj: ModelFile) => {
            ListItem() {
              Row({ space: 10 }) {
                // 左侧：模型渲染缩略图
                Stack() {
                  if (this.thumbReady(obj.id)) {
                    Image(getThumbnail(obj.id) as image.PixelMap)
                      .width(40)
                      .height(40)
                      .objectFit(ImageFit.Contain)
                      .interpolation(ImageInterpolation.High)
                  } else {
                    Text(obj.format)
                      .fontSize(10)
                      .fontColor(Theme.textSecondary)
                  }
                }
                .width(44)
                .height(44)
                .borderRadius(8)
                .backgroundColor(Theme.surfaceElevated)
                .border({
                  width: 1,
                  color: this.isRowSelected(obj.id) ? Theme.accent : Theme.border
                })

                // 中间：原始文件名 + 格式信息
                Column({ space: 2 }) {
                  Text(obj.name)
                    .fontSize(12)
                    .fontColor(Theme.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${obj.format} · ${obj.triangles} 三角面`)
                    .fontSize(10)
                    .fontColor(Theme.textSecondary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 右侧：圆形「两点」按钮 → 延伸菜单
                this.dotsButton(obj)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor(this.isRowSelected(obj.id) ? '#1F2B27' : Color.Transparent)
              .borderRadius(8)
              .onClick(() => {
                // Ctrl+点击 = 加选/减选（与桌面习惯一致；按键状态由工作区根容器广播到 AppStorage，
                // 因为这里的点击回调拿不到按键事件）
                if (AppStorage.get<boolean>('ctrlDown') ?? false) {
                  modelState.toggle(obj.id);
                  return;
                }
                modelState.select(obj.id);
                this.selectedId = obj.id;
              })
              // 长按 = 加选 / 减选（触屏上的多选入口；PC 上也可用工具栏「框选」拖矩形）
              .gesture(LongPressGesture({ repeat: false })
                .onAction(() => {
                  modelState.toggle(obj.id);
                  promptAction.showToast({ message: `已选中 ${modelState.selectedIds.length} 个对象` });
                }))
            }
          }, (obj: ModelFile) => `${obj.id}-${this.thumbSeq}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      }
      // 光晕层：铺满整栏；指针监听挂在最上层（一定拿得到事件），Transparent 不挡下面按钮点击
      PressGlow({ radius: 70 })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor(this.matSupported ? Color.Transparent : Theme.bg)
    .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.1, brightness: 1.05 })
    .systemMaterial(this.matSupported ? this.material : undefined)
    .border({ width: { right: 1 }, color: Theme.border })
    // 空白处右键 / 长按 → 粘贴菜单（对象行上的「点点」菜单优先级更高，互不影响）
    .bindMenu(this.blankMenu(), {
      placement: Placement.BottomLeft,
      enableArrow: false,
      backgroundColor: Color.Transparent
    })
  }

  // 单个盘行：盘名 + 床型 + 该盘包含的对象名（窄面板下用省略号，不溢出）
  @Builder
  plateRow(p: PlateMeta) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Text(p.name.length > 0 ? `盘 ${p.index} · ${p.name}` : `盘 ${p.index}`)
          .fontSize(11)
          .fontColor(this.activePlate === p.index ? Theme.accentSoft : Theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(p.bed.length > 0 ? p.bed : '床型未知')
          .fontSize(9)
          .fontColor(Theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Text(p.objNames.length > 0 ? p.objNames.join('、') : '（无对象）')
        .fontSize(10)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .borderRadius(8)
    .backgroundColor(this.activePlate === p.index ? '#1F2B27' : Color.Transparent)
    .border({ width: 1, color: this.activePlate === p.index ? Theme.accent : Theme.border })
    .onClick(() => {
      this.activePlate = p.index;
    })
  }

  // 圆形「两点」按钮：点击弹出延伸菜单
  @Builder
  dotsButton(obj: ModelFile) {
    Column({ space: 3 }) {
      Circle().width(3).height(3).fill(Theme.textSecondary)
      Circle().width(3).height(3).fill(Theme.textSecondary)
    }
    .width(28)
    .height(28)
    .borderRadius(14)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.selectedId === obj.id ? '#243A32' : Theme.surfaceElevated)
    // 左对齐展开（BottomLeft），贴着按钮下沿弹出操作菜单
    .bindMenu(this.rowMenu(obj), {
      placement: Placement.BottomLeft,
      enableArrow: true,
      offset: { x: 0, y: 4 },
      backgroundColor: Color.Transparent
    })
  }

  // 空白处（右键 / PC 上右键、触屏上长按）菜单：把剪贴板里的对象粘到当前盘。
  // 剪贴板为空时也给出一条说明项，保证「点了有反馈」而不是菜单一闪而过。
  @Builder
  blankMenu() {
    Column() {
      if (this.clipboardCount > 0) {
        this.menuItem('粘贴到当前盘', false, 'pastehere', -1, -1)
      } else {
        this.menuItem('剪贴板为空', false, 'noop', -1, -1)
      }
    }
    .width(150)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.matSupported ? Color.Transparent : '#E616161C')
    .systemMaterial(this.matSupported ? this.material : undefined)
  }

  // 延伸菜单（沉浸光感，类似桌面右键）：复制 / 剪切 / 粘贴到本盘 / 移到打印板 / 删除。
  // 耗材选择与「多色打印」入口已按需求移除 —— 对象列表不再承载颜色 / 耗材信息，
  // 颜色改到右侧「对象」页签里设置（见 DynamicParamsPanel 的模型颜色色板）。
  @Builder
  rowMenu(obj: ModelFile) {
    Column() {
      this.menuItem('复制', false, 'copy', obj.id, -1)
      this.menuItem('剪切', false, 'cut', obj.id, -1)
      if (this.clipboardCount > 0) {
        this.menuItem('粘贴到本盘', false, 'paste', obj.id, -1)
      }
      // 移动到指定盘：每个「不是它当前所在」的盘给一条。
      // 不用二级子菜单：盘数通常只有 2~4 块，平铺一行一项点起来更快，
      // 也避开 bindMenu 自建 builder 里再做一层弹层的不确定性。
      ForEach(this.otherPlates(obj), (pi: number) => {
        this.menuItem(`移到打印板 ${pi}`, false, 'move', obj.id, pi)
      }, (pi: number) => `mv-${obj.id}-${pi}`)
      if (obj.plate > 0) {
        this.menuItem('移出打印板', false, 'move', obj.id, 0)
      }
      this.menuItem('删除', true, 'del', obj.id, -1)
    }
    .width(150)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.matSupported ? Color.Transparent : '#E616161C')
    .systemMaterial(this.matSupported ? this.material : undefined)
  }

  @Builder
  menuItem(label: string, danger: boolean, kind: string, id: number, arg: number) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(danger ? Theme.danger : Theme.textPrimary)
    }
    .width('100%')
    .height(38)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (kind === 'copy') {
        this.doCopy(id);
      } else if (kind === 'cut') {
        this.doCut(id);
      } else if (kind === 'paste') {
        this.doPaste(id);
      } else if (kind === 'pastehere') {
        this.doPasteHere();
      } else if (kind === 'noop') {
        promptAction.showToast({ message: '剪贴板为空：先用对象菜单里的「复制」或「剪切」' });
      } else if (kind === 'move') {
        this.doMoveToPlate(id, arg);
      } else {
        this.confirmDelete(id);
      }
    })
  }
}
