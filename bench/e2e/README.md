# 真机性能测量

这些命令只读取应用的本地性能日志，或通过 afplay 播放已有 WAV 夹具。它们不会驱动
窗口、模拟键盘输入、修改默认输入/输出设备、录音或向应用注入测试音频。开始前由测试者
真实启动应用、完成权限和模型加载，并用真实按键操作界面。

应用将类型化事件写入：

    ~/Library/Application Support/Shanshuo/PerformanceDiagnostics/

每个进程一个 JSONL 文件，目录为 0700、文件为 0600；最多保留 8 个文件，每个最多
512 KiB。记录只包括随机 process/session ID、固定事件/结果、单调时间和必要音频时长。

## 空闲 CPU

获取正在运行应用的 PID 后，保持指定界面状态 120 秒。工具只在开始和结束读取同一 PID
的 user/system 累计 CPU，并核验 lstart 未变；结果以一个逻辑 CPU 核为 100%。

    python3 bench/e2e/measure.py cpu \
      --pid APP_PID \
      --seconds 120 \
      --output .work/validation/idle-cpu.json

分别对引导可见和所有窗口关闭状态运行。输出不是 NFR-004 的预填结论，必须由真机数据判断。

## 冷启动和真实端到端

每次冷启动从 proc_pid_rusage 的 process start 到生产 ready 事件计时。ready 只在已授权
麦克风、已验证并加载模型、快捷键可用、音频准备已提交且未暂停时发出。进行 3 至 5 次
真实启动；报告默认要求至少 3 个成功样本。

听写延迟只将松开快捷键到 AX 实际读回验证作为成功终点。每个不完整、取消、失败、复制、
粘贴请求或 Unicode 请求样本都会保留在分母中，不能计为通过。报告会给出：

- 40 个热键回调到 AppKit display/isVisible 提交的样本。它不等于屏幕首帧，所以
  NFR-001 的屏幕首帧仍会标为 UNVERIFIED。
- 至少各 20 个小于等于 15 秒和约 30 秒录音的 P50/P95，以及失败和不完整样本数。
- 进程启动到 ready、热键显示提交和 AX 验证延迟的覆盖率。

冷启动的 P50/P95 仅用于描述分布；每一次成功的启动都必须不超过 5 秒。没有松开事件或
没有可用音频时长的尝试会分别列为 missing release 或 unknown duration，并阻止受影响的
延迟指标通过。JSONL 目录含多个运行时，可以按 process/session UUID 明确选择测量集：

    python3 bench/e2e/report_metrics.py \
      --diagnostics-dir "$HOME/Library/Application Support/Shanshuo/PerformanceDiagnostics" \
      --process-id PROCESS_UUID \
      --session-id SESSION_UUID \
      --output .work/validation/performance-summary.json

通常只指定其中一个选择器；同时指定时两者必须匹配同一事件。选择器不会修复损坏的 JSONL
输入，报告仍会把无效行列出并拒绝将受影响指标记为 PASS。

## 扬声器到真实麦克风夹具

主 checkout 的 .work/bench-data/latency/lat-05s-00.wav 至 lat-30s-09.wav 以及
latency.jsonl 是可复用的合成时长夹具。它们可由已有本地 clips 重新构造：

    uv run --project bench/asr python bench/asr/run_bench.py make-latency \
      --data .work/bench-data

夹具生成代码使用已有 120 条本地评测集：FLEURS 中文/英文为 CC-BY-4.0，ASCEND
混说为 CC-BY-SA-4.0；原始音频不会提交到仓库，也不会由本工具下载。该扬声器到真实
麦克风测量不同于 bench/asr 的离线准确率评测。

先在另一个终端启动下列监听器，再由测试者真实按住快捷键。工具只在看到新的生产
audio_first_buffer 事件后调用 afplay 播放给当前扬声器路由：

    python3 bench/e2e/measure.py play-fixture-after-first-buffer \
      --diagnostics-dir "$HOME/Library/Application Support/Shanshuo/PerformanceDiagnostics" \
      --audio .work/bench-data/latency/lat-15s-00.wav \
      --output .work/validation/fixture-playback.json

之后使用 report_metrics.py 汇总。这些命令不预填成功率、计时值或 PASS。
