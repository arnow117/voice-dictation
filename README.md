# 语音输入（暂定名）

macOS 桌面端语音输入：在任意应用中按住快捷键说话，松开后由本地模型识别中英文，按需经 OpenRouter 模型整理成书面、结构化的文本，再插入当前输入框。

## 需求

| ID | 内容 | 优先级 | 依赖 | 产品上下文 |
|---|---|---|---|---|
| REQ-001 | 核心闭环：Onboarding 与权限引导、按住说话、本地中英识别、插入当前输入框、录音提示与隐私 | P0 | — | [REQ-001.product.md](.sdlc-v1/context/REQ-001.product.md) |
| REQ-002 | 识别文本书面化与结构化整理（OpenRouter） | P1 | REQ-001 | [REQ-002.product.md](.sdlc-v1/context/REQ-002.product.md) |
| REQ-003 | 专有词与个人词典 | P1 | REQ-001 | [REQ-003.product.md](.sdlc-v1/context/REQ-003.product.md) |

调研资料：[本地中英文 ASR 模型选型笔记](research/asr-model-selection.md)。

## 进度跟踪

本项目使用 SDLC 流程管理。需求和交付进度以 `.sdlc-v1/state.json` 为准，可用 `lifecycle_state.py status` / `next` 查看；GitHub Issues 只同步阶段进展，便于查看和讨论。

## 目录

| 路径 | 内容 |
|---|---|
| `.sdlc-v1/` | SDLC 状态与需求、研发上下文 |
| `research/` | 调研笔记 |
| `prototype/` | 交互原型（spec 阶段产物） |
