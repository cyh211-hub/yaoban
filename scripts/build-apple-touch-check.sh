#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/apple-touch-check
xcrun clang -target arm64-apple-macos14.0 -fobjc-arc -O1 -Wall -Wextra -Werror \
  -Wno-deprecated-declarations Sources/AppleTouchCheck/main.m \
  -framework Foundation -framework IOKit -o .build/apple-touch-check/check
codesign --force --sign - --options runtime .build/apple-touch-check/check
codesign --verify --strict .build/apple-touch-check/check
printf '%s\n' "$PWD/.build/apple-touch-check/check"
