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
| 运行时 | Swift 6.2 工具链（Xcode 26），macOS 14+，仅 arm64；ShanshuoCore 用 Swift 6 语言模式，应用用 Swift 5 语言模式 | `scripts/build.sh` |
| 框架 | AppKit、Carbon（RegisterEventHotKey）、ApplicationServices（AX、CGEventTap）、AVFoundation；sherpa-onnx v1.13.8 C API 静态库（含 onnxruntime） | `scripts/build.sh`、`Vendor/sherpa-onnx/README.md` |
| 存储 | 本地文件：模型在 `~/Library/Application Support/Shanshuo/Models/`（开发构建读主 checkout `.work/models/`）；历史与设置为本地文件（T013/T014 实现） | `app/Shanshuo/App/Paths.swift` |
| 外部系统 | 模型下载源 Hugging Face / hf-mirror / ModelScope（T012）；首个测试版无其他网络调用 | FEAT-001 ED-009 |

## 入口与配置

| 用途 | 路径或命令 | 说明 |
|---|---|---|
| 启动 | `open <main checkout>/.work/build/Shanshuo.app` | 构建产物在主 checkout 的 `.work/build/`，不入库 |
| 主流程 | `AppDelegate`（`app/Shanshuo/App/main.swift`）→ `Qwen3Recognizer`（`app/Shanshuo/ASR/`） | 启动后在 userInitiated 串行队列后台加载模型（ED-002、ED-014） |
| 配置 | `Info.plist` 由 `scripts/build.sh` 生成；`ShanshuoDevModelDir` 仅开发构建写入；环境变量 `SHANSHUO_MODEL_DIR` 覆盖模型目录（测试用） | 不含 secret |
| 身份、权限或外部凭据 | 代码签名身份"Shanshuo Test Signing"，专用钥匙串 `<main checkout>/.work/signing/`（不入库）；运行时需要麦克风与辅助功能权限 | 钥匙串密码文件只在本机 `.work/signing/`，不入库 |

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
| 目标环境 | 开发机 Apple M5 / 16 GB / macOS 26.4（DEC-019）；被测构建以 `CFBundleVersion`（构建时间戳）识别，菜单栏首项显示。 |
| 模型与测试身份 | Qwen3-ASR-0.6B int8（`sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25`，SHA-256 见 `spikes/model-download/models.json`）；无云端凭据。 |
| 运行产物 | `.work/build/`、`.work/spm/`（gitignore）；评测结果 `bench/asr/results/`、报告 `bench/asr/reports/`（入库）。 |
| CI | none |
| 准备缺口 | Manus 代理启动的进程只用能效核，计时类指标需在用户会话中启动的应用里测（ED-014）；`open --args` 未把参数传给应用（2026-10-21 22:45 实测），命令行计时只能在用户终端运行。 |

## 变更面映射

```yaml
surfaces:
  - name: "macos-app"
    globs: ["app/**", "scripts/**", "Vendor/**"]
    roles: ["client", "security", "design"]
    modes: [correctness, e2e]
  - name: "domain-core"
    globs: ["Packages/ShanshuoCore/**"]
    roles: ["client"]
    modes: [correctness]
  - name: "asr-bench"
    globs: ["bench/**", "tests/integration/**"]
    roles: ["quality"]
    modes: [correctness]
  - name: "prototype"
    globs: ["prototype/**"]
    roles: ["design", "product-owner"]
    modes: [correctness]
```

## 工程约定与约束

| 范畴 | 已验证的约定或限制 | 依据 |
|---|---|---|
| 命名、模块与依赖 | 领域规则只放 ShanshuoCore；sherpa-onnx 版本与 SHA-256 固定在 `scripts/fetch-vendor.sh`，升级另开 Task | `Vendor/sherpa-onnx/README.md` |
| 测试、格式化与质量检查 | 新规则先写 Swift Testing 失败测试；提交前跑 `bash scripts/test.sh` | `scripts/test.sh` |
| 错误、日志与可观测性 | 应用日志不记录识别文本、输入框内容和音频（REQ-001 隐私规则）；命令行模式输出文本只用于开发测试 | `app/Shanshuo/App/CLI.swift` |
| 数据、兼容性与安全 | 音频只在内存，不落盘（REQ-001 DEC-007）；密码框中不录音（DEC-013）；Hardened Runtime + audio-input entitlement | `scripts/build.sh` |
| 禁止操作与本地指令 | 不向 main 直接推送，除非用户当次确认；功能分支提交后推送；提交带 `Co-authored-by: Manus <dev-agent@manus.ai>`；Python 用 uv | 工作区 `user.md` |

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
  canary: "测试版：CONFIG=release 构建、ED-012 身份签名的 .app/DMG，手动分发给测试用户（DEC-018，T016）"
  full: "none"
health_check: "菜单栏第二项显示\"语音模型：就绪\"；bash scripts/test.sh"
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
