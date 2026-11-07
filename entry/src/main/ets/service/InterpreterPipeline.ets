import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AsrService } from './AsrService';
import { CloudAsrService } from './CloudAsrService';
import { AsrEngine } from './AsrEngine';
import { TtsService } from './TtsService';
import { TranslationService } from './Translator';
import { SettingsService } from './SettingsService';
import { BackgroundService } from './BackgroundService';
import {
  AppSettings,
  Direction,
  EchoStatus,
  newUtterance,
  sourceLangOf,
  StoreKeys,
  targetLangOf,
  Utterance
} from '../model/Types';

const TAG: string = 'EchoPipeline';
const MAX_HISTORY: number = 80;
const CJK_PATTERN: RegExp = /[\u4e00-\u9fff]/;
const LATIN_PATTERN: RegExp = /[a-zA-Z]/;

/**
 * 主流程编排：
 * 识别到一句源语言 → 翻译成目标语言 → 朗读目标语言。
 * 中→英使用系统离线识别；英→中使用百度短语音识别 + 自建 VAD。
 */
export class InterpreterPipeline {
  private static instance: InterpreterPipeline | null = null;

  private asr: AsrEngine | null = null;
  private tts: TtsService = new TtsService();
  private translation: TranslationService | null = null;
  private settings: AppSettings = SettingsService.get();
  private context: common.UIAbilityContext | null = null;

  private translateQueue: Utterance[] = [];
  private speakQueue: Utterance[] = [];
  private history: Utterance[] = [];
  private translating: boolean = false;
  private speaking: boolean = false;
  private lastFinalText: string = '';
  private lastFinalAt: number = 0;
  private active: boolean = false;
  private consecutiveAsrErrors: number = 0;
  private ttsQuietUntil: number = 0;
  private recentSource: Map<string, number> = new Map<string, number>();
  private guardGeneration: number = 0;

  static getInstance(): InterpreterPipeline {
    if (InterpreterPipeline.instance === null) {
      InterpreterPipeline.instance = new InterpreterPipeline();
    }
    return InterpreterPipeline.instance;
  }

  get isActive(): boolean {
    return this.active;
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.active) {
      return;
    }
    this.context = context;
    this.settings = SettingsService.get();
    this.translation = new TranslationService(this.settings);
    this.tts.setSpeed(this.settings.voiceSpeed);
    this.tts.onSpeakingChange = (speaking: boolean): void => {
      this.handleTtsState(speaking);
    };
    this.tts.onError = (message: string): void => {
      this.setError(message);
    };
    this.bindTtsSettings();
    this.active = true;
    this.setStatus('starting');
    this.setError('');
    AppStorage.setOrCreate(StoreKeys.PROVIDER, this.translation.label);
    AppStorage.setOrCreate(StoreKeys.DIRECTION, this.settings.direction);

    this.asr = this.buildAsr();
    this.bindAsr(this.asr);
    try {
      await this.asr.start();
    } catch (e) {
      this.active = false;
      this.setStatus('error');
      this.setError((e as Error).message);
      return;
    }
    this.setStatus('listening');

    // 目标语言音色初始化放到后台，避免下载音色阻塞开麦。
    this.tts.setLanguage(targetLangOf(this.settings.direction)).catch((e: Error) => {
      hilog.error(0x0000, TAG, 'tts init failed: %{public}s', e.message);
      this.setError(`朗读不可用：${e.message}`);
    });
    if (this.settings.backgroundMode) {
      await BackgroundService.start(context);
    }
  }

  private bindTtsSettings(): void {
    // 占位：后续可扩展音色/语速热更新。
  }

  private buildAsr(): AsrEngine {
    if (this.settings.direction === 'en-zh') {
      const cloud: CloudAsrService = new CloudAsrService();
      cloud.configure(this.settings.baiduAsrApiKey, this.settings.baiduAsrSecretKey);
      return cloud;
    }
    return new AsrService();
  }

  async stop(): Promise<void> {
    this.active = false;
    if (this.asr !== null) {
      this.asr.shutdown();
      this.asr = null;
    }
    this.tts.stop();
    if (this.context !== null) {
      await BackgroundService.stop(this.context);
    }
    this.translateQueue = [];
    this.speakQueue = [];
    this.setStatus('paused');
    AppStorage.setOrCreate(StoreKeys.PARTIAL_ZH, '');
  }

  async applySettings(settings: AppSettings): Promise<void> {
    const previous: AppSettings = this.settings;
    const previousDirection: Direction = previous.direction;
    this.settings = settings;
    this.tts.setSpeed(settings.voiceSpeed);
    if (this.translation !== null) {
      this.translation.applySettings(settings);
      AppStorage.setOrCreate(StoreKeys.PROVIDER, this.translation.label);
    }
    AppStorage.setOrCreate(StoreKeys.DIRECTION, settings.direction);

    const directionChanged: boolean = previousDirection !== settings.direction;
    const asrKeysChanged: boolean = previous.baiduAsrApiKey !== settings.baiduAsrApiKey ||
      previous.baiduAsrSecretKey !== settings.baiduAsrSecretKey;
    if (this.active && (directionChanged || (settings.direction === 'en-zh' && asrKeysChanged)) &&
      this.context !== null) {
      const context: common.UIAbilityContext = this.context;
      await this.stop();
      await this.start(context);
      return;
    }
    if (!this.active) {
      this.tts.setLanguage(targetLangOf(settings.direction)).catch(() => {
        // 未启动时只做预初始化，失败留到启动时提示。
      });
    }
    if (this.context !== null) {
      if (settings.backgroundMode && this.active) {
        await BackgroundService.start(this.context);
      } else if (!settings.backgroundMode) {
        await BackgroundService.stop(this.context);
      }
    }
  }

  private bindAsr(asr: AsrEngine): void {
    asr.onPartial = (text: string): void => {
      if (this.tts.isSpeaking || Date.now() < this.ttsQuietUntil) {
        AppStorage.setOrCreate(StoreKeys.PARTIAL_ZH, '');
        return;
      }
      if (!this.isExpectedSource(text)) {
        AppStorage.setOrCreate(StoreKeys.PARTIAL_ZH, '');
        return;
      }
      AppStorage.setOrCreate(StoreKeys.PARTIAL_ZH, text);
    };
    asr.onFinal = (text: string): void => {
      this.handleFinal(text);
    };
    asr.onListening = (): void => {
      this.consecutiveAsrErrors = 0;
      if (this.active) {
        this.setStatus('listening');
      }
    };
    asr.onStopped = (): void => {
      AppStorage.setOrCreate(StoreKeys.PARTIAL_ZH, '');
    };
    asr.onError = (code: number, message: string): void => {
      this.consecutiveAsrErrors++;
      hilog.warn(0x0000, TAG, 'asr error %{public}d %{public}s', code, message);
      if (this.consecutiveAsrErrors >= 2) {
        this.setError(message);
      }
      if (this.active) {
        this.setStatus('listening');
      }
    };
  }

  private isExpectedSource(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    if (this.settings.direction === 'zh-en') {
      return CJK_PATTERN.test(text);
    }
    return LATIN_PATTERN.test(text);
  }

  private handleTtsState(speaking: boolean): void {
    this.speaking = speaking;
    if (speaking) {
      this.guardGeneration++;
      if (this.asr !== null) {
        this.asr.suspend();
      }
    } else {
      this.ttsQuietUntil = Date.now() + 1500;
      const generation: number = ++this.guardGeneration;
      setTimeout(() => {
        if (generation === this.guardGeneration && this.active && this.asr !== null) {
          this.asr.resume().catch(() => {
            // 恢复失败由 ASR 错误回调处理。
          });
        }
      }, 1200);
    }
    this.setStatus(speaking ? 'speaking' : 'listening');
  }

  /** 供“试听”使用：绕过语音识别，直接走翻译 + 朗读链路。 */
  preview(text: string): void {
    if (!this.active) {
      return;
    }
    this.handleFinal(text);
  }

  /** 未监听时也能试听：只走翻译 + 目标语言朗读，不碰麦克风。 */
  async previewDirect(text: string): Promise<void> {
    this.settings = SettingsService.get();
    this.translation = new TranslationService(this.settings);
    this.tts.setSpeed(this.settings.voiceSpeed);
    this.tts.onSpeakingChange = (speaking: boolean): void => {
      this.handleTtsState(speaking);
    };
    this.tts.onError = (message: string): void => {
      this.setError(message);
    };
    await this.tts.setLanguage(targetLangOf(this.settings.direction));
    const translated: string = await this.translation.translate(text,
      sourceLangOf(this.settings.direction), targetLangOf(this.settings.direction));
    AppStorage.setOrCreate(StoreKeys.CURRENT_ZH, text);
    AppStorage.setOrCreate(StoreKeys.CURRENT_EN, translated);
    const utterance: Utterance = newUtterance(text, this.settings.direction);
    utterance.en = translated;
    utterance.state = 'done';
    this.addHistory(utterance);
    await this.tts.speak(translated);
  }

  private handleFinal(text: string): void {
    const source: string = text.trim();
    if (!this.isExpectedSource(source)) {
      return;
    }
    if (this.tts.isSpeaking || Date.now() < this.ttsQuietUntil) {
      hilog.info(0x0000, TAG, 'ignore final during playback: %{public}s', source);
      return;
    }
    const now: number = Date.now();
    const normalized: string = source.replace(/[，。！？、,.!?；;：:\s]/g, '').toLowerCase();
    const seenAt: number | undefined = this.recentSource.get(normalized);
    if (seenAt !== undefined && now - seenAt < 30000) {
      hilog.info(0x0000, TAG, 'ignore duplicate final: %{public}s', source);
      return;
    }
    this.recentSource.set(normalized, now);
    if (this.recentSource.size > 50) {
      const keys: string[] = Array.from(this.recentSource.keys());
      for (let i = 0; i < keys.length - 40; i++) {
        this.recentSource.delete(keys[i]);
      }
    }
    if (source === this.lastFinalText && now - this.lastFinalAt < 6000) {
      return;
    }
    this.lastFinalText = source;
    this.lastFinalAt = now;

    const utterance: Utterance = newUtterance(source, this.settings.direction);
    AppStorage.setOrCreate(StoreKeys.PARTIAL_ZH, '');
    AppStorage.setOrCreate(StoreKeys.CURRENT_ZH, source);
    AppStorage.setOrCreate(StoreKeys.CURRENT_EN, '');
    this.addHistory(utterance);
    this.translateQueue.push(utterance);
    this.pumpTranslate();
  }

  private async pumpTranslate(): Promise<void> {
    if (this.translating || this.translation === null) {
      return;
    }
    this.translating = true;
    while (this.translateQueue.length > 0) {
      const item: Utterance = this.translateQueue.shift() as Utterance;
      try {
        const translated: string = await this.translation.translate(item.zh,
          sourceLangOf(item.direction), targetLangOf(item.direction));
        item.en = translated;
        item.state = 'done';
        AppStorage.setOrCreate(StoreKeys.CURRENT_EN, translated);
        this.updateHistory(item);
        if (this.settings.speakTranslation) {
          this.speakQueue.push(item);
          this.pumpSpeak();
        }
      } catch (e) {
        item.state = 'error';
        item.error = (e as Error).message;
        this.updateHistory(item);
        this.setError(item.error);
      }
    }
    this.translating = false;
  }

  private async pumpSpeak(): Promise<void> {
    if (this.speaking) {
      return;
    }
    while (this.speakQueue.length > 0) {
      const item: Utterance = this.speakQueue.shift() as Utterance;
      if (item.en.length === 0) {
        continue;
      }
      try {
        this.speaking = true;
        await this.tts.speak(item.en);
      } catch (e) {
        this.setError((e as Error).message);
      } finally {
        this.speaking = false;
      }
    }
  }

  private addHistory(utterance: Utterance): void {
    this.history.push(utterance);
    if (this.history.length > MAX_HISTORY) {
      this.history.splice(0, this.history.length - MAX_HISTORY);
    }
    this.publishHistory();
  }

  private updateHistory(utterance: Utterance): void {
    for (let i = 0; i < this.history.length; i++) {
      if (this.history[i].id === utterance.id) {
        this.history[i] = utterance;
        break;
      }
    }
    this.publishHistory();
  }

  private publishHistory(): void {
    AppStorage.setOrCreate(StoreKeys.HISTORY, this.history.slice());
  }

  private setStatus(status: EchoStatus): void {
    AppStorage.setOrCreate(StoreKeys.STATUS, status);
  }

  private setError(message: string): void {
    AppStorage.setOrCreate(StoreKeys.ERROR, message);
  }

  clearHistory(): void {
    this.history = [];
    this.publishHistory();
  }
}
