#!/usr/bin/env python3
"""A cost check must tolerate shared load and still reject a persistent slowdown."""
import unittest
from unittest.mock import patch
import test_redaction_cost as cost


class CostBudgetTest(unittest.TestCase):
    def measured(self, baseline, current, kind='url-fifty-deep'):
        with patch.object(cost, 'sample', side_effect=lambda operation, size, kind, binary:
                          baseline if binary == cost.BASE_BINARY else current):
            return cost.paired_cost('apply', 100000, kind)

    def test_shared_load_keeps_the_same_verdict(self):
        for load in (1, 5, 20):
            self.assertFalse(cost.exceeds_budget(self.measured(0.07 * load, 0.12 * load)))

    def test_persistent_threefold_regression_fails_under_load(self):
        for load in (1, 5, 20):
            self.assertTrue(cost.exceeds_budget(self.measured(0.07 * load, 0.21 * load)))

    def test_fast_path_budget_is_scoped_and_still_bounds_regression(self):
        for kind in ('digits', 'split-digits', 'joined-prefixes'):
            for load in (1, 5, 20):
                self.assertFalse(cost.exceeds_budget(self.measured(0.013 * load, 0.037 * load, kind)))
                self.assertTrue(cost.exceeds_budget(self.measured(0.013 * load, 0.052 * load, kind)))
        self.assertTrue(cost.exceeds_budget(self.measured(0.013, 0.037, 'source-like')))

    def test_timeout_is_never_accepted(self):
        self.assertTrue(cost.exceeds_budget(self.measured(0.07, None)))
        self.assertTrue(cost.exceeds_budget(self.measured(None, 0.12)))

    def test_adjacent_pairs_reverse_order(self):
        with patch.object(cost, 'sample', return_value=0.07) as sample:
            cost.paired_cost('apply', 100000, 'url-fifty-deep')
        self.assertEqual([call.args[3] for call in sample.call_args_list],
                         [cost.BASE_BINARY, cost.BINARY, cost.BINARY,
                          cost.BASE_BINARY, cost.BASE_BINARY, cost.BINARY])


if __name__ == '__main__':
    unittest.main()
