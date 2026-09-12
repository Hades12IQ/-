#!/usr/bin/env python3
"""Build and test this exact source on the device returned by the genuine iOS15 probe.

The existing native gallery and normal reliability fixture run without forceLegacyUI. The
manifest binds their original reports and screenshots to the actual runtime and app binaries.
No IPA is created or published by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

BUNDLE_ID = "org.firasai.FirasAI"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    probe_path = output / "probe.json"
    probe = json.loads(probe_path.read_text(encoding="utf-8"))
    report = {"sourceCommit": os.environ.get("GITHUB_SHA"), "runID": os.environ.get("GITHUB_RUN_ID"),
              "runtime": probe.get("runtime"), "deviceID": probe.get("deviceID"),
              "forcedLegacyUI": False, "steps": [], "errors": [], "appLaunched": False,
              "status": "running"}
    started = time.monotonic()
    deadline = started + 2340
    container = None

    def save():
        report["elapsedSeconds"] = round(time.monotonic() - started, 2)
        (output / "app-verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def run(name, command, timeout=60, check=True):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("app-verification-time-budget-exhausted")
        began = time.monotonic()
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
                                "seconds": round(time.monotonic() - began, 2), "log": log.name})
        save()
        if check and code != 0:
            raise RuntimeError(name + "-failed; see " + log.name)
        return code, text

    def copy_fixture_artifacts():
        if container is None:
            return
        documents = container / "Documents"
        # This is the newly-created, unauthenticated probe simulator. Copy only artifacts from
        # the two local fixture routes, and preserve their original JSON bytes.
        patterns = ("native-gallery-*.png", "native-gallery-*.json", "reliability-*.pdf",
                    "reliability-smoke.json", "streaming-math.png", "legacy-*.png")
        for pattern in patterns:
            for source in documents.glob(pattern):
                if source.is_file():
                    shutil.copy2(source, output / source.name)

    try:
        device = report["deviceID"]
        runtime = probe.get("runtime") or {}
        if not probe.get("booted") or runtime.get("version") != "15.5":
            raise RuntimeError("genuine-iOS15.5-boot-evidence-required")
        if not device or not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
            raise RuntimeError("invalid-probe-device-identifier")
        if not report["sourceCommit"] or probe.get("sourceCommit") != report["sourceCommit"]:
            raise RuntimeError("runtime-probe-source-commit-mismatch")
        _, source = run("app-source", ["git", "rev-parse", "HEAD"])
        if source.strip() != report["sourceCommit"]:
            raise RuntimeError("checkout-does-not-match-probe-source")
        _, devices = run("app-runtime-before", ["xcrun", "simctl", "list", "devices", "--json"])
        rows = json.loads(devices)["devices"].get(runtime["identifier"], [])
        if not any(row.get("udid") == device and row.get("state") == "Booted" for row in rows):
            raise RuntimeError("probe-device-is-no-longer-booted-on-requested-runtime")
        temporary = Path(os.environ["RUNNER_TEMP"])
        derived = temporary / "FirasAI-iOS15-App"
        packages = temporary / "FirasAI-iOS15-Packages"
        run("ios15-app-build", ["xcodebuild", "-project", "ios/FirasAI.xcodeproj", "-scheme", "FirasAI",
            "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + device,
            "-clonedSourcePackagesDirPath", str(packages), "-skipPackagePluginValidation", "-skipMacroValidation",
            "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "ENABLE_PREVIEWS=NO", "build"], timeout=1500)
        app = derived / "Build/Products/Debug-iphonesimulator/FirasAI.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise RuntimeError("unexpected-app-bundle-identifier")
        report["bundleID"] = BUNDLE_ID
        report["minimumOSVersion"] = info.get("MinimumOSVersion")
        report["bundleVersion"] = info.get("CFBundleVersion")
        report["binaries"] = {name: digest(app / name) for name in ("FirasAI", "FirasAI.debug.dylib")
                              if (app / name).is_file()}
        run("ios15-app-architecture", ["file", str(app / "FirasAI")])
        run("ios15-app-install", ["xcrun", "simctl", "install", device, str(app)], timeout=90)
        _, data_path = run("ios15-app-container", ["xcrun", "simctl", "get_app_container", device, BUNDLE_ID, "data"])
        container = Path(data_path.strip())
        if not container.is_absolute() or not container.is_dir():
            raise RuntimeError("invalid-installed-app-container")
        gallery_code, _ = run("ios15-native-gallery", ["bash", "ios/scripts/native-gallery-smoke.sh",
            device, str(output), "native"], timeout=180, check=False)
        copy_fixture_artifacts()
        gallery_file = output / "native-gallery-native-complete.json"
        if not gallery_file.is_file():
            gallery_file = output / "native-gallery-complete.json"
        if gallery_file.is_file():
            gallery = json.loads(gallery_file.read_text(encoding="utf-8"))
            report["appLaunched"] = True
            report["actualOSVersion"] = gallery.get("actualOSVersion")
            report["galleryStatus"] = gallery.get("status")
            report["galleryReport"] = gallery_file.name
            if gallery.get("actualOSVersion") != runtime["version"] or gallery.get("runtimeKind") != "simulator":
                report["errors"].append("gallery-reported-a-different-actual-runtime")
            if gallery.get("forcedLegacyUI") or gallery.get("status") != "passed":
                report["errors"].append("native-gallery-did-not-pass-without-forced-compatibility")
        else:
            report["errors"].append("native-gallery-report-missing")
        if gallery_code != 0:
            report["errors"].append("native-gallery-run-failed")

        run("terminate-gallery", ["xcrun", "simctl", "terminate", device, BUNDLE_ID], check=False)
        smoke_file = container / "Documents/reliability-smoke.json"
        smoke_file.unlink(missing_ok=True)
        run("ios15-reliability-launch", ["xcrun", "simctl", "launch", device, BUNDLE_ID, "--reliability-smoke"])
        report["appLaunched"] = True
        wait_deadline = min(deadline, time.monotonic() + 240)
        while not smoke_file.is_file() and time.monotonic() < wait_deadline:
            time.sleep(2)
        run("ios15-reliability-screen", ["xcrun", "simctl", "io", device, "screenshot",
            str(output / "ios15-reliability-screen.png")], check=False)
        copy_fixture_artifacts()
        if not smoke_file.is_file():
            raise RuntimeError("normal-reliability-report-missing-after-existing-240-second-bound")
        smoke = json.loads(smoke_file.read_text(encoding="utf-8"))
        report["reliabilityStatus"] = smoke.get("status")
        report["reliabilityReport"] = "reliability-smoke.json"
        if smoke.get("status") != "passed" or smoke.get("forcedLegacyUI") is not False:
            report["errors"].append("normal-reliability-checks-failed; see original report")
        run("ios15-render-smoke-pdfs", ["xcrun", "swift", "ios/scripts/render-smoke-pdf.swift", str(output)], timeout=120)
        qa = temporary / "FirasAI-iOS15-PDF-QA"
        run("ios15-pdf-qa-environment", ["python3", "-m", "venv", str(qa)])
        python = str(qa / "bin/python")
        run("ios15-pdf-qa-dependency", [python, "-m", "pip", "install", "--quiet", "--disable-pip-version-check",
            "PyMuPDF==1.27.2.3"], timeout=180)
        code, _ = run("ios15-pdf-qa", [python, "ios/scripts/validate-final-pdf.py", str(output)], timeout=120, check=False)
        if code != 0:
            report["errors"].append("independent-pdf-clipping-validation-failed")
    except Exception as error:
        report["errors"].append(str(error))
    finally:
        copy_fixture_artifacts()
        report["status"] = "passed" if not report["errors"] else "failed"
        report["artifacts"] = {path.name: {"bytes": path.stat().st_size, "sha256": digest(path)}
                               for path in sorted(output.iterdir()) if path.is_file()
                               and path.suffix in (".png", ".pdf", ".json")
                               and path.name not in ("app-verification.json", "probe.json")}
        save()
        probe["appTested"] = report["appLaunched"]
        probe["appVerification"] = "app-verification.json"
        probe["appVerificationStatus"] = report["status"]
        if probe.get("booted"):
            probe["result"] = "real-iOS15-runtime-booted; app verification reported separately"
        probe_path.write_text(json.dumps(probe, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
