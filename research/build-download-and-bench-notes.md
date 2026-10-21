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
