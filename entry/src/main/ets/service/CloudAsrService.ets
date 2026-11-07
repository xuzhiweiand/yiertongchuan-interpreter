import { audio } from '@kit.AudioKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AsrEngine } from './AsrEngine';

const TAG: string = 'EchoCloudAsr';
const FRAME_BYTES: number = 3200; // 100ms @ 16k / 16bit / mono
const MAX_UTTERANCE_BYTES: number = 16000 * 2 * 20; // 20s
const SILENCE_FRAMES: number = 8; // 800ms
const MIN_UTTERANCE_BYTES: number = 16000 * 2 * 0.4; // 400ms
const MIN_RMS: number = 300;

interface BaiduTokenResponse {
  access_token?: string;
  expires_in?: number;
  error?: string;
  error_description?: string;
}

interface BaiduAsrResponse {
  err_no: number;
  err_msg: string;
  result?: string[];
}

/**
 * 英文语音识别：自己采集 PCM → 能量 VAD 断句 → 百度短语音识别（英文）。
 *
 * 百度短语音接口单次最长 60 秒，这里按 20 秒或 800ms 静音切句，
 * 每句单独上传，延迟可控。识别期间继续采集下一句。
 */
export class CloudAsrService implements AsrEngine {
  onPartial: (text: string) => void = () => {
  };
  onFinal: (text: string) => void = () => {
  };
  onError: (code: number, message: string) => void = () => {
  };
  onListening: () => void = () => {
  };
  onStopped: () => void = () => {
  };

  private apiKey: string = '';
  private secretKey: string = '';
  private capturer: audio.AudioCapturer | null = null;
  private running: boolean = false;
  private suspended: boolean = false;
  private loopGeneration: number = 0;

  private collecting: boolean = false;
  private chunks: Uint8Array[] = [];
  private preRoll: Uint8Array[] = [];
  private totalBytes: number = 0;
  private silenceFrames: number = 0;
  private noiseFloor: number = 220;

  private token: string = '';
  private tokenExpireAt: number = 0;
  private pending: Uint8Array[] = [];
  private recognizing: boolean = false;

  configure(apiKey: string, secretKey: string): void {
    this.apiKey = apiKey.trim();
    this.secretKey = secretKey.trim();
    this.token = '';
    this.tokenExpireAt = 0;
  }

  /** 设置页“测试密钥”：只做 OAuth 校验，不打开麦克风。 */
  static async probe(apiKey: string, secretKey: string): Promise<void> {
    const service: CloudAsrService = new CloudAsrService();
    service.configure(apiKey, secretKey);
    await service.ensureToken();
  }

  get isRunning(): boolean {
    return this.running;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    if (this.apiKey.length === 0 || this.secretKey.length === 0) {
      throw new Error('请先在设置里填写百度语音识别的 API Key 和 Secret Key');
    }
    this.running = true;
    this.suspended = false;
    this.resetVad();
    try {
      // 先校验密钥，避免“看起来在听、说话才报错”。
      await this.ensureToken();
      await this.openCapturer();
    } catch (e) {
      this.running = false;
      this.closeCapturer();
      throw e as Error;
    }
    this.onListening();
    this.loopGeneration++;
    this.readLoop(this.loopGeneration).catch((e: Error) => {
      hilog.error(0x0000, TAG, 'read loop exit: %{public}s', e.message);
    });
  }

  private async openCapturer(): Promise<void> {
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      }
    };
    const capturer: audio.AudioCapturer = await audio.createAudioCapturer(options);
    await capturer.start();
    this.capturer = capturer;
  }

  private async readLoop(generation: number): Promise<void> {
    while (this.running && !this.suspended && generation === this.loopGeneration) {
      const capturer: audio.AudioCapturer | null = this.capturer;
      if (capturer === null) {
        break;
      }
      try {
        const buffer: ArrayBuffer = await capturer.read(FRAME_BYTES, true);
        if (!this.running || this.suspended || generation !== this.loopGeneration) {
          break;
        }
        this.processFrame(buffer);
      } catch (e) {
        if (!this.running || this.suspended) {
          break;
        }
        hilog.warn(0x0000, TAG, 'read failed: %{public}s', (e as Error).message);
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 200));
      }
    }
  }

  private threshold(): number {
    return Math.max(MIN_RMS, this.noiseFloor * 2.2 + 100);
  }

  private processFrame(buffer: ArrayBuffer): void {
    const bytes: Uint8Array = new Uint8Array(buffer);
    const samples: Int16Array = new Int16Array(buffer);
    let sum: number = 0;
    for (let i = 0; i < samples.length; i++) {
      const v: number = samples[i];
      sum += v * v;
    }
    const rms: number = samples.length > 0 ? Math.sqrt(sum / samples.length) : 0;

    if (!this.collecting) {
      this.preRoll.push(bytes);
      if (this.preRoll.length > 4) {
        this.preRoll.shift();
      }
      if (rms > this.threshold()) {
        this.collecting = true;
        this.chunks = this.preRoll.slice();
        this.totalBytes = 0;
        for (let i = 0; i < this.chunks.length; i++) {
          this.totalBytes += this.chunks[i].length;
        }
        this.silenceFrames = 0;
        this.preRoll = [];
      } else {
        this.noiseFloor = this.noiseFloor * 0.95 + rms * 0.05;
      }
      return;
    }

    this.chunks.push(bytes);
    this.totalBytes += bytes.length;
    if (rms < this.threshold()) {
      this.silenceFrames++;
    } else {
      this.silenceFrames = 0;
    }
    if (this.silenceFrames >= SILENCE_FRAMES || this.totalBytes >= MAX_UTTERANCE_BYTES) {
      this.finalizeUtterance();
    }
  }

  private finalizeUtterance(): void {
    const chunks: Uint8Array[] = this.chunks;
    const total: number = this.totalBytes;
    this.resetVad();
    if (total < MIN_UTTERANCE_BYTES) {
      return;
    }
    const pcm: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (let i = 0; i < chunks.length; i++) {
      pcm.set(chunks[i], offset);
      offset += chunks[i].length;
    }
    this.pending.push(pcm);
    this.processPending();
  }

  private resetVad(): void {
    this.collecting = false;
    this.chunks = [];
    this.preRoll = [];
    this.totalBytes = 0;
    this.silenceFrames = 0;
  }

  private async processPending(): Promise<void> {
    if (this.recognizing) {
      return;
    }
    this.recognizing = true;
    while (this.pending.length > 0 && this.running) {
      const pcm: Uint8Array = this.pending.shift() as Uint8Array;
      try {
        const text: string = await this.recognize(pcm);
        if (text.length > 0 && this.running) {
          this.onFinal(text);
        }
      } catch (e) {
        this.onError(-1, (e as Error).message);
      }
    }
    this.recognizing = false;
  }

  private async ensureToken(): Promise<string> {
    if (this.token.length > 0 && Date.now() < this.tokenExpireAt) {
      return this.token;
    }
    const url: string = 'https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials' +
      `&client_id=${encodeURIComponent(this.apiKey)}&client_secret=${encodeURIComponent(this.secretKey)}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(text) as BaiduTokenResponse;
      if (parsed.access_token === undefined || parsed.access_token.length === 0) {
        throw new Error(`获取百度语音 token 失败：${parsed.error_description ?? parsed.error ?? text}`);
      }
      this.token = parsed.access_token;
      const expiresIn: number = parsed.expires_in ?? 2592000;
      this.tokenExpireAt = Date.now() + Math.max(60, expiresIn - 120) * 1000;
      return this.token;
    } finally {
      request.destroy();
    }
  }

  private async recognize(pcm: Uint8Array): Promise<string> {
    const token: string = await this.ensureToken();
    const base64: string = new util.Base64Helper().encodeToStringSync(pcm);
    const payload: string = JSON.stringify({
      format: 'pcm',
      rate: 16000,
      channel: 1,
      cuid: 'yiertong-interpreter',
      token: token,
      dev_pid: 1737,
      speech: base64,
      len: pcm.length
    });
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request('https://vop.baidu.com/server_api', {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: payload,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const parsed = JSON.parse(text) as BaiduAsrResponse;
      if (parsed.err_no !== 0) {
        throw new Error(this.errorMessage(parsed.err_no, parsed.err_msg));
      }
      if (parsed.result === undefined || parsed.result.length === 0) {
        return '';
      }
      return parsed.result.join(' ').trim();
    } finally {
      request.destroy();
    }
  }

  private errorMessage(code: number, message: string): string {
    if (code === 3302) {
      return '百度语音鉴权失败，请检查 API Key / Secret Key';
    }
    if (code === 3303 || code === 3304) {
      return '百度语音额度不足或请求过于频繁';
    }
    if (code === 3301) {
      return '音频质量太差，请靠近麦克风再说一次';
    }
    if (code === 3307) {
      return '这段英文太长，已截断识别';
    }
    return `英文识别失败(${code}: ${message})`;
  }

  suspend(): void {
    if (!this.running || this.suspended) {
      return;
    }
    this.suspended = true;
    this.loopGeneration++;
    this.resetVad();
    this.closeCapturer();
  }

  async resume(): Promise<void> {
    if (!this.running || !this.suspended) {
      return;
    }
    this.suspended = false;
    this.loopGeneration++;
    await this.openCapturer();
    this.onListening();
    const generation: number = this.loopGeneration;
    this.readLoop(generation).catch((e: Error) => {
      hilog.error(0x0000, TAG, 'read loop exit: %{public}s', e.message);
    });
  }

  private closeCapturer(): void {
    const capturer: audio.AudioCapturer | null = this.capturer;
    this.capturer = null;
    if (capturer !== null) {
      capturer.stop().then(() => {
        capturer.release();
      }).catch(() => {
        capturer.release();
      });
    }
  }

  stop(): void {
    this.running = false;
    this.suspended = false;
    this.loopGeneration++;
    this.resetVad();
    this.closeCapturer();
    this.pending = [];
    this.onStopped();
  }

  shutdown(): void {
    this.stop();
    this.token = '';
    this.tokenExpireAt = 0;
  }
}
