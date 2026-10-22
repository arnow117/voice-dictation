# T003 模型下载源验证（spike，不进产品）

这个目录验证 FEAT-001 ED-009 的下载行为，结论供 T012（Swift 实现的模型管理）使用。代码只用 Python 标准库，正式实现时会用 Swift 重写。

## 结论

**下载方式**：逐文件下载，不使用 GitHub Releases 的整包 tar.bz2。整包需要先解压 bz2，中途坏了也只能整包重下；逐文件下载可以对每个文件单独续传和校验。

**源顺序**：测试版先用 Hugging Face，失败时换 hf-mirror.com。两者路径结构相同（`/<repo>/resolve/<revision>/<path>`），都支持 HTTP Range，Hugging Face 重定向到 CDN 后 Range 头也保留。URL 中的 revision 固定为 commit 哈希，不使用 `main`，避免上游更新后文件和清单对不上。

**ModelScope**：上面没有 sherpa-onnx 格式的包（`csukuangfj` 和 `csukuangfj2` 名下都查不到），只有 Qwen 官方的 PyTorch 权重。公开分发前如果需要国内源，要自建镜像，可以在 ModelScope 上建自有仓库，也可以放到对象存储上。只要清单中的路径和 SHA-256 不变，客户端就只需新增一个源模板。测试版不做自建镜像。

**校验**：应用内置清单，记录每个文件的大小和 SHA-256。大文件使用 Hugging Face 公布的 LFS SHA-256；没有 LFS 哈希的小文本文件由 `manifest.py pin` 在下载并核对大小后计算，并标注来源。下载中的数据写入 `.part` 文件，校验通过后才原子重命名为正式文件。校验失败时删除 `.part` 并自动重下一次，第二次仍失败就报错，磁盘上不留下半截文件。

**续传**：网络出错时保留 `.part`，换下一个源后从断点继续下载，这一点已在真实服务器上验证。服务器如果忽略 Range、返回 200，就丢弃已下载的部分，从头开始。

## 实测数据（开发机 Apple M5 / macOS 26.4.1，2026-10-21）

| 实验 | 结果 |
|---|---|
| 换源续传：decoder.int8.onnx（755,914,231 字节），先从 HF 下载 100 MB 后模拟中断，再从 hf-mirror 续传 | 续传 651,056,631 字节，27.2 秒，SHA-256 与 HF LFS 记录一致 |
| 4 个候选模型全量下载（HF 优先，hf-mirror 后备） | 全部来自 HF，没有源失败或校验失败；大文件 15.9～20.6 MB/s |
| 30 MB 分段测速 | HF 8.9 MB/s，hf-mirror 7.6 MB/s，GitHub 13.0 MB/s，ModelScope（官方权重）6.4 MB/s |

**限制**：本机网络经过代理客户端（fake-IP/TUN 模式，所有域名解析到 198.18.0.0/15，出口在新加坡），直连和显式代理测出的是同一条线路，**中国大陆直连下的可用性没有测到**。测试版的使用者和开发者处在同样的网络环境，不阻塞测试版；公开分发前需要在不经代理的国内网络中复测，再决定是否自建镜像。

## 文件

| 文件 | 作用 |
|---|---|
| `download.py` | 下载器：Range 续传、按顺序换源、跨源续传、SHA-256 校验与一次自动重下、`.part` 原子重命名；`--interrupt-after` 用于模拟断网 |
| `test_download.py` | 10 项测试，用本地 HTTP 服务模拟续传、重定向、服务器忽略 Range、坏文件、源不可达和跨源续传 |
| `manifest.py` | `build` 从 Hugging Face API 按固定 revision 生成清单；`pin` 为小文件补算 SHA-256 |
| `models.json` | 4 个候选模型的清单（T001 评测用）。T001 定下默认模型后，T012 只内置选中的模型 |

## 运行

```bash
# 测试（需要在 127.0.0.1 上监听端口）
uv run --no-project --python 3.12 python -m unittest -v spikes/model-download/test_download.py

# 下载一个模型
uv run --no-project --python 3.12 python spikes/model-download/download.py \
  --manifest spikes/model-download/models.json --model qwen3-asr-0.6b-int8 \
  --dest <models dir> --source hf --source hf-mirror
```

详细数据与来源见 `research/build-download-and-bench-notes.md`。
