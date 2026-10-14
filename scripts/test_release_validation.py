import unittest
from macos_profile_report import assess
from macos_live_report import classify


def profile():
    return {'observerStarted': True, 'completedMeasurement': True, 'actualSeconds': 300,
            'workload': 'local-video', 'returnedToIdleBaseline': True, 'droppedFramesMeasured': True,
            'passed': True, 'rssGrowthKiB': 74999,
            'disposalSamples': [{'elapsedSeconds': 60, 'processes': []}],
            'samples': [{'processes': [{'pid': 1, 'processType': 'host', 'rssKiB': 100, 'command': 'host'},
                                       {'pid': 2, 'processType': 'renderer', 'rssKiB': 100, 'command': 'renderer'},
                                       {'pid': 3, 'processType': 'gpu-process', 'rssKiB': 100, 'command': 'gpu'}],
                         'localMedia': {'frames': i + 1}} for i in range(3)]}


class Reports(unittest.TestCase):
    def test_complete_profile(self):
        self.assertEqual(assess(profile())['verdict'], 'PASS')

    def test_exact_threshold_fails(self):
        p = profile(); p['rssGrowthKiB'] = 75000
        self.assertEqual(assess(p)['strictRssAcceptance'], 'FAIL')
        self.assertEqual(assess(p)['verdict'], 'FAIL')

    def test_empty_missing_observer_or_artifacts_never_pass(self):
        for key, value in [('samples', []), ('observerStarted', False), ('actualSeconds', 0), ('completedMeasurement', False),
                           ('rssGrowthKiB', None), ('disposalSamples', []), ('returnedToIdleBaseline', False), ('droppedFramesMeasured', False)]:
            p = profile(); p[key] = value
            self.assertEqual(assess(p)['verdict'], 'FAIL', key)

    def test_missing_helper_evidence(self):
        p = profile()
        for s in p['samples']: s['processes'] = s['processes'][:1]
        self.assertEqual(assess(p)['verdict'], 'FAIL')

    def test_renderer_survives_disposal_fails(self):
        p = profile(); p['disposalSamples'] = [{'elapsedSeconds': 60, 'processes': [{'processType': 'renderer'}]}]
        self.assertEqual(assess(p)['verdict'], 'FAIL')

    def test_external_challenge_blocked_not_pass(self):
        self.assertEqual(classify({'passed': False}, 'Sign_in_to_confirm_you_re_not_a_bot', 1)['verdict'], 'BLOCKED')

    def test_error150_alone_is_not_proof_of_bot_challenge(self):
        self.assertEqual(classify({'passed': False, 'failure': 'error150'}, '', 1)['verdict'], 'FAIL')

    def test_missing_report_or_unknown_failure_not_pass(self):
        self.assertEqual(classify({}, '', 0)['verdict'], 'FAIL')
        self.assertEqual(classify({'passed': True}, '', 1)['verdict'], 'FAIL')

    def test_live_pass_requires_completed_report_and_zero_exit(self):
        self.assertEqual(classify({'passed': True}, '', 0)['verdict'], 'PASS')


if __name__ == '__main__':
    unittest.main()
