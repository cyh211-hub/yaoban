# Build dependencies

The repository vendors the official Opus 1.6.1 source archive and its upstream provenance. Run `scripts/build-opus.sh` to create a local static library, then point `YAOBAN_OPUS_PREFIX` at that prefix before running `scripts/build.sh`. The release does not redistribute a prebuilt libopus.a.

Building requires macOS with Xcode Command Line Tools, Python 3, zsh, and the system frameworks named in `scripts/build.sh`. Packaging additionally uses `pkgbuild` and ad-hoc code signing. Apple PacketLogger is optional for Apple Remote voice capture and is neither included nor downloaded.
