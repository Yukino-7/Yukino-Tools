#!/bin/bash
set -euo pipefail
app_directory="${1:?Usage: verify-public-app.sh APP_PATH}"
python3 - "$app_directory" <<'PY'
from pathlib import Path
import plistlib
import sys

app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('YukinoBuildFlavor') != 'public':
    raise SystemExit('Refusing to publish an app that is not marked public.')
binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
if b'YUKINO_LOCAL_FEATURE_IMPLEMENTATION_PRESENT' in binary.read_bytes():
    raise SystemExit('Refusing to publish an app containing local feature implementation.')
print('Public app verified.')
PY
