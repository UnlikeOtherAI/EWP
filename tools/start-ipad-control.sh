#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'Usage: scripts/start-ipad-control.sh DEVICE_UDID APPLE_TEAM_ID' >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
mkdir -p artifacts
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/EWP.xcodeproj -scheme EWP -configuration Debug \
  -destination "id=$1" -derivedDataPath artifacts/DerivedData \
  "DEVELOPMENT_TEAM=$2" -allowProvisioningUpdates build-for-testing \
  > artifacts/device-build.log 2>&1
python3 - <<'PY'
from pathlib import Path
import plistlib
paths = list(Path('artifacts/DerivedData/Build/Products').glob('*iphoneos*.xctestrun'))
if len(paths) != 1:
    raise SystemExit('Expected one physical iOS test manifest')
p = paths[0]
d = plistlib.loads(p.read_bytes())
for c in d.get('TestConfigurations', []):
    for t in c.get('TestTargets', []):
        t.setdefault('EnvironmentVariables', {})['EWP_USB_CONTROL'] = '1'
for t in d.values():
    if isinstance(t, dict) and 'TestBundlePath' in t:
        t.setdefault('EnvironmentVariables', {})['EWP_USB_CONTROL'] = '1'
p.write_bytes(plistlib.dumps(d))
Path('artifacts/ui-test-manifest-path').write_text(str(p))
PY
manifest_path="$(cat artifacts/ui-test-manifest-path)"
exec xcodebuild test-without-building -xctestrun "$manifest_path" \
  -destination "id=$1" -only-testing:EWPUITests/USBControlTests/testUSBControl \
  -parallel-testing-enabled NO > artifacts/usb-control-session.log 2>&1
