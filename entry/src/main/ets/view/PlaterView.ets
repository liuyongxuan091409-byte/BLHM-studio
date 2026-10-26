import { Theme } from '../common/Theme';
import testNapi from 'libentry.so';
import promptAction from '@ohos.promptAction';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';

// 模型加载结果（与 C++ ModelInfo 对应）
class ModelInfo {
  ok: boolean = false;
  error: string = '';
  triangles: number = 0;
  sizeX: number = 0;
  sizeY: number = 0;
  sizeZ: number = 0;
}

// 中央 3D 平台视图：XComponent + 原生 GLES3 渲染（STL/OBJ 模型 + 轨道相机）
@Component
export struct PlaterView {
  @State modelInfoText: string = '未加载模型';
  @State loading: boolean = false;
  // 手势状态（每次手势从起点计增量）
  private lastRotateX: number = 0;
  private lastRotateY: number = 0;
  private lastPinchScale: number = 1;
  private lastPanX: number = 0;
  private lastPanY: number = 0;

  // 导入模型：系统文件选择器 → 拷贝沙箱 → C++ 解析上传
  private importModel(): void {
    if (this.loading) {
      return;
    }
    try {
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.fileSuffixFilters = ['.stl', '.obj', '.stp', '.step'];
      docPicker.select(opts).then((uris: string[]) => {
        if (uris.length === 0) {
          return;
        }
        this.copyAndLoad(uris[0]);
      }).catch(() => {
        promptAction.showToast({ message: '选择文件取消' });
      });
    } catch (e) {
      promptAction.showToast({ message: '打开选择器失败' });
    }
  }

  // 按扩展名识别格式（保留原扩展名传递给 C++ 分发解析器）
  private static extOf(uri: string): string {
    const lower: string = uri.toLowerCase();
    if (lower.endsWith('.obj')) { return '.obj'; }
    if (lower.endsWith('.step')) { return '.step'; }
    if (lower.endsWith('.stp')) { return '.stp'; }
    return '.stl';
  }

  private copyAndLoad(uri: string): void {
    try {
      const ext: string = PlaterView.extOf(uri);
      const ctx = this.getUIContext().getHostContext();
      if (!ctx) {
        promptAction.showToast({ message: '获取上下文失败' });
        return;
      }
      const dst: string = `${ctx.filesDir}/model${ext}`;
      const srcFile: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const dstFile: fs.File = fs.openSync(dst,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(srcFile.fd, dstFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);

      this.loading = true;
      this.modelInfoText = '解析中…';
      testNapi.rendererLoadModel(dst, (resultJson: string) => {
        this.loading = false;
        try {
          const r: ModelInfo = JSON.parse(resultJson) as ModelInfo;
          if (r.ok) {
            const fmt: string = ext === '.obj' ? 'OBJ' : (ext === '.stp' || ext === '.step') ? 'STEP' : 'STL';
            this.modelInfoText =
              `${fmt} · ${r.triangles} 三角面 · ${r.sizeX.toFixed(1)}×${r.sizeY.toFixed(1)}×${r.sizeZ.toFixed(1)} mm`;
            promptAction.showToast({ message: '模型已加载' });
          } else {
            this.modelInfoText = '加载失败';
            promptAction.showToast({ message: r.error !== '' ? r.error : '解析失败' });
          }
        } catch (e) {
          this.modelInfoText = '加载失败';
        }
      });
    } catch (e) {
      this.loading = false;
      promptAction.showToast({ message: '读取文件失败' });
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 原生 3D 表面（libraryname 触发模块注册，onLoad 再补注册以防时序）
      XComponent({
        id: 'plater',
        type: XComponentType.SURFACE,
        libraryname: 'entry'
      })
        .onLoad(() => {
          testNapi.rendererAttach();
        })
        .width('100%')
        .height('100%')
        .backgroundColor('#0E0E12')

      // 顶部信息条
      Row({ space: 10 }) {
        Text(this.modelInfoText)
          .fontSize(12)
          .fontColor(Theme.textSecondary)
          .maxLines(1)
        Blank()
        Button(this.loading ? '加载中…' : '导入模型')
          .fontSize(12)
          .height(30)
          .padding({ left: 12, right: 12 })
          .fontColor(Theme.textPrimary)
          .backgroundColor(Theme.surfaceElevated)
          .borderRadius(6)
          .stateEffect(true)
          .onClick(() => { this.importModel(); })
        Button('复位视角')
          .fontSize(12)
          .height(30)
          .padding({ left: 12, right: 12 })
          .fontColor(Theme.accentSoft)
          .backgroundColor(Theme.surfaceElevated)
          .borderRadius(6)
          .stateEffect(true)
          .onClick(() => { testNapi.rendererResetView(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })
    }
    .width('100%')
    .height('100%')
    // 手势 → 相机：单指旋转 / 双指捏合缩放 / 双指平移
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PanGesture({ fingers: 1, distance: 2 })
          .onActionStart(() => {
            this.lastRotateX = 0;
            this.lastRotateY = 0;
          })
          .onActionUpdate((e: GestureEvent) => {
            const dx: number = e.offsetX - this.lastRotateX;
            const dy: number = e.offsetY - this.lastRotateY;
            this.lastRotateX = e.offsetX;
            this.lastRotateY = e.offsetY;
            testNapi.rendererRotate(dx, dy);
          }),
        GestureGroup(GestureMode.Exclusive,
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.lastPinchScale = 1;
            })
            .onActionUpdate((e: GestureEvent) => {
              if (this.lastPinchScale > 0.01) {
                testNapi.rendererZoom(e.scale / this.lastPinchScale);
              }
              this.lastPinchScale = e.scale;
            }),
          PanGesture({ fingers: 2, distance: 6 })
            .onActionStart(() => {
              this.lastPanX = 0;
              this.lastPanY = 0;
            })
            .onActionUpdate((e: GestureEvent) => {
              const dx: number = e.offsetX - this.lastPanX;
              const dy: number = e.offsetY - this.lastPanY;
              this.lastPanX = e.offsetX;
              this.lastPanY = e.offsetY;
              testNapi.rendererPan(dx, dy);
            })
        )
      )
    )
  }
}
