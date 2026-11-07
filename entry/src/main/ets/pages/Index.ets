import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction, window } from '@kit.ArkUI';
import { SettingsService } from '../service/SettingsService';
import { InterpreterPipeline } from '../service/InterpreterPipeline';
import { CloudAsrService } from '../service/CloudAsrService';
import { AppSettings, Direction, ProviderId, Utterance } from '../model/Types';

@Entry
@Component
struct Index {
  @StorageLink('echo.status') status: string = 'idle';
  @StorageLink('echo.partialZh') partialZh: string = '';
  @StorageLink('echo.currentZh') currentZh: string = '';
  @StorageLink('echo.currentEn') currentEn: string = '';
  @StorageLink('echo.history') history: Utterance[] = [];
  @StorageLink('echo.error') errorText: string = '';
  @StorageLink('echo.provider') providerLabel: string = '免注册通道';
  @StorageLink('echo.direction') echoDirection: string = 'zh-en';

  @State running: boolean = false;
  @State busy: boolean = false;
  @State permissionDenied: boolean = false;
  @State showSettings: boolean = false;

  @State draftProvider: ProviderId = 'mymemory';
  @State draftBaiduId: string = '';
  @State draftBaiduKey: string = '';
  @State draftDeepSeekKey: string = '';
  @State draftAsrApiKey: string = '';
  @State draftAsrSecretKey: string = '';
  @State draftSpeed: number = 1.0;
  @State draftAutoStart: boolean = true;
  @State draftBackground: boolean = true;

  private pipeline: InterpreterPipeline = InterpreterPipeline.getInstance();
  private context: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.keepScreenOn();
    this.bootstrap();
  }

  onBackPress(): boolean {
    if (this.showSettings) {
      this.showSettings = false;
      return true;
    }
    return false;
  }

  private async bootstrap(): Promise<void> {
    if (this.context === null) {
      return;
    }
    await SettingsService.load(this.context);
    const settings: AppSettings = SettingsService.get();
    this.syncDraft(settings);
    this.echoDirection = settings.direction;
    const granted: boolean = await this.ensureMicrophone();
    if (!granted) {
      this.permissionDenied = true;
      return;
    }
    if (settings.autoStart) {
      await this.startListening();
    }
  }

  private syncDraft(settings: AppSettings): void {
    this.draftProvider = settings.provider;
    this.draftBaiduId = settings.baiduAppId;
    this.draftBaiduKey = settings.baiduKey;
    this.draftDeepSeekKey = settings.deepseekKey;
    this.draftAsrApiKey = settings.baiduAsrApiKey;
    this.draftAsrSecretKey = settings.baiduAsrSecretKey;
    this.draftSpeed = settings.voiceSpeed;
    this.draftAutoStart = settings.autoStart;
    this.draftBackground = settings.backgroundMode;
  }

  private async ensureMicrophone(): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const permissions: Permissions[] = ['ohos.permission.MICROPHONE' as Permissions];
      const result = await manager.requestPermissionsFromUser(this.context, permissions);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      this.permissionDenied = !granted;
      return granted;
    } catch (e) {
      this.permissionDenied = true;
      return false;
    }
  }

  private keepScreenOn(): void {
    if (this.context === null) {
      return;
    }
    window.getLastWindow(this.context).then((win: window.Window) => {
      win.setWindowKeepScreenOn(true).catch(() => {
      });
    }).catch(() => {
    });
  }

  private async startListening(): Promise<void> {
    if (this.busy || this.running || this.context === null) {
      return;
    }
    this.busy = true;
    AppStorage.setOrCreate('echo.error', '');
    try {
      await this.pipeline.start(this.context);
      this.running = this.pipeline.isActive;
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message, duration: 2500 });
    } finally {
      this.busy = false;
    }
  }

  private async stopListening(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await this.pipeline.stop();
      this.running = false;
    } finally {
      this.busy = false;
    }
  }

  private async requestAndStart(): Promise<void> {
    const granted: boolean = await this.ensureMicrophone();
    if (granted) {
      await this.startListening();
    }
  }

  private openSettings(): void {
    this.syncDraft(SettingsService.get());
    this.showSettings = true;
  }

  private async testAsrKeys(): Promise<void> {
    const apiKey: string = this.draftAsrApiKey.trim();
    const secretKey: string = this.draftAsrSecretKey.trim();
    if (apiKey.length === 0 || secretKey.length === 0) {
      promptAction.showToast({ message: '请先填写 API Key 和 Secret Key', duration: 2000 });
      return;
    }
    try {
      await CloudAsrService.probe(apiKey, secretKey);
      promptAction.showToast({ message: '密钥可用，百度语音鉴权通过', duration: 2500 });
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message, duration: 3500 });
    }
  }

  private async saveSettings(): Promise<void> {    const next: AppSettings = {
      direction: this.echoDirection as Direction,
      provider: this.draftProvider,
      baiduAppId: this.draftBaiduId.trim(),
      baiduKey: this.draftBaiduKey.trim(),
      deepseekKey: this.draftDeepSeekKey.trim(),
      baiduAsrApiKey: this.draftAsrApiKey.trim(),
      baiduAsrSecretKey: this.draftAsrSecretKey.trim(),
      voiceSpeed: this.draftSpeed,
      autoStart: this.draftAutoStart,
      backgroundMode: this.draftBackground,
      speakTranslation: true
    };
    await SettingsService.save(next);
    await this.pipeline.applySettings(next);
    this.running = this.pipeline.isActive;
    this.showSettings = false;
    promptAction.showToast({ message: '设置已保存', duration: 1600 });
  }

  private async switchDirection(next: Direction): Promise<void> {
    if (this.echoDirection === next) {
      return;
    }
    const current: AppSettings = SettingsService.get();
    const settings: AppSettings = {
      direction: next,
      provider: current.provider,
      baiduAppId: current.baiduAppId,
      baiduKey: current.baiduKey,
      deepseekKey: current.deepseekKey,
      baiduAsrApiKey: current.baiduAsrApiKey,
      baiduAsrSecretKey: current.baiduAsrSecretKey,
      voiceSpeed: current.voiceSpeed,
      autoStart: current.autoStart,
      backgroundMode: current.backgroundMode,
      speakTranslation: current.speakTranslation
    };
    await SettingsService.save(settings);
    this.echoDirection = next;
    this.syncDraft(settings);
    await this.pipeline.applySettings(settings);
    this.running = this.pipeline.isActive;
    promptAction.showToast({
      message: next === 'zh-en' ? '已切换：中文 → 英文' : '已切换：英文 → 中文',
      duration: 1600
    });
  }

  private clearHistory(): void {
    this.pipeline.clearHistory();
    promptAction.showToast({ message: '历史已清空', duration: 1200 });
  }

  private async previewSentence(): Promise<void> {
    this.showSettings = false;
    const sample: string = this.echoDirection === 'zh-en' ? '你好，很高兴认识你。' : 'Hello, nice to meet you.';
    try {
      if (this.running) {
        this.pipeline.preview(sample);
      } else {
        await this.pipeline.previewDirect(sample);
      }
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message, duration: 2500 });
    }
  }

  private sourceName(): string {
    return this.echoDirection === 'zh-en' ? '中文' : '英文';
  }

  private targetName(): string {
    return this.echoDirection === 'zh-en' ? '英文' : '中文';
  }

  private directionLabel(): string {
    return this.echoDirection === 'zh-en' ? '中 → English' : 'English → 中';
  }

  private statusText(): string {
    if (!this.running) {
      if (this.status === 'paused') {
        return '已暂停';
      }
      return this.permissionDenied ? '等待麦克风授权' : '待机';
    }
    if (this.status === 'starting') {
      return '正在启动…';
    }
    if (this.status === 'speaking') {
      return `正在朗读${this.targetName()}`;
    }
    if (this.status === 'error') {
      return '需要注意';
    }
    return this.partialZh.length > 0 ? '正在聆听…' : `在听，请说${this.sourceName()}`;
  }

  private statusHint(): string {
    if (this.permissionDenied) {
      return '授权后即可自动开始，无需再操作';
    }
    if (!this.running) {
      return '点一下开始，之后全程自动';
    }
    if (this.status === 'speaking') {
      return '朗读结束后再说下一句，避免回声';
    }
    return this.echoDirection === 'zh-en' ? '中文进 · 英文出 · 全程免动手' : '英文进 · 中文出 · 全程免动手';
  }

  private statusColor(): string {
    if (this.status === 'speaking') {
      return '#FFC66D';
    }
    if (this.status === 'error') {
      return '#FF7B7B';
    }
    return this.running ? '#5AD1FF' : '#7E93B3';
  }

  private recentHistory(): Utterance[] {
    const result: Utterance[] = [];
    for (let i = this.history.length - 1; i >= 0; i--) {
      result.push(this.history[i]);
    }
    return result;
  }

  private formatTime(ts: number): string {
    const date = new Date(ts);
    const hour: string = date.getHours().toString().padStart(2, '0');
    const minute: string = date.getMinutes().toString().padStart(2, '0');
    return `${hour}:${minute}`;
  }

  @Builder
  headerBar() {
    Row() {
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text('译耳同传')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F4F8FF')
          Text('LIVE')
            .fontSize(9)
            .fontWeight(FontWeight.Bold)
            .fontColor('#0A1524')
            .backgroundColor('#5AD1FF')
            .borderRadius(4)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        }

        Text(`${this.directionLabel()} · 实时同传`)
          .fontSize(12)
          .fontColor('#7189A8')
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Row({ space: 10 }) {
        Text(this.providerLabel)
          .fontSize(10)
          .fontColor('#9DB3D1')
          .borderRadius(10)
          .border({ width: 1, color: '#213A57' })
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })

        Text('⚙')
          .fontSize(22)
          .fontColor('#A9BCD8')
          .padding(4)
          .onClick(() => {
            this.openSettings();
          })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 16, top: 14, bottom: 8 })
  }

  @Builder
  directionChip(id: Direction, label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.echoDirection === id ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.echoDirection === id ? '#04121F' : '#9DB3D1')
      .backgroundColor(this.echoDirection === id ? '#5AD1FF' : '#132437')
      .borderRadius(16)
      .border({ width: 1, color: this.echoDirection === id ? '#5AD1FF' : '#243D58' })
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .onClick(() => {
        this.switchDirection(id);
      })
  }

  @Builder
  directionBar() {
    Row({ space: 8 }) {
      this.directionChip('zh-en', '中 → 英')
      this.directionChip('en-zh', '英 → 中')
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 8 })
  }

  @Builder
  heroCard() {
    Column({ space: 6 }) {
      Stack() {
        Circle()
          .width(176)
          .height(176)
          .fill('#0C1A2B')
          .opacity(this.running ? 0.95 : 0.55)
        Circle()
          .width(136)
          .height(136)
          .fill('#10233A')
          .border({ width: 1, color: this.running ? '#2B5E86' : '#1B3350' })
        if (this.running) {
          LoadingProgress()
            .width(54)
            .height(54)
            .color('#5AD1FF')
        } else {
          Text('🎙')
            .fontSize(44)
            .opacity(0.75)
        }
      }
      .width(180)
      .height(180)

      Row({ space: 7 }) {
        Circle()
          .width(7)
          .height(7)
          .fill(this.statusColor())
        Text(this.statusText())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E8F1FF')
      }
      .margin({ top: 2 })

      Text(this.statusHint())
        .fontSize(12)
        .fontColor('#6F86A6')
    }
    .width('100%')
    .padding({ top: 6, bottom: 10 })
  }

  @Builder
  liveLine() {
    if (this.partialZh.length > 0) {
      Row({ space: 8 }) {
        Text('正在识别')
          .fontSize(10)
          .fontColor('#5AD1FF')
          .borderRadius(4)
          .backgroundColor('#122E45')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        Text(this.partialZh)
          .fontSize(13)
          .fontColor('#9FC0E4')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor('#0E1B2C')
      .borderRadius(14)
      .border({ width: 1, color: '#1B3450' })
      .margin({ bottom: 10 })
    }
  }

  @Builder
  translationCard() {
    Column() {
      Row() {
        Text('最近一句')
          .fontSize(11)
          .fontColor('#7891B0')
        Blank()
        if (this.status === 'speaking') {
          Row({ space: 5 }) {
            Text('🔊')
              .fontSize(11)
            Text('朗读中')
              .fontSize(10)
              .fontColor('#FFC66D')
          }
        }
      }
      .width('100%')
      .margin({ bottom: 10 })

      if (this.currentZh.length > 0) {
        Text(this.currentZh)
          .fontSize(15)
          .fontColor('#93A9C5')
          .lineHeight(22)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Divider()
          .color('#1C3049')
          .margin({ top: 10, bottom: 10 })

        if (this.currentEn.length > 0) {
          Text(this.currentEn)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F8FF')
            .lineHeight(28)
            .width('100%')
        } else {
          Row({ space: 6 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color('#5AD1FF')
            Text('翻译中…')
              .fontSize(14)
              .fontColor('#6F86A6')
          }
        }
      } else {
        Text(`说一句${this.sourceName()}，${this.targetName()}译文会出现在这里`)
          .fontSize(14)
          .fontColor('#5D7492')
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#101D2F')
    .borderRadius(20)
    .border({ width: 1, color: '#1D3550' })
    .margin({ bottom: 14 })
  }

  @Builder
  historyItem(item: Utterance) {
    Column({ space: 5 }) {
      Row() {
        Text(this.formatTime(item.ts))
          .fontSize(10)
          .fontColor('#5D7492')
        Blank()
        if (item.state === 'error') {
          Text('失败')
            .fontSize(10)
            .fontColor('#FF8E8E')
        }
      }

      Text(item.zh)
        .fontSize(13)
        .fontColor('#8EA6C4')
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (item.state === 'error') {
        Text(item.error ?? '翻译失败')
          .fontSize(13)
          .fontColor('#FF9B9B')
          .width('100%')
      } else if (item.en.length > 0) {
        Text(item.en)
          .fontSize(15)
          .fontColor('#E4EEFB')
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text('翻译中…')
          .fontSize(13)
          .fontColor('#5D7492')
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 13, right: 13, top: 10, bottom: 10 })
    .backgroundColor('#0D1928')
    .borderRadius(14)
    .border({ width: 1, color: '#172B42' })
    .margin({ bottom: 8 })
  }

  @Builder
  historySection() {
    Row() {
      Text('历史记录')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#9FB4D0')
      Text(` · ${this.history.length}`)
        .fontSize(11)
        .fontColor('#5D7492')
      Blank()
      if (this.history.length > 0) {
        Text('清空')
          .fontSize(11)
          .fontColor('#6F86A6')
          .onClick(() => {
            this.clearHistory();
          })
      }
    }
    .width('100%')
    .margin({ bottom: 8 })

    if (this.history.length === 0) {
      Column() {
        Text('还没有记录')
          .fontSize(13)
          .fontColor('#516886')
        Text('开始监听后，这里会按时间倒序保存每一句')
          .fontSize(11)
          .fontColor('#41566F')
          .margin({ top: 4 })
      }
      .width('100%')
      .padding({ top: 18, bottom: 18 })
      .backgroundColor('#0B1524')
      .borderRadius(14)
      .border({ width: 1, color: '#142639' })
    } else {
      ForEach(this.recentHistory(), (item: Utterance) => {
        this.historyItem(item)
      }, (item: Utterance) => item.id)
    }
  }

  @Builder
  footerBar() {
    Column({ space: 8 }) {
      Button(this.running ? (this.busy ? '处理中…' : '暂停监听') : '开始监听')
        .width('100%')
        .height(54)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.running ? '#DCE9FA' : '#04121F')
        .backgroundColor(this.running ? '#16283D' : '#5AD1FF')
        .borderRadius(27)
        .border({ width: this.running ? 1 : 0, color: '#2C4B6B' })
        .enabled(!this.busy)
        .onClick(() => {
          if (this.running) {
            this.stopListening();
          } else {
            this.startListening();
          }
        })

      Text('无需手动操作 · 自动续听 · 自动朗读')
        .fontSize(10)
        .fontColor('#4E6480')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 12 })
  }

  @Builder
  errorBanner() {
    if (this.errorText.length > 0) {
      Row({ space: 8 }) {
        Text('!')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFDADA')
          .width(18)
          .height(18)
          .textAlign(TextAlign.Center)
          .borderRadius(9)
          .backgroundColor('#6B2A2A')
        Text(this.errorText)
          .fontSize(11)
          .fontColor('#FFC9C9')
          .layoutWeight(1)
          .maxLines(2)
        Text('×')
          .fontSize(16)
          .fontColor('#D89A9A')
          .onClick(() => {
            AppStorage.setOrCreate('echo.error', '');
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#2A1518')
      .borderRadius(12)
      .border({ width: 1, color: '#4A2226' })
      .margin({ left: 20, right: 20, bottom: 10 })
    }
  }

  @Builder
  permissionCard() {
    if (this.permissionDenied) {
      Column({ space: 8 }) {
        Text('需要麦克风权限才能开始')
          .fontSize(14)
          .fontColor('#E8F1FF')
        Text('译耳同传只在本机监听，语音不会上传；仅翻译文本会发送到所选翻译服务。')
          .fontSize(11)
          .fontColor('#7E93B3')
          .lineHeight(17)
        Button('授权麦克风')
          .height(38)
          .fontSize(13)
          .fontColor('#04121F')
          .backgroundColor('#5AD1FF')
          .borderRadius(19)
          .onClick(() => {
            this.requestAndStart();
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(16)
      .backgroundColor('#101D2F')
      .borderRadius(16)
      .border({ width: 1, color: '#1D3550' })
      .margin({ bottom: 14 })
    }
  }

  @Builder
  providerChip(id: ProviderId, label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.draftProvider === id ? '#04121F' : '#9DB3D1')
      .backgroundColor(this.draftProvider === id ? '#5AD1FF' : '#14263A')
      .borderRadius(15)
      .border({ width: 1, color: this.draftProvider === id ? '#5AD1FF' : '#243D58' })
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(36)
      .onClick(() => {
        this.draftProvider = id;
      })
  }

  @Builder
  asrSettingsSection() {
    Column({ space: 8 }) {
      Text('英文识别（百度短语音）')
        .fontSize(12)
        .fontColor('#8EA6C4')
        .width('100%')
      TextInput({ text: this.draftAsrApiKey, placeholder: '百度语音 API Key' })
        .height(42)
        .fontSize(13)
        .fontColor('#E8F1FF')
        .placeholderColor('#5D7492')
        .backgroundColor('#0C1A2B')
        .borderRadius(10)
        .onChange((value: string) => {
          this.draftAsrApiKey = value;
        })
      TextInput({ text: this.draftAsrSecretKey, placeholder: '百度语音 Secret Key' })
        .type(InputType.Password)
        .height(42)
        .fontSize(13)
        .fontColor('#E8F1FF')
        .placeholderColor('#5D7492')
        .backgroundColor('#0C1A2B')
        .borderRadius(10)
        .onChange((value: string) => {
          this.draftAsrSecretKey = value;
        })
      Text('在百度智能云控制台开通「短语音识别」，复制应用详情里的 API Key / Secret Key（不是百度翻译 AppID，也不是用户中心的 Access Key）。')
        .fontSize(11)
        .fontColor(this.draftAsrApiKey.length === 0 || this.draftAsrSecretKey.length === 0 ? '#FFB36B' : '#6F86A6')
        .lineHeight(17)
        .width('100%')
      Button('测试密钥')
        .width('100%')
        .height(36)
        .fontSize(12)
        .fontColor('#9DB3D1')
        .backgroundColor('#14263A')
        .borderRadius(18)
        .onClick(() => {
          this.testAsrKeys();
        })
    }
    .width('100%')
  }

  @Builder
  settingsPanel() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F7FF')
        Blank()
        Text('完成')
          .fontSize(14)
          .fontColor('#5AD1FF')
          .onClick(() => {
            this.showSettings = false;
          })
      }
      .width('100%')
      .margin({ bottom: 4 })

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 8 }) {
            Text('翻译通道')
              .fontSize(12)
              .fontColor('#8EA6C4')
              .width('100%')
            Row({ space: 8 }) {
              this.providerChip('mymemory', '免注册')
              this.providerChip('baidu', '百度')
              this.providerChip('deepseek', 'DeepSeek')
            }
            .width('100%')

            if (this.draftProvider === 'mymemory') {
              Text('无需配置、开箱即用；公共接口有每日额度，适合试用。正式使用建议配置百度翻译或 DeepSeek。')
                .fontSize(11)
                .fontColor('#6F86A6')
                .lineHeight(17)
                .width('100%')
            } else if (this.draftProvider === 'baidu') {
              TextInput({ text: this.draftBaiduId, placeholder: '百度翻译 AppID' })
                .height(42)
                .fontSize(13)
                .fontColor('#E8F1FF')
                .placeholderColor('#5D7492')
                .backgroundColor('#0C1A2B')
                .borderRadius(10)
                .onChange((value: string) => {
                  this.draftBaiduId = value;
                })
              TextInput({ text: this.draftBaiduKey, placeholder: '百度翻译密钥' })
                .type(InputType.Password)
                .height(42)
                .fontSize(13)
                .fontColor('#E8F1FF')
                .placeholderColor('#5D7492')
                .backgroundColor('#0C1A2B')
                .borderRadius(10)
                .onChange((value: string) => {
                  this.draftBaiduKey = value;
                })
              Text('在百度翻译开放平台申请「通用翻译」应用，免费额度足够日常使用。')
                .fontSize(11)
                .fontColor('#6F86A6')
                .width('100%')
            } else {
              TextInput({ text: this.draftDeepSeekKey, placeholder: 'DeepSeek API Key' })
                .type(InputType.Password)
                .height(42)
                .fontSize(13)
                .fontColor('#E8F1FF')
                .placeholderColor('#5D7492')
                .backgroundColor('#0C1A2B')
                .borderRadius(10)
                .onChange((value: string) => {
                  this.draftDeepSeekKey = value;
                })
              Text('DeepSeek 译文更自然，但响应比百度翻译慢一些。')
                .fontSize(11)
                .fontColor('#6F86A6')
                .width('100%')
            }
          }
          .width('100%')

          if (this.echoDirection === 'en-zh') {
            Divider().color('#1B2E45')
            this.asrSettingsSection()
          }

          Divider().color('#1B2E45')

          Column({ space: 8 }) {
            Row() {
              Text('朗读语速')
                .fontSize(12)
                .fontColor('#8EA6C4')
              Blank()
              Text(`${this.draftSpeed.toFixed(2)}x`)
                .fontSize(12)
                .fontColor('#5AD1FF')
            }
            .width('100%')

            Slider({
              value: this.draftSpeed,
              min: 0.8,
              max: 1.5,
              step: 0.05,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .selectedColor('#5AD1FF')
              .onChange((value: number) => {
                this.draftSpeed = Math.round(value * 100) / 100;
              })
          }
          .width('100%')

          Divider().color('#1B2E45')

          Row() {
            Column({ space: 3 }) {
              Text('打开应用自动监听')
                .fontSize(13)
                .fontColor('#DCE9FA')
              Text('免去每次点击')
                .fontSize(10)
                .fontColor('#6F86A6')
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.draftAutoStart })
              .selectedColor('#5AD1FF')
              .onChange((isOn: boolean) => {
                this.draftAutoStart = isOn;
              })
          }
          .width('100%')

          Row() {
            Column({ space: 3 }) {
              Text('后台持续监听')
                .fontSize(13)
                .fontColor('#DCE9FA')
              Text('锁屏后仍可收音（通知栏常驻）')
                .fontSize(10)
                .fontColor('#6F86A6')
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.draftBackground })
              .selectedColor('#5AD1FF')
              .onChange((isOn: boolean) => {
                this.draftBackground = isOn;
              })
          }
          .width('100%')

          Button('保存并应用')
            .width('100%')
            .height(46)
            .fontSize(15)
            .fontColor('#04121F')
            .backgroundColor('#5AD1FF')
            .borderRadius(23)
            .margin({ top: 4 })
            .onClick(() => {
              this.saveSettings();
            })

          Button(this.echoDirection === 'zh-en' ? '试听：你好，很高兴认识你' : '试听：Hello, nice to meet you')
            .width('100%')
            .height(40)
            .fontSize(12)
            .fontColor('#9DB3D1')
            .backgroundColor('#132437')
            .borderRadius(20)
            .onClick(() => {
              this.previewSentence();
            })

          Text('隐私：语音识别在设备本地完成；仅识别出的中文文本会发送给所选翻译服务。')
            .fontSize(10)
            .fontColor('#4E6480')
            .lineHeight(15)
            .width('100%')
            .margin({ bottom: 8 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .margin({ top: 10 })
    }
    .width('100%')
    .height('78%')
    .padding({ left: 20, right: 20, top: 18, bottom: 16 })
    .backgroundColor('#0E1A29')
    .borderRadius({ topLeft: 24, topRight: 24 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.headerBar()
        this.directionBar()

        Scroll() {
          Column() {
            this.errorBanner()
            this.permissionCard()
            this.heroCard()
            this.liveLine()
            this.translationCard()
            this.historySection()
            Blank().height(10)
          }
          .width('100%')
          .padding({ left: 20, right: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)

        this.footerBar()
      }
      .width('100%')
      .height('100%')

      if (this.showSettings) {
        Column() {
          Blank()
            .width('100%')
            .layoutWeight(1)
            .onClick(() => {
              this.showSettings = false;
            })
          this.settingsPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#080E18')
    .linearGradient({
      angle: 160,
      colors: [['#0A1422', 0.0], ['#0B1727', 0.5], ['#070C14', 1.0]]
    })
  }
}
