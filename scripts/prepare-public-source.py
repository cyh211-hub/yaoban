#!/usr/bin/env python3
"""Create the clean, reviewable Yovolpen 0.10.8 public-source tree.

This is deliberately an allowlist.  Do not broaden it with repository-wide
copies: this working directory also contains private diagnostics, reference
repositories, old packages, and vendor artwork that cannot be redistributed.
"""
from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / "release" / "Yovolpen-0.10.8" / "source"

# Files are listed by their public role.  Directory copies use the same
# exclusion rules below, so .pyc files and local metadata never enter a release.
ROOT_FILES = (
    "LICENSE",
    "PRIVACY.md",
    "THIRD_PARTY.md",
)
TREE_DIRS = (
    "Sources",
    "Tests",
    "Driver",
    "Vendor/BlackHole",
)
ASSET_FILES = (
    "Assets/Brand/BrandMark.png",
    "Assets/Devices/Xiaomi2Pro-illustration.png",
    "Assets/Devices/ILLUSTRATION.md",
    "Assets/Licenses/Opus-COPYING",
    "Assets/Licenses/OpenVoiceBridge-GPL-3.0",
    "Assets/Licenses/SiriRemoteForge-GPL-3.0",
    "Vendor/Opus/opus-1.6.1.tar.gz",
    "Vendor/Opus/UPSTREAM.md",
)
SCRIPT_FILES = (
    "scripts/prepare-public-source.py",
    "scripts/build.sh",
    "scripts/build-opus.sh",
    "scripts/build-audio-driver.py",
    "scripts/package-audio-driver.py",
    "scripts/package-v010.py",
    "scripts/package-v0108.py",
    "scripts/verify-v0108-package.py",
    "scripts/make-app-icon.swift",
    "scripts/pack-app-icon.py",
    "scripts/apple-voice-activation.py",
    "scripts/apple-voice-capture.py",
    "scripts/apple-voice-service.py",
    "scripts/apple-voice-session.py",
    "scripts/apple_voice_binary.py",
    "scripts/build-apple-check.sh",
    "scripts/build-apple-touch-check.sh",
    "scripts/build-apple-voice-check.sh",
    "scripts/test.sh",
    "scripts/test-apple-input.sh",
    "scripts/test-apple-media.sh",
    "scripts/test-apple-touch-controller.py",
    "scripts/test-apple-touch-tap.sh",
    "scripts/test-apple-touch-upgrade.sh",
    "scripts/test-apple-touch.sh",
    "scripts/test-apple-voice-activation.sh",
    "scripts/test-apple-voice.sh",
    "scripts/test-device-binding-ui.py",
    "scripts/test-preset-v8.sh",
    "scripts/test-recorder.sh",
    "scripts/test-unbound-devices.sh",
)
PACKAGE_DIRS = (
    "packaging/audio-install",
    "packaging/audio-uninstall",
    "packaging/v0108",
)
DOC_FILES = (
    "docs/BUILD_FROM_SOURCE.md",
    "docs/PUBLIC_INSTALL.md",
    "docs/PUBLIC_RELEASE.md",
    "docs/PUBLIC_SOURCE_AUDIT.md",
)
FORBIDDEN_PARTS = {
    ".git", ".build", "build", "Diagnostics", "Reference", "release",
    "豆包工作空间", "交接给豆包-Gitee首发", "网站", "宣发", "Design",
    "SiriRemoteForge对照测试", "__pycache__",
}
FORBIDDEN_NAMES = {".DS_Store", "Xiaomi2Pro-official.png", "Xiaomi2Pro-gallery.png"}
FORBIDDEN_SUFFIXES = {".pyc", ".log", ".wav", ".caf", ".pcap", ".pcapng", ".hci", ".pkg", ".zip"}


def ignored(_directory: str, names: list[str]) -> set[str]:
    return {
        name for name in names
        if name in FORBIDDEN_PARTS or name in FORBIDDEN_NAMES
        or Path(name).suffix.lower() in FORBIDDEN_SUFFIXES
    }


def sources() -> tuple[Path, ...]:
    names = ROOT_FILES + TREE_DIRS + ASSET_FILES + SCRIPT_FILES + PACKAGE_DIRS + DOC_FILES
    readme = ROOT / "docs/PUBLIC_README.md"
    # The assembled source must be able to assemble itself.  Its public README
    # already lives at the repository root, while the development tree uses a
    # staged public README supplied by the release editor.
    return tuple(ROOT / name for name in names) + (readme if readme.exists() else ROOT / "README.md",)


def validate() -> list[str]:
    missing = [str(path.relative_to(ROOT)) for path in sources() if not path.exists()]
    if missing:
        raise RuntimeError("missing required public-source input(s): " + ", ".join(missing))
    offenders: list[str] = []
    for source in sources():
        if source.is_symlink():
            offenders.append(str(source.relative_to(ROOT)) + " (symbolic link)")
    for base in TREE_DIRS + PACKAGE_DIRS:
        directory = ROOT / base
        for path in directory.rglob("*"):
            relative = path.relative_to(ROOT)
            if path.is_symlink():
                offenders.append(str(relative) + " (symbolic link)")
            elif path.name == ".DS_Store" or "__pycache__" in relative.parts or path.suffix.lower() == ".pyc":
                continue
            elif any(part in FORBIDDEN_PARTS for part in relative.parts) or path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
                offenders.append(str(relative))
    return offenders


def copy_item(source: Path, stage: Path) -> None:
    destination = stage / source.relative_to(ROOT)
    if source.is_dir():
        # validate() rejects links before this point; copying without following
        # links keeps that guarantee true even if a link appears during a run.
        shutil.copytree(source, destination, ignore=ignored, symlinks=True)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def public_readme(stage: Path) -> None:
    # The maintained public README becomes the repository README.  It is not
    # copied under docs, so the output has one authoritative entry point.
    staged_readme = stage / "docs/PUBLIC_README.md"
    if staged_readme.exists():
        shutil.copy2(staged_readme, stage / "README.md")
        staged_readme.unlink()
    (stage / ".gitignore").write_text(
        ".build/\nbuild/\nrelease/\n.DS_Store\n__pycache__/\n*.pyc\n*.log\n*.wav\n*.caf\n*.pcap\n*.pcapng\n*.hci\n*.pkg\n",
        encoding="utf-8",
    )


def dependency_note(stage: Path) -> None:
    (stage / "DEPENDENCIES.md").write_text(
        "# Build dependencies\n\n"
        "The repository vendors the official Opus 1.6.1 source archive and its upstream provenance. "
        "Run `scripts/build-opus.sh` to create a local static library, then point `YAOBAN_OPUS_PREFIX` "
        "at that prefix before running `scripts/build.sh`. The release does not redistribute a prebuilt libopus.a.\n\n"
        "Building requires macOS with Xcode Command Line Tools, Python 3, zsh, and the system frameworks "
        "named in `scripts/build.sh`. Packaging additionally uses `pkgbuild` and ad-hoc code signing. "
        "Apple PacketLogger is optional for Apple Remote voice capture and is neither included nor downloaded.\n",
        encoding="utf-8",
    )


def audit_output(stage: Path) -> list[str]:
    bad: list[str] = []
    for path in stage.rglob("*"):
        relative = path.relative_to(stage)
        if path.is_symlink():
            bad.append(str(relative) + " (symbolic link)")
        if any(part in FORBIDDEN_PARTS for part in relative.parts):
            bad.append(str(relative))
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            bad.append(str(relative))
    return bad


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate inputs and allowlist rules without writing")
    parser.add_argument("--dry-run", action="store_true", help="print the allowlisted inputs without writing")
    args = parser.parse_args()
    offenders = validate()
    if offenders:
        raise RuntimeError("forbidden files found under an allowlisted directory: " + ", ".join(offenders))
    if args.check:
        print("PASS: public-source inputs and allowlist are ready")
        return
    if args.dry_run:
        print("\n".join(str(path.relative_to(ROOT)) for path in sources()))
        return
    if DESTINATION.exists():
        raise RuntimeError("refusing to overwrite existing release source: " + str(DESTINATION))
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="yovolpen-public-source-", dir=DESTINATION.parent) as temporary:
        stage = Path(temporary) / "source"
        for source in sources():
            copy_item(source, stage)
        public_readme(stage)
        dependency_note(stage)
        bad = audit_output(stage)
        if bad:
            raise RuntimeError("generated source contains excluded material: " + ", ".join(bad))
        stage.rename(DESTINATION)
    print("PASS: wrote " + str(DESTINATION))


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
