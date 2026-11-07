#!/usr/bin/env bash
# Archive Carrel for TestFlight / the App Store, and optionally upload it.
#
#   scripts/archive.sh phone      # iPhone app
#   scripts/archive.sh tv         # Apple TV app
#   scripts/archive.sh both
#
# The team comes from Config/Team.local.xcconfig (DEVELOPMENT_TEAM = …), or CARREL_TEAM_ID.
#
# The build number is the commit count (git rev-list --count HEAD), so every upload from a
# newer commit is higher. Commit before archiving.
#
# Uploading: with UPLOAD=1 the export goes straight to App Store Connect. That uses the Apple ID
# signed in to Xcode (Settings › Accounts), or an App Store Connect API key if these are set:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the AuthKey_XXXX.p8 file)
# Without UPLOAD=1 it exports to build/export/<scheme>/ and opens the archive in Xcode's Organizer.
set -euo pipefail
cd "$(dirname "$0")/.."

what="${1:-}"
case "$what" in
  phone) schemes=(Carrel) ;;
  tv) schemes=(CarrelTV) ;;
  both) schemes=(Carrel CarrelTV) ;;
  *) echo "usage: $0 phone|tv|both" >&2; exit 64 ;;
esac

if [[ -z "${CARREL_TEAM_ID:-}" && -f Config/Team.local.xcconfig ]]; then
  CARREL_TEAM_ID=$(sed -nE 's/^ *DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' Config/Team.local.xcconfig | head -1)
fi
if [[ -z "${CARREL_TEAM_ID:-}" ]]; then
  echo "No team. Create Config/Team.local.xcconfig with: DEVELOPMENT_TEAM = <your organisation team ID>" >&2
  echo "(developer.apple.com › Account › Membership details shows the Team ID.)" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "⚠︎ Uncommitted changes: this build's number ($(git rev-list --count HEAD)) is shared with the last commit." >&2
fi
if ! grep -qE '^ *CarrelSupportEmail: *"?[^" ]+@' project.yml; then
  echo "✗ Set CarrelSupportEmail in project.yml first: App Review needs a working address for content reports (Guideline 1.2)." >&2
  exit 1
fi
build=$(git rev-list --count HEAD)
version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?/\1/p' project.yml | head -1)
echo "▸ Carrel $version ($build)"

xcodegen --quiet

auth=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  auth=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

mkdir -p build
for scheme in "${schemes[@]}"; do
  case "$scheme" in
    Carrel) destination="generic/platform=iOS" ;;
    CarrelTV) destination="generic/platform=tvOS" ;;
  esac
  archive="build/archives/$scheme-$version-$build.xcarchive"
  log="build/archive-$scheme.log"
  echo "▸ Archiving $scheme…"
  if ! xcodebuild archive -scheme "$scheme" -destination "$destination" -archivePath "$archive" \
      -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
      DEVELOPMENT_TEAM="$CARREL_TEAM_ID" CURRENT_PROJECT_VERSION="$build" >"$log" 2>&1; then
    grep -E "error:" -A4 "$log" | head -40 || true
    echo "✗ Archive failed. Full log: $log" >&2
    exit 1
  fi

  options="build/ExportOptions-$scheme.plist"
  dest=$([[ "${UPLOAD:-0}" == 1 ]] && echo upload || echo export)
  cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$dest</string>
  <key>teamID</key><string>$CARREL_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

  [[ "$dest" == upload ]] && echo "▸ Uploading $scheme…" || echo "▸ Exporting $scheme…"
  if ! xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
      -exportPath "build/export/$scheme" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} >>"$log" 2>&1; then
    grep -E "error:|Error" -A4 "$log" | tail -30 || true
    echo "✗ Export failed. Full log: $log" >&2
    exit 1
  fi
  if [[ "$dest" == upload ]]; then
    echo "✓ $scheme $version ($build) uploaded. It shows in App Store Connect › TestFlight after processing (usually 5–30 min)."
  else
    echo "✓ $scheme exported to build/export/$scheme. Upload with UPLOAD=1, or from the Organizer."
    open "$archive" 2>/dev/null || true
  fi
done
