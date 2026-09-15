#!/usr/bin/env python3
"""Create reviewable Installer packages; never install them."""
from pathlib import Path
import plistlib, shutil, subprocess, tempfile
root=Path(__file__).resolve().parent.parent
output=root/'build'
output.mkdir(parents=True,exist_ok=True)
stage=Path(tempfile.mkdtemp(prefix='mi-audio-package-',dir='/private/tmp'))
payload=stage/'root'
target=payload/'Library/Audio/Plug-Ins/HAL/MiRemoteMic.driver'
target.parent.mkdir(parents=True)
shutil.copytree(root/'build/MiRemoteMic.driver',target,copy_function=shutil.copyfile,ignore=shutil.ignore_patterns('._*','.DS_Store'))
(target/'Contents/MacOS/MiRemoteMic').chmod(0o755)
subprocess.run(['codesign','--verify','--strict',str(target)],check=True)
scripts=stage/'install-scripts'
shutil.copytree(root/'packaging/audio-install',scripts)
uninstall=stage/'uninstall-scripts'
shutil.copytree(root/'packaging/audio-uninstall',uninstall)
for folder in [scripts,uninstall]:
    for path in folder.iterdir(): path.chmod(0o755)
components=stage/'components.plist'
subprocess.run(['pkgbuild','--analyze','--root',str(payload),str(components)],check=True)
with components.open('rb') as f: descriptions=plistlib.load(f)
for component in descriptions:
    component['BundleIsRelocatable']=False
    component['BundleIsVersionChecked']=True
with components.open('wb') as f: plistlib.dump(descriptions,f)
install_package=stage/'安装遥控器麦克风.pkg'
uninstall_package=stage/'卸载遥控器麦克风.pkg'
subprocess.run(['pkgbuild','--root',str(payload),'--component-plist',str(components),'--scripts',str(scripts),'--ownership','recommended','--identifier','local.moss.MiRemoteMic.install','--version','0.2.0','--install-location','/',str(install_package)],check=True)
subprocess.run(['pkgbuild','--nopayload','--scripts',str(uninstall),'--identifier','local.moss.MiRemoteMic.uninstall','--version','0.2.0',str(uninstall_package)],check=True)
shutil.copy2(install_package,output/install_package.name)
shutil.copy2(uninstall_package,output/uninstall_package.name)
shutil.rmtree(stage)
