"""Tests for bench/asr/textnorm.py.  Run: uv run --project bench/asr python -m unittest bench/asr/test_textnorm.py"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import textnorm as tn  # noqa: E402


class NormaliseTests(unittest.TestCase):
    def test_case_punctuation_and_width(self):
        self.assertEqual(tn.normalize("Hello, World！ ２０２６年。"), "hello world 2026年")

    def test_apostrophes_and_hyphens(self):
        self.assertEqual(tn.normalize("Don't re-use it"), "dont re use it")

    def test_traditional_is_folded_to_simplified_for_common_chars(self):
        self.assertEqual(tn.normalize("這個時間點"), "这个时间点")

    def test_annotation_tags_are_dropped(self):
        self.assertEqual(tn.normalize("我想 [UNK] <noise> 去"), "我想 去")


class TokenTests(unittest.TestCase):
    def test_mixed_tokens(self):
        self.assertEqual(tn.tokens("我用Manus写code 2026年"), ["我", "用", "manus", "写", "code", "2026", "年"])

    def test_pure_english(self):
        self.assertEqual(tn.tokens("The quick brown fox."), ["the", "quick", "brown", "fox"])


class DistanceTests(unittest.TestCase):
    def test_levenshtein(self):
        self.assertEqual(tn.edit_distance(["a", "b", "c"], ["a", "x", "c", "d"]), 2)
        self.assertEqual(tn.edit_distance([], ["a"]), 1)
        self.assertEqual(tn.edit_distance(["a"], []), 1)

    def test_corpus_error_rate_weights_by_reference_length(self):
        rate = tn.error_rate(["今天天气很好", "hello world"], ["今天天汽很好", "hello"])
        self.assertAlmostEqual(rate, 2 / 8)


class EntityTests(unittest.TestCase):
    def test_recall_ignores_spacing_and_case(self):
        hits, total = tn.entity_hits(["闪说", "OpenRouter", "Qwen3-ASR"], "我在闪说里配置 open router 和 qwen3 asr")
        self.assertEqual((hits, total), (3, 3))

    def test_missing_entity(self):
        hits, total = tn.entity_hits(["王大锤", "Kowalski"], "王大垂和 kowalski")
        self.assertEqual((hits, total), (1, 2))


class NumberTests(unittest.TestCase):
    def test_digit_by_digit_years(self):
        self.assertEqual(tn.cn_numbers("二零一一年八月"), "2011年8月")

    def test_unit_numbers(self):
        self.assertEqual(tn.cn_numbers("十五米"), "15米")
        self.assertEqual(tn.cn_numbers("三千五百人"), "3500人")
        self.assertEqual(tn.cn_numbers("两万"), "20000")
        self.assertEqual(tn.cn_numbers("一百零五"), "105")

    def test_percent(self):
        self.assertEqual(tn.cn_numbers("增长百分之四十"), "增长40")

    def test_number_option_makes_digit_and_word_forms_equal(self):
        ref = "该项目于2011年8月完工"
        hyp = "该项目于二零一一年八月完工"
        self.assertGreater(tn.error_rate([ref], [hyp]), 0)
        self.assertEqual(tn.error_rate([ref], [hyp], numbers=True), 0)


class RelaxedTests(unittest.TestCase):
    def test_spelled_letters_are_joined(self):
        self.assertEqual(tn.tokens("那个i s m information", relaxed=True), ["那", "个", "ism", "information"])
        self.assertEqual(tn.tokens("那个ISM information", relaxed=True), ["那", "个", "ism", "information"])

    def test_fillers_are_dropped_on_both_sides(self):
        ref = "在念呃computer engineering对那u g的时候"
        hyp = "在念啊，computer engineering。对，那UG的时候"
        self.assertGreater(tn.error_rate([ref], [hyp]), 0)
        self.assertEqual(tn.error_rate([ref], [hyp], relaxed=True), 0)

    def test_english_fillers(self):
        self.assertEqual(tn.tokens("uh I think um it works", relaxed=True), ["i", "think", "it", "works"])

    def test_relaxed_includes_numbers(self):
        self.assertEqual(tn.error_rate(["2011年"], ["二零一一年"], relaxed=True), 0)


if __name__ == "__main__":
    unittest.main()
