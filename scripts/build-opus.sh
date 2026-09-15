#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
archive="$PWD/Vendor/Opus/opus-1.6.1.tar.gz"
expected=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
actual=$(/usr/bin/shasum -a 256 "$archive")
[[ "${actual%% *}" == "$expected" ]] || { print -u2 'Opus source checksum mismatch'; exit 1; }
# Autoconf rejects source directories containing spaces. Build in a private
# temporary directory, then copy only the install prefix into the project.
root_dir="$PWD"
work_dir=$(/usr/bin/mktemp -d /private/tmp/yovolpen-opus.XXXXXX)
trap '/bin/rm -rf "$work_dir"' EXIT
/usr/bin/tar -xzf "$archive" -C "$work_dir"
mkdir "$work_dir/build"
cd "$work_dir/build"
export SDKROOT="$(xcrun --show-sdk-path)"
CC="$(xcrun --find clang)" CFLAGS='-O2 -arch arm64 -mmacosx-version-min=26.0' LDFLAGS='-arch arm64 -mmacosx-version-min=26.0' "$work_dir/opus-1.6.1/configure" --host=aarch64-apple-darwin --prefix="$work_dir/install" --disable-shared --enable-static --disable-doc --disable-extra-programs > configure.log 2>&1 || { cat configure.log; tail -90 config.log; exit 1; }
make -j4 > make.log 2>&1 || { tail -40 make.log; exit 1; }
make install > install.log 2>&1 || { cat install.log; exit 1; }
mkdir -p "$root_dir/.build/opus-install"
cp -R "$work_dir/install/" "$root_dir/.build/opus-install/"
print "$root_dir/.build/opus-install"
