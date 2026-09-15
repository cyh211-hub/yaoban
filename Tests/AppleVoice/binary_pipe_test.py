"""Synthetic binary FIFO -> actual Opus -> WAV. Reads selected identity; no HCI/HID activation."""
import errno
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import wave

root = Path(__file__).resolve().parents[2]
script = root / 'scripts/apple-voice-capture.py'
fixture = (root / 'Tests/Fixtures/apple-packetlogger26-synthetic.tsv').read_text().splitlines()[-1].split('\t')
# The textual fixture has a reconstructed full ACL with the original first
# fragment length. Only its L2CAP PDU is reused; every binary header is rebuilt.
pdu = bytes.fromhex(fixture[5])[4:]
assert len(pdu) == 106


def record(kind, payload, micros=0):
    return struct.pack('>IIIB', len(payload) + 9, 1800000000, micros, kind) + payload


def acl(body, pb, micros=0):
    return record(3, struct.pack('<HH', 0x51 | (pb << 12), len(body)) + body, micros)


def run(name, include_connection=True, malformed=False):
    prepared = subprocess.run(['/usr/bin/python3', '-I', str(script), '--prepare', '--binary'],
                              capture_output=True, check=True)
    output = Path(json.loads(prepared.stdout)['output'])
    expected = json.loads((output / 'expected-device.json').read_text())
    peer = bytes.fromhex(expected['address'].replace(':', ''))[::-1]
    connection = record(1, bytes([0x3E, 19, 1, 0, 0x51, 0, 0, 0]) + peer + bytes(7))
    stream = (connection if include_connection else b'') + acl(pdu[:40], 2) + acl(pdu[40:], 1, 1000)
    if malformed:
        stream = b'\xff\xff\xff\xff' + stream
    process = subprocess.Popen(['/usr/bin/python3', '-I', str(script), '--listen', str(output), '--binary'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    writer = None
    try:
        deadline = time.monotonic() + 8
        while writer is None:
            try:
                writer = os.open(output / 'capture.pipe', os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                    raise
                time.sleep(.02)
        for marker in ['consumer-ready.json', 'consumer-started.json']:
            while not (output / marker).exists():
                assert time.monotonic() < deadline and process.poll() is None, 'consumer readiness failed'
                time.sleep(.02)
            if marker == 'consumer-ready.json':
                fd = os.open(output / 'start.signal', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.close(fd)
        for offset in range(0, len(stream), 17):
            os.write(writer, stream[offset:offset+17])
        os.close(writer); writer = None
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 0, 'consumer failed'
        result = json.loads(stdout)
        assert expected['address'].encode() not in stdout and expected['identity'].encode() not in stdout
        success = include_connection and not malformed
        assert result['samples'] == (960 if success else 0), result
        assert (output / 'binary-stream-ready.json').exists() == success
        assert (output / 'apple-voice.wav').exists() == success
        assert result['decodeErrors'] == 0 and result['rawTraceSaved'] is False
        if success:
            with wave.open(str(output / 'apple-voice.wav')) as audio:
                assert (audio.getnchannels(), audio.getframerate(), audio.getnframes()) == (1, 48000, 960)
        return {'case': name, 'samples': result['samples'], 'stopped': result['stopped'],
                'packetLog': result['diagnostics']['packetLog']}
    finally:
        if writer is not None:
            os.close(writer)
        if process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate()


results = [run('selected-fragmented-voice'), run('missing-connection', False), run('malformed-binary', True, True)]
(root / '.build/apple-voice-lab/binary-pipe-verification.json').write_text(json.dumps({
    'synthetic': True, 'captureStarted': False, 'activationSent': False, 'cases': results}, indent=2)+'\n')
print('PASS: binary FIFO, selected-device ready marker, fragmented Opus -> 960 PCM -> WAV; unbound/corrupt input rejected; no capture or activation')
