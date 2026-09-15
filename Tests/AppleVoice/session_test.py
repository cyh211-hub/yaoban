#!/usr/bin/python3
"""Offline launcher tests. No real sudo, Bluetooth, microphone or user settings."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import types
import unittest
from unittest import mock
import uuid

SOURCE = Path(__file__).resolve().parents[2] / 'scripts/apple-voice-session.py'
SPEC = importlib.util.spec_from_file_location('voice_session', SOURCE)
session = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(session)


class FakeChild:
    instances = []

    def __init__(self, command):
        self.command = command
        self.stdout = bytearray(b'{}')
        self.stderr = bytearray()
        self.streams = {}
        self.code = None
        self.stopped = self.closed = False
        self.process = types.SimpleNamespace(poll=lambda: self.code, returncode=0)
        self.instances.append(self)

    def running(self):
        return self.code is None

    def stop(self):
        self.stopped = True
        self.code = 0

    def close(self):
        self.closed = True


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.outputs = self.root / '.build/apple-voice-capture'
        self.outputs.mkdir(parents=True)
        self.output = self.outputs / str(uuid.uuid4())
        self.output.mkdir(mode=0o700)
        self.pointer = self.root / '.build/apple-voice-lab/current-manual-session.json'
        self.patch = mock.patch.multiple(session, OUTPUTS=self.outputs, POINTER=self.pointer)
        self.patch.start()
        FakeChild.instances = []

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def write_armed(self, content=None, mode=0o600):
        path = self.output / 'armed.json'
        path.write_text(json.dumps(session.ARMED if content is None else content))
        path.chmod(mode)

    def test_private_session_and_start_are_exclusive(self):
        with session.session_directory(self.output) as directory:
            session.signal_start(directory)
            with self.assertRaises(FileExistsError):
                session.signal_start(directory)
        info = (self.output / 'start.signal').stat()
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_size, 0)

    def test_session_rejects_path_or_mode_or_owner(self):
        for path in [self.outputs / 'not-a-uuid', self.root / str(uuid.uuid4())]:
            with self.assertRaises(session.SessionError), session.session_directory(path):
                pass
        self.output.chmod(0o755)
        with self.assertRaises(session.SessionError), session.session_directory(self.output):
            pass
        self.output.chmod(0o700)
        with mock.patch.object(session.os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaises(session.SessionError), session.session_directory(self.output):
                pass

    def test_session_rejects_symlink(self):
        link = self.outputs / str(uuid.uuid4())
        link.symlink_to(self.output, target_is_directory=True)
        with self.assertRaises(session.SessionError), session.session_directory(link):
            pass

    def test_ready_marker_strict(self):
        with session.session_directory(self.output) as directory:
            self.assertFalse(session.armed(directory))
            self.write_armed()
            self.assertTrue(session.armed(directory))
            self.write_armed(mode=0o644)
            with self.assertRaises(session.SessionError):
                session.armed(directory)
            self.write_armed({'status': 'ready', 'capturing': True, 'seconds': 20})
            with self.assertRaises(session.SessionError):
                session.armed(directory)

    def test_ready_fifo_symlink_and_oversized_rejected(self):
        marker = self.output / 'armed.json'
        with session.session_directory(self.output) as directory:
            os.mkfifo(marker, 0o600)
            with self.assertRaises(session.SessionError):
                session.armed(directory)
            marker.unlink()
            target = self.root / 'other.json'
            target.write_text('{}')
            marker.symlink_to(target)
            with self.assertRaises(OSError):
                session.armed(directory)
            marker.unlink()
            marker.write_bytes(b'x' * 513)
            marker.chmod(0o600)
            with self.assertRaises(session.SessionError):
                session.armed(directory)

    def test_pinned_directory_survives_rename(self):
        original = self.output
        with session.session_directory(original) as directory:
            moved = self.outputs / str(uuid.uuid4())
            original.rename(moved)
            original.mkdir(mode=0o700)
            session.signal_start(directory)
            self.assertTrue((moved / 'start.signal').exists())
            self.assertFalse((original / 'start.signal').exists())

    def test_pointer_private_atomic_and_no_extra_fields(self):
        session.pointer(self.output, 'arming', 'running')
        first = self.pointer.stat().st_ino
        session.pointer(self.output, 'finished', 'completed')
        self.assertNotEqual(first, self.pointer.stat().st_ino)
        self.assertEqual(stat.S_IMODE(self.pointer.stat().st_mode), 0o600)
        value = json.loads(self.pointer.read_text())
        self.assertEqual(set(value), {'output', 'phase', 'status', 'updatedAt'})
        self.assertEqual(value['status'], 'completed')

    def test_pointer_does_not_follow_symlink(self):
        self.pointer.parent.mkdir(parents=True)
        target = self.root / 'target'
        target.write_text('preserve')
        self.pointer.symlink_to(target)
        with self.assertRaises(session.SessionError):
            session.pointer(self.output, 'arming', 'running')
        self.assertEqual(target.read_text(), 'preserve')

    def test_result_filters_identifiers_and_payload(self):
        child = FakeChild([])
        child.code = 0
        child.stdout = bytearray(json.dumps({'reports': 3, 'samples': 2880, 'seconds': 0.06,
            'address': 'AB:CD:EF:12:34:56', 'pcm': 'secret', 'rawTraceSaved': False,
            'diagnostics': {'input': {'bytesRead': 300, 'raw': 'secret'},
                            'transport': {'selectedDeviceLines': 3, 'dynamicHandleReports': 2,
                                          'voiceHandleChanges': 1, 'unboundEndReports': 1,
                                          'address': 'secret', 'attributeHandle': 'secret'},
                            'timing': {'timestampPastSamples': 3, 'timestampPastMaxMilliseconds': 4000,
                                       'rawTimestamp': 'secret'},
                            'wire': {'inspectedSelectedPackets': 3, 'completeVoiceCandidates': 1,
                                     'fragmentedVoiceCandidates': 1, 'aclContinuationCandidates': 1,
                                     'voiceCandidatesOutsideATTLabel': 1, 'validHexPackets': 3,
                                     'packetType': 'secret', 'attributeHandle': 'secret', 'raw': 'secret'}}}).encode())
        child.stderr = bytearray(b'private-name AB:CD:EF:12:34:56 secret')
        saved = session.result(child, 'listen')
        encoded = json.dumps(saved)
        self.assertNotIn('secret', encoded)
        self.assertNotIn('AB:CD', encoded)
        self.assertEqual(saved['reports'], 3)
        self.assertEqual(saved['diagnostics']['transport'],
                         {'selectedDeviceLines': 3, 'dynamicHandleReports': 2,
                          'voiceHandleChanges': 1, 'unboundEndReports': 1})
        self.assertEqual(saved['diagnostics']['timing'],
                         {'timestampPastSamples': 3, 'timestampPastMaxMilliseconds': 4000})
        self.assertEqual(saved['diagnostics']['wire'],
                         {'inspectedSelectedPackets': 3, 'completeVoiceCandidates': 1,
                          'fragmentedVoiceCandidates': 1, 'aclContinuationCandidates': 1,
                          'voiceCandidatesOutsideATTLabel': 1, 'validHexPackets': 3})
        self.assertEqual(saved['diagnostic'], 'tool-diagnostic')
        child.stdout = bytearray(b'{"capture":{"stopped":"deadline","exit":0,"diagnostic":"none","raw":"secret"},"debugSettingsChanged":false}')
        self.assertNotIn('secret', json.dumps(session.result(child, 'capture')))
        child.stdout = bytearray(b'{"capture":{"stopped":[],"diagnostic":{}},"stopped":{}}')
        self.assertEqual(session.result(child, 'capture')['capture'], {})
        self.assertNotIn('stopped', session.result(child, 'listen'))

    def test_binary_ready_and_missing_identity(self):
        child = FakeChild([])
        with session.session_directory(self.output) as directory:
            with self.assertRaisesRegex(session.SessionError, 'connection-metadata-missing'):
                session.wait_binary_ready(directory, [child], 0)
            marker = self.output / 'binary-stream-ready.json'
            marker.write_text('{"status":"selected-device-ready"}')
            marker.chmod(0o600)
            session.wait_binary_ready(directory, [child], .1)
            marker.chmod(0o644)
            with self.assertRaisesRegex(session.SessionError, 'invalid-binary-ready-marker'):
                session.wait_binary_ready(directory, [child], .1)

    def test_binary_diagnostics_and_restore_filter(self):
        child = FakeChild([])
        child.code = 0
        child.stdout = bytearray(json.dumps({'diagnostics': {'packetLog': {
            'records': 10, 'selectedConnections': 1, 'reports': 2, 'address': 'secret', 'payload': 'secret'}},
            'stopped': 'invalid-packet-log'}).encode())
        saved = session.result(child, 'listen')
        self.assertEqual(saved['diagnostics']['packetLog'], {'records': 10, 'selectedConnections': 1, 'reports': 2})
        self.assertNotIn('secret', json.dumps(saved))
        child.stdout = bytearray(json.dumps({'capture': {'stopped': 'cleanup-incomplete'},
            'debugSettingsChanged': True, 'debugSettingsRestored': False, 'rawTraceRemoved': True}).encode())
        saved = session.result(child, 'capture')
        self.assertFalse(saved['debugSettingsRestored'])
        self.assertTrue(saved['rawTraceRemoved'])
        self.assertEqual(saved['capture']['stopped'], 'cleanup-incomplete')

    def test_activation_is_bounded_and_result_is_not_audio_confirmation(self):
        completed = types.SimpleNamespace(returncode=0, stdout=json.dumps({
            'status': 'submitted-audio-unverified', 'acceptedSubmissions': 2, 'address': 'secret'}).encode())
        with session.session_directory(self.output) as directory, mock.patch.object(session.subprocess, 'run', return_value=completed) as run:
            session.activate_once(directory)
            self.assertEqual(run.call_args.kwargs['timeout'], 7)
            self.assertNotIn('/usr/bin/sudo', run.call_args.args[0])
        value = json.loads((self.output / 'activation-result.json').read_text())
        self.assertEqual(value['acceptedSubmissions'], 2)
        self.assertFalse(value['remoteAudioConfirmed'])
        self.assertNotIn('secret', json.dumps(value))

    def test_summary_survives_wrapper_cancel_without_claiming_success(self):
        child = FakeChild([])
        child.code = 130
        with session.session_directory(self.output) as directory:
            session.write_json(directory, 'summary.json', {'reports': 0, 'samples': 0,
                'diagnostics': {'addressed': {'selectedPackets': 4, 'address': 'secret'}}})
            session.recover_listener_summary(directory, child)
        saved = session.result(child, 'listen')
        self.assertEqual(saved['status'], 'failed')
        self.assertEqual(saved['exit'], 130)
        self.assertEqual(saved['diagnostics']['addressed'], {'selectedPackets': 4})
        self.assertNotIn('secret', json.dumps(saved))

    @contextlib.contextmanager
    def fake_run(self, enter=None, complete=None, ready=None, auth_code=0):
        tty = types.SimpleNamespace(isatty=lambda: True)
        with contextlib.ExitStack() as stack:
            for name, value in [('Child', FakeChild), ('prepare', lambda *_args: self.output),
                                ('announce', lambda _text: None), ('pump', lambda *_args: None),
                                ('wait_armed', ready or (lambda *_args: self.write_armed())),
                                ('wait_enter', enter or (lambda *_args: None)),
                                ('wait_finished', complete or (lambda *_args: None))]:
                stack.enter_context(mock.patch.object(session, name, value))
            stack.enter_context(mock.patch.object(session.sys, 'stdin', tty))
            stack.enter_context(mock.patch.object(session.sys, 'stdout', tty))
            auth = stack.enter_context(mock.patch.object(session.subprocess, 'run',
                                return_value=types.SimpleNamespace(returncode=auth_code)))
            yield auth

    def test_complete_session_auth_commands_and_results(self):
        with self.fake_run() as auth:
            session.run()
            auth.assert_called_once_with(['/usr/bin/sudo', '-v'], check=False)
        self.assertTrue((self.output / 'start.signal').exists())
        self.assertEqual(len(FakeChild.instances), 2)
        listener, capture = FakeChild.instances
        self.assertIn('--listen', listener.command)
        self.assertEqual(capture.command[:4], ['/usr/bin/sudo', '-n', '/usr/bin/python3', '-I'])
        self.assertNotIn('--activate-once', capture.command)
        self.assertTrue(all(c.stopped and c.closed for c in FakeChild.instances))
        for name in ['capture-result.json', 'listen-result.json']:
            self.assertEqual(stat.S_IMODE((self.output / name).stat().st_mode), 0o600)
        self.assertEqual(json.loads(self.pointer.read_text())['status'], 'completed')

    def test_binary_session_forwards_mode_and_waits_for_identity(self):
        def complete(*_args):
            FakeChild.instances[1].stdout = bytearray(b'{"debugSettingsRestored":true,"rawTraceRemoved":true}')
        with self.fake_run(complete=complete), mock.patch.object(session, 'activate_once') as activate, mock.patch.object(session, 'wait_binary_ready') as ready:
            session.run(True)
            activate.assert_called_once()
            ready.assert_called_once()
        self.assertTrue(all('--binary' in child.command for child in FakeChild.instances))
        self.assertEqual(json.loads(self.pointer.read_text())['status'], 'completed')

    def test_addressed_mode_preserves_identity_ready_gate(self):
        def complete(*_args):
            FakeChild.instances[1].stdout = bytearray(b'{"debugSettingsRestored":true,"rawTraceRemoved":true}')
        with self.fake_run(complete=complete), mock.patch.object(session, 'activate_once'), mock.patch.object(session, 'wait_binary_ready') as ready:
            session.run(addressed=True)
            ready.assert_called_once()
        self.assertTrue(all('--addressed' in child.command for child in FakeChild.instances))
        self.assertTrue(all('--binary' not in child.command for child in FakeChild.instances))

    def test_cleanup_failure_is_not_reported_as_completed(self):
        def fail_stop(child):
            child.stopped = True
            raise session.subprocess.TimeoutExpired('synthetic-child', 1)
        with self.fake_run(), mock.patch.object(FakeChild, 'stop', fail_stop):
            with self.assertRaisesRegex(session.SessionError, 'cleanup-incomplete'):
                session.run()
        self.assertEqual(json.loads(self.pointer.read_text())['phase'], 'cleanup-incomplete')
        self.assertTrue(all(c.closed for c in FakeChild.instances))

    def test_cleanup_failure_takes_priority_over_cancel(self):
        def cancel(*_args):
            raise KeyboardInterrupt()
        def fail_stop(child):
            child.stopped = True
            raise session.subprocess.TimeoutExpired('synthetic-child', 1)
        with self.fake_run(enter=cancel), mock.patch.object(FakeChild, 'stop', fail_stop):
            with self.assertRaisesRegex(session.SessionError, 'cleanup-incomplete'):
                session.run()
        self.assertFalse((self.output / 'start.signal').exists())
        self.assertEqual(json.loads(self.pointer.read_text())['status'], 'failed')
        self.assertTrue(all(c.closed for c in FakeChild.instances))

    def test_cancel_or_eof_or_timeout_never_starts(self):
        for error in [KeyboardInterrupt(), session.SessionError('input-ended'),
                      session.SessionError('start-timeout')]:
            with self.subTest(error=type(error).__name__):
                for name in ['capture-result.json', 'listen-result.json', 'armed.json']:
                    with contextlib.suppress(FileNotFoundError):
                        (self.output / name).unlink()
                FakeChild.instances = []
                def cancel(*_args):
                    raise error
                with self.fake_run(enter=cancel):
                    with self.assertRaises(type(error)):
                        session.run()
                self.assertFalse((self.output / 'start.signal').exists())
                self.assertTrue(all(c.stopped and c.closed for c in FakeChild.instances))

    def test_auth_failure_never_prepares_or_spawns(self):
        with self.fake_run(auth_code=1):
            with mock.patch.object(session, 'prepare') as prepare:
                with self.assertRaises(session.SessionError):
                    session.run()
                prepare.assert_not_called()
        self.assertEqual(FakeChild.instances, [])

    def test_child_exit_prevents_start_even_after_enter(self):
        def end_before_enter(*_args):
            FakeChild.instances[0].code = 2
        with self.fake_run(enter=end_before_enter):
            with self.assertRaises(session.SessionError):
                session.run()
        self.assertFalse((self.output / 'start.signal').exists())

    def test_wait_enter_eof_and_timeout(self):
        child = FakeChild([])
        stdin = types.SimpleNamespace(fileno=lambda: 9)
        with mock.patch.object(session.sys, 'stdin', stdin), mock.patch.object(session, 'pump', return_value=b''):
            with self.assertRaisesRegex(session.SessionError, 'input-ended'):
                session.wait_enter([child])
        with self.assertRaisesRegex(session.SessionError, 'start-timeout'):
            session.wait_enter([child], 0)

    def test_wait_armed_checks_liveness_and_deadline(self):
        child = FakeChild([])
        with session.session_directory(self.output) as directory:
            with self.assertRaisesRegex(session.SessionError, 'ready-timeout'):
                session.wait_armed(directory, [child], 0)
            child.code = 2
            with mock.patch.object(session, 'pump', return_value=None):
                with self.assertRaisesRegex(session.SessionError, 'child-ended-before-start'):
                    session.wait_armed(directory, [child])


if __name__ == '__main__':
    unittest.main()
