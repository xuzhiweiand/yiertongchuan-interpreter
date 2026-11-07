import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'EchoBackground';

/**
 * 后台长时任务：申请 audioRecording 类型，让应用退到后台后仍能持续收音。
 * 系统会在通知栏展示常驻通知；失败时退回前台模式。
 */
export class BackgroundService {
  private static running: boolean = false;

  static async start(context: common.UIAbilityContext): Promise<boolean> {
    if (BackgroundService.running) {
      return true;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING, agent);
      BackgroundService.running = true;
      hilog.info(0x0000, TAG, 'background task started');
      return true;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'background task failed: %{public}s', JSON.stringify(e));
      BackgroundService.running = false;
      return false;
    }
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundService.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'stop background failed: %{public}s', JSON.stringify(e));
    }
    BackgroundService.running = false;
  }

  static get isRunning(): boolean {
    return BackgroundService.running;
  }
}
