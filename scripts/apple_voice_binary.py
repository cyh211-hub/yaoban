"""Private, bounded PacketLogger file capture. No services or audio devices installed."""
import contextlib
import copy
import fcntl
import json
import os
from pathlib import Path
import plistlib
import resource
import signal
import shutil
import selectors
import stat
import subprocess
import tempfile
import time

TRACE_FLAGS = {key: True for key in ('StackDebugEnabled', 'HCILiveTraces',
    'HCIFileTraces', 'RawAudioTrace', 'HIDTrace', 'HCISkipAuth')}


def acquire_capture_lock(path, owner):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise RuntimeError('unsafe-capture-lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BaseException:
        os.close(fd)
        raise


class SystemTracePreferences:
    path = Path('/Library/Preferences/com.apple.MobileBluetooth.debug.plist')
    domain = '/Library/Preferences/com.apple.MobileBluetooth.debug'

    def acquire(self):
        return acquire_capture_lock('/private/tmp/yaoban-apple-voice-capture.lock', 0)

    def read(self):
        try:
            info = self.path.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0:
            raise RuntimeError('unsafe-trace-preferences')
        return plistlib.loads(self.path.read_bytes()).get('HCITraces')

    def write(self, value):
        if os.geteuid() != 0:
            raise RuntimeError('administrator-required')
        if value is None:
            command = ['/usr/bin/defaults', 'delete', self.domain, 'HCITraces']
        elif value == TRACE_FLAGS:
            command = ['/usr/bin/defaults', 'write', self.domain, 'HCITraces', '-dict']
            for key in TRACE_FLAGS:
                command += [key, '-bool', 'true']
        else:
            command = ['/usr/bin/plutil', '-replace', 'HCITraces', '-xml',
                       plistlib.dumps(value).decode(), str(self.path)]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=3)

    def reload(self):
        subprocess.run(['/usr/bin/killall', '-30', 'bluetoothd'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)


class TraceTransaction:
    def __init__(self, preferences):
        self.preferences = preferences
        self.before = copy.deepcopy(preferences.read())
        self.changed = False
        self.restored = False

    def enable(self):
        if self.before != TRACE_FLAGS:
            # Arm restoration before invoking a command which might mutate and
            # then fail. The guardian owns this transaction, not its parent.
            self.changed = True
            self.preferences.write(TRACE_FLAGS)
            if self.preferences.read() != TRACE_FLAGS:
                raise RuntimeError('trace-enable-not-confirmed')
            self.preferences.reload()

    def restore(self):
        current = self.preferences.read()
        if current == self.before:
            self.restored = True
            return
        if current != TRACE_FLAGS:
            raise RuntimeError('trace-preferences-changed-externally')
        self.preferences.write(self.before)
        if self.preferences.read() != self.before:
            raise RuntimeError('trace-restore-not-confirmed')
        self.preferences.reload()
        self.restored = True


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)


def watch_binary_capture(command, output_fd, life_fd, status_fd, seconds,
                         preferences=None, addressed=False, service_marker=False):
    """Tests pass synthetic commands/preferences; live caller pins Apple binary.

    PacketLogger writes a regular root-private file so FIFO backpressure cannot
    silently discard HCI. A slow consumer ends this bounded test. The owning
    guardian stops capture, removes the file and restores settings on parent EOF.
    """
    process = None
    transaction = None
    lock_fd = None
    raw_fd = None
    file_sink = None
    result = {'stopped': 'watchdog-error', 'diagnostic': 'none',
              'rawTraceRemoved': False, 'debugSettingsChanged': False,
              'debugSettingsRestored': preferences is None}
    old_mask = os.umask(0o077)
    directory = None
    selector = None
    raw_name = 'capture.txt' if addressed else 'capture.pklg'
    try:
        directory = Path(tempfile.mkdtemp(prefix='yaoban-voice-pklg-', dir='/private/tmp'))
        if service_marker:
            marker_fd = os.open(directory / 'service-session', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(marker_fd, 'wb') as marker:
                marker.write(b'YaobanVoice1')
        raw_path = directory / raw_name
        if preferences is not None:
            if hasattr(preferences, "acquire"):
                lock_fd = preferences.acquire()
            transaction = TraceTransaction(preferences)
            # Keep only restoration metadata if cleanup fails or power is lost.
            # This is separate from the raw capture and root-private in live use.
            snapshot = {'keyWasPresent': transaction.before is not None}
            if transaction.before is not None:
                snapshot['value'] = transaction.before
            fd = os.open(directory / 'trace-before.plist', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as journal:
                journal.write(plistlib.dumps(snapshot))
                journal.flush(); os.fsync(journal.fileno())
            transaction.enable()
        environment = os.environ.copy()
        environment['TZ'] = 'UTC'
        def limit_child():
            resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024 * 1024, 8 * 1024 * 1024))
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
        if addressed:
            file_sink = os.open(raw_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        options = ['-s', '-f', 'itpahdr'] if addressed else ['-o', str(raw_path)]
        process = subprocess.Popen(command + options,
            stdin=subprocess.DEVNULL, stdout=file_sink if addressed else subprocess.DEVNULL,
            stderr=subprocess.PIPE, env=environment, close_fds=True, preexec_fn=limit_child)
        if file_sink is not None:
            os.close(file_sink); file_sink = None
        os.set_blocking(output_fd, False)
        selector = selectors.DefaultSelector()
        selector.register(life_fd, selectors.EVENT_READ, 'parent')
        selector.register(process.stderr, selectors.EVENT_READ, 'error')
        diagnostic = bytearray()
        deadline = time.monotonic() + seconds
        position = 0
        def forward():
            nonlocal raw_fd, position
            try:
                info = raw_path.lstat()
            except FileNotFoundError:
                info = None
            if info is not None:
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
                        or info.st_size > 8 * 1024 * 1024):
                    raise RuntimeError('unsafe-or-oversized-capture-file')
                if raw_fd is None:
                    raw_fd = os.open(raw_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                pinned = os.fstat(raw_fd)
                if (pinned.st_dev, pinned.st_ino) != (info.st_dev, info.st_ino) or info.st_size < position:
                    raise RuntimeError('capture-file-replaced-or-truncated')
                chunk = os.read(raw_fd, 4096)
                position += len(chunk)
                while chunk:
                    written = os.write(output_fd, chunk)
                    chunk = chunk[written:]
            return info
        reason = 'deadline'
        while time.monotonic() < deadline:
            ended = False
            for key, _ in selector.select(0.01):
                if key.data == 'parent':
                    os.read(life_fd, 1)
                    reason = 'parent-ended'; ended = True; break
                chunk = os.read(key.fd, 1024)
                diagnostic.extend(chunk[:max(0, 4096 - len(diagnostic))])
                if not chunk:
                    selector.unregister(key.fileobj)
            if ended:
                break
            info = forward()
            if process.poll() is not None and (info is None or position >= info.st_size):
                reason = 'tool-exited'; break
        stop(process)
        if reason != 'parent-ended':
            # Stop the writer before draining; a frozen finite file cannot grow
            # forever or lose its final buffered packet on a normal deadline.
            drain_deadline = time.monotonic() + 1
            while time.monotonic() < drain_deadline:
                info = forward()
                if info is None or position >= info.st_size:
                    break
            else:
                raise RuntimeError('capture-drain-timeout')
        text = diagnostic.decode('utf-8', errors='replace').lower()
        category = ('bluetooth-profile-required' if 'profile required' in text else
                    'permission-denied' if 'permission' in text or 'not permitted' in text else
                    'tool-diagnostic' if text.strip() else 'none')
        result.update(stopped=reason, exit=process.returncode, diagnostic=category)
    except (BrokenPipeError, BlockingIOError):
        result['stopped'] = 'consumer-ended'
    except BaseException:
        result['stopped'] = 'watchdog-error'
    finally:
        try:
            stop(process)
        except BaseException:
            result['stopped'] = 'cleanup-incomplete'
        if file_sink is not None:
            os.close(file_sink)
        if raw_fd is not None:
            os.close(raw_fd)
        try:
            if directory is not None:
                with contextlib.suppress(FileNotFoundError):
                    (directory / raw_name).unlink()
            result['rawTraceRemoved'] = True
        except OSError:
            result['stopped'] = 'cleanup-incomplete'
        if transaction is not None:
            result['debugSettingsChanged'] = transaction.changed
            try:
                transaction.restore()
                result['debugSettingsRestored'] = transaction.restored
            except BaseException:
                result['debugSettingsRestored'] = False
                result['stopped'] = 'cleanup-incomplete'
        if transaction is None:
            result['debugSettingsRestored'] = True  # no mutation was attempted
        if directory is not None:
            if result['debugSettingsRestored'] and result['rawTraceRemoved']:
                try:
                    shutil.rmtree(directory)
                except OSError:
                    result['stopped'] = 'cleanup-incomplete'
            else:
                result['recoveryRecord'] = str(directory / 'trace-before.plist')
        if selector is not None:
            selector.close()
        if process is not None and process.stderr is not None:
            process.stderr.close()
        if lock_fd is not None:
            os.close(lock_fd)
        os.umask(old_mask)
        with contextlib.suppress(OSError):
            os.write(status_fd, json.dumps(result).encode())
        for fd in (output_fd, life_fd, status_fd):
            with contextlib.suppress(OSError):
                os.close(fd)
