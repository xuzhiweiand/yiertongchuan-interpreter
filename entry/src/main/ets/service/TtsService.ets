import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'EchoTts';
const PERSON_EN: number = 8; // Laura, en-US
const PERSON_ZH: number = 13; // 凌小珊，zh-CN

/**
 * 目标语言朗读。
 *
 * 中→英时用英文音色（person 8，需下载）；英→中时用中文音色（person 13）。
 * 切换方向时重建引擎。
 */
export class TtsService {
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private initialized: boolean = false;
  private speaking: boolean = false;
  private resolveCurrent: (() => void) | null = null;
  private rejectCurrent: ((error: Error) => void) | null = null;
  private watchdog: number = -1;
  private initPromise: Promise<void> | null = null;
  private language: string = 'en-US';

  speed: number = 1.0;
  onSpeakingChange: (speaking: boolean) => void = () => {
  };
  onError: (message: string) => void = () => {
  };

  setSpeed(speed: number): void {
    this.speed = speed;
  }

  getLanguage(): string {
    return this.language;
  }

  async setLanguage(language: string): Promise<void> {
    const normalized: string = language.toLowerCase().indexOf('zh') === 0 ? 'zh-CN' : 'en-US';
    if (normalized === this.language && this.engine !== null) {
      return;
    }
    this.shutdown();
    this.language = normalized;
    await this.init();
  }

  async init(): Promise<void> {
    if (this.initialized && this.engine !== null) {
      return;
    }
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.doInit();
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  private personOf(language: string): number {
    return language.toLowerCase().indexOf('zh') === 0 ? PERSON_ZH : PERSON_EN;
  }

  private async doInit(): Promise<void> {
    let person: number = this.personOf(this.language);
    await this.ensureVoice(this.language, person);
    let engine: textToSpeech.TextToSpeechEngine;
    try {
      engine = await textToSpeech.createEngine(this.buildParams(person));
    } catch (e) {
      // 中文音色 13 不可用时退回默认音色 0。
      if (this.language === 'zh-CN' && person !== 0) {
        person = 0;
        engine = await textToSpeech.createEngine(this.buildParams(person));
      } else {
        throw e as Error;
      }
    }
    engine.setListener({
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
        hilog.info(0x0000, TAG, 'tts start %{public}s', requestId);
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        // type: 0 = 合成完成，1 = 播放完成。
        if (response.type === 1) {
          this.finishSpeaking();
        }
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
        this.finishSpeaking();
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        hilog.error(0x0000, TAG, 'tts error %{public}d %{public}s', errorCode, errorMessage);
        this.failSpeaking(new Error(`朗读失败(${errorCode})`));
      }
    });
    this.engine = engine;
    this.initialized = true;
  }

  private buildParams(person: number): textToSpeech.CreateEngineParams {
    const params: textToSpeech.CreateEngineParams = {
      language: this.language,
      person: person,
      online: 1,
      extraParams: {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'isBackStage': true
      }
    };
    return params;
  }

  private async ensureVoice(language: string, person: number): Promise<void> {
    try {
      const voices: textToSpeech.VoiceInfo[] = await textToSpeech.listVoices({
        requestId: `echo_voice_${Date.now()}`,
        online: 1
      });
      let needDownload: boolean = true;
      for (let i = 0; i < voices.length; i++) {
        const voice: textToSpeech.VoiceInfo = voices[i];
        if (voice.person === person && voice.language.toLowerCase().indexOf(language.substring(0, 2)) === 0) {
          if (voice.status === 'INSTALLED') {
            needDownload = false;
          }
          break;
        }
      }
      if (needDownload) {
        await new Promise<void>((resolve, reject) => {
          textToSpeech.downloadVoice({
            requestId: `echo_download_${Date.now()}`,
            language: language,
            person: person,
            style: 'interaction-broadcast'
          }, (error: BusinessError, data: textToSpeech.DownloadResponse) => {
            if (error) {
              // 模型已存在时会返回“已下载”，按成功处理。
              if (error.code === 1002300010) {
                resolve();
                return;
              }
              reject(new Error(`音色下载失败(${error.code})`));
              return;
            }
            resolve();
          });
        });
      }
    } catch (e) {
      const err = e as Error;
      hilog.warn(0x0000, TAG, 'voice check failed: %{public}s', err.message);
      // 模型可能已经存在；交给 createEngine 做最终判断。
    }
  }

  isReady(): boolean {
    return this.initialized && this.engine !== null;
  }

  async speak(text: string): Promise<void> {
    if (this.engine === null) {
      await this.init();
    }
    const engine: textToSpeech.TextToSpeechEngine = this.engine as textToSpeech.TextToSpeechEngine;
    if (this.speaking) {
      this.stop();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 120));
    }
    const requestId: string = `echo_speak_${Date.now()}`;
    return new Promise<void>((resolve, reject) => {
      this.resolveCurrent = resolve;
      this.rejectCurrent = reject;
      this.speaking = true;
      this.onSpeakingChange(true);
      const timeoutMs: number = Math.max(15000, Math.min(60000, text.length * 90));
      this.watchdog = setTimeout(() => {
        hilog.warn(0x0000, TAG, 'tts watchdog fired');
        this.failSpeaking(new Error('朗读超时'));
      }, timeoutMs);
      try {
        const params: textToSpeech.SpeakParams = {
          requestId: requestId,
          extraParams: {
            'speed': this.speed
          }
        };
        engine.speak(text, params);
      } catch (e) {
        this.failSpeaking(e as Error);
      }
    });
  }

  private finishSpeaking(): void {
    if (this.watchdog >= 0) {
      clearTimeout(this.watchdog);
      this.watchdog = -1;
    }
    this.speaking = false;
    this.onSpeakingChange(false);
    const resolve: (() => void) | null = this.resolveCurrent;
    this.resolveCurrent = null;
    this.rejectCurrent = null;
    if (resolve !== null) {
      resolve();
    }
  }

  private failSpeaking(error: Error): void {
    if (this.watchdog >= 0) {
      clearTimeout(this.watchdog);
      this.watchdog = -1;
    }
    this.speaking = false;
    this.onSpeakingChange(false);
    const reject: ((error: Error) => void) | null = this.rejectCurrent;
    this.resolveCurrent = null;
    this.rejectCurrent = null;
    if (reject !== null) {
      reject(error);
    }
  }

  stop(): void {
    if (this.engine !== null) {
      try {
        this.engine.stop();
      } catch (e) {
        // 忽略。
      }
    }
    this.finishSpeaking();
  }

  shutdown(): void {
    this.stop();
    if (this.engine !== null) {
      try {
        this.engine.shutdown();
      } catch (e) {
        // 忽略。
      }
    }
    this.engine = null;
    this.initialized = false;
  }

  get isSpeaking(): boolean {
    return this.speaking;
  }
}
