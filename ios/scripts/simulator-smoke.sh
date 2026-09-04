#!/usr/bin/env bash
set -Eeuo pipefail

ARTIFACT_ROOT="$RUNNER_TEMP/FirasAI-Artifacts"
mkdir -p "$ARTIFACT_ROOT"
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); phones=[x for a in d["devices"].values() for x in a if "iPhone" in x["name"]]; assert phones,"No iPhone simulator"; print(phones[0]["udid"])')"
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcodebuild -project ios/FirasAI.xcodeproj -scheme FirasAI -configuration Debug \
  -sdk iphonesimulator -destination "id=$DEVICE_ID" \
  -clonedSourcePackagesDirPath "$RUNNER_TEMP/FirasAI-Packages" \
  -derivedDataPath "$RUNNER_TEMP/FirasAI-Smoke" \
  CODE_SIGNING_ALLOWED=NO ENABLE_PREVIEWS=NO build \
  > "$ARTIFACT_ROOT/simulator-build.log" 2>&1 || {
    grep -E 'error:|BUILD FAILED' "$ARTIFACT_ROOT/simulator-build.log" | head -100 || true
    exit 1
  }
APP="$RUNNER_TEMP/FirasAI-Smoke/Build/Products/Debug-iphonesimulator/FirasAI.app"
xcrun simctl install "$DEVICE_ID" "$APP"
xcrun simctl launch "$DEVICE_ID" org.firasai.FirasAI --reliability-smoke
CONTAINER="$(xcrun simctl get_app_container "$DEVICE_ID" org.firasai.FirasAI data)"
REPORT="$CONTAINER/Documents/reliability-smoke.json"
for attempt in $(seq 1 120); do
  [ -f "$REPORT" ] && break
  sleep 2
done
xcrun simctl io "$DEVICE_ID" screenshot "$ARTIFACT_ROOT/simulator-smoke.png"
test -f "$REPORT"
cp "$REPORT" "$ARTIFACT_ROOT/"
find "$CONTAINER/Documents" -maxdepth 1 -name '*.pdf' -exec cp {} "$ARTIFACT_ROOT/" \;
cat "$REPORT"
xcrun swift ios/scripts/render-smoke-pdf.swift "$ARTIFACT_ROOT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("status")=="passed", d' "$REPORT"
(
  cd "$ARTIFACT_ROOT"
  zip -q FirasAI-smoke-evidence.zip reliability-smoke.json simulator-smoke.png *.pdf *-page-*.png
)
