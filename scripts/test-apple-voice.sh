#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Local offline dependency only; no package installation or app/driver changes.
opus_prefix="${YAOBAN_TEST_OPUS_PREFIX:-/opt/homebrew/opt/opus}"
[[ -f "$opus_prefix/include/opus/opus.h" && -f "$opus_prefix/lib/libopus.a" ]] || {
    print -u2 "Point YAOBAN_TEST_OPUS_PREFIX to an existing libopus installation."
    exit 1
}
voice_arch="${MI_REMOTE_ARCH:-arm64}"
case "$voice_arch" in arm64|x86_64) ;; *) exit 1 ;; esac
# This local test uses the existing host library, not the app's macOS 14 SDK floor.
voice_os="$(/usr/bin/sw_vers -productVersion)"
voice_os="${voice_os%%.*}.0"
voice_dir="$PWD/.build/apple-voice-lab"
voice_swift_flags=()
voice_c_flags=()
if [[ "${YAOBAN_TEST_ASAN:-0}" == "1" ]]; then
    voice_dir="$voice_dir/asan"
    voice_swift_flags=(-sanitize=address)
    voice_c_flags=(-fsanitize=address)
fi
mkdir -p "$voice_dir/cache"
xcrun clang -target "${voice_arch}-apple-macos${voice_os}" "${voice_c_flags[@]}" -std=c11 -Wall -Wextra -Werror -I "$opus_prefix/include/opus" -c Tests/AppleVoice/Fixtures.c -o "$voice_dir/fixtures.o"
xcrun swiftc -target "${voice_arch}-apple-macos${voice_os}" "${voice_swift_flags[@]}" -swift-version 5 -module-cache-path "$voice_dir/cache" -Xcc -I -Xcc "$opus_prefix/include/opus" -import-objc-header Tests/AppleVoice/Fixtures.h Sources/AppleVoiceLab/*.swift Tests/AppleVoice/*.swift "$voice_dir/fixtures.o" "$opus_prefix/lib/libopus.a" -o "$voice_dir/tests"
"$voice_dir/tests"
