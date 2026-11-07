import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Utterance } from '../model/Types';

const TAG: string = 'EchoAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    // 初始化界面共享状态，避免 @StorageLink 拿到 undefined。
    AppStorage.setOrCreate('echo.status', 'idle');
    AppStorage.setOrCreate('echo.partialZh', '');
    AppStorage.setOrCreate('echo.currentZh', '');
    AppStorage.setOrCreate('echo.currentEn', '');
    AppStorage.setOrCreate('echo.history', new Array<Utterance>());
    AppStorage.setOrCreate('echo.speaking', false);
    AppStorage.setOrCreate('echo.error', '');
    AppStorage.setOrCreate('echo.provider', '免注册通道');
    AppStorage.setOrCreate('echo.direction', 'zh-en');
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, TAG, 'Succeeded in loading the content.');
    });
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      mainWindow.setWindowKeepScreenOn(true).catch(() => {
        // 屏幕常亮设置失败不影响功能。
      });
    }).catch(() => {
      // 忽略窗口获取失败。
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'Ability onBackground');
  }
}
