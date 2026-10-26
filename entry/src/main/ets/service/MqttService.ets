import testNapi from 'libentry.so';
import { AppLog } from './AppLog';

// MQTT 打印机通信服务：将回调式 NAPI 封装为 Promise
export class MqttService {
  // 已落盘的原生日志条数（用于三通道日志：把新增的原生 MQTT 日志追加写进 files/diag/gcode_diag.txt）
  private static diagDumped: number = 0;

  // 把「新增的」原生 MQTT 日志（含 MqttConn 逐步诊断）追加写进应用沙箱诊断文件。
  // 原生侧只写 hilog + 内存缓冲（日志页），此方法补上第三条通道（文件），不连设备也能取走证据。
  // filePath 由调用方传入（ArkTS 侧才知道应用沙箱中的完整路径，如 filesDir/diag/gcode_diag.txt）。
  static flushLogsToDiag(filePath: string): void {
    try {
      const arr: string[] = JSON.parse(testNapi.mqttGetLogs()) as string[];
      // 缓冲被裁剪（最多 200 条）后下标会前移：长度回退时重置，避免漏写
      if (arr.length < MqttService.diagDumped) { MqttService.diagDumped = 0; }
      if (arr.length <= MqttService.diagDumped) { return; }
      const fresh: string[] = arr.slice(MqttService.diagDumped);
      MqttService.diagDumped = arr.length;
      AppLog.writeDiagFile(filePath, fresh);
    } catch (e) {
      // 忽略：诊断写文件失败不影响主流程
    }
  }

  static discover(): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.mqttDiscover((printersJson: string) => {
        resolve(printersJson);
      });
    });
  }

  static connect(ip: string, accessCode: string, serial: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.mqttConnect(ip, accessCode, serial, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  static disconnect(): void {
    testNapi.mqttDisconnect();
  }

  static getLogs(): string {
    return testNapi.mqttGetLogs();
  }

  static getStatus(): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.mqttGetStatus((statusJson: string) => {
        resolve(statusJson);
      });
    });
  }

  // 增量字段合并单元自测（同步）：返回逐条 PASS/FAIL 文本；原生侧同时写 hilog(tag=MqttSelfTest)。
  static selfTestMerge(): string {
    return testNapi.mqttSelfTestMerge();
  }

  static sendCommand(commandJson: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.mqttSendCommand(commandJson, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // 请求设备侧 K 值表（**只读**）：原生侧发 extrusion_cali_get 并发两次做热身。
  // 只查询，不写任何设备数据；应答原文由原生侧留存，用 getCaliRaw() 取。
  // 返回 {"ok":bool}（ok 只表示"请求发出去了"，不代表打印机已回答）。
  static requestKProfiles(): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.mqttRequestKProfiles((resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // 取已留存的"校准相关原始报文"：JSON 字符串数组（最多 12 条，时间升序）。
  // 协议形状尚未定案，所以原生侧不做解析，交给 KProfileParse 在 ArkTS 侧解析（可夹具单测）。
  static getCaliRaw(): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.mqttGetCaliRaw((rawJson: string) => {
        resolve(rawJson);
      });
    });
  }

  // FTPS 上传（隐式 FTPS 990）：把本地文件 PUT 到打印机 remotePath。只上传，不打印。
  // remotePath 以 '/' 开头 = 完整远端路径（如 "/sdcard/x.3mf"）；否则原生侧拼成 "/cache/<name>"。
  // ip + 访问码由原生侧从当前 MQTT 会话取（不经过 JS），返回结果 JSON（FtpsUploadResult）。
  static ftpsUpload(localPath: string, remotePath: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.ftpsUpload(localPath, remotePath, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // FTPS LIST：列打印机某个目录（如 /cache）的目录项。只读，不上传、不打印。
  // 返回结果 JSON（FtpsListResult: {ok, code, message, dir, entries:[], log:[]}）。
  static ftpsList(dir: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.ftpsList(dir, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // FTPS DELE：删除打印机上的一个文件（只删文件、不删目录）。
  // 返回结果 JSON（{ok, code, message, remotePath, log}）。
  static ftpsRemove(remotePath: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.ftpsRemove(remotePath, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // FTPS RETR：把打印机上的文件下载到本地（maxBytes 为上限，0 = 不限）。
  // 返回结果 JSON（{ok, code, message, remotePath, localPath, bytes, log}）。
  static ftpsDownload(remotePath: string, localPath: string, maxBytes: number): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void) => {
      testNapi.ftpsDownload(remotePath, localPath, maxBytes, (resultJson: string) => {
        resolve(resultJson);
      });
    });
  }

  // 启动摄像头取流：按机型自动选择端口（322 RTSPS / 6000 chamber image），
  // 端口选择与回退都在原生侧完成。forceProto 供测试注入（0 自动 / 1 强制 322 / 2 强制 6000）。
  static cameraStart(ip: string, accessCode: string, model: string, serial: string, forceProto: number): boolean {
    return testNapi.cameraStart(ip, accessCode, model, serial, forceProto);
  }

  // 查询机型/序列号将被选中的端口候选顺序（不发起连接，便于核对选择逻辑）
  static cameraResolveProtocol(model: string, serial: string): string {
    return testNapi.cameraResolveProtocol(model, serial);
  }

  static cameraStop(): void {
    testNapi.cameraStop();
  }

  static cameraGetFrame(): testNapi.CameraFrame | null {
    return testNapi.cameraGetFrame();
  }
}
