import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'volt_form_store';
const KEY_FORM_IDS = 'formIds';

// 读取/保存卡片ID列表，供应用进程刷新卡片时查找
function getStore(context: Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: STORE_NAME });
}

function addFormId(context: Context, formId: string): void {
  preferences.removePreferencesFromCacheSync(context, { name: STORE_NAME });
  const store = getStore(context);
  const ids = store.getSync(KEY_FORM_IDS, []) as string[];
  if (!ids.includes(formId)) {
    ids.push(formId);
    store.putSync(KEY_FORM_IDS, ids);
    store.flush();
  }
}

function removeFormId(context: Context, formId: string): void {
  const store = getStore(context);
  let ids = store.getSync(KEY_FORM_IDS, []) as string[];
  ids = ids.filter((id: string) => id !== formId);
  store.putSync(KEY_FORM_IDS, ids);
  store.flush();
}

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string;
    if (formId) {
      addFormId(this.context, formId);
    }
    // 初始数据：未充电状态
    const obj: Record<string, string | number> = {
      'soc': 0,
      'power': '0.0',
      'temp': '0.0',
      'duration': '00:00:00',
      'charging': 0
    };
    return formBindingData.createFormBindingData(obj);
  }

  onCastToNormalForm(formId: string): void {
  }

  onUpdateForm(formId: string): void {
  }

  onRemoveForm(formId: string): void {
    removeFormId(this.context, formId);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}