#!/usr/bin/env bash
# Build a Release app from a fork, without Manaflow's signing certificates.
#
# Personal values come from env vars or a `.fork-config` file at the repo root.
# The file is sourced as shell, so quote values containing spaces
# (FORK_APP_NAME="my cmux"); keep it out of git via .git/info/exclude.
#   FORK_BUNDLE_ID   required. Must be in YOUR namespace, e.g. dev.you.cmux.staging
#                    (com.cmuxterm.* is registered to Manaflow's Apple team).
#   FORK_TEAM_ID     optional. Apple team ID for development signing (free personal
#                    teams work). When unset, builds ad-hoc with no entitlements.
#   FORK_APP_NAME    optional display name. Default: "cmux STAGING".
#
# CMUX_SKIP_ZIG_BUILD=1 is passed through if set (needed where zig 0.15.2 cannot
# link against the host SDK; see scripts/build-ghostty-cli-helper.sh).
#
# Usage: ./scripts/reload-fork.sh [--install] [--allow-device-registration]
#   --install                    copy the built app to ~/Applications/"$FORK_APP_NAME.app"
#   --allow-device-registration  register this Mac with FORK_TEAM_ID (first build on a new team)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
ALLOW_DEVICE_REGISTRATION=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --allow-device-registration) ALLOW_DEVICE_REGISTRATION=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ -f .fork-config ]]; then
  # shellcheck disable=SC1091
  source .fork-config
fi

FORK_APP_NAME="${FORK_APP_NAME:-cmux STAGING}"
FORK_TEAM_ID="${FORK_TEAM_ID:-}"
if [[ -z "${FORK_BUNDLE_ID:-}" ]]; then
  echo "error: FORK_BUNDLE_ID is not set." >&2
  echo "Set it in .fork-config or the environment, e.g.:" >&2
  echo "  echo 'FORK_BUNDLE_ID=dev.you.cmux.staging' >> .fork-config" >&2
  echo "Use your own namespace: com.cmuxterm.* cannot be registered to other teams." >&2
  exit 1
fi

DERIVED_DATA="/tmp/cmux-release-fork"

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  PRODUCT_BUNDLE_IDENTIFIER="$FORK_BUNDLE_ID"
)

if [[ -n "$FORK_TEAM_ID" ]]; then
  echo "==> Release build signed with team $FORK_TEAM_ID ($FORK_BUNDLE_ID)"
  XCODEBUILD_ARGS+=(
    DEVELOPMENT_TEAM="$FORK_TEAM_ID"
    -allowProvisioningUpdates
    CODE_SIGN_ENTITLEMENTS=scripts/fork-dev.entitlements
  )
  if [[ "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
    XCODEBUILD_ARGS+=(-allowProvisioningDeviceRegistration)
  fi
else
  echo "==> Release build with ad-hoc signing ($FORK_BUNDLE_ID); set FORK_TEAM_ID for a signed build"
  XCODEBUILD_ARGS+=(CODE_SIGN_ENTITLEMENTS="")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: build succeeded but app not found at $BUILT_APP" >&2
  exit 1
fi

# Rename post-build, the way reload.sh handles tagged apps: a global PRODUCT_NAME
# override would rename every target's product and module and break the build.
APP="$BUILT_APP"
if [[ "$FORK_APP_NAME" != "cmux" ]]; then
  APP="$DERIVED_DATA/Build/Products/Release/$FORK_APP_NAME.app"
  rm -rf "$APP"
  cp -R "$BUILT_APP" "$APP"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $FORK_APP_NAME" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $FORK_APP_NAME" "$APP/Contents/Info.plist"
fi

# cmux ssh bootstraps the remote host with a cmuxd-remote binary that the app
# looks up through an embedded manifest. A plain xcodebuild has neither the
# manifest nor the binaries, so bootstrap fails with "This cmux build has no
# remote daemon for the remote host's platform". Build, embed and bundle them
# before re-signing, since both edit the bundle.
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DAEMON_ASSETS_DIR="$DERIVED_DATA/remote-daemon-assets"
./scripts/build_remote_daemon_release_assets.sh \
  --version "$APP_VERSION" \
  --release-tag "v${APP_VERSION}" \
  --repo "manaflow-ai/cmux" \
  --output-dir "$DAEMON_ASSETS_DIR"
python3 ./scripts/verify_remote_daemon_release.py \
  --manifest "$DAEMON_ASSETS_DIR/cmuxd-remote-manifest.json" \
  --assets-dir "$DAEMON_ASSETS_DIR" \
  --app "$APP" \
  --embed \
  --bundle-assets

# cmux ssh runs through the bundled cmux-tui client (Contents/Resources/bin/cmux-tui).
# Without it every cmux ssh fails with the generic "The Cloud VM request failed"
# error. Install the published client for this checkout, as release.yml does.
CMUX_TUI_COMMIT="$(./scripts/ci/resolve-cmux-tui-client-commit.sh)"
CMUX_TUI_INSTALL_ARGS=(
  "$APP"
  --manifest-url "https://files.cmux.com/cmux-tui/${CMUX_TUI_COMMIT}/manifest.json"
  --expected-commit "$CMUX_TUI_COMMIT"
  --require-capability wireguard-hub
)
# The installer verifies the manifest's build-provenance attestation through gh;
# without an authenticated gh it can only install unattested.
if ! command -v gh >/dev/null 2>&1 || ! gh auth token >/dev/null 2>&1; then
  CMUX_TUI_INSTALL_ARGS+=(--allow-unattested)
fi
./scripts/install-cmux-tui-client.sh "${CMUX_TUI_INSTALL_ARGS[@]}"

# The global CODE_SIGN_ENTITLEMENTS override also lands on the CLI helpers under
# Resources/bin. A standalone binary can't satisfy restricted entitlements
# (keychain-access-groups, get-task-allow) via the app's provisioning profile,
# so amfid SIGKILLs it at exec. Ad-hoc re-sign the helpers with no entitlements.
for helper in "$APP/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  echo "==> re-signing helper $(basename "$helper") without entitlements"
  codesign --force --sign - "$helper"
done

# Re-signing helpers (and any Info.plist rename edits) breaks the app's
# resource seal, so the bundle is always re-signed last.
if [[ -n "$FORK_TEAM_ID" ]]; then
  ENTITLEMENTS_TMP="$(mktemp -t fork-entitlements).plist"
  codesign -d --entitlements "$ENTITLEMENTS_TMP" --xml "$APP" 2>/dev/null
  # Re-sign with the identity Xcode used, so a second team's Apple Development
  # cert in the keychain can't silently swap the team.
  SIGN_IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "error: no Apple Development identity for team $FORK_TEAM_ID found to re-sign the bundle" >&2
    exit 1
  fi
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_TMP" "$APP"
  rm -f "$ENTITLEMENTS_TMP"
else
  codesign --force --sign - "$APP"
fi

echo
echo "App path:"
echo "  $APP"

if [[ "$INSTALL" -eq 1 ]]; then
  TARGET="$HOME/Applications/$FORK_APP_NAME.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  echo
  echo "Installed:"
  echo "  $TARGET"
fi
