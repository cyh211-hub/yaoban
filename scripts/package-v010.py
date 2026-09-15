#!/usr/bin/python3
"""Build a configured v0.10-series candidate and rollback package pair."""
from pathlib import Path
import json, plistlib, re, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = '0.10.0'
APP = ROOT / '.build/v010/遥伴.app'
DRIVER = ROOT / 'build/MiRemoteMic.driver'
OUT = ROOT / 'build/遥伴-0.10.0-候选版-安装修正版.pkg'
ROLLBACK = ROOT / 'build/遥伴-0.10.0-候选版回退-安装修正版.pkg'
PACKAGE_SCRIPTS = ROOT / 'packaging/v010'
PACKAGE_IDENTIFIER = 'local.moss.Yaoban.upgrade010'
ROLLBACK_IDENTIFIER = 'local.moss.Yaoban.upgrade010.rollback'
TEMP_PREFIX = 'yaoban-v010'

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def requirement_for(app):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    info = run(['/usr/bin/codesign', '-d', '--verbose=4', str(app)], capture_output=True, text=True).stderr
    hashes = re.findall(r'^CDHash=([0-9a-f]{40})$', info, re.M)
    if len(hashes) != 1: raise RuntimeError('expected exactly one app CDHash')
    requirement = 'identifier "local.moss.MiRemoteLab" and cdhash H"' + hashes[0] + '"'
    run(['/usr/bin/codesign', '--verify', '-R=' + requirement, str(app)])
    return requirement

def verify_driver(driver):
    run(['/usr/bin/codesign', '--verify', '--strict', str(driver)])
    info = plistlib.loads((driver / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'local.moss.MiRemoteMic':
        raise RuntimeError('unexpected microphone driver identity')
    if info.get('CFBundleName') != '遥控器麦克风':
        raise RuntimeError('unexpected microphone display name')

def verify_package(package, identifier):
    with tempfile.TemporaryDirectory(prefix=TEMP_PREFIX + '-inspect-', dir='/private/tmp') as temporary:
        expanded = Path(temporary) / 'expanded'
        run(['/usr/sbin/pkgutil', '--expand', str(package), str(expanded)])
        info = (expanded / 'PackageInfo').read_text()
        if ('identifier="' + identifier + '"') not in info or ('version="' + VERSION + '"') not in info:
            raise RuntimeError('unexpected package identity: ' + str(package))

def prepare_scripts(stage, rollback=False):
    scripts = stage / 'scripts'; scripts.mkdir(parents=True)
    names = ('install-support.py', 'rollback-postinstall') if rollback else ('install-support.py', 'preinstall', 'postinstall')
    for name in names:
        source = PACKAGE_SCRIPTS / name
        destination = scripts / ('postinstall' if name == 'rollback-postinstall' else name)
        shutil.copyfile(source, destination); destination.chmod(0o755)
    return scripts

def component_plist(payload, destination):
    run(['/usr/bin/pkgbuild', '--analyze', '--root', str(payload), str(destination)])
    components = plistlib.loads(destination.read_bytes())
    for entry in components:
        entry['BundleIsRelocatable'] = False; entry['BundleIsVersionChecked'] = True
    destination.write_bytes(plistlib.dumps(components))

def main():
    if not APP.is_dir(): raise RuntimeError('build the v' + VERSION + ' app first: ' + str(APP))
    if not DRIVER.is_dir(): raise RuntimeError('build the signed microphone driver first: ' + str(DRIVER))
    requirement = requirement_for(APP)
    verify_driver(DRIVER)
    output = OUT.parent; output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=TEMP_PREFIX + '-package-', dir='/private/tmp') as temp:
        stage = Path(temp); payload = stage / 'root'
        app = payload / 'Applications/遥伴.app'; app.parent.mkdir(parents=True)
        shutil.copytree(APP, app, symlinks=True, ignore=shutil.ignore_patterns('._*', '.DS_Store'))
        support = payload / 'Library/Application Support/YaobanVoice'; support.mkdir(parents=True)
        for name in ('apple-voice-service.py', 'apple_voice_binary.py'):
            shutil.copyfile(ROOT / 'scripts' / name, support / name)
        run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos14.0', '-O', '-module-cache-path', str(ROOT / '.build/module-cache'),
             str(ROOT / 'Sources/AppleVoicePeerCheck/main.swift'), str(ROOT / 'Sources/AppleVoicePeerCheck/PeerVerifier.swift'),
             '-framework', 'Security', '-o', str(support / 'YaobanPeerCheck')])
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'local.moss.YaobanPeerCheck', '--options', 'runtime', str(support / 'YaobanPeerCheck')])
        (support / 'client-template.json').write_text(json.dumps({'requirement': requirement, 'bundlePath': '/Applications/遥伴.app'}, indent=2) + '\n')
        hal = payload / 'Library/Audio/Plug-Ins/HAL/MiRemoteMic.driver'; hal.parent.mkdir(parents=True)
        shutil.copytree(DRIVER, hal, symlinks=True, ignore=shutil.ignore_patterns('._*', '.DS_Store'))
        run(['/usr/bin/codesign', '--verify', '--strict', str(hal)])
        launch = payload / 'Library/LaunchDaemons/local.moss.YaobanAppleVoice.plist'; launch.parent.mkdir()
        launch.write_bytes(plistlib.dumps({'Label': 'local.moss.YaobanAppleVoice', 'ProgramArguments': ['/usr/bin/python3', '-I', '/Library/Application Support/YaobanVoice/apple-voice-service.py'], 'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10, 'ExitTimeOut': 75, 'StandardOutPath': '/Library/Application Support/YaobanVoice/service.log', 'StandardErrorPath': '/Library/Application Support/YaobanVoice/service.log'}))
        for path in support.iterdir(): path.chmod(0o755 if path.name == 'YaobanPeerCheck' else 0o644)
        launch.chmod(0o644)
        scripts = prepare_scripts(stage)
        components = stage / 'components.plist'; component_plist(payload, components)
        candidate = stage / 'candidate.pkg'
        run(['/usr/bin/pkgbuild', '--root', str(payload), '--component-plist', str(components), '--scripts', str(scripts), '--ownership', 'recommended', '--identifier', PACKAGE_IDENTIFIER, '--version', VERSION, '--install-location', '/', str(candidate)])
        rollback = stage / 'rollback.pkg'
        run(['/usr/bin/pkgbuild', '--nopayload', '--scripts', str(prepare_scripts(stage / 'rollback', rollback=True)), '--identifier', ROLLBACK_IDENTIFIER, '--version', VERSION, str(rollback)])
        verify_package(candidate, PACKAGE_IDENTIFIER)
        verify_package(rollback, ROLLBACK_IDENTIFIER)
        shutil.copy2(candidate, OUT); shutil.copy2(rollback, ROLLBACK)
    print(OUT)

if __name__ == '__main__': main()
