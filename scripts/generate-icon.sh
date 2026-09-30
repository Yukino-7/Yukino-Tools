#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift scripts/DrawIcon.swift .build/AppIcon.iconset
python3 - <<'PY'
from pathlib import Path
import struct
iconset = Path('.build/AppIcon.iconset')
chunks = []
for name, kind in [('icon_16x16.png', b'icp4'), ('icon_32x32.png', b'icp5'), ('icon_32x32@2x.png', b'icp6'), ('icon_128x128.png', b'ic07'), ('icon_256x256.png', b'ic08'), ('icon_512x512.png', b'ic09'), ('icon_512x512@2x.png', b'ic10'), ('icon_16x16@2x.png', b'ic11'), ('icon_32x32@2x.png', b'ic12'), ('icon_128x128@2x.png', b'ic13'), ('icon_256x256@2x.png', b'ic14')]:
    data = (iconset / name).read_bytes()
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
content = b''.join(chunks)
Path('Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(content) + 8) + content)
PY
