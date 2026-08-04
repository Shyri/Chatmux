#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Chatmux"
BUNDLE_ID="com.cmuxterm.app.fork"
BASE_APP_NAME="cmux"

usage() {
  cat <<EOF
Usage: ./scripts/install-fork.sh [--launch] [--dest <path>] [--name <name>] [--bundle-id <id>]

Builds cmux in Release configuration and installs a renamed copy to the
destination directory (default: /Applications) as "${APP_NAME}.app", with
an isolated bundle identifier so it runs side-by-side with the official
cmux app. Replaces any existing "${APP_NAME}.app" at that destination.

Options:
  --launch            Open the installed app after copying.
  --dest <path>       Override the install directory (default: /Applications).
  --name <name>       Override the app display name (default: ${APP_NAME}).
  --bundle-id <id>    Override the bundle identifier (default: ${BUNDLE_ID}).
  -h, --help          Show this help.

Environment:
  CMUX_SKIP_ZIG_BUILD=1   Skip the Ghostty/zig build step (forwarded to xcodebuild).
EOF
}

LAUNCH=0
DEST_DIR="/Applications"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch)
      LAUNCH=1
      shift
      ;;
    --dest)
      DEST_DIR="${2:-}"
      if [[ -z "$DEST_DIR" ]]; then
        echo "error: --dest requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
  # Skip all signing during the build. The Release configuration
  # references entitlements that require a Development/Distribution
  # certificate (Automatic signing + empty DEVELOPMENT_TEAM rejects
  # the build). The fork is meant for local install only; we re-sign
  # ad-hoc after the build with the simpler root-level entitlements.
  CODE_SIGN_IDENTITY=-
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGN_ENTITLEMENTS=
)
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(CMUX_SKIP_ZIG_BUILD=1)
fi
XCODEBUILD_ARGS+=(build)

echo "==> Building cmux (Release)..."
xcodebuild "${XCODEBUILD_ARGS[@]}"

SRC_APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${BASE_APP_NAME}.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"

if [[ -z "${SRC_APP_PATH}" || ! -d "${SRC_APP_PATH}" ]]; then
  echo "error: ${BASE_APP_NAME}.app not found in DerivedData after build" >&2
  exit 1
fi

DEST="${DEST_DIR%/}/${APP_NAME}.app"
# Stage the install in a sibling path under DEST_DIR. Same APFS volume as
# DEST so the final mv is an atomic rename(2). If anything aborts before
# the final swap, the live DEST is untouched and the staging path is
# cleaned up by the EXIT trap — there is no window in which a half-baked
# bundle sits at /Applications/Chatmux.app waiting to be launched.
STAGING="${DEST_DIR%/}/.${APP_NAME}.installing.$$.app"

echo "==> Installing:"
echo "    from:       $SRC_APP_PATH"
echo "    staging:    $STAGING"
echo "    to:         $DEST"
echo "    bundle id:  $BUNDLE_ID"

# Quit any running fork at the destination before replacing.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
pkill -f "${DEST}/Contents/MacOS/${BASE_APP_NAME}" || true
sleep 0.3

SUDO=""
if [[ ! -w "$DEST_DIR" ]]; then
  SUDO="sudo"
  echo "==> ${DEST_DIR} is not writable; using sudo"
fi

# Always clean up the staging path on exit — error, interrupt, or
# normal completion (where it has already been mv'd to DEST and rm is a
# harmless no-op). Without this, a Ctrl-C between ditto and the final
# swap would leave a dangling `.Chatmux.installing.NNN.app` in
# /Applications. Also drops the temporary sanitized entitlements plist
# created later in the script.
trap '$SUDO /bin/rm -rf "$STAGING" 2>/dev/null || true; [[ -n "${FORK_ENTITLEMENTS:-}" ]] && /bin/rm -f "$FORK_ENTITLEMENTS" 2>/dev/null || true' EXIT

if [[ -e "$STAGING" ]]; then
  $SUDO /bin/rm -rf "$STAGING"
fi

# ditto preserves extended attributes, symlinks, and permissions better than cp for app bundles.
$SUDO /usr/bin/ditto "$SRC_APP_PATH" "$STAGING"

# Operate on the staging path for the rest of the install (Info.plist
# patch, nested re-signing, outer codesign, verification). FINAL_DEST
# remembers where to swap the staging bundle to once everything passes.
FINAL_DEST="$DEST"
DEST="$STAGING"

# Patch Info.plist to give the fork a distinct identity so it runs side-by-side
# with the official cmux app.
INFO_PLIST="$DEST/Contents/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  $SUDO /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "$INFO_PLIST"
  $SUDO /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$INFO_PLIST"
  $SUDO /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$INFO_PLIST"

  # Disable Sparkle on the fork bundle. The upstream `SUFeedURL` serves
  # binaries signed with Manaflow's Developer ID — applying that update
  # over the fork would silently swap our `com.cmuxterm.app.fork`
  # codesign Identifier for `com.cmuxterm.app` and break the TCC consent
  # trail the rest of this script carefully sets up. AppDelegate also
  # short-circuits `updateController.startUpdaterIfNeeded()` when running
  # under this bundle id; this is belt-and-suspenders at the metadata
  # level so a manually-launched Sparkle never even sees a feed.
  $SUDO /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$INFO_PLIST" 2>/dev/null \
    || $SUDO /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$INFO_PLIST"
  $SUDO /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$INFO_PLIST" 2>/dev/null || true
  $SUDO /usr/libexec/PlistBuddy -c "Delete :SUScheduledCheckInterval" "$INFO_PLIST" 2>/dev/null || true
fi

# Re-sign ad-hoc so Gatekeeper/codesign accepts the patched bundle.
# `-i ${BUNDLE_ID}` is critical: by default `codesign --sign -` derives
# the signature Identifier from the executable name (`cmux`), which
# collides with the official cmux's Identifier. macOS's TCC database
# keys permission grants by that Identifier, not by CFBundleIdentifier,
# so without `-i` the fork either inherits TCC state from the official
# app or — more commonly — gets re-prompted on every launch because the
# signature identity is unstable / ambiguous. Pinning the Identifier to
# the fork's bundle id is what makes "Documents access" /
# "App Management" permissions persist across launches.
#
# Apply the simple root-level entitlements (JIT, mic, camera, apple
# events, library validation off) — we deliberately skip the team-
# scoped `Resources/cmux.entitlements` (`keychain-access-groups` needs
# a real `AppIdentifierPrefix`) since ad-hoc signing has no team.
# Build a sanitized entitlements file for ad-hoc signing. The
# checked-in `cmux.entitlements` declares
# `com.apple.developer.web-browser.public-key-credential`, which is a
# restricted Apple entitlement that can only be claimed by a Developer
# ID-signed binary backed by a matching provisioning profile. When an
# ad-hoc signature tries to claim it, AMFI rejects the launch with
# `RBSRequestErrorDomain Code=5 / POSIX 153 (Launchd job spawn failed)`
# and the kernel log shows "Code has restricted entitlements, but the
# validation of its code signature failed". We strip every
# `com.apple.developer.*` key out of the entitlements before passing
# the file to codesign so the fork install only claims entitlements
# valid under ad-hoc.
SOURCE_ENTITLEMENTS="$REPO_ROOT/cmux.entitlements"
FORK_ENTITLEMENTS=""
if [[ -f "$SOURCE_ENTITLEMENTS" ]]; then
  FORK_ENTITLEMENTS="$(mktemp -t chatmux-entitlements.XXXXXX).plist"
  /bin/cp "$SOURCE_ENTITLEMENTS" "$FORK_ENTITLEMENTS"
  # PlistBuddy reads xml1, plutil converts the working copy to xml1
  # first (entitlements xml may already be xml1; this is idempotent).
  /usr/bin/plutil -convert xml1 "$FORK_ENTITLEMENTS" 2>/dev/null || true
  # Enumerate top-level keys and delete every one starting with
  # `com.apple.developer.` — those are the restricted ones an ad-hoc
  # signature cannot claim.
  while IFS= read -r key; do
    /usr/libexec/PlistBuddy -c "Delete :${key}" "$FORK_ENTITLEMENTS" 2>/dev/null || true
  done < <(/usr/libexec/PlistBuddy -c "Print" "$FORK_ENTITLEMENTS" 2>/dev/null \
    | /usr/bin/awk -F' = ' '/^[[:space:]]+com\.apple\.developer\./ { gsub(/^[[:space:]]+/, "", $1); print $1 }')
  # `keychain-access-groups` is Team-ID-scoped (e.g. `7WLXT3NR37.com.cmuxterm.app`).
  # It does not start with `com.apple.developer.`, so the loop above misses it,
  # but ad-hoc signing has no team and cannot claim it — AMFI then rejects the
  # launch with error 163 ("Code has restricted entitlements, but the validation
  # of its code signature failed") and the installed app never opens. The fork
  # keys its own keychain by bundle id, so the shared group is unnecessary here.
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$FORK_ENTITLEMENTS" 2>/dev/null || true
fi
# `--options runtime` enables hardened runtime. With the sanitized
# entitlements above (only the `com.apple.security.cs.*` flags, which
# are valid under ad-hoc), enabling runtime is consistent: the CS
# entitlements only take effect WITH hardened runtime, and recent
# macOS (≥ 14) rejects bundles that declare them without it.
# Signing identity.
#
# Ad-hoc (`--sign -`) mints a NEW cdhash on every install, and TCC keys grants
# for ad-hoc code by cdhash. So every reinstall silently invalidates Full Disk
# Access, Documents/Desktop/Downloads, camera, microphone and accessibility —
# while System Settings keeps showing the toggle switched on, because the row
# survives even though it no longer matches the running binary. That mismatch
# is why this class of "permission mysteriously stopped working" keeps coming
# back after every reinstall; stabilising the codesign Identifier (below) was
# necessary but not sufficient.
#
# A real identity keys the grant on identifier + team, which survives rebuilds.
# Override with CMUX_FORK_SIGN_IDENTITY; set it to "-" to force ad-hoc.
resolve_fork_sign_identity() {
  if [[ -n "${CMUX_FORK_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$CMUX_FORK_SIGN_IDENTITY"
    return
  fi
  local found
  found="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
  else
    printf '%s' '-'
  fi
}
SIGN_IDENTITY="$(resolve_fork_sign_identity)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Signing ad-hoc (no stable identity found)."
  echo "    macOS permissions will need re-granting after each reinstall."
else
  echo "==> Signing as: ${SIGN_IDENTITY}"
  echo "    (stable identity — macOS permissions survive reinstalls)"
fi

CODESIGN_ARGS=(
  --force
  --sign "${SIGN_IDENTITY}"
  -i "${BUNDLE_ID}"
  --options runtime
  --timestamp=none
  --generate-entitlement-der
)
if [[ -n "$FORK_ENTITLEMENTS" && -f "$FORK_ENTITLEMENTS" ]]; then
  CODESIGN_ARGS+=(--entitlements "$FORK_ENTITLEMENTS")
fi
# Re-sign nested helpers (Sparkle XPC, plugins, frameworks, dock tile
# plugin) before the outer bundle. Without this, the outer signature
# can fail validation because the inner components still carry the old
# codesign identifier. Errors are surfaced (no silent fallback) — a
# failure here propagates and breaks the outer signature, which breaks
# TCC persistence.
#
# IMPORTANT: This must cover `.plugin` (CmuxDockTilePlugin lives here),
# `.appex`, `.xpc`, `.framework` and `.app`. The dock tile plugin is
# loaded by `com.apple.dock.extra` and KEEPS RUNNING after you quit the
# app — if it has a stale signature, it triggers TCC prompts that no
# amount of "Allow" clicks will silence, because TCC cannot persist a
# grant against the colliding Identifier.
NESTED_DEPTH_FIRST=()
while IFS= read -r -d '' nested; do
  [[ "$nested" == "$DEST" ]] && continue
  NESTED_DEPTH_FIRST+=("$nested")
done < <(/usr/bin/find "$DEST" \
  \( -name "*.app" -o -name "*.appex" -o -name "*.xpc" \
     -o -name "*.framework" -o -name "*.plugin" -o -name "*.bundle" \) \
  -print0)
# Sign deepest paths first so containers are signed only after their
# embedded children.
IFS=$'\n' NESTED_SORTED=($(printf '%s\n' "${NESTED_DEPTH_FIRST[@]}" \
  | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)) || true
unset IFS
for nested in "${NESTED_SORTED[@]}"; do
  echo "==> Re-signing nested bundle: ${nested#$DEST/}"
  $SUDO /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none --generate-entitlement-der \
    "$nested"
done

# Also sign loose `.dylib` and `.so` files. The bundle-only walk above
# misses standalone shared libraries dropped under `Contents/Frameworks/`
# (e.g. `libcmux_command_palette_nucleo_ffi.dylib`), and any such
# unsigned subcomponent causes the outer `codesign` below to fail with
# "code object is not signed at all". Using `--force` makes re-signing
# of dylibs already covered by a parent framework safe — that parent
# gets re-signed afterwards anyway.
LOOSE_LIBS=()
while IFS= read -r -d '' lib; do
  LOOSE_LIBS+=("$lib")
done < <(/usr/bin/find "$DEST" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)
for lib in "${LOOSE_LIBS[@]}"; do
  echo "==> Re-signing shared library: ${lib#$DEST/}"
  $SUDO /usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none --generate-entitlement-der \
    "$lib"
done

echo "==> Re-signing outer bundle as ${BUNDLE_ID}"
$SUDO /usr/bin/codesign "${CODESIGN_ARGS[@]}" "$DEST"

# Verify the signature actually took the fork identifier — fail hard if
# it didn't. Silently leaving Identifier=cmux is what historically made
# TCC re-prompt for Documents/App Management permission on every launch
# (TCC keys grants by the codesign Identifier, not by CFBundleIdentifier,
# and Identifier=cmux collides with the official app).
SIG_ID="$($SUDO /usr/bin/codesign -dvv "$DEST" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$SIG_ID" != "$BUNDLE_ID" ]]; then
  echo "error: codesign Identifier is '${SIG_ID}', expected '${BUNDLE_ID}'." >&2
  echo "       macOS permissions (Documents access, App Management) will NOT persist." >&2
  echo "       Re-run codesign manually:" >&2
  echo "         sudo codesign --force --sign - -i '${BUNDLE_ID}' \\" >&2
  echo "           --timestamp=none --generate-entitlement-der \\" >&2
  echo "           --entitlements '${FORK_ENTITLEMENTS}' '${DEST}'" >&2
  exit 1
fi
echo "==> Signature identifier verified: ${SIG_ID}"

# Clear quarantine if something tagged it (shouldn't happen for a local build, but harmless).
$SUDO /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Atomic swap. STAGING and FINAL_DEST are siblings under the same
# DEST_DIR (same APFS volume), so the rename(2) inside `mv` is atomic:
# no observer of FINAL_DEST ever sees a half-finished bundle. We remove
# the existing FINAL_DEST first; the brief gap between rm and mv is
# acceptable because (a) the new bundle is already fully signed and
# verified at STAGING, and (b) the live FINAL_DEST we are replacing is
# either equally valid (re-install) or already broken (recovery).
if [[ -e "$FINAL_DEST" ]]; then
  echo "==> Removing previous install at $FINAL_DEST"
  $SUDO /bin/rm -rf "$FINAL_DEST"
fi
echo "==> Promoting staging bundle to $FINAL_DEST"
$SUDO /bin/mv "$DEST" "$FINAL_DEST"
DEST="$FINAL_DEST"

echo "==> Installed:"
echo "    $DEST"

if [[ "$LAUNCH" -eq 1 ]]; then
  echo "==> Launching..."
  # Don't leak dev-shell pager overrides into cmux.
  env -u GIT_PAGER -u GH_PAGER open -g "$DEST"
fi
