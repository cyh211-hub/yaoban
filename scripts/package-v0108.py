#!/usr/bin/python3
"""Build v0.10.8 with touch/voice recovery and optional PacketLogger."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('yaoban_v010_base_packager', ROOT / 'scripts/package-v010.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

packager.VERSION = '0.10.8'
packager.APP = ROOT / '.build/v0108/遥伴.app'
packager.OUT = ROOT / 'build/遥伴-0.10.8-公开测试版.pkg'
packager.ROLLBACK = ROOT / 'build/遥伴-0.10.8-回退-公开测试版.pkg'
packager.PACKAGE_SCRIPTS = ROOT / 'packaging/v0108'
packager.PACKAGE_IDENTIFIER = 'local.moss.Yaoban.upgrade0108'
packager.ROLLBACK_IDENTIFIER = 'local.moss.Yaoban.upgrade0108.rollback'
packager.TEMP_PREFIX = 'yaoban-v0108'

if __name__ == '__main__':
    packager.main()
