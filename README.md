# 译耳同传 · YierTong

一款鸿蒙（HarmonyOS）实时同传应用：**持续监听语音 → 自动翻译 → 用目标语言朗读**，全程无需手动操作。
支持 **中文 → 英文** 与 **英文 → 中文** 双向同传。

> 当前版本：v0.2.1（中 ↔ 英）。英文识别走百度短语音，其余保持离线 / 可插拔。

## 代码仓库

GitHub：<https://github.com/xuzhiweiand/yiertongchuan-interpreter>

- 默认分支：`main`
- 远程：`git@github.com:xuzhiweiand/yiertongchuan-interpreter.git`
- 归档时使用 SSH；当前网络如无法访问 GitHub，先本地提交，网络恢复后执行 `git push -u origin main`。

## 已实现

- **双向同传**：顶部一键切换「中 → 英 / 英 → 中」，翻译、音色、字幕顺序同步切换。
- **实时监听（中→英）**：Core Speech Kit 离线中文识别，长语音模式 + 自动续接，长时间不中断。
- **实时监听（英→中）**：自建 16k PCM 采集 + 能量 VAD 断句 + 百度短语音识别（英文），20 秒或 800ms 静音切句。
- **逐句翻译**：识别到一句立即翻译，翻译与朗读流水线并行，减少等待。
- **目标语言朗读**：英文用 en-US Laura，中文用 zh-CN 凌小珊；支持语速调节。
- **免手动**：打开应用自动开始；会话结束/异常自动恢复；锁屏后台继续（长时任务）。
- **可插拔翻译**：免注册公共通道 / 百度翻译 / DeepSeek，应用内设置，无需改代码。
- **界面**：实时字幕、当前译文、历史记录、运行状态与错误提示。

## 应用图标

深海军蓝渐变 + 青色辉光的「听」符号（耳 + 声波），与界面强调色 `#5AD1FF` 一致：

- 预览：[`docs/icon/app-icon-1024.png`](docs/icon/app-icon-1024.png) · 多尺寸效果 [`docs/icon/icon-preview.png`](docs/icon/icon-preview.png)
- 生成脚本：`scripts/make_icon.py`（Pillow，确定性重建；符号取自 Material Icons，Apache-2.0）
- 资源落点：
  - `AppScope/resources/base/media/app_icon.png`（应用图标，1024×1024）
  - `entry/src/main/resources/base/media/background.png` + `foreground.png`（分层图标，1024×1024）
  - `entry/src/main/resources/base/media/startIcon.png`（启动页图标，288×288）

## 英文 → 中文：一次性配置

英文语音识别需要百度智能云的**短语音识别**密钥（与百度翻译的 AppID/密钥不是同一个）：

1. 打开 [百度智能云语音识别控制台](https://console.bce.baidu.com/ai/#/ai/speech/overview/index)，创建应用；
2. 勾选「短语音识别」，进入应用详情复制 **API Key** 与 **Secret Key**；
3. 应用内切到「英 → 中」→ 右上角 ⚙ → 填写「百度语音 API Key / Secret Key」→ 保存并应用；
4. 点「开始监听」，说一句英文，停顿后即可看到中文并听到中文朗读。

> 短语音识别有免费调用额度；超出后按百度计费。密钥只保存在本机 Preferences 中。

## 环境要求

| 项 | 版本 |
| --- | --- |
| DevEco Studio | 26.0（本机 `D:\Program Files\Huawei\DevEco Studio`，`scripts/build.ps1` 会自动探测） |
| HarmonyOS SDK | API 26（`sdk/default/openharmony` + `sdk/default/hms`） |
| 真机 | HarmonyOS 6.0+（本项目在 HUAWEI Pura X，API 26 上开发） |
| Node | DevEco 自带 `tools/node`（v24） |

## 真机验证（2026-11-07，HUAWEI Pura X / API 26）

已新增 2026-11-08：v0.2.1（新图标）重新打包，`hdc install -r` 升级安装并启动通过，设备侧 `versionCode 1000002 / versionName 0.2.1`。

已完成一轮真机闭环，关键结论：

- 中文识别正常：连续说话能按句出中文，长语音会话空闲结束会自动续接。
- 百度翻译正常：修正了语言代码（百度只认 `zh` / `en`，不认 `zh-CN` / `en-US`）并加入 QPS 节流。
- 英文朗读正常：`tts start` 与播放完成回调均触发，英文音色可用。
- 中文朗读正常：英→中方向下 `Hello, nice to meet you.` → `你好，很高兴认识你。`，`tts start` 已触发。
- 方向切换与界面同步正常；英文识别在补齐百度语音密钥后即可启用。
- 回声抑制：朗读期间暂停 ASR，播放结束后 1.2 秒恢复；外放时等译文播完再说下一句即可。
- 免注册通道兜底：主通道异常时自动降级，保证仍有译文输出。

## 构建

在项目根目录执行（PowerShell）：

```powershell
.\scripts\build.ps1
```

或手动执行：

```powershell
$env:DEVECO_SDK_HOME = 'D:\Program Files\Huawei\DevEco Studio\sdk'
$env:NODE_HOME      = 'D:\Program Files\Huawei\DevEco Studio\tools\node'
& 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' `
  --mode module -p product=default -p buildMode=debug assembleHap
```

产物：

```
entry/build/default/outputs/default/entry-default-signed.hap
```

未配置签名时会生成 `entry-default-unsigned.hap`；上架/安装前需先完成 DevEco 自动签名。首次构建约 10 分钟，增量构建约 1 分钟。

## 安装与签名（重要）

项目 `bundleName` 已固定为 **`com.yiertongchuan.interpreter`**。旧的调试签名材料（绑定 `com.example.assets`）已经移除，
`build-profile.json5` 里的 `signingConfigs` 为空，需要由 DevEco 为新的包名重新生成。

首次运行：

1. 用 DevEco Studio 打开项目根目录；
2. `File → Project Structure → Signing Configs`，勾选 **Automatically generate signature**；
3. 登录华为开发者账号，Apply；
4. 直接点 Run，DevEco 会生成 `.p12 / .p7b` 并写入 `build-profile.json5`，然后安装到当前设备。

如果安装报：

```
code:9568423 ... the device is unauthorized, make sure the UDID of your device is configured in the signing profile
```

说明当前签名 Profile 没包含这台设备，重新执行一次自动签名即可。

> `bundleName` 一经上架 / APP 备案就不能修改；如确需更换，必须同步更新软著、备案、AGC 应用和签名，
> 并视为一个新应用。签名材料不要提交到代码仓库。

安装 / 启动命令：

```powershell
.\scripts\install.ps1
```

或手动：

```powershell
$hdc = 'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc install -r .\entry\build\default\outputs\default\entry-default-signed.hap
& $hdc shell "aa start -a EntryAbility -b com.yiertongchuan.interpreter"
```

## 使用

1. 首次启动授权麦克风（仅一次）。
2. 顶部选择方向：`中 → 英` 或 `英 → 中`（会记住上次选择）。
3. 应用自动开始监听，状态显示“在听，请说中文/英文”。
4. 说一句，停顿约 0.5 秒，界面出现源语言与译文，随后自动朗读译文。
5. 点右上角 ⚙ 配置翻译通道、英文识别密钥、语速、后台监听。

### 翻译通道

| 通道 | 配置 | 说明 |
| --- | --- | --- |
| 免注册通道（默认） | 无 | MyMemory 公共接口，开箱即用，有每日额度，适合试用 |
| 百度翻译 | AppID + 密钥 | 速度快、免费额度够日常；[百度翻译开放平台](https://fanyi-api.baidu.com/) 申请 |
| DeepSeek | API Key | 译文更自然，延迟略高；适合对质量要求高的场景 |

> 隐私：中→英时语音识别在设备本地完成，原始音频不上传；英→中时英文音频会发送到百度短语音识别，识别文本发送给所选翻译服务。

## 目录

```
AppScope/                     应用级配置与图标
entry/src/main/ets/
  entryability/EntryAbility   入口、窗口常亮、共享状态初始化
  pages/Index.ets             主界面（监听、译文、历史、设置）
  model/Types.ets             设置 / 记录 / 状态类型
  service/
    AsrEngine.ets             识别引擎接口（系统 / 云端）
    AsrService.ets            中文长语音识别 + 自动续接
    CloudAsrService.ets       英文 PCM 采集 + VAD + 百度短语音识别
    TtsService.ets            中/英音色检查、下载、朗读队列
    Translator.ets            翻译通道（MyMemory / 百度 / DeepSeek）+ 缓存
    InterpreterPipeline.ets   识别 → 翻译 → 朗读 主流水线
    SettingsService.ets       设置持久化（Preferences）
    BackgroundService.ets     audioRecording 长时任务
docs/DESIGN.md                设计说明与后续版本方案
docs/TEST-PLAN.md             真机测试清单
docs/TROUBLESHOOTING.md       常见问题（识别不到、百度 54003、无声、回声）
docs/RELEASE.md               上架/备案信息、签名与提审清单
scripts/build.ps1             一键构建
scripts/install.ps1           一键安装并启动
```

## 已知限制

- **中→英识别**：系统离线语音识别目前只支持中文（`zh-CN`）；本项目已实测 `en-US` 无法创建引擎。
- **英→中识别**：依赖百度短语音识别，需要联网并配置 API Key / Secret Key；按句上传，存在约 1–2 秒额外延迟。
- **必须联网**：系统未开放端侧文本翻译 API，翻译需要网络。
- **音色**：英文音色（person 8）首次使用需下载；中文音色优先 person 13，失败自动回退 person 0。
- **空闲重建**：中→英长语音会话在 60 秒无人说话时会结束并自动重开，约有 0.3 秒空隙。
- **VAD 断句**：英→中依赖能量阈值，嘈杂环境可能切碎或漏句；可在安静环境使用或后续调参。
- **朗读时暂停收音**：为避免外放回声形成“自说自话”，朗读期间 ASR 暂停，结束后 1.2 秒恢复；适合一句一顿的对话。戴耳机可进一步减少限制。
- **后台**：锁屏持续监听依赖 `audioRecording` 长时任务，系统可能在极端省电策略下回收；界面会显示状态。

更多排查步骤见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 版本路线

- **v0.2（当前）**：中 ↔ 英双向、英文云端识别、双语 TTS、方向切换。
- **v0.3**：百度实时语音识别（WebSocket）降低英文延迟；VAD 自适应降噪；耳机模式。
- **v0.4**：对话模式（区分说话人）、字幕悬浮窗、历史导出。
- **v1.0**：端侧翻译/识别模型、离线包、双屏面对面对话。
