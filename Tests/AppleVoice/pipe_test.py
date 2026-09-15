# Synthetic input test requiring a currently selected Apple remote; never starts capture.
import datetime
import errno
import json
import os
from pathlib import Path
import stat
import subprocess
import time

root = Path.cwd()
script = root / 'scripts/apple-voice-capture.py'
fixture = (root / 'Tests/Fixtures/apple-packetlogger26-synthetic.tsv').read_text().splitlines()[-1].split('\t')
results = []


def fresh(fields):
    fields = fields.copy()
    fields[0] = datetime.datetime.now().astimezone().isoformat(timespec='milliseconds')
    return ('\t'.join(fields) + '\n').encode()


def write_all(fd, data):
    deadline = time.monotonic() + 5
    while data:
        try:
            count = os.write(fd, data[:4096])
            data = data[count:]
        except BlockingIOError:
            if time.monotonic() > deadline:
                raise
            time.sleep(.01)


def run_case(name, produce, start_kind='valid', wait_before_start=0):
    prepared = subprocess.run(['/usr/bin/python3', '-I', str(script), '--prepare'],
                              capture_output=True, check=True, text=True)
    out = Path(json.loads(prepared.stdout)['output'])
    expected = json.loads((out / 'expected-device.json').read_text())
    fields = fixture.copy()
    fields[2] = expected['address']
    listener = subprocess.Popen(['/usr/bin/python3', '-I', str(script), '--listen', str(out)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    fd = None
    try:
        deadline = time.monotonic() + 8
        while fd is None:
            try:
                fd = os.open(out / 'capture.pipe', os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO or time.monotonic() > deadline:
                    raise
                time.sleep(.05)
        ready = out / 'consumer-ready.json'
        while not ready.exists():
            assert listener.poll() is None, 'consumer exited before readiness acknowledgment'
            assert time.monotonic() < deadline, 'consumer readiness timeout'
            time.sleep(.05)
        assert json.loads(ready.read_text()) == {'status': 'ready', 'capturing': False}
        assert stat.S_IMODE(ready.stat().st_mode) == 0o600
        if wait_before_start:
            # Longer than the 23 s audio budget: preparation must not use it up.
            time.sleep(wait_before_start)
            assert listener.poll() is None, 'consumer audio budget began before start signal'
            assert not (out / 'summary.json').exists() and not (out / 'apple-voice.wav').exists()
        signal = out / 'start.signal'
        if start_kind == 'symlink':
            signal.symlink_to(out / 'expected-device.json')
        else:
            signal_fd = os.open(signal, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            if start_kind == 'nonempty':
                os.write(signal_fd, b'x')
            os.close(signal_fd)
            if start_kind == 'wrong-mode':
                signal.chmod(0o644)
        if start_kind == 'valid':
            started = out / 'consumer-started.json'
            deadline = time.monotonic() + 5
            while not started.exists():
                assert listener.poll() is None, 'consumer exited before start acknowledgment'
                assert time.monotonic() < deadline, 'consumer start acknowledgment timeout'
                time.sleep(.02)
            assert json.loads(started.read_text()) == {'status': 'listening'}
            assert stat.S_IMODE(started.stat().st_mode) == 0o600
            produce(fd, fields)
        os.close(fd)
        fd = None
        stdout, stderr = listener.communicate(timeout=8)
        if start_kind != 'valid':
            assert listener.returncode != 0, 'unsafe start signal accepted'
            assert not (out / 'summary.json').exists() and not (out / 'apple-voice.wav').exists()
            assert not (out / 'consumer-started.json').exists()
            results.append({'case': name, 'invalidSignalRejected': True})
            return None
        assert listener.returncode == 0, stderr.decode()
        result = json.loads(stdout)
        assert result['rawTraceSaved'] is False
        assert expected['address'] not in stdout.decode() and expected['identity'] not in stdout.decode()
        for category in result['diagnostics'].values():
            assert all(type(value) is int and value >= 0 for value in category.values())
        results.append({'case': name, 'output': str(out), 'result': result})
        return result
    finally:
        if fd is not None:
            os.close(fd)
        if listener.poll() is None:
            listener.terminate()
            try:
                listener.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                listener.kill()
                listener.communicate()


def mixed(fd, fields):
    write_all(fd, b'\xff\nnot a PacketLogger line\n')
    foreign = fields.copy()
    foreign[0] = 'unparsed private timestamp'
    foreign[2] = '00:00:00:00:00:00' if fields[2] != '00:00:00:00:00:00' else '11:11:11:11:11:11'
    foreign[5] = 'ZZ private payload'
    write_all(fd, ('\t'.join(foreign) + '\n').encode())
    stale = fields.copy()
    stale[0] = (datetime.datetime.now().astimezone() - datetime.timedelta(seconds=2)).isoformat(timespec='milliseconds')
    write_all(fd, ('\t'.join(stale) + '\n').encode())
    malformed = fields.copy()
    raw = malformed[5].split()
    raw[15] = '00'
    malformed[5] = ' '.join(raw)
    write_all(fd, fresh(malformed))
    ended = fields.copy()
    ended[5] = ' '.join(ended[5].split()[:11] + ['00'] * 99)
    write_all(fd, fresh(ended))
    for index in range(12):
        raw = fields[5].split()
        raw[13] = format(index, '02X')
        fields[5] = ' '.join(raw)
        write_all(fd, fresh(fields))
        time.sleep(.02)
    write_all(fd, b'x' * 8193 + b'\nunfinished')


mixed_result = run_case('mixed-with-delayed-start', mixed, wait_before_start=24)
assert mixed_result['reports'] == 12 and mixed_result['samples'] == 11520, mixed_result
assert mixed_result['stopped'] == 'eof' and mixed_result['decodeErrors'] == 0, mixed_result
inputs = mixed_result['diagnostics']['input']
assert inputs['completeLines'] == 19 and inputs['invalidUTF8Lines'] == 1 and inputs['oversizedLines'] == 1, inputs
assert inputs['oversizedBufferStops'] == 0 and inputs['trailingIncompleteLines'] == 1, inputs
assert inputs['trailingIncompleteBytes'] == len(b'unfinished') and inputs['unprocessedBytesAtStop'] == len(b'unfinished'), inputs
transport = mixed_result['diagnostics']['transport']
for key, count in {'lines': 18, 'malformedFormatLines': 1, 'otherDeviceLines': 1,
                   'staleOrFutureTimestamps': 1, 'audioFrameReports': 12, 'endReports': 0, 'unboundEndReports': 1,
                   'malformedAudioReports': 1, 'reportEnvelopes': 14, 'oversizedLines': 1}.items():
    assert transport[key] == count, (key, transport)


def dynamic_handles(fd, fields):
    def send(attribute, sequence=0, connection=0x407, ended=False, bad_length=False):
        packet = fields.copy()
        raw = packet[5].split()
        header = connection | 0x2000
        raw[0:2] = [format(header & 0xff, '02X'), format(header >> 8, '02X')]
        raw[9:11] = [format(attribute & 0xff, '02X'), format(attribute >> 8, '02X')]
        raw[13:15] = [format(sequence & 0xff, '02X'), format(sequence >> 8, '02X')]
        if ended:
            raw[11:] = ['00'] * 99
        if bad_length:
            raw[15] = '01'  # TOC alone cannot establish a voice characteristic.
        packet[3] = format(connection, '#06x')
        packet[5] = ' '.join(raw)
        write_all(fd, fresh(packet))
        time.sleep(.02)

    send(0x37, ended=True)
    send(0x37)
    send(0x37, sequence=1)
    send(0x99, ended=True)
    send(0x1234, bad_length=True)
    send(0x37, sequence=2)
    send(0x1234)
    send(0x1234, connection=0x408)
    send(0x1234, connection=0x408, ended=True)


dynamic_result = run_case('dynamic-voice-handles-synthetic', dynamic_handles)
assert dynamic_result['reports'] == 6 and dynamic_result['samples'] == 4800, dynamic_result
assert dynamic_result['decodeErrors'] == 0 and dynamic_result['streamResets'] == 3, dynamic_result
assert dynamic_result['stopped'] == 'eof', dynamic_result
for key, count in {'audioFrameReports': 5, 'dynamicHandleReports': 5, 'voiceHandleChanges': 2,
                   'endReports': 1, 'unboundEndReports': 2, 'malformedAudioReports': 1}.items():
    assert dynamic_result['diagnostics']['transport'][key] == count, (key, dynamic_result)


def wire_shapes(fd, fields):
    future = fields.copy()
    future[0] = (datetime.datetime.now().astimezone() + datetime.timedelta(hours=8)).isoformat(timespec='milliseconds')
    write_all(fd, ('\t'.join(future) + '\n').encode())
    unclassified = fields.copy()
    unclassified[1] = 'Unclassified synthetic packet'
    write_all(fd, fresh(unclassified))
    raw = fields[5].split()
    first = raw[:44]
    first[2:4] = ['28', '00']
    unclassified[5] = ' '.join(first)
    write_all(fd, fresh(unclassified))
    # Same synthetic connection, PB=1, exactly 66 continuation bytes.
    header = int(raw[0], 16) | int(raw[1], 16) << 8
    continuation_header = (header & 0x0fff) | 0x1000
    continuation = [format(continuation_header & 0xff, '02X'),
                    format(continuation_header >> 8, '02X'), '42', '00'] + raw[44:]
    unclassified[5] = ' '.join(continuation)
    write_all(fd, fresh(unclassified))
    unclassified[5] = 'ZZ'
    write_all(fd, fresh(unclassified))


wire_result = run_case('shape-diagnostics-without-audio-synthetic', wire_shapes)
assert wire_result['reports'] == 0 and wire_result['samples'] == 0 and wire_result['decodeErrors'] == 0, wire_result
assert wire_result['diagnostics']['wire'] == {
    'inspectedSelectedPackets': 5, 'validHexPackets': 4, 'completeVoiceCandidates': 2,
    'fragmentedVoiceCandidates': 1, 'aclContinuationCandidates': 1, 'voiceCandidatesOutsideATTLabel': 2}, wire_result
assert wire_result['diagnostics']['transport']['staleOrFutureTimestamps'] == 1, wire_result
assert not (Path(results[-1]['output']) / 'apple-voice.wav').exists(), 'shape-only observation emitted audio'

empty_result = run_case('empty-stream', lambda fd, fields: None)
assert empty_result['reports'] == 0 and empty_result['samples'] == 0 and empty_result['stopped'] == 'eof'
assert all(value == 0 for value in empty_result['diagnostics']['input'].values()), empty_result
assert all(value == 0 for value in empty_result['diagnostics']['transport'].values()), empty_result

oversized_result = run_case('oversized-unterminated-input', lambda fd, fields: write_all(fd, b'x' * 17000))
assert oversized_result['reports'] == 0 and oversized_result['samples'] == 0, oversized_result
assert oversized_result['stopped'] == 'oversized-line', oversized_result
assert oversized_result['diagnostics']['input']['oversizedBufferStops'] == 1, oversized_result
assert oversized_result['diagnostics']['input']['trailingIncompleteLines'] == 1, oversized_result
assert oversized_result['diagnostics']['transport']['lines'] == 0, oversized_result

for kind in ['symlink', 'nonempty', 'wrong-mode']:
    run_case('invalid-start-' + kind, lambda fd, fields: None, start_kind=kind)

(root / '.build/apple-voice-pipe-test.json').write_text(json.dumps({'synthetic': True, 'cases': results}, indent=2) + '\n')
print('PASS: delayed start, selected-device FIFO, privacy-safe diagnostics, 17 synthetic frames including dynamic ATT/ACL switches, shape-only diagnostics reject future/unknown/partial audio, EOF/oversize stops, invalid start rejection; no capture')
