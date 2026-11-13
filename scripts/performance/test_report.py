"""Report math must not hide invalid samples or mislabel warm measurements."""
import unittest
from run import summary


class SummaryTests(unittest.TestCase):
    def test_even_median_and_nearest_rank_p95(self):
        result = summary(list(range(1, 21)))
        self.assertEqual(result['median_ms'], 10.5)
        self.assertEqual(result['p95_ms'], 19)
        self.assertEqual(result['first_ms'], 1)
        self.assertEqual(result['n'], 20)

    def test_first_is_input_order_not_minimum(self):
        result = summary([50, 2, 4])
        self.assertEqual(result['first_ms'], 50)
        self.assertEqual(result['median_ms'], 4)

    def test_invalid_timings_are_rejected(self):
        for samples in ([], [-1], [float('nan')], [float('inf')]):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                summary(samples)


if __name__ == '__main__':
    unittest.main()
