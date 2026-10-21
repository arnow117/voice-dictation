"""Text normalisation and scoring for the T001 ASR benchmark.

One tokenisation is used for every category so the numbers are comparable:
each CJK character is a token and each Latin/digit run is a token. On pure
Chinese this is CER, on pure English it is WER, and on mixed speech it is the
usual MER (mixed error rate).

Numbers: references and hypotheses often differ only in how numbers are written
(2011年 vs 二零一一年, 40% vs 百分之四十). With numbers=True both sides are passed
through cn_numbers() first. relaxed=True additionally drops fillers (呃/嗯/uh/um ...)
and joins spelled-out letters (ASCEND writes "i s m" where models write "ISM").
The report shows both the raw and the relaxed figures.
"""
import re
import unicodedata

from opencc import OpenCC

_T2S = OpenCC("t2s")
_TAG = re.compile(r"\[[^\]]*\]|<[^>]*>")
_TOKEN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]|[a-z0-9\u00c0-\u024f]+")
_CN_DIGITS = {"零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_CN_UNITS = {"十": 10, "百": 100, "千": 1000}
_CN_BIG = {"万": 10 ** 4, "亿": 10 ** 8}
_CN_RUN = re.compile(r"(百分之)?([零〇一二两三四五六七八九十百千万亿]+)")


def _cn_value(run: str) -> str:
    if all(ch in _CN_DIGITS for ch in run):  # 二零一一 -> 2011, 八 -> 8
        return "".join(str(_CN_DIGITS[ch]) for ch in run)
    total = section = num = 0
    for ch in run:
        if ch in _CN_DIGITS:
            num = _CN_DIGITS[ch]
        elif ch in _CN_UNITS:
            section += (num or 1) * _CN_UNITS[ch]
            num = 0
        else:
            section += num
            total += (section or 1) * _CN_BIG[ch]
            section = num = 0
    return str(total + section + num)


def cn_numbers(text: str) -> str:
    """Rewrite Chinese numerals as digits; 百分之X becomes X (the % sign is dropped by normalize anyway)."""
    return _CN_RUN.sub(lambda m: _cn_value(m.group(2)), text)


def normalize(text: str, numbers: bool = False) -> str:
    t = unicodedata.normalize("NFKC", text)
    t = _TAG.sub(" ", t)
    t = _T2S.convert(t).lower()
    if numbers:
        t = cn_numbers(t)
    t = t.replace("'", "").replace("\u2019", "")
    t = "".join(ch if (ch.isalnum() or ch.isspace()) else " " for ch in t)
    return re.sub(r"\s+", " ", t).strip()


_CN_FILLERS = set("呃嗯额唔啊哦噢诶欸")
_EN_FILLERS = {"uh", "um", "er", "erm", "ah", "hmm", "mm"}


def tokens(text: str, numbers: bool = False, relaxed: bool = False) -> list:
    """relaxed = numbers + drop fillers + join spelled letters (i s m -> ism) on whichever side is scored."""
    toks = _TOKEN.findall(normalize(text, numbers or relaxed))
    if not relaxed:
        return toks
    out, letters = [], []
    for t in toks:
        if t in _CN_FILLERS or t in _EN_FILLERS:
            continue
        if len(t) == 1 and t.isascii() and t.isalpha():
            letters.append(t)
            continue
        if letters:
            out.append("".join(letters))
            letters = []
        out.append(t)
    if letters:
        out.append("".join(letters))
    return out


def edit_distance(ref: list, hyp: list) -> int:
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def error_rate(refs: list, hyps: list, numbers: bool = False, relaxed: bool = False) -> float:
    errors = total = 0
    for r, h in zip(refs, hyps):
        rt = tokens(r, numbers, relaxed)
        errors += edit_distance(rt, tokens(h, numbers, relaxed))
        total += len(rt)
    return errors / total if total else 0.0


def _compact(text: str) -> str:
    return normalize(text).replace(" ", "")


def entity_hits(entities: list, hyp: str) -> tuple:
    """Count entities that appear verbatim in the hypothesis (case and spacing ignored)."""
    h = _compact(hyp)
    wanted = [e for e in (_compact(x) for x in entities) if e]
    return sum(1 for e in wanted if e in h), len(wanted)
