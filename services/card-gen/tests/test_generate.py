"""generate.py のユニットテスト。pytest または unittest どちらでも実行可能。"""
import unittest

from generate import (
    CARDS, SETS, SET_IDS,
    filter_by_category, get_category_stats,
    ranked_search, score_card, search_cards,
    validate_all, validate_card,
)


class CardValidationTests(unittest.TestCase):
    def test_valid_card_has_no_errors(self):
        self.assertEqual(validate_card(CARDS[0]), [])

    def test_negative_id_rejected(self):
        bad = dict(CARDS[0]); bad["id"] = -1
        self.assertTrue(any("positive integer" in e for e in validate_card(bad)))

    def test_empty_fuda_rejected(self):
        bad = dict(CARDS[0]); bad["fuda"] = "  "
        self.assertTrue(any("fuda" in e for e in validate_card(bad)))

    def test_bad_image_path_rejected(self):
        bad = dict(CARDS[0]); bad["image"] = "no/path.exe"
        self.assertTrue(any("image path" in e for e in validate_card(bad)))

    def test_validate_all_detects_duplicate_id(self):
        dup = list(CARDS) + [dict(CARDS[0])]
        results = validate_all(dup)
        self.assertTrue(any("duplicate id" in e for v in results.values() for e in v))


class SearchTests(unittest.TestCase):
    def test_search_returns_matching_cards(self):
        self.assertGreater(len(search_cards(CARDS, "そう")), 0)

    def test_search_is_case_insensitive(self):
        self.assertEqual(len(search_cards(CARDS, "SOU")), len(search_cards(CARDS, "sou")))

    def test_score_card_higher_for_fuda_match(self):
        card = CARDS[0]
        self.assertGreater(score_card(card, card["fuda"][:3]), 0)
        self.assertGreater(score_card(card, card["yomi"][:3]), 0)

    def test_ranked_search_respects_limit(self):
        self.assertLessEqual(len(ranked_search(CARDS, "や", limit=3)), 3)


class CategoryTests(unittest.TestCase):
    def test_filter_by_category_returns_only_that_category(self):
        cat = CARDS[0]["category"]
        for c in filter_by_category(CARDS, cat):
            self.assertEqual(c["category"], cat)

    def test_get_category_stats_sums_to_total(self):
        stats = get_category_stats(CARDS)
        self.assertEqual(sum(stats.values()), len(CARDS))


class LoaderIntegrationTests(unittest.TestCase):
    def test_all_30_cards_loaded(self):
        self.assertEqual(len(CARDS), 30)

    def test_all_3_sets_loaded(self):
        self.assertEqual(len(SETS), 3)

    def test_every_card_has_set(self):
        for c in CARDS:
            self.assertIn(c["set"], SET_IDS)


def build_suite() -> unittest.TestSuite:
    """generate.py の `CARD_GEN_MODE=test` で実行されるスイートを返す。"""
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()
    for cls in (CardValidationTests, SearchTests, CategoryTests, LoaderIntegrationTests):
        suite.addTests(loader.loadTestsFromTestCase(cls))
    return suite


if __name__ == "__main__":
    unittest.main()
