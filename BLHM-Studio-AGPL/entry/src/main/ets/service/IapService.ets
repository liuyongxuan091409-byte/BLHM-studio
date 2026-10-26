import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLog } from './AppLog';

// 打赏（内购）服务。本轮只做「调用桩」：定义商品表与接口，方法体为空实现/TODO，
// 绝不发起任何真实支付或网络请求。接入华为 IAP 时在此处补齐实现。
//
// 日志 tag（本次新增，不改既有 tag）：hilog + 应用内日志（日志页）+ files/diag/gcode_diag.txt 三通道同用。
export const TIP_TAG: string = 'Tip';
const DOMAIN: number = 0x0000;

// 打赏商品：金额（元）→ 华为应用内支付商品 ID。
// ！！productId 待 AGC（AppGallery Connect）侧创建消耗型商品后确认！！
// 当前 tip_2 / tip_5 … tip_50 为占位约定，接入时须与 AGC 后台配置的商品 ID 保持一字不差。
export class TipProduct {
  amount: number = 0;
  productId: string = '';

  constructor(amount: number, productId: string) {
    this.amount = amount;
    this.productId = productId;
  }
}

// ★ 入口可见性开关（应用内购买手续未办妥期间隐藏「打赏」入口 —— 只隐藏，不删除）：
//   AGC 侧消耗型商品尚未创建、华为 IAP 手续未下来，先把入口收起来。
//   待手续办妥后把本常量改回 true 即恢复入口；商品表 TIP_PRODUCTS、IapService 的
//   全部方法与 view/TipPanel.ets 一律原样保留，不需要改动任何其它文件。
export const IAP_ENTRY_VISIBLE: boolean = false;

export const TIP_PRODUCTS: TipProduct[] = [
  new TipProduct(2, 'tip_2'),
  new TipProduct(5, 'tip_5'),
  new TipProduct(10, 'tip_10'),
  new TipProduct(15, 'tip_15'),
  new TipProduct(20, 'tip_20'),
  new TipProduct(50, 'tip_50'),
];

export class IapService {
  // 按商品 ID 查金额（用于日志/展示；未命中返回 0）
  static amountOf(productId: string): number {
    for (const p of TIP_PRODUCTS) {
      if (p.productId === productId) {
        return p.amount;
      }
    }
    return 0;
  }

  // 三通道日志：hilog + 应用内日志 + files/diag/gcode_diag.txt（沿用 ThreeMfExport.log 的写入通道）。
  // filesDir 为空（拿不到上下文）时降级为两通道，绝不因此崩溃。
  static log(filesDir: string, text: string): void {
    hilog.info(DOMAIN, TIP_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${TIP_TAG}] ${text}`);
      if (filesDir.length > 0) {
        if (!AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`, [`[${TIP_TAG}] ${text}`])) {
          hilog.warn(DOMAIN, TIP_TAG, '打赏日志落盘失败');
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TIP_TAG, '打赏日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }

  // ===== 以下三个方法为「桩」：当前仅打日志说明意图，返回空实现 =====
  // 接入华为 IAP（@kit.IAPKit 的 iap.createPurchase / iap.consumePurchase / iap.finishTransaction）时，
  // 在每个 TODO 处替换为真实调用；本期不引入任何依赖、不发任何请求。

  // 拉起购买：productId 为 AGC 商品 ID（如 tip_2）。
  static createPurchase(filesDir: string, productId: string): void {
    // TODO(接入华为 IAP)：在此调用 iap.createPurchase({ productId }) 并处理购买结果。
    const amount: number = IapService.amountOf(productId);
    IapService.log(filesDir,
      `[STUB] createPurchase 将调用华为 IAP：productId=${productId} amount=${amount}元（原型未实现，未发起支付/网络请求）`);
  }

  // 消耗已购商品：purchaseToken / purchaseData 通常需先提交服务端校验，再 consume。
  // 注意：令牌属敏感数据，日志只记长度，不落原文。
  static consume(filesDir: string, purchaseToken: string, purchaseData: string): void {
    // TODO(接入华为 IAP)：服务端校验通过后调用 iap.consumePurchase({ purchaseToken, purchaseData })。
    IapService.log(filesDir,
      `[STUB] consume：purchaseToken.len=${purchaseToken.length} purchaseData.len=${purchaseData.length}（原型未实现）`);
  }

  // 结束本次购买流程（发货完成/校验失败后均需收尾）。
  static finish(filesDir: string): void {
    // TODO(接入华为 IAP)：调用 iap.finishTransaction 结束流程。
    IapService.log(filesDir, '[STUB] finish：结束购买流程（原型未实现）');
  }
}
