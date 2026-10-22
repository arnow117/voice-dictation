#!/usr/bin/env python3
"""Build the T001 benchmark data report from bench/asr/results/*.jsonl.

  uv run --project bench/asr python bench/asr/report.py --results bench/asr/results \
      --out bench/asr/reports/2026-10-21-m5.md --machine "Apple M5 ..."
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

import textnorm as tn

HERE = Path(__file__).resolve().parent
NAMES = {"qwen3-asr-0.6b-int8": "Qwen3-ASR-0.6B", "sensevoice-small-int8": "SenseVoice-Small",
         "funasr-nano-int8": "Fun-ASR-Nano", "whisper-turbo-int8": "Whisper-turbo"}
ORDER = list(NAMES)
CATS = [("zh", "中文 CER", 0.06), ("en", "英文 WER", 0.08), ("mixed", "混说 MER", 0.10), ("entity", "专有词句 CER", None)]


def load(path):
    meta, clips, end = None, [], None
    for line in path.read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        if r["type"] == "meta":
            meta = r
        elif r["type"] == "clip":
            clips.append(r)
        else:
            end = r
    return meta, clips, end


def pct(values, q):
    return float(np.percentile(values, q)) if values else float("nan")


def f_rate(x):
    return "—" if x is None or x != x else f"{x * 100:.1f}%"


def f_s(x):
    return "—" if x is None or x != x else f"{x:.2f}"


def mark(value, limit):
    if limit is None or value != value:
        return ""
    return " ✓" if value <= limit else " ✗"


def per_clip(testset, clips, relaxed=True):
    """(edit errors, reference length) per clip, the unit we resample in the bootstrap."""
    out = {}
    for c in clips:
        ref = tn.tokens(testset[c["id"]]["text"], relaxed=relaxed)
        out[c["id"]] = (tn.edit_distance(ref, tn.tokens(c["hyp"] or "", relaxed=relaxed)), len(ref))
    return out


def boot_ci(pairs, n=2000, seed=7):
    """95% bootstrap interval of sum(err)/sum(len) by resampling clips."""
    if not pairs:
        return float("nan"), float("nan")
    e = np.array([p[0] for p in pairs], float)
    l = np.array([p[1] for p in pairs], float)
    idx = np.random.default_rng(seed).integers(0, len(e), (n, len(e)))
    rates = e[idx].sum(1) / np.maximum(l[idx].sum(1), 1)
    return float(np.percentile(rates, 2.5)), float(np.percentile(rates, 97.5))


def boot_diff(a, b, n=2000, seed=7):
    """Paired bootstrap of rate(a) - rate(b) over the clip ids both have."""
    ids = sorted(set(a) & set(b))
    if not ids:
        return float("nan"), float("nan"), float("nan")
    ea = np.array([a[i][0] for i in ids], float)
    eb = np.array([b[i][0] for i in ids], float)
    l = np.array([a[i][1] for i in ids], float)
    idx = np.random.default_rng(seed).integers(0, len(ids), (n, len(ids)))
    d = (ea[idx].sum(1) - eb[idx].sum(1)) / np.maximum(l[idx].sum(1), 1)
    return float((ea.sum() - eb.sum()) / l.sum()), float(np.percentile(d, 2.5)), float(np.percentile(d, 97.5))


ROLE_TOKENS = {"system", "user", "assistant"}


def suspicious(ref, hyp):
    """Catastrophic output: empty, a bare chat-role token, or far shorter than the reference."""
    h = (hyp or "").strip().lower()
    if not h or h in ROLE_TOKENS:
        return True
    return len(tn.tokens(hyp, relaxed=True)) < 0.3 * len(tn.tokens(ref, relaxed=True))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=str(HERE / "results"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--machine", required=True)
    a = ap.parse_args()

    testset = {c["id"]: c for c in (json.loads(l) for l in (HERE / "testset.jsonl").read_text(encoding="utf-8").splitlines() if l)}
    found = {}
    for p in sorted(Path(a.results).glob("*/*.jsonl")):
        model, task, threads, provider, mode = p.stem.split("__")
        meta, clips, end = load(p)
        if meta is None or end is None:
            continue
        found[(p.parent.name, model, task, int(threads[1:]), provider, mode)] = (meta, clips, end, p)

    class Runs(dict):
        """runs[key] picks the terminal (performance-core) result when present, else the agent one."""
        def env(self, key):
            for e in ("terminal", "agent"):
                if (e,) + key in found:
                    return e
            return None

        def get(self, key, default=None):
            e = self.env(key)
            return found[(e,) + key] if e else default

        def __contains__(self, key):
            return self.env(key) is not None

        def __getitem__(self, key):
            return self.get(key)

    runs = Runs()

    def env_label(key):
        e = runs.env(key)
        r = runs.get(key)
        cores = r[2].get("cpu_percpu_avg") if r else None
        load = ""
        if cores and len(cores) == 10:
            load = f"（能效核 {sum(cores[:6]) / 6:.0f}% / 性能核 {sum(cores[6:]) / 4:.0f}%）"
        return {"terminal": "用户终端", "agent": "代理环境·仅能效核"}.get(e, "—") + load

    L = []
    w = L.append
    w("# T001 本地 ASR 评测数据（自动生成）\n")
    w(f"- 机器：{a.machine}")
    w("- 运行时：sherpa-onnx 1.13.8（Python，CPU 执行，除非另注明）；所有模型均为 int8 量化版本")
    w("- 测试集：`bench/asr/testset.jsonl`，120 条（中文 40 FLEURS、英文 30 FLEURS、中英混说 30 ASCEND、专有词 20 ContextASR-Dialogue）")
    w("- 计时：模型常驻、预热 1 次后，从创建 stream 到拿到结果，即\"松开快捷键→文字插入\"中的识别部分")
    w("- 错误率：中文按字、英文按词统一切分后的编辑距离。主口径为\"宽松口径\"：两边同样地把中文数字转为阿拉伯数字（2011年 与 二零一一年 视为相同）、"
      "去掉语气词（呃、嗯、uh、um 等）、合并逐个拼读的字母（i s m 与 ISM 视为相同）。这些差异在智能整理（REQ-002）中本来就会统一；\"原始\"口径不做这些处理")
    w("- 测量环境：Manus 代理启动的进程在这台 Mac 上只能使用 6 个能效核，因此准确率与热词在代理环境中测（与核心无关），"
      "计时以用户在自己终端中运行的结果为准；表中注明了每组数据的来源和运行期间两类核心的平均负载\n")

    # ------------------------------------------------------------ accuracy
    w("## 1. 准确率（4 线程，无热词，宽松口径）\n")
    w("| 模型 | " + " | ".join(n for _, n, _ in CATS) + " | 专有词召回 | 失败条数 |")
    w("|---|" + "---|" * (len(CATS) + 2))
    raw_rows = []
    acc_by_model = {}
    for m in ORDER:
        key = (m, "accuracy", 4, "cpu", "none")
        if key not in runs:
            continue
        _, clips, _, _ = runs[key]
        acc_by_model[m] = {c["id"]: c for c in clips}
        cells, raw_cells = [], []
        for cat, _, limit in CATS:
            cs = [c for c in clips if c["category"] == cat]
            refs = [testset[c["id"]]["text"] for c in cs]
            hyps = [c["hyp"] for c in cs]
            r_num = tn.error_rate(refs, hyps, relaxed=True)
            cells.append(f_rate(r_num) + mark(r_num, limit))
            raw_cells.append(f_rate(tn.error_rate(refs, hyps)))
        hits = total = 0
        for c in clips:
            if c["category"] == "entity":
                h, t = tn.entity_hits(testset[c["id"]]["entities"], c["hyp"])
                hits, total = hits + h, total + t
        fails = sum(1 for c in clips if c["error"])
        w(f"| {NAMES[m]} | " + " | ".join(cells) + f" | {hits}/{total}（{f_rate(hits / total if total else None)}） | {fails} |")
        raw_rows.append(f"| {NAMES[m]} | " + " | ".join(raw_cells) + " |")
    w("\n✓/✗ 对照 REQ-001 NFR-003：中文 CER ≤ 6%、英文 WER ≤ 8%、混说 MER ≤ 10%。专有词句没有单独目标。\n")
    w("原始口径（不做数字、语气词、拼读字母归一）：\n")
    w("| 模型 | " + " | ".join(n for _, n, _ in CATS) + " |")
    w("|---|" + "---|" * len(CATS))
    L.extend(raw_rows)
    w("")

    w("### 1.1 置信区间（宽松口径，bootstrap 2000 次，按句子重抽样）\n")
    w("每类只有 20～40 条，区间较宽；区间跨过目标线时，不能据此判断达标或不达标。\n")
    w("| 模型 | " + " | ".join(f"{n} 95% 区间" for _, n, _ in CATS) + " |")
    w("|---|" + "---|" * len(CATS))
    pcs = {}
    for m in acc_by_model:
        clips = list(acc_by_model[m].values())
        cells = []
        for cat, _, _ in CATS:
            pc = per_clip(testset, [c for c in clips if c["category"] == cat])
            pcs[(m, cat)] = pc
            lo, hi = boot_ci(list(pc.values()))
            cells.append(f"{f_rate(lo)}～{f_rate(hi)}")
        w(f"| {NAMES[m]} | " + " | ".join(cells) + " |")
    a_m, b_m = "qwen3-asr-0.6b-int8", "funasr-nano-int8"
    if (a_m, "zh") in pcs and (b_m, "zh") in pcs:
        w(f"\n{NAMES[a_m]} 减 {NAMES[b_m]}（同一批句子的配对差值，负数表示 Qwen3 更好）：\n")
        w("| 类别 | 差值 | 95% 区间 |")
        w("|---|---|---|")
        for cat, n, _ in CATS:
            d, lo, hi = boot_diff(pcs[(a_m, cat)], pcs[(b_m, cat)])
            w(f"| {n} | {d * 100:+.1f} 个百分点 | {lo * 100:+.1f}～{hi * 100:+.1f} |")
    w("")

    # ------------------------------------------------------------ latency
    w("## 2. 识别延迟（秒，4 线程，CPU）\n")
    w("拼接片段每种长度 10 条（中文 4、英文 3、混说 3），样本少，P95 基本等于最大值。\"真实句子\"一列取准确率测试中所有不超过 15 秒的原始片段。\n")
    w("| 模型 | 真实句子 ≤15 s P50 / P95 | 5 s P50 / P95 | 15 s P50 / P95 | 30 s P50 / P95 | 平均实时率 | 测量环境 |")
    w("|---|---|---|---|---|---|---|")
    for m in ORDER:
        lat = runs.get((m, "latency", 4, "cpu", "none"))
        acc = runs.get((m, "accuracy", 4, "cpu", "none"))
        if not lat and not acc:
            continue
        cells = []
        if acc:
            v = [c["decode_s"] for c in acc[1] if c["decode_s"] is not None and c["duration"] <= 15]
            cells.append(f"{f_s(pct(v, 50))} / {f_s(pct(v, 95))}")
        else:
            cells.append("—")
        rtf = []
        for t in (5, 15, 30):
            v = [c["decode_s"] for c in (lat[1] if lat else []) if c["target_s"] == t and c["decode_s"] is not None]
            cells.append(f"{f_s(pct(v, 50))} / {f_s(pct(v, 95))}" if v else "—")
            rtf += [c["decode_s"] / c["duration"] for c in (lat[1] if lat else []) if c["target_s"] == t and c["decode_s"]]
        w(f"| {NAMES[m]} | " + " | ".join(cells) + f" | {f_s(float(np.mean(rtf))) if rtf else '—'} | "
          f"拼接：{env_label((m, 'latency', 4, 'cpu', 'none'))}；真实句子：{env_label((m, 'accuracy', 4, 'cpu', 'none'))} |")
    w("\n对照 REQ-001 NFR-002（端到端，含插入）：15 秒以内 P50 ≤ 1.0 s、P95 ≤ 2.0 s；30 秒 P95 ≤ 3.5 s。上表只含识别，"
      "停止录音、插入等其余环节在 T002/T008 中测，需要给它们留出余量。\n")

    # ------------------------------------------------------------ memory
    w("## 3. 加载时间与内存（准确率测试进程）\n")
    w("| 模型 | 加载 s | 首次识别（预热）s | 加载后 RSS MB | 预热后 RSS MB | 进程峰值 RSS MB |")
    w("|---|---|---|---|---|---|")
    for m in ORDER:
        acc = runs.get((m, "accuracy", 4, "cpu", "none"))
        if not acc:
            continue
        meta, _, end, _ = acc
        w(f"| {NAMES[m]} | {meta['load_s']:.2f} | {meta['warmup_s']:.2f} | {meta['rss_after_load_mb']:.0f} | "
          f"{meta['rss_after_warmup_mb']:.0f} | {end['peak_rss_mb']:.0f} |" if end else f"| {NAMES[m]} | 未完成 |")
    w("\nQwen3-ASR 以 max_total_len=2048 运行（给热词实验留空间），KV 缓存按此预分配；产品中可按实际热词数量调小。\n")

    # ------------------------------------------------------------ threads / coreml
    w("## 4. Qwen3-ASR 线程数与 CoreML\n")
    w("| 配置 | 加载 s | 5 s P50 / P95 | 15 s P50 / P95 | 30 s P50 / P95 | 失败 | 测量环境 |")
    w("|---|---|---|---|---|---|---|")
    for m, th, prov in [("qwen3-asr-0.6b-int8", t, "cpu") for t in (2, 4, 6, 8)] + [
            ("qwen3-asr-0.6b-int8", 4, "coreml"), ("sensevoice-small-int8", 4, "cpu"), ("sensevoice-small-int8", 4, "coreml")]:
        r = runs.get((m, "latency", th, prov, "none"))
        label = f"{NAMES[m]} {prov.upper() if prov == 'coreml' else 'CPU'} {th} 线程"
        if not r:
            logs = sorted(Path(a.results).glob(f"*/{m}__latency__t{th}__{prov}__none.log"))
            text = logs[-1].read_text(errors="replace").strip() if logs else ""
            note = text.splitlines()[-1][:120] if text else "未运行"
            w(f"| {label} | — | — | — | — | {note} | — |")
            continue
        meta, clips, _, _ = r
        cells = []
        for t in (5, 15, 30):
            v = [c["decode_s"] for c in clips if c["target_s"] == t and c["decode_s"] is not None]
            cells.append(f"{f_s(pct(v, 50))} / {f_s(pct(v, 95))}" if v else "—")
        w(f"| {label} | {meta['load_s']:.2f} | " + " | ".join(cells) + f" | {sum(1 for c in clips if c['error'])} | "
          f"{env_label((m, 'latency', th, prov, 'none'))} |")
    w("")

    # ------------------------------------------------------------ hotwords
    w("## 5. 热词（专有词 20 条）\n")
    w("模式：none 不给热词；clip 只给这一句里出现的实体（理想上限）；dialogue 给这段对话的全部实体（9～21 个，相当于一份小词典）；"
      "global-N 把 20 条里出现过的全部实体与干扰词混成 N 个（相当于个人词典有 N 个词）。Qwen3-ASR 每次识别单独传热词，"
      "Fun-ASR-Nano 只能在加载时设定，词表变化时需要重建识别器。\n")
    w("热词实验在代理环境（仅能效核）中运行，耗时列只用于比较不同热词数量之间的相对变化。\n")
    w("| 模型 | 模式 | 热词数 | 实体召回 | 句子 CER（宽松） | 异常输出 | 识别 P50 / P95 s | 重建识别器 s | 失败 |")
    w("|---|---|---|---|---|---|---|---|---|")
    bad_examples = []
    for m in ("qwen3-asr-0.6b-int8", "funasr-nano-int8"):
        for mode in ("none", "clip", "dialogue", "global-50", "global-100", "global-200"):
            r = runs.get((m, "hotwords", 4, "cpu", mode))
            if not r:
                continue
            _, clips, _, _ = r
            hits = total = 0
            for c in clips:
                h, t = tn.entity_hits(testset[c["id"]]["entities"], c["hyp"])
                hits, total = hits + h, total + t
            counts = sorted({c["hotword_count"] for c in clips})
            cnt = str(counts[0]) if len(counts) == 1 else f"{counts[0]}～{counts[-1]}"
            refs = [testset[c["id"]]["text"] for c in clips]
            cer = tn.error_rate(refs, [c["hyp"] for c in clips], relaxed=True)
            bad = [c for c in clips if suspicious(testset[c["id"]]["text"], c["hyp"])]
            bad_examples += [(NAMES[m], mode, c["id"], c["hotword_count"], c["hyp"]) for c in bad]
            v = [c["decode_s"] for c in clips if c["decode_s"] is not None]
            rb = [c["rebuild_s"] for c in clips if c["rebuild_s"]]
            w(f"| {NAMES[m]} | {mode} | {cnt} | {hits}/{total}（{f_rate(hits / total if total else None)}） | {f_rate(cer)} | "
              f"{len(bad)} | {f_s(pct(v, 50))} / {f_s(pct(v, 95))} | {f_s(float(np.mean(rb))) if rb else '—'} | "
              f"{sum(1 for c in clips if c['error'])} |")
    w("\n异常输出：结果为空、只有 system/user/assistant 这类角色标记，或长度不足参考文本的 30%。\n")
    for name, mode, cid, n, hyp in bad_examples:
        w(f"- {name} {mode}（{n} 个热词）{cid}：输出\"{(hyp or '').strip()[:60]}\"")
    w("")

    # ------------------------------------------------------------ examples
    w("## 6. 识别样例（每类前 2 条，准确率测试）\n")
    for cat, name, _ in CATS:
        ids = [i for i, c in testset.items() if c["category"] == cat][:2]
        for i in ids:
            w(f"**{i}**（{testset[i]['duration']:.1f} s）参考：{testset[i]['text']}\n")
            for m in ORDER:
                if m in acc_by_model and i in acc_by_model[m]:
                    w(f"- {NAMES[m]}：{acc_by_model[m][i]['hyp'] or '（空）'}")
            w("")

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"report -> {out}")


if __name__ == "__main__":
    main()
