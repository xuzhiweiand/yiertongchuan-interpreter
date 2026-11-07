/**
 * 全局数据类型定义。
 */

/** 翻译通道。 */
export type ProviderId = 'mymemory' | 'baidu' | 'deepseek';

/** 同传方向。 */
export type Direction = 'zh-en' | 'en-zh';

/** 应用设置。 */
export interface AppSettings {
  /** 当前同传方向。 */
  direction: Direction;
  provider: ProviderId;
  baiduAppId: string;
  baiduKey: string;
  deepseekKey: string;
  /** 百度短语音识别 API Key（英文识别用）。 */
  baiduAsrApiKey: string;
  /** 百度短语音识别 Secret Key（英文识别用）。 */
  baiduAsrSecretKey: string;
  /** 朗读语速，0.8 ~ 1.5。 */
  voiceSpeed: number;
  /** 打开应用后自动开始监听。 */
  autoStart: boolean;
  /** 退到后台后继续监听（长时任务）。 */
  backgroundMode: boolean;
  /** 朗读译文。 */
  speakTranslation: boolean;
}

/** 一句话的翻译记录。 */
export interface Utterance {
  id: string;
  /** 源语言文本：中→英时为中文，英→中时为英文。 */
  zh: string;
  /** 目标语言文本：中→英时为英文，英→中时为中文。 */
  en: string;
  ts: number;
  direction: Direction;
  state: 'translating' | 'done' | 'error';
  error?: string;
}

export const DEFAULT_SETTINGS: AppSettings = {
  direction: 'zh-en',
  provider: 'mymemory',
  baiduAppId: '',
  baiduKey: '',
  deepseekKey: '',
  baiduAsrApiKey: '',
  baiduAsrSecretKey: '',
  voiceSpeed: 1.0,
  autoStart: true,
  backgroundMode: true,
  speakTranslation: true
};

/** AppStorage 键名，集中管理避免拼写错误。 */
export class StoreKeys {
  static readonly STATUS: string = 'echo.status';
  static readonly PARTIAL_ZH: string = 'echo.partialZh';
  static readonly CURRENT_ZH: string = 'echo.currentZh';
  static readonly CURRENT_EN: string = 'echo.currentEn';
  static readonly HISTORY: string = 'echo.history';
  static readonly SPEAKING: string = 'echo.speaking';
  static readonly ERROR: string = 'echo.error';
  static readonly PROVIDER: string = 'echo.provider';
  static readonly DIRECTION: string = 'echo.direction';
}

/** 运行状态。 */
export type EchoStatus = 'idle' | 'starting' | 'listening' | 'speaking' | 'paused' | 'error';

export function newUtterance(source: string, direction: Direction): Utterance {
  return {
    id: `${Date.now()}_${Math.floor(Math.random() * 10000)}`,
    zh: source,
    en: '',
    ts: Date.now(),
    direction: direction,
    state: 'translating'
  };
}

/** 从设置中取当前方向的源/目标语言代码（云端接口格式）。 */
export function sourceLangOf(direction: Direction): string {
  return direction === 'zh-en' ? 'zh-CN' : 'en-US';
}

export function targetLangOf(direction: Direction): string {
  return direction === 'zh-en' ? 'en-US' : 'zh-CN';
}
