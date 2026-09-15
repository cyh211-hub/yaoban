"""Offline binary guardian checks. Synthetic producer; never access Bluetooth/preferences."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import select
import plistlib
import resource
import shutil
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capture', ROOT / 'scripts/apple-voice-capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
binary = capture.BINARY_CAPTURE


class MemoryPreferences:
    def __init__(self, before=None):
        self.value = copy.deepcopy(before)
        self.reloads = 0
        self.writes = []
        self.fail_after_write = False

    def read(self):
        return copy.deepcopy(self.value)

    def write(self, value):
        self.value = copy.deepcopy(value)
        self.writes.append(copy.deepcopy(value))
        if self.fail_after_write:
            self.fail_after_write = False
            raise RuntimeError('synthetic-command-failed-after-mutation')

    def reload(self):
        self.reloads += 1


class FilePreferences:
    def __init__(self, path):
        self.path = path

    def read(self):
        return json.loads(self.path.read_text())

    def write(self, value):
        self.path.write_text(json.dumps(value))

    def reload(self):
        pass


class BinaryTests(unittest.TestCase):
    def test_concurrent_capture_cannot_change_another_session_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'capture.lock'
            first = binary.acquire_capture_lock(path, os.getuid())
            try:
                with self.assertRaises(BlockingIOError):
                    binary.acquire_capture_lock(path, os.getuid())
            finally:
                os.close(first)
            again = binary.acquire_capture_lock(path, os.getuid())
            os.close(again)
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                binary.acquire_capture_lock(path, os.getuid())

    def test_restore_absent_and_existing_exactly(self):
        for old in [None, {'custom': False, 'nested': {'preserve': [1, 'yes']}}, binary.TRACE_FLAGS]:
            prefs = MemoryPreferences(old)
            tx = binary.TraceTransaction(prefs)
            tx.enable()
            self.assertEqual(prefs.read(), binary.TRACE_FLAGS)
            tx.restore()
            self.assertEqual(prefs.read(), old)
            self.assertTrue(tx.restored)
            self.assertEqual(prefs.reloads, 0 if old == binary.TRACE_FLAGS else 2)

    def test_mutation_then_error_still_restores(self):
        prefs = MemoryPreferences({'old': True})
        prefs.fail_after_write = True
        tx = binary.TraceTransaction(prefs)
        with self.assertRaises(RuntimeError):
            tx.enable()
        tx.restore()
        self.assertTrue(tx.changed and tx.restored)
        self.assertEqual(prefs.read(), {'old': True})

    def test_external_change_not_overwritten(self):
        prefs = MemoryPreferences()
        tx = binary.TraceTransaction(prefs)
        tx.enable()
        prefs.value = {'someone-else': 1}
        with self.assertRaises(RuntimeError):
            tx.restore()
        self.assertFalse(tx.restored)
        self.assertEqual(prefs.read(), {'someone-else': 1})

    def capture(self, code, seconds=1, end_parent=False, addressed=False):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp) / 'preferences.json'
            state.write_text('{"keep":false}')
            command = ['/usr/bin/python3', '-I', '-c', code]
            started = time.monotonic()
            pid, data, life, status = capture.spawn_guardian(command, seconds, True, FilePreferences(state), addressed)
            result_data = bytearray()
            closed = False
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([data], [], [], .1)[0]:
                        part = os.read(data, 65536)
                        if not part:
                            break
                        result_data.extend(part)
                        if end_parent and not closed:
                            os.close(life); closed = True
                else:
                    self.fail('guardian did not stop in bounded time')
                os.waitpid(pid, 0)
                result = json.loads(os.read(status, 2048))
                self.assertTrue(result['rawTraceRemoved'], result)
                self.assertTrue(result['debugSettingsRestored'], result)
                self.assertTrue(result['debugSettingsChanged'], result)
                self.assertEqual(json.loads(state.read_text()), {'keep': False})
                self.assertLess(time.monotonic() - started, 5)
                return bytes(result_data), result
            finally:
                for fd in [data, status] + ([] if closed else [life]):
                    os.close(fd)

    def test_stream_and_final_drain(self):
        payload, result = self.capture('import os,sys; f=open(sys.argv[-1],"wb"); f.write(b"a"*16000); f.close()')
        self.assertEqual(payload, b'a' * 16000)
        self.assertEqual(result['stopped'], 'tool-exited')

    def test_addressed_capture_stdout_is_regular_file_and_complete(self):
        payload, result = self.capture('import os,stat,sys; assert stat.S_ISREG(os.fstat(1).st_mode); assert sys.argv[-3:]==["-s","-f","itpahdr"]; sys.stdout.write("a"*30000); sys.stdout.flush()', addressed=True)
        self.assertEqual(payload, b'a' * 30000)
        self.assertEqual(result['stopped'], 'tool-exited')

    def test_addressed_parent_end_removes_text_and_restores(self):
        payload, result = self.capture('import os,time; print(os.getpid(),flush=True); time.sleep(60)', 20, True, True)
        self.assertEqual(result['stopped'], 'parent-ended')
        with self.assertRaises(ProcessLookupError):
            os.kill(int(payload), 0)

    def test_deadline_stops_child(self):
        payload, result = self.capture('import os,sys,time; f=open(sys.argv[-1],"wb",buffering=0); f.write(str(os.getpid()).encode()); time.sleep(60)', .2)
        self.assertEqual(result['stopped'], 'deadline')
        with self.assertRaises(ProcessLookupError):
            os.kill(int(payload), 0)

    def test_parent_eof_restores(self):
        payload, result = self.capture('import os,sys,time; f=open(sys.argv[-1],"wb",buffering=0); f.write(str(os.getpid()).encode()); time.sleep(60)', 20, True)
        self.assertEqual(result['stopped'], 'parent-ended')
        with self.assertRaises(ProcessLookupError):
            os.kill(int(payload), 0)

    def test_bad_file_fails_and_restores(self):
        for statement in ['os.symlink("/dev/null",sys.argv[-1])',
                          'f=open(sys.argv[-1],"wb"); f.close(); os.chmod(sys.argv[-1],0o644)']:
            payload, result = self.capture('import os,sys,time; ' + statement + '; time.sleep(1)')
            self.assertEqual(payload, b'')
            self.assertEqual(result['stopped'], 'watchdog-error')

    def test_file_cap_applies_to_child_only(self):
        before = resource.getrlimit(resource.RLIMIT_FSIZE)
        payload, result = self.capture('import sys,resource,json; open(sys.argv[-1],"w").write(json.dumps(resource.getrlimit(resource.RLIMIT_FSIZE)))')
        self.assertEqual(json.loads(payload), [8 * 1024 * 1024] * 2)
        self.assertEqual(resource.getrlimit(resource.RLIMIT_FSIZE), before)

    def test_restore_failure_preserves_only_recovery_record(self):
        class FailRestore(MemoryPreferences):
            def write(self, value):
                if value is None:
                    raise RuntimeError('synthetic-restore-failure')
                super().write(value)
        output_r, output_w = os.pipe()
        life_r, life_w = os.pipe()
        status_r, status_w = os.pipe()
        recovery = None
        try:
            binary.watch_binary_capture(['/usr/bin/python3', '-I', '-c',
                'import sys; open(sys.argv[-1],"wb").write(b"test")'],
                output_w, life_r, status_w, 1, FailRestore())
            self.assertEqual(os.read(output_r, 100), b'test')
            result = json.loads(os.read(status_r, 2048))
            self.assertEqual(result['stopped'], 'cleanup-incomplete')
            self.assertFalse(result['debugSettingsRestored'])
            self.assertTrue(result['rawTraceRemoved'])
            recovery = Path(result['recoveryRecord'])
            self.assertEqual(plistlib.loads(recovery.read_bytes()), {'keyWasPresent': False})
            self.assertEqual(set(p.name for p in recovery.parent.iterdir()), {'trace-before.plist'})
        finally:
            for fd in [output_r, life_w, status_r]:
                os.close(fd)
            if recovery is not None:
                shutil.rmtree(recovery.parent)

    def test_capture_format_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = os.open(temp, os.O_RDONLY | os.O_DIRECTORY)
            try:
                capture.check_format(directory, os.getuid(), False)
                with self.assertRaises(RuntimeError):
                    capture.check_format(directory, os.getuid(), True)
                marker = Path(temp) / 'capture-format.json'
                marker.write_text('{"format":"pklg"}'); marker.chmod(0o600)
                capture.check_format(directory, os.getuid(), True)
                with self.assertRaises(RuntimeError):
                    capture.check_format(directory, os.getuid(), False)
            finally:
                os.close(directory)


if __name__ == '__main__':
    unittest.main()
