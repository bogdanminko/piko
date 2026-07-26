#!/bin/bash
# Build Piko.app bundle from the SPM executable.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Piko.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Piko "$APP/Contents/MacOS/Piko"

# App icon — regenerate with scripts/make-icon.sh if missing.
if [ ! -f assets/icon/Piko.icns ]; then
    ./scripts/make-icon.sh
fi
cp assets/icon/Piko.icns "$APP/Contents/Resources/Piko.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Piko</string>
    <key>CFBundleIdentifier</key>
    <string>dev.bogdanminko.piko</string>
    <key>CFBundleIconFile</key>
    <string>Piko</string>
    <key>CFBundleName</key>
    <string>Piko</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Piko records your voice so meetings can be transcribed on this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Piko records what the other participants say so meetings can be transcribed on this Mac.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Piko turns a meeting's action items into reminders, each linking back to the moment it was agreed on.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Piko puts follow-ups agreed in a meeting on the day they were set for, each linking back to the moment it was agreed on.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.bogdanminko.piko.link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>piko</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# TCC keys a permission grant to the app's designated requirement. An ad-hoc
# signature has none, so every rebuild reads as a different app and macOS asks
# for the microphone and system audio all over again. Prefer a stable identity
# (./scripts/make-signing-cert.sh creates a local one).
IDENTITY="${PIKO_SIGN_IDENTITY:-Piko Dev}"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    # Hardened Runtime denies a protected resource unless the app claims it,
    # whatever TCC says — and it fails *silently*: no prompt, and the app never
    # even appears in the Privacy pane. That is what an unentitled Calendar
    # request looks like. Reminders needs no entitlement of its own; Calendar
    # does. Not sandboxed: the backend lives in the repo and shells out to
    # ffmpeg and the venv's Python.
    ENTITLEMENTS="build/piko.entitlements"
    cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
</dict>
</plist>
ENT
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    echo "Signed with '$IDENTITY'"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc — recording permissions will be requested again after every rebuild."
    echo "Run ./scripts/make-signing-cert.sh once to keep them."
fi

echo "Built $APP"
