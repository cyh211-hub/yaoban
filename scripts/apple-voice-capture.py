#!/usr/bin/python3
"""Bounded local experiment. Binary mode temporarily enables/restores HCI traces.
No services are installed.

--prepare runs as the user. --capture needs a separate explicit administrator action.
The Python coordinator/guardian run privileged, and only Apple's verified capture
executable accesses HCI. A separate normal-login-session consumer parses, decodes,
and saves selected-device audio through a private FIFO.
"""
import argparse
import contextlib
import errno
import json
import importlib.util
import os
from pathlib import Path
import selectors
import signal
import shutil
import stat
import subprocess
import sys
import time
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUTPUTS = ROOT / '.build/apple-voice-capture'
CONSUMER = ROOT / '.build/apple-voice-lab/voice-check'
PACKETLOGGER = Path('/Applications/PacketLogger.app/Contents/Resources/packetlogger')
STAGE = 'arguments'
_BINARY_SPEC = importlib.util.spec_from_file_location('yaoban_binary_capture', ROOT / 'scripts/apple_voice_binary.py')
BINARY_CAPTURE = importlib.util.module_from_spec(_BINARY_SPEC)
_BINARY_SPEC.loader.exec_module(BINARY_CAPTURE)


@contextlib.contextmanager
def private_output(output):
    output = Path(output)
    if output.is_symlink() or output.resolve().parent != OUTPUTS.resolve():
        raise RuntimeError('Unexpected output directory')
    fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid < 501:
            raise RuntimeError('Output must be a private user-owned experiment directory')
        yield fd, info
    finally:
        os.close(fd)


def wait_for_marker(directory, name, owner, expected, seconds):
    """Bounded, nonblocking read of a fixed private marker, relative to a pinned dir.

    expected=None denotes the zero-byte start signal. Other values are fixed JSON
    readiness metadata. Never follow symlinks or open a FIFO as a marker.
    """
    deadline = time.monotonic() + seconds
    while True:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
        except FileNotFoundError:
            fd = None
        if fd is not None:
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 512:
                    raise RuntimeError('Invalid private readiness marker')
                data = os.read(fd, 513)
                if expected is None:
                    if info.st_size != 0 or data:
                        raise RuntimeError('Invalid start signal')
                    return
                try:
                    if json.loads(data) == expected:
                        return
                except ValueError:
                    pass  # The consumer may still be completing its exclusive write.
            finally:
                os.close(fd)
        if time.monotonic() >= deadline:
            raise RuntimeError('Readiness timed out; capture was not started')
        time.sleep(0.05)


def await_consumer_and_start(directory, info, consumer_seconds=15, start_seconds=60, accepted_seconds=5):
    global STAGE
    STAGE = 'waiting-for-consumer'
    wait_for_marker(directory, 'consumer-ready.json', info.st_uid,
                    {'status': 'ready', 'capturing': False}, consumer_seconds)
    STAGE = 'waiting-for-start-signal'
    ready_fd = os.open('armed.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                       0o600, dir_fd=directory)
    with os.fdopen(ready_fd, 'w') as ready:
        os.fchown(ready.fileno(), info.st_uid, info.st_gid)
        json.dump({'status': 'ready', 'seconds': 20, 'capturing': False}, ready)
    wait_for_marker(directory, 'start.signal', info.st_uid, None, start_seconds)
    STAGE = 'waiting-for-consumer-start'
    # The device may have switched while the user readied the test. The consumer
    # revalidates it after start and must acknowledge before any HCI capture.
    wait_for_marker(directory, 'consumer-started.json', info.st_uid,
                    {'status': 'listening'}, accepted_seconds)


def open_consumer_pipe(directory, owner, seconds=5):
    """Wait briefly for the normal-user reader without manufacturing readiness.

    The user starts both processes concurrently. A nonblocking writer may reach
    the FIFO before the reader enters open(). Retry only ENXIO, while pinning and
    checking the same private FIFO inode on every attempt.
    """
    initial = os.stat('capture.pipe', dir_fd=directory, follow_symlinks=False)
    if not stat.S_ISFIFO(initial.st_mode) or initial.st_uid != owner or stat.S_IMODE(initial.st_mode) != 0o600:
        raise RuntimeError('Invalid private capture pipe')
    deadline = time.monotonic() + seconds
    while True:
        current = os.stat('capture.pipe', dir_fd=directory, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (initial.st_dev, initial.st_ino):
            raise RuntimeError('Capture pipe replaced')
        if not stat.S_ISFIFO(current.st_mode) or current.st_uid != owner or stat.S_IMODE(current.st_mode) != 0o600:
            raise RuntimeError('Invalid private capture pipe')
        try:
            fd = os.open('capture.pipe', os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
        except OSError as error:
            if error.errno != errno.ENXIO:
                raise
            if time.monotonic() >= deadline:
                raise RuntimeError('Consumer pipe reader timed out')
            time.sleep(0.05)
            continue
        opened = os.fstat(fd)
        if ((opened.st_dev, opened.st_ino) != (initial.st_dev, initial.st_ino)
                or not stat.S_ISFIFO(opened.st_mode) or opened.st_uid != owner
                or stat.S_IMODE(opened.st_mode) != 0o600):
            os.close(fd)
            raise RuntimeError('Invalid private capture pipe')
        return fd


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)


def watch_capture(command, output_fd, life_fd, status_fd, seconds):
    """Independent owner of the capture process; exits on deadline or parent EOF.

    command is fixed to Apple PacketLogger by the live caller. Tests inject a local
    synthetic producer without ever calling the privileged capture entry point.
    """
    process = None
    reason, diagnostic = 'deadline', bytearray()
    try:
        # Normalize only this producer's timestamp formatting. Do not change the
        # parent environment, system timezone, or decoder freshness policy.
        child_environment = os.environ.copy()
        child_environment['TZ'] = 'UTC'
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output_fd,
                                   stderr=subprocess.PIPE, close_fds=True, env=child_environment)
        os.close(output_fd)
        selector = selectors.DefaultSelector()
        selector.register(life_fd, selectors.EVENT_READ, 'parent')
        selector.register(process.stderr, selectors.EVENT_READ, 'error')
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and process.poll() is None:
            for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                if key.data == 'parent':
                    os.read(life_fd, 1)
                    reason = 'parent-ended'
                    stop(process)
                    break
                chunk = os.read(key.fd, 1024)
                diagnostic.extend(chunk[:max(0, 4096 - len(diagnostic))])
                if not chunk:
                    selector.unregister(key.fileobj)
        if process.poll() is not None and reason == 'deadline':
            reason = 'tool-exited'
        stop(process)
        os.set_blocking(process.stderr.fileno(), False)
        try:
            diagnostic.extend(os.read(process.stderr.fileno(), 4096 - len(diagnostic)))
        except BlockingIOError:
            pass
        # Report a category only; never print raw tool output or identifiers.
        text = diagnostic.decode('utf-8', errors='replace').lower()
        category = ('bluetooth-profile-required' if 'profile required' in text else
                    'permission-denied' if 'permission' in text or 'not permitted' in text else
                    'tool-diagnostic' if text.strip() else 'none')
        result = {'stopped': reason, 'exit': process.returncode, 'diagnostic': category}
    except BaseException:
        if process is not None:
            stop(process)
        result = {'stopped': 'watchdog-error'}
    try:
        os.write(status_fd, json.dumps(result).encode())
    except OSError:
        pass
    for fd in (life_fd, status_fd):
        try:
            os.close(fd)
        except OSError:
            pass


def spawn_guardian(command, seconds, binary=False, preferences=None, addressed=False):
    read_fd, write_fd = os.pipe()
    life_read, life_write = os.pipe()
    status_read, status_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        # Do not inherit a copy of the parent's life writer: EOF must work even if
        # the coordinator is killed abruptly. Also close any consumer pipe ends.
        keep = {0, 1, 2, write_fd, life_read, status_write}
        for entry in os.listdir('/dev/fd'):
            try:
                fd = int(entry)
                if fd not in keep:
                    os.close(fd)
            except (ValueError, OSError):
                pass
        if binary or addressed:
            # Parent lifeline/deadline owns cancellation. Terminal signals must
            # not interrupt the guardian while it restores system preferences.
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            BINARY_CAPTURE.watch_binary_capture(command, write_fd, life_read, status_write,
                                                 seconds, preferences, addressed)
        else:
            watch_capture(command, write_fd, life_read, status_write, seconds)
        os._exit(0)
    os.close(write_fd)
    os.close(life_read)
    os.close(status_write)
    return pid, read_fd, life_write, status_read


def prepare(binary=False, addressed=False):
    if os.geteuid() == 0:
        raise RuntimeError('Prepare must run as the normal user')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R=anchor apple', str(PACKETLOGGER)], check=True)
    result = subprocess.run([str(CONSUMER), '--identity'], capture_output=True, timeout=5, check=True)
    identity = json.loads(result.stdout)
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    output = OUTPUTS / str(uuid.uuid4())
    output.mkdir(mode=0o700)
    # Only this explicit device binding is saved, no general Bluetooth inventory.
    fd = os.open(output / 'expected-device.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(identity, f)
    if binary or addressed:
        fd = os.open(output / 'capture-format.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump({'format': 'addressed' if addressed else 'pklg'}, f)
    os.mkfifo(output / 'capture.pipe', 0o600)
    print(json.dumps({'output': str(output), 'device': identity['name'], 'seconds': 20, 'status': 'prepared'}))


def listen(output, binary=False, addressed=False):
    if os.geteuid() == 0:
        raise RuntimeError('The audio consumer must run in the normal login session')
    output = Path(output)
    if output.is_symlink() or output.resolve().parent != OUTPUTS.resolve():
        raise RuntimeError('Unexpected output directory')
    with private_output(output) as (directory, info):
        check_format(directory, info.st_uid, binary, addressed)
    pipe = output / 'capture.pipe'
    info = pipe.lstat()
    if not stat.S_ISFIFO(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise RuntimeError('Invalid private capture pipe')
    # Wait for the approved root producer without spending the 23-second audio
    # window on the password prompt. FIFO-open waiting has its own 120-second cap.
    signal.alarm(120)
    fd = os.open(pipe, os.O_RDONLY | os.O_NOFOLLOW)
    signal.alarm(0)
    consumer = subprocess.Popen([str(CONSUMER), '--consume-addressed' if addressed else '--consume-pklg' if binary else '--consume', str(output)], stdin=fd,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(fd)
    try:
        # Cover every accepted phase: initialization 15s, user start 60s,
        # post-start identity check 5s, audio 23s, result/cleanup margin 7s.
        # This outer limit is not the recording timer.
        stdout, _ = consumer.communicate(timeout=110)
    except subprocess.TimeoutExpired:
        raise RuntimeError('Consumer timed out')
    finally:
        # Also close the ordinary-user decoder on Ctrl-C or SIGTERM. It must not
        # outlive the manual session when the supervisor cancels preparation.
        stop(consumer)
    if consumer.returncode or len(stdout) > 8192:
        raise RuntimeError('Consumer unavailable')
    print(json.dumps(json.loads(stdout)))


def check_format(directory, owner, binary, addressed=False):
    if binary or addressed:
        wait_for_marker(directory, 'capture-format.json', owner, {'format': 'addressed' if addressed else 'pklg'}, 0)
    else:
        try:
            os.stat('capture-format.json', dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise RuntimeError('Capture format mismatch')


def capture(output, binary=False, addressed=False):
    global STAGE
    STAGE = 'administrator-and-output'
    if os.geteuid() != 0:
        raise RuntimeError('Capture requires the explicitly approved administrator launch')
    # Pin the validated directory: later relative file opens cannot be redirected
    # by renaming the user-owned directory or replacing it with a symlink.
    with private_output(output) as (directory, info):
        check_format(directory, info.st_uid, binary, addressed)
        capture_in_directory(directory, info, binary or addressed, addressed)


def capture_in_directory(directory, info, binary_mode=False, addressed_mode=False):
    global STAGE
    for name in ('consumer-ready.json', 'consumer-started.json', 'armed.json', 'start.signal'):
        try:
            os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            continue
        raise RuntimeError('Use a freshly prepared experiment directory')
    STAGE = 'apple-signature'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R=anchor apple', str(PACKETLOGGER)], check=True)
    # The normal-session consumer independently verifies the prepared binding and
    # rechecks the selected device while reading. Root never opens a HID client or
    # attempts to reconstruct the user's Bluetooth login session.
    # Copy then verify in a root-private directory to prevent replacement between
    # signature validation and privileged execution, including @rpath frameworks.
    STAGE = 'private-apple-tool-copy'
    staged = tempfile.TemporaryDirectory(prefix='yaoban-packetlogger-', dir='/private/tmp')
    snapshot = Path(staged.name) / 'PacketLogger.app'
    shutil.copytree(PACKETLOGGER.parents[2], snapshot, symlinks=True)
    for item in snapshot.rglob('*'):
        if item.is_symlink() and not item.resolve().is_relative_to(snapshot.resolve()):
            staged.cleanup()
            raise RuntimeError('External bundle symlink')
    STAGE = 'private-apple-tool-signature'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=anchor apple', str(snapshot)], check=True)
    binary = snapshot / 'Contents/Resources/packetlogger'
    STAGE = 'private-consumer-pipe'
    destination = open_consumer_pipe(directory, info.st_uid)
    guardian = None
    try:
        # Opening the writer releases the normal user's waiting FIFO reader.
        # The receiver confirms identity, output, and decoder setup before we
        # announce readiness; it does not consume its audio budget until start.
        await_consumer_and_start(directory, info)
        STAGE = 'bounded-capture'
        command = [str(binary), 'convert'] + ([] if binary_mode else ['-s', '-f', 'itpahdr'])
        guardian, incoming, lifetime, status = spawn_guardian(command, 20, binary_mode,
            BINARY_CAPTURE.SystemTracePreferences() if binary_mode else None, addressed_mode)
        selector = selectors.DefaultSelector()
        selector.register(incoming, selectors.EVENT_READ)
        deadline = time.monotonic() + (30 if binary_mode else 21)
        finished = False
        while time.monotonic() < deadline and not finished:
            for _key, _events in selector.select(0.1):
                chunk = os.read(incoming, 4096)
                if not chunk:
                    finished = True
                    break
                # No unbounded queue. A slow or failed consumer ends this experiment.
                offset = 0
                while offset < len(chunk):
                    offset += os.write(destination, chunk[offset:])
    except (BrokenPipeError, BlockingIOError):
        pass
    finally:
        if guardian is not None:
            os.close(lifetime)  # independent watchdog owns and stops PacketLogger
            os.close(incoming)
            os.waitpid(guardian, 0)
            status_data = os.read(status, 2048)
            os.close(status)
        else:
            status_data = b'{}'
        os.close(destination)
        staged.cleanup()
        result = json.loads(status_data or b'{}')
        summary = {'capture': result, 'debugSettingsChanged': result.get('debugSettingsChanged', False),
                   'installedServices': False}
        if binary_mode:
            summary.update(debugSettingsRestored=result.get('debugSettingsRestored', guardian is None),
                           rawTraceRemoved=result.get('rawTraceRemoved', guardian is None))
        print(json.dumps(summary), flush=True)
    if binary_mode and (not summary['debugSettingsRestored'] or not summary['rawTraceRemoved']):
        raise RuntimeError('Binary capture cleanup requires inspection')
    if binary_mode and (result.get('stopped') == 'watchdog-error' or
            (result.get('stopped') == 'tool-exited' and result.get('exit') != 0)):
        raise RuntimeError('Binary producer unavailable')



if __name__ == '__main__':
    def cancel(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, cancel)
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare', action='store_true')
    mode.add_argument('--listen', metavar='PRIVATE_OUTPUT_DIRECTORY')
    mode.add_argument('--capture', metavar='PRIVATE_OUTPUT_DIRECTORY')
    format_mode = parser.add_mutually_exclusive_group()
    format_mode.add_argument('--binary', action='store_true')
    format_mode.add_argument('--addressed', action='store_true')
    args = parser.parse_args()
    try:
        if args.prepare:
            prepare(args.binary, args.addressed)
        elif args.listen:
            listen(args.listen, args.binary, args.addressed)
        else:
            capture(args.capture, args.binary, args.addressed)
    except KeyboardInterrupt:
        print('Voice experiment cancelled; inspect capture result for cleanup status.', file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        detail = ('; ' + str(error)) if isinstance(error, RuntimeError) else ''
        code = getattr(error, 'returncode', getattr(error, 'errno', 'unavailable'))
        print('Voice experiment stopped at '+STAGE+'; '+type(error).__name__+' code='+str(code)+detail+'; inspect capture result for cleanup status.', file=sys.stderr)
        sys.exit(2)
