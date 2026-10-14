import unittest
from macos_performance_report import analyze, stats


class PerformanceTests(unittest.TestCase):
    def report(self):
        return {'samples': [{'elapsedSeconds': i * 10,
            'rendering': {'completedMetalFrames': i * 150,
                'videoQuality': [{'targetId':'t','contextId':1,'videoIndex':0,'totalVideoFrames': i * 300,
                    'droppedVideoFrames': i * 60,'presentedFrames':i * 240}]}} for i in range(3)]}

    def test_matched_drop_fraction_and_distinct_rates(self):
        result = analyze(self.report())
        self.assertEqual(result['matchedDropFraction'], .2)
        self.assertEqual(result['windows'][0]['chromiumSubmittedFps'], 24)
        self.assertEqual(result['windows'][0]['metalCompletionFps'], 15)
        self.assertEqual(result['diagnosticVerdict'], 'INCONCLUSIVE')

    def test_counter_reset_is_not_negative_drops_or_pass(self):
        data = self.report()
        data['samples'][-1]['rendering']['videoQuality'][0]['totalVideoFrames'] = 0
        self.assertEqual(analyze(data)['diagnosticVerdict'], 'FAIL')

    def test_different_context_is_not_paired(self):
        data = self.report()
        data['samples'][-1]['rendering']['videoQuality'][0]['contextId'] = 2
        self.assertEqual(analyze(data)['matchedTotalDelta'], 300)

    def test_missing_samples_and_latency_remain_unknown(self):
        result = analyze({'samples': []})
        self.assertIsNone(result['decodeProcessingMs'])
        self.assertIsNone(result['matchedDropFraction'])
        self.assertIn('End-to-end latency', result['unmeasured'])
        self.assertIsNone(stats([]))


if __name__ == '__main__':
    unittest.main()
