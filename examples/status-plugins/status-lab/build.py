#!/usr/bin/env python3
"""Build "Ghostty Status Lab.app": this branch packaged as a separate app.

The app gets its own name, bundle identifier, configuration and Application Support
directory, so it runs beside a normal Ghostty without touching it. The tracked source
tree is never modified: macos/ is copied to a build directory and adjusted there.

    python3 examples/status-plugins/status-lab/build.py
    python3 examples/status-plugins/status-lab/build.py --name "Ghostty Status Lab" \\
        --bundle-id com.example.ghostty.statuslab --output ~/Desktop

Requirements: the toolchain from HACKING.md (Zig, Xcode with the Metal toolchain,
Nushell). Use --skip-core when GhosttyKit.xcframework is already built.
"""
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PLUGINS = HERE.parent
HELPERS = ("system-stats", "weather", "clock")


def run(command, **kwargs):
    print("+", " ".join(str(part) for part in command), flush=True)
    subprocess.run(command, check=True, **kwargs)


def replace(path: Path, old: str, new: str, required: bool = True):
    text = path.read_text()
    if old not in text:
        if required:
            sys.exit(f"Expected text not found in {path}: {old!r}. The source changed; update build.py.")
        return
    path.write_text(text.replace(old, new))


def prepare(build: Path, name: str, bundle_id: str):
    """Give the copied macOS project the Status Lab identity."""
    project = build / "macos/Ghostty.xcodeproj/project.pbxproj"
    replace(project, "PRODUCT_BUNDLE_IDENTIFIER = com.mitchellh.ghostty;",
            f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle_id}";')
    replace(project, 'PRODUCT_BUNDLE_IDENTIFIER = "com.mitchellh.ghostty-dock-tile";',
            f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle_id}.dock";')
    replace(project, "INFOPLIST_KEY_CFBundleDisplayName = Ghostty;",
            f'INFOPLIST_KEY_CFBundleDisplayName = "{name}";')

    delegate = build / "macos/Sources/App/AppDelegate.swift"
    replace(delegate, 'Ghostty.App(configPath: ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"])',
            "Ghostty.App(configPath: StatusLabBootstrap.prepare())")
    replace(delegate, "ghostty = Ghostty.App()", "ghostty = Ghostty.App(configPath: StatusLabBootstrap.prepare())")
    # A Status Lab build must never update itself to an official Ghostty release.
    replace(delegate, "        updateController.startUpdater()",
            "        // Status Lab builds never start the production updater.")
    replace(delegate, "        updateController.checkForUpdates()",
            "        // Status Lab builds are updated by rebuilding them.")
    shutil.copy2(HERE / "StatusLabBootstrap.swift", build / "macos/Sources/App/StatusLabBootstrap.swift")

    # Do not register as a handler for shell scripts, folders or Services next to Ghostty.
    info = build / "macos/Ghostty-Info.plist"
    data = plistlib.loads(info.read_bytes())
    for key in ("NSServices", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "NSDockTilePlugIn"):
        data.pop(key, None)
    data["SUEnableAutomaticChecks"] = False
    data["SUAutomaticallyUpdate"] = False
    info.write_bytes(plistlib.dumps(data))


def git(*arguments) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(REPO), *arguments], text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""


def package(source: Path, target: Path, name: str, bundle_id: str, helpers: Path):
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target, symlinks=True)
    destination = target / "Contents/Helpers"
    destination.mkdir(exist_ok=True)
    for helper in HELPERS:
        shutil.copy2(helpers / helper, destination / helper)
    shutil.copy2(HERE / "status-lab-defaults.config", target / "Contents/Resources/status-lab-defaults.config")

    version = (PLUGINS / "STATUS_LAB_VERSION").read_text().strip()
    major, minor, patch = map(int, version.split("."))
    core = re.search(r'\.version = "([^"]+)"', (REPO / "build.zig.zon").read_text()).group(1)
    head = git("rev-parse", "HEAD")
    plist = target / "Contents/Info.plist"
    data = plistlib.loads(plist.read_bytes())
    assert data["CFBundleIdentifier"] == bundle_id, data["CFBundleIdentifier"]
    data.update({
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(major * 10000 + minor * 100 + patch),
        "StatusLabVersion": version,
        "StatusLabBuildDate": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
        "StatusLabGhosttyVersion": core,
        "StatusLabUpstreamCommit": git("merge-base", "HEAD", "origin/main") or head,
        "StatusLabSourceCommit": head,
        "StatusLabSourceState": "Locally modified" if git("status", "--porcelain") else "Clean",
        "GhosttyBuild": f"Status Lab {version}; Ghostty {core}",
        "GhosttyCommit": head,
    })
    plist.write_bytes(plistlib.dumps(data))

    # Ad-hoc signature: runs on this Mac. Distributing it needs a Developer ID.
    run(["/usr/bin/xattr", "-cr", str(target)])
    for helper in HELPERS:
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(destination / helper)])
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements", str(target)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", default="Ghostty Status Lab")
    parser.add_argument("--bundle-id", default="com.example.ghostty.statuslab",
                        help="Use your own reverse-DNS identifier; it also names the settings directory.")
    parser.add_argument("--output", default=str(REPO / "zig-out/status-lab"))
    parser.add_argument("--build-dir", default=str(Path(tempfile.gettempdir()) / "ghostty-status-lab-build"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--nu", default="nu")
    parser.add_argument("--skip-core", action="store_true", help="Reuse the existing GhosttyKit.xcframework.")
    args = parser.parse_args()

    if not args.skip_core:
        run([args.zig, "build", "-Doptimize=ReleaseFast", "-Demit-macos-app=false"], cwd=REPO)
    if not (REPO / "macos/GhosttyKit.xcframework").exists():
        sys.exit("macos/GhosttyKit.xcframework is missing; run without --skip-core.")

    build = Path(args.build_dir)
    # Fresh sources every time; keep the Xcode build folder for incremental builds.
    if (build / "macos").exists():
        for child in (build / "macos").iterdir():
            if child.name != "build":
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
    build.mkdir(parents=True, exist_ok=True)
    shutil.copytree(REPO / "macos", build / "macos", symlinks=True, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("build", ".DS_Store"))
    for folder in ("images", "zig-out/share"):
        if (build / folder).exists():
            shutil.rmtree(build / folder)
        shutil.copytree(REPO / folder, build / folder, symlinks=True)
    prepare(build, args.name, args.bundle_id)
    run([args.nu, str(build / "macos/build.nu"), "--configuration", "ReleaseLocal"], cwd=build / "macos")

    helpers = build / "helpers"
    helpers.mkdir(exist_ok=True)
    for helper in HELPERS:
        run(["swiftc", "-O", str(PLUGINS / f"{helper}.swift"), "-o", str(helpers / helper)])

    output = Path(os.path.expanduser(args.output))
    output.mkdir(parents=True, exist_ok=True)
    target = output / f"{args.name}.app"
    package(build / "macos/build/ReleaseLocal/Ghostty.app", target, args.name, args.bundle_id, helpers)
    print(f"\nBuilt {target}\nOpen it with: open {str(target)!r}")


if __name__ == "__main__":
    main()
