#!/usr/bin/python3
"""Normal-user, five-second Apple auxiliary-interface probe.

Inspection is the default and never sends a report. --activate-once changes only
the selected remote's declared auxiliary Feature 0xFF with one [AF] per interface.
It does not establish that the remote accepted it or that audio can be captured.
No system preferences, services, TCC grants, or production-app files are changed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / '.build/apple-voice-lab/voice-check'


def probe(activate=False):
    if os.getuid() == 0 or os.geteuid() == 0:
        raise RuntimeError('Run in the normal login session')
    process = subprocess.Popen([str(HELPER), '--activate-mic-once' if activate else '--inspect-mic-activation'],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        return {'status': 'probe-timeout', 'remoteAudioConfirmed': False}
    if process.returncode or len(stdout) > 4096:
        # Only expose our fixed diagnostic vocabulary, never arbitrary driver
        # output, remote identifiers, serial numbers or Bluetooth payloads.
        reasons = ('unavailable', 'libraryUnavailable', 'selectedUnavailable',
                   'registryUnavailable', 'connectionUnavailable', 'initializationFailed')
        reason = next((item for item in reasons if stderr == ('voice-check: '+item+'\n').encode()), 'unavailable')
        return {'status': 'probe-unavailable', 'exit': process.returncode,
                'reason': reason, 'remoteAudioConfirmed': False}
    return json.loads(stdout)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate-once', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(probe(args.activate_once), sort_keys=True))
    except (OSError, ValueError, RuntimeError) as error:
        print(json.dumps({'status': 'probe-failed', 'category': type(error).__name__,
                          'remoteAudioConfirmed': False}), file=sys.stderr)
        sys.exit(2)
