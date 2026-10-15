#!/usr/bin/env bash
set -euo pipefail

# Archives Remux for App Store Connect and exports an .ipa ready for
# TestFlight upload. Pass --upload to send it to App Store Connect through
# the Apple ID signed into Xcode.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

upload=0
if [[ "${1:-}" == "--upload" ]]; then
  upload=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: scripts/archive_testflight.sh [--upload]" >&2
  exit 2
fi

# TestFlight ships the pinned GhosttyKit release. The framework path can also
# hold a local build, which must never reach testers.
if ! scripts/fetch_ghosttykit.sh --verify; then
  echo "Refusing to archive." >&2
  exit 1
fi

archive_path=".local/archives/Remux-$(date +%Y%m%d-%H%M%S).xcarchive"
export_path=".local/archives/export-$(date +%Y%m%d-%H%M%S)"
export_options="$(mktemp -t remux-export-options).plist"

destination="export"
if [[ "$upload" -eq 1 ]]; then
  destination="upload"
fi

cat >"$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>${destination}</string>
	<key>teamID</key>
	<string>T37P2TW58H</string>
</dict>
</plist>
PLIST

mkdir -p .local/archives

xcodebuild archive \
  -project Remux.xcodeproj \
  -scheme Remux \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=T37P2TW58H

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$export_path" \
  -allowProvisioningUpdates

rm -f "$export_options"

if [[ "$upload" -eq 1 ]]; then
  echo "Uploaded to App Store Connect. Manage the build in TestFlight."
else
  echo "Exported .ipa in $export_path"
  echo "Upload it with the Transporter app, or re-run with --upload."
fi
