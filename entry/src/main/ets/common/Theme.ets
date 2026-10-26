// 沉浸光感主题常量（对齐 Bambu Studio 深色视觉）
export class Theme {
  static readonly bg: string = '#0B0B0F';            // 页面背景
  static readonly surface: string = '#16161C';       // 卡片/面板
  static readonly surfaceElevated: string = '#1F1F27'; // 悬浮卡片
  static readonly border: string = '#2A2A33';        // 描边
  static readonly accent: string = '#00C48C';        // 品牌强调色（沉浸绿光）
  static readonly accentSoft: string = '#33E0B0';    // 高亮光晕
  static readonly textPrimary: string = '#ECECF0';   // 主文字
  static readonly textSecondary: string = '#9A9AA4'; // 次文字
  static readonly warn: string = '#FFB020';          // 警告
  static readonly info: string = '#4DA6FF';          // 信息
  static readonly danger: string = '#FF3D2E';        // 危险/高温
  // 参数「被自定义修改」高亮橙：用于把偏离预设默认值的参数数值 / 分类标签标橙，
  // 与品牌绿（accent）和警告琥珀（warn）明确区分，一眼看出哪些是用户改过的非预设值。
  static readonly modified: string = '#FF8C1A';

  // ===== 光标「绿色点光晕」（左侧导航等：光点跟着鼠标 / 手指走）=====
  // 观感：指针所在的那一项亮起一团绿色径向光，中心随光标移动。
  static readonly glowHalo: string = '#33E0B0';  // 光晕中心（高亮绿）
  static readonly glowTint: string = '#1FBF8E';  // 光晕过渡色
}
