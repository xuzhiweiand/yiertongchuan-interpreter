import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppSettings, DEFAULT_SETTINGS, Direction } from '../model/Types';

const PREF_NAME: string = 'echo_settings';
const KEY_SETTINGS: string = 'settings_json';

/**
 * 设置的读写。以 JSON 形式保存在 Preferences 中。
 */
export class SettingsService {
  private static current: AppSettings = SettingsService.cloneDefaults();
  private static prefs: preferences.Preferences | null = null;

  private static cloneDefaults(): AppSettings {
    return {
      direction: DEFAULT_SETTINGS.direction,
      provider: DEFAULT_SETTINGS.provider,
      baiduAppId: DEFAULT_SETTINGS.baiduAppId,
      baiduKey: DEFAULT_SETTINGS.baiduKey,
      deepseekKey: DEFAULT_SETTINGS.deepseekKey,
      baiduAsrApiKey: DEFAULT_SETTINGS.baiduAsrApiKey,
      baiduAsrSecretKey: DEFAULT_SETTINGS.baiduAsrSecretKey,
      voiceSpeed: DEFAULT_SETTINGS.voiceSpeed,
      autoStart: DEFAULT_SETTINGS.autoStart,
      backgroundMode: DEFAULT_SETTINGS.backgroundMode,
      speakTranslation: DEFAULT_SETTINGS.speakTranslation
    };
  }

  static async load(context: common.Context): Promise<void> {
    try {
      SettingsService.prefs = await preferences.getPreferences(context, PREF_NAME);
      const raw: preferences.ValueType = await SettingsService.prefs.get(KEY_SETTINGS, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed = JSON.parse(raw) as AppSettings;
        SettingsService.current = SettingsService.normalize(parsed);
      }
    } catch (e) {
      // 读取失败时使用默认值，不影响启动。
    }
  }

  private static normalize(raw: AppSettings): AppSettings {
    const result: AppSettings = SettingsService.cloneDefaults();
    if (raw.direction === 'en-zh' || raw.direction === 'zh-en') {
      result.direction = raw.direction as Direction;
    }
    if (raw.provider === 'baidu' || raw.provider === 'deepseek' || raw.provider === 'mymemory') {
      result.provider = raw.provider;
    }
    if (typeof raw.baiduAppId === 'string') {
      result.baiduAppId = raw.baiduAppId;
    }
    if (typeof raw.baiduKey === 'string') {
      result.baiduKey = raw.baiduKey;
    }
    if (typeof raw.deepseekKey === 'string') {
      result.deepseekKey = raw.deepseekKey;
    }
    if (typeof raw.baiduAsrApiKey === 'string') {
      result.baiduAsrApiKey = raw.baiduAsrApiKey;
    }
    if (typeof raw.baiduAsrSecretKey === 'string') {
      result.baiduAsrSecretKey = raw.baiduAsrSecretKey;
    }
    if (typeof raw.voiceSpeed === 'number' && raw.voiceSpeed >= 0.8 && raw.voiceSpeed <= 1.5) {
      result.voiceSpeed = raw.voiceSpeed;
    }
    if (typeof raw.autoStart === 'boolean') {
      result.autoStart = raw.autoStart;
    }
    if (typeof raw.backgroundMode === 'boolean') {
      result.backgroundMode = raw.backgroundMode;
    }
    if (typeof raw.speakTranslation === 'boolean') {
      result.speakTranslation = raw.speakTranslation;
    }
    return result;
  }

  static get(): AppSettings {
    return SettingsService.current;
  }

  static async save(next: AppSettings): Promise<void> {
    SettingsService.current = SettingsService.normalize(next);
    try {
      if (SettingsService.prefs === null) {
        return;
      }
      await SettingsService.prefs.put(KEY_SETTINGS, JSON.stringify(SettingsService.current));
      await SettingsService.prefs.flush();
    } catch (e) {
      // 持久化失败不阻塞使用。
    }
  }
}
