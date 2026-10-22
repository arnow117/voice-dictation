# 设置页焦点诊断：构建 20261022-184152

本构建只增加被动焦点观察，没有修正导航行为，也没有完成 T015 或 NFR-007。

## 构建与边界

- 生产窗口显示、成为/失去 key、普通 Tab/Shift-Tab 到达前和后续主线程轮次，
  记录六条固定枚举事实；每组独立随机 probe UUID，不属于听写 attempt。
- 事实包含 app active、window key、当前/初始 responder 的已知控件分类，
  以及快捷键 popup 的可获焦性。不保存文字、标题、控件值、地址或类名。
- local monitor 原样返回同一事件；关闭时解除，异步记录检查代次和可见性。
  不设置 first responder，不读取 nextValidKeyView，不重算 key-view loop。
- 普通 Tab 分类忽略 Caps Lock 状态，仍排除 Control/Option/Command/Function 组合。
- 复用 owner-only、有容量和文件数上限的诊断存储；新事件不计入性能样本分母。

完整 `SKIP_ASR=1 bash scripts/test.sh` 在首个探针构建 `183733` exit 0，
包含 13 个 Swift 核心测试和全部非 ASR harness。Caps Lock 纯分类修正后，
原生窗口 harness、formatter、diff 检查与签名 build `184152` 均 exit 0；
未改变 ASR 源码/运行时，不重复 120 条原音频。
Python reader 的 12 项测试覆盖新 Swift 编码、严格拒绝未知枚举与分母隔离。
主 Agent 使用新 reader 读取真实生产目录：227 条记录、0 条无效行。

冻结可执行文件 SHA-256：
`b360dd19ddeb50cda7fe814b0d116ea3d4ae65a0c3f73e95048d50c6fbad41cc`。
冻结副本在受控签名环境中 `codesign --verify --deep --strict` exit 0；
沙箱内的 `CSSMERR_TP_NOT_TRUSTED` 没有通过更改信任设置处理。

## 当前实机状态

旧 `165625` 已由应用自己的退出菜单关闭，新冻结构建通过 CUA 启动。
本进程 ID 为 34192，随机诊断 process UUID 为
`80BA0307-FDEF-4FF2-893D-5C6A7FAF74D2`；已记录内部 cold ready。
引导此前完成，启动后无普通窗口，CUA 连接因此超时；不据此判定应用挂起。
已请求用户打开菜单栏“设置…”并实际按一次 Tab 与 Shift-Tab，结果尚待记录。

## 同次启动的只读采样

在启动前声明本次为诊断运行：精确匹配该冻结路径后，只针对这个新进程做
2 秒 `sample`，exit 0；没有停止应用或访问音频内容。原始调用栈仅保存在忽略目录。
采样捕获启动前段的主线程菜单设置、系统 WritingTools 动态装载和音频 inputNode 初始化。
样本计数不能直接当作完整启动各阶段的耗时，也不能证明 5.50 秒的原失败由某一项造成。

本次 start→ready 为 5.911846209 秒；因主动采样有扰动，不能作为无采样性能达标证据。
原 `165625` 的无采样 5.500070708 秒失败继续有效，最终配置冷启动仍未通过。
固定 `bf93652` 的另一次只读源码分析确认启动会提交两次音频准备，音频 ready 也可能
延至下一次 0.5 秒 Timer 才被主线程观察；尚无阶段时间可以分配它们的实际贡献。
