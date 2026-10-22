# 参与开发

欢迎提交问题与 Pull Request。讨论和文档可以使用中文。

## 开始之前

先阅读 [README](README.md)、[项目上下文](.sdlc-v1/project.md)和
[当前核心流程方案](.sdlc-v1/context/FEAT-001.engineering.md)。
首版范围是本地按住说话、权限引导、模型管理、插入和隐私控制。
文本整理与个人词典在独立需求中跟踪。

需要 Apple Silicon Mac、macOS 14 或以上、Xcode Command Line Tools。
Python 工具使用 [uv](https://docs.astral.sh/uv/)；日常应用运行不需要 Python。
构建、签名和测试的实际命令以 README 为准。

## 修改约定

- 可测试的业务规则放在 `Packages/ShanshuoCore`，系统 API 放在应用适配层。
- 涉及录音、取消、焦点、安全输入和剪贴板的改动，应提供对应失败场景的验证。
- 保持正常缩进与逻辑分段，用 Xcode 自带的 `swift-format` 格式化本次修改。
- 日志只记录事件、错误码和耗时，不记录听写文本、输入框内容和音频。
- 不提交 `.work/`、模型、录音、签名私钥、钥匙串或个人使用数据。
- Pull Request 说明实际行为变化、验证命令和尚未验证的环境。

应用没有账户和遥测，调试时请使用自建测试文本，不要把私人听写记录附到公开 Issue。
安全问题按 [SECURITY.md](SECURITY.md) 处理。

提交贡献表示你有权按本项目 MIT 许可提供该贡献。
第三方代码、模型及评测数据须保留各自许可，见
[第三方声明](THIRD_PARTY_NOTICES.md)。
