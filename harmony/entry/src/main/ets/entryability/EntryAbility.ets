import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Prefs } from '../common/Prefs';

const TAG: string = 'RemoteDesk';
const DOMAIN: number = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Prefs.init(this.context);
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      // 深色沉浸式：内容铺满，状态栏改为浅色文字
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch(() => {
        // 部分设备不支持，忽略
      });
      win.setWindowSystemBarProperties({
        statusBarColor: '#0F1216',
        statusBarContentColor: '#E6EDF3',
        navigationBarColor: '#0F1216',
        navigationBarContentColor: '#E6EDF3'
      }).catch(() => {
        // ignore
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    // ignore
  }

  onBackground(): void {
    // ignore
  }
}