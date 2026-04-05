#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

find_executable() {
  local candidates=(
    "$PROJECT_DIR/.build/arm64-apple-macosx/debug/SevenZipMacUI"
    "$PROJECT_DIR/.build/debug/SevenZipMacUI"
    "/Applications/SevenZipMacUI.app/Contents/MacOS/SevenZipMacUI"
    "$HOME/Applications/SevenZipMacUI.app/Contents/MacOS/SevenZipMacUI"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ "$#" -eq 0 ]]; then
  exit 0
fi

APP_BIN="$(find_executable || true)"
if [[ -z "${APP_BIN:-}" ]]; then
  osascript -e 'display alert "SevenZipMacUI not found" message "Build or install SevenZipMacUI first."' >/dev/null 2>&1 || true
  exit 1
fi

exec "$APP_BIN" --quick-extract "$@"
