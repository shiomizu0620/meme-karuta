"""stats.py のユニットテスト。"""
import unittest

from generate import CARDS
from stats import (
    category_balance, count_by_category, count_by_set,
    render_report, text_length_stats,
)


class StatsTests(unittest.TestCase):
    def test_count_by_set_sums_to_total(self):
        self.assertEqual(sum(count_by_set(CARDS).values()), len(CARDS))

    def test_count_by_category_sums_to_total(self):
        self.assertEqual(sum(count_by_category(CARDS).values()), len(CARDS))

    def test_text_length_stats(self):
        self.assertIn("min", text_length_stats(CARDS)["fuda"])

    def test_category_balance(self):
        self.assertGreaterEqual(category_balance(CARDS)["ratio"], 0.0)

    def test_render_report_has_header(self):
        self.assertIn("カード統計", render_report(CARDS))
