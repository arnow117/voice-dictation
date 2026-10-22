# 闪说

macOS 桌面端语音输入：在任意应用中按住快捷键说话，松开后由本地模型识别中英文，并安全地插入或复制到当前输入框。书面化、结构化整理和词典属于后续的 REQ-002、REQ-003。

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

## 当前核心闭环（开发构建）

运行 `bash scripts/test.sh` 会执行 Swift 单元测试、构建并签名 `.work/build/Shanshuo.app`，然后使用本地 ASR 夹具进行冒烟检查。正常启动菜单栏应用时只采集麦克风输入；`--transcribe <wav>` 是显式的开发/测试 CLI，不是产品运行路径。

应用需要麦克风权限。授予辅助功能权限后，默认按住 Fn 录音；松开后在确认过的同一可编辑目标中直接插入。未授予辅助功能权限时，按住 ⌃⇧ Space 进入仅复制模式，结果写入剪贴板，由用户自行粘贴。应用不会请求输入监控权限。

录音胶囊和菜单栏状态先变为“正在录音”才开始采集。按 Esc、在按住快捷键时再按其他键、进入安全输入框、系统睡眠/锁屏、麦克风或直接插入权限被撤销，都会立即丢弃本次会话。短于 0.3 秒的按压丢弃；单次录音最多 3 分钟，最后 15 秒显示倒计时。焦点变化、未知或不可编辑时会复制而不会向新目标模拟输入。

## 语音模型

菜单栏的“管理语音模型…”打开原生模型窗口。首版只提供 **Qwen3-ASR 0.6B（INT8）**：首次使用从 Hugging Face 下载，失败时可切换到 hf-mirror；窗口可暂停、继续、重试、修复和删除应用下载的模型。每个文件会流式写入 `.part`，按固定 revision、大小和 SHA-256 校验，通过后才原子替换为正式文件并加载运行时。

生产模型目录是 `~/Library/Application Support/Shanshuo/Models/qwen3-asr-0.6b-int8`。`SHANSHUO_MODEL_DIR` 只供开发和测试读取已有缓存；模型窗口不会删除、修复或写入该目录。下载、校验、加载或删除期间，应用不接受新的听写，会丢弃正在进行的会话。

以下真实系统检查尚未作为本轮自动化结果记录，需在已授权的 macOS 测试账户中执行：

- 在 TextEdit 或备忘录中确认 Fn 录音时，非激活胶囊和菜单栏同步显示，且目标应用不失焦。
- 在未授权辅助功能的状态下确认 ⌃⇧ Space 只复制；授权后确认直接插入、焦点变化复制、Esc 与安全输入丢弃。
- 在终端确认包含换行的文本只复制，不发送 Return；在全屏应用和多显示器上确认胶囊位置。
- 在目标应用矩阵中检查 AX、粘贴回退和剪贴板恢复；这些兼容性与性能指标由 T015 验收。

## 进度跟踪

本项目使用 SDLC 流程管理。需求和交付进度以 `.sdlc-v1/state.json` 为准，可用 `lifecycle_state.py status` / `next` 查看；GitHub Issues 只同步阶段进展，便于查看和讨论。

## 目录

| 路径 | 内容 |
|---|---|
| `.sdlc-v1/` | SDLC 状态与需求、研发上下文 |
| `research/` | 调研笔记 |
| `prototype/` | 交互原型（spec 阶段产物） |
