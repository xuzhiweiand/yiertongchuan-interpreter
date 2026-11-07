import { speechRecognizer } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AsrEngine } from './AsrEngine';

const TAG: string = 'EchoAsr';
const AUDIO_SAMPLE_RATE: number = 16000;

export type TextCallback = (text: string) => void;
export type ErrorCallback = (code: number, message: string) => void;

/**
 * 中文实时语音识别。
 *
 * 使用 Core Speech Kit 的离线长语音模式（recognizerMode = long），
 * 引擎在本地持续识别，按句回调 isFinal 结果。长语音会话有结束的时候，
 * 这里用「自动续接」保证应用开启期间始终在听。
 */
export class AsrService implements AsrEngine {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private running: boolean = false;
  private sessionId: string = '';
  private restartTimer: number = -1;
  private failures: number = 0;
  private initialized: boolean = false;
  private suspended: boolean = false;

  onPartial: TextCallback = () => {
  };
  onFinal: TextCallback = () => {
  };
  onError: ErrorCallback = () => {
  };
  onListening: () => void = () => {
  };
  onStopped: () => void = () => {
  };

  async init(): Promise<void> {
    if (this.initialized && this.engine !== null) {
      return;
    }
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 1,
      extraParams: {
        'recognizerMode': 'long',
        'locate': 'CN'
      }
    };
    const engine: speechRecognizer.SpeechRecognitionEngine =
      await speechRecognizer.createEngine(params);
    engine.setListener({
      onStart: (sessionId: string, eventMessage: string): void => {
        hilog.info(0x0000, TAG, 'onStart %{public}s %{public}s', sessionId, eventMessage);
        if (sessionId !== this.sessionId || !this.running || this.suspended) {
          return;
        }
        this.failures = 0;
        this.onListening();
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
        hilog.info(0x0000, TAG, 'onEvent %{public}d %{public}s', eventCode, eventMessage);
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (sessionId !== this.sessionId || !this.running || this.suspended) {
          return;
        }
        const text: string = (result.result ?? '').trim();
        if (text.length === 0) {
          return;
        }
        if (result.isFinal) {
          this.onFinal(text);
          if (result.isLast) {
            this.scheduleRestart(250);
          }
        } else {
          this.onPartial(text);
        }
      },
      onComplete: (sessionId: string, eventMessage: string): void => {
        hilog.info(0x0000, TAG, 'onComplete %{public}s %{public}s', sessionId, eventMessage);
        if (this.running && sessionId === this.sessionId) {
          this.scheduleRestart(250);
        }
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
        hilog.error(0x0000, TAG, 'onError %{public}d %{public}s', errorCode, errorMessage);
        this.failures++;
        if (this.running) {
          this.onError(errorCode, errorMessage);
          const delay: number = Math.min(500 * this.failures, 4000);
          this.scheduleRestart(delay);
        }
      }
    });
    this.engine = engine;
    this.initialized = true;
  }

  /** 开始（或恢复）持续监听。 */
  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.failures = 0;
    try {
      await this.init();
      await this.startSession();
    } catch (e) {
      this.running = false;
      const err = e as BusinessError;
      this.onError(err.code ?? -1, err.message ?? '语音识别初始化失败');
      throw new Error(err.message ?? '语音识别初始化失败');
    }
  }

  private async startSession(): Promise<void> {
    if (!this.running || this.suspended) {
      return;
    }
    if (this.engine === null) {
      await this.init();
    }
    const engine: speechRecognizer.SpeechRecognitionEngine = this.engine as speechRecognizer.SpeechRecognitionEngine;
    const sessionId: string = `echo_${Date.now()}`;
    this.sessionId = sessionId;
    const params: speechRecognizer.StartParams = {
      sessionId: sessionId,
      audioInfo: {
        audioType: 'pcm',
        sampleRate: AUDIO_SAMPLE_RATE,
        soundChannel: 1,
        sampleBit: 16,
        extraParams: {
          'online': 1
        }
      },
      extraParams: {
        // 0 = 实时录音识别（引擎自己打开麦克风）；默认值 1 表示由外部 writeAudio 喂音频。
        'recognitionMode': 0,
        // 长语音最长 8 小时；不设置时默认只有 20 秒，会话会被系统悄悄结束。
        'maxAudioDuration': 28800000,
        // 等待开口的时间（默认 10 秒）；调大减少空闲时的会话重建。
        'vadBegin': 60000,
        // 一句话结束的静音时长。
        'vadEnd': 800
      }
    };
    try {
      engine.startListening(params);
      hilog.info(0x0000, TAG, 'startListening %{public}s', sessionId);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'startListening failed %{public}d %{public}s', err.code, err.message);
      this.failures++;
      this.onError(err.code ?? -1, err.message ?? '启动监听失败');
      this.scheduleRestart(Math.min(600 * this.failures, 4000));
    }
  }

  private scheduleRestart(delayMs: number): void {
    if (!this.running || this.suspended) {
      return;
    }
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
    }
    this.restartTimer = setTimeout(() => {
      this.restartTimer = -1;
      if (this.running) {
        this.startSession().catch(() => {
          // startSession 内部已经处理错误与重试。
        });
      }
    }, delayMs);
  }

  /** 朗读期间暂停收音，避免扬声器声音被自己的麦克风识别。 */
  suspend(): void {
    if (!this.running || this.suspended) {
      return;
    }
    this.suspended = true;
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
    const engine = this.engine;
    const sessionId: string = this.sessionId;
    if (engine !== null && sessionId.length > 0) {
      try {
        engine.cancel(sessionId);
      } catch (e) {
        // 会话可能已结束。
      }
    }
  }

  /** 朗读结束后恢复收音。 */
  async resume(): Promise<void> {
    if (!this.running || !this.suspended) {
      return;
    }
    this.suspended = false;
    await this.startSession();
  }

  /** 暂停监听。 */
  stop(): void {
    this.running = false;
    this.suspended = false;
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
    const engine = this.engine;
    const sessionId: string = this.sessionId;
    if (engine !== null && sessionId.length > 0) {
      try {
        engine.cancel(sessionId);
      } catch (e) {
        // 会话可能已经结束，忽略。
      }
    }
    this.onStopped();
  }

  shutdown(): void {
    this.stop();
    const engine = this.engine;
    if (engine !== null) {
      try {
        engine.shutdown();
      } catch (e) {
        // 忽略重复释放。
      }
    }
    this.engine = null;
    this.initialized = false;
  }

  get isRunning(): boolean {
    return this.running;
  }
}
