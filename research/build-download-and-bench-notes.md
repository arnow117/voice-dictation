# build 阶段调研笔记：模型下载源与评测数据（2026-10-21）

## T003 模型下载源（实测，开发机 M5 / macOS 26.4.1）

本机网络经代理客户端的 fake-IP / TUN 模式：huggingface.co、hf-mirror.com、modelscope.cn 都解析到 198.18.0.0/15 保留地址段；直连与显式走 `127.0.0.1:30975` 两种方式的出口都在新加坡（ipinfo.io 返回 SG），百度 51 ms。因此本机测不出中国大陆直连的真实可用性。

| 源 | 是否有 sherpa-onnx 包 | Range（206） | 30 MB 分段速度（直连 / 代理） | 备注 |
|---|---|---|---|---|
| Hugging Face `resolve/<rev>/<file>` | 有（csukuangfj / csukuangfj2） | 支持，重定向后仍保留 Range | 8.9 / 8.9 MB/s | API 提供 LFS 文件的 SHA-256 |
| hf-mirror.com（社区镜像，路径与 HF 相同） | 有 | 支持 | 7.6 / 7.7 MB/s；整段 651 MB 续传 22.8 MB/s | 第三方，无 SLA |
| GitHub Releases `asr-models` | 有（整包 tar.bz2，Qwen3-ASR 878,702,423 字节） | 支持 | 13.0 / 11.4 MB/s | 整包要解压 bz2，不能逐文件校验 |
| ModelScope | **没有**（csukuangfj、csukuangfj2 下均 `record not found`） | 官方 Qwen/Qwen3-ASR-0.6B safetensors 支持 206 | 6.4 MB/s（官方权重） | 只有 PyTorch 权重 1.88 GB，不是 sherpa-onnx 格式 |

换源续传实测：decoder.int8.onnx 先从 HF 下 100 MB 后模拟中断，再从 hf-mirror 续传剩余 651,056,631 字节，27.2 秒，最终 SHA-256 `4f6885be…5771` 与 HF LFS 记录一致。日志：`.work/t003/real-resume.jsonl`（主 checkout，不入库）。

全量下载实测（2026-10-21 21:32～21:35，源顺序 HF → hf-mirror，全部来自 HF，无源失败、无校验失败）：

| 模型 | 本次下载字节 | 耗时 | 平均速度 |
|---|---|---|---|
| Qwen3-ASR-0.6B int8（decoder 已在续传实验中下完，本次为其余 5 个文件 + 17 个测试音频） | 244,175,118 | 50.1 s | 4.6 MB/s（小文件多，单请求开销占主导） |
| SenseVoice-Small int8 | 237,431,441 | 11.7 s | 19.3 MB/s |
| Fun-ASR-Nano int8 | 1,009,605,061 | 60.4 s | 15.9 MB/s |
| Whisper-turbo int8 | 1,036,613,791 | 47.9 s | 20.6 MB/s |

没有 LFS 哈希的 6 个小文本文件（tokenizer/merges.txt、tokens.txt 等）由 `manifest.py pin` 根据已校验大小的本地副本计算 SHA-256，并标记 `sha256_source: computed-2026-10-21`。日志：`.work/t003/full-download.jsonl`。

固定版本（2026-10-21）：

| 模型 | 仓库 | revision | 应用所需文件合计 |
|---|---|---|---|
| Qwen3-ASR-0.6B int8 | csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25 | 68818b2313fe77bd06f6a7c5068ff3ef59d02b8a | 941.3 MB |
| SenseVoice-Small int8 | csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09 | 355f4d4884d8afd08aef04b9007a8556d7b463b2 | 226.4 MB |
| Fun-ASR-Nano int8 | csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30 | 6f16bd378457e13f36ccf3910df9017f96c346fb | 962.8 MB |
| Whisper large-v3-turbo int8 | csukuangfj/sherpa-onnx-whisper-turbo | 2ca6ff69fc878651b770880507669577ac41c2ff | 988.6 MB |

各仓库模型卡均未声明 license；上游许可证：Qwen3-ASR Apache-2.0，Fun-ASR-Nano Apache-2.0，Whisper MIT，SenseVoice 为 FunASR 模型许可（发布前需复核）。

## T001 sherpa-onnx 1.13.8 Python 接口（官方 python-api-examples@v1.13.8）

PyPI 最新为 1.13.8，有 cp310～cp313 的 macosx_11_0_arm64 wheel。

| 模型 | 构造函数 | 关键参数 |
|---|---|---|
| Qwen3-ASR | `OfflineRecognizer.from_qwen3_asr(conv_frontend, encoder, decoder, tokenizer, hotwords="", num_threads=2, provider, max_total_len=512, max_new_tokens=128, temperature=1e-6, top_p=0.8, seed=42)` | `hotwords` 逗号分隔；长音频用 `stream.set_option("max_new_tokens", "256")`；`stream.set_option("language", "Chinese")` |
| Fun-ASR-Nano | `OfflineRecognizer.from_funasr_nano(encoder_adaptor, llm, embedding, tokenizer, num_threads, provider, system_prompt, user_prompt="语音转写:", max_new_tokens=512, language="", itn=True, hotwords="")` | `hotwords` 逗号分隔 |
| Whisper | `OfflineRecognizer.from_whisper(encoder, decoder, tokens, ...)` | 无热词 |
| SenseVoice | `OfflineRecognizer.from_sense_voice(model, tokens, use_itn=True)` | 无热词 |

解码：`s = rec.create_stream(); s.accept_waveform(sr, float32_mono); rec.decode_stream(s); s.result.text`。

## T001 评测数据候选

| 数据集 | 许可证 | 内容 | 获取方式 | 用途 |
|---|---|---|---|---|
| google/fleurs | CC-BY-4.0 | 真人朗读维基句子 | `data/<lang>/audio/test.tar.gz` + `test.tsv`；datasets-server 因文件过大不可用 | 中文（cmn_hans_cn）、英文（en_us） |
| CAiRE/ASCEND | CC-BY-SA-4.0 | 香港双语者自然对话的中英混说，10.62 小时 | `main/test-00000-of-00001.parquet`（105,756,434 字节） | 中英混说 |
| MrSupW/ContextASR-Bench | MIT | DeepSeek-R1 生成含大量实体的文本，再用零样本 TTS 合成；每条带 entity_list | `ContextASR-Speech_Mandarin.jsonl` + 音频 tar | 专有词与热词效果（注意：合成语音） |
| SeACo-Paraformer Test-Aishell1-NE | AISHELL-1 Apache-2.0 | 真人朗读，808 句，400 个热词 | 需下载完整 AISHELL-1（约 15 GB）后按 `data/test/uttid` 筛选 | 备选：真人语音的专有词测试 |

来源：https://huggingface.co/datasets/MrSupW/ContextASR-Bench 、https://arxiv.org/abs/2507.05727 、https://github.com/R1ckShi/SeACo-Paraformer 、https://github.com/HLTCHKUST/ASCEND 、Hugging Face datasets API（cardData.license）。

## T001 补充事实（21:40～21:48）

**热词作用范围（sherpa-onnx v1.13.8 源码）**：`sherpa-onnx/csrc/offline-recognizer-qwen3-asr-impl.cc` 第 817～821 行注释为 "Optional per-stream hotwords via SetOption("hotwords", comma-separated…)"，代码是 `stream->HasOption("hotwords") ? stream->GetOption("hotwords") : qwen3_config.hotwords`。也就是说，Qwen3-ASR 可以在每次识别时单独传热词，个人词典更新后不用重新加载模型。热词放在 chat 模板的 system 段（`<|im_start|>system\n` + 热词 + `<|im_end|>…<|audio_start|>`），逗号分隔后用空格拼接；`max_total_len` 同时限制提示词和音频 KV，超出时日志建议减少热词或缩短音频。`offline-recognizer-funasr-nano-impl.cc` 第 904～905 行只读 `funasr_config.hotwords`，即 Fun-ASR-Nano 的热词只在加载模型时设定，换词典要重建识别器。来源：https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/csrc/

**sherpa-onnx 1.13.8 安装**：PyPI 上的 `sherpa-onnx==1.13.8` wheel 依赖 `sherpa-onnx-core==1.13.8`（其中含 libonnxruntime.dylib），但 uv 0.11.4 没有自动安装它，需要在依赖中显式写出。

**ContextASR-Bench 时长**：`ContextASR-Speech_Mandarin.jsonl` 共 15,498 条，时长 23.9～97.4 秒（中位数 44.8 秒），没有一条在 3～20 秒内；`entity_list` 是字符串形式的 Python 列表。最终改用 `ContextASR-Dialogue_Mandarin`，按每轮对话的 start/end 切分，取 3～20 秒且包含实体的轮次，每段对话最多 3 轮。实际得到 20 条、来自 7 段对话、平均 10.9 秒。干扰词取自 ContextASR-Speech 中文的实体（400 个，2～8 字，无空格）。

**测试集实际构成**（bench/asr/testset.jsonl）：zh 40 条（5.0～18.4 秒，平均 10.7 秒）、en 30 条（4.3～15.6 秒，平均 9.5 秒）、mixed 30 条（3.0～11.3 秒，平均 5.6 秒；ASCEND 为自然对话，含重复和口头语，例如"我的我的parents"）、entity 20 条（7.2～15.5 秒）。

**冒烟测试**（M5，4 线程，CPU，前 3 条中文，已预热）：

| 模型 | 加载 | 加载后 RSS | 峰值 RSS | 10.4 / 8.3 / 13.9 秒语音的识别耗时 | 观察 |
|---|---|---|---|---|---|
| Qwen3-ASR-0.6B | 1.43 s | 1270 MB | 2337 MB（max_total_len=2048） | 0.74 / 0.78 / 1.54 s | 带标点，数字输出为"二零一一年" |
| SenseVoice-Small | 0.62 s | 885 MB | 919 MB | 0.20 / 0.18 / 0.30 s | 无标点，"钙甲""银河"错字 |
| Fun-ASR-Nano | 2.75 s | 1848 MB | 2526 MB | 1.08 / 1.12 / 2.21 s | 带标点，准确 |
| Whisper-turbo int8 | 1.65 s | 2371 MB | 2988 MB | 4.14 / 4.03 / 7.21 s | 丢字，输出繁体 |

## 代理环境只能使用能效核（2026-10-21 21:52～21:56）

现象：后台运行的全量评测中，Qwen3-ASR 识别 15 秒以内真实句子的 P50 为 2.00 s、P95 为 4.79 s，实时率中位数 0.2～0.3；21:45 前台冒烟测试只有约 0.1。

排查（psutil 每核负载，cpu0～5 为 6 个能效核，cpu6～9 为 4 个性能核）：
- 评测进程 CPU 占用约 326%，cpu0～5 各约 90%，cpu6～9 各约 5～10%。
- 低电量模式 lowpowermode 0，接交流电，`pmset -g therm` 没有温度或性能警告。
- worker 内调用 `setpriority(PRIO_DARWIN_PROCESS, 0, 0)` 清除后台状态（清除前即为 0），并用 `pthread_set_qos_class_self_np` 设为 USER_INTERACTIVE（读回 0x21），仍然只在能效核上运行，实时率 0.276。
- 独立探测脚本（`bench/asr/core_probe.py`）：4 个纯计算进程把 cpu0～5 打满到 100%，cpu6～9 约 5%；用 `taskpolicy -t 0 -l 0` 启动结果相同。

结论：Manus 代理启动的整棵进程树被限制在能效核上，进程自己无法解除。准确率和热词召回与核心无关，继续在代理环境中测；所有计时改由用户在自己的终端中运行 `bench/asr/run_terminal.sh`。worker 在结果中记录运行期间各核心的平均负载，作为证据。

对产品的影响：闪说如果在低 QoS 线程上识别，同样只会用到能效核，NFR-002 直接不达标。新增 FEAT-001 ED-014，识别队列使用 userInitiated。

## T001 中间结果（2026-10-21 22:16，代理环境，宽松口径）

| 模型 | 中文 CER | 英文 WER | 混说 MER | 专有词句 CER | 专有词召回（无热词） | 加载 s | 加载后 RSS MB | 峰值 RSS MB |
|---|---|---|---|---|---|---|---|---|
| Qwen3-ASR-0.6B | 3.2% | 5.3% | 11.7% | 3.8% | 25/37（67.6%） | 1.12 | 1883 | 2793 |
| SenseVoice-Small | 5.5% | 31.5% | 14.9% | 7.8% | 16/37（43.2%） | 0.71 | 872 | 932 |
| Fun-ASR-Nano | 3.7% | 7.1% | 9.8% | 5.0% | 21/37（56.8%） | 3.12 | 1638 | 2636 |

原始口径：Qwen3 4.8/5.4/13.2/3.8；SenseVoice 8.7/33.8/15.2/7.7；Fun-ASR-Nano 5.5/7.1/11.1/4.9。混说只有 30 条，差距需要看置信区间。

Qwen3 热词（专有词 20 条）：none 召回 67.6%、CER 3.8%；clip（本句实体 1～4 个）召回 86.5%、CER 7.0%；dialogue（7～10 个）召回 89.2%、CER 2.3%；global-50 召回 75.7%、CER 3.7%。

**问题**：entity-003 在 clip 模式下只给 1 个热词"徐贤"时，Qwen3 整句输出变成"system"（CER 从 2 个错字变为 36 个）。这是提示模板泄漏导致的灾难性失败。产品需要做输出校验：结果为空、只有角色标记（system/user/assistant）或长度与音频时长严重不符时，去掉热词再识别一次，并记录诊断事件。dialogue 模式（更多热词）没有出现这个问题。

代理环境计时不可靠：22:09～22:11 编译 Swift 时与评测共用能效核，dialogue 模式出现 11 s 的异常值。
