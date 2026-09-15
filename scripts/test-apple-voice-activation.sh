#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Offline pure-logic checks only: no Bluetooth/HID access, recording or installation.
activation_test_dir="$PWD/.build/apple-voice-activation-policy"
mkdir -p "$activation_test_dir/cache"
xcrun swiftc -swift-version 5 -D APPLE_VOICE_ACTIVATION_TEST \
    -module-cache-path "$activation_test_dir/cache" \
    Sources/AppleVoiceLab/AppleVoiceActivationPolicy.swift \
    Tests/AppleVoice/activation_policy_test.swift \
    -o "$activation_test_dir/tests"
"$activation_test_dir/tests"
