import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { AppSettings, ProviderId } from '../model/Types';

/** 翻译器抽象：后续增加语向（英译中）时只需新增实现。 */
export interface Translator {
  readonly id: ProviderId;
  readonly label: string;
  translate(text: string, from: string, to: string): Promise<string>;
}

export function providerLabel(id: ProviderId): string {
  if (id === 'baidu') {
    return '百度翻译';
  }
  if (id === 'deepseek') {
    return 'DeepSeek';
  }
  return '免注册通道';
}

export function providerConfigured(id: ProviderId, settings: AppSettings): boolean {
  if (id === 'baidu') {
    return settings.baiduAppId.length > 0 && settings.baiduKey.length > 0;
  }
  if (id === 'deepseek') {
    return settings.deepseekKey.length > 0;
  }
  return true;
}

function md5Hex(text: string): string {
  const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
  const encoder: util.TextEncoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(text);
  md.updateSync({ data: bytes });
  const digest: cryptoFramework.DataBlob = md.digestSync();
  let hex: string = '';
  for (let i = 0; i < digest.data.length; i++) {
    hex += digest.data[i].toString(16).padStart(2, '0');
  }
  return hex;
}

function baiduLang(code: string): string {
  const lower: string = code.toLowerCase();
  if (lower.indexOf('zh') === 0) {
    return 'zh';
  }
  if (lower.indexOf('en') === 0) {
    return 'en';
  }
  return code;
}

async function httpText(url: string, method: http.RequestMethod, header: Record<string, string>,
  body: string | undefined, timeoutMs: number): Promise<string> {
  const request: http.HttpRequest = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING
    };
    if (body !== undefined) {
      options.extraData = body;
    }
    const response: http.HttpResponse = await request.request(url, options);
    const code: number = response.responseCode;
    const raw: string | Object | ArrayBuffer = response.result;
    const text: string = typeof raw === 'string' ? raw : JSON.stringify(raw);
    if (code !== 200) {
      throw new Error(`HTTP ${code}`);
    }
    return text;
  } finally {
    request.destroy();
  }
}

/** 把长文本切成接口允许的长度，优先在标点处断开。 */
function splitText(text: string, limit: number): string[] {
  const result: string[] = [];
  let rest: string = text;
  while (rest.length > limit) {
    let cut: number = -1;
    for (let i = limit; i > Math.floor(limit / 2); i--) {
      const ch: string = rest.charAt(i - 1);
      if (ch === '，' || ch === '。' || ch === '！' || ch === '？' || ch === ',' || ch === '.' ||
        ch === '!' || ch === '?' || ch === '；' || ch === ';') {
        cut = i;
        break;
      }
    }
    if (cut < 0) {
      cut = limit;
    }
    result.push(rest.substring(0, cut));
    rest = rest.substring(cut);
  }
  if (rest.length > 0) {
    result.push(rest);
  }
  return result;
}

function cleanEnglish(text: string): string {
  let out: string = text.trim();
  out = out.replace(/\r/g, ' ').replace(/\n+/g, ' ');
  if (out.length >= 2) {
    const first: string = out.charAt(0);
    const last: string = out.charAt(out.length - 1);
    if ((first === '"' && last === '"') || (first === '“' && last === '”') ||
      (first === '\'' && last === '\'')) {
      out = out.substring(1, out.length - 1).trim();
    }
  }
  return out;
}

/* ------------------------------ MyMemory ------------------------------ */

interface MyMemoryData {
  translatedText: string;
}

interface MyMemoryResponse {
  responseStatus: number | string;
  responseData: MyMemoryData | string;
}

class MyMemoryTranslator implements Translator {
  readonly id: ProviderId = 'mymemory';
  readonly label: string = '免注册通道';

  async translate(text: string, from: string, to: string): Promise<string> {
    const chunks: string[] = splitText(text, 420);
    const parts: string[] = [];
    for (let i = 0; i < chunks.length; i++) {
      const q: string = encodeURIComponent(chunks[i]);
      const pair: string = encodeURIComponent(`${from}|${to}`);
      const url: string = `https://api.mymemory.translated.net/get?q=${q}&langpair=${pair}`;
      const body: string = await httpText(url, http.RequestMethod.GET, {}, undefined, 8000);
      const parsed = JSON.parse(body) as MyMemoryResponse;
      if (typeof parsed.responseData === 'string') {
        throw new Error('翻译服务返回异常');
      }
      const translated: string = parsed.responseData.translatedText;
      if (translated === undefined || translated === null || translated.length === 0) {
        throw new Error('翻译结果为空');
      }
      parts.push(translated);
    }
    return cleanEnglish(parts.join(' '));
  }
}

/* ------------------------------- Baidu -------------------------------- */

interface BaiduItem {
  src: string;
  dst: string;
}

interface BaiduResponse {
  from?: string;
  to?: string;
  trans_result?: BaiduItem[];
  error_code?: string;
  error_msg?: string;
}

class BaiduTranslator implements Translator {
  readonly id: ProviderId = 'baidu';
  readonly label: string = '百度翻译';
  private appId: string;
  private key: string;
  // 百度通用翻译免费版 QPS 为 1，必须节流，否则返回 54003。
  private static lastCallAt: number = 0;

  constructor(appId: string, key: string) {
    this.appId = appId;
    this.key = key;
  }

  private async waitForSlot(): Promise<void> {
    const wait: number = BaiduTranslator.lastCallAt + 1150 - Date.now();
    if (wait > 0) {
      await new Promise<void>((resolve) => setTimeout(() => resolve(), wait));
    }
    BaiduTranslator.lastCallAt = Date.now();
  }

  async translate(text: string, from: string, to: string): Promise<string> {
    // 百度只认 zh / en，不能直接用 BCP-47 的 zh-CN / en-US。
    const baiduFrom: string = baiduLang(from);
    const baiduTo: string = baiduLang(to);
    const chunks: string[] = splitText(text, 1500);
    const result: string[] = [];
    for (let i = 0; i < chunks.length; i++) {
      const q: string = chunks[i];
      let lastError: string = '';
      let done: boolean = false;
      for (let attempt = 0; attempt < 2 && !done; attempt++) {
        await this.waitForSlot();
        const salt: string = `${Date.now()}${i}`;
        const sign: string = md5Hex(this.appId + q + salt + this.key);
        const body: string = `q=${encodeURIComponent(q)}&from=${baiduFrom}&to=${baiduTo}` +
          `&appid=${encodeURIComponent(this.appId)}&salt=${salt}&sign=${sign}`;
        const responseText: string = await httpText('https://fanyi-api.baidu.com/api/trans/vip/translate',
          http.RequestMethod.POST, { 'Content-Type': 'application/x-www-form-urlencoded' }, body, 8000);
        const parsed = JSON.parse(responseText) as BaiduResponse;
        if (parsed.error_code !== undefined && parsed.error_code !== '52000') {
          lastError = `百度翻译错误 ${parsed.error_code}: ${parsed.error_msg ?? ''}`;
          // 54003 频率受限 / 54005 长 query 频繁：等待后重试一次。
          if ((parsed.error_code === '54003' || parsed.error_code === '54005') && attempt === 0) {
            await new Promise<void>((resolve) => setTimeout(() => resolve(), 1300));
            continue;
          }
          throw new Error(lastError);
        }
        if (parsed.trans_result === undefined || parsed.trans_result.length === 0) {
          throw new Error('百度翻译未返回结果');
        }
        for (let j = 0; j < parsed.trans_result.length; j++) {
          result.push(parsed.trans_result[j].dst);
        }
        done = true;
      }
      if (!done) {
        throw new Error(lastError.length > 0 ? lastError : '百度翻译失败');
      }
    }
    return cleanEnglish(result.join(' '));
  }
}

/* ------------------------------ DeepSeek ------------------------------ */

interface DsMessage {
  role: string;
  content: string;
}

interface DsChoice {
  message: DsMessage;
}

interface DsError {
  message: string;
}

interface DsResponse {
  choices?: DsChoice[];
  error?: DsError;
}

class DeepSeekTranslator implements Translator {
  readonly id: ProviderId = 'deepseek';
  readonly label: string = 'DeepSeek';
  private key: string;

  constructor(key: string) {
    this.key = key;
  }

  async translate(text: string, from: string, to: string): Promise<string> {
    const toChinese: boolean = to.toLowerCase().indexOf('zh') === 0;
    const system: string = toChinese ?
      '你是专业的同声传译引擎。把用户给出的英文口语翻译成自然、地道、简洁的中文口语。' +
      '只输出中文译文，不要引号，不要解释，不要拼音，不要添加原文没有的信息。数字、专有名词保持准确。' :
      '你是专业的同声传译引擎。把用户给出的中文口语翻译成自然、地道、简洁的英语口语。' +
      '只输出英文译文，不要引号，不要解释，不要音标，不要添加原文没有的信息。数字、专有名词保持准确。';
    const payload: string = JSON.stringify({
      model: 'deepseek-chat',
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: text }
      ] as DsMessage[],
      temperature: 0.2,
      max_tokens: 512,
      stream: false
    });
    const responseText: string = await httpText('https://api.deepseek.com/chat/completions',
      http.RequestMethod.POST, {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${this.key}`
    }, payload, 20000);
    const parsed = JSON.parse(responseText) as DsResponse;
    if (parsed.error !== undefined) {
      throw new Error(`DeepSeek: ${parsed.error.message}`);
    }
    if (parsed.choices === undefined || parsed.choices.length === 0) {
      throw new Error('DeepSeek 未返回结果');
    }
    return cleanEnglish(parsed.choices[0].message.content);
  }
}

/* ------------------------------ 服务封装 ------------------------------ */

export function createTranslator(settings: AppSettings): Translator {
  if (settings.provider === 'baidu' && providerConfigured('baidu', settings)) {
    return new BaiduTranslator(settings.baiduAppId, settings.baiduKey);
  }
  if (settings.provider === 'deepseek' && providerConfigured('deepseek', settings)) {
    return new DeepSeekTranslator(settings.deepseekKey);
  }
  return new MyMemoryTranslator();
}

const CACHE_LIMIT: number = 200;

/** 带缓存、降级与限速的翻译服务。 */
export class TranslationService {
  private translator: Translator;
  private fallback: Translator = new MyMemoryTranslator();
  private cache: Map<string, string> = new Map<string, string>();
  private fallbackNotified: boolean = false;

  constructor(settings: AppSettings) {
    this.translator = createTranslator(settings);
  }

  get label(): string {
    return this.translator.label;
  }

  applySettings(settings: AppSettings): void {
    this.translator = createTranslator(settings);
    this.fallbackNotified = false;
  }

  async translate(zh: string, from: string, to: string): Promise<string> {
    const cacheKey: string = `${from}|${to}|${zh}`;
    const cached: string | undefined = this.cache.get(cacheKey);
    if (cached !== undefined) {
      return cached;
    }
    try {
      return await this.run(this.translator, zh, from, to);
    } catch (e) {
      const primaryError: string = (e as Error).message;
      // 主通道不可用时自动降级到免注册通道，保证用户仍能听到译文。
      if (this.translator.id !== 'mymemory') {
        try {
          const translated: string = await this.run(this.fallback, zh, from, to);
          this.notifyFallback();
          return translated;
        } catch (fallbackError) {
          // 两条通道都失败，返回主通道错误。
        }
      }
      throw new Error(this.friendlyError(primaryError));
    }
  }

  private async run(translator: Translator, text: string, from: string, to: string): Promise<string> {
    const translated: string = await translator.translate(text, from, to);
    if (translated.length === 0) {
      throw new Error('翻译结果为空');
    }
    const cacheKey: string = `${from}|${to}|${text}`;
    if (this.cache.size >= CACHE_LIMIT) {
      const firstKey: string | undefined = this.cache.keys().next().value;
      if (firstKey !== undefined) {
        this.cache.delete(firstKey);
      }
    }
    this.cache.set(cacheKey, translated);
    return translated;
  }

  private notifyFallback(): void {
    if (!this.fallbackNotified) {
      this.fallbackNotified = true;
      AppStorage.setOrCreate('echo.error', '当前翻译通道不可用（额度/频率受限），已临时切换到免注册通道');
    }
  }

  private friendlyError(message: string): string {
    if (message.indexOf('HTTP') >= 0) {
      return '网络异常，翻译失败';
    }
    if (message.indexOf('百度') >= 0) {
      return message;
    }
    if (message.indexOf('DeepSeek') >= 0) {
      return message;
    }
    return `翻译失败：${message}`;
  }
}
