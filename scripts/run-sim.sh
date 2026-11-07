#!/usr/bin/env bash
# Build Carrel and (re)launch it in a simulator.
#   scripts/run-sim.sh tv    [device name]   e.g. "Apple TV 4K (3rd generation)"
#   scripts/run-sim.sh phone [device name]   e.g. "iPhone 16 Pro"
# With no device name, uses the booted simulator of that kind, else the first available one.
# Set PULL=1 to `git pull` first. Pass --fresh to delete the app first (clears its data).
set -euo pipefail

cd "$(dirname "$0")/.."

kind="${1:-}"
shift || true
fresh=0
name=""
for arg in "$@"; do
  case "$arg" in
    --fresh) fresh=1 ;;
    *) name="$arg" ;;
  esac
done

case "$kind" in
  tv)    scheme=CarrelTV; pattern="Apple TV"; products="Debug-appletvsimulator" ;;
  phone) scheme=Carrel;   pattern="iPhone";   products="Debug-iphonesimulator" ;;
  *) echo "usage: $0 tv|phone [device name] [--fresh]" >&2; exit 64 ;;
esac
bundle_id=au.com.bitcoinbrisbane.carrel

[[ "${PULL:-0}" == 1 ]] && git pull --ff-only

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
xcodegen --quiet

# Pick a simulator: the named one, else a booted one of this kind, else the first available.
devices=$(xcrun simctl list devices available)
udid_of() { sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p' | head -1; }
if [[ -n "$name" ]]; then
  udid=$(grep -F "    $name (" <<<"$devices" | udid_of)
else
  udid=$(grep -E "^ +$pattern" <<<"$devices" | grep "(Booted)" | udid_of)
  [[ -z "$udid" ]] && udid=$(grep -E "^ +$pattern" <<<"$devices" | udid_of)
fi
if [[ -z "$udid" ]]; then
  echo "No $pattern simulator found. Add one in Xcode (Window > Devices and Simulators), or list them with: xcrun simctl list devices available" >&2
  exit 1
fi
label=$(grep -F "$udid" <<<"$devices" | sed -E 's/^ +//; s/ \([0-9A-F-]{36}\).*//')
echo "▸ $scheme on $label"

xcrun simctl boot "$udid" 2>/dev/null || true      # already booted is fine
open -a Simulator --args -CurrentDeviceUDID "$udid"

echo "▸ Building…"
log=build/run-$kind.log
mkdir -p build
if ! xcodebuild -scheme "$scheme" -destination "id=$udid" -derivedDataPath build build >"$log" 2>&1; then
  grep -E "error:" -A4 "$log" | head -40 || true
  echo "✗ Build failed. Full log: $log" >&2
  exit 1
fi

app=$(find "build/Build/Products/$products" -maxdepth 1 -name "*.app" | head -1)
[[ -z "$app" ]] && { echo "✗ Built, but no .app in build/Build/Products/$products" >&2; exit 1; }

xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
if [[ $fresh == 1 ]]; then
  xcrun simctl uninstall "$udid" "$bundle_id" 2>/dev/null || true
fi
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$bundle_id" >/dev/null
echo "✓ Carrel running on $label"
