"""Offline broker tests. Fake preferences and synthetic pipes only; no Bluetooth/root."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import socket
import struct
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('service', ROOT / 'scripts/apple-voice-service.py')
service = importlib.util.module_from_spec(spec); spec.loader.exec_module(service)

class Preferences:
    def __init__(self, value=None): self.value=value; self.reloads=0; self.fail=False
    def acquire(self): return os.open('/dev/null', os.O_RDONLY)
    def read(self): return self.value
    def write(self, value): self.value=value
    def reload(self):
        if self.fail: raise RuntimeError('reload-failed')
        self.reloads+=1

class ServiceTests(unittest.TestCase):
    def test_private_umask_does_not_block_client_directory_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp)/'socket-dir'
            previous=os.umask(0o077)
            try:
                service.prepare_socket_directory(directory,os.getuid())
            finally:
                os.umask(previous)
            self.assertEqual(directory.stat().st_mode & 0o777,0o755)
            directory.chmod(0o700)
            service.prepare_socket_directory(directory,os.getuid())
            self.assertEqual(directory.stat().st_mode & 0o777,0o755)

    def test_socket_directory_rejects_writable_symlink_and_wrong_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp)/'dir'; directory.mkdir(); directory.chmod(0o777)
            with self.assertRaises(RuntimeError):service.prepare_socket_directory(directory,os.getuid())
            self.assertEqual(directory.stat().st_mode & 0o777,0o777)
            directory.chmod(0o700)
            with self.assertRaises(RuntimeError):service.prepare_socket_directory(directory,os.getuid()+1)
            link=Path(temp)/'alias'; link.symlink_to(directory)
            with self.assertRaises(RuntimeError):service.prepare_socket_directory(link,os.getuid())

    def test_request_whitelist_and_bounds(self):
        for text, expected in [(b'WARM\n',True),(b'CAPTURE\n',False),(b'CAPTURE /tmp/x\n',None),(b'A'*100,None),(b'',None)]:
            a,b=socket.socketpair()
            with a,b:
                a.sendall(text); a.shutdown(socket.SHUT_WR)
                if expected is None:
                    with self.assertRaises(RuntimeError): service.request(b)
                else: self.assertEqual(service.request(b),expected)

    def test_frames_are_length_bounded(self):
        a,b=socket.socketpair()
        a.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,65536)
        with a,b:
            service.frame(a,2,b'x'*8192)
            data=b.recv(9000)
            self.assertEqual(data[:5], b'\x02'+struct.pack('>I',8192))
            self.assertEqual(len(data),8197)
            with self.assertRaises(RuntimeError): service.frame(a,2,b'x'*8193)

    def test_wrong_uid_and_nonconsole_denied_without_signature_execution(self):
        with patch.object(service,'peer',return_value=(502,123)), patch.object(service.subprocess,'run') as run:
            self.assertFalse(service.authenticate(None,{'uid':501})); run.assert_not_called()
        with patch.object(service,'peer',return_value=(501,123)), patch.object(service.os,'stat',return_value=types.SimpleNamespace(st_uid=502)), patch.object(service.subprocess,'run') as run:
            self.assertFalse(service.authenticate(None,{'uid':501})); run.assert_not_called()

    def test_signature_failure_denied(self):
        with patch.object(service,'peer',return_value=(501,123)), patch.object(service.os,'stat',return_value=types.SimpleNamespace(st_uid=501)), patch.object(service.subprocess,'run',return_value=types.SimpleNamespace(returncode=3)):
            self.assertFalse(service.authenticate(None,{'uid':501}))

    def test_journal_restores_absent_and_custom_on_next_start(self):
        for original in [None, {'custom':False}]:
            with tempfile.TemporaryDirectory() as temp:
                prefs=Preferences(original); path=Path(temp)/'state.plist'
                wrapper=service.RecoveryPreferences(prefs,path)
                with patch.object(service,'root_file',side_effect=lambda p:Path(p).read_bytes()):
                    wrapper.write(service.TRACE_FLAGS); wrapper.reload()
                    self.assertTrue(path.exists()); self.assertEqual(path.stat().st_mode & 0o777,0o600)
                    # Simulate service crash after mutation, before normal restoration.
                    recovered=service.RecoveryPreferences(prefs,path)
                    fd=recovered.acquire(); os.close(fd)
                    self.assertEqual(prefs.read(),original); self.assertFalse(path.exists())

    def test_failed_restore_preserves_journal_and_external_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            prefs=Preferences(); path=Path(temp)/'state.plist'; wrapper=service.RecoveryPreferences(prefs,path)
            with patch.object(service,'root_file',side_effect=lambda p:Path(p).read_bytes()):
                wrapper.write(service.TRACE_FLAGS)
                prefs.fail=True
                with self.assertRaises(RuntimeError): wrapper.acquire()
                self.assertTrue(path.exists())
                prefs.fail=False; prefs.value={'someone-else':True}
                with self.assertRaises(RuntimeError): wrapper.acquire()
                self.assertEqual(prefs.value,{'someone-else':True}); self.assertTrue(path.exists())

    def test_normal_restore_removes_journal_after_reload_only(self):
        with tempfile.TemporaryDirectory() as temp:
            prefs=Preferences(); path=Path(temp)/'state.plist'; wrapper=service.RecoveryPreferences(prefs,path)
            with patch.object(service,'root_file',side_effect=lambda p:Path(p).read_bytes()):
                wrapper.write(service.TRACE_FLAGS); wrapper.reload(); wrapper.write(None)
                self.assertTrue(path.exists()); wrapper.reload(); self.assertFalse(path.exists())

    def exercise_capture(self,warm):
        a,b=socket.socketpair(); frames=[]; finished=[]
        uid=os.stat('/dev/console').st_uid
        threads=[]
        def fake_spawn(module,seconds):
            self.assertEqual(seconds,10 if warm else 63)
            incoming,outgoing=os.pipe(); life_read,life_write=os.pipe(); sr,sw=os.pipe()
            def producer():
                os.write(outgoing,b'synthetic-selected-packet\n')
                os.read(life_read,1)  # The broker MUST close its lifeline.
                finished.append(True)
                for fd in [life_read,outgoing]: os.close(fd)
                os.write(sw,json.dumps({'debugSettingsRestored':True,'rawTraceRemoved':True}).encode()); os.close(sw)
            thread=threading.Thread(target=producer); thread.start(); threads.append(thread)
            return 999,incoming,life_write,sr
        def waitpid(pid,flags):
            threads[0].join(2); self.assertFalse(threads[0].is_alive()); return pid,0
        with a,b,patch.object(service,'spawn',side_effect=fake_spawn),patch.object(service.os,'waitpid',side_effect=waitpid):
            thread=threading.Thread(target=lambda:service.capture(b,None,uid,warm)); thread.start()
            a.settimeout(3); buf=b''
            while not frames or frames[-1][0]!=3:
                buf+=a.recv(4096)
                while len(buf)>=5:
                    n=struct.unpack('>I',buf[1:5])[0]
                    if len(buf)<5+n: break
                    frames.append((buf[0],buf[5:5+n])); buf=buf[5+n:]
                    if frames[-1][0]==2: a.shutdown(socket.SHUT_WR)
            thread.join(3); self.assertFalse(thread.is_alive())
        self.assertEqual(finished,[True]); result=json.loads(frames[-1][1])
        self.assertTrue(result['debugSettingsRestored'] and result['rawTraceRemoved'] and result['receivedData'])
        self.assertEqual([f[0] for f in frames],[3] if warm else [1,2,3])

    def test_warm_stops_on_first_data_and_restores(self): self.exercise_capture(True)
    def test_release_half_close_stops_and_returns_cleanup(self): self.exercise_capture(False)

if __name__=='__main__': unittest.main()
