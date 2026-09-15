"""No installer actions; validate bundle inspection with temporary fixtures."""
import importlib.util
from pathlib import Path
import os
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('install',ROOT/'packaging/apple-voice/install-support.py')
install=importlib.util.module_from_spec(spec);spec.loader.exec_module(install)
class InstallerTests(unittest.TestCase):
    def test_external_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle=Path(temp)/'app';bundle.mkdir();(bundle/'link').symlink_to('/etc')
            with self.assertRaises(RuntimeError):install.inspect_tree(bundle)
    def test_internal_framework_symlink_allowed(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle=Path(temp)/'app';bundle.mkdir();(bundle/'Versions').mkdir();(bundle/'Versions/A').mkdir()
            (bundle/'Current').symlink_to('Versions/A');install.inspect_tree(bundle)
    def test_hardlink_and_special_file_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle=Path(temp)/'app';bundle.mkdir();(bundle/'a').write_bytes(b'content');os.link(bundle/'a',bundle/'b')
            with self.assertRaises(RuntimeError):install.inspect_tree(bundle)
            (bundle/'a').unlink();(bundle/'b').unlink();os.mkfifo(bundle/'fifo')
            with self.assertRaises(RuntimeError):install.inspect_tree(bundle)
    def test_top_level_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle=Path(temp)/'app';bundle.mkdir();(Path(temp)/'alias').symlink_to(bundle)
            with self.assertRaises(RuntimeError):install.inspect_tree(Path(temp)/'alias')
if __name__=='__main__':unittest.main()
