#!/usr/bin/env bash
# Archive the fork's iOS app and upload it to TestFlight under the fork's team.
#
# Uses Xcode automatic signing with the Apple ID signed in to Xcode, so the team
# needs no App Store Connect API key. Run it from your own terminal: a session
# that can't see Xcode's account fails the export with "No Accounts"; then open
# the archive in Xcode's Organizer and use Distribute App instead. The upload
# needs an App Store Connect app record for FORK_IOS_BUNDLE_ID (Apps > + > New
# App), created once by hand.
#
# Same .fork-config as ios/scripts/reload-fork.sh (FORK_BUNDLE_ID, FORK_TEAM_ID,
# optional FORK_IOS_BUNDLE_ID / FORK_IOS_APP_NAME). The build uses the stripped
# fork entitlements on every target: no APNs, Sign in with Apple, App Groups or
# VPN, which are registered to Manaflow's team.
#
# Usage: ios/scripts/release-fork.sh [--no-upload]
#   --no-upload   export a signed .ipa instead of uploading it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
cd "$REPO_ROOT"

UPLOAD=1
for arg in "$@"; do
  case "$arg" in
    --no-upload) UPLOAD=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ -f .fork-config ]]; then
  # shellcheck disable=SC1091
  source .fork-config
fi

die() { echo "error: $*" >&2; exit 1; }

FORK_APP_NAME="${FORK_APP_NAME:-cmux fork}"
FORK_IOS_APP_NAME="${FORK_IOS_APP_NAME:-$FORK_APP_NAME}"
[[ -n "${FORK_BUNDLE_ID:-}" ]] || die "FORK_BUNDLE_ID is not set (see ios/scripts/reload-fork.sh)"
[[ -n "${FORK_TEAM_ID:-}" ]] || die "FORK_TEAM_ID is not set; TestFlight needs a paid team"
FORK_IOS_BUNDLE_ID="${FORK_IOS_BUNDLE_ID:-${FORK_BUNDLE_ID}.ios}"
case "$FORK_IOS_BUNDLE_ID" in
  com.cmuxterm.*|com.cmux.app|com.cmux.app.*|dev.cmux.app|dev.cmux.app.*|dev.cmux.ios|dev.cmux.ios.*)
    die "FORK_IOS_BUNDLE_ID='$FORK_IOS_BUNDLE_ID' is a Manaflow-owned id" ;;
esac

if [[ "$UPLOAD" -eq 1 ]]; then
  [[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit first so the build matches published source"
fi

DERIVED_DATA="${CMUX_FORK_IOS_RELEASE_DERIVED_DATA:-/tmp/cmux-ios-fork-release}"
ARCHIVE="$DERIVED_DATA/cmux-fork.xcarchive"
EXPORT_DIR="$DERIVED_DATA/export"
ENTITLEMENTS="$IOS_DIR/Config/fork-dev.entitlements"

if [[ -x "$REPO_ROOT/scripts/ensure-ghosttykit.sh" ]]; then
  "$REPO_ROOT/scripts/ensure-ghosttykit.sh"
fi

# TestFlight needs a build number that is new for this marketing version and
# higher than the last one. A UTC timestamp (YYMMDD.HHMM, no leading zero in
# HHMM since each part is compared as an integer) always is.
BUILD_NUMBER="$(date -u +%y%m%d).$((10#$(date -u +%H%M)))"
GIT_SHA="$(git rev-parse --short HEAD)"

echo "==> archiving $FORK_IOS_APP_NAME ($FORK_IOS_BUNDLE_ID) build $BUILD_NUMBER for team $FORK_TEAM_ID"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild archive \
  -workspace "$IOS_DIR/cmux.xcworkspace" \
  -scheme cmux-ios \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$FORK_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  CMUX_APP_BUNDLE_IDENTIFIER="$FORK_IOS_BUNDLE_ID" \
  CMUX_HOST_BUNDLE_IDENTIFIER="$FORK_IOS_BUNDLE_ID" \
  CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER="$FORK_IOS_BUNDLE_ID.NotificationService" \
  CMUX_CLOUD_VPN_BUNDLE_IDENTIFIER="$FORK_IOS_BUNDLE_ID.CloudVPN" \
  PRODUCT_DISPLAY_NAME="$FORK_IOS_APP_NAME" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CMUX_GIT_SHA="$GIT_SHA" \
  CMUX_DEV_TAG=

OPTIONS="$DERIVED_DATA/ExportOptions.plist"
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$([[ "$UPLOAD" -eq 1 ]] && echo upload || echo export)</string>
	<key>teamID</key>
	<string>$FORK_TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

echo "==> $([[ "$UPLOAD" -eq 1 ]] && echo "uploading to TestFlight" || echo "exporting .ipa")"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist")"
echo
if [[ "$UPLOAD" -eq 1 ]]; then
  echo "Uploaded $FORK_IOS_APP_NAME $MARKETING_VERSION ($BUILD_NUMBER). It appears in App Store Connect"
  echo "> TestFlight after Apple finishes processing, usually 5-15 minutes."
else
  echo "Exported, not uploaded:"
  ls "$EXPORT_DIR"/*.ipa
fi
