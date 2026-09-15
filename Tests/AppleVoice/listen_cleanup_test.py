"""Cancel a synthetic listener and prove its decoder child is reaped."""
import errno
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='yaoban-listen-cancel-') as temporary:
    base = Path(temporary)
    folder = base / 'session'
    folder.mkdir(mode=0o700)
    os.mkfifo(folder / 'capture.pipe', 0o600)
    decoder = base / 'fake-decoder'
    decoder.write_text('#!/usr/bin/python3\nimport os, pathlib, signal, sys\n'
                       'pathlib.Path(sys.argv[2], "synthetic-child.pid").write_text(str(os.getpid()))\n'
                       'signal.pause()\n')
    decoder.chmod(0o700)
    harness = base / 'listener.py'
    harness.write_text('import importlib.util, pathlib, signal, sys\n'
        'spec=importlib.util.spec_from_file_location("capture",sys.argv[1])\n'
        'c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)\n'
        'c.OUTPUTS=pathlib.Path(sys.argv[2]);c.CONSUMER=pathlib.Path(sys.argv[3])\n'
        'def cancel(signum,frame):\n    raise KeyboardInterrupt\n'
        'signal.signal(signal.SIGTERM,cancel)\n'
        'try:c.listen(sys.argv[4])\n'
        'except KeyboardInterrupt:sys.exit(130)\n')
    process = subprocess.Popen(['/usr/bin/python3', '-I', str(harness), str(root / 'scripts/apple-voice-capture.py'),
                                str(base), str(decoder), str(folder)],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    writer = None
    child = None
    try:
        deadline = time.monotonic() + 5
        while writer is None:
            try:
                writer = os.open(folder / 'capture.pipe', os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
        pidfile = folder / 'synthetic-child.pid'
        while not pidfile.exists():
            assert process.poll() is None and time.monotonic() < deadline
            time.sleep(0.02)
        child = int(pidfile.read_text())
        process.terminate()
        process.communicate(timeout=4)
        assert process.returncode == 130
        try:
            os.kill(child, 0)
            raise AssertionError('decoder survived cancellation')
        except ProcessLookupError:
            child = None
    finally:
        if writer is not None:
            os.close(writer)
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=2)
        if child is not None:
            try: os.kill(child, signal.SIGKILL)
            except ProcessLookupError: pass
print('PASS: cancelled listener reaps its synthetic decoder; no Bluetooth or administrator access')
