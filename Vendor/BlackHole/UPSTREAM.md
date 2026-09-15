# BlackHole source and local driver

Source: https://github.com/ExistentialAudio/BlackHole

Version: v0.7.1, commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`.
Retrieved 2026-09-08. Copyright Existential Audio Inc. and contributors, GPL-3.0; LICENSE is included here.

BlackHole.c and BlackHole.plist are retained unmodified. BlackHole is a monolithic C implementation and does not require a BlackHole.h. The upstream README is retained as README.upstream.md.

The local build script generates a patched build copy: Audio Device transport reports USB, following the interoperability approach documented by https://github.com/HD838A/remote-mic-app at commit `c9fabd1ef53e1a311dab4518a70693494631368b`. This is a virtual device transporting Bluetooth remote audio, not an actual USB microphone.

DriverConfig.h sets an independent bundle ID, device UIDs, names, fixed 48 kHz stereo format, visible input-only device and hidden output-only mirror. Info.plist uses an independent factory UUID. No BlackHole or other audio driver is replaced. The matching source, build configuration, local changes and GPL license are all present in this project.

Build: `python3 scripts/build-audio-driver.py`. Building does not install the driver.
