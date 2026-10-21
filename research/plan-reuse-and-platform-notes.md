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

## 补充：快捷键权限、自动学习与剪贴板（2026-10-21 20:50 后）

**只用辅助功能就能监听快捷键。** Apple 开发者论坛帖子 https://developer.apple.com/forums/thread/828082 （2026-05，macOS 15，已签名并公证的应用）描述：在授予辅助功能之前，listen-only 的 `CGEvent.tapCreate` 返回 nil；授予辅助功能之后，tap 创建成功，而应用依然不出现在"输入监控"列表里。`NSEvent.addGlobalMonitorForEvents` 的官方文档写明，按键类事件只有在辅助功能开启、或应用被辅助功能信任时才能监听（https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching:handler:%29）。Wispr Flow 的安装说明只要求麦克风和辅助功能（https://docs.wisprflow.ai/articles/3152211871-setup-guide），Handy 的 README 写的也是 "microphone, accessibility"。另一篇实测文章（https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/）认为监听全局事件需要输入监控，并指出两点：重新签名后 TCC 会把应用当成新身份，tap 虽然存在但收不到事件；因此要定时检查 `tapIsEnabled`，失效时重新安装。两处说法不一致，以 FEAT-001 T002 的实机结果为准。不授予任何权限时，只能用 Carbon `RegisterEventHotKey` 注册"修饰键 + 普通键"组合，它能收到按下和松开事件，但无法注册单独的 Fn 或右 Option。

**Wispr Flow 的自动学习。** 官方文档 https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary ：只有打开 "auto-learn words" 并且用户修改了听写出来的文字时，Flow 才会把改正的词自动加入个人词典；在桌面端删除词条是永久的，自动学习不会把已删除的词再学回来；自动学到的词与手动添加的词放在同一个词典中，之后可以再为它补上误拼写。功能页 https://wisprflow.ai/features ："When you correct a spelling, Flow adds it automatically to your personal dictionary." Reddit 用户反馈该开关位于 Settings → System → Extras → Auto-Add to Dictionary。

**本机剪贴板策略实测。** 在 macOS 26.4.1（25E253）上编译并运行一段只读取 `NSPasteboard.general.accessBehavior` 的程序（不读取剪贴板内容），结果为 rawValue 2，对应 `.alwaysAllow`（枚举值：default 0、ask 1、alwaysAllow 2、alwaysDeny 3）。说明当前系统对这个进程没有启用"读取剪贴板需询问"；但该进程由终端启动，权限可能归属终端，独立 .app 的行为仍需在 T002 中实测。本机 `security find-identity -v -p codesigning` 结果为 0 个有效签名身份。
