#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$PROJECT_DIR/stop.sh"
"$PROJECT_DIR/start.sh"
