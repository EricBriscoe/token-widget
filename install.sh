#!/usr/bin/env bash
# Builds Token Widget, installs it to ~/Applications, and launches it.
#
# Signing: an App Group ID must be prefixed with your Apple Developer team ID,
# so the team is baked into project.yml and the two entitlement files. This
# script detects your team from the codesigning identities in your keychain and
# rewrites those three files, so a fresh clone needs no manual editing.
#
#   ./install.sh                 detect the team automatically
#   TEAM_ID=ABCDE12345 ./install.sh   use a specific team

set -euo pipefail

cd "$(dirname "$0")"

BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

say() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
warn() { printf '%swarning:%s %s\n' "$BOLD" "$RESET" "$1" >&2; }
die() { printf '%serror:%s %s\n' "$BOLD" "$RESET" "$1" >&2; exit 1; }

# --- prerequisites ------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "Token Widget is macOS only."

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_MAJOR" -ge 14 ] || die "macOS 14 or later is required (found $(sw_vers -productVersion))."

command -v xcodebuild >/dev/null || die "Xcode is required. Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild is not usable. Run: sudo xcode-select -s /Applications/Xcode.app"

if ! command -v xcodegen >/dev/null; then
    if command -v brew >/dev/null; then
        say "Installing XcodeGen with Homebrew"
        brew install xcodegen
    else
        die "XcodeGen is required. Install Homebrew from https://brew.sh then run: brew install xcodegen"
    fi
fi

# --- signing team -------------------------------------------------------------

# The parenthesised suffix in an identity's name is the certificate ID, not the
# team. The team is the OU field of the certificate's subject.
detect_team_from_certificate() {
    local names name ou
    names=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p')
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        ou=$(security find-certificate -c "$name" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | tr ',/' '\n\n' \
            | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
        if [ -n "$ou" ]; then printf '%s' "$ou"; return 0; fi
    done <<< "$names"
    return 1
}

detect_team_from_profiles() {
    local profile team
    for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
                   "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
        [ -e "$profile" ] || continue
        team=$(security cms -D -i "$profile" 2>/dev/null \
            | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null) || continue
        if [ -n "$team" ]; then printf '%s' "$team"; return 0; fi
    done
    return 1
}

detect_team() {
    detect_team_from_certificate || detect_team_from_profiles || true
}

TEAM_ID="${TEAM_ID:-$(detect_team)}"

# An Apple ID added under Xcode > Settings > Accounts does not by itself put a
# development certificate in the keychain. Xcode only mints one when something
# asks it to. So an empty result here is not necessarily a missing account, and
# the build below is given -allowProvisioningUpdates to create the certificate.
if [ -z "$TEAM_ID" ]; then
    TEAM_ID=$(sed -n 's/.*DEVELOPMENT_TEAM: \([A-Z0-9]*\).*/\1/p' project.yml | head -1)
    if [ -n "$TEAM_ID" ]; then
        warn "No signing certificate in your keychain yet; letting Xcode create one for team ${TEAM_ID}."
    else
        die "No signing certificate and no DEVELOPMENT_TEAM in project.yml. Pass one: TEAM_ID=ABCDE12345 ./install.sh"
    fi
else
    say "Signing team: ${TEAM_ID}"
fi

# The entitlements use $(TeamIdentifierPrefix), which Xcode expands at build
# time, so DEVELOPMENT_TEAM is the only place the team has to be written.
CURRENT_TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM: \([A-Z0-9]*\).*/\1/p' project.yml | head -1)
if [ "$CURRENT_TEAM" != "$TEAM_ID" ]; then
    say "Setting DEVELOPMENT_TEAM to ${TEAM_ID} (was ${CURRENT_TEAM:-unset})"
    /usr/bin/sed -i '' "s/DEVELOPMENT_TEAM: ${CURRENT_TEAM}/DEVELOPMENT_TEAM: ${TEAM_ID}/" project.yml
fi

# --- build --------------------------------------------------------------------

say "Generating Xcode project"
xcodegen generate --quiet

mkdir -p .build
BUILD_DIR="$(pwd)/.build/xcode"

# -allowProvisioningUpdates is what lets Xcode mint the development certificate
# and provisioning profile for a signed-in Apple ID. Without it a machine whose
# account is set up but has never signed anything fails with a bare signing
# error, which reads as "your Apple ID is missing" when it is not.
build() {
    xcodebuild \
        -project TokenWidget.xcodeproj \
        -scheme TokenWidget \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$BUILD_DIR" \
        -allowProvisioningUpdates \
        build > .build/xcodebuild.log 2>&1
}

say "Building (this takes a minute on a clean checkout)"
if ! build; then
    # The failed attempt may still have created a certificate, which is the
    # first point at which the real team ID is knowable. If it differs from what
    # we guessed, write it in and try once more.
    DETECTED=$(detect_team)
    if [ -n "$DETECTED" ] && [ "$DETECTED" != "$TEAM_ID" ]; then
        say "Detected signing team ${DETECTED}; rebuilding"
        /usr/bin/sed -i '' "s/DEVELOPMENT_TEAM: ${TEAM_ID}/DEVELOPMENT_TEAM: ${DETECTED}/" project.yml
        TEAM_ID="$DETECTED"
        xcodegen generate --quiet
    fi
    if ! build; then
        tail -40 .build/xcodebuild.log >&2
        echo >&2
        cat >&2 <<EOF
error: the build could not be signed.

Token Widget shares data between the app and the widget through an App Group,
and an App Group ID has to be prefixed with an Apple Developer team ID, so the
build has to be signed. Check, in order:

  1. Xcode > Settings > Accounts lists your Apple ID (a free account works)
  2. Select the account, click Manage Certificates, and confirm there is an
     "Apple Development" certificate. If not, click + and add one.
  3. If you belong to more than one team, name the right one:
       TEAM_ID=ABCDE12345 ./install.sh

Full log: .build/xcodebuild.log
EOF
        exit 1
    fi
fi

APP_SOURCE="$BUILD_DIR/Build/Products/Release/TokenWidget.app"
[ -d "$APP_SOURCE" ] || die "Build reported success but $APP_SOURCE is missing."

# --- install ------------------------------------------------------------------

DESTINATION="$HOME/Applications/TokenWidget.app"
say "Installing to $DESTINATION"
mkdir -p "$HOME/Applications"
# Quit a running copy so the bundle can be replaced cleanly.
pkill -x TokenWidget 2>/dev/null || true
rm -rf "$DESTINATION"
cp -R "$APP_SOURCE" "$DESTINATION"

say "Launching"
open "$DESTINATION"

# Give the widget extension a moment to register with the system.
sleep 3
if pluginkit -m -p com.apple.widgetkit-extension 2>/dev/null | grep -q tokenwidget; then
    say "Widget registered with macOS"
else
    warn "The widget did not register yet. It usually appears within a minute; if not, log out and back in."
fi

cat <<EOF

${BOLD}Installed.${RESET} The app is scanning your transcripts now.

${BOLD}To add the desktop widget:${RESET}
  1. Control-click an empty area of your desktop, then choose ${BOLD}Edit Widgets${RESET}
     (or click the clock in the menu bar and scroll to the bottom)
  2. Search for ${BOLD}Token Widget${RESET}
  3. Drag a size onto the desktop: Small, Medium, Large, or Extra Large
  4. Control-click the placed widget and choose ${BOLD}Edit Widget${RESET} to pick the
     range (week, month, quarter, year) and whether it shows cost or tokens

${DIM}Keep the app running, or tick "Open at login" in its window, so the widget
keeps getting fresh numbers. It stores history in
~/Library/Group Containers/${TEAM_ID}.group.dev.ericbriscoe.tokenwidget/${RESET}
EOF
