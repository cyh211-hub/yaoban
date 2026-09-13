# Third-party attribution

This local development prototype includes `ATVVProtocol.swift` from [Open Voice Bridge](https://github.com/nijez/open-voice-bridge), by its contributors, under GNU GPL version 3. A copy of the upstream license is provided in `LICENSE`. The copied protocol file is unmodified. The HID wire format and ATVV handshake in the new diagnostic implementation were checked against that project's `RemoteButtons.swift` and `XiaomiBluetoothBridge.swift`.

Reference sources were retrieved on 2026-09-08. The observed upstream main revision during retrieval was `1796b149f752ff2d2fa82fd818f8a5a2bc60802a`. `Reference/open-voice-bridge` retains the fetched reference files. No upstream app, updater, installer or install script is executed by this project.

The new diagnostic application, UI, local WAV capture and build script were added on 2026-09-08. The earlier OK toggle was removed after the user clarified physical down/up semantics. Current defaults map the native microphone key to right Command and OK to Return.

Device-specific mapping and restoration were informed by Open Voice Bridge's `RemoteVoiceFunctionMapper.swift` and Apple's [TN2450](https://developer.apple.com/library/archive/technotes/tn2450/_index.html). New code adds a persisted restoration journal, editable mappings and a chord lifecycle state machine.

This combined prototype is provided under GNU GPL version 3, with its corresponding source and build instructions, without warranty. It is a local prototype, not an official Xiaomi, Doubao or OpenAI application.

The system microphone component is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole), by Existential Audio and contributors, under GPL version 3. The vendored revision is `e2b22aaaba4e507a097131704bf96dabc004d9cf` (v0.7.1). Original source and license are retained under `Vendor/BlackHole`. Our build supplies unique device names, UIDs, plug-in factory identity, a 48 kHz input/hidden-output configuration, and patches the generated build copy to report USB transport for input-method compatibility. The original vendored C source remains unchanged. See `Vendor/BlackHole/UPSTREAM.md` for details. The locally authored installer and uninstaller only manage `MiRemoteMic.driver`; no upstream installation scripts are executed.

Version 0.2.0 adds menu-bar operation, per-mode settings and verified persistent storage. Fresh defaults map OK to left Control + Return and Power to Return, while preserving right Command for the native microphone key. Existing user settings migrate separately from these defaults.

Version 0.5.0 uses the original Xiaomi Bluetooth Remote 2 Pro product thumbnail from the official product catalogue (product 23714), retrieved 2026-09-09. See `Assets/Devices/SOURCE.md`. The manufacturer image and trademarks retain their original rights and are not covered by the source-code licence. The Yovolpen brand mark was generated for this project from the user-selected design.

Version 0.9.0's local Apple voice preview statically links libopus 1.6.1, under its BSD-style license; the complete notice is included at `Assets/Licenses/Opus-COPYING` and in the application's resources. The addressed PacketLogger / Opus workflow and first-use warm-up were studied in SiriRemoteForge revision `4c65969c71c5` (GPL-3.0), retained under `Reference/SiriRemoteForge-4c65969c71c5`. Yovolpen's parser, bounded capture broker, source checks and lifecycle integration are in this repository under GPL-3.0. Apple's PacketLogger remains proprietary: this local installer only copies and verifies the user's already-installed Apple tool; it does not redistribute it.
