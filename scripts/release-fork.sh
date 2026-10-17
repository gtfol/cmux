#!/usr/bin/env bash
# Build, Developer ID sign, notarize and publish a fork's app as a GitHub release.
#
# A notarized DMG opens on any Mac without registering its UDID or clearing
# quarantine. The app is universal (arm64 + x86_64) and updates itself from the
# fork's own Sparkle appcast, never from upstream's.
#
# One-time setup (values go in .fork-config, next to reload-fork.sh's):
#   - A "Developer ID Application" certificate for FORK_TEAM_ID in the login
#     keychain (Xcode > Settings > Accounts > Manage Certificates).
#   - An explicit App ID for FORK_BUNDLE_ID and a Developer ID provisioning
#     profile for it, downloaded to FORK_DEVID_PROFILE.
#   - notarytool credentials stored under FORK_NOTARY_PROFILE:
#       xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#   - An authenticated gh with write access to FORK_RELEASE_REPO.
# The Sparkle signing key is created in the login keychain on the first run.
#
# Config (env or .fork-config):
#   FORK_DEVID_PROFILE    required. Path to the Developer ID .provisionprofile.
#   FORK_NOTARY_PROFILE   notarytool keychain profile. Default: cmux-fork-notary.
#   FORK_SPARKLE_ACCOUNT  keychain account of the Sparkle key. Default: cmux-fork.
#   FORK_RELEASE_REPO     owner/repo to publish to. Default: the origin remote.
#
# Usage: ./scripts/release-fork.sh [--skip-build] [--no-publish]
#   --skip-build   reuse the last reload-fork.sh build instead of rebuilding
#   --no-publish   stop after notarizing; print the DMG and appcast paths
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=0
PUBLISH=1
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --no-publish) PUBLISH=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ -f .fork-config ]]; then
  # shellcheck disable=SC1091
  source .fork-config
fi

die() { echo "error: $*" >&2; exit 1; }

FORK_APP_NAME="${FORK_APP_NAME:-cmux STAGING}"
FORK_NOTARY_PROFILE="${FORK_NOTARY_PROFILE:-cmux-fork-notary}"
FORK_SPARKLE_ACCOUNT="${FORK_SPARKLE_ACCOUNT:-cmux-fork}"
[[ -n "${FORK_BUNDLE_ID:-}" ]] || die "FORK_BUNDLE_ID is not set (see reload-fork.sh)"
[[ -n "${FORK_TEAM_ID:-}" ]] || die "FORK_TEAM_ID is not set; Developer ID signing needs a paid team"
[[ -n "${FORK_DEVID_PROFILE:-}" ]] || die "FORK_DEVID_PROFILE is not set"
[[ -f "$FORK_DEVID_PROFILE" ]] || die "Developer ID profile not found at $FORK_DEVID_PROFILE"

if [[ -z "${FORK_RELEASE_REPO:-}" ]]; then
  FORK_RELEASE_REPO="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
fi

# --- Preflight: fail before the long build, not after it. ---

IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: .* ($FORK_TEAM_ID)\)\"$/\1/p" | head -1)"
[[ -n "$IDENTITY" ]] || die "no \"Developer ID Application: ... ($FORK_TEAM_ID)\" identity in the keychain"

PROFILE_PLIST="$(mktemp -t fork-devid-profile).plist"
trap 'rm -f "$PROFILE_PLIST"' EXIT
security cms -D -i "$FORK_DEVID_PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
  || die "could not decode $FORK_DEVID_PROFILE"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$PROFILE_PLIST")"
PROFILE_ALL_DEVICES="$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$PROFILE_PLIST" 2>/dev/null || echo false)"
[[ "$PROFILE_APP_ID" == "$FORK_TEAM_ID.$FORK_BUNDLE_ID" ]] \
  || die "profile is for $PROFILE_APP_ID, expected $FORK_TEAM_ID.$FORK_BUNDLE_ID"
[[ "$PROFILE_ALL_DEVICES" == "true" ]] \
  || die "$FORK_DEVID_PROFILE is not a Developer ID profile (it is limited to registered devices)"

xcrun notarytool history --keychain-profile "$FORK_NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile \"$FORK_NOTARY_PROFILE\" is missing; run xcrun notarytool store-credentials"

if [[ "$PUBLISH" -eq 1 ]]; then
  gh auth token >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
  [[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit first so the release tag matches the build"
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main \
    || die "HEAD is not on origin/main; push it first so the release tag points at published source"
fi

# --- Build ---

DERIVED_DATA="/tmp/cmux-release-fork"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$FORK_APP_NAME.app"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  ./scripts/reload-fork.sh
fi
[[ -d "$BUILT_APP" ]] || die "no build at $BUILT_APP; run without --skip-build"

STAGE="$DERIVED_DATA/release"
APP="$STAGE/$FORK_APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$BUILT_APP" "$APP"
PLIST="$APP/Contents/Info.plist"

for bin in "$APP/Contents/MacOS/cmux" "$APP/Contents/Resources/bin/cmux"; do
  archs="$(lipo -archs "$bin")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "$(basename "$bin") is not universal ($archs)"
done

# --- Version: <upstream version>-fork.<n>, build <upstream build>.<n> ---
# The build number grows with each fork release of one upstream version, and
# resets above it once an upstream merge raises the upstream build.

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
UPSTREAM_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
LAST_N="$(gh release list --repo "$FORK_RELEASE_REPO" --limit 200 --json tagName -q '.[].tagName' 2>/dev/null \
  | sed -n "s/^v${APP_VERSION//./\\.}-fork\.\([0-9][0-9]*\)$/\1/p" | sort -n | tail -1)"
N=$(( ${LAST_N:-0} + 1 ))
TAG="v${APP_VERSION}-fork.${N}"
BUILD_VERSION="${UPSTREAM_BUILD}.${N}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$PLIST"
echo "==> releasing $FORK_APP_NAME $TAG (build $BUILD_VERSION) to $FORK_RELEASE_REPO"

# --- Sparkle: the fork's own feed and key ---

SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle tools not found in $SPARKLE_BIN"
if ! SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$FORK_SPARKLE_ACCOUNT" -p 2>/dev/null)"; then
  echo "==> creating Sparkle signing key (keychain account $FORK_SPARKLE_ACCOUNT)"
  "$SPARKLE_BIN/generate_keys" --account "$FORK_SPARKLE_ACCOUNT" >/dev/null
  SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$FORK_SPARKLE_ACCOUNT" -p)"
fi
FEED_URL="https://github.com/$FORK_RELEASE_REPO/releases/latest/download/appcast.xml"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_KEY" "$PLIST"

# --- Developer ID signing ---

cp "$FORK_DEVID_PROFILE" "$APP/Contents/embedded.provisionprofile"
ENTITLEMENTS="$STAGE/fork-release.entitlements"
sed -e "s/__TEAM_ID__/$FORK_TEAM_ID/g" -e "s/__BUNDLE_ID__/$FORK_BUNDLE_ID/g" \
  scripts/fork-release.entitlements > "$ENTITLEMENTS"
./scripts/sign-cmux-bundle.sh "$APP" "$ENTITLEMENTS" "$IDENTITY"

# --- Notarize ---

notarize() {
  local path="$1" result status id
  result="$(xcrun notarytool submit "$path" --keychain-profile "$FORK_NOTARY_PROFILE" --wait --output-format json)"
  status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$result")"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$FORK_NOTARY_PROFILE" || true
    die "notarization of $(basename "$path") finished with status: ${status:-unknown}"
  fi
}

echo "==> notarizing app"
ZIP="$STAGE/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> building DMG"
SLUG="$(tr '[:upper:] ' '[:lower:]-' <<<"$FORK_APP_NAME")"
DMG="$STAGE/$SLUG-macos.dmg"
DMG_ROOT="$STAGE/dmg-root"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/$FORK_APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname "$FORK_APP_NAME" -srcfolder "$DMG_ROOT" -format ULMO -ov "$DMG"
rm -rf "$DMG_ROOT"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "==> notarizing DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# --- Appcast ---

ED_ATTRS="$("$SPARKLE_BIN/sign_update" --account "$FORK_SPARKLE_ACCOUNT" "$DMG")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")"
APPCAST="$STAGE/appcast.xml"
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuszewski.com/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$FORK_APP_NAME</title>
    <item>
      <title>$FORK_APP_NAME $APP_VERSION (fork build $N)</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/$FORK_RELEASE_REPO/releases/tag/$TAG</link>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$FORK_RELEASE_REPO/releases/download/$TAG/$(basename "$DMG")" $ED_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

if [[ "$PUBLISH" -eq 0 ]]; then
  echo
  echo "Notarized, not published:"
  echo "  $DMG"
  echo "  $APPCAST"
  exit 0
fi

# --- Publish ---

NOTES="$FORK_APP_NAME, built from $(git rev-parse --short HEAD) of [$FORK_RELEASE_REPO](https://github.com/$FORK_RELEASE_REPO) on cmux $APP_VERSION.

Download \`$(basename "$DMG")\`, open it and drag $FORK_APP_NAME to Applications. Universal build for Apple silicon and Intel Macs, macOS $MIN_SYSTEM or later. The app updates itself from this repository's releases."
gh release create "$TAG" "$DMG" "$APPCAST" \
  --repo "$FORK_RELEASE_REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "$FORK_APP_NAME $APP_VERSION (fork build $N)" \
  --notes "$NOTES" \
  --latest

echo
echo "Published: https://github.com/$FORK_RELEASE_REPO/releases/tag/$TAG"
echo "Latest download: https://github.com/$FORK_RELEASE_REPO/releases/latest/download/$(basename "$DMG")"
