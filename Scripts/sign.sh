#!/bin/bash
# Ad hoc signs an app bundle. Not notarised: YTA is built and run locally.
set -euo pipefail
APP="${1:?usage: sign.sh path/to/YTA.app}"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
