"""Synthetic FIFO startup ordering checks; no Bluetooth or administrator calls."""
import importlib.util
import os
from pathlib import Path
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capture', root / 'scripts/apple-voice-capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)

with tempfile.TemporaryDirectory(prefix='yaoban-fifo-start-') as temporary:
    folder = Path(temporary)
    directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.mkfifo(folder / 'capture.pipe', 0o600)
        received = []
        def delayed_reader():
            time.sleep(0.15)
            fd = os.open(folder / 'capture.pipe', os.O_RDONLY)
            received.append(os.read(fd, 1))
            os.close(fd)
        reader = threading.Thread(target=delayed_reader)
        reader.start()
        writer = capture.open_consumer_pipe(directory, os.getuid(), seconds=1)
        os.write(writer, b'x')
        os.close(writer)
        reader.join(timeout=2)
        assert received == [b'x'] and not reader.is_alive()

        started = time.monotonic()
        try:
            capture.open_consumer_pipe(directory, os.getuid(), seconds=0.1)
            raise AssertionError('missing reader accepted')
        except RuntimeError:
            assert time.monotonic() - started < 1

        for kind in ('regular', 'symlink', 'public'):
            (folder / 'capture.pipe').unlink()
            if kind == 'regular':
                (folder / 'capture.pipe').write_bytes(b'')
                (folder / 'capture.pipe').chmod(0o600)
            elif kind == 'symlink':
                os.mkfifo(folder / 'target.pipe', 0o600)
                (folder / 'capture.pipe').symlink_to(folder / 'target.pipe')
            else:
                os.mkfifo(folder / 'capture.pipe', 0o644)
            try:
                capture.open_consumer_pipe(directory, os.getuid(), seconds=0.1)
                raise AssertionError('invalid FIFO accepted: ' + kind)
            except RuntimeError:
                pass

        (folder / 'capture.pipe').unlink()
        os.mkfifo(folder / 'capture.pipe', 0o600)
        def replace_pipe():
            time.sleep(0.05)
            (folder / 'capture.pipe').rename(folder / 'old.pipe')
            os.mkfifo(folder / 'capture.pipe', 0o600)
        replacement = threading.Thread(target=replace_pipe)
        replacement.start()
        try:
            capture.open_consumer_pipe(directory, os.getuid(), seconds=0.3)
            raise AssertionError('replacement accepted')
        except RuntimeError as error:
            assert str(error) == 'Capture pipe replaced'
        replacement.join(timeout=1)
    finally:
        os.close(directory)
print('PASS: delayed FIFO reader, bounded absence, regular/symlink/public rejection, inode replacement; no capture')
