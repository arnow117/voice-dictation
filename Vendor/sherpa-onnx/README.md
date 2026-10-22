# Vendor/sherpa-onnx

本地语音识别运行时，固定为 sherpa-onnx v1.13.8（Apache-2.0，<https://github.com/k2-fsa/sherpa-onnx>）。

`include/sherpa-onnx/c-api/c-api.h` 原样取自 v1.13.8 标签，入库。`lib/` 下的静态库由 `scripts/fetch-vendor.sh` 从官方发布页下载（`sherpa-onnx-v1.13.8-osx-arm64-static-no-tts-lib.tar.bz2`，SHA-256 `3d7f9b8a496694af13d9802c33b8133231e397bdef302f543d19468765e83136`），不入库。

升级版本需要另开 Task：同时更新脚本里的版本号和 SHA-256、头文件，并重跑 `bench/asr` 和 `scripts/test.sh`。
