"""Offline checks for the v0.10.1 repair and rollback package configuration."""
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


v0101 = load('v0101_packager', ROOT / 'scripts/package-v0101.py')
helper010 = load('v010_install_support_for_v0101_test', ROOT / 'packaging/v010/install-support.py')
helper0101 = load('v0101_install_support', ROOT / 'packaging/v0101/install-support.py')


class V0101PackagingTests(unittest.TestCase):
    def test_repair_package_has_dedicated_paths_version_and_identifiers(self):
        configured = v0101.packager
        self.assertEqual('0.10.1', configured.VERSION)
        self.assertEqual(ROOT / '.build/v0101/遥伴.app', configured.APP)
        self.assertEqual(ROOT / 'build/遥伴-0.10.1-修复版.pkg', configured.OUT)
        self.assertEqual(ROOT / 'build/遥伴-0.10.1-回退.pkg', configured.ROLLBACK)
        self.assertEqual('local.moss.Yaoban.upgrade0101', configured.PACKAGE_IDENTIFIER)
        self.assertEqual('local.moss.Yaoban.upgrade0101.rollback', configured.ROLLBACK_IDENTIFIER)

    def test_v0101_helper_only_changes_the_final_backup_directory(self):
        original = (ROOT / 'packaging/v010/install-support.py').read_text().splitlines()
        repair = (ROOT / 'packaging/v0101/install-support.py').read_text().splitlines()
        differences = [(left, right) for left, right in zip(original, repair) if left != right]
        self.assertEqual(len(original), len(repair))
        self.assertEqual([
            ("BACKUP = Path('/Library/Application Support/YaobanUpgrade010Restore')",
             "BACKUP = Path('/Library/Application Support/YaobanUpgrade0101Restore')")
        ], differences)
        self.assertEqual(Path('/Library/Application Support/YaobanUpgrade010Restore'), helper010.BACKUP)
        self.assertEqual(Path('/Library/Application Support/YaobanUpgrade0101Restore'), helper0101.BACKUP)

    def test_candidate_and_rollback_stage_only_v0101_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = v0101.packager.prepare_scripts(root / 'candidate')
            rollback = v0101.packager.prepare_scripts(root / 'rollback', rollback=True)
            self.assertEqual({'install-support.py', 'preinstall', 'postinstall'},
                             {entry.name for entry in candidate.iterdir()})
            self.assertEqual({'install-support.py', 'postinstall'},
                             {entry.name for entry in rollback.iterdir()})
            self.assertNotIn(' preinstall', (rollback / 'postinstall').read_text())
            self.assertIn(' rollback', (rollback / 'postinstall').read_text())
            self.assertIn('YaobanUpgrade0101Restore', (candidate / 'install-support.py').read_text())
            self.assertNotIn("BACKUP = Path('/Library/Application Support/YaobanUpgrade010Restore')",
                             (candidate / 'install-support.py').read_text())
            for directory in (candidate, rollback):
                for entry in directory.iterdir():
                    self.assertTrue(entry.stat().st_mode & stat.S_IXUSR)

    def test_package_inspection_requires_v0101_version(self):
        configured = v0101.packager

        def expand(args, **kwargs):
            expanded = Path(args[-1])
            expanded.mkdir()
            (expanded / 'PackageInfo').write_text(
                '<pkg-info identifier="local.moss.Yaoban.upgrade0101" version="0.10.1"/>')
            return mock.Mock()

        with mock.patch.object(configured, 'run', side_effect=expand):
            configured.verify_package(Path('/unused/candidate.pkg'),
                                      'local.moss.Yaoban.upgrade0101')

    def test_missing_candidate_stops_before_any_packaging_command(self):
        configured = v0101.packager
        with tempfile.TemporaryDirectory() as temporary:
            missing_app = Path(temporary) / 'missing/遥伴.app'
            with mock.patch.object(configured, 'APP', missing_app), \
                    mock.patch.object(configured, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, r'build the v0\.10\.1 app first'):
                    configured.main()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
