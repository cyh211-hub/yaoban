"""Offline behavioral checks for the v0.10 candidate and rollback packager."""
import importlib.util
import json
from pathlib import Path
import os
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


v010 = load('v010_install_support', ROOT / 'packaging/v010/install-support.py')
packager = load('v010_packager', ROOT / 'scripts/package-v010.py')


class V010PackagingTests(unittest.TestCase):
    def test_copy_root_file_copies_bytes_mode_and_sets_root_owner_without_following_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source.plist'
            destination = root / 'destination.plist'
            source.write_bytes(b'launch-daemon-payload')
            source.chmod(0o751)
            real_safe_regular = v010.safe_regular

            def validate_for_test_user(path):
                return real_safe_regular(path, uid=os.getuid())

            with mock.patch.object(v010, 'safe_regular', side_effect=validate_for_test_user), \
                    mock.patch.object(v010.os, 'chown') as chown:
                v010.copy_root_file(source, destination)

            self.assertEqual(b'launch-daemon-payload', destination.read_bytes())
            self.assertEqual(0o751, stat.S_IMODE(destination.stat().st_mode))
            chown.assert_called_once_with(destination, 0, 0, follow_symlinks=False)

    def test_postinstall_writes_client_config_and_prepares_service_in_isolated_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            support = root / 'Application Support' / 'YaobanVoice'
            support.mkdir(parents=True)
            support.chmod(0o755)
            app = root / '遥伴.app'
            plist = root / 'local.moss.YaobanAppleVoice.plist'
            hal = root / 'MiRemoteMic.driver'
            template = {'requirement': 'identifier "local.test.app"', 'existing': 'value'}
            (support / 'client-template.json').write_text(json.dumps(template))
            plist.write_text('plist payload')
            plist.chmod(0o600)
            real_safe_directory = v010.safe_directory
            real_safe_regular = v010.safe_regular

            def validate_directory_for_test_user(path, **kwargs):
                return real_safe_directory(path, uid=os.getuid(), **kwargs)

            def validate_file_for_test_user(path, **kwargs):
                return real_safe_regular(path, uid=os.getuid(), **kwargs)

            with mock.patch.multiple(v010, SUPPORT=support, APP=app, PLIST=plist, HAL=hal), \
                    mock.patch.object(v010, 'safe_directory', side_effect=validate_directory_for_test_user), \
                    mock.patch.object(v010, 'safe_regular', side_effect=validate_file_for_test_user), \
                    mock.patch.object(v010, 'console_user', return_value=(501, root / 'Users/test')), \
                    mock.patch.object(v010, 'run') as run, \
                    mock.patch.object(v010.os, 'chown') as chown, \
                    mock.patch.object(v010.subprocess, 'run') as subprocess_run:
                v010.postinstall()

            client = support / 'client.json'
            self.assertEqual({**template, 'uid': 501}, json.loads(client.read_text()))
            self.assertEqual(0o600, stat.S_IMODE(client.stat().st_mode))
            self.assertEqual(0o644, stat.S_IMODE(plist.stat().st_mode))
            chown.assert_called_once_with(plist, 0, 0, follow_symlinks=False)
            run.assert_has_calls([
                mock.call(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                           '-R=' + template['requirement'], str(app)]),
                mock.call(['/usr/bin/codesign', '--verify', '--strict', str(hal)]),
                mock.call(['/bin/launchctl', 'bootstrap', 'system', str(plist)]),
            ])
            self.assertEqual(3, run.call_count)
            subprocess_run.assert_called_once_with(
                ['/usr/bin/killall', 'coreaudiod'], stdin=v010.subprocess.DEVNULL,
                timeout=30, check=False)

    def test_tree_rejects_external_links_and_hardlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'bundle'; root.mkdir(); (root / 'outside').symlink_to('/etc')
            with self.assertRaises(RuntimeError): v010.inspect_tree(root)
            (root / 'outside').unlink(); (root / 'one').write_bytes(b'x'); os.link(root / 'one', root / 'two')
            with self.assertRaises(RuntimeError): v010.inspect_tree(root)

    def test_settings_allowlist_is_bounded_and_includes_model_migration_backup(self):
        self.assertTrue(v010.allowed_setting('按键设置.json'))
        self.assertTrue(v010.allowed_setting('按键设置-型号隔离升级前.json'))
        self.assertTrue(v010.allowed_setting('mapping-restore-01234567-89ab-cdef-0123-456789abcdef.json'))
        self.assertFalse(v010.allowed_setting('../evil.json'))
        self.assertFalse(v010.allowed_setting('mapping-restore-../evil.json'))
        self.assertFalse(v010.allowed_setting('service.py'))
        self.assertFalse(v010.allowed_setting('mapping-restore-' + 'x' * 80 + '.json'))

    def test_prepare_scripts_creates_nested_rollback_without_upgrade_preinstall(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary) / 'nested' / 'rollback'
            scripts = packager.prepare_scripts(stage, rollback=True)
            self.assertEqual({'install-support.py', 'postinstall'}, {entry.name for entry in scripts.iterdir()})
            self.assertFalse((scripts / 'preinstall').exists())
            self.assertIn(' rollback', (scripts / 'postinstall').read_text())
            for entry in scripts.iterdir():
                self.assertTrue(entry.stat().st_mode & stat.S_IXUSR)

    def test_directory_chain_rejects_symlinked_ancestor_and_public_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); real = root / 'real'; real.mkdir()
            (real / 'settings').mkdir(); (root / 'linked').symlink_to(real, target_is_directory=True)
            with self.assertRaises(OSError):
                v010.open_directory_chain(root / 'linked/settings', os.getuid())
            root.chmod(0o755)
            with self.assertRaises(RuntimeError):
                v010.safe_private_directory(root, uid=os.getuid())

    def test_applications_parent_policy_only_allows_canonical_root_admin_0775(self):
        valid = SimpleNamespace(st_mode=stat.S_IFDIR | 0o775, st_uid=0, st_gid=80)
        v010.validate_system_parent(Path('/Applications'), valid, admin_gid=80)
        invalid = [
            (Path('/tmp/Applications'), valid),
            (Path('/Applications'), SimpleNamespace(st_mode=stat.S_IFDIR | 0o777, st_uid=0, st_gid=80)),
            (Path('/Applications'), SimpleNamespace(st_mode=stat.S_IFDIR | 0o775, st_uid=0, st_gid=0)),
            (Path('/Applications'), SimpleNamespace(st_mode=stat.S_IFLNK | 0o775, st_uid=0, st_gid=80)),
        ]
        for path, info in invalid:
            with self.subTest(path=path, mode=info.st_mode, gid=info.st_gid):
                with self.assertRaises(RuntimeError):
                    v010.validate_system_parent(path, info, admin_gid=80)

    def test_source_symlink_swap_cannot_escape_pinned_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.mkdir()
            secret = root / 'secret'; secret.write_bytes(b'root-secret')
            name = '按键设置.json'; (source / name).write_bytes(b'user-settings')
            directory_fd = os.open(source, v010.OPEN_DIRECTORY)
            real_open = os.open; swapped = False

            def interposed_open(path, flags, *args, **kwargs):
                nonlocal swapped
                if path == name and kwargs.get('dir_fd') == directory_fd and not swapped:
                    swapped = True
                    os.unlink(name, dir_fd=directory_fd)
                    os.symlink(secret, name, dir_fd=directory_fd)
                return real_open(path, flags, *args, **kwargs)

            try:
                with mock.patch.object(v010.os, 'open', side_effect=interposed_open):
                    with self.assertRaises(OSError):
                        v010.open_regular_at(directory_fd, name, os.getuid())
            finally:
                os.close(directory_fd)
            self.assertTrue(swapped)
            self.assertEqual(b'root-secret', secret.read_bytes())

    def test_target_symlink_swap_is_replaced_without_touching_victim(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; destination = root / 'destination'
            source.mkdir(); destination.mkdir()
            name = '按键设置.json'; (source / name).write_bytes(b'restored-settings')
            victim = root / 'victim'; victim.write_bytes(b'do-not-touch')
            (destination / name).write_bytes(b'candidate-settings')
            source_fd = os.open(source / name, v010.OPEN_REGULAR)
            destination_fd = os.open(destination, v010.OPEN_DIRECTORY)
            real_replace = os.replace; swapped = False

            def interposed_replace(src, dst, *args, **kwargs):
                nonlocal swapped
                if dst == name and kwargs.get('dst_dir_fd') == destination_fd and not swapped:
                    swapped = True
                    os.unlink(name, dir_fd=destination_fd)
                    os.symlink(victim, name, dir_fd=destination_fd)
                return real_replace(src, dst, *args, **kwargs)

            try:
                with mock.patch.object(v010.os, 'replace', side_effect=interposed_replace):
                    v010.atomic_copy_at(source_fd, destination_fd, name, os.getuid(), os.getgid())
            finally:
                os.close(source_fd); os.close(destination_fd)
            self.assertTrue(swapped)
            self.assertFalse((destination / name).is_symlink())
            self.assertEqual(b'restored-settings', (destination / name).read_bytes())
            self.assertEqual(b'do-not-touch', victim.read_bytes())

    def test_failed_system_commit_restores_every_previous_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / 'first'; second = root / 'second'
            first.write_text('current-one'); second.write_text('current-two')
            first_restore = root / 'restore-one'; second_restore = root / 'restore-two'
            first_restore.write_text('old-one'); second_restore.write_text('old-two')
            staged = [
                {'destination': first, 'replacement': first_restore, 'quarantine': root / 'current-one',
                 'had_current': True, 'committed': False},
                {'destination': second, 'replacement': second_restore, 'quarantine': root / 'current-two',
                 'had_current': True, 'committed': False},
            ]
            real_replace = os.replace

            def fail_second_restore(src, dst, *args, **kwargs):
                if Path(src) == second_restore and Path(dst) == second:
                    raise OSError('interposed second restore failure')
                return real_replace(src, dst, *args, **kwargs)

            with mock.patch.object(v010.os, 'replace', side_effect=fail_second_restore):
                with self.assertRaises(OSError):
                    v010.commit_system_restore(staged)
            self.assertEqual('current-one', first.read_text())
            self.assertEqual('current-two', second.read_text())

    def test_failed_user_commit_restores_all_candidate_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); backup = root / 'backup'; settings = root / 'settings'; preferences = root / 'preferences'
            backup.mkdir(); settings.mkdir(); preferences.mkdir()
            names = ['按键设置.json', '设备库.json']
            source_fds = {}
            for index, name in enumerate(names):
                (backup / name).write_text('old-' + str(index))
                (settings / name).write_text('candidate-' + str(index))
                source_fds[name] = os.open(backup / name, v010.OPEN_REGULAR)
            settings_fd = os.open(settings, v010.OPEN_DIRECTORY)
            preferences_fd = os.open(preferences, v010.OPEN_DIRECTORY)
            plan = {'manifest': {'uid': os.getuid(), 'files': names, 'preferences': False},
                    'uid': os.getuid(), 'source_fds': source_fds,
                    'settings_fd': settings_fd, 'preferences_fd': preferences_fd}
            real_replace = os.replace; failed = False

            def fail_second_setting(src, dst, *args, **kwargs):
                nonlocal failed
                if dst == names[1] and str(src).startswith('.v010-') and not failed:
                    failed = True
                    raise OSError('interposed user restore failure')
                return real_replace(src, dst, *args, **kwargs)

            try:
                with mock.patch.object(v010.os, 'fchown'), \
                     mock.patch.object(v010.os, 'replace', side_effect=fail_second_setting):
                    with self.assertRaises(OSError):
                        v010.restore_user_settings(plan)
            finally:
                for fd in source_fds.values(): os.close(fd)
                os.close(settings_fd); os.close(preferences_fd)
            self.assertTrue(failed)
            self.assertEqual('candidate-0', (settings / names[0]).read_text())
            self.assertEqual('candidate-1', (settings / names[1]).read_text())

    def test_user_preflight_failure_happens_before_service_or_files_change(self):
        state = {'app': True, 'support': True, 'plist': True, 'hal': True}
        with mock.patch.multiple(v010,
                                 require_quit=mock.DEFAULT,
                                 _validated_state=mock.DEFAULT,
                                 console_user=mock.DEFAULT,
                                 prepare_user_restore=mock.DEFAULT,
                                 stage_system_restore=mock.DEFAULT,
                                 stop_service=mock.DEFAULT):
            v010._validated_state.return_value = state
            v010.console_user.return_value = (501, Path('/Users/test'))
            v010.prepare_user_restore.side_effect = RuntimeError('invalid final backup file')
            with self.assertRaises(RuntimeError):
                v010.rollback()
            v010.stage_system_restore.assert_not_called()
            v010.stop_service.assert_not_called()

    def test_trace_recovery_failure_discards_staging_and_restarts_service(self):
        state = {'app': True, 'support': True, 'plist': True, 'hal': True}
        user_plan = {'source_fds': {}}
        staged = [{'replacement': Path('/unused'), 'quarantine': Path('/unused-q')}]
        with mock.patch.multiple(v010,
                                 require_quit=mock.DEFAULT,
                                 _validated_state=mock.DEFAULT,
                                 console_user=mock.DEFAULT,
                                 prepare_user_restore=mock.DEFAULT,
                                 stage_system_restore=mock.DEFAULT,
                                 stop_service=mock.DEFAULT,
                                 recover_trace=mock.DEFAULT,
                                 commit_system_restore=mock.DEFAULT,
                                 discard_system_restore=mock.DEFAULT,
                                 start_service_if_present=mock.DEFAULT,
                                 close_user_restore=mock.DEFAULT):
            v010._validated_state.return_value = state
            v010.console_user.return_value = (501, Path('/Users/test'))
            v010.prepare_user_restore.return_value = user_plan
            v010.stage_system_restore.return_value = staged
            v010.recover_trace.side_effect = RuntimeError('trace recovery failed')
            with self.assertRaises(RuntimeError):
                v010.rollback()
            v010.commit_system_restore.assert_not_called()
            v010.discard_system_restore.assert_called_once_with(staged)
            v010.start_service_if_present.assert_called_once_with()
            v010.close_user_restore.assert_called_once_with(user_plan)


if __name__ == '__main__': unittest.main()
