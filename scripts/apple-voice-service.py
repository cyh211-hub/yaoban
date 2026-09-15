#!/usr/bin/python3
"""Installed, root-owned, authenticated on-demand capture broker. No HID or audio decode."""
import ctypes
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import selectors
import shutil
import signal
import socket
import stat
import struct
import subprocess
import time

SUPPORT = Path('/Library/Application Support/YaobanVoice')
SOCKET_DIR = Path('/var/run/yaoban-apple-voice')
SOCKET_PATH = SOCKET_DIR / 'control.sock'
PACKETLOGGER_BUNDLES = (
    Path('/Applications/PacketLogger.app'),
    SUPPORT / 'PacketLogger.app',  # retain compatibility with earlier private installs
)
PACKETLOGGER_BUNDLE = next((path for path in PACKETLOGGER_BUNDLES if path.is_dir()), PACKETLOGGER_BUNDLES[0])
PACKETLOGGER = PACKETLOGGER_BUNDLE / 'Contents/Resources/packetlogger'
AUTH = SUPPORT / 'YaobanPeerCheck'


def root_file(path, limit=4096):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022
                or info.st_nlink != 1 or info.st_size > limit):
            raise RuntimeError('unsafe-installed-file')
        return os.read(fd, limit + 1)
    finally:
        os.close(fd)


class RecoveryPreferences:
    """Durable pre-mutation recovery record survives service crash/reboot."""
    def __init__(self, delegate, journal=SUPPORT / 'trace-state.plist'):
        self.delegate = delegate
        self.journal = journal

    def read(self):
        return self.delegate.read()

    def original(self):
        data = plistlib.loads(root_file(self.journal))
        if type(data.get('keyWasPresent')) is not bool:
            raise RuntimeError('invalid-recovery-record')
        return data.get('value') if data['keyWasPresent'] else None

    def acquire(self):
        fd = self.delegate.acquire()
        try:
            if self.journal.exists():
                before = self.original()
                current = self.read()
                if current not in (before, TRACE_FLAGS):
                    raise RuntimeError('trace-settings-changed-externally')
                if current != before:
                    self.delegate.write(before)
                self.delegate.reload()
                self.journal.unlink()
            return fd
        except BaseException:
            os.close(fd)
            raise

    def write(self, value):
        if value == TRACE_FLAGS and not self.journal.exists():
            before = self.read()
            record = {'keyWasPresent': before is not None}
            if before is not None:
                record['value'] = before
            fd = os.open(self.journal, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(plistlib.dumps(record)); stream.flush(); os.fsync(stream.fileno())
        self.delegate.write(value)

    def reload(self):
        self.delegate.reload()
        if self.journal.exists() and self.read() == self.original():
            self.journal.unlink()


TRACE_FLAGS = {key: True for key in ('StackDebugEnabled', 'HCILiveTraces',
    'HCIFileTraces', 'RawAudioTrace', 'HIDTrace', 'HCISkipAuth')}


def peer(sock):
    uid, gid = ctypes.c_uint(), ctypes.c_uint()
    if ctypes.CDLL(None).getpeereid(sock.fileno(), ctypes.byref(uid), ctypes.byref(gid)):
        raise RuntimeError('peer-unavailable')
    # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=2.
    pid = sock.getsockopt(0, 2)
    return uid.value, pid


def authenticate(sock, config):
    uid, pid = peer(sock)
    if uid != config['uid'] or uid < 501 or pid <= 1:
        return False
    if os.stat('/dev/console').st_uid != uid:
        return False
    return subprocess.run([str(AUTH), str(pid)], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3).returncode == 0


def frame(sock, kind, payload=b''):
    if len(payload) > 8192:
        raise RuntimeError('oversized-frame')
    sock.sendall(bytes([kind]) + struct.pack('>I', len(payload)) + payload)


def request(sock):
    # An authenticated client can only request warm-up or bounded capture.
    data = bytearray()
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and len(data) < 16:
        part = sock.recv(1)
        if not part:
            raise RuntimeError('client-ended')
        data.extend(part)
        if part == b'\n':
            break
    if data not in (b'WARM\n', b'CAPTURE\n'):
        raise RuntimeError('invalid-request')
    return data == b'WARM\n'


def spawn(binary_module, seconds):
    incoming, outgoing = os.pipe()
    life_read, life_write = os.pipe()
    status_read, status_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        keep = {0, 1, 2, outgoing, life_read, status_write}
        for entry in os.listdir('/dev/fd'):
            try:
                fd = int(entry)
                if fd not in keep:
                    os.close(fd)
            except (ValueError, OSError):
                pass
        binary_module.watch_binary_capture([str(PACKETLOGGER), 'convert'], outgoing,
            life_read, status_write, seconds, RecoveryPreferences(binary_module.SystemTracePreferences()), addressed=True, service_marker=True)
        os._exit(0)
    for fd in (outgoing, life_read, status_write):
        os.close(fd)
    return pid, incoming, life_write, status_read


def capture(sock, binary_module, uid, warm):
    pid, incoming, life, status_fd = spawn(binary_module, 10 if warm else 63)
    received = False
    result = {}
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(incoming, selectors.EVENT_READ, 'data')
            selector.register(sock, selectors.EVENT_READ, 'client')
            deadline = time.monotonic() + (14 if warm else 67)
            while time.monotonic() < deadline:
                if os.stat('/dev/console').st_uid != uid:
                    break
                ended = False
                for key, _ in selector.select(.1):
                    if key.data == 'client':
                        # No further commands or arbitrary payloads are allowed.
                        sock.recv(1); ended = True; break
                    chunk = os.read(incoming, 4096)
                    if not chunk:
                        ended = True; break
                    if not received:
                        received = True
                        if warm:
                            ended = True; break
                        frame(sock, 1)
                    if not warm:
                        frame(sock, 2, chunk)
                if ended:
                    break
    finally:
        os.close(life)
        os.close(incoming)
        os.waitpid(pid, 0)  # independent guardian's deadline also covers parent death
        data = os.read(status_fd, 2048)
        os.close(status_fd)
        try:
            result = json.loads(data)
        except ValueError:
            result = {}
        safe = {key: result.get(key) is True for key in ('debugSettingsRestored', 'rawTraceRemoved')}
        safe['receivedData'] = received
        safe['warm'] = warm
        if not all(safe[key] for key in ('debugSettingsRestored', 'rawTraceRemoved')):
            # Only cleanup metadata is logged; never packet contents/identifiers.
            print(json.dumps({'cleanupFailure': True, 'recoveryRecord': result.get('recoveryRecord')}), flush=True)
        try:
            frame(sock, 3, json.dumps(safe).encode())
        except OSError:
            pass


def clean_abandoned_sessions(base=Path('/private/tmp')):
    # Caller holds the shared capture lock: no live session can be removed.
    # Only our root-private, explicitly marked directories qualify.
    for directory in base.glob('yaoban-voice-pklg-*'):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            continue
        try:
            if root_file(directory / 'service-session', 64) != b'YaobanVoice1':
                continue
        except (OSError, RuntimeError):
            continue
        names = {entry.name for entry in directory.iterdir()}
        if not names.issubset({'service-session', 'capture.txt', 'trace-before.plist'}):
            continue
        shutil.rmtree(directory)


def prepare_socket_directory(directory, owner=0):
    directory.mkdir(mode=0o755, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner or info.st_mode & 0o022:
        raise RuntimeError('unsafe-socket-directory')
    # The service's private-file umask is 077: mkdir(0755) alone becomes 0700.
    # Only the directory is traversable; the socket remains 0600 for the console
    # user, and every connection must additionally pass code identity checks.
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        pinned = os.fstat(fd)
        if (pinned.st_dev, pinned.st_ino) != (info.st_dev, info.st_ino):
            raise RuntimeError('socket-directory-replaced')
        os.fchmod(fd, 0o755)
    finally:
        os.close(fd)


def run():
    if os.geteuid() != 0:
        raise RuntimeError('administrator-required')
    os.umask(0o077)
    config = json.loads(root_file(SUPPORT / 'client.json'))
    if type(config.get('uid')) is not int or config['uid'] < 501:
        raise RuntimeError('invalid-user')
    root_file(SUPPORT / 'apple_voice_binary.py', 65536)
    spec = importlib.util.spec_from_file_location('capture_binary', SUPPORT / 'apple_voice_binary.py')
    binary = importlib.util.module_from_spec(spec); spec.loader.exec_module(binary)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=anchor apple',
                    str(PACKETLOGGER_BUNDLE)], check=True, timeout=10,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    recovery = RecoveryPreferences(binary.SystemTracePreferences())
    recovered_fd = recovery.acquire()
    try:
        clean_abandoned_sessions()
    finally:
        os.close(recovered_fd)
    prepare_socket_directory(SOCKET_DIR)
    try:
        info = SOCKET_PATH.lstat()
        if not stat.S_ISSOCK(info.st_mode):
            raise RuntimeError('unsafe-socket')
        SOCKET_PATH.unlink()
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(SOCKET_PATH))
        os.chown(SOCKET_PATH, config['uid'], -1)
        os.chmod(SOCKET_PATH, 0o600)
        listener.listen(2); listener.settimeout(.5)
        last_warm = -60.0
        while True:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            with client:
                client.settimeout(.5)
                try:
                    if not authenticate(client, config):
                        continue
                    warm = request(client)
                    if warm and time.monotonic() - last_warm < 15:
                        frame(client, 4, b'warm-rate-limited'); continue
                    if warm:
                        last_warm = time.monotonic()
                    capture(client, binary, config['uid'], warm)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                    try:
                        frame(client, 4, b'capture-unavailable')
                    except OSError:
                        pass
    finally:
        listener.close()
        SOCKET_PATH.unlink(missing_ok=True)


if __name__ == '__main__':
    def cancel(_sig, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    run()
