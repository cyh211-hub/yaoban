#!/usr/bin/python3
"""Fixed-path v0.10 upgrade and rollback operations for Installer only."""
import importlib.util
import grp
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile

SUPPORT = Path('/Library/Application Support/YaobanVoice')
BACKUP = Path('/Library/Application Support/YaobanUpgrade0108Restore')
APP = Path('/Applications/遥伴.app')
PLIST = Path('/Library/LaunchDaemons/local.moss.YaobanAppleVoice.plist')
HAL = Path('/Library/Audio/Plug-Ins/HAL/MiRemoteMic.driver')
APPLE = Path('/Applications/PacketLogger.app')
LEGACY_APPLE = SUPPORT / 'PacketLogger.app'
VOICE_SOCKET = Path('/var/run/yaoban-apple-voice/control.sock')
SETTINGS = {'按键设置.json', '按键设置.backup.json', '按键设置-升级长按前.json',
            '按键设置-型号隔离升级前.json', '遥控器绑定.json', 'mapping-restore.json',
            'audio-input-restore.json', '设备库.json', '设备库.backup.json',
            '设备模式事务.json'}
MAX_SETTING_BYTES = 16 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
OPEN_DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)
OPEN_REGULAR = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)


def run(args):
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL, timeout=90)


def safe_directory(path, create=False, mode=0o755, uid=0):
    if not path.exists() and not path.is_symlink() and create:
        path.mkdir(mode=mode)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
        raise RuntimeError('unsafe-directory: ' + str(path))


def safe_private_directory(path, uid=0):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise RuntimeError('unsafe-private-directory: ' + str(path))


def validate_system_parent(path, info, admin_gid=None):
    """Apply the sole group-writable system-directory exception used by rollback."""
    if Path(path) != Path('/Applications'):
        raise RuntimeError('unexpected-system-parent: ' + str(path))
    if admin_gid is None:
        admin_gid = grp.getgrnam('admin').gr_gid
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_gid != admin_gid
            or stat.S_IMODE(info.st_mode) != 0o775):
        raise RuntimeError('unsafe-applications-directory')


def open_applications_directory():
    root_fd = os.open('/', OPEN_DIRECTORY)
    try:
        applications_fd = os.open('Applications', OPEN_DIRECTORY, dir_fd=root_fd)
    finally:
        os.close(root_fd)
    try:
        validate_system_parent(Path('/Applications'), os.fstat(applications_fd))
        return applications_fd
    except Exception:
        os.close(applications_fd)
        raise


def inspect_tree(path):
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError('unsafe-bundle')
    base = path.resolve()
    for parent, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            entry = Path(parent) / name
            info = entry.lstat()
            if entry.is_symlink():
                target = entry.resolve()
                if target != base and base not in target.parents:
                    raise RuntimeError('external-bundle-symlink')
            elif not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                raise RuntimeError('special-bundle-file')
            elif stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
                raise RuntimeError('hardlinked-bundle-file')


def normalize_tree(path, uid=0):
    inspect_tree(path)
    for parent, dirs, files in os.walk(path, followlinks=False):
        for entry in [Path(parent)] + [Path(parent) / name for name in files + dirs]:
            os.lchown(entry, uid, 0)
            if not entry.is_symlink():
                entry.chmod(entry.stat().st_mode & 0o755)


def safe_regular(path, uid=0):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1 or info.st_mode & 0o022:
        raise RuntimeError('unsafe-file: ' + str(path))


def stop_service():
    if PLIST.exists() and not PLIST.is_symlink():
        subprocess.run(['/bin/launchctl', 'bootout', 'system', str(PLIST)], stdin=subprocess.DEVNULL, timeout=90, check=False)


def start_service_if_present():
    if PLIST.exists() and not PLIST.is_symlink():
        safe_regular(PLIST)
        run(['/bin/launchctl', 'bootstrap', 'system', str(PLIST)])


def packetlogger_if_available():
    for candidate in (APPLE, LEGACY_APPLE):
        if not candidate.exists() and not candidate.is_symlink():
            continue
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=anchor apple', str(candidate)])
        inspect_tree(candidate)
        return candidate
    return None


def remove_stale_voice_socket():
    if not VOICE_SOCKET.exists() and not VOICE_SOCKET.is_symlink():
        return
    info = VOICE_SOCKET.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != 0:
        raise RuntimeError('unsafe-voice-socket')
    VOICE_SOCKET.unlink()


def recover_trace():
    state = SUPPORT / 'trace-state.plist'
    if not state.exists():
        return
    safe_directory(SUPPORT)
    for name in ('apple-voice-service.py', 'apple_voice_binary.py', 'trace-state.plist'):
        safe_regular(SUPPORT / name)
    service_spec = importlib.util.spec_from_file_location('yaoban_voice_service', SUPPORT / 'apple-voice-service.py')
    service = importlib.util.module_from_spec(service_spec); service_spec.loader.exec_module(service)
    binary_spec = importlib.util.spec_from_file_location('yaoban_voice_binary', SUPPORT / 'apple_voice_binary.py')
    binary = importlib.util.module_from_spec(binary_spec); binary_spec.loader.exec_module(binary)
    fd = service.RecoveryPreferences(binary.SystemTracePreferences()).acquire()
    os.close(fd)


def require_quit():
    if subprocess.run(['/usr/bin/pgrep', '-x', 'MiRemoteLab'], capture_output=True).returncode == 0:
        raise RuntimeError('请先从菜单栏退出遥伴，再运行安装包。')


def copy_root_tree(source, destination):
    inspect_tree(source)
    shutil.copytree(source, destination, symlinks=True)
    normalize_tree(destination)


def copy_root_file(source, destination):
    safe_regular(source)
    shutil.copyfile(source, destination)
    os.chown(destination, 0, 0, follow_symlinks=False)
    destination.chmod(source.stat().st_mode & 0o755)


def console_user():
    uid = os.stat('/dev/console').st_uid
    if uid < 501:
        raise RuntimeError('请登录桌面用户后再安装')
    return uid, Path(pwd.getpwuid(uid).pw_dir)


def allowed_setting(name):
    return name in SETTINGS or re.fullmatch(
        r'mapping-restore-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json',
        name, re.IGNORECASE) is not None


def _safe_component(name):
    if not name or name in ('.', '..') or '/' in name or '\0' in name:
        raise RuntimeError('unsafe-file-name')


def _safe_directory_info(info, uid):
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, uid):
        return False
    if info.st_mode & 0o022:
        return info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
    return True


def open_directory_chain(path, uid):
    """Open an absolute directory without following a link in any component."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise RuntimeError('unsafe-directory-path: ' + str(path))
    fd = os.open('/', OPEN_DIRECTORY)
    try:
        for component in path.parts[1:]:
            _safe_component(component)
            next_fd = os.open(component, OPEN_DIRECTORY, dir_fd=fd)
            os.close(fd); fd = next_fd
            if not _safe_directory_info(os.fstat(fd), uid):
                raise RuntimeError('unsafe-directory: ' + str(path))
        if os.fstat(fd).st_uid != uid:
            raise RuntimeError('unsafe-directory-owner: ' + str(path))
        return fd
    except Exception:
        os.close(fd)
        raise


def open_regular_at(directory_fd, name, uid, maximum=MAX_SETTING_BYTES):
    _safe_component(name)
    fd = os.open(name, OPEN_REGULAR, dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1
                or info.st_mode & 0o022 or info.st_size > maximum):
            raise RuntimeError('unsafe-file: ' + name)
        return fd
    except Exception:
        os.close(fd)
        raise


def _copy_bounded(source_fd, destination_fd, maximum):
    remaining = maximum
    while True:
        chunk = os.read(source_fd, min(1024 * 1024, remaining + 1))
        if not chunk:
            return
        if len(chunk) > remaining:
            raise RuntimeError('file-too-large')
        view = memoryview(chunk)
        while view:
            written = os.write(destination_fd, view)
            view = view[written:]
        remaining -= len(chunk)


def atomic_copy_at(source_fd, destination_fd, name, uid, gid, mode=0o600,
                   maximum=MAX_SETTING_BYTES, temporary_names=None):
    """Copy an already-pinned source to a new fd, then rename within a pinned directory."""
    _safe_component(name)
    temporary = '.v010-' + secrets.token_hex(12)
    out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                  getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0),
                  0o600, dir_fd=destination_fd)
    try:
        _copy_bounded(source_fd, out, maximum)
        os.fchown(out, uid, gid)
        os.fchmod(out, mode)
        os.fsync(out)
    except Exception:
        os.close(out)
        os.unlink(temporary, dir_fd=destination_fd)
        raise
    os.close(out)
    if temporary_names is not None:
        temporary_names[name] = temporary
    else:
        os.replace(temporary, name, src_dir_fd=destination_fd, dst_dir_fd=destination_fd)


def read_regular_at(directory_fd, name, uid, maximum=MAX_MANIFEST_BYTES):
    fd = open_regular_at(directory_fd, name, uid, maximum)
    try:
        chunks = []
        remaining = maximum
        while True:
            chunk = os.read(fd, min(65536, remaining + 1))
            if not chunk:
                return b''.join(chunks)
            if len(chunk) > remaining:
                raise RuntimeError('file-too-large: ' + name)
            chunks.append(chunk); remaining -= len(chunk)
    finally:
        os.close(fd)


def backup_user_settings(uid, home, backup=BACKUP):
    backup_fd = open_directory_chain(backup, 0)
    data_fd = None
    try:
        os.mkdir('user', mode=0o700, dir_fd=backup_fd)
        data_fd = os.open('user', OPEN_DIRECTORY, dir_fd=backup_fd)
        manifest = {'uid': uid, 'files': [], 'preferences': False}
        directory = home / 'Library/Application Support/MiRemoteLab'
        try:
            user_fd = open_directory_chain(directory, uid)
        except FileNotFoundError:
            user_fd = None
        if user_fd is not None:
            try:
                for name in os.listdir(user_fd):
                    if allowed_setting(name):
                        source_fd = open_regular_at(user_fd, name, uid)
                        try:
                            atomic_copy_at(source_fd, data_fd, name, 0, 0)
                        finally:
                            os.close(source_fd)
                        manifest['files'].append(name)
            finally:
                os.close(user_fd)
        try:
            preferences_fd = open_directory_chain(home / 'Library/Preferences', uid)
        except FileNotFoundError:
            preferences_fd = None
        if preferences_fd is not None:
            try:
                try:
                    source_fd = open_regular_at(preferences_fd, 'local.moss.MiRemoteLab.plist', uid)
                except FileNotFoundError:
                    pass
                else:
                    try:
                        atomic_copy_at(source_fd, data_fd, 'local.moss.MiRemoteLab.plist', 0, 0)
                    finally:
                        os.close(source_fd)
                    manifest['preferences'] = True
            finally:
                os.close(preferences_fd)
        encoded = (json.dumps(manifest, sort_keys=True) + '\n').encode()
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, encoded); os.close(write_fd); write_fd = -1
            atomic_copy_at(read_fd, backup_fd, 'user-settings.json', 0, 0,
                           maximum=MAX_MANIFEST_BYTES)
        finally:
            os.close(read_fd)
            if write_fd >= 0: os.close(write_fd)
    finally:
        if data_fd is not None: os.close(data_fd)
        os.close(backup_fd)


def _validated_user_manifest(backup_fd):
    raw = read_regular_at(backup_fd, 'user-settings.json', 0)
    manifest = json.loads(raw.decode('utf-8'))
    if set(manifest) != {'uid', 'files', 'preferences'}:
        raise RuntimeError('invalid-user-manifest')
    uid, files, preferences = manifest['uid'], manifest['files'], manifest['preferences']
    if not isinstance(uid, int) or uid < 501 or isinstance(uid, bool):
        raise RuntimeError('invalid-user-manifest-uid')
    if not isinstance(files, list) or len(files) != len(set(files)):
        raise RuntimeError('invalid-user-manifest-files')
    if any(not isinstance(name, str) or not allowed_setting(name) for name in files):
        raise RuntimeError('invalid-user-manifest-file')
    if not isinstance(preferences, bool):
        raise RuntimeError('invalid-user-manifest-preferences')
    return manifest


def prepare_user_restore(uid, home):
    """Validate and pin every user/backup directory needed by rollback."""
    backup_fd = open_directory_chain(BACKUP, 0)
    data_fd = None
    source_fds = {}
    settings_fd = preferences_fd = None
    try:
        if os.fstat(backup_fd).st_mode & 0o077:
            raise RuntimeError('unsafe-private-backup-directory')
        manifest = _validated_user_manifest(backup_fd)
        if uid != manifest['uid']:
            raise RuntimeError('回退必须由原安装桌面用户登录后执行')
        data_fd = os.open('user', OPEN_DIRECTORY, dir_fd=backup_fd)
        info = os.fstat(data_fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            raise RuntimeError('unsafe-backup-user-directory')
        expected = set(manifest['files'])
        if manifest['preferences']:
            expected.add('local.moss.MiRemoteLab.plist')
        if set(os.listdir(data_fd)) != expected:
            raise RuntimeError('unexpected-backup-user-file')
        for name in expected:
            source_fds[name] = open_regular_at(data_fd, name, 0)
        try:
            settings_fd = open_directory_chain(home / 'Library/Application Support/MiRemoteLab', uid)
        except FileNotFoundError:
            if manifest['files']:
                raise RuntimeError('缺少原设置目录，拒绝在用户路径中新建回退文件')
        preferences_fd = open_directory_chain(home / 'Library/Preferences', uid)
        return {'manifest': manifest, 'backup_fd': backup_fd, 'data_fd': data_fd,
                'source_fds': source_fds, 'settings_fd': settings_fd,
                'preferences_fd': preferences_fd, 'uid': uid}
    except Exception:
        for fd in source_fds.values(): os.close(fd)
        for fd in (settings_fd, preferences_fd, data_fd, backup_fd):
            if fd is not None: os.close(fd)
        raise


def close_user_restore(plan):
    for fd in plan.get('source_fds', {}).values(): os.close(fd)
    for key in ('settings_fd', 'preferences_fd', 'data_fd', 'backup_fd'):
        fd = plan.get(key)
        if fd is not None: os.close(fd)


def _entry_exists_at(directory_fd, name):
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _require_replaceable_at(directory_fd, name):
    info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
        raise RuntimeError('unsafe-user-target: ' + name)


def restore_user_settings(plan):
    """Stage all writes, then rename and unlink only within pinned user directories."""
    manifest = plan['manifest']; uid = plan['uid']; staged = []; actions = []
    try:
        if plan['settings_fd'] is not None:
            for name in manifest['files']:
                temporary = {}
                os.lseek(plan['source_fds'][name], 0, os.SEEK_SET)
                atomic_copy_at(plan['source_fds'][name], plan['settings_fd'], name,
                               uid, 0, temporary_names=temporary)
                staged.append((plan['settings_fd'], temporary[name], name))
        if manifest['preferences']:
            name = 'local.moss.MiRemoteLab.plist'; temporary = {}
            os.lseek(plan['source_fds'][name], 0, os.SEEK_SET)
            atomic_copy_at(plan['source_fds'][name], plan['preferences_fd'], name,
                           uid, 0, temporary_names=temporary)
            staged.append((plan['preferences_fd'], temporary[name], name))
    except Exception:
        for directory_fd, temporary, _ in staged:
            try: os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError: pass
        raise
    removals = []
    if plan['settings_fd'] is not None:
        retained = set(manifest['files'])
        removals.extend((plan['settings_fd'], name) for name in os.listdir(plan['settings_fd'])
                        if allowed_setting(name) and name not in retained)
    if not manifest['preferences'] and _entry_exists_at(plan['preferences_fd'], 'local.moss.MiRemoteLab.plist'):
        removals.append((plan['preferences_fd'], 'local.moss.MiRemoteLab.plist'))
    try:
        for directory_fd, temporary, name in staged:
            quarantine = '.v010-previous-' + secrets.token_hex(12)
            had_previous = _entry_exists_at(directory_fd, name)
            if had_previous:
                _require_replaceable_at(directory_fd, name)
                os.replace(name, quarantine, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
            try:
                os.replace(temporary, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
            except Exception:
                if had_previous:
                    os.replace(quarantine, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                raise
            actions.append(('replace', directory_fd, name, quarantine, had_previous))
        for directory_fd, name in removals:
            if not _entry_exists_at(directory_fd, name):
                continue
            _require_replaceable_at(directory_fd, name)
            quarantine = '.v010-removed-' + secrets.token_hex(12)
            os.replace(name, quarantine, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
            actions.append(('remove', directory_fd, name, quarantine, True))
        for directory_fd, _, name in staged:
            check_fd = open_regular_at(directory_fd, name, uid)
            os.close(check_fd)
    except Exception:
        for kind, directory_fd, name, quarantine, had_previous in reversed(actions):
            if kind == 'replace' and _entry_exists_at(directory_fd, name):
                _require_replaceable_at(directory_fd, name)
                os.unlink(name, dir_fd=directory_fd)
            if had_previous:
                os.replace(quarantine, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        for directory_fd, temporary, _ in staged:
            if _entry_exists_at(directory_fd, temporary):
                _require_replaceable_at(directory_fd, temporary)
                os.unlink(temporary, dir_fd=directory_fd)
        raise
    for _, directory_fd, _, quarantine, had_previous in actions:
        if had_previous:
            try:
                _require_replaceable_at(directory_fd, quarantine)
                os.unlink(quarantine, dir_fd=directory_fd)
            except (FileNotFoundError, OSError, RuntimeError):
                pass


def backup_previous(uid=None, home=None):
    if BACKUP.exists() or BACKUP.is_symlink():
        raise RuntimeError('已有 v0.10.8 回退备份；请先使用回退包或人工保留后再继续。')
    if uid is None or home is None: uid, home = console_user()
    safe_directory(BACKUP.parent, uid=0)
    temporary = Path(tempfile.mkdtemp(prefix='.YaobanUpgrade0108Restore-', dir=BACKUP.parent))
    try:
        state = {'app': False, 'support': False, 'plist': False, 'hal': False}
        if APP.exists() or APP.is_symlink(): copy_root_tree(APP, temporary / '遥伴.app'); state['app'] = True
        if SUPPORT.exists() or SUPPORT.is_symlink(): copy_root_tree(SUPPORT, temporary / 'YaobanVoice'); state['support'] = True
        if PLIST.exists() or PLIST.is_symlink(): copy_root_file(PLIST, temporary / 'YaobanAppleVoice.plist'); state['plist'] = True
        if HAL.exists() or HAL.is_symlink(): copy_root_tree(HAL, temporary / 'MiRemoteMic.driver'); state['hal'] = True
        backup_user_settings(uid, home, temporary)
        manifest = temporary / 'manifest.json'
        manifest.write_text(json.dumps(state, sort_keys=True) + '\n'); manifest.chmod(0o600)
        os.replace(temporary, BACKUP)
    except Exception:
        if temporary.exists(): shutil.rmtree(temporary)
        raise


def _validated_state():
    safe_private_directory(BACKUP, uid=0)
    backup_fd = open_directory_chain(BACKUP, 0)
    try: state = json.loads(read_regular_at(backup_fd, 'manifest.json', 0).decode('utf-8'))
    finally: os.close(backup_fd)
    if set(state) != {'app', 'support', 'plist', 'hal'} or any(type(value) is not bool for value in state.values()):
        raise RuntimeError('invalid-rollback-manifest')
    entries = {'app': ('遥伴.app', True), 'support': ('YaobanVoice', True),
               'plist': ('YaobanAppleVoice.plist', False), 'hal': ('MiRemoteMic.driver', True)}
    for key, (name, is_tree) in entries.items():
        source = BACKUP / name
        if state[key]: inspect_tree(source) if is_tree else safe_regular(source)
        elif source.exists() or source.is_symlink(): raise RuntimeError('unexpected-rollback-backup: ' + name)
    return state


def _validate_root_target_at(directory_fd, name, is_tree):
    flags = OPEN_DIRECTORY if is_tree else OPEN_REGULAR
    fd = os.open(name, flags, dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        expected = stat.S_ISDIR(info.st_mode) if is_tree else stat.S_ISREG(info.st_mode)
        if not expected or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError('unsafe-installed-target: ' + name)
        if not is_tree and info.st_nlink != 1:
            raise RuntimeError('hardlinked-installed-target: ' + name)
    finally:
        os.close(fd)


def _stage_application_restore(source, present):
    applications_fd = open_applications_directory()
    private_stage = BACKUP / ('.rollback-app-' + secrets.token_hex(12))
    stage_fd = None
    try:
        private_stage.mkdir(mode=0o700)
        safe_private_directory(private_stage, uid=0)
        if present:
            copy_root_tree(source, private_stage / 'replacement')
        had_current = _entry_exists_at(applications_fd, APP.name)
        if had_current:
            _validate_root_target_at(applications_fd, APP.name, True)
        stage_fd = open_directory_chain(private_stage, 0)
        return {'destination': APP, 'replacement': 'replacement' if present else None,
                'quarantine': 'current', 'had_current': had_current, 'committed': False,
                'secure_application': True, 'destination_fd': applications_fd,
                'stage_fd': stage_fd, 'private_stage': private_stage}
    except Exception:
        if stage_fd is not None: os.close(stage_fd)
        os.close(applications_fd)
        if private_stage.exists(): shutil.rmtree(private_stage)
        raise


def stage_system_restore(state):
    entries = [(APP, BACKUP / '遥伴.app', state['app'], True),
               (SUPPORT, BACKUP / 'YaobanVoice', state['support'], True),
               (PLIST, BACKUP / 'YaobanAppleVoice.plist', state['plist'], False),
               (HAL, BACKUP / 'MiRemoteMic.driver', state['hal'], True)]
    staged = []
    try:
        for destination, source, present, is_tree in entries:
            if destination == APP:
                staged.append(_stage_application_restore(source, present))
                continue
            safe_directory(destination.parent, uid=0)
            if destination.exists() or destination.is_symlink():
                inspect_tree(destination) if is_tree else safe_regular(destination)
            replacement = None
            if present:
                replacement = destination.parent / ('.v010-restore-' + secrets.token_hex(12))
            item = {'destination': destination, 'replacement': replacement,
                    'quarantine': destination.parent / ('.v010-current-' + secrets.token_hex(12)),
                    'had_current': destination.exists() or destination.is_symlink(), 'committed': False}
            staged.append(item)
            if present:
                copy_root_tree(source, replacement) if is_tree else copy_root_file(source, replacement)
        return staged
    except Exception:
        discard_system_restore(staged)
        raise


def commit_system_restore(staged):
    try:
        for item in staged:
            if item.get('secure_application'):
                destination = APP.name
                if item['had_current']:
                    os.replace(destination, item['quarantine'],
                               src_dir_fd=item['destination_fd'], dst_dir_fd=item['stage_fd'])
                try:
                    if item['replacement'] is not None:
                        os.replace(item['replacement'], destination,
                                   src_dir_fd=item['stage_fd'], dst_dir_fd=item['destination_fd'])
                except Exception:
                    if item['had_current']:
                        os.replace(item['quarantine'], destination,
                                   src_dir_fd=item['stage_fd'], dst_dir_fd=item['destination_fd'])
                    raise
                item['committed'] = True
                continue
            destination = item['destination']; replacement = item['replacement']
            if item['had_current']: os.replace(destination, item['quarantine'])
            try:
                if replacement is not None: os.replace(replacement, destination)
            except Exception:
                if item['had_current']: os.replace(item['quarantine'], destination)
                raise
            item['committed'] = True
    except Exception:
        undo_system_restore(staged)
        raise


def undo_system_restore(staged):
    for item in reversed(staged):
        if not item['committed']: continue
        if item.get('secure_application'):
            destination = APP.name
            if item['replacement'] is not None and _entry_exists_at(item['destination_fd'], destination):
                os.replace(destination, item['replacement'],
                           src_dir_fd=item['destination_fd'], dst_dir_fd=item['stage_fd'])
            if item['had_current']:
                os.replace(item['quarantine'], destination,
                           src_dir_fd=item['stage_fd'], dst_dir_fd=item['destination_fd'])
            item['committed'] = False
            continue
        destination = item['destination']
        if destination.exists() or destination.is_symlink(): os.replace(destination, item['replacement'])
        if item['had_current']: os.replace(item['quarantine'], destination)
        item['committed'] = False


def finish_system_restore(staged):
    for item in staged:
        if item.get('secure_application'):
            os.close(item['destination_fd']); os.close(item['stage_fd'])
            shutil.rmtree(item['private_stage'])
            continue
        quarantine = item['quarantine']
        if item['had_current'] and (quarantine.exists() or quarantine.is_symlink()):
            shutil.rmtree(quarantine) if quarantine.is_dir() and not quarantine.is_symlink() else quarantine.unlink()


def discard_system_restore(staged):
    for item in staged:
        if item.get('secure_application'):
            os.close(item['destination_fd']); os.close(item['stage_fd'])
            if item['private_stage'].exists(): shutil.rmtree(item['private_stage'])
            continue
        for candidate in (item['replacement'], item['quarantine']):
            if candidate is not None and (candidate.exists() or candidate.is_symlink()):
                shutil.rmtree(candidate) if candidate.is_dir() and not candidate.is_symlink() else candidate.unlink()


def clear_completed_backup():
    safe_private_directory(BACKUP, uid=0)
    archive = BACKUP.parent / ('.YaobanUpgrade0108Restore-completed-' + secrets.token_hex(12))
    os.replace(BACKUP, archive)
    shutil.rmtree(archive)


def preinstall():
    if sys.version_info < (3, 9): raise RuntimeError('Python 3.9 required')
    require_quit()
    # PacketLogger is optional. It enables Siri Remote voice, but its absence
    # must not block the app, buttons, touch surface or other remote models.
    packetlogger_if_available()
    safe_directory(Path('/Library/Application Support'))
    safe_directory(Path('/Library/LaunchDaemons'))
    safe_directory(Path('/Library/Audio/Plug-Ins/HAL'))
    stop_service()
    try:
        recover_trace(); backup_previous()
    except Exception:
        start_service_if_present()
        raise


def postinstall():
    safe_directory(SUPPORT)
    config = json.loads((SUPPORT / 'client-template.json').read_text())
    uid, _ = console_user(); config['uid'] = uid
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=' + config['requirement'], str(APP)])
    with tempfile.NamedTemporaryFile(mode='w', prefix='.client-', dir=SUPPORT, delete=False) as stream:
        json.dump(config, stream); stream.flush(); os.fsync(stream.fileno()); temporary = stream.name
    os.chmod(temporary, 0o600); os.replace(temporary, SUPPORT / 'client.json')
    safe_regular(PLIST)
    os.chown(PLIST, 0, 0, follow_symlinks=False)
    PLIST.chmod(0o644)
    run(['/usr/bin/codesign', '--verify', '--strict', str(HAL)])
    if packetlogger_if_available() is not None:
        run(['/bin/launchctl', 'bootstrap', 'system', str(PLIST)])
    else:
        remove_stale_voice_socket()
    subprocess.run(['/usr/bin/killall', 'coreaudiod'], stdin=subprocess.DEVNULL, timeout=30, check=False)


def rollback():
    require_quit()
    state = _validated_state()
    uid, home = console_user()
    user_plan = prepare_user_restore(uid, home)
    try:
        staged = stage_system_restore(state)
        try:
            stop_service(); recover_trace()
            commit_system_restore(staged)
        except Exception:
            discard_system_restore(staged)
            start_service_if_present()
            raise
        try:
            restore_user_settings(user_plan)
        except Exception:
            undo_system_restore(staged)
            discard_system_restore(staged)
            start_service_if_present()
            raise
        if state['hal']:
            run(['/usr/bin/codesign', '--verify', '--strict', str(HAL)])
            subprocess.run(['/usr/bin/killall', 'coreaudiod'], stdin=subprocess.DEVNULL, timeout=30, check=False)
        if state['plist']: start_service_if_present()
        finish_system_restore(staged)
        clear_completed_backup()
    finally:
        close_user_restore(user_plan)


if __name__ == '__main__':
    if os.geteuid() != 0: raise SystemExit('installer-root-required')
    if len(sys.argv) != 2 or sys.argv[1] not in ('preinstall', 'postinstall', 'rollback'): raise SystemExit(2)
    globals()[sys.argv[1]]()
