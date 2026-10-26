import { MeshGeometry, FaceIndex, meshVolume, meshTriCount } from './MeshUtils';
import { ModelFile, PlateMeta } from './Models';
import type { Vec3, Quaternion } from '@kit.ArkGraphics3D';

// 「换盘补偿」的结果：是否真的平移、平移量、以及原 content 盘尺寸（供日志核对）
export class PlateShiftResult {
  applied: boolean = false;
  dx: number = 0;
  dz: number = 0;
  fromW: number = 0;
  fromH: number = 0;
}

// =============================================================================
// 多模型全局状态（模块级单例，跨页面共享）。
// 注意：网格数据量大，必须放单例而非 AppStorage（AppStorage 会序列化导致卡顿）。
// AppStorage 只存轻量元数据（id/name/...）供对象列表渲染。
// =============================================================================

// 预览显示色板：仅用于 3D 预览给"这个对象"着色，与打印耗材 / AMS 槽位映射无关
//（颜色值本身不代表任何耗材色号）。左右两侧（对象列表已不显示颜色）与参数面板共用这一份。
export interface DisplayColorOption {
  name: string;
  hex: string;
}

export const DISPLAY_COLORS: DisplayColorOption[] = [
  { name: '白', hex: '#F2F2F0' },
  { name: '黑', hex: '#1A1A1C' },
  { name: '灰', hex: '#8A8A92' },
  { name: '红', hex: '#D8322B' },
  { name: '橙', hex: '#E8761E' },
  { name: '黄', hex: '#E8C11C' },
  { name: '绿', hex: '#2FA24A' },
  { name: '青', hex: '#1FB6C1' },
  { name: '蓝', hex: '#2A5FD8' },
  { name: '紫', hex: '#7A4FD0' },
  { name: '粉', hex: '#E06BA8' },
  { name: '棕', hex: '#8A5A34' },
];

// 贴板时的极小抬升（mm）：**仅为避免模型底面与打印板面共面导致 z-fighting（闪烁）**。
// 说明（对应「修 3」）：内核贴板真值是 0（底面与板面严格同高），直接照搬会让底面与板面
// 在深度缓冲里互相竞争，出现闪烁/摩尔纹。这里给一个 0.05mm 的 epsilon —— 远小于任何
// 可打印特征（层高 0.1mm 起），视觉不可见，却足以让底面稳定压在板面之上。
// 全工程只用这一个值：导入摆位、旋转后落板、预设取景都引用它，避免各处各写一个数。
export const PLATE_LIFT_MM: number = 0.05;

// =============================================================================
// 实例克隆 / 结构快照（撤销重做、剪贴板、多盘复制、复制的公共底座）
//
// 性能约定（**改代码时不要破坏它**）：`geometry` 与 `faceIndex` 在导入完成后
// **从不原地修改** —— 旋转/缩放/移动只改 transform，复制走本文件的 cloneGeometry。
// 因此「快照」可以只存引用、不深拷贝几何：一帧快照的成本与网格大小无关，
// 这是「50 步撤销栈不吃内存」的前提。若以后确需原地改几何，必须同步改成写时复制。
// 注意：导入阶段确实存在原地改写（`zUpToYUpInPlace`），但它发生在实例入列之前，
// 与上面这条约定不冲突。
// =============================================================================
function cloneGeometry(src: MeshGeometry): MeshGeometry {
  const g: MeshGeometry = new MeshGeometry();
  // 大网格（TypedArray）与程序化小网格（对象数组）两种存储形态都要按原样深拷贝
  if (src.pos !== null) { g.pos = src.pos.slice(); }
  if (src.nrm !== null) { g.nrm = src.nrm.slice(); }
  if (src.idx !== null) { g.idx = src.idx.slice(); }
  g.vertices = src.vertices.slice();
  g.normals = src.normals.slice();
  g.indices = src.indices.slice();
  return g;
}

function cloneTransform(t: ModelTransform, dxMm: number, dyMm: number): ModelTransform {
  return {
    position: { x: t.position.x + dxMm, y: t.position.y + dyMm, z: t.position.z },
    baseRotation: { x: t.baseRotation.x, y: t.baseRotation.y, z: t.baseRotation.z, w: t.baseRotation.w },
    rotX: t.rotX,
    rotY: t.rotY,
    rotZ: t.rotZ,
    scale: { x: t.scale.x, y: t.scale.y, z: t.scale.z },
  };
}

function cloneOverrideBucket(src: Map<string, number> | undefined): Map<string, number> {
  const dst: Map<string, number> = new Map<string, number>();
  if (src !== undefined) {
    src.forEach((v: number, k: string) => {
      dst.set(k, v);
    });
  }
  return dst;
}

// 网格包围盒尺寸（拆分后各部件需要各自的 size/maxDim 供取景/手柄使用）
function meshSizeOf(g: MeshGeometry): Vec3 {
  let minX: number = 1e30;
  let minY: number = 1e30;
  let minZ: number = 1e30;
  let maxX: number = -1e30;
  let maxY: number = -1e30;
  let maxZ: number = -1e30;
  const n: number = g.vertexCount();
  if (g.pos !== null) {
    const p: Float32Array = g.pos;
    for (let i = 0; i < n; i++) {
      const k: number = i * 3;
      const x: number = p[k];
      const y: number = p[k + 1];
      const z: number = p[k + 2];
      if (x < minX) { minX = x; }
      if (x > maxX) { maxX = x; }
      if (y < minY) { minY = y; }
      if (y > maxY) { maxY = y; }
      if (z < minZ) { minZ = z; }
      if (z > maxZ) { maxZ = z; }
    }
  } else {
    for (const v of g.vertices) {
      if (v.x < minX) { minX = v.x; }
      if (v.x > maxX) { maxX = v.x; }
      if (v.y < minY) { minY = v.y; }
      if (v.y > maxY) { maxY = v.y; }
      if (v.z < minZ) { minZ = v.z; }
      if (v.z > maxZ) { maxZ = v.z; }
    }
  }
  if (minX > maxX) {
    return { x: 0, y: 0, z: 0 };
  }
  return { x: maxX - minX, y: maxY - minY, z: maxZ - minZ };
}

// 盘注册表条目：盘列表的「结构来源」。
// 改造前盘列表完全由「对象聚合」派生 —— 没有对象的盘不存在，盘名/床型也只能从对象上汇总，
// 所以「新增空盘 / 删除盘 / 盘改名 / 排序」无处落脚。有注册表后空盘可以存在。
// 兼容性：注册表为空时，publish() 的行为与改造前完全一致（纯对象聚合 + filePlates 兜底）。
export class PlateRec {
  index: number = 1;
  name: string = '';
  bed: string = '';
  sizeW: number = 0; // 0 = 使用机型默认板尺寸
  sizeH: number = 0;
}

// 一帧结构快照（撤销/重做的最小单位）。
// 其中的 instances 是「快照克隆」：标量与 transform 独立，geometry/faceIndex 共享引用。
export interface ModelSnapshot {
  objects: ModelInstance[];
  selectedIds: number[];
  activePlate: number;
  objectOverrides: Map<number, Map<string, number>>;
  plates: PlateRec[];
  filePlates: PlateMeta[];
  nextId: number;
}

// 单个模型的变换（盘面编辑）
// 旋转 = 用户欧拉角（rotX/Y/Z）× 选面基准朝向（baseRotation）
// 选面会写入 baseRotation 并把欧拉角清零；之后调 XYZ 滑杆是叠加，不会重置选面方向
export interface ModelTransform {
  position: Vec3;         // 平移（Y 为抬升高度，落板时自动计算）
  baseRotation: Quaternion; // 选面得到的基准朝向
  rotX: number;            // 用户绕 X 角度（度）
  rotY: number;            // 用户绕 Y 角度（度）
  rotZ: number;            // 用户绕 Z 角度（度）
  scale: Vec3;             // 每轴缩放（1 = 原始大小）；锁定等比时三轴相同
}

// 单个模型实例（含网格 + 元数据 + 变换）
export class ModelInstance {
  id: number = 0;
  name: string = '';
  format: string = '';
  triangles: number = 0;
  geometry: MeshGeometry = new MeshGeometry();
  faceIndex: FaceIndex | null = null; // 面索引（首次选面时惰性构建）
  maxDim: number = 0;             // 原始最大尺寸（取景用）
  size: Vec3 = { x: 0, y: 0, z: 0 }; // 原始三维尺寸（信息展示）
  volumeMm3: number = 0;          // 原始网格实体体积（mm³，显示时按缩放比例换算）
  plate: number = 0;              // 所属盘（1 起；0 = 未分盘）
  plateName: string = '';
  // 所属盘的床型（内核 curr_bed_type 名，如 "Cool Plate"；空 = 未知）。
  // 按对象存的原因：盘床型是文件级设置，但左侧盘列表要按对象聚合出「每盘的床型」，
  // 存到对象上后 publish() 才能无额外状态地汇总出盘列表。
  plateBed: string = '';
  // 预览显示色（hex，如 '#D8322B'）：仅用于 3D 预览着色，与打印耗材 / AMS 无关。
  // 空串表示"用户没设过" -> 预览用默认色，保证打开时不改变原有外观。
  displayColor: string = '';
  // 单喷嘴专属区归属（原始几何口径）：'' = 未触碰任何专属区（中间共用区）；'left'/'right' = 仅落在该侧专属区。
  // 由 3D 预览页按「对象 XY 包围盒 ∩ 专属区矩形」实时判定（板坐标系与专属区同一套映射）。
  // 这是「区域约束」的原始输入，供「耗材→喷嘴」分组计算（见 FilamentGrouping）使用。
  zoneSide: string = '';
  // 是否同时触碰左/右两个专属区（仅 H2D/H2D Pro/H2C 这类双头机型的专属区才可能出现）：
  // true 时复用「超出打印区域」告警并阻止打印（单个对象不得同时占用两侧专属区）。
  // 注意：这与「同色同料槽位被两个对象分别要求左右两侧」是两回事，后者记在 sideError。
  zoneConflict: boolean = false;
  // 对象 Z 方向高度（mm，世界坐标系含缩放/旋转）；用于「高度>320mm 必须右喷」的材料/区域约束判定。
  heightMm: number = 0;
  // 对象使用的耗材预设名（对象级有效值：对象覆盖优先，否则全局）。供「耗材→喷嘴」分组。
  filamentName: string = '';
  // 最终喷嘴侧归属（由「耗材分组 + 区域/高度/材料约束」计算，见 FilamentGrouping.applyToState）。
  // '' = 两侧共用（未定/中性）；'left'/'right' = 只能该侧。打印弹窗据此过滤可选 AMS 槽位。
  nozzleSide: string = '';
  // 双喷嘴冲突原因（非空 = 该对象无法打印，复用「超出打印区域」告警并阻止打印）。
  // 分组身份是「耗材槽位 = 显示色|材料类型」：同材料不同色的对象是不同槽位，可分别归到左右喷嘴，
  // 不算冲突；只有【同色同料】的槽位被同时要求左右两侧（或与材料级限制/高度限制互斥）才是真冲突。
  sideError: string = '';
  // 需求 4：该对象导入时原生侧算出的悬空（朝下）面启发式统计。
  // 为什么按对象存：告警不能只在「导入那一瞬间」判一次 —— 切页回来 / 编辑已有模型时也要能重算，
  // 否则已加载的模型永远不会被评估（=「需求 4 没效果」的一个根因）。
  overhangNeeded: boolean = false;
  overhangRatioPct: number = 0;
  overhangAngleDeg: number = 0;
  overhangAreaPctThr: number = 0;
  transform: ModelTransform = {
    position: { x: 0, y: PLATE_LIFT_MM, z: 0 }, // 默认贴板抬升（见 PLATE_LIFT_MM：仅为防共面闪烁）
    baseRotation: { x: 0, y: 0, z: 0, w: 1 },
    rotX: 0,
    rotY: 0,
    rotZ: 0,
    scale: { x: 1, y: 1, z: 1 },
  };
}

export class ModelState {
  instances: ModelInstance[] = [];
  // 选中集合（第一个 = 主选中）。为什么还保留一个 selectedId：全工程有 20+ 处只关心
  // 「当前那一个对象」（参数面板、操作手柄、缩略图、打印弹窗），改成集合会把它们全拖下水。
  // 所以 selectedId 退化为**派生只读属性**，语义与改造前完全一致（无选中 = -1）。
  selectedIds: number[] = [];
  revision: number = 0; // 结构版本：每次增删改递增，供 3D 视图监听并同步场景节点
  private nextId: number = 1;

  get selectedId(): number {
    return this.selectedIds.length > 0 ? this.selectedIds[0] : -1;
  }

  // 对象级参数覆盖（对象 id -> 参数名 -> 数值）。
  // 为什么放在 ModelState 而不是 SliceParamStore：它本质是**对象状态**，生命周期必须与对象一致 ——
  // 删除要清理、复制要跟随、撤销/重做要一起回滚。放在这里三个问题一次性消失。
  // SliceParamStore 保留同名静态 API 作为门面（对外签名不变），内部转发到本表。
  objectOverrides: Map<number, Map<string, number>> = new Map<number, Map<string, number>>();

  // 盘注册表（结构来源）。空数组 = 沿用「纯对象聚合」的旧行为（见 PlateRec 注释）。
  plates: PlateRec[] = [];

  // 文件级盘状态（盘元数据，与「对象」无关）。
  // 为什么需要它：盘列表原来是**按对象聚合**出来的 —— 0 个对象就没有盘行。
  // 但像 001.gcode.3mf 这类切片产出的包，本身带 <plate> 元数据却没有任何网格，
  // 于是「盘列表为空」与「该文件不含模型，仅读取设置」同时出现，看起来自相矛盾。
  // 这里把内核给的盘元数据独立保存；publish() 在「对象聚合不出盘」时用它兜底，
  // 保证无网格文件也能显示「盘号/床型/（无对象）」。
  // 只由导入路径写入：含网格的文件写空数组（交给对象聚合），无网格文件写文件里的盘。
  filePlates: PlateMeta[] = [];

  // 设置文件级盘状态（导入时调用；传空数组 = 清除）
  setFilePlates(plates: PlateMeta[]): void {
    this.filePlates = plates;
  }

  // 新增模型，返回 id（自动设为选中）；plate/plateName 用于多盘文件分组
  add(g: MeshGeometry, maxDim: number, size: Vec3, name: string, format: string, triangles: number,
    plate: number = 0, plateName: string = ''): number {
    const inst = new ModelInstance();
    inst.id = this.nextId++;
    inst.geometry = g;
    inst.maxDim = maxDim;
    inst.size = size;
    inst.name = name;
    inst.format = format;
    inst.triangles = triangles;
    inst.volumeMm3 = meshVolume(g);
    inst.plate = plate;
    inst.plateName = plateName;
    this.instances.push(inst);
    this.setSelection([inst.id]);
    this.revision++;
    return inst.id;
  }

  // 深拷贝一个实例：几何独立（不共享可写状态），面索引共享（纯派生的只读缓存）。
  // 共用于「复制对象」「剪贴板粘贴」「复制到其它盘」。
  cloneInstance(src: ModelInstance, newId: number, nameSuffix: string, dxMm: number): ModelInstance {
    const inst: ModelInstance = new ModelInstance();
    inst.id = newId;
    inst.name = src.name + nameSuffix;
    inst.format = src.format;
    inst.triangles = src.triangles;
    inst.maxDim = src.maxDim;
    inst.size = { x: src.size.x, y: src.size.y, z: src.size.z };
    inst.volumeMm3 = src.volumeMm3;
    inst.plate = src.plate;
    inst.plateName = src.plateName;
    inst.plateBed = src.plateBed;
    // 副本外观与源一致（颜色按对象存，不共享引用）
    inst.displayColor = src.displayColor;
    // 耗材绑定随对象复制（同一耗材）；区域/高度/分组侧由几何与分组计算重算，不复制。
    inst.filamentName = src.filamentName;
    // 副本几何与源完全相同 → 悬空结论一并带过去，避免副本「凭空消失」告警
    inst.overhangNeeded = src.overhangNeeded;
    inst.overhangRatioPct = src.overhangRatioPct;
    inst.overhangAngleDeg = src.overhangAngleDeg;
    inst.overhangAreaPctThr = src.overhangAreaPctThr;
    inst.geometry = cloneGeometry(src.geometry);
    inst.faceIndex = src.faceIndex;
    inst.transform = cloneTransform(src.transform, dxMm, 0);
    return inst;
  }

  // 副本 X 偏移：按对象自身宽度 + 间隙排开，避免多份副本叠在同一位置。
  // slot = 第几个副本（1 起）。
  private copyOffsetX(src: ModelInstance, slot: number): number {
    const w: number = src.size.x > 0 ? src.size.x : 30;
    return (w + 5) * slot;
  }

  // 复制模型（几何独立深拷贝 + 变换复制 + **对象级参数覆盖跟随**），返回新 id（自动设为选中）
  duplicate(id: number): number {
    const ids: number[] = this.duplicateMany([id], 1);
    return ids.length > 0 ? ids[0] : -1;
  }

  // 一次复制多份（对象列表「复制」、批量复制、剪贴板粘贴共用）：
  //   count = 每份源对象复制几份；plate > 0 时把副本落到指定盘。
  // 偏移按「源对象自身宽度 + 5mm 间隙」逐份排开（不再固定 +30mm —— 多份副本会叠在一起）。
  duplicateMany(ids: number[], count: number = 1, plate: number = -1): number[] {
    const out: number[] = [];
    const n: number = count < 1 ? 1 : count;
    for (const id of ids) {
      const src: ModelInstance | undefined = this.get(id);
      if (src === undefined) {
        continue;
      }
      for (let k = 1; k <= n; k++) {
        const newId: number = this.nextId++;
        const inst: ModelInstance = this.cloneInstance(src, newId, ' 副本', this.copyOffsetX(src, k));
        if (plate > 0) {
          const rec: PlateRec = this.ensurePlate(plate);
          inst.plate = plate;
          inst.plateName = rec.name;
          inst.plateBed = rec.bed;
        }
        this.instances.push(inst);
        // 对象级参数覆盖必须随副本一起走，否则副本会「回到全局参数」
        this.copyObjectOverrides(src.id, newId);
        out.push(newId);
      }
    }
    if (out.length > 0) {
      this.setSelection(out);
      this.revision++;
    }
    return out;
  }

  // 供剪贴板暂存：产生一个与当前状态解耦的实例克隆（标量独立、几何共享引用）。
  // 剪贴板只「记下来」，真正落板时再由 pasteInstance 做几何独立深拷贝。
  copyInstanceForClipboard(id: number): ModelInstance | undefined {
    const src: ModelInstance | undefined = this.get(id);
    if (src === undefined) {
      return undefined;
    }
    return this.snapInstance(src);
  }

  // 把剪贴板里的克隆插入板上（分配新 id、按偏移落位、可选换盘），返回新 id。
  pasteInstance(snap: ModelInstance, nameSuffix: string, dxMm: number, plate: number): number {
    const newId: number = this.nextId++;
    const inst: ModelInstance = this.cloneInstance(snap, newId, nameSuffix, dxMm);
    if (plate > 0) {
      const rec: PlateRec = this.ensurePlate(plate);
      inst.plate = plate;
      inst.plateName = rec.name;
      inst.plateBed = rec.bed;
    }
    this.instances.push(inst);
    this.setSelection([newId]);
    this.revision++;
    return newId;
  }

  // 用「拆分后的多个连通体」替换原对象（拆分到对象）。
  // 各部件沿用原对象的盘/变换/颜色/耗材与对象级参数；原对象删除，选中落到第一个（最大）部件。
  replaceWithSplit(srcId: number, geoms: MeshGeometry[]): number[] {
    const idx: number = this.instances.findIndex((m: ModelInstance) => m.id === srcId);
    if (idx < 0 || geoms.length === 0) {
      return [];
    }
    const src: ModelInstance = this.instances[idx];
    const out: number[] = [];
    for (let i = 0; i < geoms.length; i++) {
      const g: MeshGeometry = geoms[i];
      const inst: ModelInstance = this.cloneInstance(src, this.nextId++, ` 部件${i + 1}`, 0);
      inst.geometry = g;
      inst.triangles = meshTriCount(g);
      inst.volumeMm3 = meshVolume(g);
      inst.size = meshSizeOf(g);
      inst.maxDim = Math.max(inst.size.x, Math.max(inst.size.y, inst.size.z));
      inst.faceIndex = null; // 几何已变：面索引必须重建
      // 几何已变：旧的悬空结论不再成立，清掉避免误报
      inst.overhangNeeded = false;
      inst.overhangRatioPct = 0;
      this.copyObjectOverrides(srcId, inst.id);
      this.instances.push(inst);
      out.push(inst.id);
    }
    this.instances.splice(idx, 1);
    this.objectOverrides.delete(srcId);
    this.setSelection(out.length > 0 ? [out[0]] : []);
    this.revision++;
    return out;
  }

  // 合并多个对象为一个：基准对象保留 id/盘/变换/对象参数，其余对象删除。
  // geom 已由调用方换算到基准对象的局部坐标系。
  replaceWithMerged(baseId: number, otherIds: number[], geom: MeshGeometry): number {
    const idx: number = this.instances.findIndex((m: ModelInstance) => m.id === baseId);
    if (idx < 0) {
      return -1;
    }
    const base: ModelInstance = this.instances[idx];
    const keep: ModelInstance[] = [];
    for (const m of this.instances) {
      if (m.id === baseId) {
        keep.push(m);
      } else if (otherIds.indexOf(m.id) >= 0) {
        this.objectOverrides.delete(m.id);
      } else {
        keep.push(m);
      }
    }
    base.geometry = geom;
    base.triangles = meshTriCount(geom);
    base.volumeMm3 = meshVolume(geom);
    base.size = meshSizeOf(geom);
    base.maxDim = Math.max(base.size.x, Math.max(base.size.y, base.size.z));
    base.faceIndex = null; // 几何已变：面索引必须重建
    base.overhangNeeded = false;
    base.overhangRatioPct = 0;
    this.instances = keep;
    this.setSelection([baseId]);
    this.revision++;
    return baseId;
  }

  remove(id: number): void {
    const idx = this.instances.findIndex((m: ModelInstance) => m.id === id);
    if (idx < 0) {
      return;
    }
    const removed: ModelInstance = this.instances[idx];
    this.instances.splice(idx, 1);
    // 对象级参数覆盖必须随对象一起消失：id 可能被复用（快照还原会回退 nextId），
    // 留着就会把 A 的参数挂到 B 身上 —— 这类错配是静默的，必须在这里掐断。
    this.objectOverrides.delete(id);
    // 删掉的若是（主）选中对象，选中不能悬空（否则面板/操作手柄会指向已删除的 id）。
    // 多选时只把它从集合里摘掉；集合空了再按老规则挑一个（优先同盘剩余对象，
    // 多盘时避免选中跳到一个当前盘看不见的对象），一个不剩则清空为 -1。
    if (this.selectedIds.indexOf(id) >= 0) {
      const rest: number[] = this.selectedIds.filter((sid: number) => sid !== id);
      if (rest.length === 0) {
        let next: ModelInstance | undefined = undefined;
        for (const m of this.instances) {
          if (m.plate === removed.plate) {
            next = m;
          }
        }
        if (next === undefined && this.instances.length > 0) {
          next = this.instances[this.instances.length - 1];
        }
        if (next !== undefined) {
          rest.push(next.id);
        }
      }
      this.selectedIds = rest;
      this.publishSelection();
    }
    this.revision++;
  }

  // ---- 「用户改过模型变换吗」的判定（决定切片输入要不要把变换烘进 3MF，见 Index.startSlice）----
  // 每个实例在**导入收尾那一刻**的变换记一份基线；之后任何旋转/缩放/移动/尺寸/选面都会让它不同。
  // 为什么不在各编辑入口打脏标记：入口有六七处（手柄拖拽、数值输入、贴底面、选面朝下、复制对象、
  // 预设方块），漏一个就会静默失效 —— 表现正是「移动了模型，切出来还是没动过的那个」。
  private tfBase: Map<number, string> = new Map<number, string>();
  private tfCapturePending: boolean = false;
  // 「换盘补偿」：换机型/盘尺寸时，为了保持**绝对床坐标**不变，实例的 content 位置会整体平移。
  // 这份平移不是用户编辑 —— 比较基线时先减掉它，避免「换一次打印机就被当成改过模型 → 触发重烘」。
  private plateShiftX: number = 0;
  private plateShiftZ: number = 0;
  // content 坐标是「相对哪块盘的中心」算出来的（导入时定：单盘=文件热床，多盘=工程机型盘）。
  // 它可能和当前 3D 盘尺寸不同（例如工程自带 A1M 的 3MF 在 X1C 下导入）—— 换盘补偿必须用它做起点，
  // 不能拿“上一次的 plateW”猜，否则会把导入时就已正确的坐标再平一次（真机表现为整体偏 38mm）。
  private contentPlateW: number = 0;
  private contentPlateH: number = 0;

  setContentPlate(w: number, h: number): void {
    this.contentPlateW = w > 0 ? w : 0;
    this.contentPlateH = h > 0 ? h : 0;
  }

  // 盘尺寸变化到 (plateW, plateH)：保持绝对床坐标不变，把实例整体平移。
  //   content_x = 床X − 盘W/2  → dx = (content盘W − 新盘W)/2
  //   content_z = −床Y + 盘H/2 → dz = (新盘H − content盘H)/2
  // 为什么必须这么做：切片输入用的是 3MF 里的**绝对床坐标**（换盘不会自动居中，拓竹亦然），
  // 而 3D 视图用的是「相对盘中心」的 content 坐标。不补这份平移就会出现
  // 「模型在板中心、切片路径却在偏左」的错位。
  syncPlateTo(plateW: number, plateH: number): PlateShiftResult {
    const r: PlateShiftResult = new PlateShiftResult();
    if (this.contentPlateW <= 0 || this.contentPlateH <= 0) {
      // 不知道 content 用哪块盘（极少见：文件没有 bed 信息）→ 直接认作当前盘，不平移
      this.contentPlateW = plateW;
      this.contentPlateH = plateH;
      return r;
    }
    const dx: number = (this.contentPlateW - plateW) * 0.5;
    const dz: number = (plateH - this.contentPlateH) * 0.5;
    r.fromW = this.contentPlateW;
    r.fromH = this.contentPlateH;
    this.contentPlateW = plateW;
    this.contentPlateH = plateH;
    if (Math.abs(dx) < 1e-6 && Math.abs(dz) < 1e-6) {
      return r;
    }
    for (const m of this.instances) {
      m.transform.position.x += dx;
      m.transform.position.z += dz;
    }
    this.plateShiftX += dx;
    this.plateShiftZ += dz;
    this.revision++;
    r.applied = true;
    r.dx = dx;
    r.dz = dz;
    return r;
  }

  // 由导入流程在收尾处调用：清空基线并置「待捕获」—— 下一次 publish() 会把当时在场的实例记为基线。
  // 之后新增的实例（如「复制对象」）不在基线里，会被当作「改过」→ 需要烘入变换
  // （这是正确的：原始文件里没有那个副本）。
  resetTransformBaseline(): void {
    this.tfBase.clear();
    this.tfCapturePending = true;
    // 新基线是在“当前盘面”下拍的 → 换盘补偿归零（归一化后比较的是同一坐标系）
    this.plateShiftX = 0;
    this.plateShiftZ = 0;
  }

  private tfOf(m: ModelInstance): string {
    const t: ModelTransform = m.transform;
    const q: Quaternion = t.baseRotation;
    // 扣掉「换盘补偿」再比较：换机型导致的整体平移不算用户编辑
    const px: number = t.position.x - this.plateShiftX;
    const pz: number = t.position.z - this.plateShiftZ;
    return `${px.toFixed(4)},${t.position.y.toFixed(4)},${pz.toFixed(4)}` +
      `|${q.x.toFixed(5)},${q.y.toFixed(5)},${q.z.toFixed(5)},${q.w.toFixed(5)}` +
      `|${t.rotX.toFixed(3)},${t.rotY.toFixed(3)},${t.rotZ.toFixed(3)}` +
      `|${t.scale.x.toFixed(5)},${t.scale.y.toFixed(5)},${t.scale.z.toFixed(5)}`;
  }

  // 任一实例的当前变换 ≠ 导入基线，或出现了基线里没有的实例 → true。
  // 没有基线时也返回 true：宁可多烘一次（多花一次输入工程构建），也不能切出与「所见」不符的结果。
  transformsEditedSinceLoad(): boolean {
    if (this.tfCapturePending) { return true; }
    for (const m of this.instances) {
      const base: string | undefined = this.tfBase.get(m.id);
      if (base === undefined || base !== this.tfOf(m)) { return true; }
    }
    return false;
  }

  // 把轻量元数据同步到 AppStorage（对象列表 + 选中 id + 结构版本 + 盘列表）
  publish(): void {
    // 导入收尾后的第一次 publish：把当时在场的实例记为变换基线（见 tfBase 说明）。
    // 位置刻意放在这里而不是导入代码里 —— 导入流程会多次 publish，基线必须取「安放完成」那一次。
    if (this.tfCapturePending) {
      this.tfCapturePending = false;
      this.tfBase.clear();
      for (const m of this.instances) { this.tfBase.set(m.id, this.tfOf(m)); }
    }
    const metas: ModelFile[] = this.instances.map((i: ModelInstance): ModelFile => ({
      id: i.id,
      name: i.name,
      format: i.format,
      sizeKB: 0,
      triangles: i.triangles,
      importedAt: '',
      plate: i.plate,
      plateName: i.plateName
    }));
    AppStorage.setOrCreate<ModelFile[]>('modelObjects', metas);

    // 汇总盘信息（只统计已分盘的模型）
    const byIndex: Map<number, PlateMeta> = new Map<number, PlateMeta>();
    for (const i of this.instances) {
      if (i.plate <= 0) {
        continue;
      }
      let m: PlateMeta | undefined = byIndex.get(i.plate);
      if (m === undefined) {
        m = { index: i.plate, name: i.plateName, count: 0, firstId: i.id, bed: i.plateBed, objNames: [] };
        byIndex.set(i.plate, m);
      }
      m.count++;
      // 左侧盘列表要能看出「每盘有哪些对象」：这里如实收集对象名
      m.objNames.push(i.name);
    }
    const plates: PlateMeta[] = [];
    // 盘列表 = 注册表（提供名称/床型/顺序，空盘也能存在）+ 对象聚合（提供数量/对象名）。
    // 注册表为空时结果与改造前**逐字段一致**（纯对象聚合），保证不引入行为回归。
    const merged: Map<number, PlateMeta> = new Map<number, PlateMeta>();
    for (const p of this.plates) {
      if (p.index <= 0) {
        continue;
      }
      merged.set(p.index, { index: p.index, name: p.name, count: 0, firstId: 0, bed: p.bed, objNames: [] });
    }
    byIndex.forEach((m: PlateMeta, k: number) => {
      const reg: PlateMeta | undefined = merged.get(k);
      if (reg === undefined) {
        merged.set(k, m);
      } else {
        reg.count = m.count;
        reg.firstId = m.firstId;
        reg.objNames = m.objNames;
        if (reg.name.length === 0) { reg.name = m.name; }
        if (reg.bed.length === 0) { reg.bed = m.bed; }
      }
    });
    merged.forEach((m: PlateMeta) => {
      plates.push(m);
    });
    plates.sort((a: PlateMeta, b: PlateMeta) => a.index - b.index);
    // 对象聚合不出任何盘（典型的「无网格但有盘元数据」文件，如 001.gcode.3mf）时，
    // 退回文件级盘状态 —— 否则盘列表整块不渲染，与「仅读取设置」的提示互相打架。
    const shown: PlateMeta[] = plates.length > 0 ? plates : this.filePlates;
    AppStorage.setOrCreate<PlateMeta[]>('modelPlates', shown);

    // 无盘时保持 -1（不过滤）；当前盘失效时回到第一个盘
    const cur: number | undefined = AppStorage.get<number>('activePlate');
    if (shown.length === 0) {
      AppStorage.setOrCreate<number>('activePlate', -1);
    } else if (cur === undefined || cur <= 0 || !shown.some((m: PlateMeta) => m.index === cur)) {
      AppStorage.setOrCreate<number>('activePlate', shown[0].index);
    }

    // 选中态（主选中 + 完整集合）与结构版本：视图据此刷新高亮与场景
    this.publishSelection();
    AppStorage.setOrCreate<number>('modelRevision', this.revision);
  }


  get(id: number): ModelInstance | undefined {
    return this.instances.find((m: ModelInstance) => m.id === id);
  }

  getSelected(): ModelInstance | undefined {
    return this.get(this.selectedId);
  }

  select(id: number): void {
    this.setSelection(id >= 0 ? [id] : []);
  }

  // ---- 选中（多选） ----
  // 覆盖式设置选中集合：去重、剔除不存在的 id、保持传入顺序。
  setSelection(ids: number[]): void {
    const next: number[] = [];
    for (const id of ids) {
      if (id >= 0 && next.indexOf(id) < 0 && this.get(id) !== undefined) {
        next.push(id);
      }
    }
    this.selectedIds = next;
    this.publishSelection();
  }

  // 全选（Ctrl+A）：plate <= 0 时选全部；否则只选「该盘 + 未分盘」的对象 —— 
  // 与列表显示、3D 可见性同一口径，避免手柄作用到看不见的对象上。
  // 返回选中数量（供 UI 提示）。
  selectAllOnPlate(plate: number): number {
    const ids: number[] = [];
    for (const inst of this.instances) {
      if (plate <= 0 || inst.plate <= 0 || inst.plate === plate) {
        ids.push(inst.id);
      }
    }
    this.setSelection(ids);
    return ids.length;
  }

  // 多选：把对象加入/移出选中集合（触屏长按、Ctrl 点击用）
  toggle(id: number): void {
    if (this.get(id) === undefined) {
      return;
    }
    if (this.selectedIds.indexOf(id) >= 0) {
      this.selectedIds = this.selectedIds.filter((sid: number) => sid !== id);
    } else {
      this.selectedIds = this.selectedIds.concat([id]);
    }
    this.publishSelection();
  }

  isSelected(id: number): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  selectAll(): void {
    this.setSelection(this.instances.map((m: ModelInstance) => m.id));
  }

  clearSelection(): void {
    this.setSelection([]);
  }

  // 当前全部选中对象（顺序与 instances 一致，保证批量操作的顺序稳定可预期）
  getSelectedAll(): ModelInstance[] {
    const picked: ModelInstance[] = [];
    for (const m of this.instances) {
      if (this.selectedIds.indexOf(m.id) >= 0) {
        picked.push(m);
      }
    }
    return picked;
  }

  // 只把选中态同步到 AppStorage（不重算对象/盘列表）：
  // selectedModelId = 主选中（既有消费方不变）；selectedModelIds = 完整集合（多选高亮/批量操作用）。
  private publishSelection(): void {
    AppStorage.setOrCreate<number>('selectedModelId', this.selectedId);
    AppStorage.setOrCreate<number[]>('selectedModelIds', this.selectedIds);
  }

  // ---- 对象级参数覆盖 ----
  // 返回内部表本身（调用方只读遍历；写入一律走下面的方法，不要就地改）
  getObjectOverrides(): Map<number, Map<string, number>> {
    return this.objectOverrides;
  }

  getObjectOverrideBucket(id: number): Map<string, number> {
    let b: Map<string, number> | undefined = this.objectOverrides.get(id);
    if (b === undefined) {
      b = new Map<string, number>();
      this.objectOverrides.set(id, b);
    }
    return b;
  }

  setObjectOverride(id: number, key: string, value: number): void {
    this.getObjectOverrideBucket(id).set(key, value);
  }

  clearObjectOverride(id: number, key: string): void {
    const b: Map<string, number> | undefined = this.objectOverrides.get(id);
    if (b === undefined) {
      return;
    }
    b.delete(key);
    // 桶空了就整条摘掉，避免快照/持久化里留下一堆空壳
    if (b.size === 0) {
      this.objectOverrides.delete(id);
    }
  }

  // 副本跟随源的覆盖（复制对象时调用）
  copyObjectOverrides(srcId: number, dstId: number): void {
    const b: Map<string, number> | undefined = this.objectOverrides.get(srcId);
    if (b === undefined || b.size === 0) {
      return;
    }
    this.objectOverrides.set(dstId, cloneOverrideBucket(b));
  }

  // 清掉某个对象的全部覆盖（对象级「复位」用）
  clearObjectOverrides(id: number): void {
    this.objectOverrides.delete(id);
  }

  // 清掉全部对象级覆盖（全局「复位」用；对象仍在，只是参数回到各自预设/全局值）
  clearAllObjectOverrides(): void {
    this.objectOverrides.clear();
  }

  // 清空整个文档（「新建工程」用）：对象 / 选择 / 盘注册表 / 文件级盘 / 对象级覆盖 全部归零。
  //
  // 边界说明：**不动全局参数覆盖**（那是 SliceParamStore 的职责）—— 这里保持模型层不反向依赖服务层；
  // 新建工程时由调用方决定要不要一并把参数复位（见 Index.newProject）。
  // 覆盖表用 clear() 而不是换新 Map：面板持有这张表的引用，换实例会让它继续读旧表（同 restore 的坑）。
  clearAll(): void {
    this.instances = [];
    this.selectedIds = [];
    this.plates = [];
    this.filePlates = [];
    this.objectOverrides.clear();
    this.revision++;
  }

  // 是否存在任何**有效**的对象级参数覆盖（有空桶也算「有」，调用方按需再判）。
  // 用途：决定切片输入要不要「烘入」成我们自己生成的 3MF —— 逐对象参数只能写在
  // Metadata/model_settings.config 里，原始导入文件不含它（见 Index.startSlice 的说明）。
  hasObjectOverrides(): boolean {
    let any: boolean = false;
    this.objectOverrides.forEach((bucket: Map<string, number>) => {
      if (bucket.size > 0) { any = true; }
    });
    return any;
  }

  // ---- 盘注册表（多盘管理底座） ----
  // 保证某盘号在注册表里存在；已存在则只补空缺字段（不覆盖已有的名字/床型）
  ensurePlate(index: number, name: string = '', bed: string = ''): PlateRec {
    let rec: PlateRec | undefined = this.plates.find((p: PlateRec) => p.index === index);
    if (rec === undefined) {
      rec = new PlateRec();
      rec.index = index;
      rec.name = name.length > 0 ? name : `打印板 ${index}`;
      rec.bed = bed;
      this.plates.push(rec);
      this.plates.sort((a: PlateRec, b: PlateRec) => a.index - b.index);
      return rec;
    }
    if (rec.name.length === 0 && name.length > 0) { rec.name = name; }
    if (rec.bed.length === 0 && bed.length > 0) { rec.bed = bed; }
    return rec;
  }

  // 下一个可用盘号（注册表与现存对象都要算进去）
  nextPlateIndex(): number {
    let max: number = 0;
    for (const p of this.plates) {
      if (p.index > max) { max = p.index; }
    }
    for (const m of this.instances) {
      if (m.plate > max) { max = m.plate; }
    }
    return max + 1;
  }

  // 现存盘号（注册表 ∪ 对象归属），升序去重
  collectPlateIndexes(): number[] {
    const set: number[] = [];
    for (const p of this.plates) {
      if (p.index > 0 && set.indexOf(p.index) < 0) { set.push(p.index); }
    }
    for (const m of this.instances) {
      if (m.plate > 0 && set.indexOf(m.plate) < 0) { set.push(m.plate); }
    }
    set.sort((a: number, b: number) => a - b);
    return set;
  }

  // 新增空盘，返回新盘号
  addPlate(name: string = ''): number {
    const hadPlates: boolean = this.collectPlateIndexes().length > 0;
    const idx: number = this.nextPlateIndex();
    const rec: PlateRec = this.ensurePlate(idx, name);
    if (!hadPlates) {
      // 首次建盘：把「未分盘」(plate=0) 的对象收编进这块盘。
      // 为什么必须收编：未分盘对象按 isPlateVisible 的规则在**每块盘上都可见**
      //（用于「整个文档还没有盘」的单盘兼容模式）。若建盘后仍留在 0，用户新增第二块盘后
      // 切盘会看到同一批对象，改一块另一块也跟着改 —— 多盘形同虚设。
      for (const m of this.instances) {
        if (m.plate <= 0) {
          m.plate = idx;
          m.plateName = rec.name;
          m.plateBed = rec.bed;
        }
      }
    }
    this.revision++;
    return idx;
  }

  renamePlate(index: number, name: string): void {
    const rec: PlateRec = this.ensurePlate(index);
    rec.name = name;
    // 对象上的盘名是冗余副本（用于无注册表时的兜底聚合），改名时同步刷新
    for (const m of this.instances) {
      if (m.plate === index) { m.plateName = name; }
    }
    this.revision++;
  }

  // 设置盘级床型（内核 enum 名，如 "Cool Plate"；空串 = 跟随全局床型）。
  // 盘是唯一权威：对象上的 plateBed 只是冗余副本（盘列表聚合/3MF 写入用），一起同步。
  setPlateBed(index: number, bed: string): void {
    const rec: PlateRec = this.ensurePlate(index);
    rec.bed = bed;
    for (const m of this.instances) {
      if (m.plate === index) { m.plateBed = bed; }
    }
    this.revision++;
  }

  // 把对象移到指定盘（0 = 移出全部盘，即「未分盘」）
  moveObjectsToPlate(ids: number[], plate: number): void {
    let name: string = '';
    let bed: string = '';
    if (plate > 0) {
      const rec: PlateRec = this.ensurePlate(plate);
      name = rec.name;
      bed = rec.bed;
    }
    for (const id of ids) {
      const m: ModelInstance | undefined = this.get(id);
      if (m === undefined) { continue; }
      m.plate = plate;
      m.plateName = name;
      m.plateBed = bed;
    }
    this.revision++;
  }

  // 删除一个盘。policy：'move' = 盘内对象移到「未分盘」（默认，安全）；'delete' = 盘内对象一并删除。
  removePlate(index: number, policy: string = 'move'): void {
    const ids: number[] = this.instances
      .filter((m: ModelInstance) => m.plate === index)
      .map((m: ModelInstance) => m.id);
    if (policy === 'delete') {
      for (const id of ids) {
        this.remove(id);
      }
    } else {
      this.moveObjectsToPlate(ids, 0);
    }
    this.plates = this.plates.filter((p: PlateRec) => p.index !== index);
    // 盘号是「隐式主键」：删掉中间一个盘后必须把后面的盘号整体前移，否则出现空洞（1,3）
    this.compactPlates();
    this.revision++;
  }

  // 读某个盘的注册表记录（UI 显示盘名/床型用；不存在返回 undefined）
  getPlateRec(index: number): PlateRec | undefined {
    return this.plates.find((p: PlateRec) => p.index === index);
  }

  // 复制一个盘：新盘**紧随其后**（先 remapPlate 把后面的盘号整体 +1 腾位），
  // 并把源盘上的对象原样复制一份落到新盘（位置与源盘一致，不做偏移 —— 是「复制整块盘」，
  // 不是「再放一个对象」，所以副本必须落在与新盘相同的盘面坐标上）。
  // 返回新盘号；失败返回 -1。
  duplicatePlate(index: number): number {
    if (index <= 0) {
      return -1;
    }
    const src: PlateRec = this.ensurePlate(index);
    const srcName: string = src.name;
    const srcBed: string = src.bed;
    const srcW: number = src.sizeW;
    const srcH: number = src.sizeH;
    const newIndex: number = index + 1;
    // 腾位：所有 > index 的盘号 +1（对象/注册表/filePlates 一起走，见 remapPlate 的收口说明）
    this.remapPlate(index, 1);
    const rec: PlateRec = new PlateRec();
    rec.index = newIndex;
    rec.name = `${srcName} 副本`;
    rec.bed = srcBed;
    rec.sizeW = srcW;
    rec.sizeH = srcH;
    this.plates.push(rec);
    this.plates.sort((a: PlateRec, b: PlateRec) => a.index - b.index);
    // 源盘对象（remap 只动了 > index 的盘号，所以源盘对象仍是 plate === index）
    const srcIds: number[] = this.instances
      .filter((m: ModelInstance) => m.plate === index)
      .map((m: ModelInstance) => m.id);
    for (const id of srcIds) {
      const s: ModelInstance | undefined = this.get(id);
      if (s === undefined) { continue; }
      const nid: number = this.nextId++;
      const inst: ModelInstance = this.cloneInstance(s, nid, ' 副本', 0);
      inst.plate = newIndex;
      inst.plateName = rec.name;
      inst.plateBed = rec.bed;
      this.instances.push(inst);
      // 对象级参数覆盖随副本走（否则副本会「回到全局参数」）
      this.copyObjectOverrides(id, nid);
    }
    this.revision++;
    return newIndex;
  }

  // 盘号重映射：把所有 > from 的盘号整体 +delta。
  // **这是盘结构变化的唯一收口** —— 对象只记 plate 编号，任何增删/排序若不重映射，
  // 对象会静默跑到别的盘上（数据不报错、只是盘对不上）。
  remapPlate(from: number, delta: number): void {
    if (delta === 0) {
      return;
    }
    for (const m of this.instances) {
      if (m.plate > from) { m.plate += delta; }
    }
    for (const p of this.plates) {
      if (p.index > from) { p.index += delta; }
    }
    for (const fp of this.filePlates) {
      if (fp.index > from) { fp.index += delta; }
    }
  }

  // 把盘号压成 1..N 连续（删盘后调用），对象与文件级盘同步平移
  private compactPlates(): void {
    const used: number[] = this.collectPlateIndexes();
    for (let i = 0; i < used.length; i++) {
      const oldIdx: number = used[i];
      const newIdx: number = i + 1;
      if (oldIdx === newIdx) { continue; }
      for (const m of this.instances) {
        if (m.plate === oldIdx) { m.plate = newIdx; }
      }
      for (const p of this.plates) {
        if (p.index === oldIdx) { p.index = newIdx; }
      }
      for (const fp of this.filePlates) {
        if (fp.index === oldIdx) { fp.index = newIdx; }
      }
    }
    this.plates.sort((a: PlateRec, b: PlateRec) => a.index - b.index);
  }

  // ---- 结构快照 / 还原（撤销栈的底座；栈与 UI 在 Phase 1 接入）----
  // 快照克隆：标量与 transform 独立、geometry/faceIndex 共享引用（见文件头性能约定）。
  private snapInstance(src: ModelInstance): ModelInstance {
    const inst: ModelInstance = new ModelInstance();
    inst.id = src.id;
    inst.name = src.name;
    inst.format = src.format;
    inst.triangles = src.triangles;
    inst.geometry = src.geometry;
    inst.faceIndex = src.faceIndex;
    inst.maxDim = src.maxDim;
    inst.size = { x: src.size.x, y: src.size.y, z: src.size.z };
    inst.volumeMm3 = src.volumeMm3;
    inst.plate = src.plate;
    inst.plateName = src.plateName;
    inst.plateBed = src.plateBed;
    inst.displayColor = src.displayColor;
    inst.zoneSide = src.zoneSide;
    inst.zoneConflict = src.zoneConflict;
    inst.heightMm = src.heightMm;
    inst.filamentName = src.filamentName;
    inst.nozzleSide = src.nozzleSide;
    inst.sideError = src.sideError;
    inst.overhangNeeded = src.overhangNeeded;
    inst.overhangRatioPct = src.overhangRatioPct;
    inst.overhangAngleDeg = src.overhangAngleDeg;
    inst.overhangAreaPctThr = src.overhangAreaPctThr;
    inst.transform = cloneTransform(src.transform, 0, 0);
    return inst;
  }

  snapshot(): ModelSnapshot {
    const objects: ModelInstance[] = [];
    for (const m of this.instances) {
      objects.push(this.snapInstance(m));
    }
    const ov: Map<number, Map<string, number>> = new Map<number, Map<string, number>>();
    this.objectOverrides.forEach((bucket: Map<string, number>, id: number) => {
      ov.set(id, cloneOverrideBucket(bucket));
    });
    const plates: PlateRec[] = [];
    for (const p of this.plates) {
      const rec: PlateRec = new PlateRec();
      rec.index = p.index;
      rec.name = p.name;
      rec.bed = p.bed;
      rec.sizeW = p.sizeW;
      rec.sizeH = p.sizeH;
      plates.push(rec);
    }
    const fps: PlateMeta[] = this.filePlates.map((fp: PlateMeta): PlateMeta => ({
      index: fp.index,
      name: fp.name,
      count: fp.count,
      firstId: fp.firstId,
      bed: fp.bed,
      objNames: fp.objNames.slice()
    }));
    return {
      objects: objects,
      selectedIds: this.selectedIds.slice(),
      activePlate: AppStorage.get<number>('activePlate') ?? -1,
      objectOverrides: ov,
      plates: plates,
      filePlates: fps,
      nextId: this.nextId,
    };
  }

  // 还原到快照（**不 publish**，由调用方决定何时刷新，避免一次撤销触发多次列表重建）
  restore(snap: ModelSnapshot): void {
    // ⚠️ 关键：必须**克隆**快照里的对象与盘，绝不能把快照的数组直接当活动数组。
    // 活动对象会被后续编辑就地改写（transform.position/rotX/scale…），一旦与快照共享同一批实例，
    // 基线就被同步改掉了 —— 症状正是「撤销/重做跳到莫名其妙的位置，且之后的编辑不再入栈」。
    const live: ModelInstance[] = [];
    for (const o of snap.objects) {
      live.push(this.snapInstance(o));
    }
    this.instances = live;
    this.selectedIds = snap.selectedIds.slice();
    // 覆盖表必须**就地替换内容**、不能整个换掉 Map 实例：
    // DynamicParamsPanel 持有的就是这张表的引用（SliceParamStore.getObjectOverrides()），
    // 换实例会让面板继续读旧表（表现为「撤销后参数面板还显示老覆盖值」）。
    this.objectOverrides.clear();
    snap.objectOverrides.forEach((bucket: Map<string, number>, id: number) => {
      this.objectOverrides.set(id, cloneOverrideBucket(bucket));
    });
    const plates: PlateRec[] = [];
    for (const p of snap.plates) {
      const rec: PlateRec = new PlateRec();
      rec.index = p.index;
      rec.name = p.name;
      rec.bed = p.bed;
      rec.sizeW = p.sizeW;
      rec.sizeH = p.sizeH;
      plates.push(rec);
    }
    this.plates = plates;
    this.filePlates = snap.filePlates.map((fp: PlateMeta): PlateMeta => ({
      index: fp.index,
      name: fp.name,
      count: fp.count,
      firstId: fp.firstId,
      bed: fp.bed,
      objNames: fp.objNames.slice()
    }));
    // nextId 一起回退（否则「撤销掉一次新增」后再新增会跳号）；因为空出的号会被复用，
    // 所以 objectOverrides 必须随快照整体还原，否则覆盖会挂到复用了同一 id 的别的对象上。
    this.nextId = snap.nextId;
    // 当前盘也随快照回落。注意要连同 -1 一起还原（-1 = 显示全部/未分盘），
    // 且撤回到「盘还没建出来」的状态时，若原 activePlate 已不存在必须清掉 ——
    // 否则盘条/对象过滤会一直指着一块不存在的盘（画面看起来像「对象凭空少了」）。
    let ap: number = snap.activePlate;
    if (ap > 0 && plates.findIndex((p: PlateRec) => p.index === ap) < 0) {
      ap = -1;
    }
    AppStorage.setOrCreate<number>('activePlate', ap);
    this.revision++;
  }

  // 设置某个对象的"预览显示色"（hex，空串=恢复默认色）。
  // 只改内存态、按对象存；revision++ 让 3D 预览页的 @Watch 立即重新着色（不重建几何/不重解析网格）。
  // 注意：这里不含任何耗材 / AMS 语义，纯显示用途。
  setDisplayColor(id: number, color: string): void {
    const inst: ModelInstance | undefined = this.get(id);
    if (inst === undefined) {
      return;
    }
    if (inst.displayColor === color) {
      return;
    }
    inst.displayColor = color;
    this.revision++;
  }

  // 按对象写入「区域侧归属 / 两侧冲突 / Z 高度」（由 3D 预览页实时判定后回填，属几何原始口径）。
  // fresh：对象 id -> '' | 'left' | 'right'；conflicts：同时触碰两侧的对象 id 集合；
  // heights：对象 id -> 世界坐标 Z 高度(mm)。
  // 只在真的变化时才 revision++（避免拖拽过程中每次 syncSelection 都触发全场景重扫）；
  // publish()/分组重算 由调用方在返回 true 时执行，让打印弹窗/其他页看到最新归属。
  applyNozzleSides(fresh: Map<number, string>, conflicts: Set<number>, heights: Map<number, number>): boolean {
    let changed: boolean = false;
    for (const inst of this.instances) {
      const s: string = fresh.get(inst.id) ?? '';
      const c: boolean = conflicts.has(inst.id);
      const h: number = heights.get(inst.id) ?? 0;
      if (inst.zoneSide !== s) { inst.zoneSide = s; changed = true; }
      if (inst.zoneConflict !== c) { inst.zoneConflict = c; changed = true; }
      if (Math.abs(inst.heightMm - h) > 0.01) { inst.heightMm = h; changed = true; }
    }
    if (changed) { this.revision++; }
    return changed;
  }

  // 供分组服务回填最终喷嘴侧与冲突原因（不直接 publish，由调用方决定）。
  setGroupSides(objSide: Map<number, string>, objError: Map<number, string>): boolean {
    let changed: boolean = false;
    for (const inst of this.instances) {
      const side: string = objSide.get(inst.id) ?? '';
      const err: string = objError.get(inst.id) ?? '';
      if (inst.nozzleSide !== side) { inst.nozzleSide = side; changed = true; }
      if (inst.sideError !== err) { inst.sideError = err; changed = true; }
    }
    return changed;
  }

  hasModel(): boolean {
    return this.instances.length > 0;
  }

  clear(): void {
    this.instances = [];
    this.selectedIds = [];
    this.filePlates = [];
    // 对象级参数覆盖与盘注册表都是「跟着对象走」的状态，对象清空后必须一起清，
    // 否则下次导入会捡到上一次会话残留的覆盖值（这类残留是静默的、极难排查）。
    this.objectOverrides.clear();
    this.plates = [];
  }
}

export const modelState: ModelState = new ModelState();
