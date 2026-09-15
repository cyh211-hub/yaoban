#!/usr/bin/python3
"""Build an offscreen native integration harness; run with --preview on a GUI-capable host."""
from pathlib import Path
import subprocess, os
ROOT=Path(__file__).resolve().parent.parent
OPUS=Path(os.environ.get('YAOBAN_OPUS_PREFIX', str(ROOT/'.build/opus-install')))
OUT=ROOT/'.build/v0105-ui'; OUT.mkdir(parents=True,exist_ok=True)
s=(ROOT/'Sources/MiRemoteLab/main.swift').read_text().split('\nlet app = NSApplication.shared')[0]
s=s.replace('final class LabApp: NSObject,','final class LabApp: NSObject,',1)
pos=s.index('\n    let systemMic')
s=s[:pos]+'\n    var testMenu = NSMenu()\n    var testCandidates: [RemoteBinding] = []\n    var testFailDeviceSave = false'+s[pos:]
a=s.index('        let item = statusItem ??',s.index('    func makeStatusMenu()'))
b=s.index('        let menu = NSMenu()',a)
s=s[:a]+s[b:]
s=s.replace('        item.menu = menu; statusItem = item','        testMenu = menu')
s+='\n'+(ROOT/'Tests/DeviceBindingUI/checks.swift').read_text()
(OUT/'main.swift').write_text(s)
b=(ROOT/'Sources/MiRemoteLab/BindingControls.swift').read_text().replace('if isPreview { return [] }','if isPreview { return testCandidates }',1)
(OUT/'BindingControls.swift').write_text(b)
d=(ROOT/'Sources/MiRemoteLab/DeviceManagement.swift').read_text().replace('try deviceStore.save(next); deviceLibrary = next','if testFailDeviceSave { throw PrivateFiles.error("Injected save failure") }; try deviceStore.save(next); deviceLibrary = next',1)
(OUT/'DeviceManagement.swift').write_text(d)
r=(ROOT/'Sources/MiRemoteLab/RemoteRuntime.swift').read_text().replace('final class RemoteRuntime {','final class RemoteRuntime {\n    var testStarts = 0\n    var testStops = 0\n    var testRestoreFailure = false',1)
r=r.replace('    func start() {','    func start() {\n        if ProcessInfo.processInfo.arguments.contains("--preview") { testStarts += 1; running = selectedForInput && record.enabled && record.binding.isBound; return }',1)
r=r.replace('    func stop() {','    func stop() {\n        if ProcessInfo.processInfo.arguments.contains("--preview") { testStops += 1; running = false; restoreFailure = testRestoreFailure ? "Injected restore failure" : nil; return }',1)
(OUT/'RemoteRuntime.swift').write_text(r)
subprocess.run(['xcrun','clang','-target','arm64-apple-macos26.0','-std=c11','-O2','-I','Sources/AudioBuffer/include','-c','Sources/AudioBuffer/AudioRing.c','-o',str(OUT/'AudioRing.o')],cwd=ROOT,check=True)
files=[p for p in (ROOT/'Sources/MiRemoteLab').glob('*.swift') if p.name not in ('main.swift','BindingControls.swift','DeviceManagement.swift','RemoteRuntime.swift')]
files+=list((ROOT/'Sources/AppleVoiceLab').glob('*.swift'))+[ROOT/'Sources/AppleVoiceCheck/BoundApple.swift',OUT/'BindingControls.swift',OUT/'DeviceManagement.swift',OUT/'RemoteRuntime.swift',OUT/'main.swift']
args=['xcrun','swiftc','-target','arm64-apple-macos26.0','-swift-version','5','-Onone','-module-cache-path',str(ROOT/'.build/module-cache'),'-I','Sources/AudioBuffer/include','-Xcc','-I','-Xcc',str(OPUS/'include/opus'),'-import-objc-header',str(OPUS/'include/opus/opus.h')]
args+=list(map(str,files))+[str(OPUS/'lib/libopus.a'),str(OUT/'AudioRing.o')]
for name in ['AppKit','CoreBluetooth','IOKit','IOBluetooth','CoreAudio','AudioToolbox','ServiceManagement']: args+=['-framework',name]
args+=['-o',str(OUT/'check')]
subprocess.run(args,cwd=ROOT,check=True)
print(OUT/'check')
