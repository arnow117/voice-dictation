# 项目上下文：闪说（Shanshuo）

## 项目概览与事实边界

| 项目 | 已验证的事实 |
|---|---|
| 解决的问题与使用者 | macOS 桌面语音输入：用户在任何应用中按住全局快捷键说话，本地识别后把文字插入当前输入框。首个测试版只含 REQ-001 核心闭环（REQ-001 DEC-021）。 |
| 当前仓库范围 | 原生 macOS 菜单栏应用（`app/`、`Packages/ShanshuoCore/`）、交互原型（`prototype/`）、ASR 评测台（`bench/asr/`）、平台与下载探针（`spikes/`）、调研笔记（`research/`）、SDLC 上下文（`.sdlc-v1/`）。不拥有：sherpa-onnx 运行时与 Qwen3-ASR 模型（上游下载，固定版本与 SHA-256）。 |
| 已知运行形态 | 菜单栏应用 `Shanshuo.app`（LSUIElement，无 Dock 图标）；开发用命令行模式 `Shanshuo --transcribe <wav...>`。 |
| 事实来源 | `scripts/build.sh`、`scripts/test.sh`、`scripts/fetch-vendor.sh`、`Packages/ShanshuoCore/Package.swift`，以及 2026-10-21 22:43 `bash scripts/test.sh` 全部通过的实际运行。 |

## 仓库结构与入口

| 区域 | 路径 | 职责或使用方式 | 依据 |
|---|---|---|---|
| 应用或库入口 | `app/Shanshuo/App/main.swift` | 菜单栏应用入口；`--transcribe` 进入开发命令行 | `scripts/build.sh` |
| 主要业务代码 | `Packages/ShanshuoCore/Sources/ShanshuoCore/`（纯领域逻辑，无 AppKit、无 I/O）；`app/Shanshuo/{App,ASR,...}`（系统适配与 UI） | 领域规则只放 ShanshuoCore，应用层通过 `import ShanshuoCore` 使用 | `Packages/ShanshuoCore/Package.swift` |
| 测试与测试资产 | `Packages/ShanshuoCore/Tests/`（Swift Testing）；`tests/integration/asr_smoke.py`（构建产物 + WAV 夹具）；`bench/asr/`（准确率评测，`testset.jsonl` 入库，音频在 `.work/bench-data/`） | 单元 / 集成 / 评测三层 | `scripts/test.sh` |
| 构建、部署或自动化 | `scripts/build.sh`、`scripts/fetch-vendor.sh`、`spikes/platform/user-setup-signing.sh` | 无 Xcode 工程，swiftc 直接构建并签名（FEAT-001 ED-017） | 脚本本身 |
| 文档与操作说明 | `README.md`、`.sdlc-v1/context/*.md`、`research/*.md`、`spikes/platform/RESULTS.md`、`bench/asr/reports/` | 产品规则以 REQ 产品上下文为准，工程决定以 FEAT-001 工程上下文为准 | 各文件 |

## 技术栈

| 领域 | 使用技术 | 用途与仓库依据 |
|---|---|---|
| 运行时 | Swift 6.3.3 工具链，macOS 14+，仅 arm64；ShanshuoCore 用 Swift 6 语言模式，应用用 Swift 5 语言模式 | `scripts/build.sh`；2026-10-22 `xcrun swift --version` |
| 框架 | AppKit、Carbon（RegisterEventHotKey）、ApplicationServices（AX、CGEventTap）、AVFoundation；sherpa-onnx v1.13.8 C API 静态库（含 onnxruntime） | `scripts/build.sh`、`Vendor/sherpa-onnx/README.md` |
| 存储 | 模型在 `~/Library/Application Support/Shanshuo/Models/`（开发构建读主 checkout `.work/models/`）；历史由串行系统 SQLite3 存储，设置和引导进度使用应用 UserDefaults | `app/Shanshuo/App/Paths.swift`、`app/Shanshuo/History/HistoryStore.swift` |
| 外部系统 | 模型下载源 Hugging Face / hf-mirror（T012）；固定 revision 的 Qwen3-ASR 转换包，无 ModelScope 源；首个测试版无其他产品网络调用 | FEAT-001 ED-009 |

## 入口与配置

| 用途 | 路径或命令 | 说明 |
|---|---|---|
| 启动 | `open <main checkout>/.work/build/Shanshuo.app` | 构建产物在主 checkout 的 `.work/build/`，不入库 |
| 主流程 | `AppDelegate` → `DictationCoordinator` → 平台协议适配器、`Qwen3ASRService` → `Qwen3ChunkDecoder` / `Qwen3Recognizer` | Coordinator 为主线程会话所有者；ASR 在唯一 userInitiated 串行队列加载、使用与卸载（ED-002、ED-014，源码 `500ec4c`） |
| 配置 | `Info.plist` 由 `scripts/build.sh` 生成；release 省略 `ShanshuoDevModelDir`，修正后候选版本为 `0.1.0/1.0.2`，时间另存 `ShanshuoBuildTimestamp`；环境变量 `SHANSHUO_MODEL_DIR` 只供开发测试覆盖 | 不含 secret |
| 身份、权限或外部凭据 | 公共源码默认 ad-hoc 开发构建，可指定自己的签名身份；项目 release 显式使用既有 "Shanshuo Test Signing"，通过 `SHANSHUO_SIGNING_DIR` 或独立 keychain/password-file 路径提供本地资源 | 私钥和密码文件不入库，缺失 release 签名配置必须失败 |

## 常用命令

```yaml
commands:
  unit: "swift test --package-path Packages/ShanshuoCore --scratch-path ../../.work/spm/core --disable-sandbox"
  coverage: "none"
  e2e: "bash scripts/test.sh"
  typecheck: "bash scripts/build.sh"
  lint: "none"
  build: "bash scripts/build.sh"
```

## 验证资源与准备

| 项目 | 已验证的准备、来源或缺口 |
|---|---|
| 方式与工具 | Swift Testing（单元）；`tests/integration/asr_smoke.py`（uv，调用构建产物识别 8 条夹具，按类别检查错误率）；手测清单 `spikes/platform/CHECKLIST.md`。XCUITest 不可用（无 Xcode 工程，ED-017）。 |
| 测试资产 | `bench/asr/testset.jsonl`（入库）；音频与模型在主 checkout `.work/bench-data/`、`.work/models/`，由 `bench/asr/prepare_data.py` 与 `spikes/model-download/download.py` 重建。 |
| 目标环境 | 开发机 Apple M5 / 16 GB / macOS 26.4.1（DEC-019）；安装候选用 `CFBundleShortVersionString`、合法数字 `CFBundleVersion` 和独立 `ShanshuoBuildTimestamp` 识别。 |
| 模型与测试身份 | Qwen3-ASR-0.6B int8（`sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25`，SHA-256 见 `spikes/model-download/models.json`）；无云端凭据。 |
| 运行产物 | `.work/build/`、`.work/spm/`（gitignore）；评测结果 `bench/asr/results/`、报告 `bench/asr/reports/`（入库）。 |
| CI | none |
| 准备缺口 | 2026-10-21 Manus 环境观察到能效核限制及 `open --args` 参数问题；这些是历史环境证据，不能推定当前 Codex 进程也受相同限制。2026-10-22 原生启动日志定位布局约束异常；修正后构建 `20261022-130455` 经 CUA 打开引导，麦克风状态实际显示已授权，系统辅助功能 Shanshuo 开关已开启，引导自动推进至模型就绪步骤。密码身份验证由用户在本机完成；应用未申请输入监控。真实麦克风、调度与端到端计时仍需验证；8 个本机应用与 4 个缺失应用见 DEC-023，首版准确率例外见 DEC-024。 |

## 变更面映射

```yaml
surfaces:
  - name: "macos-app"
    globs: ["app/**", "scripts/**", "Vendor/**"]
    roles: ["client-dev", "design", "security", "qa"]
    modes: [correctness, "e2e:App"]
  - name: "domain-core"
    globs: ["Packages/ShanshuoCore/**"]
    roles: ["client-dev", "qa"]
    modes: [correctness]
  - name: "asr-bench"
    globs: ["bench/**", "tests/integration/**"]
    roles: ["server-dev", "qa"]
    modes: [correctness, eval-bench]
  - name: "prototype"
    globs: ["prototype/**"]
    roles: ["design", "product-owner", "qa"]
    modes: [correctness]
```

## 工程约定与约束

| 范畴 | 已验证的约定或限制 | 依据 |
|---|---|---|
| 命名、模块与依赖 | 领域规则只放 ShanshuoCore；sherpa-onnx 版本与 SHA-256 固定在 `scripts/fetch-vendor.sh`，升级另开 Task | `Vendor/sherpa-onnx/README.md` |
| 测试、格式化与质量检查 | 新规则先写 Swift Testing 失败测试；提交前跑 `bash scripts/test.sh` | `scripts/test.sh` |
| 错误、日志与可观测性 | 应用日志不记录识别文本、输入框内容和音频（REQ-001 隐私规则）；命令行模式输出文本只用于开发测试 | `app/Shanshuo/App/CLI.swift` |
| 数据、兼容性与安全 | 音频只在内存，不落盘（REQ-001 DEC-007）；密码框中不录音（DEC-013）；Hardened Runtime + audio-input entitlement | `scripts/build.sh` |
| 禁止操作与本地指令 | 功能分支提交后推送；主分支和公开发布通常需当次明确授权，本 Feature 已由 REQ-001 DEC-022 授权。按实际贡献者记录提交，不沿用先前工具身份；Python 用 uv | 上级 AGENTS.md、`user.md`、REQ-001 DEC-022 |

## 已知风险与未确认事实

| 风险或未确认项 | 影响区域 | 当前处理、验证方式或缺口 |
|---|---|---|
| 识别延迟（NFR-002）在性能核上的实测缺失 | `app/Shanshuo/ASR/` | 能效核 RTF 0.25～0.35；T010 闭环在应用内记录每次识别耗时作为实测 |
| 常驻内存约 1.9 GB（max_total_len 2048） | `Qwen3Recognizer` | 按最长录音时长下调 `maxTotalLen` 后复测 |
| 未在 M1 上测试 | 全部性能指标 | DEC-019，安装说明写明 |

## 部署与运行环境

```yaml
target: other
config_paths: ["scripts/build.sh", "scripts/fetch-vendor.sh"]
environments:
  dev: "开发构建：本机 .work/build/Shanshuo.app，读取 .work/models 下的模型"
  staging: "none"
  canary: "v0.1.0-beta.1：CONFIG=release，ED-012 测试签名；arm64 ZIP、DMG、SHA256SUMS.txt；未经 Apple 公证"
  full: "源码与测试版分发：仅 arnow117/voice-dictation，main 与 GitHub prerelease v0.1.0-beta.1（DEC-022/025）"
health_check: "安装路径进程及模型就绪；必要 native 回归、分发包内容与签名检查、公开资产下载后校验 SHA-256；原 NFR 未完成部分明确披露"
```

## 仓库上下文来源（Repository context sources）

```yaml
root_guidance: "none"
scoped_guidance: []
canonical_documents: [".sdlc-v1/context/REQ-001.product.md", ".sdlc-v1/context/FEAT-001.engineering.md", "research/asr-model-selection.md", "spikes/platform/RESULTS.md", "bench/asr/reports/2026-10-21-m5.md"]
repo_context:
  status: ready
  analyzed_commit: "84a9328"
```

## 长期上下文导航与维护提示

改动 `scripts/build.sh` 的链接库、签名或 Info.plist 后，同步本文件"技术栈"和"入口与配置"。升级 sherpa-onnx 或更换模型后，重跑 `bench/asr` 并更新 FEAT-001 ED-002 与报告。

## AI 可读性

一条命令 `bash scripts/test.sh` 覆盖单元测试、构建和识别冒烟测试；构建约 8 秒，识别冒烟测试约 30 秒。生成物都在主 checkout `.work/`，不进入仓库。项目没有 AGENTS.md；工作区根目录的 `user.md` 和 `soul.md` 是 Agent 行为约定。
