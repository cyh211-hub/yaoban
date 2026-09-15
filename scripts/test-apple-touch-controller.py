#!/usr/bin/python3
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
out=root/'.build/apple-touch-controller-tests'
out.mkdir(parents=True,exist_ok=True)
source=(root/'Sources/MiRemoteLab/AppleTouchController.swift').read_text()
source+='''
extension AppleTouchController {
    func testInput(_ value:String) { receive(Data(value.utf8)) }
    func testSettings(_ value:RemoteTouchSettings) { settings = value }
    func testEOF() { interrupted() }
    var testReady:Bool { ready }
}
'''
(out/'AppleTouchController.swift').write_text(source)
(out/'main.swift').write_text((root/'Tests/AppleTouchController/checks.swift').read_text())
files=['AppleButtonInput.swift','DeviceStatus.swift','RemoteButtonLayout.swift','RemoteReport.swift','KeyMapping.swift','RemoteTouchMotion.swift','RemoteTouchTap.swift']
args=['xcrun','swiftc','-swift-version','5','-module-cache-path',str(root/'.build/module-cache')]
args += [str(root/'Sources/MiRemoteLab'/name) for name in files]
args += [str(out/'AppleTouchController.swift'),str(out/'main.swift'),'-o',str(out/'check')]
subprocess.run(args,cwd=root,check=True)
subprocess.run([str(out/'check')],cwd=root,check=True)
