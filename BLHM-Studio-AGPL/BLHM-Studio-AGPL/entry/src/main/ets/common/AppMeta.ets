// 应用元信息（关于页 / 开源合规的唯一来源）
//
// 为什么单独一个文件：源码地址会变（换仓库、换账号），AGPL 声明也会随发布形态变。
// 把它们集中在这里，改地址只需要动一行，不用翻 UI 代码；也避免同一句话在几个页面各写一遍。
export class AppMeta {
  // 应用显示名（与 AppScope/app.json5 的 label 对应）
  static readonly APP_NAME: string = 'BLHM studio';

  // 源码仓库地址 —— **发布前必须改成你自己的仓库**
  // 改法：只替换下面这一行的字符串。判断是否还是占位值看 SOURCE_PLACEHOLDER。
  // AGPL-3.0 第 6 条要求向拿到二进制的人提供对应源码，这个地址就是那个入口。
  static readonly SOURCE_URL: string = 'https://github.com/your-account/blhm-studio';

  // 占位值里带的这段特征串；UI 据此提示「未配置」，避免把假地址当真的给用户
  static readonly SOURCE_PLACEHOLDER: string = 'your-account';

  // 许可证展示名
  static readonly LICENSE_NAME: string = 'GNU Affero General Public License v3.0';

  // 许可证全文：随包放在 rawfile 里（离线也能读，不依赖网络）
  static readonly LICENSE_RAW: string = 'LICENSE-AGPL-3.0.txt';

  // 是否已把占位地址替换成真实地址
  static isSourceConfigured(): boolean {
    return AppMeta.SOURCE_URL.indexOf(AppMeta.SOURCE_PLACEHOLDER) < 0;
  }

  // 关于页的 AGPL 声明正文（与仓库根 LICENSE / NOTICE.md 口径一致）
  static agplStatement(): string {
    return '本应用（含 ArkTS 界面层、C++ 原生层与切片内核）整体以 AGPL-3.0 授权发布。'
      + '切片内核来自 Bambu Studio 开源的 libslic3r，其原始版权归 Bambu Lab 与 PrusaSlicer 等上游作者所有。'
      + '我们对内核的改动已记录在仓库的 MODIFICATIONS.md 中。';
  }

  // 源码与许可证说明（关于页第二段）
  static sourceHint(): string {
    return '按 AGPL-3.0 第 6 条，任何拿到本应用安装包的人都有权获得完整对应源码。'
      + '源码仓库包含切片内核源码树、原生层、界面层与构建脚本；'
      + 'FFmpeg、OpenCASCADE 等预编译依赖不随仓库分发，获取方式见仓库 README。';
  }
}
