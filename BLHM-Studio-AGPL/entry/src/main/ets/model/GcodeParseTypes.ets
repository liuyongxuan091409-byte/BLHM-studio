// gcode 解析 Worker 与主线程共享的消息/结果类型（放在独立模块，避免主线程 import worker 文件
// 时把 worker 的顶层代码也跑一遍）。

// 主线程 → Worker：请求解析某个 gcode 文件
export interface GcodeWorkerRequest {
  seq: number;       // 请求序号（主线程用于丢弃过期结果）
  path: string;
}

// Worker → 主线程：解析结果（紧凑扁平缓冲，避免百万级小对象）
export interface GcodeParseResult {
  ok: boolean;
  error: string;
  rawSegCount: number;
  segCount: number;
  ptCount: number;
  runCount: number;
  statText: string;
  presentRoles: number[];
  roleSegCount: number[];
  unknownNames: string[];
  unknownCounts: number[];
  ptXY: Float32Array;             // 2*ptCount（x,y 交替）
  runStart: Int32Array;
  runLen: Int32Array;
  runRole: Uint8Array;
  runW: Float32Array;
  layRunStart: Int32Array;        // layers+1
  layZ: Float32Array;
  layHMark: Float32Array;
}

// Worker → 主线程：响应包（要么有 result，要么有 error）
export interface GcodeWorkerResponse {
  seq: number;
  error: string;                  // 非空 = Worker 内部异常（主线程据此回退主线程解析）
  result: GcodeParseResult;
}
