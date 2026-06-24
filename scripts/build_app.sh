#!/usr/bin/env bash
#
# build_app.sh — Build ReadFlow and assemble a runnable ReadFlow.app bundle.
#
# This file is meant to be executable. If git did not preserve the bit, run:
#     chmod +x "scripts/build_app.sh"
# You can always run it without the bit via:
#     bash "scripts/build_app.sh"
#
# What it does:
#   1. swift build -c release            (arm64 executable)
#   2. assemble ReadFlow.app             (MacOS binary + Info.plist + Resources)
#   3. ad-hoc codesign                   (codesign --force --deep --sign -)
#   4. print Accessibility-grant steps
#
# The finished app lands in:  build/ReadFlow.app
#
# Note: the project path contains a space, so every path is quoted.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# Resolve the project root from this script's own location so the script works
# no matter the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

APP_NAME="ReadFlow"
BUNDLE_ID="com.readflow.app"
SHORT_VERSION="1.0"
BUILD_VERSION="1"

BUILD_DIR="${PROJECT_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
ENTITLEMENTS="${BUILD_DIR}/${APP_NAME}.entitlements"
RELEASE_BIN="${PROJECT_ROOT}/.build/release/${APP_NAME}"

# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
info()  { printf '\033[34m•\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Compile (release)
# ---------------------------------------------------------------------------
bold "[1/4] Building ReadFlow (release)…"
info "swift build -c release"
( cd "${PROJECT_ROOT}" && swift build -c release )

if [[ ! -x "${RELEASE_BIN}" ]]; then
    warn "Release binary not found at: ${RELEASE_BIN}"
    exit 1
fi
ok "Built ${RELEASE_BIN}"

# ---------------------------------------------------------------------------
# 2. Assemble the .app bundle
# ---------------------------------------------------------------------------
bold "[2/4] Assembling ${APP_NAME}.app…"

# Start clean so stale binaries/signatures never linger.
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy the freshly built executable into the bundle.
cp "${RELEASE_BIN}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
ok "Copied executable into Contents/MacOS/"

# Bundle the OpenDyslexic font if the project ships one (optional, never fatal).
if [[ -d "${PROJECT_ROOT}/Resources" ]]; then
    cp -R "${PROJECT_ROOT}/Resources/." "${RESOURCES_DIR}/" 2>/dev/null || true
    info "Copied project Resources/ into the bundle"
fi

# Info.plist — CFBundle keys + LSUIElement (menu-bar agent) +
# NSAppleEventsUsageDescription (the Cmd-C clipboard fallback sends Apple events).
cat > "${INFO_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Koe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>ReadFlow sends a Copy command to grab the text you have selected so it can read it aloud when direct accessibility access is unavailable.</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Read in Koe</string>
            </dict>
            <key>NSMessage</key>
            <string>readSelectionService</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>NSStringPboardType</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
ok "Wrote Info.plist (LSUIElement=0 — real window app, NSAppleEventsUsageDescription)"

# ---------------------------------------------------------------------------
# 3. Ad-hoc codesign
# ---------------------------------------------------------------------------
bold "[3/4] Code signing (ad-hoc)…"

# Entitlements: keep the app UNSANDBOXED so Accessibility, the global hotkey,
# and the clipboard fallback all work; allow sending Apple events for Cmd-C.
cat > "${ENTITLEMENTS}" <<'ENTITLEMENTS_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS_EOF

# Strip extended attributes (resource forks / Finder info / quarantine) that
# Finder, iCloud, or the Desktop add. codesign refuses to sign a bundle that
# carries them ("resource fork ... not allowed"), which would leave the app
# unsigned — losing its Accessibility grant on every rebuild.
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

# Prefer a STABLE self-signed identity so the Accessibility grant survives every
# rebuild (ad-hoc changes the code fingerprint each build, forcing a re-grant).
# Create it once with:  scripts/make_signing_cert.sh
SIGN_IDENTITY="Koe Signing"
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    SIGN_ARG="${SIGN_IDENTITY}"
    ok "Signing with stable identity '${SIGN_IDENTITY}' — Accessibility grant persists across rebuilds"
else
    SIGN_ARG="-"
    warn "Stable cert '${SIGN_IDENTITY}' not found; using ad-hoc (you'll re-grant Accessibility each rebuild)."
    warn "Run scripts/make_signing_cert.sh once to fix that permanently."
fi

codesign --force --deep --sign "${SIGN_ARG}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}"

if codesign --verify --deep --strict "${APP_BUNDLE}" 2>/dev/null; then
    ok "Ad-hoc signed and verified"
else
    warn "Code signature verification reported issues (ad-hoc signing can still run locally)"
fi

# ---------------------------------------------------------------------------
# 3b. Refresh the installed /Applications copy (if present)
# ---------------------------------------------------------------------------
# Once Koe lives in /Applications (the user-facing home + Login Item target),
# keep it current on every rebuild IN PLACE at the same path, so the stable
# "Koe Signing" identity + path keep the Accessibility grant intact.
INSTALLED_APP="/Applications/Koe.app"
if [[ -d "${INSTALLED_APP}" ]]; then
    rm -rf "${INSTALLED_APP}"
    cp -R "${APP_BUNDLE}" "${INSTALLED_APP}"
    ok "Refreshed installed copy: ${INSTALLED_APP}"
fi

# ---------------------------------------------------------------------------
# 4. Next steps
# ---------------------------------------------------------------------------
bold "[4/4] Done."
ok "Built app: ${APP_BUNDLE}"
if [[ -d "${INSTALLED_APP}" ]]; then ok "Installed app: ${INSTALLED_APP} (Koe)"; fi
echo
bold "Launch it:"
echo "    open \"${APP_BUNDLE}\""
echo
bold "Grant Accessibility permission (needed to read your selected text):"
echo "  1. Launch ReadFlow (command above). The Koe window opens (and a Dock icon)."
echo "  2. Open System Settings → Privacy & Security → Accessibility."
echo "  3. Turn ON the switch next to ReadFlow."
echo "     (If ReadFlow is not listed, click +, then add it from:"
echo "      ${APP_BUNDLE} )"
echo "  4. If you had an older copy enabled, toggle it OFF then ON again so macOS"
echo "     picks up this freshly signed build."
echo
info "Select text anywhere, then press Option-R to read it aloud."
info "The System voice works immediately. Kokoro (natural, local) and Azure are optional upgrades — see README.md."
