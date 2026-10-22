# T002 macOS 平台能力验证结论（2026-10-21）

环境：Apple M5，macOS 26.4.1（25E253），单显示器。探测应用 `ShanshuoProbe`（`spikes/platform/ShanshuoProbe/`），用 ED-012 的"Shanshuo Test Signing"身份签名并开启 Hardened Runtime；用户手动操作约 12 分钟后，按用户 22:30 的"加速做集成交付"指示提前结束。原始日志：`probe-log-2026-10-21.jsonl`（只含事件、应用名、长度与结果）。

| # | 结论项 | 结果 | 证据 | 对设计的影响 |
|---|---|---|---|---|
| 1 | 只授予辅助功能时 CGEventTap 能否收到 Fn / 右 Option / Esc | **通过**（Fn、右 Option）；Esc 拦截未测 | Fn 7 次、右 Option 3 次完整按下/松开；未申请输入监控 | DEC-017 成立，ED-003 定稿；Esc 拦截在 T006 中测 |
| 2 | 无权限时 Carbon ⌃⇧Space 按下与松开 | **通过** | 11 次完整按下/松开，注册状态 0；仅复制模式下临时 Esc 热键（含 ⌃⇧ 修饰）注册成功；输入法冲突未收到异常报告 | DEC-020 成立，ED-003 定稿 |
| 3 | 重新构建后权限是否保持 | **麦克风通过**；辅助功能未测 | 新构建 20261021-222346 启动时麦克风为 authorized，未重新授权；证书根哈希固定 | ED-012 定稿；辅助功能保持在 T004 首次重建时确认 |
| 4 | 安全输入下的事件 | 未测 | — | ED-006 保持默认；T006 测 |
| 5 | 胶囊显示 | **单显示器通过**；全屏与多显示器未测 | 20 次显示，按键到显示 P50 1 ms、最大 34 ms；有辅助功能时按活跃窗口定位 | NFR-001 的提示部分余量充足；全屏在 T007 测 |
| 6 | 13 个应用的插入 | **备忘录通过**；其余 12 个改在 T015 用正式版测 | 备忘录 AX 直接写入 6/6，读回校验全部包含测试文字，人工确认可见 | ED-005 的 AX 优先成立；矩阵移到 T015 |
| 7 | 读取剪贴板是否弹提示；Transient 标记 | **不弹提示**；Transient 效果未测 | 首次启动时 `NSPasteboard.accessBehavior` 即为 `alwaysAllow`，读取 1 ms，无提示 | 保留"恢复原剪贴板"（REQ-001 FR-003），ED-005 定稿 |
| 8 | AX 能否读取输入框文字 | **备忘录可读** | 值可读，支持 AXStringForRange，光标前后 200 字可读 | 供 REQ-003 静默学习 |
| 9 | 深链接与授权后免重启 | **免重启通过**；深链接未用（用户手动进入设置） | 打开开关后同一毫秒内 tap 安装成功并启用 | DEC-016 免重启成立；深链接在 T011 测 |
| 附 | 麦克风采集启动 | **发现问题** | AVAudioEngine 冷启动 1655 ms，之后 P50 56 ms；按键到第一块音频 P50 163 ms、最大 185 ms；48 kHz | 新增 ED-016：启动后预热音频设备，冷启动时开头会丢约 1.6 秒 |

## 日志汇总（自动生成）

## 1. 构建与权限

| build | 启动次数 | 启动时辅助功能 | 启动时麦克风 | 剪贴板访问策略 |
|---|---|---|---|---|
| 20261021-221141 | 1 | False | not_determined | always_allow |
| 20261021-222346 | 1 | False | authorized | always_allow |

- 2026-10-21T14:27:07.202Z 辅助功能变为 True（build 20261021-222346）
- 2026-10-21T14:27:07.215Z 授权后不重启安装 tap：ok=True enabled=True
- 2026-10-21T14:27:07.215Z tap_install ok=True
- 2026-10-21T14:20:26.762Z 打开深链接 mic_old ok=True
- 2026-10-21T14:20:29.201Z 打开深链接 mic_old ok=True
- 2026-10-21T14:19:17.973Z 麦克风请求结果 granted=True
- 2026-10-21T14:20:25.164Z 麦克风请求结果 granted=True
- 2026-10-21T14:20:28.297Z 麦克风请求结果 granted=True

## 2. 按键事件

| 按键 | 按下 | 松开 | 其中安全输入开启时 |
|---|---|---|---|
| fn | 7 | 7 | 0 |
| right_option | 7 | 7 | 0 |
| esc | 0 | 0 | 0 |
| ctrl_shift_space_seen_by_tap | 0 | 0 | 0 |

Esc 被拦截 0 次；取消事件：Counter()

Carbon ⌃⇧Space：未授权时 按下 11 / 松开 11；授权后 按下 0 / 松开 0；Carbon Esc 0 次；注册结果 [(0, 0)]

密码框/安全输入时拒绝开始：0 次；插入时识别为密码框：0 次

## 3. 录音胶囊

显示 20 次；从按键到显示 P50 1 ms，最大 34 ms；定位方式 Counter({'focused_window': 15, 'mouse': 5})；屏幕编号 Counter({0: 20})（共 1 块）

| 前台应用 | 次数 | visible | on_active_space |
|---|---|---|---|
| com.arnow117.shanshuo.probe | 9 | Counter({True: 9}) | Counter({True: 9}) |
| 备忘录 | 11 | Counter({True: 11}) | Counter({True: 11}) |

## 3.1 麦克风采集

启动 12 次；engine.start 耗时 P50 56 ms、最大 1655 ms；从按键到开始采集 P50 60 ms；从按键到第一块音频 P50 163.0 ms、最大 185 ms；采样率 Counter({48000: 12})

按住时长减去采到的音频时长（即开头和结尾丢掉的部分）：P50 0.13 s、最大 1.67 s；峰值音量 P50 0.39

采集失败 0 次；因未授权跳过 0 次

## 4. 插入（按应用 × 方式）

| 应用 | 方式 | 次数 | AX 读回包含 | 人工判定 | 角色 | 可写选中文字 | 值可读 | 可按范围读 | 光标附近可读字数 | 备注 |
|---|---|---|---|---|---|---|---|---|---|---|
| com.arnow117.shanshuo.probe | copied_to_clipboard | 6 | {'—': 6} | {'未判定': 6} | —/ | — | — | — | —→— |  |
| com.arnow117.shanshuo.probe | paste | 2 | {'no': 2} | {'not_visible': 2} | AXTextArea/ | False | True | True | 200→200 | 读剪贴板 1 项 0 ms |
| 备忘录 | ax | 6 | {'yes': 6} | {'未判定': 5, 'visible_ok': 1} | AXTextArea/ | True | True | True | 400→400 | AX 写入 rc=0 |
| 备忘录 | copied_to_clipboard | 5 | {'—': 5} | {'not_visible': 2, '未判定': 3} | —/ | — | — | — | —→— |  |

## 5. 剪贴板


恢复方式：Counter({'fallback_1s': 2})；1 秒兜底：2 次
- 2026-10-21T14:18:42.815Z 读取测试：1 项，1 ms，策略 always_allow，前台 com.arnow117.shanshuo.probe
- 2026-10-21T14:18:45.203Z 写入测试：markers=True
- 2026-10-21T14:18:46.197Z 写入测试：markers=False

日志共 243 行，2026-10-21T14:17:36.965Z ～ 2026-10-21T14:32:03.024Z；T002 完成标记：0
