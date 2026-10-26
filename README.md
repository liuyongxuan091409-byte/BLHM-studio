# BLHM Studio（鸿蒙 3D 打印切片客户端）

面向 HarmonyOS / OpenHarmony 的 FDM 3D 打印客户端：ArkTS 写界面与业务，C++ 通过 NAPI 承担切片、
网络（MQTT / FTPS）、模型解析与渲染。

- **切片内核**：`libslic3r`，来自 [BambuStudio](https://github.com/bambulab/BambuStudio)（2.8.2.61 同源），交叉编译为 OpenHarmony arm64 静态库。
- **应用层**：本仓库自有代码（ArkTS 62 个文件 + C++ 原生层），实现模型导入/摆位、参数编辑、切片、预览、设备连接与打印。
- **许可证**：**AGPL-3.0**（见 `LICENSE`）。因为本程序链接并分发了 Bambu Studio 的 libslic3r 及其衍生源码，
  整个作品按 AGPL-3.0 分发。详见 `NOTICE.md`、`MODIFICATIONS.md`、`SOURCE-OFFER.md`。

> 这是**衍生作品**，并非 Bambu Lab 官方产品；上游 GUI（wxWidgets 桌面版）不在本仓库内。

---

## 一、仓库内容

```
.
├─ AppScope/                    应用级配置与图标
├─ entry/
│  ├─ src/main/
│  │  ├─ ets/                   ArkTS 界面与业务（62 文件）
│  │  ├─ cpp/                   原生层
│  │  │  ├─ napi_init.cpp        NAPI 导出与桥接
│  │  │  ├─ bambu_mqtt.cpp       MQTT 客户端（设备控制通道）
│  │  │  ├─ bambu_ftps.cpp       打印文件上传（隐式 FTPS）
│  │  │  ├─ bambu_discovery.cpp  局域网设备发现
│  │  │  ├─ bambu_camera.cpp     RTSP 摄像头
│  │  │  ├─ bambu_renderer.cpp   模型渲染
│  │  │  ├─ bambu_mesh.cpp       网格处理
│  │  │  └─ libslic3r/           **切片内核完整源码树**（含我们新增的 ohos_slicer_api.cpp/.hpp）
│  │  ├─ resources/             图标、预设、校准模型、HMS 故障码表
│  │  └─ module.json5
│  ├─ build-profile.json5
│  └─ oh-package.json5
├─ LICENSES/                    各第三方许可证全文
├─ build.ps1 / build.cmd        构建脚本（Windows）
├─ LICENSE                      AGPL-3.0 全文
├─ NOTICE.md                    第三方组件与许可证
├─ MODIFICATIONS.md             相对上游的修改说明（AGPL §5(a)）
└─ SOURCE-OFFER.md              对应源码说明（AGPL §6/§13）
```

**不包含**（体积大或含个人信息，需自行准备）：

- 预编译静态库：`liblibslic3r.a`、FFmpeg（`ffmpeg-6.1.2`）、OpenCASCADE（`occt-build`）、TBB/CGAL/GMP/MPFR/nlopt/expat 等；
- 签名材料（`.p12` / `.p7b` / `.cer`）与口令、`local.properties`、本机装机脚本；
- 构建产物（`entry/build`、`.hvigor`、`entry/.cxx`）。

## 二、构建（Windows + DevEco Studio）

1. 安装 DevEco Studio 与 HarmonyOS SDK；工程按 **API 26（6.0.0）** 配置，原生 ABI 为 `arm64-v8a`。
2. 准备原生依赖，并**改写** `entry/src/main/cpp/CMakeLists.txt` 里的绝对路径：
   ```cmake
   set(FFMPEG_DIR C:/HMBambulabStudio/ffmpeg-6.1.2)     # → 你的 FFmpeg for OHOS 路径
   set(OCCT_BUILD C:/HMBambulabStudio/occt-build)       # → 你的 OCCT for OHOS 构建路径
   ```
   `libslic3r` 的源码在本仓库 `entry/src/main/cpp/libslic3r/`，需先用 OpenHarmony NDK 交叉编译出
   `liblibslic3r.a`（上游无现成脚本，社区做法可参考 BambuStudio / PrusaSlicer 的 CMake 选项）。
3. 签名：本仓库**不含**签名配置。用 DevEco Studio 的自动签名，或自行在 `build-profile.json5`
   的 `app.signingConfigs` 中填入你的材料。
4. 构建：
   ```bat
   build.cmd
   ```
   等价于 `hvigorw assembleHap --mode module -p product=default -p buildMode=debug`。

   > `build.ps1` 里还硬编码了开发机的两处路径，复现时按本机改：
   > `$DevEco = 'C:\Program Files\Huawei\DevEco Studio'`、`$JdkHome = 'C:\tools\jdk-21.0.12.1+1'`。

> 后端说明：本机未安装 DevEco CLI（`devecocli`）时，工具链会回退到 `hvigorw`，属正常路径。

## 三、当前状态（据实说明）

已完成并在真机（HarmonyOS PC 形态）验证过的部分：模型导入与摆位、参数面板、切片、分层预览、
局域网设备连接、打印弹窗与文件上传准备、校准向导（流量比例 / 动态流量 PA 图案）与结果写回本地耗材预设、
设备侧 K 值**只读**查询链路。

**未完成 / 未验证**：

- 设备侧 K 值**写回**（`extrusion_cali_set`）尚未接入；面板明确标注「未接入」，不以本地成功冒充设备成功。
- 双喷嘴机型（H2D 等）的 `project_file` 喷嘴映射字段仍在补齐中。
- 校准的自动 PA 线（机内自动判定）需要打印机侧配合，当前仅给出手动图案试块。

## 四、发布前必读（与 AGPL 无关、但会直接影响你）

AGPL 合规由本仓库的 `LICENSE` / `NOTICE.md` / `MODIFICATIONS.md` / `SOURCE-OFFER.md` 覆盖；
下面几条是**另外的风险**，请你自己决定怎么处理，我没有替你改代码：

1. **包名与 vendor 含 "bambu"**：`AppScope/app.json5` 里 `bundleName: "com.bambuHM.lcy"`、`vendor: "bambuHM"`。
   公开分发前建议改成你自己的域名倒序（同时改 `module.json5` 与装机脚本中的引用）。
2. **商标素材**：`entry/src/main/resources/base/media/app_icon.png` 等图标沿用了拓竹标识风格
   （`docs/` 下另有官方参考 SVG，未打进本仓库）。公开仓库建议换成自绘标识——这是商标问题，AGPL 不解决。
3. **随包的上游资产**：`resources/rawfile/calib/*.3mf`（校准试块）、`hms_*.json`（HMS 故障码表）、
   `fdm_process_common.json` 等来自 Bambu Studio 仓库，随 AGPL 源码一并分发；若上游另有资产条款，以你的判断为准。
4. **不要提交**：`local.properties`、任何 `.p12/.p7b/.cer`、`entry/build`、`.hvigor`、`leave` 出去的构建日志。
5. **应用内「关于页」的源码地址是占位值**：`entry/src/main/ets/common/AppMeta.ets` 里的
   `SOURCE_URL` 目前是 `https://github.com/your-account/blhm-studio`。仓库建好后把这一行改成真实地址，
   否则关于页的「获取源码」会跳到不存在的页面（页面上会显示一条黄色占位提示）。

## 五、许可证与免责

- 本作品以 **GNU Affero General Public License v3.0** 分发（`LICENSE`）。你可以修改、再分发，
  但再分发时必须提供对应源码并保留版权与许可声明。
- 无任何担保。使用本软件造成的设备损坏、耗材浪费或数据丢失，作者不承担责任。
- Bambu、Bambu Lab、Bambu Studio 等名称与标识归其权利人所有；本仓库仅作技术说明与兼容性引用。

## 六、对应源码

本仓库的 `entry/src/main/cpp/`（含完整 `libslic3r` 源码树）即是 AGPL 意义上的**对应源码**。
获取方式、可复现构建边界见 `SOURCE-OFFER.md`。
