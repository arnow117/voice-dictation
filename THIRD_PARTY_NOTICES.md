# 第三方声明

闪说自有源代码使用根目录的 [MIT 许可](LICENSE)。下面的代码、模型、数据及其派生内容
保留各自许可；根目录 MIT 许可不替代这些条款。各组件与本项目维护者无隶属或背书关系。

## 应用运行库

应用从 sherpa-onnx 官方发布下载固定版本的 macOS arm64 静态库，在本机链接。
下载归档的版本与 SHA-256 由 `scripts/fetch-vendor.sh` 固定；库文件不提交到 Git。
头文件 `Vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h` 保留原始版权注释。

| 组件 | 版本 / 来源 | 许可与随附文件 |
|---|---|---|
| sherpa-onnx | [v1.13.8](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8)，Copyright Xiaomi Corporation / 上游贡献者 | Apache-2.0，[正文](licenses/sherpa-onnx.LICENSE) |
| ONNX Runtime | [v1.28.2](https://github.com/microsoft/onnxruntime/tree/v1.28.2)，Copyright Microsoft Corporation；sherpa 构建采用 csukuangfj/onnxruntime-libs 的 arm64 静态分发 | MIT，[许可](licenses/onnxruntime.LICENSE)、[上游完整第三方声明](licenses/onnxruntime.ThirdPartyNotices.txt) |
| kaldi-decoder | [v0.3.0](https://github.com/k2-fsa/kaldi-decoder/tree/v0.3.0)，含 Kaldi 衍生代码，版权保留在上游源码 | Apache-2.0，[正文](licenses/kaldi-decoder.LICENSE) |
| kaldi-native-fbank | [v1.22.3](https://github.com/csukuangfj/kaldi-native-fbank/tree/v1.22.3)，版权保留在上游源码 | Apache-2.0，[正文](licenses/kaldi-native-fbank.LICENSE) |
| OpenFst / kaldifst | sherpa v1.13.8 中的 [OpenFst fork v1.8.5-2026-07-09](https://github.com/csukuangfj/openfst/tree/v1.8.5-2026-07-09)，含 Google 与上游贡献者代码 | Apache-2.0，[上游 COPYING](licenses/openfst.COPYING)，完整 Apache 正文同上 |
| KissFFT | [febd4caeed32e33ad8b2e0bb5ea77542c40f18ec](https://github.com/mborgerding/kissfft/tree/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec)，Copyright (c) 2003–2010 Mark Borgerding | BSD-3-Clause，[版权声明](licenses/kissfft.COPYING)、[上游条款](licenses/kissfft.BSD-3-Clause)、[许可正文](licenses/kissfft.BSD-3-Clause.txt) |
| simple-sentencepiece | [v0.7](https://github.com/pkufool/simple-sentencepiece/tree/v0.7)，版权保留在上游源码 | Apache-2.0，[正文](licenses/simple-sentencepiece.LICENSE) |
| JSON for Modern C++ | [v3.12.0](https://github.com/nlohmann/json/tree/v3.12.0)，Copyright (c) 2013–2025 Niels Lohmann | MIT，[正文](licenses/nlohmann-json.LICENSE.MIT) |
| hclust-cpp / fastcluster | [2026-02-25](https://github.com/csukuangfj/hclust-cpp/tree/2026-02-25)，Copyright Daniel Müllner / Christoph Dalitz，完整署名见许可文件 | BSD-2-Clause，[正文](licenses/hclust-cpp.LICENSE) |
| Eigen | [5.0.1](https://gitlab.com/libeigen/eigen/-/tree/5.0.1)，版权由各上游源文件作者保留 | MPL-2.0，部分文件另有宽松许可；[MPL 正文](licenses/Eigen.COPYING.MPL2)，未修改的对应源码可从版本链接取得 |

依赖版本依据 sherpa-onnx v1.13.8 的 `cmake/` 构建清单核对。
ONNX Runtime 的完整声明覆盖其多种构建配置，并不表示其中所有可选组件均包含在本应用中。
不需要的 PortAudio 静态库不参与应用链接；音频采集使用 macOS AVFoundation。
系统框架由 macOS 提供，不随本项目重新分发。
Eigen 的 MPL 条款适用于其覆盖文件，不将闪说自有代码改为 MPL；本项目未修改 Eigen。

## 识别模型

首版只提供 **Qwen3-ASR-0.6B int8**，安装包不含模型权重，首次运行时下载。
模型原始发布方为 Qwen 团队，原始模型卡为
[Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)，标注 Apache-2.0。
随附 [Qwen3-ASR 许可正文](licenses/Qwen3-ASR.LICENSE)。

ONNX int8 转换包由 sherpa-onnx 社区提供：
[csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25](https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25)，
固定 revision `68818b2313fe77bd06f6a7c5068ff3ef59d02b8a`。
文件大小与 SHA-256 记录在仓库内模型清单中；应用不修改模型权重。
转换包仓库未单独声明新的许可，使用上游模型的 Apache-2.0 条款与来源署名。
下载镜像只改变托管来源，不改变校验清单和模型许可。

`bench/` 和 `spikes/model-download/` 中可能保留其他候选模型的历史研究记录及下载脚本；
这些模型不是首版分发资产。特别是 SenseVoice 的模型条款不能由本项目 MIT 许可覆盖，
若以后分发其他模型，需重新检查其许可。

## 评测数据及结果

仓库只保存选样清单、文本参考、识别输出和统计结果，不分发评测音频。
`bench/asr/prepare_data.py` 中固定数据 revision，`bench/asr/testset.jsonl` 的每条记录
含原始来源与许可。切片、重采样、选样和文本归一化由评测脚本执行。
这些文本片段、相应识别输出及报告中的引用保留以下来源许可。

| 数据 | 署名、原始来源 | 许可 |
|---|---|---|
| FLEURS 中文与英文，70 条 | FLEURS authors / Google，Conneau et al., *FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech*，[数据集](https://huggingface.co/datasets/google/fleurs) | CC-BY-4.0，[正文](licenses/CC-BY-4.0.txt) |
| ASCEND 中英混说，30 条 | ASCEND authors / CAiRE, HKUST，[数据集](https://huggingface.co/datasets/CAiRE/ASCEND)、[项目](https://github.com/HLTCHKUST/ASCEND) | CC-BY-SA-4.0，[正文](licenses/CC-BY-SA-4.0.txt)；本项目中 ASCEND 文本片段及相应改编仍按相同许可提供 |
| ContextASR-Bench 中文对话实体，20 条 | He Wang et al., *ContextASR-Bench*，[数据集](https://huggingface.co/datasets/MrSupW/ContextASR-Bench)、[项目](https://github.com/MrSupW/ContextASR-Bench) | MIT，[上游版权与许可](licenses/ContextASR-Bench.GitHub.LICENSE)；本部分为合成语音，不当作真人录音结果 |

评测结果中的句子不是私人听写历史。重新分发或改编数据时，请保留来源、许可和改动说明；
数据许可与本项目代码许可分别适用。
