# plan 阶段调研笔记：复用候选与 macOS 平台事实（2026-10-21）

## 复用候选

- **Handy**（https://github.com/cjpais/handy，2026-10-21 查阅）：MIT 许可；Tauri + Rust；按住或切换录音、录音浮层、粘贴到当前输入框、历史、词典（Raycast 扩展可管理）、`--toggle-post-process` 后处理；引擎为 Whisper（Small/Medium/Turbo/Large）和 Parakeet，使用 Silero VAD。README 说明：fn（Globe）快捷键只在 Apple 键盘上触发，第三方键盘在固件内处理 Fn、不发送事件；标准剪贴板粘贴在固定延时后恢复旧剪贴板，负载高时目标应用可能读到旧内容（issue #502），Debug 中有 "Reliable Paste (Beta)"，使用剪贴板读取通知推迟恢复。Handy 名称、Logo、图标等品牌资产不开源，fork 必须换品牌。
- **VoiceInk**（https://github.com/beingpax/VoiceInk，2026-10-21 查阅）：GPL-3.0；原生 macOS（14.4+）；whisper.cpp、FluidAudio（Parakeet）、TranscribeCpp（GGUF）、SenseVoice Small；个人词典、按应用切换模式、屏幕上下文、AI 助手；不接受 PR。
- **clips 模板**（本地 `workspace/20260922-agent-native-research/templates/clips/desktop`，Tauri）：`src-tauri/src/shortcuts.rs` 用 ListenOnly CGEventTap 监听 SecondaryFn 标志位，按边沿触发开始与结束，代码注释写明 ListenOnly tap 需要输入监控权限、仅有辅助功能不够，并处理 TapDisabledByTimeout/UserInput；`clips/mod.rs` 的 `insert_text_for_frontmost` 对 GUI 应用用剪贴板粘贴并恢复，对终端用 Unicode 输入；`permission_status.rs` 用 `CGPreflightListenEventAccess`；系统设置深链接形如 `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility` / `?Privacy_ListenEvent` / `?Privacy_Microphone`。未找到许可证文件，只参考思路。

## sherpa-onnx

- 最新发布 v1.13.8（GitHub release，2026-09-10）；crates.io 上 `sherpa-onnx` crate 1.13.8（2026-09-11）。
- C API（https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/c-api/c-api.h）定义 `SherpaOnnxOfflineQwen3ASRModelConfig`：`conv_frontend`、`encoder`、`decoder`（带 KV cache）、`tokenizer` 目录、`max_total_len`、`max_new_tokens`、`temperature`、`top_p`、`seed`、`hotwords`（逗号分隔 UTF-8）。离线识别器另有 `SherpaOnnxCreateOfflineStreamWithHotwords`；它对 Qwen3-ASR 是否按单个 stream 生效，有待验证。
- 官方 Swift 封装 `swift-api-examples/SherpaOnnx.swift` 有 `sherpaOnnxOfflineQwen3ASRModelConfig(...)`，离线模型配置的参数为 `qwen3Asr`。

## OpenRouter ZDR

- https://openrouter.ai/docs/features/zdr（2026-10-21 查阅）：OpenRouter 跟踪每个端点的数据政策；无法确认政策的端点按"会保存且会训练"处理。请求中 `provider.zdr: true` 时只路由到有零数据保留政策的端点；请求级参数与账户级、guardrail 级设置是"或"关系，只能加严，不能关闭账户级强制。提供商数据中心内对提示词的内存缓存不算"保存"，ZDR 下仍允许。

## macOS 剪贴板隐私

- Apple 在 macOS 15.4 预告：应用以程序方式读取通用剪贴板时，将向用户弹出提示；`NSPasteboard` 新增 `accessBehavior`，以及不触发提示的检测接口（detect patterns/metadata）；系统设置隐私中新增"从其他应用粘贴"（Paste from Other Apps）。来源：https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/ 、https://developer.apple.com/documentation/appkit/nspasteboard-detection-patterns 、https://www.idownloadblog.com/2025/05/14/apple-macos-16-clipboard-privacy-prompt/ 。当前 macOS 26.4.1 是否默认启用，尚未找到确认来源，需实机验证（FEAT-001 T002）。

## 本机环境

- Apple M5，16 GB，macOS 26.4.1（25E253），Xcode 26.6（17F113），Swift 6.3.3；已装 cargo/rustc；未找到 "Developer ID Application" 签名证书。
