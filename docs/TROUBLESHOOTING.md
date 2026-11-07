# 常见问题

## 1. 安装失败：`code:9568423 ... device is unauthorized`

签名 Profile 里没有当前设备的 UDID。处理：

```powershell
# 查看设备 UDID
& 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' shell "bm get -u"
```

在 DevEco Studio 里打开项目 → `File → Project Structure → Signing Configs` → 勾选
**Automatically generate signature** → Apply → Run。DevEco 会为当前包名和设备重新生成
`.p12 / .p7b` 并写回 `build-profile.json5`。

> 当前工程的 `bundleName` 是 `com.yiertongchuan.interpreter`；签名材料需由 DevEco 自动生成（旧 `com.example.assets` 的签名已移除）。
> 换包名或换设备都要重新签名。

## 2. 界面显示“在听”，但说什么都没有反应

先确认麦克风权限，再看日志：

```powershell
$hdc = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $hdc shell "hilog -x | grep -a 'EchoAsr\|StartInnerRpc' | tail -n 40"
```

正常应看到：

```
RunCapabilityEngineStart input json : [{... "maxAudioDuration":28800000.0, "startMode":0, "vadBegin":60000.0 ...}]
EchoAsr: startListening echo_...
EchoAsr: onStart echo_... startListening success
```

- 若 `startMode` 不是 0：`StartParams.extraParams.recognitionMode` 没生效（必须是数字 `0`）。
- 若 `maxAudioDuration` 是 20000：没设置长语音时长，20 秒后会静默结束。
- 若 `vadBegin` 是 10000：空闲 10 秒就结束，属正常默认值；本项目已改为 60000。
- 若完全没有 `StartInnerRpc`：多半是权限被拒或引擎创建失败，检查 `EchoAsr: onError ...`。

## 3. 百度翻译报 `54003 Invalid Access Limit`

两类原因：

1. **语言码不对**：百度只接受 `zh` / `en`，不能传 `zh-CN` / `en-US`（本工程已做映射）。
2. **QPS / 额度限制**：免费标准版 QPS = 1。本工程已加 1.15 秒节流；若仍报错，去
   [百度翻译开放平台](https://fanyi-api.baidu.com/) → 管理控制台 → 我的服务，确认：
   - 已开通「通用文本翻译」；
   - 免费额度未用完；
   - 该 AppID 的 QPS 不为 0。

若一时无法解决，应用会自动降级到免注册通道（界面会提示），仍可正常出英文。

## 4. 有译文但没有英文声音

```powershell
& $hdc shell "hilog -x | grep -a 'EchoTts\|tts' | tail -n 40"
```

- 没有 `EchoTts: tts start`：TTS 引擎初始化失败，检查英文音色 `person = 8` 是否下载完成。
- 有 `tts start` 但听不到：检查媒体音量、是否连接了蓝牙耳机、是否被静音。
- 首次使用需要下载英文音色，下载失败会在错误条提示；可在设置里点“保存并应用”后重试。

## 5. 朗读之后又开始“自言自语”/重复翻译

外放时麦克风会拾取英文朗读，中文 ASR 可能把它识别成中文。当前版本的处理：

- **朗读期间直接暂停 ASR**，播放结束后 1.2 秒再恢复；
- 恢复后仍有 1.5 秒静默期，丢弃混响；
- 30 秒内相同句子只处理一次。

使用时请等英文播完再说下一句。如果仍有回环，建议戴耳机，或把媒体音量适当调低。
后续版本会接入系统回声消除，实现边说边译。

## 6. 退到后台 / 锁屏后不再翻译

- 确认设置里“后台持续监听”已打开；
- 系统通知栏应有“译耳同传”的常驻通知；
- 关闭电池优化：设置 → 应用 → 译耳同传 → 耗电管理 → 允许后台活动；
- 部分系统版本会限制后台麦克风，这是平台策略，应用无法完全绕过。

## 7. 日志里出现 `Exceeded the maximum audio length` / `1002200003`

`maxAudioDuration` 仍偏小或参数没生效。确认 `StartParams.extraParams.maxAudioDuration`
为数字，推荐 `28800000`（8 小时）。

## 8. 如何清空历史 / 恢复默认设置

- 历史：主界面“历史记录”右侧“清空”。
- 设置：右上角 ⚙ → 修改后“保存并应用”。
- 完全重置：卸载重装（会清除 Preferences 里的百度/DeepSeek 配置）。

## 9. 英 → 中：提示“请先填写百度语音识别的 API Key / Secret Key”

英文识别走百度智能云的**短语音识别**，和百度翻译的 AppID/密钥不是一回事：

1. 打开 [百度智能云语音识别控制台](https://console.bce.baidu.com/ai/#/ai/speech/overview/index)；
2. 创建应用 → 勾选「短语音识别」→ 进入应用详情；
3. 复制 **API Key** 和 **Secret Key**；
4. 应用切到「英 → 中」→ ⚙ → 填写并保存 → 开始监听。

密钥只保存在本机 Preferences，不会上传到除百度以外的服务。

## 10. 英 → 中：有英文但识别不出来 / 报错

先看错误条与日志：

```powershell
& $hdc shell "hilog -x | grep -a 'EchoCloudAsr\|EchoAsr' | tail -n 40"
```

| 现象 | 原因 / 处理 |
| --- | --- |
| `Client authentication failed` / `invalid_client` | 密钥不是百度 AI 应用的 API Key/Secret Key（常见：误填用户中心的 Access Key，或填了翻译 AppID） |
| `百度语音鉴权失败` / `3302` | API Key / Secret Key 填错，或应用未开通短语音识别 |
| `百度语音额度不足` / `3303` / `3304` | 免费额度用完或 QPS 超限，去控制台查看 |
| `获取百度语音 token 失败` | 网络不可用，或 Key 无效 |
| `音频质量太差` / `3301` | 离麦克风太远、环境太吵；靠近再说 |
| 一直“在听”但没文本 | 说话太轻/太短（<0.4 秒），或环境噪声把阈值抬高；安静环境重试 |
| 一句话被切碎 | VAD 静音阈值 800ms；句间停顿不要超过 0.8 秒，或后续调参 |

拿到正确密钥的路径：

1. 确认登录的是创建语音应用的百度账号；
2. 打开 [百度智能云 → 语音技术 → 语音识别](https://console.bce.baidu.com/ai/#/ai/speech/overview/index)；
3. 「应用列表」→ 目标应用 → 「应用详情」；
4. 复制 **API Key**（24 位）与 **Secret Key**（32 位）；
5. 不要用：百度翻译开放平台的 AppID/密钥、百度云「用户中心 → 安全认证」里的 Access Key/Secret Key。填好后点应用内的「测试密钥」验证。

VAD 参数在 `CloudAsrService.ets`：`SILENCE_FRAMES`（静音帧数）、`MIN_RMS`、`MAX_UTTERANCE_BYTES`。

## 11. 英 → 中：有中文译文但没有声音

- 中文音色优先 `person = 13`，失败会自动回退 `person = 0`；
- 看日志是否有 `EchoTts: tts start`：
  ```powershell
  & $hdc shell "hilog -x | grep -a 'EchoTts' | tail -n 20"
  ```
- 没有 `tts start`：检查媒体音量、是否静音、是否连接了蓝牙耳机；
- 有 `tts start` 但听不到：系统媒体音量或音频输出设备问题。

## 12. 切换方向后没有自动开始

- 切到「英 → 中」需要百度语音密钥；缺密钥会停在“待机”并显示错误条。
- 填好密钥后点一次“开始监听”；之后再启动会记住方向并自动开始。
- 运行中切换方向会重启流水线，历史记录保留。
