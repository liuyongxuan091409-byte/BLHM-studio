#include "napi/native_api.h"
#include "rawfile/raw_file_manager.h"
#include "bambu_mqtt.hpp"
#include "bambu_discovery.hpp"
#include "bambu_camera.hpp"
#include "bambu_renderer.hpp"
#include "bambu_mesh.hpp"
#include "bambu_ftps.hpp"
// 切片内核对外 API（实现在 libslic3r/libslic3r/ohos_slicer_api.cpp，编进 liblibslic3r.a）
#include "ohos_slicer_api.hpp"
// 只为拼 schema JSON 用（和 bambu_mqtt.cpp 同一份 in-tree nlohmann）
#include "libslic3r/nlohmann/json.hpp"
// 增量字段合并的单元自测（调 真实 applyReport，喂缺字段 JSON 断言不清零）
#include "bambu_state_merge_selftest.hpp"

#include <ace/xcomponent/native_interface_xcomponent.h>

#include <chrono>
#include <cmath>
#include <cstring>
#include <exception>
#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <algorithm>
#include <atomic>
#include <vector>

#include <hilog/log.h>

// =============================================================================
//  Bambu Studio HM —— NAPI 桥接层
//  切片内核 / 打印机通信(MQTT) / 切片参数 schema（数据驱动动态表单）
//  耗时操作走 napi_async_work，不阻塞 UI 主线程。
// =============================================================================

namespace {

// ---- 切片参数元信息表（UI 元信息；「参数是否存在 / 当前值」以内核 config 为准） ----
//
//  这张表只负责「界面该怎么显示」：中文显示名、单位、量程、分组、控件类型。
//  * 哪些参数会出现  -> 由内核 config 快照决定（BuildSchemaJson 里查不到就丢弃），
//    所以内核里不存在的参数不会凭空出现在界面上（不造假项）；
//  * 值            -> 一律取内核快照（枚举取内核下标）；
//  * 枚举候选项    -> 一律取内核 slicerEnumValues()（顺序 = 内核下标），
//    options 只是「同长度的中文标签」，长度对不上时自动退回内核英文名，保证不会错位。
//
// 分组沿用桌面版 Bambu Studio「工艺设置」的页签：质量 / 强度 / 速度 / 支撑 / 多材料 / 其他；
// 桌面版的「高级」是同一页签内的 简易/高级 视图开关（对应这里的 mode 字段），不是独立页签。
//
// type: 0=浮点 1=整数 2=百分比 3=布尔 4=枚举
// mode: 0=简易视图可见 1=仅高级视图可见（与桌面版 简易/高级 对应）
struct ParamMeta {
    const char* key;
    const char* label;
    int type;
    const char* unit;
    double min;
    double max;
    const char* options; // 枚举用，逗号分隔（仅作中文标签，长度必须与内核 enum_values 一致）
    const char* group;
    const char* subgroup;
    double def;          // 兜底默认值（枚举为索引）；内核快照可用时会被真实值覆盖
    int mode;            // 0=简易 1=高级
    const char* tooltip;
};

static const ParamMeta kSchema[] = {
    // ============================== 质量 ==============================
    // 层高
    {"layer_height", "层高", 0, "mm", 0, 10, "", "质量", "层高", 0.16, 0, "每层切片高度，越小越精细耗时越长"},
    {"initial_layer_print_height", "首层层高", 0, "mm", 0, 10, "", "质量", "层高", 0.20, 0, "首层高度，稍厚可提高平台附着力"},
    // 线宽
    {"line_width", "线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.42, 0, "全局默认线宽"},
    {"initial_layer_line_width", "首层线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.42, 0, "首层线宽"},
    {"outer_wall_line_width", "外墙线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.42, 0, "外墙线宽"},
    {"inner_wall_line_width", "内墙线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.45, 0, "内墙线宽"},
    {"top_surface_line_width", "顶面线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.42, 0, "顶面线宽"},
    {"internal_solid_infill_line_width", "内部实心填充线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.45, 0, "内部实心填充线宽"},
    {"sparse_infill_line_width", "稀疏填充线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.45, 0, "稀疏填充线宽"},
    {"support_line_width", "支撑线宽", 0, "mm", 0, 2, "", "质量", "线宽", 0.42, 1, "支撑线宽"},
    // 流量比：内核真实参数 print_flow_ratio（PrintObjectConfig，默认 1.0；min 0.01 / max 2）
    // 注意：filament_flow_ratio 是向量型选项，apply_params 会整项跳过（保留预设值），改它不会生效，
    // 所以这里用对象级的标量 print_flow_ratio。
    {"print_flow_ratio", "对象流量比", 0, "", 0.01, 2, "", "质量", "线宽", 1.0, 0, "挤出流量倍率（1.0=不缩放）；越大壁越粗，越小壁越细"},
    // 接缝
    {"seam_position", "接缝位置", 4, "", 0, 0, "最近,对齐,背面,随机", "质量", "接缝", 1, 0, "外墙起始打印位置"},
    {"seam_gap", "接缝间隙", 2, "%", 0, 100, "", "质量", "接缝", 0, 0, "接缝处留缝比例，0 表示关闭"},
    {"seam_placement_away_from_overhangs", "接缝避开悬垂", 3, "", 0, 0, "", "质量", "接缝", 0, 0, "把接缝尽量放在不悬垂的位置"},
    {"seam_slope_type", "接缝斜坡类型", 4, "", 0, 0, "", "质量", "接缝", 0, 1, "阶梯式接缝的斜坡方式"},
    {"seam_slope_start_height", "接缝斜坡起始高度", 0, "mm", 0, 20, "", "质量", "接缝", 0, 1, "从该高度开始做接缝斜坡"},
    {"seam_slope_entire_loop", "接缝斜坡整圈", 3, "", 0, 0, "", "质量", "接缝", 0, 1, "整圈都做斜坡而不是单点"},
    {"seam_slope_inner_walls", "接缝斜坡内墙", 3, "", 0, 0, "", "质量", "接缝", 0, 1, "内墙也做接缝斜坡"},
    {"seam_slope_min_length", "接缝斜坡最小长度", 0, "mm", 0, 20, "", "质量", "接缝", 0, 1, "斜坡长度下限"},
    {"scarf_angle_threshold", "阶梯接缝触发角度", 1, "°", 0, 90, "", "质量", "接缝", 30, 1, "超过该角度的接缝才做斜坡"},
    // 墙体生成
    {"wall_generator", "墙生成器", 4, "", 0, 0, "经典,Arachne", "质量", "墙体生成", 0, 1, "经典恒宽 / Arachne 变宽"},
    {"wall_transition_length", "墙过渡长度", 2, "%", 0, 300, "", "质量", "墙体生成", 100, 1, "Arachne 墙宽过渡长度"},
    {"wall_transition_filter_deviation", "墙过渡过滤偏差", 2, "%", 0, 100, "", "质量", "墙体生成", 25, 1, "过滤掉过小的墙宽过渡"},
    {"wall_transition_angle", "墙过渡角度", 0, "°", 0, 90, "", "质量", "墙体生成", 10, 1, "触发墙宽过渡的夹角"},
    {"wall_distribution_count", "墙分布数量", 1, "", 0, 10, "", "质量", "墙体生成", 1, 1, "同一位置的墙体分布份数"},
    // 精度
    {"precise_z_height", "精确 Z 高度", 3, "", 0, 0, "", "质量", "精度", 0, 1, "使用精确 Z 高度"},
    {"resolution", "切片分辨率", 0, "mm", 0, 1, "", "质量", "精度", 0.01, 1, "G-code 曲线离散精度"},
    {"enable_arc_fitting", "圆弧拟合", 3, "", 0, 0, "", "质量", "精度", 1, 1, "把圆滑轨迹拟合成 G2/G3"},
    {"smooth_coefficient", "平滑系数", 0, "", 0, 1000, "", "质量", "精度", 150, 1, "BBS 预置的路径平滑系数"},
    {"detect_overhang_wall", "检测悬垂墙", 3, "", 0, 0, "", "质量", "精度", 1, 1, "识别悬垂外墙并单独控制"},
    {"elefant_foot_compensation", "象脚补偿", 0, "mm", -1, 2, "", "质量", "精度", 0.15, 0, "收缩首层底面尺寸，抵消象脚"},
    // 熨烫
    {"ironing_type", "熨烫类型", 4, "", 0, 0, "不熨烫,顶面,最顶面,所有实体层", "质量", "熨烫", 0, 1, "熨烫使平面更光滑"},
    {"ironing_pattern", "熨烫图案", 4, "", 0, 0, "", "质量", "熨烫", 0, 1, "熨烫走线方式"},
    {"ironing_flow", "熨烫流量", 2, "%", 0, 100, "", "质量", "熨烫", 10, 1, "熨烫挤出流量比例"},
    {"ironing_spacing", "熨烫线距", 0, "mm", 0, 10, "", "质量", "熨烫", 0.1, 1, "熨烫走线间距"},
    {"ironing_inset", "熨烫内缩", 0, "mm", 0, 10, "", "质量", "熨烫", 0, 1, "熨烫区域相对轮廓内缩"},
    {"ironing_speed", "熨烫速度", 0, "mm/s", 0, 1000, "", "质量", "熨烫", 20, 1, "熨烫移动速度"},
    {"ironing_direction", "熨烫方向", 0, "°", 0, 360, "", "质量", "熨烫", 0, 1, "熨烫走线角度"},
    // 桥接
    {"bridge_flow", "桥接流量", 0, "", 0, 2, "", "质量", "桥接", 1, 1, "桥接挤出倍率"},
    {"bridge_angle", "桥接角度", 0, "°", 0, 360, "", "质量", "桥接", 0, 1, "桥接走线角度（0=自动）"},
    {"internal_bridge_support_thickness", "内部桥接支撑厚度", 0, "mm", 0, 10, "", "质量", "桥接", 0.5, 1, "内部桥接下方的支撑厚度"},
    {"thick_bridges", "加厚桥接", 3, "", 0, 0, "", "质量", "桥接", 0, 1, "桥接处额外挤出以增强附着力"},
    {"bridge_no_support", "桥接处不生成支撑", 3, "", 0, 0, "", "质量", "桥接", 0, 1, "桥接区域不生成支撑"},
    {"max_bridge_length", "最大桥接长度", 0, "mm", 0, 500, "", "质量", "桥接", 0, 1, "超过该长度的桥接视为悬垂"},
    {"counterbore_hole_bridging", "沉孔桥接", 4, "", 0, 0, "", "质量", "桥接", 0, 1, "沉孔顶部的桥接策略"},
    {"top_one_wall_type", "顶面单墙类型", 4, "", 0, 0, "", "质量", "桥接", 0, 1, "顶面只保留一圈墙时的处理"},
    {"top_area_threshold", "顶面单墙面积阈值", 2, "%", 0, 100, "", "质量", "桥接", 10, 1, "顶面小面积阈值"},

    // ============================== 强度 ==============================
    // 墙体
    {"wall_loops", "壁环数", 1, "", 0, 1000, "", "强度", "墙体", 2, 0, "每层墙体圈数"},
    {"detect_thin_wall", "检查薄壁", 3, "", 0, 0, "", "强度", "墙体", 1, 0, "检测薄壁"},
    {"only_one_wall_first_layer", "首层仅单墙", 3, "", 0, 0, "", "强度", "墙体", 0, 1, "首层只打一圈墙"},
    {"wall_sequence", "墙体顺序", 4, "", 0, 0, "", "强度", "墙体", 0, 1, "内外墙的打印先后"},
    {"is_infill_first", "先填后墙", 3, "", 0, 0, "", "强度", "墙体", 0, 1, "同一层先打印填充再打印外墙"},
    {"ensure_vertical_shell_thickness", "保证竖直外壳厚度", 4, "", 0, 0, "", "强度", "墙体", 0, 1, "自动补足竖直外壳厚度"},
    // 顶部/底部外壳
    {"top_shell_layers", "顶部壳体层数", 1, "", 0, 100, "", "强度", "顶部/底部外壳", 6, 0, "顶部实体层数"},
    {"top_shell_thickness", "顶部壳体厚度", 0, "mm", 0, 100, "", "强度", "顶部/底部外壳", 0.6, 0, "顶部实体最小厚度"},
    {"top_surface_pattern", "顶面图案", 4, "", 0, 0, "", "强度", "顶部/底部外壳", 0, 0, "顶面走线图案"},
    {"top_surface_density", "顶面密度", 2, "%", 0, 100, "", "强度", "顶部/底部外壳", 100, 0, "顶面走线密度"},
    {"top_solid_infill_flow_ratio", "顶面实心填充流量比", 0, "", 0, 5, "", "强度", "顶部/底部外壳", 1, 1, "顶面挤出的流量倍率"},
    {"bottom_shell_layers", "底部壳体层数", 1, "", 0, 100, "", "强度", "顶部/底部外壳", 4, 0, "底部实体层数"},
    {"bottom_shell_thickness", "底部壳体厚度", 0, "mm", 0, 100, "", "强度", "顶部/底部外壳", 0, 0, "底部实体最小厚度（0=按层数）"},
    {"bottom_surface_pattern", "底面图案", 4, "", 0, 0, "", "强度", "顶部/底部外壳", 0, 0, "底面走线图案"},
    {"bottom_surface_density", "底面密度", 2, "%", 0, 100, "", "强度", "顶部/底部外壳", 100, 0, "底面走线密度"},
    {"initial_layer_flow_ratio", "首层流量比", 0, "", 0, 5, "", "强度", "顶部/底部外壳", 1, 1, "首层挤出流量倍率"},
    // 实心填充
    {"internal_solid_infill_pattern", "内部实心填充图案", 4, "", 0, 0, "", "强度", "实心填充", 0, 0, "内部实心填充走线"},
    // 稀疏填充
    {"sparse_infill_density", "稀疏填充密度", 2, "%", 0, 100, "", "强度", "稀疏填充", 20, 0, "内部稀疏填充密度"},
    {"sparse_infill_pattern", "稀疏填充图案", 4, "", 0, 0, "同心圆,锯齿形,网格,直线,立方体,三角形,三六边形,螺旋,蜂窝,自适应立方,对齐直线,3D蜂窝,希尔伯特曲线,阿基米德弦,八角星螺旋,支撑立方,闪电,交叉影线,锯齿,交叉锯齿,锁定锯齿,2D点阵", "强度", "稀疏填充", 2, 0, "稀疏填充线型"},
    {"sparse_infill_anchor", "稀疏填充锚点最小长度", 0, "mm", 0, 1000, "", "强度", "稀疏填充", 400, 1, "填充锚点最小长度（过短则不生成锚点）"},
    {"sparse_infill_anchor_max", "稀疏填充锚点最大长度", 0, "mm", 0, 1000, "", "强度", "稀疏填充", 400, 1, "填充锚点最大长度"},
    {"infill_direction", "填充方向", 0, "°", 0, 360, "", "强度", "稀疏填充", 45, 0, "填充角度"},
    {"infill_wall_overlap", "填充/墙体重叠", 2, "%", 0, 100, "", "强度", "稀疏填充", 15, 0, "填充与墙体的重叠比例"},
    {"infill_combination", "填充组合", 3, "", 0, 0, "", "强度", "稀疏填充", 0, 1, "多行填充合成一条路径"},
    {"infill_shift_step", "填充偏移步长", 0, "mm", 0, 100, "", "强度", "稀疏填充", 0.4, 1, "每层填充的横向偏移"},
    {"infill_rotate_step", "填充旋转步长", 0, "°", 0, 360, "", "强度", "稀疏填充", 0, 1, "每层填充的旋转角度"},
    {"filter_out_gap_fill", "过滤间隙填充", 0, "mm", 0, 10, "", "强度", "稀疏填充", 0, 1, "小于该宽度的间隙不填充"},
    {"fill_multiline", "填充多线", 1, "", 0, 20, "", "强度", "稀疏填充", 1, 1, "每个填充线条包含的线数"},
    {"skeleton_infill_density", "骨架填充密度", 2, "%", 0, 100, "", "强度", "稀疏填充", 0, 1, "内部骨架的填充密度"},
    {"skin_infill_density", "表皮填充密度", 2, "%", 0, 100, "", "强度", "稀疏填充", 0, 1, "表皮层的填充密度"},
    {"skeleton_infill_line_width", "骨架填充线宽", 0, "mm", 0, 2, "", "强度", "稀疏填充", 0.4, 1, "骨架填充线宽"},
    {"skin_infill_line_width", "表皮填充线宽", 0, "mm", 0, 2, "", "强度", "稀疏填充", 0.4, 1, "表皮填充线宽"},
    {"skin_infill_depth", "表皮填充深度", 0, "mm", 0, 20, "", "强度", "稀疏填充", 1, 1, "表皮填充的层深"},
    {"infill_lock_depth", "填充锁定深度", 0, "mm", 0, 20, "", "强度", "稀疏填充", 0, 1, "填充与表皮锁定的深度"},
    {"symmetric_infill_y_axis", "填充 Y 轴对称", 3, "", 0, 0, "", "强度", "稀疏填充", 0, 1, "填充图案沿 Y 轴对称"},
    {"sparse_infill_lattice_angle_1", "点阵填充角度 1", 0, "°", 0, 180, "", "强度", "稀疏填充", 0, 1, "点阵填充第一组角度"},
    {"sparse_infill_lattice_angle_2", "点阵填充角度 2", 0, "°", 0, 180, "", "强度", "稀疏填充", 0, 1, "点阵填充第二组角度"},

    // ============================== 速度 ==============================
    // 首层速度
    {"initial_layer_speed", "首层速度", 0, "mm/s", 0, 1000, "", "速度", "首层速度", 50, 0, "首层打印速度"},
    {"initial_layer_infill_speed", "首层填充速度", 0, "mm/s", 0, 1000, "", "速度", "首层速度", 105, 0, "首层填充速度"},
    // 其他层速度
    {"outer_wall_speed", "外墙速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 200, 0, "外墙速度"},
    {"inner_wall_speed", "内墙速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 300, 0, "内墙速度"},
    {"sparse_infill_speed", "稀疏填充速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 330, 0, "稀疏填充速度"},
    {"internal_solid_infill_speed", "内部实心填充速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 300, 0, "内部实心填充速度"},
    {"top_surface_speed", "顶面速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 200, 0, "顶面速度"},
    {"gap_infill_speed", "间隙填充速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 300, 1, "间隙填充速度"},
    {"support_speed", "支撑速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 150, 0, "支撑打印速度"},
    {"support_interface_speed", "支撑界面速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 80, 0, "支撑界面速度"},
    {"travel_speed", "空驶速度", 0, "mm/s", 1, 1000, "", "速度", "其他层速度", 500, 0, "空驶移动速度"},
    {"travel_speed_z", "空驶速度 Z", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 0, 1, "Z 轴空驶速度（0=取全局空驶速度）"},
    {"vertical_shell_speed", "垂直外壳速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 80, 1, "竖直外壳（薄壁）速度"},
    {"small_perimeter_speed", "小周长速度", 0, "mm/s", 0, 1000, "", "速度", "其他层速度", 50, 1, "小周长处的降速值"},
    {"small_perimeter_threshold", "小周长阈值", 0, "mm", 0, 1000, "", "速度", "其他层速度", 0, 1, "多长以下视为小周长"},
    // 悬垂降速
    {"bridge_speed", "桥接速度", 0, "mm/s", 0, 1000, "", "速度", "悬垂降速", 25, 0, "桥接速度"},
    {"enable_overhang_speed", "启用悬垂降速", 3, "", 0, 0, "", "速度", "悬垂降速", 1, 0, "按悬垂比例自动降速"},
    {"overhang_totally_speed", "完全悬垂速度", 0, "mm/s", 0, 1000, "", "速度", "悬垂降速", 10, 1, "100% 悬垂时的速度"},
    {"overhang_1_4_speed", "悬垂 1/4 速度", 0, "mm/s", 0, 1000, "", "速度", "悬垂降速", 60, 1, "悬垂比例 0-25% 的速度"},
    {"overhang_2_4_speed", "悬垂 2/4 速度", 0, "mm/s", 0, 1000, "", "速度", "悬垂降速", 30, 1, "悬垂比例 25-50% 的速度"},
    {"overhang_3_4_speed", "悬垂 3/4 速度", 0, "mm/s", 0, 1000, "", "速度", "悬垂降速", 10, 1, "悬垂比例 50-75% 的速度"},
    {"overhang_4_4_speed", "悬垂 4/4 速度", 0, "mm/s", 0, 1000, "", "速度", "悬垂降速", 10, 1, "悬垂比例 75-100% 的速度"},
    {"enable_height_slowdown", "启用高度降速", 3, "", 0, 0, "", "速度", "悬垂降速", 0, 1, "按打印高度分段降速"},
    {"slowdown_start_height", "降速起始高度", 0, "mm", 0, 1000, "", "速度", "悬垂降速", 0, 1, "从该高度开始降速"},
    {"slowdown_start_speed", "降速起始速度", 0, "mm/s", 0, 2000, "", "速度", "悬垂降速", 1000, 1, "降速段的起始速度"},
    {"slowdown_start_acc", "降速起始加速度", 0, "mm/s²", 0, 200000, "", "速度", "悬垂降速", 100000, 1, "降速段的起始加速度"},
    {"slowdown_end_height", "降速结束高度", 0, "mm", 0, 1000, "", "速度", "悬垂降速", 400, 1, "到该高度降速结束"},
    {"slowdown_end_speed", "降速结束速度", 0, "mm/s", 0, 2000, "", "速度", "悬垂降速", 1000, 1, "降速段的结束速度"},
    {"slowdown_end_acc", "降速结束加速度", 0, "mm/s²", 0, 200000, "", "速度", "悬垂降速", 100000, 1, "降速段的结束加速度"},
    // 加速度
    {"default_acceleration", "默认加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 10000, 0, "通用打印加速度"},
    {"outer_wall_acceleration", "外墙加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 5000, 0, "外墙加速度"},
    {"inner_wall_acceleration", "内墙加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 0, 1, "内墙加速度（0=用默认）"},
    {"top_surface_acceleration", "顶面加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 2000, 0, "顶面加速度"},
    {"initial_layer_acceleration", "首层加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 500, 0, "首层加速度"},
    {"initial_layer_travel_acceleration", "首层空驶加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 6000, 1, "首层空驶加速度"},
    {"travel_acceleration", "空驶加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 10000, 0, "空驶移动加速度"},
    {"travel_short_distance_acceleration", "短距空驶加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 250, 1, "短距离移动的加速度"},
    {"sparse_infill_acceleration", "稀疏填充加速度", 0, "mm/s²", 0, 200000, "", "速度", "加速度", 100, 1, "稀疏填充加速度"},
    {"accel_to_decel_enable", "启用加减速控制", 3, "", 0, 0, "", "速度", "加速度", 0, 1, "按比例限制减速度"},
    {"accel_to_decel_factor", "加减速比例", 2, "%", 0, 100, "", "速度", "加速度", 50, 1, "减速度 = 加速度 × 该比例"},
    // 抖动
    {"default_jerk", "默认抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 9, 1, "通用 Jerk"},
    {"outer_wall_jerk", "外墙抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 9, 1, "外墙 Jerk"},
    {"inner_wall_jerk", "内墙抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 9, 1, "内墙 Jerk"},
    {"infill_jerk", "填充抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 9, 1, "填充 Jerk"},
    {"top_surface_jerk", "顶面抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 9, 1, "顶面 Jerk"},
    {"initial_layer_jerk", "首层抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 9, 1, "首层 Jerk"},
    {"travel_jerk", "空驶抖动", 0, "mm/s", 0, 100, "", "速度", "抖动", 12, 1, "空驶 Jerk"},
    // 冷却
    {"slow_down_layer_time", "层冷却时间", 1, "s", 0, 1000, "", "速度", "冷却", 8, 1, "单层最短打印时间（冷却）"},
    {"slow_down_for_layer_cooling", "层冷却降速", 3, "", 0, 0, "", "速度", "冷却", 1, 1, "为满足层冷却时间而自动降速"},
    {"cooling_slowdown_logic", "冷却降速逻辑", 4, "", 0, 0, "", "速度", "冷却", 0, 1, "冷却降速的判定范围"},
    {"cooling_perimeter_transition_distance", "冷却过渡距离", 0, "mm", 0, 100, "", "速度", "冷却", 10, 1, "周长冷却过渡距离"},
    {"full_fan_speed_layer", "全风扇速度层", 1, "", 0, 100, "", "速度", "冷却", 0, 1, "从该层开始全速风扇"},
    {"reduce_fan_stop_start_freq", "减少风扇启停", 3, "", 0, 0, "", "速度", "冷却", 0, 1, "减少风扇频繁启停"},
    {"close_fan_the_first_x_layers", "关闭风扇的前若干层", 1, "", 0, 100, "", "速度", "冷却", 1, 1, "前 N 层关闭部件风扇"},
    {"first_x_layer_fan_speed", "前若干层风扇速度", 0, "%", 0, 100, "", "速度", "冷却", 100, 1, "前 N 层的风扇速度"},
    {"fan_max_speed", "风扇最大速度", 1, "%", 0, 100, "", "速度", "冷却", 100, 1, "部件风扇最大转速"},
    {"fan_min_speed", "风扇最小速度", 1, "%", 0, 100, "", "速度", "冷却", 70, 1, "部件风扇最小转速"},
    {"fan_cooling_layer_time", "风扇冷却层时间", 1, "s", 0, 1000, "", "速度", "冷却", 4, 1, "低于该层时间则全速风扇"},
    {"enable_overhang_bridge_fan", "启用悬垂桥接风扇", 3, "", 0, 0, "", "速度", "冷却", 1, 1, "悬垂/桥接处加强散热"},
    {"overhang_fan_speed", "悬垂风扇速度", 1, "%", 0, 100, "", "速度", "冷却", 100, 1, "悬垂处的风扇速度"},
    {"overhang_fan_threshold", "悬垂风扇触发阈值", 4, "", 0, 0, "", "速度", "冷却", 0, 1, "超过该悬垂比例才加强散热"},

    // ============================== 支撑 ==============================
    // 支撑
    {"enable_support", "开启支撑", 3, "", 0, 0, "", "支撑", "支撑", 0, 0, "是否生成支撑"},
    {"support_type", "支撑类型", 4, "", 0, 0, "普通(自动),树状(自动),普通(手动),树状(手动)", "支撑", "支撑", 1, 0, "支撑类型"},
    {"support_style", "支撑样式", 4, "", 0, 0, "", "支撑", "支撑", 0, 0, "支撑生成风格"},
    {"support_threshold_angle", "支撑阈值角度", 1, "°", 0, 90, "", "支撑", "支撑", 30, 0, "低于该角度的悬垂生成支撑"},
    {"support_angle", "支撑叠加角度", 0, "°", 0, 90, "", "支撑", "支撑", 0, 1, "支撑头顶部叠加角度"},
    {"support_on_build_plate_only", "仅在打印板上生成支撑", 3, "", 0, 0, "", "支撑", "支撑", 0, 0, "支撑仅在打印板生成"},
    {"support_critical_regions_only", "仅关键区域生成支撑", 3, "", 0, 0, "", "支撑", "支撑", 0, 1, "只在关键悬垂处生成支撑"},
    {"support_remove_small_overhang", "移除小悬垂支撑", 3, "", 0, 0, "", "支撑", "支撑", 1, 1, "小面积悬垂不生成支撑"},
    {"support_expansion", "支撑扩展", 0, "mm", -10, 10, "", "支撑", "支撑", 0, 0, "支撑水平扩展量"},
    {"support_fast_purge_mode", "支撑快速冲刷", 3, "", 0, 0, "", "支撑", "支撑", 1, 1, "换支撑材料时快速冲刷"},
    {"independent_support_layer_height", "独立支撑层高", 3, "", 0, 0, "", "支撑", "支撑", 1, 1, "支撑使用独立层高"},
    {"support_object_skip_flush", "支撑对象跳过冲刷", 3, "", 0, 0, "", "支撑", "支撑", 0, 1, "支撑对象不参与换料冲刷"},
    // 可分离支撑
    {"support_object_xy_distance", "支撑/模型 XY 间距", 0, "mm", 0, 10, "", "支撑", "可分离支撑", 0.35, 0, "支撑与模型水平间距"},
    {"support_object_first_layer_gap", "支撑首层间隙", 0, "mm", 0, 10, "", "支撑", "可分离支撑", 0.2, 1, "支撑与模型在首层的间隙"},
    {"support_top_z_distance", "支撑顶部 Z 距离", 0, "mm", 0, 10, "", "支撑", "可分离支撑", 0.16, 0, "支撑顶部与模型间距"},
    {"support_bottom_z_distance", "支撑底部 Z 距离", 0, "mm", 0, 10, "", "支撑", "可分离支撑", 0.16, 0, "支撑底部与模型间距"},
    {"support_base_pattern", "支撑底图案", 4, "", 0, 0, "", "支撑", "可分离支撑", 0, 0, "支撑主体填充图案"},
    {"support_base_pattern_spacing", "支撑底图案间距", 0, "mm", 0, 20, "", "支撑", "可分离支撑", 2.5, 0, "支撑主体填充间距"},
    // 支撑界面
    {"support_interface_top_layers", "支撑界面顶层数", 1, "", 0, 20, "", "支撑", "支撑界面", 2, 0, "支撑顶面致密层数"},
    {"support_interface_bottom_layers", "支撑界面底层数", 1, "", -1, 20, "", "支撑", "支撑界面", 0, 1, "支撑底面致密层数（-1=同顶层）"},
    {"support_interface_spacing", "支撑界面间距", 0, "mm", 0, 20, "", "支撑", "支撑界面", 0, 0, "支撑界面走线间距"},
    {"support_bottom_interface_spacing", "支撑底部界面间距", 0, "mm", 0, 20, "", "支撑", "支撑界面", 0.5, 1, "支撑底部界面走线间距"},
    {"support_interface_pattern", "支撑界面图案", 4, "", 0, 0, "", "支撑", "支撑界面", 0, 0, "支撑界面走线图案"},
    {"support_interface_loop_pattern", "支撑界面环状图案", 3, "", 0, 0, "", "支撑", "支撑界面", 0, 1, "支撑界面生成环状路径"},
    {"support_interface_not_for_body", "支撑界面不贴主体", 3, "", 0, 0, "", "支撑", "支撑界面", 1, 1, "支撑界面不生成在模型下方"},
    {"enable_support_ironing", "启用支撑熨烫", 3, "", 0, 0, "", "支撑", "支撑界面", 0, 1, "对支撑界面做熨烫"},
    {"support_ironing_pattern", "支撑熨烫图案", 4, "", 0, 0, "", "支撑", "支撑界面", 0, 1, "支撑熨烫走线方式"},
    {"support_ironing_flow", "支撑熨烫流量", 2, "%", 0, 100, "", "支撑", "支撑界面", 10, 1, "支撑熨烫挤出流量比例"},
    {"support_ironing_spacing", "支撑熨烫线距", 0, "mm", 0, 20, "", "支撑", "支撑界面", 0.1, 1, "支撑熨烫走线间距"},
    {"support_ironing_inset", "支撑熨烫内缩", 0, "mm", 0, 20, "", "支撑", "支撑界面", 0, 1, "支撑熨烫区域内缩"},
    {"support_ironing_speed", "支撑熨烫速度", 0, "mm/s", 0, 1000, "", "支撑", "支撑界面", 20, 1, "支撑熨烫速度"},
    {"support_ironing_direction", "支撑熨烫方向", 0, "°", 0, 360, "", "支撑", "支撑界面", 0, 1, "支撑熨烫走线角度"},
    // 树状支撑
    {"tree_support_branch_angle", "树状支撑分支角度", 0, "°", 0, 90, "", "支撑", "树状支撑", 40, 1, "树状支撑分支最大夹角"},
    {"tree_support_branch_distance", "树状支撑分支间距", 0, "mm", 0, 100, "", "支撑", "树状支撑", 5, 1, "树枝分叉间距"},
    {"tree_support_branch_diameter", "树状支撑分支直径", 0, "mm", 0, 100, "", "支撑", "树状支撑", 2, 1, "树枝直径"},
    {"tree_support_branch_diameter_angle", "树状支撑分支直径变化角", 0, "°", 0, 90, "", "支撑", "树状支撑", 5, 1, "树枝直径随高度变化的角度"},
    {"tree_support_wall_count", "树状支撑墙数", 1, "", 0, 10, "", "支撑", "树状支撑", 0, 1, "树枝外壳圈数"},
    // 裙边/筏
    {"brim_type", "裙边类型", 4, "", 0, 0, "自动,涂色,仅外侧,仅内侧,内外都有,无裙边", "支撑", "裙边/筏", 0, 0, "裙边生成方式"},
    {"brim_width", "裙边宽度", 0, "mm", 0, 100, "", "支撑", "裙边/筏", 5, 0, "裙边宽度"},
    {"brim_object_gap", "裙边/模型间距", 0, "mm", 0, 10, "", "支撑", "裙边/筏", 0.1, 0, "裙边与模型的距离"},
    {"raft_layers", "筏层数", 1, "", 0, 100, "", "支撑", "裙边/筏", 0, 1, "底座筏层数量"},
    {"raft_first_layer_density", "筏首层密度", 2, "%", 0, 100, "", "支撑", "裙边/筏", 90, 1, "筏首层填充密度"},
    {"raft_first_layer_expansion", "筏首层扩展", 0, "mm", 0, 100, "", "支撑", "裙边/筏", 2, 1, "筏首层相对模型的扩展"},
    {"raft_contact_distance", "筏接触距离", 0, "mm", 0, 10, "", "支撑", "裙边/筏", 0.1, 1, "筏与模型的 Z 间距"},
    {"raft_expansion", "筏扩展", 0, "mm", 0, 10, "", "支撑", "裙边/筏", 1.5, 1, "筏相对模型的水平扩展"},

    // ============================== 多材料 ==============================
    // 擦拭塔
    {"enable_prime_tower", "启用擦拭塔", 3, "", 0, 0, "", "多材料", "擦拭塔", 1, 0, "多材料换料时生成擦拭塔"},
    {"prime_tower_width", "擦拭塔宽度", 0, "mm", 0, 200, "", "多材料", "擦拭塔", 35, 0, "擦拭塔边长"},
    {"prime_tower_brim_width", "擦拭塔裙边宽度", 0, "mm", 0, 100, "", "多材料", "擦拭塔", 3, 0, "擦拭塔底部裙边宽度"},
    {"wipe_tower_rotation_angle", "擦拭塔旋转角度", 0, "°", 0, 360, "", "多材料", "擦拭塔", 0, 0, "擦拭塔相对打印板旋转角度"},
    {"prime_tower_max_speed", "擦拭塔最大速度", 0, "mm/s", 0, 1000, "", "多材料", "擦拭塔", 90, 1, "擦拭塔打印速度上限"},
    {"prime_tower_lift_height", "擦拭塔抬升高度", 0, "mm", 0, 100, "", "多材料", "擦拭塔", 0, 1, "换料时抬升高度"},
    {"prime_tower_lift_speed", "擦拭塔抬升速度", 0, "mm/s", 0, 1000, "", "多材料", "擦拭塔", 90, 1, "抬升动作速度"},
    {"prime_tower_skip_points", "擦拭塔跳过点位", 3, "", 0, 0, "", "多材料", "擦拭塔", 1, 1, "跳过擦拭塔上的泊料点位"},
    {"prime_tower_rib_wall", "擦拭塔加肋外墙", 3, "", 0, 0, "", "多材料", "擦拭塔", 1, 1, "擦拭塔外墙加肋提高强度"},
    {"prime_tower_rib_width", "擦拭塔肋宽", 0, "mm", 0, 100, "", "多材料", "擦拭塔", 5, 1, "外墙肋的宽度"},
    {"prime_tower_infill_gap", "擦拭塔填充间隙", 2, "%", 0, 100, "", "多材料", "擦拭塔", 50, 1, "擦拭塔内部填充间隙"},
    {"wipe_tower_no_sparse_layers", "稀疏层不生成擦拭塔", 3, "", 0, 0, "", "多材料", "擦拭塔", 0, 1, "稀疏层跳过擦拭塔"},
    {"enable_tower_interface_features", "启用擦拭塔界面特性", 3, "", 0, 0, "", "多材料", "擦拭塔", 0, 1, "料塔界面层使用专用参数"},
    // 换料/冲刷
    {"ooze_prevention", "防溢料", 3, "", 0, 0, "", "多材料", "换料/冲刷", 0, 0, "换料前降温防溢料"},
    {"standby_temperature_delta", "待机温度差", 1, "°C", -200, 200, "", "多材料", "换料/冲刷", -5, 0, "待机时相对打印温度的差值"},
    {"filament_flush_volumetric_speed", "冲刷体积速度", 0, "mm³/s", 0, 200, "", "多材料", "换料/冲刷", 0, 1, "换料冲刷的最大体积速度"},
    {"filament_flush_temp", "冲刷温度", 1, "°C", 0, 350, "", "多材料", "换料/冲刷", 0, 1, "冲刷时的喷嘴温度"},
    {"filament_minimal_purge_on_wipe_tower", "擦拭塔最小冲刷量", 0, "mm³", 0, 1000, "", "多材料", "换料/冲刷", 15, 0, "换料时最小冲刷体积"},
    {"filament_ramming_volumetric_speed", "回抽体积速度", 0, "mm³/s", 0, 200, "", "多材料", "换料/冲刷", 0.4, 1, "换料回抽体积速度"},
    {"filament_prime_volume", "填充体积", 0, "mm³", 0, 1000, "", "多材料", "换料/冲刷", 0, 1, "换料时额外填充体积"},

    // ============================== 其他 ==============================
    {"print_sequence", "打印顺序", 4, "", 0, 0, "逐层,按对象", "其他", "其他", 0, 0, "打印顺序"},
    {"spiral_mode", "螺旋花瓶模式", 3, "", 0, 0, "", "其他", "其他", 0, 0, "螺旋花瓶模式"},
    {"spiral_mode_smooth", "螺旋花瓶平滑", 3, "", 0, 0, "", "其他", "其他", 0, 1, "平滑螺旋上升的 Z"},
    {"spiral_mode_max_xy_smoothing", "螺旋花瓶最大 XY 平滑", 0, "%", 0, 100, "", "其他", "其他", 0, 1, "XY 方向最大平滑比例"},
    {"reduce_crossing_wall", "避免跨越外墙", 3, "", 0, 0, "", "其他", "其他", 0, 1, "空驶路径尽量不穿过外墙"},
    {"max_travel_detour_distance", "最大绕行距离", 0, "mm", 0, 1000, "", "其他", "其他", 0, 1, "为避免跨越外墙允许的最大绕行"},
    {"exclude_object", "排除对象", 3, "", 0, 0, "", "其他", "其他", 1, 1, "在 G-code 中输出可排除对象标记"},
    {"silent_mode", "静音模式", 3, "", 0, 0, "", "其他", "其他", 0, 1, "降低机器运行噪音"},
    {"auxiliary_fan", "辅助风扇", 3, "", 0, 0, "", "其他", "其他", 0, 0, "启用辅助风扇"},
    {"activate_air_filtration", "启用空气过滤", 3, "", 0, 0, "", "其他", "其他", 0, 0, "打印时开启腔体空气过滤"},
    {"during_print_exhaust_fan_speed", "打印期间排气扇速度", 1, "%", 0, 100, "", "其他", "其他", 100, 1, "打印期间排气风扇转速"},
    {"complete_print_exhaust_fan_speed", "打印完成排气扇速度", 1, "%", 0, 100, "", "其他", "其他", 100, 1, "打印结束后的排气风扇转速"},
    {"support_chamber_temp_control", "腔温控制", 3, "", 0, 0, "", "其他", "其他", 0, 1, "按耗材要求控制腔体温度"},
    {"chamber_temperatures", "腔体温度", 1, "°C", 0, 100, "", "其他", "其他", 0, 1, "目标腔体温度"},
    // 温度
    {"nozzle_temperature", "喷嘴温度", 1, "°C", 0, 350, "", "其他", "温度", 220, 0, "其余层的喷嘴温度"},
    {"nozzle_temperature_initial_layer", "首层喷嘴温度", 1, "°C", 0, 350, "", "其他", "温度", 220, 0, "首层喷嘴温度"},
    {"nozzle_temperature_range_low", "喷嘴温度下限", 1, "°C", 0, 350, "", "其他", "温度", 190, 1, "耗材允许的最低喷嘴温度"},
    {"nozzle_temperature_range_high", "喷嘴温度上限", 1, "°C", 0, 350, "", "其他", "温度", 240, 1, "耗材允许的最高喷嘴温度"},
    {"hot_plate_temp", "热床温度（高温板）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "高温打印板的目标床温"},
    {"hot_plate_temp_initial_layer", "首层床温（高温板）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "高温打印板的首层床温"},
    {"textured_plate_temp", "热床温度（纹理 PEI）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "纹理 PEI 板的目标床温"},
    {"textured_plate_temp_initial_layer", "首层床温（纹理 PEI）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "纹理 PEI 板的首层床温"},
    // 其余三套床温必须与 hot/textured 一并存在：内核 config 里是四套独立向量，curr_bed_type
    // 选哪套就只读哪套。缺了它们会连带两个可见问题：
    //   ① 参数面板「打印板」右侧的床温摘要（bedTempText）对工程材料/低温/SuperTack 板恒为空；
    //   ② 耗材编辑里改这几套床温后，面板叠不到对应参数项上（表现为"还是出厂预设温度"）。
    {"eng_plate_temp", "热床温度（工程材料板）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "工程材料打印板的目标床温"},
    {"eng_plate_temp_initial_layer", "首层床温（工程材料板）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "工程材料打印板的首层床温"},
    {"cool_plate_temp", "热床温度（低温板）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "低温打印板的目标床温"},
    {"cool_plate_temp_initial_layer", "首层床温（低温板）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "低温打印板的首层床温"},
    {"supertack_plate_temp", "热床温度（SuperTack）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "SuperTack 打印板的目标床温"},
    {"supertack_plate_temp_initial_layer", "首层床温（SuperTack）", 1, "°C", 0, 200, "", "其他", "温度", 60, 0, "SuperTack 打印板的首层床温"},
    // 绒毛表面
    {"fuzzy_skin", "绒毛表面", 4, "", 0, 0, "无(允许绘制),轮廓,轮廓和孔,所有壁,已禁用", "其他", "绒毛表面", 0, 0, "绒毛表面效果"},
    {"fuzzy_skin_thickness", "绒毛表面厚度", 0, "mm", 0, 5, "", "其他", "绒毛表面", 0.3, 0, "绒毛表面抖动厚度"},
    {"fuzzy_skin_point_distance", "绒毛表面点间距", 0, "mm", 0, 5, "", "其他", "绒毛表面", 0.8, 0, "绒毛表面点间距"},
    {"fuzzy_skin_first_layer", "首层绒毛表面", 3, "", 0, 0, "", "其他", "绒毛表面", 0, 1, "首层也应用绒毛表面"},
    {"fuzzy_skin_noise_type", "绒毛表面噪声类型", 4, "", 0, 0, "", "其他", "绒毛表面", 0, 1, "绒毛表面噪声算法"},
    {"fuzzy_skin_scale", "绒毛表面缩放", 0, "", 0, 10, "", "其他", "绒毛表面", 1, 1, "噪声缩放系数"},
    {"fuzzy_skin_octaves", "绒毛表面八度", 1, "", 0, 10, "", "其他", "绒毛表面", 4, 1, "噪声叠加层数"},
    {"fuzzy_skin_persistence", "绒毛表面持续度", 0, "", 0, 1, "", "其他", "绒毛表面", 0.5, 1, "噪声持续度"},
    // G-code
    {"gcode_add_line_number", "G-code 添加行号", 3, "", 0, 0, "", "其他", "G-code", 0, 1, "在 G-code 中输出行号"},
    {"scan_first_layer", "首层扫描检测", 3, "", 0, 0, "", "其他", "G-code", 0, 1, "首层完成后扫描检测"},
    {"print_in_clockwise", "顺时针打印", 3, "", 0, 0, "", "其他", "G-code", 0, 1, "轮廓按顺时针方向打印"},

    // 打印板类型（curr_bed_type）：由面板顶部「打印板」下拉承载，它的 group 不进 tab 列表，
    // 但必须留在参数流里 —— 它直接决定首层温度，collectParamsJson 要带上。
    // 选项顺序必须对齐内核 PrintConfigDef 的 enum_values（第 5 项是 SuperTack，不是光面 PEI）。
    {"curr_bed_type", "打印板类型", 4, "", 0, 0, "低温打印板,工程材料打印板,高温打印板,纹理 PEI 打印板,SuperTack 打印板", "打印板", "", 0, 0, "打印板类型（影响首层温度）"},
};

// ---- 异步任务上下文 ----
struct AsyncContext {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_ref callbackRef = nullptr;
    std::function<std::string()> worker;
    std::string resultJson;
};

void ExecuteCallback(napi_env env, void* data)
{
    auto* ctx = static_cast<AsyncContext*>(data);
    if (ctx->worker) {
        ctx->resultJson = ctx->worker();
    }
}

void CompleteCallback(napi_env env, napi_status status, void* data)
{
    auto* ctx = static_cast<AsyncContext*>(data);
    napi_value callback = nullptr;
    napi_get_reference_value(env, ctx->callbackRef, &callback);
    napi_value result = nullptr;
    napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &result);
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_value argv[1] = { result };
    napi_call_function(env, global, callback, 1, argv, nullptr);
    napi_delete_reference(env, ctx->callbackRef);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

void QueueAsync(napi_env env, napi_value callback, std::function<std::string()> worker)
{
    auto* ctx = new AsyncContext();
    ctx->env = env;
    ctx->worker = std::move(worker);
    napi_create_reference(env, callback, 1, &ctx->callbackRef);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "BambuHMAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ExecuteCallback, CompleteCallback, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
}

std::string GetStringArg(napi_env env, napi_value arg)
{
    size_t len = 0;
    napi_get_value_string_utf8(env, arg, nullptr, 0, &len);
    std::string str(len, '\0');
    napi_get_value_string_utf8(env, arg, str.data(), len + 1, &len);
    return str;
}

// ---- rawfile 资源管理器（用于 C++ 读取预设 JSON）----
static NativeResourceManager* g_resMgr = nullptr;

std::string ReadRawFile(const char* filename)
{
    if (g_resMgr == nullptr) {
        return "";
    }
    RawFile* f = OH_ResourceManager_OpenRawFile(g_resMgr, filename);
    if (f == nullptr) {
        return "";
    }
    long len = OH_ResourceManager_GetRawFileSize(f);
    std::string buf(static_cast<size_t>(len), '\0');
    if (len > 0) {
        OH_ResourceManager_ReadRawFile(f, &buf[0], static_cast<size_t>(len));
    }
    OH_ResourceManager_CloseRawFile(f);
    return buf;
}

// 按 ',' 切分
std::vector<std::string> SplitCsv(const std::string& s)
{
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == ',') {
            out.push_back(cur);
            cur.clear();
        } else {
            cur += c;
        }
    }
    if (!cur.empty()) {
        out.push_back(cur);
    }
    return out;
}

// 内核 category（英文）→ 界面页签（中文）。只做一对一的诚实映射：拿不准的一律进「其他」，绝不猜。
// 粒度差异说明：内核把支撑/挤出机/擦料分得很细，界面沿用桌面版工艺设置的 6 个页签。
static const char* KernelCategoryToGroup(const std::string& category)
{
    if (category == "Quality")       return "质量";
    if (category == "Strength")      return "强度";
    if (category == "Speed")         return "速度";
    if (category == "Support")       return "支撑";
    if (category == "Extruders")     return "多材料";
    if (category == "Flush options") return "多材料";
    return "其他";
}

// 内核类型（已剥 coVectorType 位）→ 界面控件类型：0=浮点 1=整数 2=百分比 3=布尔 4=枚举。
// 返回 -1 = 「界面没有对应控件 / 这个类型不能安全来回写」→ 该参数不上界面（宁可少显示，也不出错）。
//
// 为什么不收 coFloatOrPercent（5）：它在内核里可能存的是「150%」这种带百分号的文本，
// 而快照走 getFloat() 只给数值（→1.5）。界面按浮点编辑后再写回就变成「1.5mm」，
// 语义悄悄从「150% of X」变成「1.5 毫米」—— 这是静默改参数，必须排除。
static int KernelTypeToUiType(int base_type)
{
    switch (base_type) {
        case 1:   return 0;   // coFloat
        case 2:   return 1;   // coInt
        case 4:   return 2;   // coPercent（数值 ↔ 百分比文本对称，可安全来回写）
        case 8:   return 3;   // coBool
        case 9:   return 4;   // coEnum（写回按「下标 → 内核名」映射）
        default:  return -1;  // coString / coPoint / coPoint3 / co*Groups / coFloatOrPercent
    }
}

// 构建切片参数 schema JSON
//
//   数据来源分三层，各司其职：
//     1) 内核 config 快照（slicer_config_snapshot）：决定「这个预设下到底有哪些参数」以及
//        每一项的当前值。快照里没有的 key 直接丢弃 —— 这是「不造假项」的保证。
//        * 布尔项快照发的是 JSON bool（不是数字），漏掉 is_boolean() 会让表单退回硬编码默认值，
//          进而在切片时把官方预设的布尔项覆盖掉；
//        * 向量型选项（bridge_speed / sparse_infill_speed 等 coFloats）快照给的是数组首元素，
//          只用于显示，写回时内核会跳过（见 apply_params）；
//        * 枚举项快照给的是 PrintConfigDef::enum_values 的**下标**（不是底层枚举值 getInt()）；
//          内核 config_flat_json() 用唯一权威映射做了「枚举值 → 下标」的换算，
//          所以这里的下标与 slicer_enum_values() 的顺序、apply_params() 的赋值语义三者同源。
//     2) 内核枚举表（slicer_enum_values）：枚举下拉的候选项与顺序，保证「表单选第 N 项」
//        ≡「内核第 N 个枚举名」，不会再出现枚举错位。
//     3) 本地 kSchema：只提供中文显示名/单位/分组/量程/控件类型这些 UI 元信息。
std::string BuildSchemaJson()
{
    const nlohmann::json snapshot =
        nlohmann::json::parse(Slic3r::ohos::slicer_config_snapshot(), nullptr, false);
    const nlohmann::json enum_names =
        nlohmann::json::parse(Slic3r::ohos::slicer_enum_values(), nullptr, false);
    // 内核全量定义元信息（label/tooltip/单位/量程/模式/枚举/分类）——手写表里没有的键用它兜底
    const nlohmann::json defs =
        nlohmann::json::parse(Slic3r::ohos::slicer_config_defs(), nullptr, false);
    const bool have_snapshot = snapshot.is_object() && !snapshot.empty();
    const bool have_enums    = enum_names.is_object();

    nlohmann::json arr = nlohmann::json::array();
    // 手写表已经出过的 key（含「表里有、快照里没有」的）：第二遍兜底时不再重复出
    std::set<std::string> listed;
    const size_t n = sizeof(kSchema) / sizeof(kSchema[0]);
    for (size_t i = 0; i < n; ++i) {
        const ParamMeta& p = kSchema[i];
        listed.insert(p.key);
        const bool is_enum = (p.type == 4);

        // 预设未就绪（快照为空）时先按 kSchema 兜底渲染，别让面板空着；
        // 快照可用后则以内核为准筛选 —— 内核里没有的参数一律不上界面。
        nlohmann::json::const_iterator sit = snapshot.end();
        bool in_snapshot = false;
        if (have_snapshot) {
            sit = snapshot.find(p.key);
            in_snapshot = (sit != snapshot.end());
            if (!in_snapshot)
                continue;
        }

        std::vector<std::string> values;   // 内核实名，顺序 = 内核枚举下标顺序
        std::vector<std::string> options;  // 界面显示项
        double                   value = p.def;

        if (is_enum) {
            if (have_enums) {
                auto it = enum_names.find(p.key);
                if (it != enum_names.end() && it->is_array()) {
                    for (const auto& v : *it) {
                        values.emplace_back(v.get<std::string>());
                    }
                }
            }
            options = SplitCsv(p.options);
            if (values.empty() || options.size() != values.size()) {
                // 拿不到内核枚举表，或中文标签数量和内核枚举对不上：
                // 宁可用内核名（丑但不会错位）
                options = values;
            }
            if (in_snapshot) {
                if (sit->is_number()) {
                    // 内核 coEnum 快照发的是枚举下标（= PrintConfigDef enum_values 的下标）
                    const long idx = std::lround(sit->get<double>());
                    if (idx >= 0 && static_cast<size_t>(idx) < values.size())
                        value = static_cast<double>(idx);
                } else if (sit->is_string()) {
                    const std::string cur = sit->get<std::string>();
                    for (size_t k = 0; k < values.size(); ++k) {
                        if (values[k] == cur) {
                            value = static_cast<double>(k);
                            break;
                        }
                    }
                }
            }
        } else if (in_snapshot) {
            if (sit->is_number())
                value = sit->get<double>();
            else if (sit->is_boolean())
                value = sit->get<bool>() ? 1.0 : 0.0;
        }

        nlohmann::json item;
        item["key"]      = p.key;
        item["label"]    = p.label;
        item["type"]     = p.type;
        item["unit"]     = p.unit;
        item["min"]      = p.min;
        item["max"]      = p.max;
        item["group"]    = p.group;
        item["subgroup"] = p.subgroup;
        item["mode"]     = p.mode;
        item["tooltip"]  = p.tooltip;
        item["options"]  = options;
        if (is_enum) {
            item["values"] = values;
        }
        item["value"] = value;
        arr.push_back(std::move(item));
    }
    // 手写表实际出了多少条（下面算「内核兜底出了多少」要用）
    const size_t manual_n = arr.size();

    // ---- 第二遍：快照里有、手写表里没有的键 → 用内核定义兜底 ----
    //
    // 目的：参数总量从「手写表 ∩ 快照」提到「快照全键集」。过去这些键是在上面的循环里
    // 被静默丢掉的（快照查得到、表里没有），于是「内核有、界面没有」的参数既看不见也改不了。
    // 四条硬约束（宁可少显示，也不显示错的）：
    //   1) 只上界面有对应控件的类型：字符串 / 坐标 / 分组型没有控件 → 跳过；
    //   2) 一律归到**高级视图**（mode=1）：这些键的中文名、量程、分组都没有人工校过，
    //      绝不能污染默认的简易视图（简易视图保持现状 = 无可用性回归，见路线文档的风险条）；
    //   3) 只读项（readonly，例如线程数）跳过：那是内核回读值，写回去没有意义；
    //   4) 量程只有内核**显式声明**过才带上；缺省发 0/0 = 「未声明范围」，界面据此不做夹取。
    size_t skip_vector = 0, skip_type = 0, skip_readonly = 0, skip_nodef = 0, skip_enum = 0;
    if (have_snapshot && defs.is_object()) {
        for (auto it = snapshot.begin(); it != snapshot.end(); ++it) {
            const std::string key = it.key();
            if (listed.find(key) != listed.end())
                continue;
            const nlohmann::json::const_iterator dit = defs.find(key);
            if (dit == defs.end()) {
                ++skip_nodef;                    // 内核没有这条定义 → 不上界面（不造假项）
                continue;
            }
            const nlohmann::json& od = *dit;
            if (od.value("readonly", false)) {
                ++skip_readonly;
                continue;
            }
            // 向量型（按喷嘴/耗材分档）一律不收：快照只给第一档，界面是单个标量控件，
            // 写回时 apply_params 会把标量**广播到每一档**（见其「标量 + 数组 → 广播」分支），
            // 于是多档不同的值会被第一档统一覆盖 —— 那是静默改参数。手写表对 fil_flow_ratio
            // 之类也是同样口径（宁可让用户去耗材弹窗按数组改）。
            if (od.value("vector", false)) {
                ++skip_vector;
                continue;
            }
            const int ui_type = KernelTypeToUiType(od.value("type", 0));
            if (ui_type < 0) {
                ++skip_type;
                continue;
            }

            const std::string label   = od.value("label", std::string());
            const std::string cat     = od.value("category", std::string());

            std::vector<std::string> values;    // 内核实名（枚举）
            std::vector<std::string> options;
            double value = 0;

            if (ui_type == 4) {
                const auto ev = od.find("enum_values");
                if (ev != od.end() && ev->is_array()) {
                    for (const auto& v : *ev) {
                        values.emplace_back(v.get<std::string>());
                    }
                }
                if (values.empty()) {
                    ++skip_enum;
                    continue;                    // 枚举拿不到候选 → 不给一个空下拉
                }
                const auto el = od.find("enum_labels");
                if (el != od.end() && el->is_array() && el->size() == values.size()) {
                    for (const auto& v : *el) {
                        options.emplace_back(v.get<std::string>());
                    }
                } else {
                    options = values;            // 内核没给中文标签 → 用内核名（丑但不会错位）
                }
                if (it->is_number()) {
                    const long idx = std::lround(it->get<double>());
                    if (idx >= 0 && static_cast<size_t>(idx) < values.size())
                        value = static_cast<double>(idx);
                } else if (it->is_string()) {
                    const std::string cur = it->get<std::string>();
                    for (size_t k = 0; k < values.size(); ++k) {
                        if (values[k] == cur) { value = static_cast<double>(k); break; }
                    }
                }
            } else if (it->is_number()) {
                value = it->get<double>();
            } else if (it->is_boolean()) {
                value = it->get<bool>() ? 1.0 : 0.0;
            }

            double vmin = 0;
            double vmax = 0;   // 0/0 = 未声明范围 → 界面不夹取
            const auto fmin = od.find("min");
            const auto fmax = od.find("max");
            if (fmin != od.end() && fmax != od.end() && fmin->is_number() && fmax->is_number()) {
                vmin = fmin->get<double>();
                vmax = fmax->get<double>();
            }

            nlohmann::json extra;
            extra["key"]      = key;
            // 显示名：内核 label 优先；为空就退回 key 原名（绝不编一个中文名）
            extra["label"]    = label.empty() ? key : label;
            extra["type"]     = ui_type;
            extra["unit"]     = od.value("unit", std::string());
            extra["min"]      = vmin;
            extra["max"]      = vmax;
            extra["group"]    = KernelCategoryToGroup(cat);
            // 二级分组这里给**内核原分类**（英文），由 ETS 侧翻译并拼成「内核 · <中文分类>」。
            // src 显式标出来源：ETS 靠它决定「这项要不要过官方译法」——
            // 比在两侧各自维护一个中文字符串前缀去匹配可靠得多（跨语言字符串比对最容易静默失效）。
            extra["subgroup"] = cat;
            extra["src"]      = "kernel";
            extra["mode"]     = 1;
            extra["tooltip"]  = od.value("tooltip", std::string());
            extra["options"]  = options;
            if (ui_type == 4)
                extra["values"] = values;
            extra["value"]    = value;
            arr.push_back(std::move(extra));
        }
    }

    // 自证：参数总量与「第二遍都因为什么被跳过」——排查「某个参数怎么不见了」先看这条。
    // 两个坑：① hilog 格式串不支持 %zu（size_t 长度修饰符），必须显式转 int 用 %{public}d，
    //            否则整行被判非法格式、什么都不打印；
    //         ② LOG_APP(=0) 这个 domain 的行在本机不进 hilog 缓冲，得用 App 侧同一个 domain
    //            （ETS 的 hilog 用 0xA00000）显式调 OH_LOG_Print，才和界面日志一起可见。
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xA00000, "SliceSchema",
        "schema built: total=%{public}d manual=%{public}d from_kernel=%{public}d "
        "| snapshot=%{public}d defs_ok=%{public}d skip(vector=%{public}d type=%{public}d "
        "readonly=%{public}d no_def=%{public}d enum=%{public}d)",
        static_cast<int>(arr.size()), static_cast<int>(manual_n),
        static_cast<int>(arr.size() - manual_n), static_cast<int>(snapshot.size()),
        defs.is_object() ? 1 : 0,
        static_cast<int>(skip_vector), static_cast<int>(skip_type),
        static_cast<int>(skip_readonly), static_cast<int>(skip_nodef),
        static_cast<int>(skip_enum));
    return arr.dump();
}

// JSON 字符串转义：ext 的显示值里可能出现引号/反斜杠（如任务名），不转义会让整段 JSON 解析失败
static std::string JsonEscape(const std::string& s)
{
    std::string o;
    o.reserve(s.size() + 8);
    for (size_t i = 0; i < s.size(); ++i) {
        const char c = s[i];
        switch (c) {
        case '"':  o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break;
        case '\t': o += "\\t"; break;
        default:
            // 其余控制字符直接丢弃（JSON 里非法）
            if (static_cast<unsigned char>(c) >= 0x20) { o += c; }
            break;
        }
    }
    return o;
}

// 将打印机状态序列化为 JSON
std::string StateToJson(const BambuMqtt::PrinterState& s)
{
    std::string out = "{";
    out += "\"connected\":" + std::string(s.connected ? "true" : "false");
    out += ",\"serial\":\"" + s.serial + "\"";
    out += ",\"ip\":\"" + s.ip + "\"";
    out += ",\"state\":\"" + s.gcodeState + "\"";
    out += ",\"progress\":" + std::to_string(s.progress);
    out += ",\"layer\":" + std::to_string(s.layer);
    out += ",\"totalLayers\":" + std::to_string(s.totalLayers);
    out += ",\"remainingMinutes\":" + std::to_string(s.remainingMinutes);
    out += ",\"nozzleTemp\":" + std::to_string(s.nozzleTemp);
    out += ",\"bedTemp\":" + std::to_string(s.bedTemp);
    out += ",\"chamberTemp\":" + std::to_string(s.chamberTemp);
    // 温度是否"已知"：增量上报下未收到该字段 → false（UI 显示 "--"，绝不用 0 冒充真实值）
    out += ",\"nozzleTempKnown\":" + std::string(s.hasNozzleTemp ? "true" : "false");
    out += ",\"bedTempKnown\":" + std::string(s.hasBedTemp ? "true" : "false");
    out += ",\"chamberTempKnown\":" + std::string(s.hasChamberTemp ? "true" : "false");
    out += ",\"nozzleTargetTemp\":" + std::to_string(s.nozzleTargetTemp);
    out += ",\"bedTargetTemp\":" + std::to_string(s.bedTargetTemp);
    out += ",\"chamberTargetTemp\":" + std::to_string(s.chamberTargetTemp);
    out += ",\"hasChamberHeater\":" + std::string(s.hasChamberHeater ? "true" : "false");
    out += ",\"partFan\":" + std::to_string(s.partFan);
    out += ",\"auxFan\":" + std::to_string(s.auxFan);
    out += ",\"chamberFan\":" + std::to_string(s.chamberFan);
    out += ",\"ams\":" + (s.amsJson.empty() ? "[]" : s.amsJson);
    // 外挂料盘（print.vt_tray）：空串 → {}（界面据此不显示该项，不编造）
    out += ",\"externalSpool\":" + (s.externalSpoolJson.empty() ? "{}" : s.externalSpoolJson);
    // 表驱动扩展字段（显示名 → 显示值）：以后新增上报字段只要加进 kExtReportFields，
    // 这里与 ETS 的「状态详情」区都不用改（UI 直接按 名/值 两列渲染）。
    out += ",\"ext\":{";
    bool firstExt = true;
    for (std::map<std::string, std::string>::const_iterator it = s.ext.begin(); it != s.ext.end(); ++it) {
        if (!firstExt) { out += ","; }
        firstExt = false;
        out += "\"" + JsonEscape(it->first) + "\":\"" + JsonEscape(it->second) + "\"";
    }
    out += "}";
    // HMS 故障数组原样透传（[] = 当前无故障）。文案查表在 ETS 侧做：码表是 rawfile 资源，
    // 换语言/更新码表都不需要重编原生库。
    out += ",\"hms\":" + (s.hmsJson.empty() ? "[]" : s.hmsJson);
    // 机器侧 AI 检测开关（原样透传；{} = 该机型没有这套检测，UI 整块隐藏）
    out += ",\"xcam\":" + (s.xcamJson.empty() ? "{}" : s.xcamJson);
    out += ",\"npEnabled\":" + std::string(s.npEnabled ? "true" : "false");
    // 本会话收到的状态推送条数（0 = 已连接但未收到任何状态数据，供 UI 区分“已连接”与“已连接但无数据”）
    out += ",\"pushStatusCount\":" + std::to_string(s.pushStatusCount);
    out += "}";
    return out;
}

// ---------------------------------------------------------------------------
// 同步接口
// ---------------------------------------------------------------------------

static napi_value Add(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double value0 = 0;
    double value1 = 0;
    napi_get_value_double(env, args[0], &value0);
    napi_get_value_double(env, args[1], &value1);
    napi_value sum = nullptr;
    napi_create_double(env, value0 + value1, &sum);
    return sum;
}

static napi_value SlicerGetVersion(napi_env env, napi_callback_info info)
{
    // 返回 libslic3r 的真实版本（= SLIC3R_VERSION，对齐桌面版 Bambu Studio 2.8.2.61）
    const std::string ver = Slic3r::ohos::slicer_version();
    napi_value result = nullptr;
    napi_create_string_utf8(env, ver.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 初始化 rawfile 资源管理器（ArkTS 侧传入 context.resourceManager）
static napi_value InitResourceManager(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    g_resMgr = OH_ResourceManager_InitNativeResourceManager(env, args[0]);
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

// 返回全部切片参数 schema（元数据 + 值）
static napi_value GetSliceParamSchema(napi_env env, napi_callback_info info)
{
    std::string schema = BuildSchemaJson();
    napi_value result = nullptr;
    napi_create_string_utf8(env, schema.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 初始化切片预设：把 rawfile 里的 bambu_res.zip 交给内核解压 + 加载 BBL 官方预设。
// 首次运行会解 2500+ 个小文件，所以走异步，避免卡 UI。
static napi_value SlicerInitPresets(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[1];
    std::string filesDir = GetStringArg(env, args[0]);
    QueueAsync(env, callback, [filesDir]() -> std::string {
        if (filesDir.empty()) {
            return std::string("{\"ok\":false,\"message\":\"filesDir 为空\"}");
        }
        // rawfile 里的预设包直接在内存里交给内核（miniz 从内存解压），不落 zip 到磁盘
        const std::string zip = ReadRawFile("bambu_res.zip");
        const void* data = zip.empty() ? nullptr : static_cast<const void*>(zip.data());
        return Slic3r::ohos::slicer_init_presets(filesDir, data, zip.size());
    });
    return nullptr;
}

// 切换预设（打印机/工艺/耗材），空串表示保持当前选择
static napi_value SlicerSelectPresets(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string printer  = GetStringArg(env, args[0]);
    const std::string process  = GetStringArg(env, args[1]);
    const std::string filament = GetStringArg(env, args[2]);
    const std::string out = Slic3r::ohos::slicer_select_presets(printer, process, filament);
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 枚举"可被选中"的预设候选表（kind: 0=printer / 1=process / 2=filament）。
// 返回内核集合顺序的 items（含 name / layerHeight / nozzle）；UI 下拉直接用这份列表 + 下标。
static napi_value SlicerPresetOptions(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t kind = 0;
    if (args[0] != nullptr) {
        napi_get_value_int32(env, args[0], &kind);
    }
    const std::string out = Slic3r::ohos::slicer_preset_options(static_cast<int>(kind));
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 按索引选择预设（kind: 0=printer / 1=process / 2=filament；index 为候选表下标）。
// 接口不再传名字字符串，从机制上消除"界面名字 ↔ 内核名字对不上"导致的静默回退。
static napi_value SlicerSelectPresetByIndex(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t kind  = -1;
    int32_t index = -1;
    if (args[0] != nullptr) {
        napi_get_value_int32(env, args[0], &kind);
    }
    if (args[1] != nullptr) {
        napi_get_value_int32(env, args[1], &index);
    }
    const std::string out =
        Slic3r::ohos::slicer_select_preset_by_index(static_cast<int>(kind), static_cast<int>(index));
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 用内核兼容性元数据（compatible_printers / compatible_printers_condition）返回该打印机
// 真正兼容的工艺 / 耗材预设名。UI 用它替换原来的"名字后缀启发式"过滤。
static napi_value SlicerPresetsForPrinter(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string printer = GetStringArg(env, args[0]);
    const std::string out = Slic3r::ohos::slicer_presets_for_printer(printer);
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 当前打印机预设的打印板（完整多边形 + 高度 + 包围盒）。ArkTS 画打印板/网格/取景用它。
static napi_value SlicerPrinterBed(napi_env env, napi_callback_info info)
{
    const std::string out = Slic3r::ohos::slicer_printer_bed();
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 当前预设合成出的配置快照（动态表单取初值用）
static napi_value SlicerConfigSnapshot(napi_env env, napi_callback_info info)
{
    const std::string out = Slic3r::ohos::slicer_config_snapshot();
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 当前**被编辑的耗材预设**的键值快照（含向量型，按数组返回）—— 耗材编辑弹窗取初值用
static napi_value SlicerFilamentSnapshot(napi_env env, napi_callback_info info)
{
    const std::string out = Slic3r::ohos::slicer_filament_snapshot();
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 枚举选项的内核权威取值表（表单下拉的取值顺序必须用它）
static napi_value SlicerEnumValues(napi_env env, napi_callback_info info)
{
    const std::string out = Slic3r::ohos::slicer_enum_values();
    napi_value result = nullptr;
    napi_create_string_utf8(env, out.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value MqttDisconnect(napi_env env, napi_callback_info info)
{
    BambuMqtt::disconnect();
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

// 同步：返回 MQTT 运行日志（JSON 字符串数组）
static napi_value MqttGetLogs(napi_env env, napi_callback_info info)
{
    std::string logs = BambuMqtt::getLogs();
    napi_value result = nullptr;
    napi_create_string_utf8(env, logs.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// ---------------------------------------------------------------------------
// 异步接口（切片 / 打印机发现 / MQTT 连接）
// ---------------------------------------------------------------------------

static napi_value SlicerSlice(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[3];
    std::string inputPath = GetStringArg(env, args[0]);
    std::string paramsJson = GetStringArg(env, args[1]);
    std::string outputPath = GetStringArg(env, args[2]);
    // 真正的 libslic3r 切片管线：Model 载入 -> Print::apply -> process -> export_gcode
    // 结果 JSON：{"ok":true,"status":"done","output":...,"layers":N,"filamentUsedG":...}
    QueueAsync(env, callback, [inputPath, paramsJson, outputPath]() -> std::string {
        return Slic3r::ohos::slicer_slice(inputPath, paramsJson, outputPath);
    });
    return nullptr;
}

// 导出「项目 3MF」（含完整切片设置，拓竹原生工程格式）。由内核 store_bbs_3mf 写文件。
// 异步：与切片同一套 QueueAsync（耗时在 worker 线程，结果经回调回主线程）。
static napi_value SlicerExportProject3mf(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[3];
    std::string inputPath = GetStringArg(env, args[0]);
    std::string paramsJson = GetStringArg(env, args[1]);
    std::string outputPath = GetStringArg(env, args[2]);
    QueueAsync(env, callback, [inputPath, paramsJson, outputPath]() -> std::string {
        return Slic3r::ohos::slicer_export_project_3mf(inputPath, paramsJson, outputPath);
    });
    return nullptr;
}

// 导出「含 gcode 的 .gcode.3mf」：同一份 store_bbs_3mf 链路，额外把 gcodePath 指定的已切 gcode
// 作为 Metadata/plate_1.gcode 打进包（真打印的前提）。异步：与项目导出同一套 QueueAsync。
static napi_value SlicerExportGcode3mf(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[4];
    std::string inputPath  = GetStringArg(env, args[0]);
    std::string paramsJson = GetStringArg(env, args[1]);
    std::string outputPath = GetStringArg(env, args[2]);
    std::string gcodePath  = GetStringArg(env, args[3]);
    QueueAsync(env, callback, [inputPath, paramsJson, outputPath, gcodePath]() -> std::string {
        return Slic3r::ohos::slicer_export_gcode_3mf(inputPath, paramsJson, outputPath, gcodePath);
    });
    return nullptr;
}

// ---------------------------------------------------------------------------
// 3MF 导入（几何 + 设置 + 盘）
//
// 复用 meshParse 已有的「内核网格 → ArkTS」通道形态：元数据走 info JSON 字符串，
// 顶点走**一次性分配 + memcpy** 的 ArrayBuffer（绝不逐元素 set_element，也不塞进 JSON）。
// worker 线程跑内核加载器（load_model_file -> load_bbs_3mf），Complete 在 JS 线程拷进 JS 堆。
// ---------------------------------------------------------------------------
struct Import3mfCtx {
    napi_async_work    work = nullptr;
    napi_ref           cb = nullptr;
    std::string        path;
    std::string        resultJson;
    std::vector<float> positions;
};

static void Import3mfExecute(napi_env env, void* data)
{
    (void)env;
    auto* ctx = static_cast<Import3mfCtx*>(data);
    ctx->resultJson = Slic3r::ohos::slicer_import_3mf(ctx->path, ctx->positions);
}

static void Import3mfComplete(napi_env env, napi_status status, void* data)
{
    auto* ctx = static_cast<Import3mfCtx*>(data);
    napi_value callback = nullptr;
    napi_get_reference_value(env, ctx->cb, &callback);
    if (callback != nullptr) {
        napi_value result = nullptr;
        napi_create_object(env, &result);
        napi_value infoStr = nullptr;
        napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &infoStr);
        napi_set_named_property(env, result, "info", infoStr);

        // 顶点：一次分配 + 一次 memcpy，避免循环 napi_set_element 钉死 JS 线程
        void* posData = nullptr;
        napi_value posAb = nullptr;
        napi_create_arraybuffer(env, ctx->positions.size() * sizeof(float), &posData, &posAb);
        if (!ctx->positions.empty() && posData != nullptr) {
            memcpy(posData, ctx->positions.data(), ctx->positions.size() * sizeof(float));
        }
        napi_set_named_property(env, result, "positions", posAb);

        napi_value global = nullptr;
        napi_get_global(env, &global);
        napi_value argv[1] = { result };
        napi_call_function(env, global, callback, 1, argv, nullptr);
    }
    napi_delete_reference(env, ctx->cb);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value SlicerImport3mf(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, nullptr, "need (path, callback)");
        return nullptr;
    }
    auto* ctx = new Import3mfCtx();
    ctx->path = GetStringArg(env, args[0]);
    napi_create_reference(env, args[1], 1, &ctx->cb);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "Import3mf", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, Import3mfExecute, Import3mfComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return nullptr;
}

static napi_value MqttDiscover(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[0];
    QueueAsync(env, callback, []() -> std::string {
        return BambuDiscovery::toJson(BambuDiscovery::discover());
    });
    return nullptr;
}

static napi_value MqttConnect(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[3];
    std::string ip = GetStringArg(env, args[0]);
    std::string accessCode = GetStringArg(env, args[1]);
    std::string serial = GetStringArg(env, args[2]);
    QueueAsync(env, callback, [ip, accessCode, serial]() -> std::string {
        bool ok = BambuMqtt::connect(ip, accessCode, serial);
        nlohmann::json j;
        j["ok"] = ok;
        if (!ok) {
            // 失败原因：code（机器可读）+ message（中文可行动原因），供 UI 直接展示
            j["code"] = BambuMqtt::lastErrorCode();
            j["message"] = BambuMqtt::lastErrorMessage();
        }
        return j.dump();
    });
    return nullptr;
}

static napi_value MqttGetStatus(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[0];
    QueueAsync(env, callback, []() -> std::string {
        return StateToJson(BambuMqtt::getState());
    });
    return nullptr;
}

// 增量字段合并单元自测（同步）：跑真实 applyReport 的缺字段用例，返回逐条 PASS/FAIL 文本。
// 同时把每条写进 hilog/应用日志（tag=MqttSelfTest），便于 hdc 抓取核对。
static napi_value MqttSelfTestMerge(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string text = BambuMqtt::selfTestMerge();
    size_t pos = 0;
    while (pos < text.size()) {
        size_t nl = text.find('\n', pos);
        std::string line = (nl == std::string::npos) ? text.substr(pos) : text.substr(pos, nl - pos);
        if (!line.empty()) { BambuMqtt::addLogTagged("MqttSelfTest", line); }
        if (nl == std::string::npos) { break; }
        pos = nl + 1;
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, text.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value MqttSendCommand(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[1];
    std::string commandJson = GetStringArg(env, args[0]);
    QueueAsync(env, callback, [commandJson]() -> std::string {
        bool ok = BambuMqtt::sendCommand(commandJson);
        return "{\"ok\":" + std::string(ok ? "true" : "false") + "}";
    });
    return nullptr;
}

// 设备侧 K 值表（只读）：发 extrusion_cali_get。**只查不写**，不触碰设备侧数据。
// 参数：mqttRequestKProfiles(callback) → {"ok":bool}。
static napi_value MqttRequestKProfiles(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[0];
    QueueAsync(env, callback, []() -> std::string {
        bool ok = BambuMqtt::requestKProfiles();
        return "{\"ok\":" + std::string(ok ? "true" : "false") + "}";
    });
    return nullptr;
}

// 取已留存的"校准相关原始报文"（JSON 字符串数组）。协议形状未定案前，靠它拿真机原文。
static napi_value MqttGetCaliRaw(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[0];
    QueueAsync(env, callback, []() -> std::string {
        return BambuMqtt::getCaliRaw();
    });
    return nullptr;
}

// FTPS 上传（隐式 FTPS 990）：把本地文件 PUT 到打印机。**只上传，不触发打印**。
// ip + 访问码取自当前 MQTT 会话（BambuMqtt::currentSession），访问码不回传到 JS 层。
// 参数：ftpsUpload(localPath, remotePath, callback)。
//   remotePath 以 '/' 开头 = 完整远端路径（如 "/sdcard/x.3mf"，用于落点回退）；
//   否则视作裸文件名，内部拼成 "/cache/<name>"（保持既有 /cache 口径向后兼容）。
static napi_value FtpsUpload(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[2];   // args[0]=localPath, args[1]=remotePath, args[2]=callback
    std::string localPath = GetStringArg(env, args[0]);
    std::string remotePath = GetStringArg(env, args[1]);
    QueueAsync(env, callback, [localPath, remotePath]() -> std::string {
        std::string ip, code, serial;
        if (!BambuMqtt::currentSession(ip, code, serial)) {
            return std::string("{\"ok\":false,\"code\":\"NOSESSION\",\"message\":\"未连接打印机（无 MQTT 会话，拿不到访问码）\"}");
        }
        std::string remote = (!remotePath.empty() && remotePath[0] == '/') ? remotePath : ("/cache/" + remotePath);
        return BambuFtps::upload(ip, "bblp", code, localPath, remote);
    });
    return nullptr;
}

// FTPS 列目录（隐式 FTPS 990）：列打印机某目录（如 /cache）。**只读，不上传、不打印**。
// ip + 访问码取自当前 MQTT 会话（BambuMqtt::currentSession），访问码不回传到 JS 层。
// 参数：ftpsList(dir, callback)；dir 直接给出（如 "/cache"）。
static napi_value FtpsList(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[1];   // args[0]=dir, args[1]=callback
    std::string dir = GetStringArg(env, args[0]);
    QueueAsync(env, callback, [dir]() -> std::string {
        std::string ip, code, serial;
        if (!BambuMqtt::currentSession(ip, code, serial)) {
            return std::string("{\"ok\":false,\"code\":\"NOSESSION\",\"message\":\"未连接打印机（无 MQTT 会话，拿不到访问码）\"}");
        }
        return BambuFtps::list(ip, "bblp", code, dir);
    });
    return nullptr;
}

// 删除打印机上的文件：ftpsRemove(remotePath, cb)
static napi_value FtpsRemove(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[1];   // args[0]=remotePath, args[1]=callback
    std::string path = GetStringArg(env, args[0]);
    QueueAsync(env, callback, [path]() -> std::string {
        std::string ip, code, serial;
        if (!BambuMqtt::currentSession(ip, code, serial)) {
            return std::string("{\"ok\":false,\"code\":\"NOSESSION\",\"message\":\"未连接打印机（无 MQTT 会话，拿不到访问码）\"}");
        }
        return BambuFtps::removeFile(ip, "bblp", code, path);
    });
    return nullptr;
}

// 下载打印机上的文件：ftpsDownload(remotePath, localPath, maxBytes, cb)
static napi_value FtpsDownload(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value callback = args[3];   // args[3]=callback
    std::string remotePath = GetStringArg(env, args[0]);
    std::string localPath = GetStringArg(env, args[1]);
    double maxBytes = 0;
    if (argc > 2) {
        napi_get_value_double(env, args[2], &maxBytes);
    }
    const long long cap = static_cast<long long>(maxBytes);
    QueueAsync(env, callback, [remotePath, localPath, cap]() -> std::string {
        std::string ip, code, serial;
        if (!BambuMqtt::currentSession(ip, code, serial)) {
            return std::string("{\"ok\":false,\"code\":\"NOSESSION\",\"message\":\"未连接打印机（无 MQTT 会话，拿不到访问码）\"}");
        }
        return BambuFtps::download(ip, "bblp", code, remotePath, localPath, cap);
    });
    return nullptr;
}


// 启动摄像头拉流（按机型选择端口）
// 参数：cameraStart(ip, accessCode, model, serial, forceProto)
//   model      = SSDP 友好机型名（可空；空则用 serial 前缀兜底推断）
//   serial     = 打印机序列号（用于机型兜底）
//   forceProto = 0 自动 / 1 强制 322 / 2 强制 6000（测试注入用）
// 端口选择与回退在 C++ 侧完成：322(RTSPS/H.264) 或 6000(TCP+TLS chamber image/JPEG)。
static napi_value CameraStart(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string ip = GetStringArg(env, args[0]);
    std::string accessCode = GetStringArg(env, args[1]);
    std::string model = argc > 2 ? GetStringArg(env, args[2]) : std::string();
    std::string serial = argc > 3 ? GetStringArg(env, args[3]) : std::string();
    int forceProto = 0;
    if (argc > 4 && args[4] != nullptr) {
        napi_get_value_int32(env, args[4], &forceProto);
    }
    bool ok = BambuCamera::startForDevice(ip, accessCode, model, serial, forceProto);
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

// 纯查询：机型/序列号 → 端口候选顺序描述（如 "6000,322 (机型属 6000 家族)"）。
// 供日志/自检/测试注入验证“选择逻辑”用，不发起任何网络连接。
static napi_value CameraResolveProtocol(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string model = argc > 0 ? GetStringArg(env, args[0]) : std::string();
    std::string serial = argc > 1 ? GetStringArg(env, args[1]) : std::string();
    std::string desc = BambuCamera::resolveProtocol(model, serial);
    napi_value result = nullptr;
    napi_create_string_utf8(env, desc.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 停止摄像头拉流
static napi_value CameraStop(napi_env env, napi_callback_info info)
{
    BambuCamera::stop();
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// 获取最新一帧（{width,height,seq,data:ArrayBuffer(RGBA)}，无新帧时返回 null）
// 性能设计：
//  - 帧序号去重：无新帧直接返回 null（仅一次锁内比较，零拷贝）
//  - ArrayBuffer 复用：同一块持久缓冲反复写入，避免每帧 3.7MB 分配/GC
//    （ArkTS 侧 pmPending 保证上一帧 createPixelMap 完成后才取下一帧，覆盖安全）
static napi_ref g_frameAbRef = nullptr;
static void* g_frameAbData = nullptr;
static size_t g_frameAbCap = 0;
static uint64_t g_lastServedSeq = 0;

static napi_value CameraGetFrame(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_get_null(env, &result);

    // 预探测：无帧或无新帧时零拷贝返回
    BambuCamera::FrameInfo probe;
    if (!BambuCamera::peekFrame(probe) || probe.seq == g_lastServedSeq) {
        return result;
    }
    // 缓冲不够大（首帧/分辨率变化）时重建持久 ArrayBuffer
    if (g_frameAbRef == nullptr || g_frameAbCap < probe.size) {
        if (g_frameAbRef != nullptr) {
            napi_delete_reference(env, g_frameAbRef);
            g_frameAbRef = nullptr;
        }
        napi_value ab = nullptr;
        void* data = nullptr;
        if (napi_create_arraybuffer(env, probe.size, &data, &ab) != napi_ok) {
            return result;
        }
        napi_create_reference(env, ab, 1, &g_frameAbRef);
        g_frameAbData = data;
        g_frameAbCap = probe.size;
    }

    BambuCamera::FrameInfo fi;
    if (!BambuCamera::copyFrameIfNew(g_lastServedSeq, g_frameAbData, g_frameAbCap, fi)) {
        return result;
    }
    g_lastServedSeq = fi.seq;

    napi_value ab = nullptr;
    napi_get_reference_value(env, g_frameAbRef, &ab);
    if (ab == nullptr) {
        return result;
    }
    napi_create_object(env, &result);
    napi_value w = nullptr;
    napi_value h = nullptr;
    napi_value seq = nullptr;
    napi_create_int32(env, fi.width, &w);
    napi_create_int32(env, fi.height, &h);
    napi_create_int64(env, static_cast<int64_t>(fi.seq), &seq);
    napi_set_named_property(env, result, "width", w);
    napi_set_named_property(env, result, "height", h);
    napi_set_named_property(env, result, "seq", seq);
    // 帧格式：6000 通道为完整 JPEG（ArkTS 用系统 image 模块解码）；322 通道为 RGBA
    napi_value fmt = nullptr;
    napi_create_string_utf8(env, fi.isJpeg ? "jpeg" : "rgba", NAPI_AUTO_LENGTH, &fmt);
    napi_set_named_property(env, result, "format", fmt);
    napi_set_named_property(env, result, "data", ab);
    return result;
}

// ---------------------------------------------------------------------------
// 3D 渲染器：XComponent 表面回调 + 相机控制 + 模型加载
// ---------------------------------------------------------------------------

// 持有 exports 引用：XComponent 的 __NATIVE_XCOMPONENT__ 属性在模块 Init 之后才注入
static napi_ref g_exportsRef = nullptr;

void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window)
{
    (void)component;
    BambuRenderer::onSurfaceCreated(window);
}

void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window)
{
    uint64_t w = 0;
    uint64_t h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    BambuRenderer::onSurfaceChanged(window, static_cast<int>(w), static_cast<int>(h));
}

void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window)
{
    (void)component;
    (void)window;
    BambuRenderer::onSurfaceDestroyed();
}

static OH_NativeXComponent_Callback g_xcomponentCallback = {};

bool TryRegisterXComponent(napi_env env)
{
    if (g_exportsRef == nullptr) {
        return false;
    }
    napi_value exports = nullptr;
    napi_get_reference_value(env, g_exportsRef, &exports);
    if (exports == nullptr) {
        return false;
    }
    napi_value exportInstance = nullptr;
    napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance);
    if (exportInstance == nullptr) {
        return false;
    }
    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) != napi_ok
        || nativeXComponent == nullptr) {
        return false;
    }
    g_xcomponentCallback.OnSurfaceCreated = OnSurfaceCreatedCB;
    g_xcomponentCallback.OnSurfaceChanged = OnSurfaceChangedCB;
    g_xcomponentCallback.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
    g_xcomponentCallback.DispatchTouchEvent = nullptr; // 手势走 ArkTS，转调相机接口
    OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_xcomponentCallback);
    BambuMqtt::addLog("renderer: xcomponent registered");
    return true;
}

// ArkTS 在 XComponent onLoad 时调用（确保 XComponent 属性已注入）
static napi_value RendererAttach(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_get_boolean(env, TryRegisterXComponent(env), &result);
    return result;
}

static float GetNumArg(napi_env env, napi_value arg)
{
    double v = 0;
    napi_get_value_double(env, arg, &v);
    return static_cast<float>(v);
}

static napi_value RendererRotate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 2) {
        BambuRenderer::rotate(GetNumArg(env, args[0]), GetNumArg(env, args[1]));
    }
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value RendererZoom(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        BambuRenderer::zoom(GetNumArg(env, args[0]));
    }
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value RendererPan(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 2) {
        BambuRenderer::pan(GetNumArg(env, args[0]), GetNumArg(env, args[1]));
    }
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value RendererResetView(napi_env env, napi_callback_info info)
{
    (void)info;
    BambuRenderer::resetView();
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

// 切片路径（3D 预览）：verts = Float32Array [x,y,z]*n，batches = Int32Array [slot,first,count]*m
// 顶点已按颜色分组连续排布，原生侧每批一次 GL_LINES（无需逐顶点颜色属性）
static napi_value RendererSetGcode(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::vector<float> verts;
    std::vector<int>   batches;

    if (argc >= 1 && args[0] != nullptr) {
        napi_typedarray_type type = napi_int8_array;
        size_t length = 0;
        void* data = nullptr;
        napi_value ab = nullptr;
        size_t off = 0;
        if (napi_get_typedarray_info(env, args[0], &type, &length, &data, &ab, &off) == napi_ok &&
            data != nullptr && length > 0 && type == napi_float32_array) {
            const float* p = static_cast<const float*>(data);
            verts.assign(p, p + length);
        }
    }
    if (argc >= 2 && args[1] != nullptr) {
        napi_typedarray_type type = napi_int8_array;
        size_t length = 0;
        void* data = nullptr;
        napi_value ab = nullptr;
        size_t off = 0;
        if (napi_get_typedarray_info(env, args[1], &type, &length, &data, &ab, &off) == napi_ok &&
            data != nullptr && length > 0 && type == napi_int32_array) {
            const int* p = static_cast<const int*>(data);
            batches.assign(p, p + length);
        }
    }
    BambuRenderer::stageGcodeLines(verts, batches);
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value RendererSetGcodeMode(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool on = false;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &on);
    }
    BambuRenderer::setGcodeMode(on);
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value RendererClearGcode(napi_env env, napi_callback_info info)
{
    (void)info;
    BambuRenderer::clearGcodeLines();
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

// 模型加载（异步：worker 解析 → JS 线程上传 GPU + 自动取景）
struct ModelLoadCtx {
    napi_async_work work = nullptr;
    napi_ref cb = nullptr;
    std::string path;
    std::string resultJson;
};

static void ModelLoadExecute(napi_env env, void* data)
{
    (void)env;
    auto* ctx = static_cast<ModelLoadCtx*>(data);
    BambuRenderer::ModelInfo info;
    // STL/OBJ/STEP 统一入口（bambu_mesh 按扩展名分发，STEP 走 OCCT）
    BambuRenderer::parseModelFile(ctx->path, info);
    char buf[256];
    if (info.ok) {
        snprintf(buf, sizeof(buf),
                 "{\"ok\":true,\"triangles\":%d,\"sizeX\":%.2f,\"sizeY\":%.2f,\"sizeZ\":%.2f}",
                 info.triangles, info.sizeX, info.sizeY, info.sizeZ);
    } else {
        snprintf(buf, sizeof(buf), "{\"ok\":false,\"error\":\"%s\"}", info.error.c_str());
    }
    ctx->resultJson = buf;
}

static void ModelLoadComplete(napi_env env, napi_status status, void* data)
{
    auto* ctx = static_cast<ModelLoadCtx*>(data);
    // Complete 运行在 JS 线程 = EGL 上下文线程，可直接上传 GPU
    if (BambuRenderer::uploadStagedModel()) {
        BambuRenderer::resetView();
    }
    napi_value callback = nullptr;
    napi_get_reference_value(env, ctx->cb, &callback);
    if (callback != nullptr) {
        napi_value result = nullptr;
        napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &result);
        napi_value global = nullptr;
        napi_get_global(env, &global);
        napi_value argv[1] = { result };
        napi_call_function(env, global, callback, 1, argv, nullptr);
    }
    napi_delete_reference(env, ctx->cb);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value RendererLoadModel(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, nullptr, "need (path, callback)");
        return nullptr;
    }
    auto* ctx = new ModelLoadCtx();
    ctx->path = GetStringArg(env, args[0]);
    napi_create_reference(env, args[1], 1, &ctx->cb);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "ModelLoad", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ModelLoadExecute, ModelLoadComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return nullptr;
}

// ---------------------------------------------------------------------------
// 网格解析（3D 预览页专用）：C++ 只解析出平面数组，渲染完全在 ArkTS ArkGraphics3D。
// 回调对象：{ info: string(JSON), positions: ArrayBuffer, normals: ArrayBuffer, indices: ArrayBuffer }
// positions/normals 为 Float32 唯一顶点数组（Z 轴向上，已居中贴板）；indices 为 Uint32 面索引
// ---------------------------------------------------------------------------
struct MeshParseCtx {
    napi_async_work work = nullptr;
    napi_ref cb = nullptr;
    std::string path;
    std::string resultJson;
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;
};

static void MeshParseExecute(napi_env env, void* data)
{
    (void)env;
    auto* ctx = static_cast<MeshParseCtx*>(data);
    BambuMesh::MeshArrays arr;
    BambuMesh::parseFile(ctx->path, arr);
    ctx->positions = std::move(arr.positions);
    ctx->normals = std::move(arr.normals);
    ctx->indices = std::move(arr.indices);
    char buf[512];
    if (arr.ok) {
        // 报「原始真实值」：大模型会在 C++ 侧抽稀出一份预览副本（防 ArkTS 堆爆掉），
        // 但界面要显示的是模型真实的面数与尺寸，切片用的也始终是原始文件。
        const bool hasOrig = (arr.origTriangles > 0);
        const int tris = hasOrig ? arr.origTriangles : arr.triangles;
        const float sx = hasOrig ? arr.origSize[0] : arr.size[0];
        const float sy = hasOrig ? arr.origSize[1] : arr.size[1];
        const float sz = hasOrig ? arr.origSize[2] : arr.size[2];
        snprintf(buf, sizeof(buf),
                 "{\"ok\":true,\"triangles\":%d,\"sizeX\":%.2f,\"sizeY\":%.2f,\"sizeZ\":%.2f,"
                 "\"overhangRatioPct\":%.3f,\"overhangAngleDeg\":%.1f,\"overhangAreaPctThreshold\":%.3f,"
                 "\"needsSupport\":%s}",
                 tris, sx, sy, sz, arr.overhangRatioPct, arr.overhangAngleDeg,
                 arr.overhangAreaPctThreshold, arr.needsSupport ? "true" : "false");
    } else {
        snprintf(buf, sizeof(buf), "{\"ok\":false,\"error\":\"%s\"}",
                 arr.error.empty() ? "解析失败" : arr.error.c_str());
    }
    ctx->resultJson = buf;
}

static void MeshParseComplete(napi_env env, napi_status status, void* data)
{
    auto* ctx = static_cast<MeshParseCtx*>(data);
    napi_value callback = nullptr;
    napi_get_reference_value(env, ctx->cb, &callback);
    if (callback != nullptr) {
        napi_value result = nullptr;
        napi_create_object(env, &result);
        napi_value infoStr = nullptr;
        napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &infoStr);
        napi_set_named_property(env, result, "info", infoStr);

        napi_value posAb = nullptr;
        void* posData = nullptr;
        napi_create_arraybuffer(env, ctx->positions.size() * sizeof(float), &posData, &posAb);
        if (!ctx->positions.empty() && posData != nullptr) {
            memcpy(posData, ctx->positions.data(), ctx->positions.size() * sizeof(float));
        }
        napi_set_named_property(env, result, "positions", posAb);

        napi_value normAb = nullptr;
        void* normData = nullptr;
        napi_create_arraybuffer(env, ctx->normals.size() * sizeof(float), &normData, &normAb);
        if (!ctx->normals.empty() && normData != nullptr) {
            memcpy(normData, ctx->normals.data(), ctx->normals.size() * sizeof(float));
        }
        napi_set_named_property(env, result, "normals", normAb);

        // 唯一顶点索引（Uint32；每 3 个 = 一个三角面）
        napi_value idxAb = nullptr;
        void* idxData = nullptr;
        napi_create_arraybuffer(env, ctx->indices.size() * sizeof(uint32_t), &idxData, &idxAb);
        if (!ctx->indices.empty() && idxData != nullptr) {
            memcpy(idxData, ctx->indices.data(), ctx->indices.size() * sizeof(uint32_t));
        }
        napi_set_named_property(env, result, "indices", idxAb);

        napi_value global = nullptr;
        napi_get_global(env, &global);
        napi_value argv[1] = { result };
        napi_call_function(env, global, callback, 1, argv, nullptr);
    }
    napi_delete_reference(env, ctx->cb);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value MeshParse(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, nullptr, "need (path, callback)");
        return nullptr;
    }
    auto* ctx = new MeshParseCtx();
    ctx->path = GetStringArg(env, args[0]);
    napi_create_reference(env, args[1], 1, &ctx->cb);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "MeshParse", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, MeshParseExecute, MeshParseComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return nullptr;
}

// ---------------------------------------------------------------------------
// 网格解析（带进度）：meshParse 的进度版。
//
// 为什么用 napi_threadsafe_function(TSFN) 而不是 async_work：async_work 的 Complete 只回调
// 一次（只够 onDone），而进度是「多次回调」；且回调必须回到 JS 线程执行（worker 线程上碰
// napi_env 是非法的）。TSFN 正好是「worker 多次投递 → JS 线程多次执行」的机制，两者用途不同。
//
//   worker 线程：parseFile(..., progress) → 每条进度 napi_call_threadsafe_function()
//   JS  主线程：call_js_cb → 调 onProgress(json)
//   worker 结束再投一条「收尾项」（阻塞投递，FIFO 保证排在所有进度之后）→ JS 主线程上
//   补发「上传几何」阶段进度 + 调 onDone(结果对象)，随后释放 TSFN。
//
// 生命周期安全（保证不会在 napi_env 失效之后被调用）：
//   1) TSFN 由运行时托管：env 销毁时运行时会把 TSFN 置为 closing，之后 call_js_cb 不再被调用；
//      worker 侧每次投递都检查返回值，非 napi_ok 就地回收负载，绝不在 worker 上调用任何 napi_*。
//   2) 负载 ProgressItem 在 JS 线程的 call_js_cb 里 delete；投递失败时在 worker 线程 delete，
//      不泄漏。
//   3) ctx 用原子引用计数：async_work 的 Complete 一份 + TSFN 的 finalize 一份，谁最后谁
//      delete —— 无论「Complete 先跑」还是「finalize 先跑」都不会 use-after-free。
//   4) onDone 只调一次（doneSent 原子标志）；TSFN 建失败时由 Complete 兜底收尾，
//      保证「onDone 一定会到」。
// ---------------------------------------------------------------------------

// 一条待派发的负载：kind 0 = 进度，1 = 收尾（worker 已结束）
struct ProgressItem {
    int kind = 0;
    std::string json;
};

struct MeshProgressCtx {
    napi_env env = nullptr;                     // JS 主线程 env
    napi_async_work work = nullptr;
    napi_threadsafe_function tsfn = nullptr;
    napi_ref onProgressRef = nullptr;           // onProgress（主线程直接调用用；TSFN 内部另持一份）
    napi_ref onDoneRef = nullptr;               // onDone
    std::string path;
    std::string resultJson;
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;
    std::atomic<int> refs{2};                   // async_work Complete + TSFN finalize
    std::atomic<bool> stage3Sent{false};        // stage 3 那几条进度只发一次
    std::atomic<bool> doneSent{false};          // onDone 只调一次
};

std::string FmtCount(long long v)
{
    bool neg = v < 0;
    unsigned long long u = neg ? static_cast<unsigned long long>(-v) : static_cast<unsigned long long>(v);
    std::string s = std::to_string(u);
    for (int i = static_cast<int>(s.size()) - 3; i > 0; i -= 3) { s.insert(static_cast<size_t>(i), ","); }
    return neg ? ("-" + s) : s;
}

std::string ProgressJson(int stage, int pct, const std::string& msg)
{
    if (pct < 0) { pct = 0; } else if (pct > 100) { pct = 100; }
    std::string out = "{\"stage\":" + std::to_string(stage) +
                      ",\"pct\":" + std::to_string(pct) + ",\"msg\":\"";
    for (char c : msg) {
        if (c == '"' || c == '\\') { out += '\\'; }
        out += c;
    }
    out += "\"}";
    return out;
}

// ---- 逐跳插桩（诊断「载入卡在法线完成」）------------------------------------
// 统一日志前缀：「hopN <label> t=<ms>」，t 为进程内单调毫秒（steady 时钟，跨线程一致可比）。
// 后半段一律用 %{public}d / %{public}s 拼接，避免依赖 hilog 对 64 位长度修饰符的支持。
std::string LoadDlgNowMsStr()
{
    return std::to_string(std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now().time_since_epoch()).count());
}

std::string LoadDlgStamp(const char* hop, const char* label)
{
    return std::string("hop") + hop + " " + label + " t=" + LoadDlgNowMsStr();
}

// 结果对象（与 meshParse 的 MeshParseResult 完全同构）。
// 关键点：几何一律是「一次性分配 + memcpy」的扁平缓冲（napi_create_arraybuffer + 直接写指针），
// 绝不在循环里逐元素调 napi_set_element —— 千万级元素那样做会把 JS 线程钉死几十秒。
// 另外：每个缓冲拷完立刻释放 worker 搬进来的那份源缓冲，同一份几何不再同时驻留两份
// （大模型下这是几百 MB 的峰值内存，直接决定会不会被 GC 抖动 / OOM 拖成「假死」）。
// 注意：这里不再 emit 进度 —— stage 3 的几条进度已由 EmitStage3Progress 在「上一次独立任务」里
// 发完了，本函数只做 memcpy，好让调用它的那一次事件循环尽量短。
napi_value MakeMeshResultObject(napi_env env, MeshProgressCtx* ctx)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value infoStr = nullptr;
    napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &infoStr);
    napi_set_named_property(env, result, "info", infoStr);

    auto setAb = [&](const char* key, const void* data, size_t bytes) {
        void* p = nullptr;
        napi_value ab = nullptr;
        napi_create_arraybuffer(env, bytes, &p, &ab);
        if (bytes > 0 && p != nullptr) { memcpy(p, data, bytes); }
        napi_set_named_property(env, result, key, ab);
    };
    setAb("positions", ctx->positions.data(), ctx->positions.size() * sizeof(float));
    setAb("normals", ctx->normals.data(), ctx->normals.size() * sizeof(float));
    setAb("indices", ctx->indices.data(), ctx->indices.size() * sizeof(uint32_t));

    // 拷完立即释放源缓冲：几何全程只搬一次，之后不再留第二份
    std::vector<float>().swap(ctx->positions);
    std::vector<float>().swap(ctx->normals);
    std::vector<uint32_t>().swap(ctx->indices);
    return result;
}


// 调用一个 JS 函数并【强制检查】返回值与 pending exception。
// 为什么必须检查：napi_call_function 在 JS 侧抛异常时返回 napi_pending_exception，且异常会挂在
// env 上。若既不检查也不清，后续 napi_* 调用都会被视为「异常进行中」而失败 —— 表现就是
// 「什么都没发生」（弹窗不动、也不报错）。这里把异常取出、转成文本 hilog 出来，绝不静默忽略。
bool CallJsChecked(napi_env env, napi_value global, napi_value fn,
                   size_t argc, napi_value* argv, const char* what)
{
    napi_status st = napi_call_function(env, global, fn, argc, argv, nullptr);
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (st == napi_ok && !pending) { return true; }

    std::string desc = "(no message)";
    if (pending) {
        napi_value exc = nullptr;
        if (napi_get_and_clear_last_exception(env, &exc) == napi_ok && exc != nullptr) {
            napi_value s = nullptr;
            if (napi_coerce_to_string(env, exc, &s) == napi_ok && s != nullptr) {
                size_t len = 0;
                if (napi_get_value_string_utf8(env, s, nullptr, 0, &len) == napi_ok) {
                    std::vector<char> buf(len + 1, 0);
                    napi_get_value_string_utf8(env, s, buf.data(), buf.size(), &len);
                    desc.assign(buf.data(), len);
                    if (desc.size() > 500) { desc.resize(500); desc += "…"; }
                }
            }
        }
    }
    OH_LOG_ERROR(LOG_APP, "LoadDlg %{public}s callback=%{public}s status=%{public}d pending=%{public}d err=%{public}s",
                 LoadDlgStamp("err", "js-call-failed").c_str(), what, static_cast<int>(st),
                 pending ? 1 : 0, desc.c_str());
    return false;
}

// stage 3「上传几何」的进度：计数全部取自 ctx 里真实的几何尺寸（不编造）。
// 这几条 emit 很轻（只是调 onProgress），所以它们所在的那一次 TSFN 任务会很快结束 ——
// 事件循环随即有机会渲染，用户先看到「上传几何」在动，再进入 onDone 的重活。
void EmitStage3Progress(napi_env env, napi_value global, napi_value jsProgress, MeshProgressCtx* ctx)
{
    const int verts = static_cast<int>(ctx->positions.size() / 3);
    const int tris = static_cast<int>(ctx->indices.size() / 3);
    auto emit = [&](int pct, const std::string& m) -> bool {
        const std::string j = ProgressJson(3, pct, m);
        napi_value s = nullptr;
        napi_create_string_utf8(env, j.c_str(), NAPI_AUTO_LENGTH, &s);
        napi_value a[1] = { s };
        return CallJsChecked(env, global, jsProgress, 1, a, "onProgress(stage3)");
    };
    // hop5：第一条 stage 3 emit 之前 —— 真机若停在这里，说明卡点在本任务之前（拿到收尾项之前）
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s verts=%{public}d tris=%{public}d",
                LoadDlgStamp("5", "stage3-first-emit-before").c_str(), verts, tris);

    emit(20, "打包几何数据 · " + FmtCount(verts) + " 顶点 / " + FmtCount(tris) + " 三角面");
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s", LoadDlgStamp("6", "emit-20-打包几何数据-ok").c_str());
    emit(40, "拷贝顶点缓冲 · " + FmtCount(verts) + " 顶点");
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s", LoadDlgStamp("6", "emit-40-拷贝顶点缓冲-ok").c_str());
    emit(55, "拷贝法线缓冲 · " + FmtCount(verts) + " 顶点");
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s", LoadDlgStamp("6", "emit-55-拷贝法线缓冲-ok").c_str());
    emit(70, "拷贝索引缓冲 · " + FmtCount(tris) + " 三角面");
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s", LoadDlgStamp("6", "emit-70-拷贝索引缓冲-ok").c_str());
}

// 收尾重活：建结果对象（真正的 memcpy）+ 调 onDone。只在 JS 主线程、且只执行一次。
void BuildAndCallDone(napi_env env, napi_value global, MeshProgressCtx* ctx)
{
    napi_value result = MakeMeshResultObject(env, ctx);

    napi_value onDone = nullptr;
    if (ctx->onDoneRef != nullptr) { napi_get_reference_value(env, ctx->onDoneRef, &onDone); }
    if (onDone != nullptr) {
        napi_value argv[1] = { result };
        OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s", LoadDlgStamp("10", "onDone-before").c_str());
        CallJsChecked(env, global, onDone, 1, argv, "onDone");
        OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s", LoadDlgStamp("10", "onDone-after").c_str());
    } else {
        // onDone 取不到 = 收尾一定失败，必须显式报出来（此前正是这种「悄悄什么都不做」）
        OH_LOG_ERROR(LOG_APP, "LoadDlg %{public}s onDone=null onDoneRef=%{public}d",
                     LoadDlgStamp("10", "onDone-missing").c_str(), ctx->onDoneRef != nullptr ? 1 : 0);
    }
    // napi_ref 必须在 JS 线程释放
    if (ctx->onDoneRef != nullptr) { napi_delete_reference(env, ctx->onDoneRef); ctx->onDoneRef = nullptr; }
    if (ctx->onProgressRef != nullptr) { napi_delete_reference(env, ctx->onProgressRef); ctx->onProgressRef = nullptr; }
}

// JS 主线程执行：
//   kind=0 —— 普通进度 → onProgress；
//   kind=1 —— stage 3 那几条进度（轻，独立任务，先于 onDone 渲染）；
//   kind=2 —— 建结果对象 + 调 onDone（重）。
// 拆成两个独立任务（而不是在一次 call_js_cb 里连做）就是为了让 UI 至少能先画出 stage 3 的日志。
void MeshProgressCallJs(napi_env env, napi_value jsProgress, void* context, void* data)
{
    auto* ctx = static_cast<MeshProgressCtx*>(context);
    ProgressItem* item = static_cast<ProgressItem*>(data);
    if (item == nullptr) { return; }      // TSFN 关闭信号：此后不会再有任何回调
    if (env == nullptr || jsProgress == nullptr || ctx == nullptr) { delete item; return; }

    // hop9：进入 call_js_cb（区分进度项 / stage3 项 / 收尾项）
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s kind=%{public}d",
                LoadDlgStamp("9", "calljs-enter").c_str(), item->kind);

    napi_value global = nullptr;
    napi_get_global(env, &global);

    if (item->kind == 0) {
        napi_value s = nullptr;
        napi_create_string_utf8(env, item->json.c_str(), NAPI_AUTO_LENGTH, &s);
        napi_value argv[1] = { s };
        CallJsChecked(env, global, jsProgress, 1, argv, "onProgress");
    } else if (item->kind == 1) {
        // 只发 stage 3 进度（不拷贝）；本任务很快结束 → 事件循环即可渲染
        if (!ctx->stage3Sent.exchange(true)) { EmitStage3Progress(env, global, jsProgress, ctx); }
    } else {
        if (!ctx->doneSent.exchange(true)) { BuildAndCallDone(env, global, ctx); }
    }
    delete item;
}

// TSFN 销毁时的 finalize：只做引用计数收尾（env 可能已经失效，不能碰它）
void MeshProgressFinalize(napi_env env, void* data, void* hint)
{
    (void)env; (void)hint;
    auto* ctx = static_cast<MeshProgressCtx*>(data);
    if (ctx == nullptr) { return; }
    if (--ctx->refs == 0) { delete ctx; }
}

void MeshProgressExecute(napi_env env, void* data)
{
    (void)env;   // worker 线程：绝不用 env
    auto* ctx = static_cast<MeshProgressCtx*>(data);
    BambuMesh::MeshArrays arr;
    // parseFile（含 STEP/OCCT）理论上不抛，但一旦抛，若不管就会让 worker 直接崩掉、
    // 收尾项永远发不出（弹窗只能等到天荒地老）。这里兜住，保证任何路径都会走到下面的收尾投递。
    try {
        BambuMesh::parseFile(ctx->path, arr, [ctx](int stage, int pct, const char* msg) {
            if (ctx->tsfn == nullptr) { return; }
            auto* item = new ProgressItem();
            item->kind = 0;
            item->json = ProgressJson(stage, pct, msg);
            // 非阻塞投递：队列关闭（env 已销毁/已释放）时立即返回非 ok，就地回收负载
            if (napi_call_threadsafe_function(ctx->tsfn, item, napi_tsfn_nonblocking) != napi_ok) {
                delete item;
            }
        });
    } catch (const std::exception& e) {
        arr.ok = false;
        arr.error = std::string("解析异常: ") + e.what();
    } catch (...) {
        arr.ok = false;
        arr.error = "解析异常";
    }

    // hop3：parseFile 已返回（成功 / 失败 / 抛异常都在这里汇合），几何尚未搬进 ctx
    {
        const std::string stamp = LoadDlgStamp("3", "worker-parse-return");
        OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s ok=%{public}d pos=%{public}d idx=%{public}d err=%{public}s",
                    stamp.c_str(), arr.ok ? 1 : 0, static_cast<int>(arr.positions.size()),
                    static_cast<int>(arr.indices.size()), arr.error.empty() ? "-" : arr.error.c_str());
    }

    if (!arr.ok) {
        // 失败/异常路径：几何无意义，清空，避免把半成品搬进 ctx 再拷成 ArrayBuffer
        arr.positions.clear();
        arr.normals.clear();
        arr.indices.clear();
    }

    ctx->positions = std::move(arr.positions);
    ctx->normals = std::move(arr.normals);
    ctx->indices = std::move(arr.indices);

    // hop4：几何已就位（三个 std::move 都是 O(1)，不会在这里耗时间）
    {
        const std::string stamp = LoadDlgStamp("4", "worker-geom-ready");
        OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s verts=%{public}d tris=%{public}d",
                    stamp.c_str(), static_cast<int>(ctx->positions.size() / 3),
                    static_cast<int>(ctx->indices.size() / 3));
    }

    char buf[512];
    if (arr.ok) {
        // 报「原始真实值」：大模型会在 C++ 侧抽稀出一份预览副本，但界面要显示模型真实的面数与尺寸
        const bool hasOrig = (arr.origTriangles > 0);
        const int tris = hasOrig ? arr.origTriangles : arr.triangles;
        const float sx = hasOrig ? arr.origSize[0] : arr.size[0];
        const float sy = hasOrig ? arr.origSize[1] : arr.size[1];
        const float sz = hasOrig ? arr.origSize[2] : arr.size[2];
        snprintf(buf, sizeof(buf),
                 "{\"ok\":true,\"triangles\":%d,\"sizeX\":%.2f,\"sizeY\":%.2f,\"sizeZ\":%.2f,"
                 "\"unitScale\":%.0f,"
                 "\"origTriangles\":%d,\"weldInVerts\":%d,\"uniqueVerts\":%d,\"creaseSplit\":%d,\"outVerts\":%d,"
                 "\"overhangRatioPct\":%.3f,\"overhangAngleDeg\":%.1f,\"overhangAreaPctThreshold\":%.3f,"
                 "\"needsSupport\":%s}",
                 tris, sx, sy, sz, static_cast<double>(arr.unitScale),
                 arr.origTriangles, arr.weldInVerts, arr.uniqueVerts,
                 arr.creaseSplit, arr.outVerts,
                 arr.overhangRatioPct, arr.overhangAngleDeg,
                 arr.overhangAreaPctThreshold, arr.needsSupport ? "true" : "false");
    } else {
        snprintf(buf, sizeof(buf), "{\"ok\":false,\"error\":\"%s\"}",
                 arr.error.empty() ? "解析失败" : arr.error.c_str());
    }
    ctx->resultJson = buf;

    // hop7：收尾拆成两次独立 TSFN 投递（Task 2 的关键）。
    //   kind=1 —— 只发 stage 3 的进度（轻）；
    //   kind=2 —— 建结果对象（真正的 memcpy）+ 调 onDone（重）。
    // 两次投递在 TSFN 队列里是两个独立任务，中间事件循环有机会渲染 —— 于是「法线完成」之后
    // 用户能立刻看到「上传几何」在走，而不是卡在法线完成不动。
    // 都用非阻塞投递：worker 线程绝不为投递而阻塞；万一投递失败，Complete 的兜底会补上。
    auto post = [&](int kind, const char* label) {
        const std::string before = LoadDlgStamp("7", label);
        OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s 投递前 kind=%{public}d tsfn=%{public}d",
                    before.c_str(), kind, ctx->tsfn != nullptr ? 1 : 0);
        if (ctx->tsfn == nullptr) { return; }
        auto* item = new ProgressItem();
        item->kind = kind;
        napi_status st = napi_call_threadsafe_function(ctx->tsfn, item, napi_tsfn_nonblocking);
        if (st != napi_ok) { delete item; }
        const std::string after = LoadDlgStamp("7", label);
        OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s 投递后 kind=%{public}d status=%{public}d",
                    after.c_str(), kind, static_cast<int>(st));
    };
    post(1, "stage3-progress");
    post(2, "onDone");
}

void MeshProgressComplete(napi_env env, napi_status status, void* data)
{
    (void)status;
    auto* ctx = static_cast<MeshProgressCtx*>(data);
    // hop8：进入 async_work 的 Complete（此时 worker 已结束、TSFN 即将释放）
    OH_LOG_INFO(LOG_APP, "LoadDlg %{public}s status=%{public}d stage3Sent=%{public}d doneSent=%{public}d",
                LoadDlgStamp("8", "complete-enter").c_str(), static_cast<int>(status),
                ctx->stage3Sent.load() ? 1 : 0, ctx->doneSent.load() ? 1 : 0);

    // 兜底：TSFN 没建成 / 收尾项投递失败 / 收尾项排在 Complete 之后时，收尾可能永远不落地，
    // 这里补上 —— 必须「stage 3 进度」与「onDone」两件都补，缺一个都会让界面卡住。
    // 两个原子标志保证各自只执行一次：真正的收尾项若稍后到达，只会被跳过，绝不会重复调 onDone。
    napi_value progressFn = nullptr;
    if (ctx->onProgressRef != nullptr) { napi_get_reference_value(env, ctx->onProgressRef, &progressFn); }
    napi_value global = nullptr;
    napi_get_global(env, &global);
    if (progressFn != nullptr && !ctx->stage3Sent.exchange(true)) {
        EmitStage3Progress(env, global, progressFn, ctx);
    }
    if (!ctx->doneSent.exchange(true)) {
        BuildAndCallDone(env, global, ctx);
    }
    // 释放 TSFN：worker 线程计数归零 → 队列里剩余项会在 finalize 之前派发完
    if (ctx->tsfn != nullptr) {
        napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);
        ctx->tsfn = nullptr;
    }
    napi_delete_async_work(env, ctx->work);
    if (--ctx->refs == 0) { delete ctx; }
}

static napi_value MeshParseWithProgress(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_error(env, nullptr, "need (path, onProgress, onDone)");
        return nullptr;
    }
    auto* ctx = new MeshProgressCtx();
    ctx->env = env;
    ctx->path = GetStringArg(env, args[0]);
    napi_create_reference(env, args[1], 1, &ctx->onProgressRef);
    napi_create_reference(env, args[2], 1, &ctx->onDoneRef);

    napi_value resName = nullptr;
    napi_create_string_utf8(env, "MeshParseProgress", NAPI_AUTO_LENGTH, &resName);
    napi_status st = napi_create_threadsafe_function(
        env, args[1], nullptr, resName,
        0 /* 队列不设上限：进度条数很少 */, 1 /* 初始线程数 = worker 一个 */,
        ctx, MeshProgressFinalize, ctx, MeshProgressCallJs, &ctx->tsfn);
    if (st != napi_ok) {
        ctx->tsfn = nullptr;
        ctx->refs.store(1);   // 没有 TSFN：只剩 async_work Complete 这一份
    }

    napi_value workName = nullptr;
    napi_create_string_utf8(env, "MeshParseProgressWork", NAPI_AUTO_LENGTH, &workName);
    napi_create_async_work(env, nullptr, workName, MeshProgressExecute, MeshProgressComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return nullptr;
}

// ---------------------------------------------------------------------------
// 切片进度（异步 + TSFN）：与 MeshParseWithProgress 完全同一套机制。
//   worker 线程：slicer_slice_with_progress(..., progress) → 每条进度经 TSFN 投递到 JS 线程；
//               worker 结束再投一条收尾项（kind=1）→ JS 线程上调 onDone(resultJson)。
//   * CallJsChecked：检查返回值与 pending exception，绝不静默忽略；
//   * non-blocking 投递：worker 绝不为投递阻塞，失败就地回收负载；
//   * onDone 只调一次（doneSent 原子标志）；TSFN 建失败由 Complete 兜底，保证 onDone 一定到。
// ---------------------------------------------------------------------------
struct SliceProgressCtx {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_threadsafe_function tsfn = nullptr;
    napi_ref onProgressRef = nullptr;
    napi_ref onDoneRef = nullptr;
    std::string inputPath;
    std::string paramsJson;
    std::string outputPath;
    std::string resultJson;
    std::atomic<int> refs{2};            // async_work Complete + TSFN finalize
    std::atomic<bool> doneSent{false};   // onDone 只调一次
};

void SliceProgressCallJs(napi_env env, napi_value jsProgress, void* context, void* data)
{
    auto* ctx = static_cast<SliceProgressCtx*>(context);
    ProgressItem* item = static_cast<ProgressItem*>(data);
    if (item == nullptr) { return; }      // TSFN 关闭信号
    if (env == nullptr || jsProgress == nullptr || ctx == nullptr) { delete item; return; }

    napi_value global = nullptr;
    napi_get_global(env, &global);

    if (item->kind == 0) {
        napi_value s = nullptr;
        napi_create_string_utf8(env, item->json.c_str(), NAPI_AUTO_LENGTH, &s);
        napi_value argv[1] = { s };
        CallJsChecked(env, global, jsProgress, 1, argv, "onProgress(slice)");
    } else if (!ctx->doneSent.exchange(true)) {
        napi_value onDone = nullptr;
        if (ctx->onDoneRef != nullptr) { napi_get_reference_value(env, ctx->onDoneRef, &onDone); }
        if (onDone != nullptr) {
            napi_value s = nullptr;
            napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &s);
            napi_value argv[1] = { s };
            CallJsChecked(env, global, onDone, 1, argv, "onDone(slice)");
        } else {
            OH_LOG_ERROR(LOG_APP, "SliceDlg onDone=null");
        }
        if (ctx->onDoneRef != nullptr) { napi_delete_reference(env, ctx->onDoneRef); ctx->onDoneRef = nullptr; }
        if (ctx->onProgressRef != nullptr) { napi_delete_reference(env, ctx->onProgressRef); ctx->onProgressRef = nullptr; }
    }
    delete item;
}

void SliceProgressFinalize(napi_env env, void* data, void* hint)
{
    (void)env; (void)hint;
    auto* ctx = static_cast<SliceProgressCtx*>(data);
    if (ctx == nullptr) { return; }
    if (--ctx->refs == 0) { delete ctx; }
}

void SliceProgressExecute(napi_env env, void* data)
{
    (void)env;   // worker 线程：绝不用 env
    auto* ctx = static_cast<SliceProgressCtx*>(data);
    try {
        ctx->resultJson = Slic3r::ohos::slicer_slice_with_progress(
            ctx->inputPath, ctx->paramsJson, ctx->outputPath,
            [ctx](int stage, int pct, const std::string& msg) {
                if (ctx->tsfn == nullptr) { return; }
                auto* item = new ProgressItem();
                item->kind = 0;
                item->json = ProgressJson(stage, pct, msg);
                if (napi_call_threadsafe_function(ctx->tsfn, item, napi_tsfn_nonblocking) != napi_ok) {
                    delete item;
                }
            });
    } catch (const std::exception& e) {
        ctx->resultJson = std::string("{\"ok\":false,\"status\":\"error\",\"message\":\"切片异常: ")
                          + e.what() + "\"}";
    } catch (...) {
        ctx->resultJson = "{\"ok\":false,\"status\":\"error\",\"message\":\"切片异常: 未知错误\"}";
    }

    // 收尾项（阻塞语义由 FIFO 保证排在所有进度之后）→ JS 线程上调 onDone，保证一定被调用一次。
    if (ctx->tsfn != nullptr) {
        auto* item = new ProgressItem();
        item->kind = 1;
        if (napi_call_threadsafe_function(ctx->tsfn, item, napi_tsfn_nonblocking) != napi_ok) { delete item; }
    }
}

void SliceProgressComplete(napi_env env, napi_status status, void* data)
{
    (void)status;
    auto* ctx = static_cast<SliceProgressCtx*>(data);
    // 兜底：TSFN 没建成 / 收尾项投递失败 / 收尾项排在 Complete 之后时，这里补一次 onDone。
    if (!ctx->doneSent.exchange(true)) {
        napi_value global = nullptr;
        napi_get_global(env, &global);
        napi_value onDone = nullptr;
        if (ctx->onDoneRef != nullptr) { napi_get_reference_value(env, ctx->onDoneRef, &onDone); }
        if (onDone != nullptr) {
            napi_value s = nullptr;
            napi_create_string_utf8(env, ctx->resultJson.c_str(), NAPI_AUTO_LENGTH, &s);
            napi_value argv[1] = { s };
            CallJsChecked(env, global, onDone, 1, argv, "onDone(slice,complete)");
        }
        if (ctx->onDoneRef != nullptr) { napi_delete_reference(env, ctx->onDoneRef); ctx->onDoneRef = nullptr; }
        if (ctx->onProgressRef != nullptr) { napi_delete_reference(env, ctx->onProgressRef); ctx->onProgressRef = nullptr; }
    }
    if (ctx->tsfn != nullptr) {
        napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);
        ctx->tsfn = nullptr;
    }
    napi_delete_async_work(env, ctx->work);
    if (--ctx->refs == 0) { delete ctx; }
}

static napi_value SlicerSliceWithProgress(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_error(env, nullptr, "need (inputPath, paramsJson, outputPath, onProgress, onDone)");
        return nullptr;
    }
    auto* ctx = new SliceProgressCtx();
    ctx->env = env;
    ctx->inputPath  = GetStringArg(env, args[0]);
    ctx->paramsJson = GetStringArg(env, args[1]);
    ctx->outputPath = GetStringArg(env, args[2]);
    napi_create_reference(env, args[3], 1, &ctx->onProgressRef);
    napi_create_reference(env, args[4], 1, &ctx->onDoneRef);

    napi_value resName = nullptr;
    napi_create_string_utf8(env, "SliceProgress", NAPI_AUTO_LENGTH, &resName);
    napi_status st = napi_create_threadsafe_function(
        env, args[3], nullptr, resName,
        0 /* 队列不设上限 */, 1 /* 初始线程数 = worker */,
        ctx, SliceProgressFinalize, ctx, SliceProgressCallJs, &ctx->tsfn);
    if (st != napi_ok) {
        ctx->tsfn = nullptr;
        ctx->refs.store(1);
    }

    napi_value workName = nullptr;
    napi_create_string_utf8(env, "SliceProgressWork", NAPI_AUTO_LENGTH, &workName);
    napi_create_async_work(env, nullptr, workName, SliceProgressExecute, SliceProgressComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return nullptr;
}

// 内置托盘网格（同步，编译期常量，真机必然可用）。
// 返回 { positions: ArrayBuffer, normals: ArrayBuffer, triangles: number }（Z 轴向上，X/Y 已居中）
static napi_value BedMesh(napi_env env, napi_callback_info info)
{
    BambuMesh::MeshArrays arr = BambuMesh::buildBedMesh();
    napi_value result = nullptr;
    napi_create_object(env, &result);

    void* pd = nullptr;
    napi_value pab = nullptr;
    napi_create_arraybuffer(env, arr.positions.size() * sizeof(float), &pd, &pab);
    if (pd != nullptr) {
        memcpy(pd, arr.positions.data(), arr.positions.size() * sizeof(float));
    }
    napi_set_named_property(env, result, "positions", pab);

    void* nd = nullptr;
    napi_value nab = nullptr;
    napi_create_arraybuffer(env, arr.normals.size() * sizeof(float), &nd, &nab);
    if (nd != nullptr) {
        memcpy(nd, arr.normals.data(), arr.normals.size() * sizeof(float));
    }
    napi_set_named_property(env, result, "normals", nab);

    napi_value t = nullptr;
    napi_create_int32(env, arr.triangles, &t);
    napi_set_named_property(env, result, "triangles", t);
    return result;
}

// 按机型返回对应的开源打印板网格（同步）。
// 入参 = 该机型的 bed_model 名（如 "bbl-3dp-H2D.stl"，取自 BBL 预设字段；也接受简写 "H2D"）。
// 返回 { ok, positions, normals, triangles, width, height }；未找到时 ok=false（调用方退回默认板）。
static napi_value BedMeshForModel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string bedModel = GetStringArg(env, args[0]);

    BambuMesh::MeshArrays arr;
    const bool ok = BambuMesh::buildBedMeshFor(bedModel, arr);

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value okv = nullptr;
    napi_get_boolean(env, ok, &okv);
    napi_set_named_property(env, result, "ok", okv);

    napi_value pab = nullptr;
    void* pd = nullptr;
    napi_create_arraybuffer(env, arr.positions.size() * sizeof(float), &pd, &pab);
    if (pd != nullptr && !arr.positions.empty())
        memcpy(pd, arr.positions.data(), arr.positions.size() * sizeof(float));
    napi_set_named_property(env, result, "positions", pab);

    napi_value nab = nullptr;
    void* nd = nullptr;
    napi_create_arraybuffer(env, arr.normals.size() * sizeof(float), &nd, &nab);
    if (nd != nullptr && !arr.normals.empty())
        memcpy(nd, arr.normals.data(), arr.normals.size() * sizeof(float));
    napi_set_named_property(env, result, "normals", nab);

    napi_value t = nullptr;
    napi_create_int32(env, arr.triangles, &t);
    napi_set_named_property(env, result, "triangles", t);

    // 板模型自身的包围盒尺寸（mm），渲染侧用它把板缩放到机型盘面尺寸
    napi_value wv = nullptr;
    napi_create_double(env, ok ? static_cast<double>(arr.size[0]) : 0.0, &wv);
    napi_set_named_property(env, result, "width", wv);
    napi_value hv = nullptr;
    napi_create_double(env, ok ? static_cast<double>(arr.size[1]) : 0.0, &hv);
    napi_set_named_property(env, result, "height", hv);

    // 板模型在【绝对床坐标】里的包围盒（mm）。渲染侧据此把 extruder_printable_area 等
    // 绝对床坐标映射到与板模型完全相同的坐标系（同一套 中心/缩放 映射），避免「区域坐标系
    // 与板模型坐标系不一致」导致的偏移。
    float bbMinX = 0.0f, bbMinY = 0.0f, bbMaxX = 0.0f, bbMaxY = 0.0f;
    const bool hasBb = ok && BambuMesh::bedModelBBox(bedModel, bbMinX, bbMinY, bbMaxX, bbMaxY);
    napi_value vminx = nullptr;
    napi_create_double(env, hasBb ? static_cast<double>(bbMinX) : 0.0, &vminx);
    napi_set_named_property(env, result, "bboxMinX", vminx);
    napi_value vminy = nullptr;
    napi_create_double(env, hasBb ? static_cast<double>(bbMinY) : 0.0, &vminy);
    napi_set_named_property(env, result, "bboxMinY", vminy);
    napi_value vmaxx = nullptr;
    napi_create_double(env, hasBb ? static_cast<double>(bbMaxX) : 0.0, &vmaxx);
    napi_set_named_property(env, result, "bboxMaxX", vmaxx);
    napi_value vmaxy = nullptr;
    napi_create_double(env, hasBb ? static_cast<double>(bbMaxY) : 0.0, &vmaxy);
    napi_set_named_property(env, result, "bboxMaxY", vmaxy);
    return result;
}

// 内置 logo 网格（同步，编译期常量）。
// 返回 { lightPositions, lightTriangles, darkPositions, darkTriangles }（Z 轴向上，X/Y 已居中）
static napi_value LogoMesh(napi_env env, napi_callback_info info)
{
    BambuMesh::MeshArrays light;
    BambuMesh::MeshArrays dark;
    BambuMesh::buildLogoMesh(light, dark);

    napi_value result = nullptr;
    napi_create_object(env, &result);

    auto setAb = [&](const char* key, const std::vector<float>& v) {
        void* d = nullptr;
        napi_value ab = nullptr;
        napi_create_arraybuffer(env, v.size() * sizeof(float), &d, &ab);
        if (d != nullptr) {
            memcpy(d, v.data(), v.size() * sizeof(float));
        }
        napi_set_named_property(env, result, key, ab);
    };
    auto setInt = [&](const char* key, int val) {
        napi_value n = nullptr;
        napi_create_int32(env, val, &n);
        napi_set_named_property(env, result, key, n);
    };

    setAb("lightPositions", light.positions);
    setInt("lightTriangles", light.triangles);
    setAb("darkPositions", dark.positions);
    setInt("darkTriangles", dark.triangles);
    return result;
}

// 对象级布尔（同步）：A/B 都是索引网格，返回 {result, positions, indices}。
// 大网格会阻塞调用线程数秒，ETS 侧用 setTimeout 让出一帧后再调。
static napi_value SlicerMeshBoolean(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::vector<float> a_pos, b_pos;
    std::vector<uint32_t> a_idx, b_idx;

    // 输入统一按 ArrayBuffer 读取（ETS 侧传 typedArray.buffer）。
    // 不能用 napi_get_typedarray_info 的 length：本机实测它回的是**字节数**而不是元素数
    //（Float32Array 19008 元素 → 回 76032），照元素复制会越界读到垃圾索引。
    // ArrayBuffer 的 byte_length 语义唯一，除以 4 即元素数。
    auto read_f32 = [&](napi_value v, std::vector<float>& out) {
        bool is_ab = false;
        if (napi_is_arraybuffer(env, v, &is_ab) != napi_ok || !is_ab) { return; }
        void* data = nullptr;
        size_t blen = 0;
        if (napi_get_arraybuffer_info(env, v, &data, &blen) != napi_ok || data == nullptr ||
            blen < sizeof(float) || (blen % sizeof(float)) != 0) {
            return;
        }
        const float* p = static_cast<const float*>(data);
        out.assign(p, p + blen / sizeof(float));
    };
    auto read_u32 = [&](napi_value v, std::vector<uint32_t>& out) {
        bool is_ab = false;
        if (napi_is_arraybuffer(env, v, &is_ab) != napi_ok || !is_ab) { return; }
        void* data = nullptr;
        size_t blen = 0;
        if (napi_get_arraybuffer_info(env, v, &data, &blen) != napi_ok || data == nullptr ||
            blen < sizeof(uint32_t) || (blen % sizeof(uint32_t)) != 0) {
            return;
        }
        const uint32_t* p = static_cast<const uint32_t*>(data);
        out.assign(p, p + blen / sizeof(uint32_t));
    };

    if (argc >= 4) {
        read_f32(args[0], a_pos);
        read_u32(args[1], a_idx);
        read_f32(args[2], b_pos);
        read_u32(args[3], b_idx);
    }
    std::string op = "difference";
    if (argc >= 5) {
        size_t len = 0;
        if (napi_get_value_string_utf8(env, args[4], nullptr, 0, &len) == napi_ok && len > 0) {
            std::vector<char> buf(len + 1, '\0');
            if (napi_get_value_string_utf8(env, args[4], buf.data(), buf.size(), &len) == napi_ok)
                op.assign(buf.data(), len);
        }
    }

    std::vector<float> out_pos;
    std::vector<uint32_t> out_idx;
    std::string result_json = Slic3r::ohos::slicer_mesh_boolean(a_pos, a_idx, b_pos, b_idx, op, out_pos, out_idx);

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value js_result = nullptr;
    napi_create_string_utf8(env, result_json.c_str(), NAPI_AUTO_LENGTH, &js_result);
    napi_set_named_property(env, result, "result", js_result);

    void* pdata = nullptr;
    napi_value pos_ab = nullptr;
    const size_t pbytes = out_pos.empty() ? sizeof(float) : out_pos.size() * sizeof(float);
    if (napi_create_arraybuffer(env, pbytes, &pdata, &pos_ab) == napi_ok) {
        if (pdata != nullptr && !out_pos.empty())
            std::memcpy(pdata, out_pos.data(), out_pos.size() * sizeof(float));
        napi_set_named_property(env, result, "positions", pos_ab);
    }

    void* idata = nullptr;
    napi_value idx_ab = nullptr;
    const size_t ibytes = out_idx.empty() ? sizeof(uint32_t) : out_idx.size() * sizeof(uint32_t);
    if (napi_create_arraybuffer(env, ibytes, &idata, &idx_ab) == napi_ok) {
        if (idata != nullptr && !out_idx.empty())
            std::memcpy(idata, out_idx.data(), out_idx.size() * sizeof(uint32_t));
        napi_set_named_property(env, result, "indices", idx_ab);
    }
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerGetVersion", nullptr, SlicerGetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initResourceManager", nullptr, InitResourceManager, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSliceParamSchema", nullptr, GetSliceParamSchema, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerInitPresets", nullptr, SlicerInitPresets, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerSelectPresets", nullptr, SlicerSelectPresets, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerPresetOptions", nullptr, SlicerPresetOptions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerSelectPresetByIndex", nullptr, SlicerSelectPresetByIndex, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerPresetsForPrinter", nullptr, SlicerPresetsForPrinter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerPrinterBed", nullptr, SlicerPrinterBed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerConfigSnapshot", nullptr, SlicerConfigSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerFilamentSnapshot", nullptr, SlicerFilamentSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerEnumValues", nullptr, SlicerEnumValues, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttDisconnect", nullptr, MqttDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttGetLogs", nullptr, MqttGetLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerSlice", nullptr, SlicerSlice, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerSliceWithProgress", nullptr, SlicerSliceWithProgress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerExportProject3mf", nullptr, SlicerExportProject3mf, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerExportGcode3mf", nullptr, SlicerExportGcode3mf, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerImport3mf", nullptr, SlicerImport3mf, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"slicerMeshBoolean", nullptr, SlicerMeshBoolean, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttDiscover", nullptr, MqttDiscover, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttConnect", nullptr, MqttConnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttGetStatus", nullptr, MqttGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttSelfTestMerge", nullptr, MqttSelfTestMerge, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttSendCommand", nullptr, MqttSendCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttRequestKProfiles", nullptr, MqttRequestKProfiles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mqttGetCaliRaw", nullptr, MqttGetCaliRaw, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ftpsUpload", nullptr, FtpsUpload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ftpsList", nullptr, FtpsList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ftpsRemove", nullptr, FtpsRemove, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ftpsDownload", nullptr, FtpsDownload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cameraStart", nullptr, CameraStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cameraResolveProtocol", nullptr, CameraResolveProtocol, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cameraStop", nullptr, CameraStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cameraGetFrame", nullptr, CameraGetFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererAttach", nullptr, RendererAttach, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererLoadModel", nullptr, RendererLoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meshParse", nullptr, MeshParse, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meshParseWithProgress", nullptr, MeshParseWithProgress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"bedMesh", nullptr, BedMesh, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"bedMeshForModel", nullptr, BedMeshForModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"logoMesh", nullptr, LogoMesh, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererRotate", nullptr, RendererRotate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererZoom", nullptr, RendererZoom, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererPan", nullptr, RendererPan, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererResetView", nullptr, RendererResetView, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererSetGcode", nullptr, RendererSetGcode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererSetGcodeMode", nullptr, RendererSetGcodeMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rendererClearGcode", nullptr, RendererClearGcode, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    // 持有 exports：XComponent 的 native 属性在 Init 后才注入，onLoad 时再取
    if (g_exportsRef == nullptr) {
        napi_create_reference(env, exports, 1, &g_exportsRef);
    }
    TryRegisterXComponent(env);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
