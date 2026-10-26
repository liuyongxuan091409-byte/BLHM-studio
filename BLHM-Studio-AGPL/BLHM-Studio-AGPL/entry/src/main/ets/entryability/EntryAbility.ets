import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import uiMaterial from '@ohos.arkui.uiMaterial';
import { SlicerService } from '../service/SlicerService';
import { MqttService } from '../service/MqttService';
import { AppLog } from '../service/AppLog';
import { SliceCache } from '../service/SliceCache';
import { GlowSettings } from '../service/GlowSettings';
import { SliceParamStore } from '../service/SliceParamStore';
import { docGuard } from '../service/DocGuard';
import { autoBackup } from '../service/AutoBackup';
import { hmsTable } from '../service/HmsTable';
import { CalibAssets } from '../service/CalibAssets';
import { history } from '../model/History';
import { Theme } from '../common/Theme';

const DOMAIN = 0x0000;

// 屏幕方向自证日志 tag（新增 tag，不改动任何既有 tag）
const ORIENT_TAG: string = 'ScreenOrient';

// 安全区自证日志 tag（本次新增 tag，不改动任何既有 tag）
const INSET_TAG: string = 'ScreenInset';

// 安全区 inset 广播键（单位 px；UI 侧 px2vp 后作为顶栏 / 底部工具栏的间距）。
// 真因：沉浸式布局下布局铺满整屏、不再自动避让系统栏，必须由应用自己把「避让区高度」用在内容上。
const SAFE_TOP_KEY: string = 'safeTopPx';
const SAFE_BOTTOM_KEY: string = 'safeBottomPx';

// ---- 前台恢复信号（AppStorage）--------------------------------------------------
// 真因：窗口失焦 / 前后台切换时，ArkGraphics3D 会重建渲染表面，已缓存的材质绑定随之丢失，
// 几何回落到引擎默认材质 → 切片路径、打印板一起「变灰」（网格甚至消失）。
// 因此「窗口重新回到前台 / 重新可见」必须广播给 UI 侧，由 3D 场景页重贴材质。
// 为什么走 AppStorage 而不是直接回调：恢复动作必须由「持有 scene 与材质的组件」执行，
// 而该组件（ModelPreviewPage）随页签切换会被销毁重建 —— 保存它的回调会打到已卸载的旧实例。
// AppStorage 是同一个 Ability/ArkTS 运行时内的可观察单例：谁在，谁就收到。
const RESUME_SEQ_KEY: string = 'renderResumeSeq';
const RESUME_SRC_KEY: string = 'renderResumeSrc';

export default class EntryAbility extends UIAbility {
  // 沉浸式布局是否生效：真为真时 UI 才需要自己避让系统栏（见 publishSafeInsets）。
  // 若 setWindowLayoutFullScreen 失败（布局仍会自动避让系统栏），则广播 0，避免「双重避让」把内容顶飞。
  private immersiveOk: boolean = false;

  // 主窗口引用：固定深色时需要在运行时（用户切系统主题 → onConfigurationUpdate）重新钉回深色窗口底色/系统栏配色。
  private mainWindow: window.Window | null = null;

  // 固定深色（应用级）：本应用外观不跟随系统深浅色。
  // 真因：沉浸系统材质（uiMaterial.ImmersiveMaterial，见 LeftNav/ObjectList/DevicePanel/ModelPreviewPage）
  // 的取色跟随「应用 UI 颜色模式」。此前 onCreate 设的是 COLOR_MODE_NOT_SET（跟随系统），
  // 系统处于浅色时这些材质层被渲染成浅灰 → 用户看到的「灰块 / 灰带」；3D 视口与深色控件也因此割裂。
  // 处理：把应用 UI 颜色模式钉死为深色。setColorMode 失败不崩，只记日志。
  private forceDark(): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      hilog.info(DOMAIN, 'ColorMode', '已固定深色 COLOR_MODE_DARK');
    } catch (e) {
      hilog.error(DOMAIN, 'ColorMode', 'setColorMode(DARK) 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 把「窗口底色 + 系统栏配色」钉死为深色（与页面背景同源 Theme.bg）。
  // 供启动（setupWindow）与配置变更（onConfigurationUpdate）复用：系统切主题后可能重置窗口底色，
  // 必须重新钉回深色，否则沉浸式露出的窗口底会变浅、与深色控件叠出灰块。
  private applyWindowDarkChrome(): void {
    const w: window.Window | null = this.mainWindow;
    if (w === null) {
      return;
    }
    try {
      w.setWindowBackgroundColor(Theme.bg);
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, 'setWindowBackgroundColor(重钉深色) 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    try {
      w.setWindowSystemBarProperties({
        statusBarColor: Theme.bg,
        navigationBarColor: Theme.bg,
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      }).catch((e: Object) => {
        hilog.warn(DOMAIN, INSET_TAG, 'setWindowSystemBarProperties(重钉深色) 失败: %{public}s',
          e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, 'setWindowSystemBarProperties(重钉深色) 同步异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 系统配置变化（含用户切换深浅色）：只要当前不是深色就重新强制为深色。
  // 这是「固定深色」的关键：否则用户一步主题设置就又变浅，灰块重现。
  onConfigurationUpdate(newConfig: Configuration): void {
    if (newConfig.colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      hilog.info(DOMAIN, 'ColorMode', '系统配色变化 colorMode=%{public}d → 重新强制深色',
        newConfig.colorMode as number);
      this.forceDark();
    }
    // 窗口底 / 系统栏也可能被系统重置为浅色，一并钉回深色。
    this.applyWindowDarkChrome();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 固定深色：把应用 UI 颜色模式钉死为深色（不再跟随系统），消除沉浸材质/系统栏在浅色下的灰块。
    this.forceDark();
    // 撤销栈初始化：建立空基线并写入 history 相关的 AppStorage 键。
    // 为什么要在启动时做：Index/SliceBar 用 @StorageLink 读这些键，先有值可以避免
    // 「键还不存在」这类挂载期告警；同时把基线定为「空工程」，导入时会被 ThreeMfImport 再重置一次。
    history.reset();
    // 【崩溃恢复第一步：会话锁】启动时「先探测、再打锁」：探测到旧锁 = 上次不是正常退出
    // （进程被杀 / 被系统回收 / force-stop 都不会走到清理逻辑）。
    // 这里只是探测与打锁，「要不要弹恢复框」由 Index 在页面可见后决定（还要看有没有备份）。
    try {
      const abnormal: boolean = autoBackup.beginSession(this.context.filesDir);
      hilog.info(DOMAIN, 'AutoBackup', '会话锁已处理 上次异常退出=%{public}s',
        abnormal ? 'true' : 'false');
    } catch (e) {
      hilog.warn(DOMAIN, 'AutoBackup', '会话锁处理失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    SlicerService.initResourceManager(this.context.resourceManager);
    // HMS 离线码表要用 rawfile 资源（懒惰加载：真出现故障时才读，见 service/HmsTable）
    hmsTable.init(this.context.resourceManager);
    // 校准模型同走 rawfile（懒惰落地：点「生成并切片」时才拷到沙箱，见 service/CalibAssets）
    CalibAssets.init(this.context.resourceManager);
    // 切片预设（BBL 官方 profile）在这里异步预热：首次运行要把 rawfile 里的
    // bambu_res.zip 解到 filesDir（2500+ 个小文件），放后台做，别挡启动。
    // 这是初始化链路的第一发起人（生命周期 onCreate）；结果统一由 SlicerService 发布成
    // 三态 loading/ready/failed，这里只负责把"发起"和"终态"打进 hilog 便于真机排查。
    hilog.info(DOMAIN, 'PresetInit', 'onCreate 发起预设初始化 filesDir=%{public}s', this.context.filesDir);
    try {
      SlicerService.initPresets(this.context.filesDir)
        .then((ok: boolean) => {
          hilog.info(DOMAIN, 'PresetInit', 'onCreate 侧初始化回调 ok=%{public}s state=%{public}s',
            ok ? 'true' : 'false', SlicerService.getState());
        })
        .catch((e: Object) => {
          // 初始化链路本身保证不 reject；此处兜底并如实记日志（不吞异常）
          hilog.error(DOMAIN, 'PresetInit', 'onCreate 侧初始化异常: %{public}s',
            e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
          SlicerService.markFailed('启动初始化异常');
        });
    } catch (e) {
      hilog.error(DOMAIN, 'PresetInit', 'onCreate 发起初始化同步抛异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      SlicerService.markFailed('启动初始化同步异常');
    }
    hilog.info(DOMAIN, 'BambuHM', '%{public}s', 'Ability onCreate');

    // 增量字段合并单元自测：随启动跑一次真实 applyReport 的"缺字段不清零"用例（不依赖打印机）。
    // 结果同步写 hilog(tag=MqttSelfTest) 与 files/diag/mqtt_merge_selftest.txt，便于 hdc 取走核对。
    try {
      const selftest: string = MqttService.selfTestMerge();
      const okWrite: boolean = AppLog.writeDiagFile(
        `${this.context.filesDir}/diag/mqtt_merge_selftest.txt`, selftest.split('\n'));
      hilog.info(DOMAIN, 'MqttSelfTest', '启动自测完成 写文件=%{public}s', okWrite ? 'true' : 'false');
    } catch (e) {
      hilog.error(DOMAIN, 'MqttSelfTest', '启动自测异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }

    // HMS 离线码表自测：随启动跑一次（不连打印机）—— 验证码表能读进 rawfile、
    // 「attr/code → 16 位键」的组合规则与真实键自洽、真实条目能查到文案。
    // 结果写 hilog(tag=HmsSelfTest) 与 files/diag/hms_selftest.txt。
    try {
      const hms: string = hmsTable.selfTest();
      const ok: boolean = AppLog.writeDiagFile(`${this.context.filesDir}/diag/hms_selftest.txt`,
        hms.split('\n'));
      hilog.info(DOMAIN, 'HmsSelfTest', '码表自测完成 写文件=%{public}s', ok ? 'true' : 'false');
    } catch (e) {
      hilog.error(DOMAIN, 'HmsSelfTest', '码表自测异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'BambuHM', '%{public}s', 'Ability onDestroy');
    // 【正常退出：清会话锁】不清的话，下次启动会把「这次正常关软件」误判成异常退出。
    // 注意这条路径**不够**（实测「关闭窗口」不一定会走 onDestroy），
    // 所以「允许关闭窗口」那条路径也要清一次，见 onWindowStageCreate 的 windowWillClose。
    try {
      autoBackup.endSession();
    } catch (e) {
      hilog.warn(DOMAIN, 'AutoBackup', '清会话锁异常: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    // 【关软件：清切片缓存】此前 onDestroy 只打日志 → output.gcode / output_plate_N.gcode /
    // slice_plate_N.3mf / gcode_pkg_cache / slice_tmp / 126MB 的 project_input.tmp.3mf 全留在沙箱里。
    try {
      SliceCache.clearAll(this.context.filesDir, 'onDestroy');
    } catch (e) {
      hilog.warn(DOMAIN, 'BambuHM', '退出清理切片缓存失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'BambuHM', '%{public}s', 'Ability onWindowStageCreate');
    const mainWindow: window.Window = windowStage.getMainWindowSync();
    // 记录主窗口：固定深色需要它来在运行时重钉窗口底/系统栏配色（见 applyWindowDarkChrome）。
    this.mainWindow = mainWindow;
    // 再钉一次深色：确保窗口舞台就绪后 UI 颜色模式已是深色（首帧就用深色渲染，不闪浅色）。
    this.forceDark();
    // 【启动兜底清理切片缓存】关软件时虽然 onDestroy 里也清（见 onDestroy），但实测「关闭窗口 /
    // 进程被系统回收」等路径并不一定会走 onDestroy —— 于是切片产物会一直躺在沙箱里（曾堆到 425MB）。
    // 这里在每次启动时再清一次，保证「关闭软件后不留切片缓存」这条语义**一定**成立。
    // 只删切片产物，不动用户工程（未命名项目.3mf）、预设与 bambu_res/diag。
    try {
      SliceCache.clearAll(this.context.filesDir, '启动兜底');
    } catch (e) {
      hilog.warn(DOMAIN, 'BambuHM', '启动清理切片缓存失败: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    // 订阅窗口舞台生命周期：ACTIVE / RESUMED / SHOWN 都表示窗口重新可见/获焦
    // （应用内弹窗、其它窗口抢到前台，都会先 INACTIVE/HIDDEN 再回 ACTIVE），
    // 这是「有弹窗/切窗口到前台后变灰」这条用户实测触发路径的主要来源。
    try {
      windowStage.on('windowStageEvent', (ev: window.WindowStageEventType): void => {
        if (ev === window.WindowStageEventType.ACTIVE ||
            ev === window.WindowStageEventType.RESUMED ||
            ev === window.WindowStageEventType.SHOWN) {
          this.signalRenderResume(`windowStageEvent:${ev}`);
        }
      });
    } catch (e) {
      hilog.error(DOMAIN, 'RenderResume', '订阅 windowStageEvent 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    // 【关闭窗口前把关】有未保存的改动时先问用户（保存并退出 / 不保存 / 取消）。
    // 为什么用 windowWillClose 而不是 UIAbility.onPrepareToTerminate：后者需要
    // ohos.permission.PREPARE_APP_TERMINATE（受限权限，侧载包声明它有被拒风险），
    // 而窗口级事件不需要额外权限，且正好覆盖「点系统标题栏关闭按钮」这条路径。
    // 返回语义是**反的**：resolve(true) = 不关闭，所以这里把业务判定取反。
    try {
      mainWindow.on('windowWillClose', (): Promise<boolean> => {
        return docGuard.ask().then((allow: boolean) => {
          if (allow) {
            // 这是一次**正常关闭**：清会话锁，否则下次启动会把这次正常关窗误判成崩溃、
            // 弹一个没有意义的「上次未正常退出，要恢复吗」。
            autoBackup.endSession();
          }
          return !allow;
        });
      });
    } catch (e) {
      hilog.error(DOMAIN, 'DocGuard', '订阅 windowWillClose 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    // 【光感设置读回】背景发光 / 手柄发光此前只存在 AppStorage（内存），重启即丢。
    // 这里在 UI/3D 场景初始化（loadContent）之前读回 ui_glow.json 并写进 AppStorage，
    // 保证 ModelPreviewPage 创建时 @StorageLink('glowBg'/'glowHandle') 就能拿到持久化值；
    // 文件缺失/解析失败/越界时回落默认 1.0，绝不抛异常中断启动。
    GlowSettings.load(this.context.filesDir);
    // 【参数覆盖读回】用户手改过的切片参数此前只存在内存，force-stop 重启即回到预设默认值。
    // 这里在 loadContent 之前读回 param_overrides.json：参数面板首帧就会拿到恢复后的值
    //（面板重建时用 SliceParamStore.applyUserOverrides 回放，早于它就等于没恢复）。
    // 文件里带工艺预设名标签，与 preset_last.json 不一致时自动丢弃（换过预设不会串值）。
    try {
      const replayed: number = SliceParamStore.loadParamOverrides(this.context.filesDir);
      hilog.info(DOMAIN, 'ParamOverride', '参数覆盖读回 条数=%{public}d', replayed);
    } catch (e) {
      hilog.warn(DOMAIN, 'ParamOverride', '参数覆盖读回异常（按无覆盖处理）: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'BambuHM', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'BambuHM', 'Succeeded in loading the content.');
      this.setupWindow(mainWindow);
      // 内容就绪后再设方向：此时主窗口可用，且不会与 loadContent 的窗口初始化竞争。
      this.applyPhoneLandscape(mainWindow);
    });
  }

  // 需求：手机上强制横屏并允许上下翻转（横屏 / 反向横屏自动旋转）；2in1（PC/自由窗口）与平板不受影响。
  //
  // 为什么选运行时方案而不是 module.json5 的静态 orientation：静态字段对该 Ability 在「所有」
  // deviceTypes 上全局生效，会把 2in1 / 平板的自由窗口也钉死成横屏，无法满足「只对手机生效」。
  // 运行时按 deviceInfo.deviceType 判断，仅 phone 调用窗口方向设置 —— 对 2in1/平板零影响。
  private applyPhoneLandscape(w: window.Window): void {
    let devType: string = 'unknown';
    try {
      devType = deviceInfo.deviceType;
    } catch (e) {
      // 取设备类型失败：无法确认是手机，宁可不设置（绝不误伤 2in1/平板）
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(DOMAIN, ORIENT_TAG, '读取 deviceType 失败: %{public}s', msg);
      this.logOrientation(devType, '未设置(设备类型读取失败)', `失败(${msg})`);
      return;
    }
    if (devType !== deviceInfo.DeviceTypes.TYPE_PHONE) {
      this.logOrientation(devType, '未设置(非手机)', '成功');
      return;
    }
    // AUTO_ROTATION_LANDSCAPE：随传感器在「横屏 + 反向横屏」两个方向自动旋转，且不受控制中心旋转锁影响，
    // 正是「强制横屏且允许上下翻转」所需（其余靠近成员的语义见报告，此处不选用）。
    try {
      w.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE)
        .then(() => {
          this.logOrientation(devType, 'AUTO_ROTATION_LANDSCAPE', '成功');
        })
        .catch((e: Object) => {
          // 失败不崩：记原因后继续运行（可能无权限/该设备不支持，此时降级为系统默认方向）
          const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
          hilog.error(DOMAIN, ORIENT_TAG, 'setPreferredOrientation 失败: %{public}s', msg);
          this.logOrientation(devType, 'AUTO_ROTATION_LANDSCAPE', `失败(${msg})`);
        });
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(DOMAIN, ORIENT_TAG, 'setPreferredOrientation 同步异常: %{public}s', msg);
      this.logOrientation(devType, 'AUTO_ROTATION_LANDSCAPE', `失败(${msg})`);
    }
  }

  // 屏幕方向自证日志：hilog + 应用内日志 + files/diag/gcode_diag.txt 三通道同写（与既有诊断同一文件）。
  private logOrientation(devType: string, set: string, result: string): void {
    const text: string = `屏幕方向 设备=${devType} 已设置=${set} 结果=${result}`;
    hilog.info(DOMAIN, ORIENT_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${ORIENT_TAG}] ${text}`);
      const ok: boolean = AppLog.writeDiagFile(`${this.context.filesDir}/diag/gcode_diag.txt`,
        [`[${ORIENT_TAG}] ${text}`]);
      if (!ok) {
        hilog.warn(DOMAIN, ORIENT_TAG, '方向日志落盘失败');
      }
    } catch (e) {
      hilog.error(DOMAIN, ORIENT_TAG, '方向日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 广播一次「渲染恢复」信号：递增序号（变化 → UI 侧 @StorageLink/@Watch 必然触发），
  // 并把触发来源一并带上，便于在设备上看日志时区分是哪条路径唤醒的。
  private signalRenderResume(src: string): void {
    const cur: number = AppStorage.get<number>(RESUME_SEQ_KEY) ?? 0;
    AppStorage.setOrCreate<string>(RESUME_SRC_KEY, src);
    AppStorage.setOrCreate<number>(RESUME_SEQ_KEY, cur + 1);
    hilog.info(DOMAIN, 'RenderResume', '触发恢复信号 src=%{public}s seq=%{public}d', src, cur + 1);
  }

  // 配置窗口。
  //
  // 【黑边】底色问题已由 ③ 解决：窗口不再铺满到屏幕最底部时，露出的系统栏区域用的是
  // Theme.bg（setWindowSystemBarProperties + setWindowBackgroundColor），不是原先的半透明黑。
  //
  // 【默认窗口尺寸 · 修复】之前一律 resize 到「整块显示区」(display.getDefaultDisplaySync().height)，
  // 在任务栏占据屏幕底部的 PC 上，窗口下沿会伸到任务栏**底下**，于是「底栏（导入/保存/切片/打印）」
  // 被排到窗口可见区之外、既看不到也点不到（用户实测：点一下系统「全屏化」就正常了 —— 那正是
  // 系统按工作区重排的结果）。所以默认尺寸改为**不超过可用区**（getAvailableArea，PC 上即扣掉任务栏）。
  // 沉浸式布局（①）与安全区 inset 广播（③④）保持不变。
  // 沉浸光感（uiMaterial.ImmersiveMaterial）能力探针：把「是否支持 + 设备类型」打出来，
  // 便于区分是"回落成模糊"还是"材质生效但背后无可折射内容"。
  private probeMaterial(): void {
    let supported: boolean = false;
    try {
      supported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      supported = false;
    }
    let dev: string = 'unknown';
    try {
      dev = deviceInfo.deviceType;
    } catch (e) {
      dev = 'unknown';
    }
    hilog.info(DOMAIN, 'MaterialProbe',
      '沉浸光感支持=%{public}s 设备类型=%{public}s 设备型号=%{public}s',
      String(supported), dev, deviceInfo.productModel);
  }

  private async setupWindow(w: window.Window): Promise<void> {
    this.probeMaterial();
    await this.applyTitleBar(w);
    // ① 沉浸式布局：布局不避让系统栏，组件可延伸到系统栏区域
    try {
      await w.setWindowLayoutFullScreen(true);
      this.immersiveOk = true;
    } catch (e) {
      // 失败不崩：保持系统默认（布局自动避让系统栏），此时广播 0 即可，不额外加间距
      this.immersiveOk = false;
      hilog.error(DOMAIN, INSET_TAG, 'setWindowLayoutFullScreen 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    // ② 默认窗口尺寸：整块显示区与可用区取小者（避免底栏落到窗口可见区之外、被任务栏遮住）
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      if (d.width > 0 && d.height > 0) {
        let ww: number = d.width;
        let hh: number = d.height;
        try {
          const area: display.Rect = await d.getAvailableArea();
          if (area !== undefined && area.width > 0 && area.height > 0) {
            ww = Math.min(ww, area.width);
            hh = Math.min(hh, area.height);
          }
        } catch (e2) {
          hilog.warn(DOMAIN, INSET_TAG, '取可用区失败(退回整块显示区): %{public}s',
            e2 instanceof Error ? `${e2.name}: ${e2.message}` : JSON.stringify(e2));
        }
        // 默认窗口取可用区的 92% 并居中：既保证底栏在窗口内（不会掉到任务栏下面），
        // 又明显小于全屏 —— 否则窗口一铺满，用户分不清"当前是不是已经全屏了"。
        const ww2: number = Math.max(640, Math.round(ww * 0.92));
        const hh2: number = Math.max(480, Math.round(hh * 0.92));
        let lx: number = 0;
        let ly: number = 0;
        try {
          const area2: display.Rect = await d.getAvailableArea();
          if (area2 !== undefined && area2.width > 0 && area2.height > 0) {
            lx = area2.left + Math.round((area2.width - ww2) / 2);
            ly = area2.top + Math.round((area2.height - hh2) / 2);
          }
        } catch (e3) {
          lx = Math.round((ww - ww2) / 2);
          ly = Math.round((hh - hh2) / 2);
        }
        await w.resize(ww2, hh2);
        await w.moveWindowTo(lx, ly);
      }
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, '窗口尺寸设置失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    // ③ 窗口底色 / 系统栏配色跟随深色主题，避免沉浸后露出的底色与页面背景不一致
    try {
      w.setWindowBackgroundColor(Theme.bg);
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, 'setWindowBackgroundColor 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    try {
      // 保留状态栏与三键导航栏（不调用 setWindowSystemBarEnable 隐藏），只把配色改成与页面背景一致
      await w.setWindowSystemBarProperties({
        statusBarColor: Theme.bg,
        navigationBarColor: Theme.bg,
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      });
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, 'setWindowSystemBarProperties 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    await this.applyTitleBar(w);
    // 计算并广播安全区；窗口可见性/尺寸/旋转/折叠导致避让区变化时刷新
    this.publishSafeInsets(w);
    try {
      w.on('avoidAreaChange', (_data: window.AvoidAreaOptions) => {
        this.publishSafeInsets(w);
      });
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, '订阅 avoidAreaChange 失败: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
    // 窗口状态变化（还原/最大化/全屏切换）后重新应用标题栏与安全区，避免三大键消失 / 间距错位
    try {
      w.on('windowStatusChange', () => {
        this.applyTitleBar(w);
        this.publishSafeInsets(w);
      });
    } catch (e) {
      hilog.warn(DOMAIN, INSET_TAG, 'on windowStatusChange failed');
    }
  }

  // 读取窗口避让区（TYPE_SYSTEM = 状态栏 + 三键导航栏）高度并广播到 AppStorage（单位 px）。
  // 为什么走 AppStorage：padding 必须加在 ArkUI 布局根上，而布局根在页面（Index.ets）里；
  // 这里只负责把「真值」发布出去，谁持有页面谁就用它（避免把 UI 组件依赖塞进 Ability）。
  private publishSafeInsets(w: window.Window): void {
    if (!this.immersiveOk) {
      // 沉浸式未生效：布局本身已避让系统栏，广播 0，绝不重复留间距
      AppStorage.setOrCreate<number>(SAFE_TOP_KEY, 0);
      AppStorage.setOrCreate<number>(SAFE_BOTTOM_KEY, 0);
      this.logInset('安全区 顶=0px 底=0px（沉浸式未生效，由系统自动避让）');
      return;
    }
    try {
      const sys: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const top: number = sys.visible ? sys.topRect.height : 0;
      const bottom: number = sys.visible ? sys.bottomRect.height : 0;
      AppStorage.setOrCreate<number>(SAFE_TOP_KEY, top);
      AppStorage.setOrCreate<number>(SAFE_BOTTOM_KEY, bottom);
      this.logInset(`安全区 顶=${top}px 底=${bottom}px 系统栏可见=${sys.visible ? '是' : '否'}`);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      hilog.error(DOMAIN, INSET_TAG, '读取避让区失败: %{public}s', msg);
      // 读失败时兜底为 0：宁可内容略微延伸，也不要因为异常让页面留出错误间距（不吞异常，已打 hilog）
      AppStorage.setOrCreate<number>(SAFE_TOP_KEY, 0);
      AppStorage.setOrCreate<number>(SAFE_BOTTOM_KEY, 0);
      this.logInset(`安全区 读取失败，按 0 处理: ${msg}`);
    }
  }

  // 安全区自证日志：hilog + 应用内日志 + files/diag/gcode_diag.txt 三通道同写（与方向日志同一文件）
  private logInset(text: string): void {
    hilog.info(DOMAIN, INSET_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${INSET_TAG}] ${text}`);
      const ok: boolean = AppLog.writeDiagFile(`${this.context.filesDir}/diag/gcode_diag.txt`,
        [`[${INSET_TAG}] ${text}`]);
      if (!ok) {
        hilog.warn(DOMAIN, INSET_TAG, '安全区日志落盘失败');
      }
    } catch (e) {
      hilog.error(DOMAIN, INSET_TAG, '安全区日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // 隐藏标题栏灰条背景，保留系统自绘三大键；禁用顶部悬浮标题栏，保留底部导航栏
  private async applyTitleBar(w: window.Window): Promise<void> {
    try {
      w.setWindowDecorVisible(false);
    } catch (e) {
      hilog.warn(DOMAIN, 'BambuHM', 'setWindowDecorVisible failed');
    }
    try {
      w.setWindowTitleButtonVisible(true, true, true);
    } catch (e) {
      hilog.warn(DOMAIN, 'BambuHM', 'setWindowTitleButtonVisible failed');
    }
    try {
      await w.setTitleAndDockHoverShown(false, true);
    } catch (e) {
      hilog.warn(DOMAIN, 'BambuHM', 'setTitleAndDockHoverShown failed');
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'BambuHM', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'BambuHM', '%{public}s', 'Ability onForeground');
    // 回到前台 = 渲染表面被重建的高概率时刻：必须让 UI 侧重贴材质，否则切片路径/打印板变灰。
    this.signalRenderResume('onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'BambuHM', '%{public}s', 'Ability onBackground');
  }
}
