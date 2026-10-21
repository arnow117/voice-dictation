# 闪说

macOS 桌面端语音输入：在任意应用中按住快捷键说话，松开后由本地模型识别中英文，按需经 OpenRouter 模型整理成书面、结构化的文本，再插入当前输入框。

## 需求

| ID | 内容 | 优先级 | 依赖 | 状态 | 产品上下文 |
|---|---|---|---|---|---|
| REQ-001 | 核心闭环：Onboarding 与权限引导、按住说话、本地中英识别、插入当前输入框、录音提示与隐私 | P0 | — | Ready，开放问题 OPEN-004 待确认 | [REQ-001.product.md](.sdlc-v1/context/REQ-001.product.md) |
| REQ-002 | 识别文本书面化与结构化整理（OpenRouter） | P1 | REQ-001 | Spec 已完成，待 REQ-001 发布后进入 plan | [REQ-002.product.md](.sdlc-v1/context/REQ-002.product.md) |
| REQ-003 | 专有词与个人词典 | P1 | REQ-001 | Spec，静默学习细则 OPEN-003 待确认 | [REQ-003.product.md](.sdlc-v1/context/REQ-003.product.md) |

调研资料：[本地中英文 ASR 模型选型笔记](research/asr-model-selection.md)、[plan 阶段复用候选与 macOS 平台调研](research/plan-reuse-and-platform-notes.md)。

## 研发

| Feature | Requirement | 状态 | 研发上下文 |
|---|---|---|---|
| FEAT-001 闪说核心闭环 | REQ-001 | plan 已确认，待开始 build（16 个任务，T001～T003 验证任务可并行） | [FEAT-001.engineering.md](.sdlc-v1/context/FEAT-001.engineering.md) |

## 交互原型

`prototype/index.html` 是 spec 阶段的可交互原型（v0.3），覆盖 REQ-001～003 的首发体验：Onboarding 与权限引导、按住说话与录音提示、插入规则与修复入口、智能整理设置、词典（含从用户修改中静默学习专有词）与历史。直接用浏览器打开即可，不需要安装或联网；右侧"演示设置"面板用于切换场景和模拟系统权限、模型下载、OpenRouter 结果，"原型说明"页列出全部 20 个验收场景的操作方法。

原型里的识别和整理结果是预设句子，不代表真实模型效果。领域规则在 `prototype/domain.js`，可用 `node prototype/tests/domain.test.js` 运行状态测试。场景映射、验证证据和原型限制写在各 Requirement 产品上下文的"原型 baseline"一节。

## 测试版说明

首发只做测试版（REQ-001 DEC-018）：用固定的自签名身份签名，不做 Apple 公证，测试者第一次打开时需要在"系统设置 › 隐私与安全性"中允许打开。闪说只申请麦克风和辅助功能两项权限，不申请输入监控（DEC-017）。

性能与准确率只在开发机（Apple M5、16 GB、macOS 26.4.1）上测试，**未在 M1 等较老机型上测试，较老机型上的识别延迟可能更高**（DEC-019）。

## 进度跟踪

本项目使用 SDLC 流程管理。需求和交付进度以 `.sdlc-v1/state.json` 为准，可用 `lifecycle_state.py status` / `next` 查看；GitHub Issues 只同步阶段进展，便于查看和讨论。

## 目录

| 路径 | 内容 |
|---|---|
| `.sdlc-v1/` | SDLC 状态与需求、研发上下文 |
| `research/` | 调研笔记 |
| `prototype/` | 交互原型（spec 阶段产物） |
