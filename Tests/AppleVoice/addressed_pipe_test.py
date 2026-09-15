"""Synthetic addressed FIFO -> actual Opus -> WAV. Reads selected identity; no HCI/HID activation."""
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


def run(name, include_connection=True, malformed=False, metadata_first=False, metadata_only=False):
    prepared = subprocess.run(['/usr/bin/python3', '-I', str(script), '--prepare', '--addressed'],
                              capture_output=True, check=True)
    output = Path(json.loads(prepared.stdout)['output'])
    expected = json.loads((output / 'expected-device.json').read_text())
    selected_address = expected['address'] if include_connection else '00:00:00:00:00:00'
    def text_line(raw, tick):
        # Deliberately unrelated to the host clock; only relative ordering is
        # meaningful for this fresh, bounded, address-annotated producer path.
        return ('\t'.join(['2026-09-13T08:00:00.'+tick+'Z', 'Synthetic receive label',
            selected_address, '0x0052' if malformed else '0x0051', 'RECV', raw.hex(' '), ''])+'\n').encode()
    stream = text_line(acl(pdu[:40], 2)[13:], '001') + text_line(acl(pdu[40:], 1, 1000)[13:], '002')
    process = subprocess.Popen(['/usr/bin/python3', '-I', str(script), '--listen', str(output), '--addressed'],
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
        if metadata_first or metadata_only:
            # Mirrors the failure's known category (selected source, rejected
            # transport) without pretending to reproduce its unsaved raw bytes.
            metadata = ('\t'.join(['2026-09-13T08:00:00.000Z', 'Synthetic status',
                selected_address, '----', 'RECV', '01 02', ''])+'\n').encode()
            os.write(writer, metadata)
            ready_deadline = time.monotonic() + 2
            while not (output / 'binary-stream-ready.json').exists():
                assert time.monotonic() < ready_deadline and process.poll() is None, 'selected metadata did not release source readiness'
                time.sleep(.01)
            assert not (output / 'apple-voice.wav').exists(), 'status metadata produced audio'
        if metadata_only:
            stream = b''
        for offset in range(0, len(stream), 17):
            os.write(writer, stream[offset:offset+17])
        os.close(writer); writer = None
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 0, 'consumer failed'
        result = json.loads(stdout)
        assert expected['address'].encode() not in stdout and expected['identity'].encode() not in stdout
        success = include_connection and not malformed and not metadata_only
        assert result['samples'] == (960 if success else 0), result
        assert (output / 'binary-stream-ready.json').exists() == include_connection
        assert (output / 'apple-voice.wav').exists() == success
        assert result['decodeErrors'] == 0 and result['rawTraceSaved'] is False
        if success:
            with wave.open(str(output / 'apple-voice.wav')) as audio:
                assert (audio.getnchannels(), audio.getframerate(), audio.getnframes()) == (1, 48000, 960)
        return {'case': name, 'samples': result['samples'], 'stopped': result['stopped'],
                'addressed': result['diagnostics']['addressed']}
    finally:
        if writer is not None:
            os.close(writer)
        if process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate()


results = [run('already-connected-fragmented-voice'), run('foreign-address', False), run('displayed-handle-mismatch', True, True),
           run('selected-status-before-voice', metadata_first=True), run('selected-status-only-no-audio', metadata_only=True)]
(root / '.build/apple-voice-lab/addressed-pipe-verification.json').write_text(json.dumps({
    'synthetic': True, 'captureStarted': False, 'activationSent': False, 'cases': results}, indent=2)+'\n')
print('PASS: addressed FIFO needs no connection event; address/handle checks, fragmented Opus -> 960 PCM -> WAV, selected-device readiness; no capture or activation')
