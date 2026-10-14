"""Classify proven service challenges separately; unknown failures remain FAIL."""
import argparse
import json
from pathlib import Path


def classify(report, logs, exit_status):
    if exit_status != 0 and ('Sign_in_to_confirm_you_re_not_a_bot' in logs or
                             'LOGIN_REQUIRED' in logs or 'HTTP 429' in logs):
        return {'verdict': 'BLOCKED', 'reason': 'Explicit external authentication/rate-limit challenge',
                'productRegression': 'INCONCLUSIVE', 'exitStatus': exit_status}
    if exit_status == 0 and report.get('passed') is True:
        return {'verdict': 'PASS', 'reason': 'Live workload completed', 'exitStatus': 0}
    return {'verdict': 'FAIL', 'reason': report.get('failure', 'Missing report or failed live validation without proven external challenge'),
            'productRegression': 'INCONCLUSIVE', 'exitStatus': exit_status}


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--directory', type=Path, required=True)
    a = p.parse_args()
    stages = []
    for name, report in [('youtube-live', 'youtube-live.json'), ('allocation-profile', 'allocation-profile.json')]:
        try:
            result = json.loads((a.directory / name / 'result.json').read_text())
            data = json.loads((a.directory / report).read_text())
            logs = '\n'.join(x.read_text(errors='replace') for x in (a.directory / name).glob('*.log'))
            stages.append(dict(stage=name, **classify(data, logs, result['exitStatus'])))
        except (OSError, ValueError, KeyError) as error:
            stages.append(dict(stage=name, verdict='FAIL', reason=str(error)))
    verdict = 'FAIL' if any(s['verdict'] == 'FAIL' for s in stages) else 'BLOCKED' if any(s['verdict'] == 'BLOCKED' for s in stages) else 'PASS'
    (a.directory / 'live-verdict.json').write_text(json.dumps({'verdict': verdict, 'stages': stages}, indent=2) + '\n')
    (a.directory / 'live-summary.md').write_text('# Live YouTube validation\n\n**' + verdict + '**\n\n' + '\n'.join(str(s) for s in stages) + '\n')
    raise SystemExit(0 if verdict == 'PASS' else 78 if verdict == 'BLOCKED' else 1)
