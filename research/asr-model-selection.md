# 本地中英文 ASR 模型选型笔记

> 日期：2026-10-21。用途：为 REQ-001 / REQ-003 的模型决定（DEC-004）提供依据。本文只记录事实、来源和推荐，不构成已确认决定；最终选型由 plan 阶段 eval-bench 实测确认。

## 一、项目与知识库内已有调研

| 来源 | 时间 | 与本需求相关的结论 |
|---|---|---|
| `workspace/20260928-blurt-analysis/repo/skills/blurt/reference/asr.md` | 2026-09-28 | 本地默认后端为 SenseVoice（sherpa-onnx，CPU，约 240 MB，zh/en/ja/ko/yue 及中英混说），约 2–4 秒处理 1 分钟音频；Apple GPU 可选 mlx-whisper（large-v3-turbo，1.6 GB）；云端可选 Qwen3-ASR-Flash。流水线为 ffmpeg → 16 kHz mono → Silero VAD → 后端。中国大陆提供 hf-mirror 下载。 |
| `workspace/20261010-yovoice-development/.sdlc-v1/context/FEAT-001.engineering.md` | 2026-10-10 | 已在本机实际使用 sherpa-onnx/core 1.13.8（Python CPU 子进程）做声纹特征；形成了"固定版本 + 模型 SHA256 校验 + 子进程 JSON 协议 + 有界超时"的接入经验。说明 sherpa-onnx 在本团队已有落地先例。 |
| `workspace/20260922-agent-native-research/templates/clips/desktop/design-refs/wispr-ux.md` | 2026-05-03 | Wispr Flow 体验参考：按住说话、底部居中录音胶囊、权限卡片式 Onboarding、练习沙盒、个人词典自动学习、"一二三"自动编号列表、云端整理。 |
| `workspace/20260922-agent-native-research/templates/clips/desktop/` | — | Tauri 2 托盘应用模板，README 声明 macOS 上有 Fn 听写快捷键、自动粘贴文本和本地 Whisper 转写。可作为 plan 阶段的代码复用候选。 |
| `~/Documents/nsync/ai_knowledge/tools/yovoice.md` | 2026-10-10 | 将 sherpa-onnx 列为本地部署候选（声纹方向）。知识库中没有专门的 ASR 选型卡片。 |

内部调研的空白：上述材料的默认推荐是 SenseVoice，但 SenseVoice 没有热词能力，不能直接满足"专有词与个人词典"（用户需求第 4 点）；也没有覆盖 2026 年开源的 Qwen3-ASR。以下外部资料用于补齐。

## 二、外部事实（截至 2026-10-21）

**Qwen3-ASR（阿里通义，2026-01-29 开源，Apache-2.0）。** 提供 0.6B 和 1.7B 两个尺寸，单模型支持 30 种语言和 22 种中文方言，离线与流式统一推理 [1]。官方公开基准中，0.6B 在 Fleurs-zh 为 2.88、AISHELL-2 为 3.15、Fleurs-en 为 4.39；同表 Whisper-large-v3 分别为 4.09、5.06、4.08 [1]。模型卡说明可以通过 prompt 传入自由文本上下文（领域词汇、人名等）来偏置识别结果 [2]。

**sherpa-onnx 已原生支持 Qwen3-ASR-0.6B。** 官方文档列出 macOS（x64/arm64）、Windows、Linux、iOS、Android 平台，并提供 `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` 预训练包 [3]。该包约 1 GB（conv_frontend 44.1 MB、encoder 182 MB、decoder 756 MB）[4]。实现源码把热词放进 chat template 的 system 段，并提示热词越多、音频越长，prompt 与音频的总长度越容易触达上限 [5]。

**SenseVoice-Small。** 非自回归，CPU 上即可实时，q8 量化约 250 MB [6]。一次 Mac 实测（M5 MacBook Air，FLEURS 朗读短句）中，SenseVoice 中位速度为 162.3 倍实时，Qwen3-ASR-1.7B（MLX 8-bit）为 9.6 倍，Whisper Large V3 Turbo 为 2.6 倍；中文 CER 分别为 7.69%、6.49%、7.97% [7]。sherpa-onnx 的通用热词机制只支持 transducer 模型，SenseVoice 不在其中 [8]。

**Fun-ASR-Nano-2512（通义，0.8B）。** 由 SenseVoice 编码器加 Qwen3-0.6B 解码器构成，支持中、英、日及多种中文方言口音，FunASR 推理接口提供 `hotwords` 参数，另有 llama.cpp/GGUF 本地运行时，权重卡标注 Apache-2.0 [9]。FunASR 官方选型文建议有 GPU 时用 Nano，纯 CPU 用 SenseVoice，中文热词场景可用 Paraformer [6]。

**OpenRouter 隐私控制（与 REQ-002 相关）。** 支持按请求强制 Zero Data Retention（`zdr` 参数），并可用 `data_collection: "deny"` 排除会存储或训练输入的提供商 [10] [11]。

## 三、候选对比

| 候选 | 中英/混说 | 专有词偏置 | 体积 | 速度（相对） | 主要风险 |
|---|---|---|---|---|---|
| **Qwen3-ASR-0.6B（sherpa-onnx int8）** | 支持，中文基准优于 Whisper | prompt 上下文热词（原生） | 约 1 GB | 中等（自回归解码，需实测） | 本机 CPU/GPU 延迟未实测；热词数量受 prompt 长度限制 |
| SenseVoice-Small（sherpa-onnx int8） | 支持 zh/en/ja/ko/yue | 无，只能靠识别后替换和 LLM 校对 | 约 230–250 MB | 最快 | 专有词无法在识别阶段偏置 |
| Fun-ASR-Nano-2512 | 支持 zh/en/ja | `hotwords` 参数 | 约 0.8B 参数 | 中等偏慢，官方建议 GPU | Mac 本地运行时成熟度需验证 |
| Qwen3-ASR-1.7B | 支持，精度最高 | prompt 上下文热词 | 约 2.5 GB | 慢于 0.6B | 内存约 2.4 GiB，建议 16 GB 机器 |
| Whisper large-v3-turbo | 中文弱于以上模型 | initial prompt | 约 1.6 GB | 最慢 | 中文和混说表现不占优 |

## 四、推荐

默认模型推荐 **Qwen3-ASR-0.6B（sherpa-onnx int8）**。它同时满足中英混说和识别阶段的专有词偏置，开源许可清晰，sherpa-onnx 提供跨平台 C/C++ 接口，团队在 yovoice 中已有 sherpa-onnx 的接入经验。

轻量备选推荐 **SenseVoice-Small**，用于低内存机器或用户更看重速度的情况；它的专有词能力由 REQ-003 的识别后替换和 REQ-002 的 LLM 校对补足。

Fun-ASR-Nano 和 Qwen3-ASR-1.7B 进入 plan 阶段的对比评测，不作为首发默认。

需要在 plan 阶段用 eval-bench 实测后才能定稿的事项：

1. 在基线机型上，5 秒、15 秒、30 秒语音从松开按键到出文本的 P50/P95 延迟，以及 0.6B 走 CPU 与走 Apple GPU（如 MLX 移植）的差异。
2. 自建听写测试集上的准确率：中文 CER、英文 WER、中英混说 MER，以及加入个人词典前后的专有词召回率。
3. 热词数量与延迟、准确率的关系，用来确定 REQ-003 中 ASR 阶段可用的词条上限。

## References

[1]: https://github.com/QwenLM/Qwen3-ASR "QwenLM/Qwen3-ASR GitHub"
[2]: https://huggingface.co/Qwen/Qwen3-ASR-0.6B-hf "Qwen3-ASR-0.6B-hf model card"
[3]: https://k2-fsa.github.io/sherpa/onnx/qwen3-asr/index.html "sherpa-onnx Qwen3-ASR documentation"
[4]: https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tree/main "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25 files"
[5]: https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-recognizer-qwen3-asr-impl.cc "sherpa-onnx Qwen3-ASR recognizer implementation"
[6]: https://www.funasr.com/en/blog/which-funasr-model.html "Which FunASR Model? 2026 Guide"
[7]: https://whispernotes.app/blog/qwen3-asr-vs-whisper "Qwen3-ASR 1.7B vs Whisper Large V3 Turbo on one Mac"
[8]: https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html "sherpa-onnx Hotwords documentation"
[9]: https://github.com/QwenAudio/Fun-ASR "QwenAudio/Fun-ASR GitHub"
[10]: https://openrouter.ai/docs/guides/features/zdr "OpenRouter Zero Data Retention"
[11]: https://openrouter.ai/blog/insights/zero-data-retention/ "OpenRouter blog: Zero Data Retention"
