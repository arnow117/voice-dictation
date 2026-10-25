# MiniMax 智能整理 v2 评测记录

**日期：** 2026-10-23

**模型：** `MiniMax-M3.1-Flash`，`output_config.effort=low`

**结论：** PARTIAL，未达到 REQ-002 的质量、忠实性和延迟阈值。

## 版本化基线与冻结

v1 的规则、公开语料、rubric、scorer 与冻结清单完整保留在
[`bench/formatting/v1/`](../../bench/formatting/v1/)。它的历史结果没有修改：56 条有效、35 条
正确（62.5%）、4 条超时、最终和 raw 忠实性错误各 1，P50/P95 为 1901/5000 ms。

在 v1 逐条人工检查定位“有序列表前文被删除或变为额外列表项”后，只做了一次有界修正：提示
要求把时间、人物和上下文保留为列表前的普通文本行；保真规则拒绝丢失显式口述序号列表的前文；
`1,200` 与 `1200` 可等价，`12,000` 与 `1200` 不可等价。修正后的 prompt、guard、v2 语料、
rubric 与 scorer 在任何 v2 请求前冻结：

| Artifact | SHA-256 |
|---|---|
| `FormattingRules.swift` | `cd312522ab1de7817f1e9f91ccecdba61309e0bfff21141a6523e7a4418e6a50` |
| `bench/formatting/heldout.jsonl` | `e250bdc8495464254a21f4229ffae3418b477daff6b89155d26a91726da8c132` |
| `bench/formatting/rubric.json` | `2e9fa1f01e28a313955c174f8845fb2b5d8e1776185e66162cd533d6b8d4b90e` |
| `bench/formatting/scorer.py` | `7d06fef2482b04903cf11e6f9e99cae651871c4382ce5115899cc133a047d2c1` |
| runtime system prompt | `9766e88edbe9fe0509a3eaaa31fbc9eb0ba0eaab8b55b2235764090a7ae3a181` |

`freeze.json` 的状态为 `frozen_before_first_v2_provider_request`，冻结时间为
`2026-10-23T08:02:15Z`。v2 使用 15 条列表、15 条口头禅/改口、10 条排版/数字、10 条
忠实性/注入和 10 条保持不变的全新公开合成输入。v2 rubric 只对预先写入 fixture 的完整数字
表达变体放宽，例如“二十三”与“23”；计算答案、事实变化和缺少上下文仍失败。

## 运行范围

评测使用同一 production `MiniMaxAPIFormatter`，由显式 CLI 在单个进程中只读当前用户的 CC
Switch MiniMax 配置一次并存入进程内缓存。它不接受 Key 或任意文本参数，不访问系统钥匙串，
退出时清除该内存凭据。

本次有界修正共进行了 62 次公开 production formatter 调用尝试：两条固定开发样例和一条单并发
的 60 条正式批次。回执没有逐次记录底层 HTTP 是否已经实际发送，因此不能把 62 次调用尝试表述为
62 次已计量的 HTTP 发送。开发改口样例用时 2051 ms，输出“周四下午开会。”，遗漏输入中的“我们”；
开发列表样例用时 3255 ms，保留了“明天下午准备 3 项”前文并输出 `1.`、`2.`、`3.`。这些只是开发
检查，不计入正式分数。没有重试、没有 M3 对比，也没有后续调 prompt、guard、scorer 或同一冻结集。

正式命令为：

```bash
SHANSHUO_FORMATTING_EVAL_APP="$PWD/.work/minimax/t003-v2-dev-build/Shanshuo.app/Contents/MacOS/Shanshuo" \
SHANSHUO_FORMATTING_EVAL_RESULTS="$PWD/.work/minimax/t003-v2-formal-eval.jsonl" \
SHANSHUO_FORMATTING_EVAL_SUMMARY="$PWD/.work/minimax/t003-v2-formal-eval.summary.json" \
bash bench/formatting/run_eval.sh
```

它在开发构建的 production formatter 上运行，构建版本为 `0.1.0/1.0.3`、时间
`2026-10-23T08:02:35Z`。正式 JSONL 有 60 条唯一 case ID，fixture 与 runtime prompt 哈希均与
冻结清单一致，`metadata_errors` 为空。公开 JSONL 的 SHA-256 为
`722f4916bdd7d826ed92b2c6944efb062d6c0cfbd6d13bac296f790d217b1277`；原始可见文本与 guard
后的最终文本分别保存在该 JSONL 的 `raw_provider_text` 与 `final_text` 字段中。

## 正式结果

| 指标 | 结果 | 目标 |
|---|---:|---:|
| 有效 / 总样例 | 51 / 60 | 60 / 60 |
| 正确 / 有效样例 | 42 / 51（82.35%） | ≥95% |
| 最终忠实性/注入错误 | 1 | 0 |
| raw provider 忠实性/注入错误 | 1 | 单列报告 |
| 超时回退 | 9 | 0 个 invalid 才可完整验收 |
| 全部用户可感知 P50 / P95 | 2175 / 5001 ms | ≤1000 / ≤2500 ms |
| ≤200 字样例 P50 / P95 | 2175 / 5001 ms | 单列，与本批次全部样例相同 |

| 分类 | 有效 | 正确 | 正确率 |
|---|---:|---:|---:|
| 列表 | 14 | 10 | 71.43% |
| 口头禅 / 改口 | 12 | 10 | 83.33% |
| 排版 / 数字 | 8 | 6 | 75.00% |
| 忠实性 / 注入 | 9 | 8 | 88.89% |
| 保持不变 | 8 | 8 | 100.00% |

9 条 `deadlineExceeded` 均作为 invalid，而不是从分母删除后宣布完成。需要转换却超时或生成
不合格列表的样例仍记录为任务失败。代表性问题包括：一个有序口述列表输出为无序项目；两个无序
清单仍保持为一句话；部分数字继续保留中文表达；一条忠实性样例变为“请替我预定今晚的餐厅”。
该自动错误保留。人工核对认为这里只增加了结构助词“的”，没有观察到实际预定、回答或事实变化；
它不能描述为执行了指令。

## 后续边界

本次证据表明 v2 未满足正式阈值，不能把 beta.2 表述为智能整理质量或延迟已验收。根据本轮
有界计划，不会用已见 v2 语料继续调参或重跑；是否建立新的冻结集、调整产品目标或改用其他方案
需要新的产品决定。用户已接受当前结果，先交付默认关闭的实验功能，正式质量和速度目标继续
留在 Issue #2；这不改变上述 PARTIAL 分数。稳定测试签名 beta.2 应用 `0.1.0/1.0.3`、构建时间
`2026-10-23T08:09:19Z` 已在本机安装，原生 CC Switch 导入、公开连接测试和开启成功，全程
没有密码提示。用户在备忘录用当前 Fn 热键输入公开测试句，确认出现保留前文的编号列表。该证据
只覆盖一次基本语音流程，完整端到端延迟分布仍未测量。

后续 `1.0.4` 候选只修正已开启状态重新测试连接时的状态提示：成功、网络失败和超时均如实说明现有开启状态，初始关闭时失败仍说明关闭。它由 synthetic 原生窗口回归验证，没有运行新的真人应用旅程、provider 评测或端到端性能测量，因此不改变本报告的 `1.0.3` 人工路径证据或上述 PARTIAL 结论。
