import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { Vec3 } from '@kit.ArkGraphics3D';
import { MeshGeometry, zUpToYUpInPlace, repairNormals } from '../model/MeshUtils';
import { modelState, ModelInstance, PLATE_LIFT_MM } from '../model/ModelState';
import { history } from '../model/History';
import { ensureThumbnail } from '../model/Thumbnail';
import { Import3mfInfo, Import3mfSettings, ImportObjectMeta, ImportPlateMeta, PlateMeta, PlateSize, resolvePlateSize } from '../model/Models';
import { SlicerService } from './SlicerService';
import { ThreeMfExport } from './ThreeMfExport';
import { AppLog } from './AppLog';

// =============================================================================
// 3MF 导入：**几何 + 设置 + 盘一次拿全**，全部来自内核自带的 BBL 3MF 加载器
//   slicerImport3mf -> slic3r_import_3mf -> load_model_file -> Model::read_from_file
//                   -> load_bbs_3mf（与切片/项目导出同一条内核路径）
//
// 【为什么删掉原来的自研 XML 解析器】
//   旧实现自己在 ArkTS 里解 zip + 解析 *.model / model_settings.config，只能拿到几何与盘，
//   且 project_settings.config 一个字都没读（机型/工艺/耗材/板/层高/墙层数/首层速度全部不还原），
//   盘信息还因为 model_settings.config 形态不匹配而恒为 0 盘。改用内核加载器后，
//   旧的那套（MfObject/MfRef/MfDoc/parseDoc/collectVertices/parsePlates/gather/makeMesh…）
//   已无任何引用，故整体删除，不留「两套并存」。
//
// 顶点走 ArrayBuffer（大模型不能塞 JSON），元数据（名字/面数/摆放/包围盒/顶点区间/盘/设置）走 JSON。
// =============================================================================

// 专用日志 tag（三通道：hilog + 应用内日志 + files/diag/gcode_diag.txt）
export const IMPORT3MF_TAG: string = 'Import3mf';

// 内核导入的原始返回（Promise 包装用；ArkTS 静态类型，不用 any）
class Import3mfRaw {
  info: string = '';
  positions: ArrayBuffer = new ArrayBuffer(0);
}

// 导入结果（交给页面决定提示文案；ok=false 时 message 为真实失败原因）
export class Import3mfOutcome {
  ok: boolean = false;
  hasModel: boolean = false;
  message: string = '';
  objectCount: number = 0;
  triangleCount: number = 0;
  plateCount: number = 0;
  // 机型/工艺/耗材/板/层高/墙层数/首层速度 摘要（日志与提示共用，值全部来自内核）
  summary: string = '';
  settings: Import3mfSettings | null = null;
}

export class ThreeMfImport {
  // 「底部贴板面积」下限（mm²）：低于该值视为**点/尖接触底** —— 首层几乎没有有效挤出截面，
  // 切片内核会报 empty initial layer（Bambu 官方给的建议是 cut the bottom or enable supports）。
  // 这里**只做提示**、不改几何（自动加支撑/自动切底都会改用户模型，不能悄悄做）。
  // 0.5mm² 取得很保守：连 1×1mm 的小平面都能通过，只有真正的点/尖接触才命中。
  private static readonly THIN_BOTTOM_MM2: number = 0.5;
  /** 本次导入里「底部点/尖接触」的件名（带面积），供调用方给可操作提示。 */
  static thinBottoms: string[] = [];
  // 本次导入的耗材槽位颜色列表（project_settings.config 的 filament_colour）。
  // 与每个对象的 extruder 序号配合，把「对象颜色」还原回 displayColor（多色工程往返）。
  private static importColours: string[] = [];

  // 入口：把选择器 URI 的 3MF 交给内核加载器，按返回结果建模型实例 + 发布设置
  static async importFromUri(uri: string, filesDir: string): Promise<Import3mfOutcome> {
    const out: Import3mfOutcome = new Import3mfOutcome();
    const shortName: string = ThreeMfImport.baseNameOf(uri);
    ThreeMfImport.thinBottoms = [];

    // 内核加载器需要「真实路径 + .3mf 扩展名」，先拷一份到应用私有目录
    // （选择器给的是 content:// URI，libslic3r 只会按路径读文件）
    const slicePath: string = `${filesDir}/slice_input.3mf`;
    if (!ThreeMfImport.copyTo(uri, slicePath)) {
      out.message = '读取所选文件失败';
      ThreeMfImport.log(filesDir, `导入3mf 路径=${uri} 结果=失败(文件拷贝失败)`);
      return out;
    }
    AppStorage.setOrCreate<string>('sliceModelPath', slicePath);

    // 内核导入（worker 线程；几何以 ArrayBuffer 回来，元数据在 info JSON）
    let raw: Import3mfRaw;
    try {
      raw = await ThreeMfImport.callKernel(slicePath);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      out.message = `内核调用失败：${msg}`;
      ThreeMfImport.log(filesDir, `导入3mf 路径=${shortName} 结果=失败(内核调用异常:${msg})`);
      return out;
    }

    let info: Import3mfInfo;
    try {
      info = JSON.parse(raw.info) as Import3mfInfo;
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      out.message = '导入结果解析失败';
      ThreeMfImport.log(filesDir, `导入3mf 路径=${shortName} 结果=失败(结果解析异常:${msg})`);
      return out;
    }

    const presetsPrinter: string = info.presets !== undefined ? info.presets.printer : '';
    const presetsProcess: string = info.presets !== undefined ? info.presets.process : '';
    const presetsFilament: string = info.presets !== undefined ? info.presets.filament : '';
    const presetsBed: string = info.presets !== undefined ? info.presets.bed : '';
    const lh: number = ThreeMfImport.numOf(info.layerHeight);
    const wl: number = ThreeMfImport.numOf(info.wallLoops);
    const ils: number = ThreeMfImport.numOf(info.initialLayerSpeed);

    if (info.ok !== true) {
      out.message = info.message !== undefined && info.message !== '' ? info.message : '内核导入失败';
      ThreeMfImport.log(filesDir,
        `导入3mf 路径=${shortName} 对象=0 三角面=0 盘=0 机型=${presetsPrinter} 工艺=${presetsProcess} ` +
        `耗材=${presetsFilament} 板=${presetsBed} 层高=${lh} 墙层数=${wl} 首层速度=${ils} ` +
        `结果=失败(${out.message})`);
      return out;
    }

    const objects: ImportObjectMeta[] = info.objects !== undefined ? info.objects : [];
    const plates: ImportPlateMeta[] = info.plates !== undefined ? info.plates : [];

    // 盘 id → 盘名 / 床型
    const plateNameById: Map<number, string> = new Map<number, string>();
    const plateBedById: Map<number, string> = new Map<number, string>();
    for (const p of plates) {
      plateNameById.set(p.id, p.name);
      plateBedById.set(p.id, p.bed);
    }

    // 盘面公共中心（内核 instance 摆放是盘面坐标）：优先用内核给的热床包围盒，
    // 拿不到时退到「各对象世界中心的平均」，保证 3D 里对象相对方位不变。
    let fileBedCx: number = 0;
    let fileBedCy: number = 0;
    if (info.bed !== undefined && info.bed.w > 0 && info.bed.h > 0) {
      fileBedCx = info.bed.minX + info.bed.w * 0.5;
      fileBedCy = info.bed.minY + info.bed.h * 0.5;
    } else {
      let sumX: number = 0;
      let sumY: number = 0;
      for (const o of objects) {
        sumX += ThreeMfImport.at(o.offset, 0) + (ThreeMfImport.at(o.bbox, 0) + ThreeMfImport.at(o.bbox, 3)) * 0.5;
        sumY += ThreeMfImport.at(o.offset, 1) + (ThreeMfImport.at(o.bbox, 1) + ThreeMfImport.at(o.bbox, 4)) * 0.5;
      }
      const n: number = objects.length > 0 ? objects.length : 1;
      fileBedCx = sumX / n;
      fileBedCy = sumY / n;
    }

    // =========================================================================
    // 多盘映射（把 makerlab/拓竹多盘件「盘 2 及之后越界」的对象搬回单板）
    //
    // 现象：多盘 3MF 在世界坐标里把各盘按板阵列排布（盘 2 在 +320，盘 4 在 −320……），
    // 导入后画面上同时出现好几块板、盘 2+ 的对象跑到单板范围外。
    //
    // 盘 origin 取法（说明依据）：
    //   内核 slicer_import_3mf 只回报「盘归属」（plates[].objects[]）与每个对象的
    //   offset/bbox，**不回报盘原点/盘 bbox**（见 ohos_slicer_api.cpp：PlateData 加载路径上
    //   只有 obj_inst_map）。因此盘原点不可得 —— 退而按「该盘对象群的集体 bbox」推导偏移：
    //     该盘对象群的世界 bbox 中心 = 组中心 C_p；
    //     目标单板中心 = targetC；Δ_p = targetC − C_p。
    //   即把「盘 p 的对象整体」平移，使它们的集体中心落到我们这块板的中心。**盘内相对布局不变**
    //   （同盘所有对象加同一个 Δ），也不打散/不堆到原点。
    //   盘 1 的对象本来就在单板中心附近（组中心≈单板中心）→ Δ≈0，与单盘行为一致。
    //   幂等性：Δ 每次都从文件**原始** offset/bbox 现算与「单板中心」比较，不依赖上一次结果、
    //   不累积；映射后的单板件再导入时盘数=1，不再触发映射 → 结果稳定。
    //
    // 单盘 / 无盘 / 归属缺失 / 坐标已合理 一律不映射（见下方逐条判定）。
    // =========================================================================
    const targetSize: PlateSize = resolvePlateSize(presetsPrinter);
    const targetCx: number = targetSize.w * 0.5;
    const targetCy: number = targetSize.h * 0.5;

    // 判定：对象归属到 >=2 个不同盘才算多盘。全部对象同盘（含内核兜底全归盘 1、或单盘文件）
    // 一律不映射 —— 避免把本来正常的单盘件误平移。
    const distinct: Set<number> = new Set<number>();
    let plateMissing: number = 0;
    for (const o of objects) {
      if (o.plate > 0) {
        distinct.add(o.plate);
      } else {
        plateMissing++;
      }
    }
    const multiPlate: boolean = distinct.size > 1;

    // 盘 id → Δ（床坐标 mm）；仅多盘时非零
    const shiftX: Map<number, number> = new Map<number, number>();
    const shiftY: Map<number, number> = new Map<number, number>();
    let mappedAny: boolean = false;
    if (multiPlate) {
      distinct.forEach((pid: number) => {
        let loX: number = 1e30;
        let loY: number = 1e30;
        let hiX: number = -1e30;
        let hiY: number = -1e30;
        let cnt: number = 0;
        const names: string[] = [];
        for (const o of objects) {
          if (o.plate !== pid) {
            continue;
          }
          cnt++;
          names.push(o.name);
          const ox: number = ThreeMfImport.at(o.offset, 0);
          const oy: number = ThreeMfImport.at(o.offset, 1);
          const bx0: number = ox + ThreeMfImport.at(o.bbox, 0);
          const by0: number = oy + ThreeMfImport.at(o.bbox, 1);
          const bx1: number = ox + ThreeMfImport.at(o.bbox, 3);
          const by1: number = oy + ThreeMfImport.at(o.bbox, 4);
          if (bx0 < loX) { loX = bx0; }
          if (by0 < loY) { loY = by0; }
          if (bx1 > hiX) { hiX = bx1; }
          if (by1 > hiY) { hiY = by1; }
        }
        // 判定（坐标已合理，不映射）：该盘对象群的世界 bbox 已完全落在单板范围内 → Δ=0。
        // 用一点容差（0.001mm）避免浮点噪声把「刚好贴边」误判成越界。
        const inside: boolean =
          loX >= -0.001 && hiX <= targetSize.w + 0.001 && loY >= -0.001 && hiY <= targetSize.h + 0.001;
        let dx: number = 0;
        let dy: number = 0;
        if (!inside) {
          dx = targetCx - (loX + hiX) * 0.5;
          dy = targetCy - (loY + hiY) * 0.5;
        }
        shiftX.set(pid, dx);
        shiftY.set(pid, dy);
        if (dx !== 0 || dy !== 0) {
          mappedAny = true;
        }
        const res: string = inside
          ? '已在板内,不映射'
          : `已映射(组中心(${ThreeMfImport.f1((loX + hiX) * 0.5)},${ThreeMfImport.f1((loY + hiY) * 0.5)})→(${ThreeMfImport.f1(targetCx)},${ThreeMfImport.f1(targetCy)}))`;
        ThreeMfImport.log(filesDir,
          `导入3mf 多盘映射 盘=${pid} 偏移=(${ThreeMfImport.f1(dx)},${ThreeMfImport.f1(dy)}) ` +
          `对象=${cnt}(${names.join(';')}) 结果=${res}`);
      });
    }
    if (multiPlate && plateMissing > 0) {
      // 归属缺失：这些对象没有盘 id，无法判定属于哪块板 —— 不平移（保持内核给的原位），如实记录。
      ThreeMfImport.log(filesDir, `导入3mf 多盘映射 无盘归属对象=${plateMissing} 结果=保持原位(不平移)`);
    }

    // 摆放用的盘中心：多盘映射时用「我们这块板的中心」，使映射后 position 相对它归零；
    // 单盘保持原有「文件热床中心」口径，行为与之前完全一致。
    const posCx: number = multiPlate ? targetCx : fileBedCx;
    const posCy: number = multiPlate ? targetCy : fileBedCy;
    // 记下「content 坐标是基于哪块盘的中心」：换机型时据此做换盘补偿（见 ModelState.syncPlateTo）。
    // 单盘 = 文件热床（导入后通常会切到工程自带机型）；多盘映射 = 目标盘（工程机型）。
    // 取不到热床尺寸时给 0 → 由 syncPlateTo 认作当前盘（不做任何平移）。
    const contentW: number = multiPlate ? targetSize.w
      : (info.bed !== undefined && info.bed.w > 0 ? info.bed.w : 0);
    const contentH: number = multiPlate ? targetSize.h
      : (info.bed !== undefined && info.bed.h > 0 ? info.bed.h : 0);
    modelState.setContentPlate(contentW, contentH);

    // ---- 建几何：内核给的是一段连续的三角汤顶点，按 vertOffset/vertCount 切片 ----
    // 「对象颜色」还原：把本文件的耗材槽位颜色列表挂到导入会话上，addOne 按对象 extruder 取色。
    ThreeMfImport.importColours = info.filamentColours !== undefined ? info.filamentColours : [];
    const all: Float32Array = new Float32Array(raw.positions);
    let triTotal: number = 0;
    let count: number = 0;
    for (const meta of objects) {
      const off: number = meta.vertOffset;
      const cnt: number = meta.vertCount;
      if (cnt < 9 || off < 0 || off + cnt > all.length) {
        continue;
      }
      const name: string = meta.name !== undefined && meta.name !== '' ? meta.name : shortName;
      const plate: number = meta.plate > 0 ? meta.plate : 0;
      const plateName: string = plateNameById.get(plate) !== undefined ? (plateNameById.get(plate) as string) : '';
      const plateBed: string = plateBedById.get(plate) !== undefined ? (plateBedById.get(plate) as string) : '';
      const dx: number = multiPlate && plate > 0 && shiftX.get(plate) !== undefined ? (shiftX.get(plate) as number) : 0;
      const dy: number = multiPlate && plate > 0 && shiftY.get(plate) !== undefined ? (shiftY.get(plate) as number) : 0;
      const id: number = ThreeMfImport.addOne(all.subarray(off, off + cnt), meta, name, plate, plateName, plateBed,
        posCx, posCy, dx, dy);
      if (id < 0) {
        continue;
      }
      triTotal += meta.triangles;
      count++;
    }

    if (count > 0) {
      AppStorage.setOrCreate<number>('focusModelSeq', (AppStorage.get<number>('focusModelSeq') ?? 0) + 1);
    }

    // 文件级盘状态（见 ModelState.filePlates）：无网格文件（如 001.gcode.3mf）只有盘元数据，
    // 对象聚合不出盘行 —— 这里把内核给的盘如实交给 ModelState，盘列表才不会空。
    // 含网格的文件一律写空数组：盘归属交给「对象聚合」，避免两套口径打架。
    const filePlates: PlateMeta[] = [];
    if (count === 0) {
      for (const p of plates) {
        filePlates.push({
          index: p.id,
          name: p.name,
          count: 0,
          firstId: -1,          // 无对象 → 无缩略图（列表里显示盘号占位）
          bed: p.bed,
          objNames: []          // 盘行会如实显示「（无对象）」
        });
      }
    }
    modelState.setFilePlates(filePlates);
    // 多盘文件：把每盘自己的床型记进盘注册表（PlateRec.bed 是盘级床型的唯一权威）。
    // 单盘文件不记 —— 保持「跟随全局床型」的旧语义；多盘才需要每盘独立。
    if (multiPlate && count > 0) {
      for (const p of plates) {
        if (p.id > 0 && p.bed !== undefined && p.bed.length > 0) {
          modelState.ensurePlate(p.id, p.name, p.bed);
        }
      }
    }
    // 无论是否含网格都要 publish：0 对象时也要把盘列表推给 UI（否则整块不渲染）
    // 导入收尾：把「当前姿态」记为变换基线。之后用户一旦旋转/缩放/移动，切片前就会据此判定
    // 「需要把变换烘进切片输入工程」（否则切出来仍是导入时的原位，见 Index.startSlice）。
    modelState.resetTransformBaseline();
    modelState.publish();
    // 新文档载入完成：重建撤销栈基线并清空历史。
    // 必须做 —— 否则新文档的第一次编辑会把「上一个文档的状态」当成 before，撤销一下会串到旧文档。
    history.reset();

    // ---- 切片输入一致性 ----
    // 切片用的是「导入时的原始文件副本」slice_input.3mf（Index.ets 直接拿 sliceModelPath 去切）。
    // · 单盘文件：**保持原样** —— 不引入多余转换，slice_input 仍是原始副本，行为与之前完全一致。
    // · 多盘文件：预览/编辑里对象已被「显示映射」搬回单板，但那是**显示服务**，切片不得沿用。
    //   切片输入 = 导入时的**原始文件副本**（slice_input.3mf），绝不写回显示用的「映射后单板工程」。
    //   原因：显示映射把各盘叠到同一块板；切片沿用它会多盘互相压叠、直接失败。
    //   多盘切片改由 Index.startSlice 逐盘构建「只含该盘对象」的输入工程（见 ThreeMfExport.build(plate)）。
    const sliceInput: string = mappedAny ? '原始(多盘改为按盘切片)' : '原始';

    // ---- 组装结果 + 发布设置（给面板应用：文件 > 本机持久化）----
    const settings: Import3mfSettings = new Import3mfSettings();
    settings.printer = presetsPrinter;
    settings.process = presetsProcess;
    settings.filament = presetsFilament;
    settings.bed = presetsBed;
    settings.keys = info.settingKeys !== undefined ? info.settingKeys : [];
    settings.values = info.settingValues !== undefined ? info.settingValues : [];
    settings.source = shortName;
    AppStorage.setOrCreate<Import3mfSettings>('importSettings', settings);
    AppStorage.setOrCreate<number>('importSettingsSeq', (AppStorage.get<number>('importSettingsSeq') ?? 0) + 1);

    out.ok = true;
    out.hasModel = count > 0;
    out.objectCount = count;
    out.triangleCount = triTotal;
    out.plateCount = plates.length;
    out.settings = settings;
    out.summary = `机型=${presetsPrinter} 工艺=${presetsProcess} 耗材=${presetsFilament} 板=${presetsBed} ` +
      `层高=${lh} 墙层数=${wl} 首层速度=${ils}`;

    const tail: string =
      `导入3mf 路径=${shortName} 对象=${count} 三角面=${triTotal} 盘=${plates.length} ` +
      `机型=${presetsPrinter} 工艺=${presetsProcess} 耗材=${presetsFilament} 板=${presetsBed} ` +
      `层高=${lh} 墙层数=${wl} 首层速度=${ils} 结果=成功`;
    if (count === 0) {
      // 几何为 0 的情形单独一条：不是失败，而是「包内无网格」，设置仍然读到了
      ThreeMfImport.log(filesDir, tail);
      ThreeMfImport.log(filesDir, `导入3mf 路径=${shortName} 该文件不含模型（包内无网格），仅读取设置`);
      out.message = '该文件不含模型，仅读取设置';
    } else {
      ThreeMfImport.log(filesDir, tail);
    }
    // 多盘总结行：盘数 / 是否已映射到单板 / 切片输入用的是原始还是映射后 / 结果
    if (multiPlate) {
      ThreeMfImport.log(filesDir,
        `导入3mf 盘数=${plates.length} 已映射到单板=${mappedAny ? '是' : '否'} 切片输入=${sliceInput} 结果=成功`);
    }
    return out;
  }

  // 调内核导入（Promise 包装；NAPI 同步抛异常会让 Promise reject，由调用方 catch）
  private static callKernel(path: string): Promise<Import3mfRaw> {
    return new Promise<Import3mfRaw>((resolve: (v: Import3mfRaw) => void) => {
      SlicerService.import3mf(path, (infoJson: string, positions: ArrayBuffer) => {
        const r: Import3mfRaw = new Import3mfRaw();
        r.info = infoJson;
        r.positions = positions;
        resolve(r);
      });
    });
  }

  // 把一段三角汤（Z-up、对象本地坐标）归一化成「XY 居中、底面 z=0」并入库。
  // 归一化是必要的：内核对象本地网格的原点不在底面上（add_volume 会把包围盒中心挪到原点），
  // 而 3D 场景用 transform.position 摆位，必须让几何底面 = 0、XY 中心 = 0。
  // 摆放（instance offset）单独用：世界中心 = offset + 本地中心 → 相对盘面中心的偏移。
  // shiftX/shiftY：多盘映射的整盘平移（单盘恒为 0，见 importFromUri 的映射段）。
  // 返回 modelState id；几何不可用返回 -1。
  private static addOne(sub: Float32Array, meta: ImportObjectMeta, name: string,
                        plate: number, plateName: string, plateBed: string,
                        bedCx: number, bedCy: number, shiftX: number, shiftY: number): number {
    let lo0: number = 1e30, lo1: number = 1e30, lo2: number = 1e30;
    let hi0: number = -1e30, hi1: number = -1e30, hi2: number = -1e30;
    for (let i = 0; i + 2 < sub.length; i += 3) {
      if (sub[i] < lo0) { lo0 = sub[i]; }
      if (sub[i] > hi0) { hi0 = sub[i]; }
      if (sub[i + 1] < lo1) { lo1 = sub[i + 1]; }
      if (sub[i + 1] > hi1) { hi1 = sub[i + 1]; }
      if (sub[i + 2] < lo2) { lo2 = sub[i + 2]; }
      if (sub[i + 2] > hi2) { hi2 = sub[i + 2]; }
    }
    if (!(hi0 > lo0) && !(hi1 > lo1) && !(hi2 > lo2)) {
      return -1;
    }
    // 底面贴板面积（mm²）：与最低点同高（0.05mm 内）的三角形的面积之和。
    // 面积≈0 = 点/尖接触底 → 首层无有效截面 → 内核会报 empty initial layer。
    let contactArea: number = 0;
    const zTol: number = lo2 + 0.05;
    for (let i = 0; i + 8 < sub.length; i += 9) {
      if (sub[i + 2] <= zTol && sub[i + 5] <= zTol && sub[i + 8] <= zTol) {
        const ux: number = sub[i + 3] - sub[i];
        const uy: number = sub[i + 4] - sub[i + 1];
        const vx: number = sub[i + 6] - sub[i];
        const vy: number = sub[i + 7] - sub[i + 1];
        contactArea += 0.5 * Math.abs(ux * vy - uy * vx);
      }
    }
    if (contactArea < ThreeMfImport.THIN_BOTTOM_MM2) {
      ThreeMfImport.thinBottoms.push(name);
      hilog.warn(0x0000, 'Import3mf',
        '底部点/尖接触 件=%{public}s 贴板面积=%{public}smm² → 切片可能报「首层为空」,建议开支撑或切平底部',
        name, `${contactArea.toFixed(3)}`);
    }
    const cx: number = (lo0 + hi0) * 0.5;
    const cy: number = (lo1 + hi1) * 0.5;
    const pos: Float32Array = new Float32Array(sub.length);
    for (let i = 0; i + 2 < sub.length; i += 3) {
      pos[i] = sub[i] - cx;
      pos[i + 1] = sub[i + 1] - cy;
      pos[i + 2] = sub[i + 2] - lo2;
    }

    const g: MeshGeometry = new MeshGeometry();
    // 大网格走扁平 TypedArray：原地做 Z-up → Y-up，直接采用归一化后的缓冲（零额外对象分配）。
    // 不再逐顶点建 Vec3[]（百万面模型会瞬时分配上百 MB 并触发大量 GC，是导入闪退根因）。
    zUpToYUpInPlace(pos);
    g.pos = pos;
    // 大网格跳过法线修复：法线缓冲又是整整一份 Float32Array（192 万面=69MB），
    // 与「去掉复制 + 跳过缩略图」一起才能把百万面模型的峰值压下来（否则 OOM 闪退）。
    const triEst: number = Math.floor(sub.length / 9);
    if (triEst <= 300000) {
      repairNormals(g);
    }

    const size: Vec3 = { x: hi0 - lo0, y: hi1 - lo1, z: hi2 - lo2 };
    const maxDim: number = Math.max(size.x, Math.max(size.y, size.z));
    const triangles: number = meta.triangles > 0 ? meta.triangles : Math.floor(sub.length / 9);
    const id: number = modelState.add(g, maxDim, size, name, '3MF', triangles, plate, plateName);
    const inst: ModelInstance | undefined = modelState.get(id);
    if (inst !== undefined) {
      inst.plateBed = plateBed;
      // 摆放：内核 instance offset 是「对象本地坐标系在盘面上的平移」，
      // 本地中心 (cx,cy) 与底面偏移 (-lo2)... 归一化后底面落在几何 y=0，
      // 所以世界位置 = offset + (cx, cy, lo2)（旋转/缩放已烘进几何）。
      // shiftX/shiftY 再叠加「多盘映射」的整盘平移（单盘为 0）。
      const wx: number = ThreeMfImport.at(meta.offset, 0) + cx + shiftX;
      const wy: number = ThreeMfImport.at(meta.offset, 1) + cy + shiftY;
      const wz: number = ThreeMfImport.at(meta.offset, 2) + lo2;
      // 盘面坐标 → content（Y-up）：X 直通，盘面 Y 映射到 content 的 -Z；
      // Y（高度）= 内核贴板真值（落板 = 0）+ PLATE_LIFT_MM。
      // 内核真值底面恰好与板面同高，会与板面共面 → z-fighting 闪烁；
      // PLATE_LIFT_MM 是「仅为避免共面」的极小抬升（见 ModelState 里的常量说明），不是路径截断。
      inst.transform.position = { x: wx - bedCx, y: wz + PLATE_LIFT_MM, z: -(wy - bedCy) };
      // 「对象颜色」还原：对象 extruder（1 基）→ 本文件耗材槽位色（filament_colour）。
      // 值合法才写入，避免空色覆盖默认外观；这样多色工程存盘后再打开颜色仍在。
      const ex: number = meta.extruder !== undefined && meta.extruder > 0 ? meta.extruder : 0;
      if (ex > 0 && ex <= ThreeMfImport.importColours.length) {
        const col: string = ThreeMfImport.importColours[ex - 1];
        if (col !== undefined && col !== '') {
          inst.displayColor = col;
        }
      }
    }
    ensureThumbnail(id, g);
    return id;
  }

  private static numOf(v: number): number {
    return Number.isFinite(v) ? v : 0;
  }

  // 多盘映射日志用的定点格式化（1 位小数，mm）；非有限值按 0 处理
  private static f1(v: number): string {
    return Number.isFinite(v) ? v.toFixed(1) : '0.0';
  }

  // 安全取数组第 i 项（JSON 反序列化后数组可能缺项/非有限值）
  private static at(a: number[], i: number): number {
    return (a !== undefined && a.length > i && Number.isFinite(a[i])) ? a[i] : 0;
  }

  // 从选择器 URI 还原文件名（去掉查询/片段与扩展名并解码）
  static baseNameOf(uri: string): string {
    let s: string = uri;
    const q: number = s.indexOf('?');
    if (q >= 0) { s = s.substring(0, q); }
    const h: number = s.indexOf('#');
    if (h >= 0) { s = s.substring(0, h); }
    const slash: number = s.lastIndexOf('/');
    let name: string = slash >= 0 ? s.substring(slash + 1) : s;
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      // 解码失败保留原串（不吞异常：hilog 留痕）
      hilog.warn(0x0000, IMPORT3MF_TAG, '文件名解码失败，保留原串: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    const dot: number = name.lastIndexOf('.');
    if (dot > 0) { name = name.substring(0, dot); }
    return name.length > 0 ? name : '模型';
  }

  private static copyTo(srcUri: string, dstPath: string): boolean {
    try {
      const src: fs.File = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      try {
        const dst: fs.File = fs.openSync(dstPath,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.copyFileSync(src.fd, dst.fd);
        } finally {
          fs.closeSync(dst);
        }
      } finally {
        fs.closeSync(src);
      }
      return true;
    } catch (e) {
      hilog.error(0x0000, IMPORT3MF_TAG, '拷贝到沙箱失败 %{public}s: %{public}s', dstPath,
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
      return false;
    }
  }

  // 三通道日志：hilog + 应用内日志（日志页）+ files/diag/gcode_diag.txt（不连设备也能取）
  static log(filesDir: string, text: string): void {
    hilog.info(0x0000, IMPORT3MF_TAG, '%{public}s', text);
    try {
      AppLog.push(`[${IMPORT3MF_TAG}] ${text}`);
      const ok: boolean = AppLog.writeDiagFile(`${filesDir}/diag/gcode_diag.txt`,
        [`[${IMPORT3MF_TAG}] ${text}`]);
      if (!ok) {
        hilog.warn(0x0000, IMPORT3MF_TAG, '诊断文件落盘失败');
      }
    } catch (e) {
      hilog.error(0x0000, IMPORT3MF_TAG, '日志写入异常: %{public}s',
        e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
    }
  }
}
