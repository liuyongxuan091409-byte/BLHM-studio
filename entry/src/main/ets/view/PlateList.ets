import { Theme } from '../common/Theme';
import { PlateMeta } from '../model/Models';
import { getThumbnail } from '../model/Thumbnail';
import { modelState, PlateRec } from '../model/ModelState';
import { plateAddEmpty, plateRename, plateDuplicate, plateDelete, plateActiveAfterDelete } from '../service/PlateActions';
import image from '@ohos.multimedia.image';
import uiMaterial from '@ohos.arkui.uiMaterial';
import promptAction from '@ohos.promptAction';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 3D 视图右侧的「盘」列表：多盘文件打开时出现，点击切换当前查看/编辑的盘。
// 视觉：沉浸光感玻璃竖条 + 缩略图卡片，单一强调色（品牌绿）。
@Component
export struct PlateList {
  @StorageLink('modelPlates') @Watch('onPlatesChanged') plates: PlateMeta[] = [];
  @StorageLink('activePlate') activePlate: number = -1;
  // 可选外部接管：切片路径态下本列表渲染在 GcodePreview 覆盖层之上，点击需转发给控制层的
  // switchPlate(n)（写 activePlate + reload 重载该盘几何）。未提供时保持原行为（本组件自己写 activePlate）。
  onSelect: (index: number) => void = (index: number): void => {};
  @State matSupported: boolean = false;
  @State appear: boolean = false;
  // 正在改名的盘号（-1 = 无）：改名走「就地输入框」，不弹对话框 —— 盘条只有 76vp 宽，
  // 就地编辑比把焦点搬到全屏弹窗更顺，也省掉一套跨组件的弹窗总线。
  @State renaming: number = -1;
  @State renameText: string = '';

  private material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: '#141A1E24',
    applyShadow: true,
    interactive: true,
    lightEffect: { color: '#00C48C' },
  });

  aboutToAppear(): void {
    try {
      this.matSupported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      this.matSupported = false;
    }
    this.appear = true;
  }

  private onPlatesChanged(): void {
    // 盘列表变化时保持展开状态
    this.appear = true;
  }

  // ---------------------------------------------------------------------------
  // 盘管理（Phase 3）：新增 / 重命名 / 复制 / 删除
  //
  // 为什么菜单挂在表头「⋯」而不是盘项长按：`bindContextMenu` 的 LongPress 只对触摸生效
  // （官方明确「鼠标长按不支持」），而目标机型是 2in1（鼠标 + 触摸都在用）。
  // 表头按钮在两种输入下都可靠；盘项点击继续只负责「切盘」这一件事，职责不混。
  //
  // 所有盘结构变更都必须 modelState.publish()：3D 侧按 activePlate 过滤可见对象，
  // 而 publish() 会自增 modelRevision → 预览页 onModelRevision → 重写可见性。
  // ---------------------------------------------------------------------------
  private doAddPlate(): void {
    const idx: number = plateAddEmpty();
    this.activePlate = idx;
    // 第一块盘会把原有「未分盘」对象收编进来（见 ModelState.addPlate）
    const cnt: number = modelState.instances.filter((m) => m.plate === idx).length;
    promptAction.showToast({
      message: cnt > 0
        ? `已新增打印板 ${idx}（原有对象已归入此盘）`
        : `已新增打印板 ${idx}（空盘）`
    });
    hilog.info(0x0000, 'PlateList', '新增打印板 idx=%{public}d 盘数=%{public}d 收编对象=%{public}d',
      idx, this.plates.length, cnt);
  }

  private startRename(): void {
    const i: number = this.activePlate;
    if (i <= 0) {
      promptAction.showToast({ message: '先在右侧盘条里点一块盘，或新增一块' });
      return;
    }
    const rec: PlateRec | undefined = modelState.getPlateRec(i);
    this.renameText = rec !== undefined ? rec.name : `打印板 ${i}`;
    this.renaming = i;
  }

  private commitRename(): void {
    const i: number = this.renaming;
    this.renaming = -1;
    if (i <= 0) {
      return;
    }
    // 空名视为放弃（plateRename 内部已判）
    plateRename(i, this.renameText);
  }

  private doDuplicatePlate(): void {
    const i: number = this.activePlate;
    if (i <= 0) {
      promptAction.showToast({ message: '先选一块要复制的盘' });
      return;
    }
    const n: number = plateDuplicate(i);
    if (n <= 0) {
      promptAction.showToast({ message: '复制失败' });
      return;
    }
    this.activePlate = n;
    promptAction.showToast({ message: `已复制为打印板 ${n}（含盘内对象）` });
  }

  private doDeletePlate(): void {
    const i: number = this.activePlate;
    if (i <= 0) {
      promptAction.showToast({ message: '先选一块要删除的盘' });
      return;
    }
    const cnt: number = modelState.instances.filter((m) => m.plate === i).length;
    const msg: string = cnt > 0
      ? `盘 ${i} 上的 ${cnt} 个对象会移到「未分盘」，不会删除。确定删除这块盘吗？`
      : `确定删除盘 ${i} 吗？`;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除打印板',
        message: msg,
        buttons: [
          { text: '取消', color: '#9A9AA4' },
          { text: '删除', color: '#FF3D2E' }
        ]
      }).then((res: promptAction.ShowDialogSuccessResponse) => {
        if (res.index !== 1) {
          return;
        }
        plateDelete(i);
        this.activePlate = plateActiveAfterDelete();
        promptAction.showToast({ message: `已删除打印板 ${i}` });
      }).catch((err: Error) => {
        hilog.error(0x0000, 'PlateList', 'deletePlate: showDialog failed %{public}s',
          `${err.name}: ${err.message}`);
      });
    } catch (e) {
      hilog.error(0x0000, 'PlateList', 'deletePlate: threw %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  build() {
    Column({ space: 6 }) {
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
        // 盘管理菜单入口（作用于「当前盘」）
        Text('⋯')
          .fontSize(14)
          .fontColor(Theme.textSecondary)
          .padding({ left: 4, right: 2 })
          .bindMenu(this.plateMenu(), {
            placement: Placement.BottomRight,
            enableArrow: false,
            backgroundColor: Color.Transparent
          })
      }
      .width('100%')
      .padding({ left: 3, right: 1, bottom: 2 })

      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.plates, (p: PlateMeta) => {
            this.plateItem(p)
          }, (p: PlateMeta) => `${p.index}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: 380 })
    }
    .width(76)
    .padding(7)
    .borderRadius(16)
    .backgroundColor(this.matSupported ? Color.Transparent : '#CC0E1116')
    .backgroundEffect(this.matSupported ? undefined : { radius: 20, saturation: 1.15, brightness: 1.05 })
    .systemMaterial(this.matSupported ? this.material : undefined)
    .opacity(this.appear ? 1 : 0)
    .translate({ x: this.appear ? 0 : 18 })
    .animation({ duration: 240, curve: Curve.FastOutSlowIn })
  }

  @Builder
  plateMenu() {
    Column() {
      this.plateMenuItem('新增打印板', 'add')
      this.plateMenuItem(`重命名盘 ${this.activePlate > 0 ? this.activePlate : ''}`, 'rename')
      this.plateMenuItem('复制当前盘', 'dup')
      this.plateMenuItem('删除当前盘', 'del')
    }
    .width(168)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(this.matSupported ? Color.Transparent : '#E616161C')
    .systemMaterial(this.matSupported ? this.material : undefined)
  }

  @Builder
  plateMenuItem(label: string, kind: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(kind === 'del' ? Theme.danger : Theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(38)
    .padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (kind === 'add') {
        this.doAddPlate();
      } else if (kind === 'rename') {
        this.startRename();
      } else if (kind === 'dup') {
        this.doDuplicatePlate();
      } else {
        this.doDeletePlate();
      }
    })
  }

  @Builder
  plateItem(p: PlateMeta) {
    Column({ space: 4 }) {
      Stack() {
        if (getThumbnail(p.firstId) !== undefined) {
          Image(getThumbnail(p.firstId) as image.PixelMap)
            .width(40)
            .height(40)
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.High)
        } else {
          Text(`${p.index}`)
            .fontSize(15)
            .fontColor(Theme.textSecondary)
        }
        // 序号角标
        Text(`${p.index}`)
          .fontSize(9)
          .textAlign(TextAlign.Center)
          .width(15)
          .height(15)
          .borderRadius(5)
          .backgroundColor(this.activePlate === p.index ? Theme.accent : '#26FFFFFF')
          .fontColor(this.activePlate === p.index ? '#06281E' : '#B9B9C4')
          .position({ x: 3, y: 3 })
      }
      .width(46)
      .height(46)
      .borderRadius(11)
      .backgroundColor('#15151A')
      .border({ width: 1, color: this.activePlate === p.index ? Theme.accent : Theme.border })

      if (this.renaming === p.index) {
        // 就地改名：回车 / 失焦提交（空名视为放弃，见 commitRename）
        TextInput({ text: this.renameText })
          .fontSize(10)
          .height(24)
          .width('100%')
          .padding({ left: 4, right: 4 })
          .backgroundColor('#22FFFFFF')
          .fontColor(Theme.textPrimary)
          .onChange((v: string) => { this.renameText = v; })
          .onSubmit(() => { this.commitRename(); })
          .onBlur(() => { this.commitRename(); })
      } else {
        Text(p.name.length > 0 ? p.name : `盘 ${p.index}`)
          .fontSize(10)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
          .fontColor(this.activePlate === p.index ? Theme.accentSoft : Theme.textSecondary)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .borderRadius(12)
    .backgroundColor(this.activePlate === p.index ? '#1F2B27' : Color.Transparent)
    .animation({ duration: 180, curve: Curve.Sharp })
    .onClick(() => {
      hilog.info(0x0000, 'PlateList', '盘列表点击 盘=%{public}d（旧=%{public}d）', p.index, this.activePlate);
      // 先转发给外部（切片路径态 → 控制层 switchPlate：读旧值 → 写 AppStorage → reload），
      // 再写本组件的 activePlate 保证高亮即时同步（idempotent：值相同不触发重复通知）。
      // 【顺序不能反】若先写 activePlate，控制层 switchPlate 读到的就是新值 → 直接 return，不会重载几何。
      this.onSelect(p.index);
      this.activePlate = p.index;
    })
  }
}
