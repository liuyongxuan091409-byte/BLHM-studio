// =============================================================================
// 关闭窗口前的「有未保存改动」把关（Phase 4 补做）
//
// 为什么单独抽一个模块：触发点在 EntryAbility（窗口关闭事件），而「弹确认框 + 保存」
// 只有页面层能做（需要 UIContext 与整套导出链路）。用一个注册回调把两头接起来，
// 避免 Ability 反向依赖某个页面组件（页面随页签切换会被销毁重建，直接持有它很危险）。
//
// 语义约定：ask() 返回 **true = 允许关闭**。
// 注意窗口事件 `windowWillClose` 的返回语义是相反的（resolve(true) = 不关闭），
// 取反由 EntryAbility 那一侧做，本模块只表达「业务上是否放行」。
// =============================================================================

export class DocGuard {
  // 由页面在 aboutToAppear 里注册；未注册（页面还没起来）时一律放行
  ask: () => Promise<boolean> = async (): Promise<boolean> => true;
}

export const docGuard: DocGuard = new DocGuard();
