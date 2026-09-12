#!/usr/bin/env python3
"""Bounded, standalone Apple-runtime probe; never publishes an app or changes the main workflow.

Run on an ephemeral macOS CI runner with Xcode 26 selected:
  python3 ios/scripts/probe-ios15-runtime.py --output "$RUNNER_TEMP/iOS15-Probe"

The native Apple download command runs first. Old package-based runtimes may require the
signed installer from the exact source in Apple's public catalogue. No patched runtimes,
host-version overrides, third-party mirrors, Apple account or provisioning secrets are used.
A successful probe leaves ONLY its newly-created device booted for a following app test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

INDEX = "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"
VERSION = "15.5"


def bundle_manifest(root, deadline):
    """Hash bytes, relative names, modes and symlink targets without following runtime links."""
    checksum = hashlib.sha256()
    counts = {"files": 0, "directories": 0, "symlinks": 0, "bytes": 0}

    def walk(directory):
        if time.monotonic() >= deadline:
            raise RuntimeError("runtime-manifest-time-budget-exhausted")
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            info = path.lstat()
            name = path.relative_to(root).as_posix()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                row = [name, "symlink", mode, os.readlink(path)]
                counts["symlinks"] += 1
            elif stat.S_ISDIR(info.st_mode):
                row = [name, "directory", mode]
                counts["directories"] += 1
            elif stat.S_ISREG(info.st_mode):
                with path.open("rb") as stream:
                    sha = hashlib.file_digest(stream, "sha256").hexdigest()
                row = [name, "file", mode, info.st_size, sha]
                counts["files"] += 1
                counts["bytes"] += info.st_size
            else:
                raise RuntimeError("unexpected-special-file-in-runtime: " + name)
            checksum.update(json.dumps(row, ensure_ascii=True, separators=(",", ":")).encode() + b"\n")
            if stat.S_ISDIR(info.st_mode):
                walk(path)

    walk(root)
    return dict(counts, sha256=checksum.hexdigest())


def runtime_bundle_metadata(bundle, version, build):
    """A package payload must identify the exact Apple OS requested by the live catalogue."""
    if bundle.is_symlink() or not bundle.is_dir() or bundle.suffix != ".simruntime":
        raise RuntimeError("invalid-runtime-bundle-root")
    info_path = bundle / "Contents/Info.plist"
    if info_path.is_symlink() or not info_path.resolve().is_relative_to(bundle.resolve()):
        raise RuntimeError("runtime-info-plist-escapes-bundle")
    info = plistlib.loads(info_path.read_bytes())
    expected_id = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
    if info.get("CFBundleIdentifier") != expected_id:
        raise RuntimeError("extracted-runtime-identifier-mismatch")
    systems = [bundle / path for path in (
        "Contents/Resources/RuntimeRoot/System/Library/CoreServices/SystemVersion.plist",
        "Contents/RuntimeRoot/System/Library/CoreServices/SystemVersion.plist")]
    systems = [path for path in systems if path.is_file() and not path.is_symlink()
               and path.resolve().is_relative_to(bundle.resolve())]
    if len(systems) != 1:
        raise RuntimeError("extracted-runtime-system-version-layout-mismatch")
    system = plistlib.loads(systems[0].read_bytes())
    if system.get("ProductVersion") != version or system.get("ProductBuildVersion") != build:
        raise RuntimeError("extracted-runtime-version-or-build-mismatch")
    return {"bundleIdentifier": expected_id, "systemVersion": system,
            "infoPlistSHA256": hashlib.sha256(info_path.read_bytes()).hexdigest(),
            "systemVersionSHA256": hashlib.sha256(systems[0].read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--method", choices=("auto", "apple-cli", "apple-package"), default="auto")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    report = {"requestedRuntime": VERSION, "hostArchitecture": platform.machine(), "steps": [],
              "booted": False, "appTested": False, "sourceIndex": INDEX,
              "sourceCommit": os.environ.get("GITHUB_SHA"), "runID": os.environ.get("GITHUB_RUN_ID")}
    began = time.monotonic()
    deadline = began + 1080
    mounted = None
    device = None

    def save():
        report["elapsedSeconds"] = round(time.monotonic() - began, 2)
        (output / "probe.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def run(name, command, timeout=60, check=True):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("probe-time-budget-exhausted")
        started = time.monotonic()
        log = output / (name + ".log")
        print(name, flush=True)
        with log.open("wb") as stream:
            process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=min(timeout, remaining))
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                code = 124
        text = log.read_text(encoding="utf-8", errors="replace")
        report["steps"].append({"name": name, "exitCode": code, "timedOut": timed_out,
                                "seconds": round(time.monotonic() - started, 2), "log": log.name})
        save()
        if check and code != 0:
            raise RuntimeError(name + "-failed; see " + log.name)
        return code, text

    def runtimes(name):
        _, text = run(name, ["xcrun", "simctl", "list", "runtimes", "--json"])
        return json.loads(text)["runtimes"]

    def selected_runtime(rows):
        return next((row for row in rows if row.get("version") == VERSION), None)

    def version_tuple(value):
        return tuple(int(v) for v in re.findall(r"\d+", value)[:3])

    try:
        if platform.system() != "Darwin":
            raise RuntimeError("requires-macOS; no download or installation was attempted")
        _, host = run("host", ["sw_vers", "-productVersion"])
        _, xcode = run("xcode", ["xcodebuild", "-version"])
        report["hostVersion"] = host.strip()
        match = re.search(r"Xcode\s+(\S+)", xcode)
        if not match or not match.group(1).startswith("26."):
            raise RuntimeError("select-Xcode-26-first; Xcode27 has a higher simulator minimum")
        report["xcodeVersion"] = match.group(1)
        run("disk-space", ["df", "-h", str(output)])
        raw = urllib.request.urlopen(INDEX, timeout=30).read()
        (output / "apple-index.plist").write_bytes(raw)
        catalogue = plistlib.loads(raw)
        entry = next(row for row in catalogue["downloadables"]
                     if row.get("platform") == "com.apple.platform.iphoneos"
                     and row.get("simulatorVersion", {}).get("version") == VERSION)
        report["catalogueEntry"] = entry
        report["catalogueSHA256"] = hashlib.sha256(raw).hexdigest()
        requirements = entry.get("hostRequirements", {})
        for key, actual in (("maxHostVersion", host.strip()), ("maxXcodeVersion", match.group(1))):
            if key in requirements and version_tuple(actual) > version_tuple(requirements[key]):
                raise RuntimeError("Apple-catalogue-rejects-" + key)
        if host.strip().startswith("14."):
            raise RuntimeError("Apple-excludes-iOS15-Simulator-on-macOS-Sonoma14")
        source = entry["source"]
        parsed = urllib.parse.urlparse(source)
        if parsed.scheme != "https" or parsed.netloc != "devimages-cdn.apple.com":
            raise RuntimeError("unexpected-runtime-source; refusing installation")
        head = urllib.request.urlopen(urllib.request.Request(source, method="HEAD"), timeout=30)
        report["publicDownload"] = {"status": head.status, "url": head.url,
                                    "contentLength": head.headers.get("Content-Length"),
                                    "contentType": head.headers.get("Content-Type")}
        head.close()
        save()
        runtime = selected_runtime(runtimes("runtimes-before"))
        downloads = output / "downloads"
        downloads.mkdir(exist_ok=True)
        if runtime is None and args.method in ("auto", "apple-cli"):
            run("apple-download-platform", ["xcodebuild", "-downloadPlatform", "iOS",
                "-buildVersion", VERSION, "-exportPath", str(downloads),
                "-architectureVariant", "universal"], timeout=360, check=False)
            runtime = selected_runtime(runtimes("runtimes-after-cli"))
        if runtime is None and args.method in ("auto", "apple-package"):
            if entry.get("contentType") != "package":
                raise RuntimeError("catalogue-content-type-changed; re-review-install-method")
            image = downloads / Path(parsed.path).name
            if not image.exists():
                run("apple-download-package", ["curl", "--fail", "--location", "--proto", "=https",
                    "--connect-timeout", "20", "--max-time", "360", "--output", str(image), source], timeout=380)
            expected = report["publicDownload"]["contentLength"]
            if expected and image.stat().st_size != int(expected):
                raise RuntimeError("download-length-mismatch")
            # Apple's catalogue fileSize differs from its CDN Content-Length; record both. The
            # image verifier and Apple package signature, not that estimate, establish integrity.
            report["downloadedBytes"] = image.stat().st_size
            with image.open("rb") as stream:
                report["downloadSHA256"] = hashlib.file_digest(stream, "sha256").hexdigest()
            run("image-integrity", ["hdiutil", "verify", str(image)], timeout=90)
            mountpoint = output / "runtime-installer"
            mountpoint.mkdir(exist_ok=True)
            run("mount-installer", ["hdiutil", "attach", "-readonly", "-nobrowse",
                "-mountpoint", str(mountpoint), str(image)], timeout=60)
            mounted = mountpoint
            packages = list(mountpoint.glob("*.pkg"))
            if len(packages) != 1 or not packages[0].resolve().is_relative_to(mountpoint.resolve()):
                raise RuntimeError("unexpected-installer-layout")
            _, signature = run("apple-package-signature", ["pkgutil", "--check-signature", str(packages[0])])
            if "Software Update" not in signature and "Apple Inc." not in signature:
                raise RuntimeError("unexpected-package-signer; refusing installation")
            install_code, installer_log = run("install-apple-runtime",
                ["sudo", "-n", "installer", "-pkg", str(packages[0]), "-target", "/"], timeout=240, check=False)
            if install_code != 0:
                if "The package is attempting to install content to the system volume" not in installer_log:
                    raise RuntimeError("install-apple-runtime-failed; see install-apple-runtime.log")
                # A legacy pkg installs at an obsolete system-volume location. Expand its already
                # verified payload with Apple's tool; register only the intact .simruntime in the
                # documented CoreSimulator bundle directory, without running or editing scripts.
                report["legacyInstallerFallback"] = "verified-Apple-runtime-bundle-registration"
                expanded = output / ("expanded-apple-package-" + uuid.uuid4().hex)
                run("expand-verified-apple-package", ["pkgutil", "--expand-full", str(packages[0]), str(expanded)], timeout=240)
                bundles = []
                for directory, children, _ in os.walk(expanded, followlinks=False):
                    for name in list(children):
                        if name.endswith(".simruntime"):
                            bundles.append(Path(directory) / name)
                            children.remove(name)
                if len(bundles) != 1 or not bundles[0].resolve().is_relative_to(expanded.resolve()):
                    raise RuntimeError("unexpected-expanded-runtime-bundle-layout")
                bundle = bundles[0]
                run("extracted-runtime-info", ["plutil", "-p", str(bundle / "Contents/Info.plist")])
                metadata = runtime_bundle_metadata(bundle, VERSION, entry["simulatorVersion"]["buildUpdate"])
                metadata["packageRelativePath"] = bundle.relative_to(expanded).as_posix()
                print("verify-original-runtime-bundle", flush=True)
                before = bundle_manifest(bundle, deadline)
                metadata["originalManifest"] = before
                report["extractedRuntime"] = metadata
                save()
                base = Path("/Library/Developer/CoreSimulator/Profiles/Runtimes")
                if base.resolve() != base or any(path.is_symlink() for path in (base, *base.parents)):
                    raise RuntimeError("unexpected-CoreSimulator-registration-directory")
                destination = base / bundle.name
                if destination.exists() or destination.is_symlink():
                    raise RuntimeError("runtime-destination-already-exists; no overwrite allowed")
                run("create-runtime-registration-directory", ["sudo", "-n", "mkdir", "-p", str(base)])
                available = shutil.disk_usage(base).free
                report["registrationFreeBytes"] = available
                if available < before["bytes"] + 1_000_000_000:
                    raise RuntimeError("insufficient-space-for-intact-runtime-copy")
                stage = base / (".firas-ios15-stage-" + uuid.uuid4().hex)
                if stage.exists() or stage.is_symlink():
                    raise RuntimeError("runtime-stage-already-exists")
                # Stage without the .simruntime extension so CoreSimulator never sees half a copy.
                run("copy-intact-apple-runtime", ["sudo", "-n", "ditto", "--rsrc", "--extattr", "--acl",
                    str(bundle), str(stage)], timeout=240)
                print("verify-copied-runtime-bundle", flush=True)
                after = bundle_manifest(stage, deadline)
                metadata["copiedManifest"] = after
                if after != before:
                    raise RuntimeError("runtime-copy-content-or-permission-mismatch")
                if destination.exists() or destination.is_symlink():
                    raise RuntimeError("runtime-destination-created-concurrently; no overwrite allowed")
                run("register-intact-apple-runtime", ["sudo", "-n", "mv", "-n", str(stage), str(destination)])
                if stage.exists() or not destination.is_dir():
                    raise RuntimeError("runtime-registration-did-not-complete")
                metadata["registeredPath"] = str(destination)
                metadata["registeredMetadata"] = runtime_bundle_metadata(destination, VERSION,
                    entry["simulatorVersion"]["buildUpdate"])
                run("runtime-signature-diagnostic", ["codesign", "--verify", "--deep", "--strict", str(destination)],
                    timeout=120, check=False)
                save()
            runtime = selected_runtime(runtimes("runtimes-after-package"))
        if runtime is None:
            raise RuntimeError("runtime-not-registered")
        report["runtime"] = runtime
        if not runtime.get("isAvailable", False):
            raise RuntimeError("runtime-unavailable: " + runtime.get("availabilityError", "see runtime metadata"))
        root = Path(runtime.get("bundlePath", ""))
        if root.is_dir() and str(root) != ".":
            for relative in ("Contents/Resources/RuntimeRoot/usr/lib/dyld", "Contents/RuntimeRoot/usr/lib/dyld"):
                binary = root / relative
                if binary.exists():
                    run("runtime-architectures", ["file", str(binary)], check=False)
                    break
        _, text = run("device-types", ["xcrun", "simctl", "list", "devicetypes", "--json"])
        types = json.loads(text)["devicetypes"]
        device_type = next(row for row in types if row["name"] == "iPhone 13")
        _, text = run("create-probe-device", ["xcrun", "simctl", "create", "FirasAI iOS15 runtime probe",
                                             device_type["identifier"], runtime["identifier"]])
        device = text.strip()
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
            raise RuntimeError("unexpected-created-device-identifier")
        report["deviceID"] = device
        report["deviceType"] = device_type
        run("boot-probe-device", ["xcrun", "simctl", "boot", device], timeout=90)
        run("wait-for-boot", ["xcrun", "simctl", "bootstatus", device, "-b"], timeout=120)
        _, text = run("devices-after-boot", ["xcrun", "simctl", "list", "devices", "--json"])
        devices = json.loads(text)["devices"].get(runtime["identifier"], [])
        actual = next(row for row in devices if row.get("udid") == device)
        if actual.get("state") != "Booted":
            raise RuntimeError("device-not-booted")
        run("actual-ios15-screen", ["xcrun", "simctl", "io", device, "screenshot", str(output / "ios15-system.png")])
        report["booted"] = True
        report["result"] = "real-iOS15-runtime-booted; app-not-tested-yet"
    except Exception as error:
        report["result"] = str(error)
    finally:
        if mounted is not None:
            try:
                run("detach-installer", ["hdiutil", "detach", str(mounted)], timeout=30, check=False)
            except Exception as error:
                report["detachDiagnostic"] = str(error)
        save()
    print(json.dumps({key: report.get(key) for key in
                      ("result", "hostVersion", "hostArchitecture", "xcodeVersion", "deviceID", "booted", "appTested")}, indent=2))
    return 0 if report["booted"] else 1


if __name__ == "__main__":
    sys.exit(main())
