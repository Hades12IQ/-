#!/usr/bin/env bash
# Capture the actual native screens; the app report records the actual simulator OS.
set -Eeuo pipefail
DEVICE_ID="$1"
ARTIFACT_ROOT="$2"
MODE="${3:-native}"
mkdir -p "$ARTIFACT_ROOT"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE_ID" org.firasai.FirasAI data)"
REPORT="$CONTAINER/Documents/native-gallery-complete.json"
xcrun simctl terminate "$DEVICE_ID" org.firasai.FirasAI || true
rm -f "$REPORT"
ARGS=(--reliability-smoke --native-gallery)
if [ "$MODE" = forced-legacy ]; then ARGS+=(--reliability-legacy-ui); fi
xcrun simctl launch "$DEVICE_ID" org.firasai.FirasAI "${ARGS[@]}"
for attempt in $(seq 1 60); do
  [ -f "$REPORT" ] && break
  sleep 2
done
find "$CONTAINER/Documents" -maxdepth 1 -name 'native-gallery-*.png' -exec cp {} "$ARTIFACT_ROOT/" \;
find "$CONTAINER/Documents" -maxdepth 1 -name 'native-gallery-ios-*.json' -exec cp {} "$ARTIFACT_ROOT/" \;
test -f "$REPORT"
cp "$REPORT" "$ARTIFACT_ROOT/native-gallery-$MODE-complete.json"
python3 - "$REPORT" "$MODE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('status') == 'passed', d
assert bool(d.get('forcedLegacyUI')) == (sys.argv[2] == 'forced-legacy'), d
assert d.get('actualOSVersion'), 'Gallery must name its real OS version'
assert d.get('screens'), 'Gallery must contain native screenshots'
print(json.dumps(d, ensure_ascii=False, indent=2))
PY
