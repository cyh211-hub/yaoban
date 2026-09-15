# Public source audit: Yovolpen 0.10.8

`scripts/prepare-public-source.py` is the sole source-release assembly step. It uses an explicit allowlist, writes `release/Yovolpen-0.10.8/source`, and refuses to replace an existing output.

## Included

- Application, helper, audio-ring, driver, test and fixture source in `Sources`, `Driver` and `Tests`.
- The vendored BlackHole source, licence and provenance in `Vendor/BlackHole`.
- The official Opus 1.6.1 source archive and provenance in `Vendor/Opus`, its licence notice, and `scripts/build-opus.sh`; no prebuilt `libopus.a` is released.
- The 0.10.8 app/driver/package/test scripts and the matching `packaging/v0108` install and rollback scripts.
- The product’s public README, build/install/release documents, privacy notice, licence and third-party notices.

## Deliberately excluded

- `Reference`, including the SiriRemoteForge and Open Voice Bridge working references.
- `Diagnostics`, `.build`, `build`, old packages, logs, recordings, packet captures, local settings, historical investigation notes, and all Doubao handoff/workspace material.
- Xiaomi product images and their source note. The public build includes only the generated illustration and its provenance.
- Websites, promotion/design material, Windows artifacts and macOS metadata/cache files.

## Test-fixture review

The included Apple voice fixtures use synthetic packet rows and placeholder Bluetooth addresses such as `11:22:33:44:55:66`. They contain no recordings, PacketLogger capture, account credential, real personal path or physical-device identifier (tests may use synthetic /Users/test paths). Test text that says `secret` is a negative redaction assertion, not a credential. Audio, trace and capture extensions are blocked by the assembler.

## Build dependencies and release gaps resolved

The 0.10.6 build linked `/opt/homebrew/opt/opus/include/opus/opus.h` and `/opt/homebrew/opt/opus/lib/libopus.a`. That made its public source non-reproducible and its available archive arm64-only. The 0.10.8 source release must instead include the official Opus 1.6.1 source archive plus `scripts/build-opus.sh`, which creates the static dependency selected by `YAOBAN_OPUS_PREFIX`.

The release machine still needs macOS, Xcode Command Line Tools, Python 3 and zsh. The app build uses Apple system frameworks. Packaging needs `pkgbuild` and ad-hoc signing. Apple PacketLogger remains a user-supplied optional tool for Apple Remote voice capture; it is neither bundled nor downloaded.

## Release gate

Before assembly, run `python3 scripts/prepare-public-source.py --check`. After assembly, verify that `release/Yovolpen-0.10.8/source` contains no `Reference`, `Diagnostics`, `豆包`, `.build`, `build`, `*.pkg`, recordings, packet captures or Xiaomi product images. Build and package from the generated tree using its `DEPENDENCIES.md` and `docs/BUILD_FROM_SOURCE.md`.
