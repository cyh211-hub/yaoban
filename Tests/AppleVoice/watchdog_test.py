"""Exercise the independent guardian with synthetic processes as an ordinary user."""
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import time
from unittest.mock import patch

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capture', root / 'scripts/apple-voice-capture.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert os.geteuid() != 0

# Exercise watch_capture directly as well as through its fork below. A fork-only
# test could miss accidental mutation of the guardian's own os.environ.
environment_command = ['/usr/bin/python3', '-I', '-c',
    'import json,os,time; print(json.dumps({'
    '"tz":os.environ.get("TZ"),'
    '"formatted":time.strftime("%Y-%m-%dT%H:%M:%S%z",time.localtime(1704067200)),'
    '"sentinel":os.environ.get("YAOBAN_WATCHDOG_TEST_SENTINEL")}),flush=True)']
original_environment = os.environ.copy()
for parent_timezone in ('Asia/Shanghai', None):
    with patch.dict(os.environ, {'YAOBAN_WATCHDOG_TEST_SENTINEL': 'preserved'}):
        if parent_timezone is None:
            os.environ.pop('TZ', None)
        else:
            os.environ['TZ'] = parent_timezone
        parent_environment = os.environ.copy()
        output_read, output_write = os.pipe()
        life_read, life_write = os.pipe()
        status_read, status_write = os.pipe()
        try:
            module.watch_capture(environment_command, output_write, life_read, status_write, 1)
            payload = json.loads(os.read(output_read, 1024))
            result = json.loads(os.read(status_read, 2048))
            assert payload == {'tz': 'UTC', 'formatted': '2024-01-01T00:00:00+0000',
                               'sentinel': 'preserved'}, 'child environment was not normalized'
            assert result == {'stopped': 'tool-exited', 'exit': 0, 'diagnostic': 'none'}, result
            assert os.environ.copy() == parent_environment, 'parent environment changed'
        finally:
            # watch_capture owns and closes the other three pipe ends.
            for fd in (output_read, life_write, status_read):
                os.close(fd)
    assert os.environ.copy() == original_environment, 'test environment was not restored'

command = ['/usr/bin/python3', '-I', '-c',
           'import os,time; print(os.getpid(),flush=True); time.sleep(60)']

for seconds, parent_end in [(0.4, False), (20, True)]:
    started = time.monotonic()
    guardian, data, life, status = module.spawn_guardian(command, seconds)
    assert select.select([data], [], [], 3)[0], 'producer did not start'
    producer = int(os.read(data, 100))
    if parent_end:
        os.close(life)
    os.waitpid(guardian, 0)
    result = json.loads(os.read(status, 2048))
    assert result['stopped'] == ('parent-ended' if parent_end else 'deadline'), result
    assert time.monotonic() - started < 3
    try:
        os.kill(producer, 0)
        raise AssertionError('producer survived guardian cleanup')
    except ProcessLookupError:
        pass
    for fd in (data, status):
        os.close(fd)
    if not parent_end:
        os.close(life)

# Abrupt coordinator death must still close the lifeline. The guardian owns the
# producer, reaps it independently, and reports after the coordinator is gone.
read_fd, write_fd = os.pipe()
coordinator = os.fork()
if coordinator == 0:
    os.close(read_fd)
    guardian, data, life, status = module.spawn_guardian(command, 20)
    producer = int(os.read(data, 100))
    os.write(write_fd, str(producer).encode())
    os.kill(os.getpid(), signal.SIGKILL)
os.close(write_fd)
producer = int(os.read(read_fd, 100))
os.close(read_fd)
os.waitpid(coordinator, 0)
deadline = time.monotonic() + 3
gone = False
while time.monotonic() < deadline:
    try:
        os.kill(producer, 0)
    except ProcessLookupError:
        gone = True
        break
    time.sleep(0.05)
assert gone, 'producer survived abrupt coordinator death'
print('PASS: child UTC with inherited/unset parent TZ, UTC formatting, sentinel preservation, '
      'unchanged parent environment; watchdog deadline, parent EOF, abrupt parent death; no Bluetooth access')
