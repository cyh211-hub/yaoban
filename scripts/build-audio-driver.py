#!/usr/bin/env python3
"""Build a local, isolated BlackHole variant. Never installs or invokes sudo."""
from pathlib import Path
import hashlib, json, plistlib, shutil, subprocess

root = Path(__file__).resolve().parent.parent
source = root / 'Vendor/BlackHole/BlackHole.c'
build = root / '.build/audio-driver'
driver = root / 'build/MiRemoteMic.driver'
build.mkdir(parents=True, exist_ok=True)
(driver / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(driver / 'Contents/Resources').mkdir(parents=True, exist_ok=True)

# Only the Audio Device transport changes, as in Remote Mic's Doubao fix.
# Retain the upstream file verbatim; generate the patched copy at build time.
text = source.read_text()
anchor = '"BlackHole_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the device");\n\t\t\t*((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;'
assert text.count(anchor) == 1, 'Unexpected upstream source; do not patch blindly'
patched = build / 'MiRemoteMic.c'
patched.write_text(text.replace(anchor, anchor.replace('kAudioDeviceTransportTypeVirtual', 'kAudioDeviceTransportTypeUSB')))
subprocess.run(['xcrun', 'clang', '-O2', '-Wno-format-extra-args', '-fblocks', '-bundle', '-arch', 'arm64', '-arch', 'x86_64', '-mmacosx-version-min=14.0', '-include', str(root/'Driver/DriverConfig.h'), str(patched), '-framework', 'CoreAudio', '-framework', 'CoreFoundation', '-framework', 'Accelerate', '-o', str(driver/'Contents/MacOS/MiRemoteMic')], check=True)

factory = 'abf9e3bb-2803-4ba5-92ac-53c542ed61a8'
info = dict(CFBundleDevelopmentRegion='zh_CN', CFBundleExecutable='MiRemoteMic', CFBundleIdentifier='local.moss.MiRemoteMic', CFBundleInfoDictionaryVersion='6.0', CFBundleName='遥控器麦克风', CFBundlePackageType='BNDL', CFBundleShortVersionString='0.2.0', CFBundleVersion='2', CFPlugInFactories={factory:'BlackHole_Create'}, CFPlugInTypes={'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]}, LSMinimumSystemVersion='14.0')
with (driver/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
for name in ['LICENSE','UPSTREAM.md']:
    shutil.copy2(root/'Vendor/BlackHole'/name, driver/'Contents/Resources'/name)
if (root/'Vendor/BlackHole/BlackHole.icns').exists():
    shutil.copy2(root/'Vendor/BlackHole/BlackHole.icns', driver/'Contents/Resources/BlackHole.icns')
subprocess.run(['codesign','--force','--sign','-','--identifier','local.moss.MiRemoteMic',str(driver)],check=True)
subprocess.run(['codesign','--verify','--strict',str(driver)],check=True)
print(driver)
