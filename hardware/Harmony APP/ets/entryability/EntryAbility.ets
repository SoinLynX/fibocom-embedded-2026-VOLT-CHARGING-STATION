import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { pushService } from '@kit.PushKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppIPConfig } from '../model/IP';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.initPushToken(); // 每次启动获取并上报 push token
  }

  // 获取 push token 并上报 nexus 服务器（实况窗链路第一步）
  private async initPushToken(): Promise<void> {
    try {
      const token: string = await pushService.getToken();
      hilog.info(DOMAIN, 'VOLT', '✅ push token: %{public}s', token);
      AppStorage.setOrCreate('pushToken', token); // 存一份，登录成功后也可补报

      const userId: string = AppStorage.get<string>('userId') || '';
      if (userId) {
        this.reportPushToken(userId, token);
      } else {
        hilog.info(DOMAIN, 'VOLT', '未登录，token 已暂存，登录后补报');
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'VOLT', '❌ getToken失败: %{public}d %{public}s', e.code, e.message);
    }
  }

  // 上报 token 到服务器（登录成功处也可以调用这个方法补报）
  public reportPushToken(userId: string, token: string): void {
    const req = http.createHttp();
    req.request(AppIPConfig.BASE_URL + '/api/pushToken', {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: { userId: userId, token: token }
    }).then(() => {
      hilog.info(DOMAIN, 'VOLT', '✅ push token 已上报服务器');
      req.destroy();
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'VOLT', '❌ token 上报失败: %{public}s', JSON.stringify(err));
      req.destroy();
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Home', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}