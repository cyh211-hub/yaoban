#!/usr/bin/python3
from pathlib import Path
import hashlib,json,plistlib,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
VERSION='0.10.8'; APP=ROOT/'.build/v0108/遥伴.app'
def run(args): return subprocess.run(args,check=True,capture_output=True,text=True)
report={'version':'0.10.8 (26)','backup':'/Library/Application Support/YaobanUpgrade0108Restore','hashes':{},'installed_by_agent':False}
for suffix,rollback in [('公开测试版',False),('回退-公开测试版',True)]:
 package=ROOT/f'build/遥伴-{VERSION}-{suffix}.pkg'
 report['hashes'][package.name]=hashlib.sha256(package.read_bytes()).hexdigest()
 with tempfile.TemporaryDirectory(prefix='yaoban-0108-final-',dir='/private/tmp') as temp:
  expanded=Path(temp)/'expanded'
  run(['/usr/sbin/pkgutil','--expand-full',str(package),str(expanded)])
  scripts=expanded/'Scripts'
  assert (scripts/'install-support.py').read_bytes()==(ROOT/'packaging/v0108/install-support.py').read_bytes()
  assert 'YaobanUpgrade0108Restore' in (scripts/'install-support.py').read_text()
  assert 'YaobanUpgrade0105Restore' not in (scripts/'install-support.py').read_text()
  if rollback:
   assert not (scripts/'preinstall').exists()
   assert (scripts/'postinstall').read_bytes()==(ROOT/'packaging/v0108/rollback-postinstall').read_bytes()
  else:
   for name in ('preinstall','postinstall'): assert (scripts/name).read_bytes()==(ROOT/'packaging/v0108'/name).read_bytes()
   payload=expanded/'Payload'
   assert not list(payload.rglob('PacketLogger.app'))
   assert not list(payload.rglob('Xiaomi2Pro-official.png'))
   bundled=payload/'Applications/遥伴.app'
   assert (bundled/'Contents/Resources/Xiaomi2Pro-illustration.png').read_bytes()==(ROOT/'Assets/Devices/Xiaomi2Pro-illustration.png').read_bytes()
   info=plistlib.loads((bundled/'Contents/Info.plist').read_bytes())
   assert info['CFBundleShortVersionString']==VERSION and info['CFBundleVersion']=='26'
   assert (bundled/'Contents/MacOS/MiRemoteLab').read_bytes()==(APP/'Contents/MacOS/MiRemoteLab').read_bytes()
   assert (bundled/'Contents/Helpers/YaobanTouch').read_bytes()==(APP/'Contents/Helpers/YaobanTouch').read_bytes()
   template=json.loads((payload/'Library/Application Support/YaobanVoice/client-template.json').read_text())
   assert template['bundlePath']=='/Applications/遥伴.app'
   run(['/usr/bin/codesign','--verify','--deep','--strict','-R='+template['requirement'],str(bundled)])
   run(['/usr/bin/codesign','--verify','--strict',str(payload/'Library/Audio/Plug-Ins/HAL/MiRemoteMic.driver')])
   report['app_requirement']=template['requirement']
report['validation']='clean-source build; manufacturer image absent; payload signature and backup isolation verified; 0.10.8 hardware installation pending user'
(ROOT/'docs/v0.10.8').mkdir(parents=True,exist_ok=True)
(ROOT/'docs/v0.10.8/安装包验证.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('PASS: v0.10.8 app/version/payload, voice peer requirement, driver signature, dedicated backup and rollback scripts; package hashes recorded')
