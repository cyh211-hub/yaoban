#!/usr/bin/python3
"""User-operated, one-shot Apple voice experiment. Never run this entry point as root."""
import argparse
import contextlib
import datetime
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUTPUTS = ROOT / '.build/apple-voice-capture'
POINTER = ROOT / '.build/apple-voice-lab/current-manual-session.json'
CAPTURE = ROOT / 'scripts/apple-voice-capture.py'
PYTHON = '/usr/bin/python3'
ARMED = {'status': 'ready', 'seconds': 20, 'capturing': False}
DIAGNOSTICS = {'none', 'bluetooth-profile-required', 'permission-denied',
               'authorization-required', 'tool-diagnostic', 'invalid-result', 'not-started'}
INPUT_COUNTERS = {'bytesRead', 'readChunks', 'completeLines', 'invalidUTF8Lines',
                  'oversizedLines', 'oversizedBufferStops', 'unprocessedBytesAtStop',
                  'trailingIncompleteLines', 'trailingIncompleteBytes'}
TRANSPORT_COUNTERS = {'lines', 'oversizedLines', 'malformedFormatLines', 'nonReceiveLines',
    'otherDeviceLines', 'selectedDeviceLines', 'invalidTimestamps', 'staleOrFutureTimestamps',
    'outOfOrderTimestamps', 'malformedHexLines', 'hciEventLines', 'disconnectEvents',
    'unrelatedPacketTypes', 'attReceiveLines', 'unrecognizedATTShape', 'invalidTransportHeaders',
    'unrelatedATTValues', 'reportEnvelopes', 'audioFrameReports', 'endReports', 'malformedAudioReports',
    'replayedSessionReports', 'dynamicHandleReports', 'voiceHandleChanges', 'unboundEndReports'}
TIMING_COUNTERS = {'timestampPastSamples', 'timestampFutureSamples',
    'timestampPastMinMilliseconds', 'timestampPastMaxMilliseconds',
    'timestampFutureMinMilliseconds', 'timestampFutureMaxMilliseconds',
    'timestampOffsetsOverDay', 'timestampInvalidOffsets'}
WIRE_COUNTERS = {'inspectedSelectedPackets', 'validHexPackets', 'completeVoiceCandidates',
                 'fragmentedVoiceCandidates', 'aclContinuationCandidates', 'voiceCandidatesOutsideATTLabel'}

PACKET_LOG_COUNTERS = {'records', 'invalidRecords', 'connectionEvents', 'selectedConnections',
    'disconnects', 'unboundACL', 'otherACL', 'selectedACL', 'otherRecords', 'invalidACL',
    'outOfOrder', 'reports', 'endReports', 'unboundEnds', 'duplicateReports', 'partialBytesAtEOF'}
ADDRESSED_COUNTERS = {'lines', 'malformedLines', 'otherDeviceLines', 'nonReceiveLines',
    'selectedAddressRecords', 'invalidHex', 'missingACLHeader', 'headerMismatch', 'lengthMismatch',
    'selectedPackets', 'invalidPackets', 'completePDUs', 'reports', 'endReports',
    'unboundEnds', 'duplicateReports', 'outOfOrder', 'disconnects'}
ACTIVATION = ROOT / 'scripts/apple-voice-activation.py'


class SessionError(Exception):
    pass


def announce(message):
    print(message, flush=True)


def private_directory(path, owner, exact_mode=None):
    path = Path(path)
    if path.is_symlink():
        raise SessionError('unsafe-directory')
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != owner or
            (exact_mode is not None and stat.S_IMODE(info.st_mode) != exact_mode)):
        os.close(fd)
        raise SessionError('unsafe-directory')
    return fd


@contextlib.contextmanager
def session_directory(output):
    output = Path(output)
    try:
        canonical_name = str(uuid.UUID(output.name))
    except ValueError:
        raise SessionError('invalid-session-path')
    if (not output.is_absolute() or output.name != canonical_name or
            output.parent != OUTPUTS or OUTPUTS.is_symlink() or
            OUTPUTS.parent.is_symlink() or output.resolve() != output):
        raise SessionError('invalid-session-path')
    fd = private_directory(output, os.getuid(), 0o700)
    try:
        yield fd
    finally:
        os.close(fd)


def write_json(directory, name, value):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=directory)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, ensure_ascii=True, allow_nan=False)


def pointer(output, phase, status):
    # Atomic replacement in the pinned, user-owned parent; no identity or audio.
    POINTER.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = private_directory(POINTER.parent, os.getuid())
    name = '.' + POINTER.name + '.' + str(uuid.uuid4())
    try:
        try:
            old = os.stat(POINTER.name, dir_fd=directory, follow_symlinks=False)
            if not stat.S_ISREG(old.st_mode) or old.st_uid != os.getuid():
                raise SessionError('unsafe-status-file')
        except FileNotFoundError:
            pass
        write_json(directory, name, {'output': str(output), 'phase': phase,
            'updatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'status': status})
        os.replace(name, POINTER.name, src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name, dir_fd=directory)
        os.close(directory)


def armed(directory):
    try:
        fd = os.open('armed.json', os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return False
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 512):
            raise SessionError('invalid-ready-marker')
        data = os.read(fd, 513)
        try:
            value = json.loads(data)
        except ValueError:
            return False  # The exclusive marker writer may still be completing.
        if value != ARMED:
            raise SessionError('invalid-ready-marker')
        return True
    finally:
        os.close(fd)


def signal_start(directory):
    fd = os.open('start.signal', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=directory)
    os.close(fd)


class Child:
    def __init__(self, command):
        # Inherit the same terminal as sudo -v. No second password prompt.
        self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.streams = {self.process.stdout: self.stdout, self.process.stderr: self.stderr}
        for stream in self.streams:
            os.set_blocking(stream.fileno(), False)

    def running(self):
        return self.process.poll() is None

    def stop(self):
        if self.running():
            with contextlib.suppress(ProcessLookupError, PermissionError):
                self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    self.process.kill()
                # The privileged capture also has its independent 20-second guardian.
                self.process.wait(timeout=25)
        else:
            self.process.wait()

    def close(self):
        for stream in list(self.streams):
            stream.close()
        self.streams.clear()


def pump(children, seconds=0.1, input_fd=None):
    """Drain bounded metadata only. Discard excess stderr; never persist raw text."""
    with selectors.DefaultSelector() as selector:
        for child in children:
            for stream, target in list(child.streams.items()):
                selector.register(stream, selectors.EVENT_READ, (child, target))
        if input_fd is not None:
            selector.register(input_fd, selectors.EVENT_READ, None)
        entered = None
        for key, _ in selector.select(seconds):
            if key.data is None:
                entered = os.read(input_fd, 256)
                continue
            child, target = key.data
            chunk = os.read(key.fd, 4096)
            if not chunk:
                child.streams.pop(key.fileobj)
                key.fileobj.close()
                continue
            limit = 16384 if target is child.stdout else 4096
            remaining = max(0, limit - len(target))
            target.extend(chunk[:remaining])
            if target is child.stdout and len(chunk) > remaining:
                raise SessionError('excess-result-output')
        return entered


def require_running(children):
    if any(not child.running() for child in children):
        pump(children, 0)
        raise SessionError('child-ended-before-start')


def wait_armed(directory, children, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        require_running(children)
        if armed(directory):
            return
        pump(children, min(0.1, max(0, deadline - time.monotonic())))
    raise SessionError('ready-timeout')


def wait_enter(children, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        require_running(children)
        data = pump(children, min(0.1, max(0, deadline - time.monotonic())), sys.stdin.fileno())
        if data == b'':
            raise SessionError('input-ended')
        if data is not None and (b'\n' in data or b'\r' in data):
            require_running(children)
            return
    raise SessionError('start-timeout')


def wait_finished(children, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        pump(children, min(0.1, max(0, deadline - time.monotonic())))
        if all(not child.running() and not child.streams for child in children):
            return
    raise SessionError('finish-timeout')


def diagnostic(data):
    value = bytes(data[:4096]).lower()
    if b'profile required' in value:
        return 'bluetooth-profile-required'
    if b'password' in value or b'authentication' in value:
        return 'authorization-required'
    if b'permission' in value or b'not permitted' in value:
        return 'permission-denied'
    return 'tool-diagnostic' if value.strip() else 'none'


def counters(value, allowed):
    if not isinstance(value, dict):
        return {}
    return {key: number for key, number in value.items()
            if key in allowed and type(number) is int and 0 <= number <= 10**12}


def result(child, kind):
    if child is None:
        return {'status': 'not-started', 'diagnostic': 'not-started'}
    code = child.process.poll()
    saved = {'status': 'completed' if code == 0 else 'failed',
             'exit': code, 'diagnostic': diagnostic(child.stderr)}
    try:
        value = json.loads(child.stdout)
    except ValueError:
        saved['diagnostic'] = 'invalid-result' if saved['diagnostic'] == 'none' else saved['diagnostic']
        return saved
    if not isinstance(value, dict):
        saved['diagnostic'] = 'invalid-result'
        return saved
    if kind == 'capture':
        capture = value.get('capture', {})
        if isinstance(capture, dict):
            filtered = {}
            if type(capture.get('stopped')) is str and capture['stopped'] in {'deadline', 'parent-ended', 'tool-exited', 'watchdog-error', 'consumer-ended', 'cleanup-incomplete'}:
                filtered['stopped'] = capture['stopped']
            if type(capture.get('exit')) is int:
                filtered['exit'] = capture['exit']
            if type(capture.get('diagnostic')) is str and capture['diagnostic'] in DIAGNOSTICS:
                filtered['diagnostic'] = capture['diagnostic']
            recovery = capture.get('recoveryRecord')
            if (isinstance(recovery, str) and recovery.startswith('/private/tmp/yaoban-voice-pklg-')
                    and len(recovery) < 256 and Path(recovery).name == 'trace-before.plist'
                    and '..' not in Path(recovery).parts and len(Path(recovery).parts) == 5):
                filtered['recoveryRecord'] = recovery
            saved['capture'] = filtered
        for key in ('debugSettingsChanged', 'installedServices', 'debugSettingsRestored', 'rawTraceRemoved'):
            if type(value.get(key)) is bool:
                saved[key] = value[key]
    else:
        saved.update(counters(value, {'reports', 'samples', 'decodeErrors', 'streamResets'}))
        for key in ('seconds', 'rms'):
            number = value.get(key)
            if type(number) in (int, float) and math.isfinite(number) and 0 <= number <= 10**9:
                saved[key] = number
        if type(value.get('stopped')) is str and value['stopped'] in {'eof', 'consumer-timeout', 'device-changed-or-disconnected',
                                    'read-failure', 'oversized-line', 'audio-limit', 'invalid-packet-log', 'addressed-capture-stopped'}:
            saved['stopped'] = value['stopped']
        if type(value.get('rawTraceSaved')) is bool:
            saved['rawTraceSaved'] = value['rawTraceSaved']
        details = value.get('diagnostics', {})
        if isinstance(details, dict):
            saved['diagnostics'] = {'input': counters(details.get('input'), INPUT_COUNTERS),
                                   'transport': counters(details.get('transport'), TRANSPORT_COUNTERS),
                                   'timing': counters(details.get('timing'), TIMING_COUNTERS),
                                   'wire': counters(details.get('wire'), WIRE_COUNTERS)}
            if isinstance(details.get('packetLog'), dict):
                saved['diagnostics']['packetLog'] = counters(details['packetLog'], PACKET_LOG_COUNTERS)
            if isinstance(details.get('addressed'), dict):
                saved['diagnostics']['addressed'] = counters(details['addressed'], ADDRESSED_COUNTERS)
    return saved


def recover_listener_summary(directory, child):
    if child is None or 'reports' in result(child, 'listen'):
        return
    try:
        fd = os.open('summary.json', os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 8192):
            return
        data = os.read(fd, 8193)
        value = json.loads(data)
        if isinstance(value, dict) and type(value.get('reports')) is int:
            child.stdout = bytearray(data)
    except (OSError, ValueError):
        pass
    finally:
        os.close(fd)


def prepare(binary=False, addressed=False):
    child = Child([PYTHON, '-I', str(CAPTURE), '--prepare'] + (['--addressed'] if addressed else ['--binary'] if binary else []))
    try:
        wait_finished([child], 20)
        if child.process.returncode != 0:
            raise SessionError('prepare-failed')
        value = json.loads(child.stdout)
        if not isinstance(value, dict) or type(value.get('output')) is not str:
            raise SessionError('prepare-failed')
        output = Path(value['output'])
        with session_directory(output):
            pass
        return output
    finally:
        child.stop()
        child.close()


def wait_binary_ready(directory, children, seconds=9):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        require_running(children)
        try:
            fd = os.open('binary-stream-ready.json', os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                         dir_fd=directory)
        except FileNotFoundError:
            pump(children, 0.1)
            continue
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                    stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 512):
                raise SessionError('invalid-binary-ready-marker')
            try:
                value = json.loads(os.read(fd, 513))
            except ValueError:
                value = None
            if value == {'status': 'selected-device-ready'}:
                return
            if value is not None:
                raise SessionError('invalid-binary-ready-marker')
        finally:
            os.close(fd)
        pump(children, 0.1)
    raise SessionError('connection-metadata-missing')


def activate_once(directory):
    # Runs as the login user after source readiness, before the speech prompt.
    # The probe has its own
    # five-second kill deadline; only the bound, declared auxiliary interface.
    completed = subprocess.run([PYTHON, '-I', str(ACTIVATION), '--activate-once'],
                               capture_output=True, timeout=7)
    if completed.returncode or len(completed.stdout) > 4096:
        raise SessionError('activation-unavailable')
    value = json.loads(completed.stdout)
    saved = counters(value, {'auxiliaryInterfaces', 'featureInterfaces', 'openedInterfaces',
                            'writeAttempts', 'acceptedSubmissions', 'openFailures', 'writeFailures'})
    accepted = value.get('status') == 'submitted-audio-unverified'
    saved.update(status='submitted-audio-unverified' if accepted else 'activation-unavailable',
                 remoteAudioConfirmed=False)
    write_json(directory, 'activation-result.json', saved)
    if not accepted:
        raise SessionError('activation-unavailable')


def run(binary=False, addressed=False):
    guarded = binary or addressed
    if os.geteuid() == 0 or os.getuid() == 0:
        raise SessionError('normal-user-required')
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise SessionError('terminal-required')
    os.umask(0o077)
    if guarded:
        announce('本次使用独立文件采集：临时开启蓝牙诊断，结束后恢复原设置并删除本工具的临时原始文件。\n'
                 '只保存已绑定苹果遥控器的短录音；不安装服务、不更换遥伴、不重启电脑。\n'
                 '说话前会向已绑定遥控器发送一次已核对的麦克风启动指令。')
    announce('苹果遥控器收音实验：仅一次 20 秒，只解码已选 Apple 遥控器。\n'
             '不启用其它麦克风，不上传。\n'
             '管理员密码在终端输入，不会显示；按 Ctrl-C 可取消。\n'
             '请先完成下面的管理员验证，现在不用按遥控器。')
    if subprocess.run(['/usr/bin/sudo', '-v'], check=False).returncode != 0:
        raise SessionError('authorization-cancelled')
    output = prepare(binary, addressed) if guarded else prepare()
    children = []
    listener = capture = None
    state = 'failed'
    phase = 'arming'
    with session_directory(output) as directory:
        try:
            pointer(output, phase, 'running')
            listener = Child([PYTHON, '-I', str(CAPTURE), '--listen', str(output)] + (['--addressed'] if addressed else ['--binary'] if binary else []))
            children.append(listener)
            capture = Child(['/usr/bin/sudo', '-n', PYTHON, '-I', str(CAPTURE), '--capture', str(output)] + (['--addressed'] if addressed else ['--binary'] if binary else []))
            children.append(capture)
            announce('验证已完成，正在准备采集通道，请稍等。')
            wait_armed(directory, children)
            phase = 'waiting-for-enter'
            pointer(output, phase, 'ready')
            if guarded:
                announce('准备完成。按回车开始后，请先等终端显示“可以说话”，再按住苹果侧边语音键\n'
                         '说“苹果遥控器收音测试，一二三”约 5 秒后松开。没有出现提示就不用说话。\n'
                         '期间无需回聊天回复。请在 40 秒内按回车；按 Ctrl-C 取消。')
            else:
                announce('准备完成。按回车开始，随后等待 3 秒，再按住苹果侧边语音键说\n'
                         '“苹果遥控器收音测试，一二三”约 5 秒后松开。\n'
                         '期间无需回聊天回复。请在 40 秒内按回车；按 Ctrl-C 取消。')
            wait_enter(children)
            # Recheck readiness and child liveness directly before the exclusive start.
            require_running(children)
            if not armed(directory):
                raise SessionError('ready-marker-lost')
            signal_start(directory)
            capture_started = time.monotonic()
            phase = 'capturing'
            pointer(output, phase, 'running')
            if guarded:
                announce('请轻按苹果遥控器方向键；若还没出现“可以说话”，隔两秒再轻按一次。' if addressed else
                         '正在确认已绑定遥控器的连接信息，请先不要说话。')
                try:
                    wait_binary_ready(directory, children)
                except SessionError as error:
                    if addressed and str(error) == 'connection-metadata-missing':
                        raise SessionError('selected-device-packets-missing')
                    raise
                activate_once(directory)
                if time.monotonic() - capture_started > 13:
                    raise SessionError('voice-ready-timeout')
                announce('可以说话：现在按住苹果侧边语音键，说约 5 秒，松开后等待结束。')
            else:
                announce('计时开始。等待 3 秒后按住侧边语音键说话，松开后等待采集结束。')
            wait_finished(children, 40 if guarded else 30)
            if any(child.process.returncode != 0 for child in children):
                raise SessionError('capture-or-listener-failed')
            if guarded:
                cleanup = result(capture, 'capture')
                if cleanup.get('debugSettingsRestored') is not True or cleanup.get('rawTraceRemoved') is not True:
                    raise SessionError('cleanup-incomplete')
            state, phase = 'completed', 'finished'
        except KeyboardInterrupt:
            state, phase = 'cancelled', 'cancelled'
            raise
        except (OSError, ValueError, SessionError, subprocess.SubprocessError):
            phase = 'failed'
            raise
        finally:
            cleanup_failed = False
            for child in reversed(children):
                try:
                    if guarded and child is listener:
                        # Root is stopped first. Give the EOF-driven decoder time
                        # to flush its bounded summary before signalling its wrapper.
                        until = time.monotonic() + 2
                        while child.running() and time.monotonic() < until:
                            pump(children, .05)
                    child.stop()
                except (OSError, subprocess.SubprocessError):
                    cleanup_failed = True
            with contextlib.suppress(OSError, ValueError, SessionError):
                pump(children, 0)
            if guarded and capture is not None:
                restored = result(capture, 'capture')
                if (restored.get('debugSettingsChanged') is True and
                        restored.get('debugSettingsRestored') is not True) or restored.get('capture', {}).get('stopped') == 'cleanup-incomplete':
                    cleanup_failed = True
            with contextlib.suppress(OSError):
                recover_listener_summary(directory, listener)
            for name, child, kind in [('capture-result.json', capture, 'capture'),
                                      ('listen-result.json', listener, 'listen')]:
                with contextlib.suppress(OSError):
                    write_json(directory, name, result(child, kind))
            for child in children:
                child.close()
            if cleanup_failed:
                state, phase = 'failed', 'cleanup-incomplete'
            pointer(output, phase, state)
            if cleanup_failed:
                raise SessionError('cleanup-incomplete')
    announce('采集结束，请回聊天告诉我“已完成”；暂不能据文字判断收音成功。')


def cancelled_signal(_signum, _frame):
    raise KeyboardInterrupt()


def main():
    signal.signal(signal.SIGTERM, cancelled_signal)
    try:
        parser = argparse.ArgumentParser()
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument("--binary", action="store_true")
        mode.add_argument("--addressed", action="store_true")
        args = parser.parse_args()
        run(args.binary, args.addressed)
        return 0
    except KeyboardInterrupt:
        announce('\n实验已取消。请回聊天告诉我已取消。')
        return 130
    except (OSError, ValueError, SessionError, subprocess.SubprocessError) as error:
        # Only our own fixed categories are displayed; never echo child output.
        category = str(error) if isinstance(error, SessionError) else 'system-operation-failed'
        announce('实验已停止（' + category + '）。请回聊天告诉我这个提示，无需再次输入密码。')
        return 2


if __name__ == '__main__':
    sys.exit(main())
