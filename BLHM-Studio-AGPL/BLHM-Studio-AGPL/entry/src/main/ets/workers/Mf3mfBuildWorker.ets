import fs from '@ohos.file.fs';
import { worker } from '@kit.ArkTS';
import { MessageEvents } from '@ohos.worker';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Mf3mfJob, Mf3mfResult, writeModel3mf } from '../service/Mf3mfWriter';

// =============================================================================
// 「按盘切片输入工程」构建 Worker（独立线程）
//
// 【为什么必须开线程】按盘切片要为每盘生成一份「只含该盘对象」的 3MF 输入工程。这份 XML 序列化
// 在真机上是重活（盘1：11 个对象 / 约 42 万面 / 74MB XML），放在主线程上实测连续占用 22.8~41 秒
// → AppFreeze 看门狗判 THREAD_BLOCK_3S/6S（界面卡死 + 系统「应用无响应」弹窗）。
// 把它整体搬到本 Worker 后，主线程只做「装配 job + 收结果」，全程保持可响应。
//
// 写入器（ByteWriter / zip / XML 序列化）与主线程共用 service/Mf3mfWriter.ets 同一份实现，
// 因此 Worker 产物与主线程同步构建的产物逐字节一致（保存/打印链路不受影响）。
// =============================================================================

class Mf3mfWriteRequest {
  plate: number = 0;
  outPath: string = '';
  job: Mf3mfJob = new Mf3mfJob();
}

class Mf3mfWriteResponse {
  ok: boolean = false;
  reason: string = '';
  bytes: number = 0;
  triangles: number = 0;
  verts: number = 0;
  // 逐段耗时（ms）：totalMs 含消息反序列化后的全部工作；其余见 Mf3mfWriter.writeModel3mf。
  totalMs: number = 0;
  xmlMs: number = 0;
  vMs: number = 0;
  triMs: number = 0;
  zipMs: number = 0;
  writeMs: number = 0;
}

const workerPort = worker.workerPort;
workerPort.onmessage = (e: MessageEvents): void => {
  const req: Mf3mfWriteRequest = e.data as Mf3mfWriteRequest;
  const resp: Mf3mfWriteResponse = new Mf3mfWriteResponse();
  const t0: number = Date.now();
  try {
    const r: Mf3mfResult = writeModel3mf(req.job);
    const tWrite0: number = Date.now();
    const f: fs.File = fs.openSync(req.outPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, r.bytes.buffer);
    } finally {
      fs.closeSync(f);
    }
    resp.writeMs = Date.now() - tWrite0;
    resp.ok = true;
    resp.bytes = r.bytes.length;
    resp.triangles = r.triangleCount;
    resp.verts = r.vertCount;
    resp.xmlMs = r.xmlMs;
    resp.vMs = r.vMs;
    resp.triMs = r.triMs;
    resp.zipMs = r.zipMs;
  } catch (err) {
    resp.ok = false;
    resp.reason = err instanceof Error ? `${err.name}: ${err.message}` : JSON.stringify(err);
  }
  resp.totalMs = Date.now() - t0;
  // 逐段耗时进 hilog（tag=Mf3mfWorker），便于切片日志外单独核对；主线程也会收到同一份数据。
  hilog.info(0x0000, 'Mf3mfWorker',
    '盘=%{public}d 对象=%{public}d 顶点=%{public}d 面=%{public}d 字节=%{public}d ' +
    '总=%{public}dms XML=%{public}dms(顶点=%{public}dms 三角=%{public}dms) zip=%{public}dms 落盘=%{public}dms',
    req.plate, req.job.objs.length, resp.verts, resp.triangles, resp.bytes,
    resp.totalMs, resp.xmlMs, resp.vMs, resp.triMs, resp.zipMs, resp.writeMs);
  workerPort.postMessage(resp);
};
