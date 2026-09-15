"""Normal-user readiness protocol tests. No Apple tool or Bluetooth access."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capture', root / 'scripts/apple-voice-capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
assert os.geteuid() != 0


def write_marker(folder, name, value=None):
    fd = os.open(folder / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        if value is not None:
            stream.write(json.dumps(value).encode())


def await_file(path):
    deadline = time.monotonic() + 2
    while not path.exists():
        assert time.monotonic() < deadline, 'readiness did not arrive'
        time.sleep(0.01)


with tempfile.TemporaryDirectory(prefix='yaoban-readiness-') as temporary:
    base = Path(temporary)
    capture.OUTPUTS = base
    for scenario in ('delayed', 'no-consumer', 'no-start', 'device-no-longer-ready'):
        folder = base / scenario
        folder.mkdir(mode=0o700)
        completed, failures = [], []
        with capture.private_output(folder) as (directory, info):
            def wait():
                try:
                    capture.await_consumer_and_start(directory, info, 0.3, 0.3, 0.3)
                    completed.append(True)
                except RuntimeError as error:
                    failures.append(str(error))
            worker = threading.Thread(target=wait)
            worker.start()
            time.sleep(0.05)
            assert not (folder / 'armed.json').exists(), 'armed before consumer initialized'
            if scenario != 'no-consumer':
                write_marker(folder, 'consumer-ready.json', {'status': 'ready', 'capturing': False})
                await_file(folder / 'armed.json')
                assert not completed, 'capture permitted before user start'
                if scenario != 'no-start':
                    write_marker(folder, 'start.signal')
                    time.sleep(0.05)
                    assert not completed, 'capture permitted before device revalidation'
                    if scenario == 'delayed':
                        write_marker(folder, 'consumer-started.json', {'status': 'listening'})
            worker.join(timeout=2)
            assert not worker.is_alive()
            assert bool(completed) == (scenario == 'delayed'), (scenario, completed, failures)
            assert bool(failures) == (scenario != 'delayed')

    for kind in ('symlink', 'fifo', 'public', 'nonempty', 'oversized'):
        folder = base / kind
        folder.mkdir(mode=0o700)
        path = folder / 'start.signal'
        if kind == 'symlink':
            (folder / 'target').write_bytes(b'')
            path.symlink_to(folder / 'target')
        elif kind == 'fifo':
            os.mkfifo(path, 0o600)
        else:
            write_marker(folder, 'start.signal')
            if kind == 'public':
                path.chmod(0o644)
            if kind == 'nonempty':
                path.write_bytes(b'x')
            if kind == 'oversized':
                path.write_bytes(b'x' * 513)
        with capture.private_output(folder) as (directory, info):
            try:
                capture.wait_for_marker(directory, 'start.signal', info.st_uid, None, 0.1)
                raise AssertionError('invalid marker was accepted: ' + kind)
            except (OSError, RuntimeError):
                pass

    # Renaming the original directory cannot redirect the privileged file open.
    folder = base / 'pinned'
    folder.mkdir(mode=0o700)
    with capture.private_output(folder) as (directory, info):
        original = base / 'original'
        folder.rename(original)
        replacement = base / 'replacement'
        replacement.mkdir(mode=0o700)
        write_marker(replacement, 'start.signal')
        folder.symlink_to(replacement)
        try:
            capture.wait_for_marker(directory, 'start.signal', info.st_uid, None, 0.1)
            raise AssertionError('directory replacement redirected marker lookup')
        except RuntimeError:
            pass
        write_marker(original, 'start.signal')
        capture.wait_for_marker(directory, 'start.signal', info.st_uid, None, 0.1)

print('PASS: readiness before start, missing/failed consumer, start timeout, device revalidation, unsafe markers, pinned directory; no Bluetooth access')
