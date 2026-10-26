import { promptAction } from '@kit.ArkUI';
import { UIContext } from '@ohos.arkui.UIContext';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { modelState, ModelInstance } from '../model/ModelState';
import { dropThumbnail } from '../model/Thumbnail';
import { history } from '../model/History';

// =============================================================================
// 对象级操作（跨组件复用）
//
// 为什么抽出来：删除对象有两条入口 —— 对象列表的「点点」菜单、PC 上的 Delete 快捷键。
// 两者必须走完全相同的语义（确认弹窗文案 / 多选整组删除 / 一步撤销 / 删空后作废切片入口），
// 各写一份迟早会不一致。
// =============================================================================

// 删除给定对象（先确认）。onDone 供调用方补自己的 UI 副作用。
export function confirmDeleteObjects(ctx: UIContext, ids: number[], onDone?: () => void): void {
  if (ids.length === 0) {
    return;
  }
  const one: ModelInstance | undefined = ids.length === 1 ? modelState.get(ids[0]) : undefined;
  const what: string = ids.length > 1
    ? `选中的 ${ids.length} 个对象`
    : `「${one !== undefined ? one.name : '该对象'}」`;
  try {
    ctx.getPromptAction().showDialog({
      title: '删除对象',
      message: `确定要删除${what}吗？`,
      buttons: [
        { text: '取消', color: '#9A9AA4' },
        { text: '删除', color: '#FF3D2E' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index !== 1) {
        return;
      }
      deleteObjects(ids);
      if (onDone !== undefined) {
        onDone();
      }
    }).catch((err: Error) => {
      // 关键：不再吞异常。删除失败必须可查：
      //   hdc hilog | Select-String "ObjActions"
      hilog.error(0x0000, 'ObjActions', 'delete: showDialog failed %{public}s',
        `${err.name}: ${err.message}`);
    });
  } catch (e) {
    hilog.error(0x0000, 'ObjActions', 'delete: showDialog threw %{public}s',
      e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e));
  }
}

// 直接删除（不再确认）：供「已确认」的路径复用。
// 整组算**一步**撤销（只 commitNow 一次）。
export function deleteObjects(ids: number[]): void {
  for (const id of ids) {
    modelState.remove(id);
    // 缩略图是 CPU 光栅化出来的 PixelMap，必须显式 release，否则删掉的对象缩略图一直占内存
    dropThumbnail(id);
  }
  // 删空后清掉切片入口记录的模型路径：否则底部「切片」还会去切已被删除的对象
  //（同一次导入的多个对象共享一个路径，只有全删光才作废）
  if (modelState.instances.length === 0) {
    AppStorage.setOrCreate<string>('sliceModelPath', '');
  }
  modelState.publish();
  history.commitNow('删除对象');
  hilog.info(0x0000, 'ObjActions', 'delete: removed %{public}d objects, remaining=%{public}d',
    ids.length, modelState.instances.length);
}
