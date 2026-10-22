#!/usr/bin/env sh
# Downloads and installs the bridge on Linux and on macOS.
#
# The script reads the machine, picks the asset name, downloads it from the release
# page and installs it. It asks nothing.
#
#   linux-x64
#   osx-arm64
#
# There is no linux-arm64 build yet, because no aarch64 build image exists. On Linux
# aarch64 the script stops at once and names the supported platforms.
#
# On an Apple Silicon Mac it takes the osx-arm64 tar.gz. There is no osx-x64 build yet,
# so on an Intel Mac the script stops at once and names the supported platforms. On
# Windows, run install.ps1.
#
# On Linux with dpkg or rpm it takes the deb or the rpm, so the package manager
# owns the file. Everywhere else it takes the tar.gz and copies the binary.
#
# On macOS the script is the whole installer, as the MSI is on Windows, so it runs as
# root. It checks the seal of the new build, unloads the update job, stops a running
# service, writes the binary and Quix Lake Bridge.app (the twin of the Start-menu
# shortcut), installs and starts the service, adds the menu bar item for every person,
# and opens the console for the person who ran sudo. A failure after the stop puts the
# old binary, the old app and the old service back. A second run of the same version
# repairs the install. With --uninstall it removes all of it, and the data too unless
# --keep-data says no. With --from-local <folder> it installs a local build (the
# quix-bridge an AOT publish wrote) instead of a release.
#
# After the install the bridge updates itself: the LaunchDaemon io.quix.bridge.update
# runs every 5 minutes and installs the release the gateway offers. It installs nothing
# when config.yaml sets update.channel to manual.
#
# usage:
#   curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sh
#   QUIX_BRIDGE_VERSION=0.1.0 sh install.sh
#
# usage on macOS (root, because the service and the menu bar item are for every person):
#   curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sudo sh
#   curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sudo QUIX_BRIDGE_VERSION=0.1.0 sh
#   curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sudo sh -s -- --uninstall
#   curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sudo sh -s -- --uninstall --keep-data
#   sudo sh packaging/install.sh --from-local out/osx-arm64      (a local build, from the repo)
set -eu

REPO="${QUIX_BRIDGE_REPO:-quixio/quix-lake-bridge}"
VERSION="${QUIX_BRIDGE_VERSION:-latest}"
PREFIX="${QUIX_BRIDGE_PREFIX:-/usr/local/bin}"

fail() { echo "$1" >&2; exit 1; }

# ---- macOS: the installer and the uninstaller -------------------------------

# The places the macOS install touches outside the binary. The bridge owns every one
# of them (ServiceLifecycle, MacLoginItem, AuditLogPaths, UpdateLayout); the script names
# them only to check for them and to delete what the binary leaves behind. A test points
# them at a scratch folder: the functions test sets each one, and the whole-script test
# sets QUIX_BRIDGE_TEST_ROOT, which nothing else reads.
MAC_ROOT="${QUIX_BRIDGE_TEST_ROOT:-}"
MAC_DAEMON_PLIST="${MAC_ROOT}/Library/LaunchDaemons/io.quix.bridge.plist"
MAC_UPDATE_PLIST="${MAC_ROOT}/Library/LaunchDaemons/io.quix.bridge.update.plist"
MAC_UPDATE_JOB="system/io.quix.bridge.update"
MAC_SERVICE_JOB="system/io.quix.bridge"
MAC_ACCOUNT="_quixbridge"
MAC_TRAY_AGENT_NAME="io.quix.bridge.tray.plist"
MAC_TRAY_AGENT="${MAC_ROOT}/Library/LaunchAgents/${MAC_TRAY_AGENT_NAME}"
MAC_LOG_DIR="${MAC_ROOT}/Library/Logs/Quix/Bridge"
# The folders of the launchd stderr.log of the service (the service user owns it) and of the update job (root owns it).
MAC_SERVICE_LOG_DIR="${MAC_ROOT}/Library/Logs/Quix/Bridge Service"
MAC_UPDATE_LOG_DIR="${MAC_ROOT}/Library/Logs/Quix/Bridge Update"
MAC_SUPPORT_DIR="${MAC_ROOT}/Library/Application Support/Quix"
MAC_UPDATE_DIR="${MAC_SUPPORT_DIR}/Bridge Update"
MAC_USERS_DIR="${MAC_ROOT}/Users"
MAC_CONSOLE_DEVICE="/dev/console"

# The app: MacAppBundle.InstalledApp. The release tar.gz carries it next to the binary,
# and make-app.sh builds it from a local build. A test points both at a scratch folder.
MAC_APP_NAME="Quix Lake Bridge.app"
MAC_APP_DIR="${MAC_ROOT}/Applications/${MAC_APP_NAME}"
MAC_MAKE_APP="$(dirname "$0")/macos/make-app.sh"

# How long the script waits for the console after the service starts. The service
# writes the console secret and binds the port a moment after launchd starts it.
MAC_CONSOLE_WAIT_SECONDS=30

# The line that names the command a person runs when the script opens no console.
MAC_UI_HINT="The script did not open the console. Run 'sudo quix-bridge ui' in Terminal. It prints the login URL and the code."

# The one-time console open the tray does by itself on its first start. The tray reads
# this marker (Tray/FirstRun.cs) in the person's own profile. When the script opened the
# console itself, it writes the marker, so the tray shows no second cue. When the open
# failed it writes none, so the tray still opens the console once.
MAC_FIRST_RUN_MARKER='Library/Application Support/Quix/Bridge/console-opened'

# The folder of the menu bar item in each person's own profile: its log, its lock and the
# marker above.
MAC_PERSON_DIR='Library/Application Support/Quix/Bridge'

# Stops with the one line that says how to run the script as root. The Windows
# script asks for administrator rights before msiexec runs; a piped shell script
# cannot ask, so it stops before it downloads or changes anything.
mac_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "The macOS $1 needs root rights, because the service and the menu bar item are for every person. Nothing changed. Run it again with sudo:
  curl -fsSL https://github.com/${REPO}/raw/main/install.sh | sudo sh${2:+ -s -- $2}"
    fi
}

# Reads the login URL from what 'quix-bridge ui' printed: the first line that starts
# with "URL:". It prints nothing for any other text, or for a URL that is not http or
# https, or that holds a quote. MacAdminScript.LoginUrlIn reads the same line for the
# tray. The URL is a credential, so the caller never prints it.
mac_login_url_in() {
    printf '%s\n' "$1" | tr '\r' '\n' \
        | sed -n 's/^[[:space:]]*URL:[[:space:]]*//p' | head -n 1 \
        | sed 's/[[:space:]]*$//' \
        | grep -E '^https?://[^"[:space:]]+$' || true
}

# The running menu bar items, one process id a line. A tray is "quix-bridge tray" from
# any folder, so a tray a person started by hand counts too, and so does the app's copy
# of the binary with no words (the app opened from Finder). The app's path holds
# spaces, so the rule reads the whole command and not the words awk splits.
mac_tray_pids() {
    ps -axo pid=,command= | awk '{
        command = $0
        sub(/^[ \t]*[0-9]+[ \t]+/, "", command)
        if (command ~ /(^|\/)quix-bridge tray( |$)/ || command ~ /\.app\/Contents\/MacOS\/quix-bridge$/) print $1
    }'
}

# Opens the console in the browser of the person who ran sudo, as that person. The
# Windows script does the same through explorer.exe, so the browser never runs with
# the installer's rights.
#
# Only a person at the screen gets a browser. A deployment tool runs as root with no
# SUDO_USER, and a person on SSH is not the owner of the console; both get the hint
# line, as a silent Windows install does.
mac_open_console() {
    person="${SUDO_USER:-}"
    person_uid="${SUDO_UID:-}"
    if [ -z "$person" ] || [ -z "$person_uid" ] || [ "$person_uid" = "0" ]; then
        echo "$MAC_UI_HINT"
        return 0
    fi

    screen_uid="$(stat -f %u "$MAC_CONSOLE_DEVICE" 2> /dev/null || true)"
    if [ "$screen_uid" != "$person_uid" ]; then
        echo "$MAC_UI_HINT"
        return 0
    fi

    # The ui command mints a URL only when the service answers, so it is asked again
    # until the service has started. A failed ask mints nothing. --console-user records
    # the person, so the menu bar item later fetches the console link with no prompt.
    url=""
    waited=0
    while :; do
        ui_output="$("${PREFIX}/quix-bridge" ui --console-user "$person_uid" 2> /dev/null)" || ui_output=""
        url="$(mac_login_url_in "$ui_output")"
        [ -z "$url" ] || break
        [ "$waited" -lt "$MAC_CONSOLE_WAIT_SECONDS" ] || break
        sleep 1
        waited=$((waited + 1))
    done
    ui_output=""

    if [ -z "$url" ]; then
        echo "$MAC_UI_HINT"
        return 0
    fi

    # launchctl asuser puts osascript in the person's own login session, where their
    # browser runs. sudo -u drops root. The URL works once and expires in 5 minutes, and
    # it buys a 30-day session. Every local account reads every command line with ps, so
    # the URL reaches osascript on its standard input and never on a command line.
    # "open location" asks LaunchServices, as open(1) does. A quotation mark or a
    # backslash would end the AppleScript string, so such a URL is not opened.
    case "$url" in
        *[\"\\]*)
            echo "$MAC_UI_HINT"
            url=""
            return 0
            ;;
    esac
    if printf 'open location "%s"\n' "$url" \
        | launchctl asuser "$person_uid" sudo -u "$person" /usr/bin/osascript - > /dev/null 2>&1; then
        # The marker goes in after the open worked, as the person, and before the menu bar
        # item starts, so that item stays quiet. A failed open writes none: the item then
        # opens the console itself on its first start.
        # The single quotes are on purpose: $HOME is the person's, read by the inner shell.
        # shellcheck disable=SC2016
        sudo -u "$person" -H /bin/sh -c 'mkdir -p "$HOME/$(dirname "$1")" && : > "$HOME/$1"' sh "$MAC_FIRST_RUN_MARKER" \
            > /dev/null 2>&1 || true
        echo "Opened the console in the browser."
        echo "In Chrome or Edge, click Install in the address bar. In Safari, choose File > Add to Dock. The console then has its own Dock icon."
    else
        echo "$MAC_UI_HINT"
    fi
    url=""
}

# The hidden copies the install, an update and a rollback keep next to the app.
mac_app_beside() { printf '%s/.%s%s' "$(dirname "$MAC_APP_DIR")" "$MAC_APP_NAME" "$1"; }

# Refuses a build whose seal is broken, before anything stops. Apple Silicon runs no
# binary with a broken signature, so a damaged download would stop the service and then
# never start again. The release binary carries the linker's ad hoc signature and the app
# one ad hoc seal (docs/bridge/SIGNING.md), and both pass this check.
mac_verify_seal() {
    command -v codesign > /dev/null 2>&1 \
        || fail "This Mac has no codesign, so the script cannot check the seal of the new build. Nothing changed."
    codesign --verify --strict "$1" > /dev/null 2>&1 \
        || fail "The seal of the new quix-bridge is broken: codesign --verify --strict refused it. Nothing changed. Run the script again to download it again."
    if [ -n "${2:-}" ] && [ -d "$2" ]; then
        codesign --verify --strict --deep "$2" > /dev/null 2>&1 \
            || fail "The seal of the new ${MAC_APP_NAME} is broken: codesign --verify --strict refused it. Nothing changed. Run the script again to download it again."
    fi
}

# The owner uid and the mode of one folder, as "0 drwxr-xr-x", or nothing when ls fails.
# A test swaps it.
mac_folder_owner_mode() {
    ls -ldn "$1" 2> /dev/null | awk '{ print $3, substr($1, 1, 10) }'
}

# Refuses a PREFIX that a person other than root could change, before anything stops. root
# runs the binary there: the update job, and the Start item of the menu bar item. A person
# who may write PREFIX, or a folder above it, could swap that binary, as a user-owned
# /usr/local/bin of Intel Homebrew allows. So root must own every folder from PREFIX to /,
# and no group and no other user may write one. A PREFIX that is not there yet is made by
# root, so the check reads the folders that are there.
#
# It reads two walks, as the C# check of 'service install' does. The real path holds the
# binary. The typed path can pass a link, such as /tmp/quix-link -> /usr/local/bin, and a
# person who may write the folder of that link can point it elsewhere. So both walks must pass.
mac_require_root_owned_prefix() {
    folder="$PREFIX"
    while [ ! -d "$folder" ]; do
        folder="$(dirname "$folder")"
    done
    typed="$(cd "$folder" && pwd -L)" && real="$(cd "$folder" && pwd -P)" \
        || fail "The script cannot read the real path of ${PREFIX}. Nothing changed."
    mac_require_root_owned_folders "$typed"
    mac_require_root_owned_folders "$real"
}

# Walks from one folder to / and refuses a folder that a person other than root may change. A
# link on the typed path counts by its owner only: the mode of a link grants nothing, and the
# folder that holds it is the next step of the walk.
mac_require_root_owned_folders() {
    folder="$1"
    while :; do
        owner_mode="$(mac_folder_owner_mode "$folder")"
        owner="${owner_mode%% *}"
        mode="${owner_mode#* }"
        if [ -z "$owner_mode" ] || [ "$owner" = "$owner_mode" ]; then
            fail "The script cannot read the owner of '${folder}', so it cannot prove that only root may change ${PREFIX}. Nothing changed."
        fi
        case "$owner:$mode" in
            0:l*) writable="" ;;
            0:?????w*|0:????????w*|0:) writable="1" ;;
            0:*) writable="" ;;
            *) writable="1" ;;
        esac
        if [ -n "$writable" ]; then
            fail "The script installs nothing in ${PREFIX}: root must own every folder above the binary, and no other user may write one. '${folder}' has owner uid ${owner} and mode ${mode}. root runs the binary there, so a person who may write that folder could swap it. Nothing changed. Give the folder to root and take away the write right of others, then run the script again:
  sudo chown root:wheel '${folder}' && sudo chmod go-w '${folder}'"
        fi
        [ "$folder" != "/" ] || break
        folder="$(dirname "$folder")"
    done
}

# Unloads the update job first, as the MSI deletes the update task before it stops the
# service: a run that fires in the middle would stop, swap and start the service under
# the script. 'service install' loads it again. A job that is not loaded is normal.
mac_stop_update_job() {
    launchctl bootout "$MAC_UPDATE_JOB" > /dev/null 2>&1 || true
}

# Stops the service through launchd, for a binary that is gone or does not run and so
# cannot stop its own service. It answers true once launchd no longer holds the job.
mac_bootout_service() {
    launchctl bootout "$MAC_SERVICE_JOB" > /dev/null 2>&1 || true
    ! launchctl print "$MAC_SERVICE_JOB" > /dev/null 2>&1
}

# The uninstall for a binary that is gone or does not run, as 'service uninstall' does it:
# the job, its plist and the console link. With the purge also the config folder, the
# empty mount folders and the service user, as 'service uninstall --purge' does. A mount
# folder is removed only when it is empty, so the script never deletes a file on a share.
mac_remove_service_by_hand() {
    echo "${PREFIX}/quix-bridge does not run, so the script removes the service by hand."
    mac_bootout_service \
        || fail "launchd still holds ${MAC_SERVICE_JOB}, and the binary does not run. Run 'sudo launchctl bootout ${MAC_SERVICE_JOB}', then run the script again."
    if [ -f "$MAC_DAEMON_PLIST" ]; then
        rm -f "$MAC_DAEMON_PLIST"
        echo "The script deleted ${MAC_DAEMON_PLIST}."
    fi
    rm -rf "${MAC_SUPPORT_DIR}/Bridge Console"
    [ "$1" != "keep" ] || return 0

    if [ -d "${MAC_SUPPORT_DIR}/Bridge" ]; then
        rm -rf "${MAC_SUPPORT_DIR}/Bridge"
        echo "The script deleted ${MAC_SUPPORT_DIR}/Bridge, with config.yaml and the stored share credentials."
    fi
    mounts="${MAC_SUPPORT_DIR}/Bridge Mounts"
    for folder in "$mounts"/*/* "$mounts"/* "$mounts"; do
        rmdir "$folder" 2> /dev/null || true
    done
    dscl . -delete "/Users/${MAC_ACCOUNT}" > /dev/null 2>&1 || true
    dscl . -delete "/Groups/${MAC_ACCOUNT}" > /dev/null 2>&1 || true
    echo "The script removed the user '${MAC_ACCOUNT}'."
}

# Puts the old version back after a failed install: the old binary, the old app, and the
# old service, started again. mac_install arms it once the old service stopped, and
# disarms it once the new service runs. on_exit runs it. On a first install there is no old
# version, so it runs the uninstall instead. A config folder that was there before stays.
mac_rollback() {
    if [ -n "$MAC_ROLLBACK_FIRST" ]; then
        echo "The install failed, and no old version was there to put back, so the script removes the bridge it installed. The lines above say why the install failed." >&2
        mac_uninstall "$MAC_ROLLBACK_FIRST"
        return 0
    fi
    echo "The install failed, so the script puts the old version back." >&2
    if [ -n "$MAC_ROLLBACK_BINARY" ] && [ -f "$MAC_ROLLBACK_BINARY" ]; then
        "$MAC_BINARY" service stop > /dev/null 2>&1 || true
        # The kernel just ran the new file, and Apple Silicon kills a signed file that
        # changed in place. So the old binary goes to a copy beside it, and the rename
        # gives the path a new file.
        if cp -p "$MAC_ROLLBACK_BINARY" "${MAC_BINARY}.rollback"; then
            mv -f "${MAC_BINARY}.rollback" "$MAC_BINARY" || true
        fi
        rm -f "${MAC_BINARY}.rollback"
    fi
    old_app="$(mac_app_beside .old)"
    if [ "$MAC_ROLLBACK_APP" = "1" ] && [ -d "$old_app" ]; then
        rm -rf "$MAC_APP_DIR"
        mv "$old_app" "$MAC_APP_DIR" || true
    fi
    if [ "$MAC_ROLLBACK_SERVICE" = "1" ] && [ -x "$MAC_BINARY" ]; then
        # The old install writes its own plist and loads the update job again.
        "$MAC_BINARY" service install > /dev/null 2>&1 || true
        if "$MAC_BINARY" service start > /dev/null 2>&1; then
            echo "The old version runs again." >&2
        else
            echo "The old version is back, and its service did not start. Run 'sudo quix-bridge service start'." >&2
        fi
    fi
}

# The one exit handler: the rollback of a failed macOS install, then the scratch folders.
MAC_ROLLBACK_ARMED=""
MAC_ROLLBACK_BINARY=""
MAC_ROLLBACK_APP=""
MAC_ROLLBACK_SERVICE=""
# "purge" or "keep" on a first install (no old binary): the data the rollback's uninstall keeps.
MAC_ROLLBACK_FIRST=""
MAC_BINARY=""
on_exit() {
    if [ "$1" -ne 0 ] && [ "$MAC_ROLLBACK_ARMED" = "1" ]; then
        MAC_ROLLBACK_ARMED=""
        mac_rollback || true
    fi
    [ -z "${app_work:-}" ] || rm -rf "$app_work"
    [ -z "${work:-}" ] || rm -rf "$work"
}

# Writes Quix Lake Bridge.app to /Applications: the twin of the Windows Start-menu
# shortcut, so a person who quit the menu bar item opens it again from Finder,
# Launchpad or Spotlight. The app runs only the menu bar item; the service keeps
# running the binary in PREFIX.
#
# The new app is copied next to the old one and moved in whole. root owns every file
# and nobody else may write one: the menu bar item runs this copy, and its Start and
# Stop Service items run it as root behind the password prompt, so a file a person
# could change would be a way to root. A tar.gz unpacked as root keeps the owner of
# the build machine, so the script sets the owner itself.
#
# A release with no app (one from before the app) leaves no older app behind: that app
# would run an older copy of the binary, and the login item would pick it.
mac_install_app() {
    new_app="$1"
    if [ -z "$new_app" ] || [ ! -d "$new_app" ]; then
        if [ -d "$MAC_APP_DIR" ]; then
            # Moved aside, not deleted, until the new service runs: a rollback puts it back.
            rm -rf "$(mac_app_beside .old)"
            mv "$MAC_APP_DIR" "$(mac_app_beside .old)"
            MAC_ROLLBACK_APP="1"
            echo "This build holds no ${MAC_APP_NAME}, so the script deleted the older one at ${MAC_APP_DIR}."
        fi
        return 0
    fi
    staged="$(mac_app_beside .installing)"
    old_app="$(mac_app_beside .old)"
    rm -rf "$staged"
    mkdir -p "$(dirname "$MAC_APP_DIR")"
    cp -R "$new_app" "$staged"
    chown -R root:wheel "$staged"
    chmod -R go-w "$staged"
    # The old app stays beside it until the new service runs, so a rollback can put it back.
    rm -rf "$old_app"
    if [ -d "$MAC_APP_DIR" ]; then
        mv "$MAC_APP_DIR" "$old_app"
        MAC_ROLLBACK_APP="1"
    fi
    mv "$staged" "$MAC_APP_DIR"
    echo "The script wrote ${MAC_APP_DIR}."
}

# Exits 0 when the first version is newer than the second. A version is dotted numbers,
# as 'quix-bridge version' prints them ("0.1.26"). A leading v goes, a suffix after the
# numbers goes ("0.2.0-rc1" reads as 0.2.0), and a missing part reads as 0.
mac_version_newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        sub(/^v/, "", a); sub(/[^0-9.].*$/, "", a); n = split(a, x, ".")
        sub(/^v/, "", b); sub(/[^0-9.].*$/, "", b); m = split(b, y, ".")
        last = n > m ? n : m
        for (i = 1; i <= last; i++) {
            p = (i in x) ? x[i] + 0 : 0
            q = (i in y) ? y[i] + 0 : 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 1
    }'
}

# The install and the upgrade. A second run of the same version is the repair: every
# step runs again, so a lost plist, a lost config folder lock, a lost app or a lost
# login item comes back, as the MSI repair puts back the service and the config folder.
# The second argument is the new Quix Lake Bridge.app, or empty for a build with none.
mac_install() {
    new_binary="$1"
    new_app="${2:-}"
    binary="${PREFIX}/quix-bridge"
    MAC_BINARY="$binary"
    trap 'on_exit "$?"' EXIT

    # A binary folder that a person other than root may write stops the script first.
    mac_require_root_owned_prefix

    # A broken app stops the script before it stops anything.
    if [ -n "$new_app" ] && [ -d "$new_app" ] && [ ! -f "${new_app}/Contents/MacOS/quix-bridge" ]; then
        fail "${new_app} holds no Contents/MacOS/quix-bridge. Nothing changed."
    fi

    # So does a broken seal: the stop comes after the check.
    mac_verify_seal "$new_binary" "$new_app"

    # The MSI refuses a downgrade (DowngradeErrorMessage in quix-bridge.wxs), so the
    # script refuses one too, before it stops anything. Each binary names its own
    # version. An installed binary that prints none is broken, and the repair replaces
    # it. The same version is the repair, and it runs.
    if [ -x "$binary" ]; then
        installed_version="$("$binary" version 2> /dev/null)" || installed_version=""
        new_version="$("$new_binary" version 2> /dev/null)" || new_version=""
        if [ -n "$installed_version" ] && [ -n "$new_version" ] && mac_version_newer "$installed_version" "$new_version"; then
            fail "Quix Bridge ${installed_version} is already installed. It is newer than ${new_version}, and the script refuses a downgrade. Nothing changed. Run the script with --uninstall --keep-data first, or run it with QUIX_BRIDGE_VERSION=${installed_version}."
        fi
    fi

    # The update job goes first, before the stop, as in the MSI.
    mac_stop_update_job

    # Never replace the binary of a running service. 'service stop' waits until launchd
    # lets the job go, and it says so when the service was stopped already.
    # A binary that is gone or does not run cannot stop its own service, so launchd
    # stops it, and the repair goes on.
    if [ -f "$MAC_DAEMON_PLIST" ]; then
        echo "The script stops the service before it replaces the binary."
        if [ -x "$binary" ] && "$binary" service stop; then
            MAC_ROLLBACK_SERVICE="1"
        elif [ -x "$binary" ] && "$binary" version > /dev/null 2>&1; then
            fail "The service did not stop, so the script replaced nothing. Run 'sudo quix-bridge service stop', then run the script again."
        else
            mac_bootout_service \
                || fail "The service did not stop, and ${binary} does not run, so the script replaced nothing. Run 'sudo launchctl bootout ${MAC_SERVICE_JOB}', then run the script again."
            echo "${binary} does not run, so launchctl stopped the service."
        fi
    fi

    # From here a failure puts the old version back, so a failed copy never leaves the
    # service down. The old binary stays as quix-bridge.old, as an update keeps it: the
    # way back by hand.
    MAC_ROLLBACK_ARMED="1"
    if [ ! -f "$binary" ]; then
        MAC_ROLLBACK_FIRST="purge"
        [ ! -d "${MAC_SUPPORT_DIR}/Bridge" ] || MAC_ROLLBACK_FIRST="keep"
    fi
    mkdir -p "$PREFIX"
    if [ -f "$binary" ]; then
        cp -p "$binary" "${binary}.old"
        MAC_ROLLBACK_BINARY="${binary}.old"
    fi

    # A fresh Apple Silicon Mac has no /usr/local/bin. A running menu bar item keeps the
    # old file open; install writes a new file, and the item starts itself again on it.
    install -m 0755 "$new_binary" "$binary"
    echo "The script wrote ${binary}."

    # The app goes in before the service starts again: a running menu bar item restarts
    # itself on the new file once the service runs, and before the login item, which
    # runs the app's copy when the app is there.
    mac_install_app "$new_app"

    # A browser download marks a local build with com.apple.quarantine, and the copy keeps
    # the mark. The script clears it. A file with no mark is normal.
    xattr -dr com.apple.quarantine "$binary" > /dev/null 2>&1 || true
    [ ! -d "$MAC_APP_DIR" ] || xattr -dr com.apple.quarantine "$MAC_APP_DIR" > /dev/null 2>&1 || true

    # Run on every install, so an upgrade and a repair lock the config folder again.
    "$binary" service install \
        || fail "The service install failed. The binary is at ${binary}. Run 'sudo quix-bridge service install' to read why."
    "$binary" service start \
        || fail "The service did not start. Run 'sudo quix-bridge logs' to read why, then 'sudo quix-bridge service start'."
    echo "The script installed the bridge and started the service."

    # The new version runs, so the old app goes. Nothing after this fails the install.
    MAC_ROLLBACK_ARMED=""
    rm -rf "$(mac_app_beside .old)"

    # The console opens before the menu bar item starts, so the item finds the marker
    # and shows no second first-run box.
    mac_open_console

    # The macOS twin of the all-users Startup shortcut: a LaunchAgent for every person,
    # started now in the session at the screen. It runs the app's copy, so Login Items
    # names Quix Lake Bridge. Like the MSI's tray start, a failure here costs the icon
    # and never the install.
    if ! "$binary" tray login-item install; then
        echo "The script could not add the menu bar item. Run 'sudo quix-bridge tray login-item install'."
    fi

    if [ -d "$MAC_APP_DIR" ]; then
        echo "After Quit, open Quix Lake Bridge from Applications, Launchpad or Spotlight to show the menu bar item again."
    fi

    # The twin of the install.ps1 text: 'service install' loaded the update job.
    echo "The bridge updates itself: the LaunchDaemon io.quix.bridge.update runs every 5 minutes and installs the release the gateway offers. It installs nothing when config.yaml sets update.channel to manual."

    # No code can grant Full Disk Access, so the script names the step and opens no window.
    echo "A share under ~/Documents, ~/Desktop, ~/Downloads, iCloud Drive or a removable disk needs Full Disk Access for ${binary}: open System Settings > Privacy & Security > Full Disk Access, and add it."
}

# A local build: the quix-bridge an AOT publish wrote, with no download. The folder may
# hold Quix Lake Bridge.app too; without one, make-app.sh (next to this script in the
# repository) builds it from the binary, so a local install has the app as a release
# does. Then the release install runs.
mac_install_local() {
    local_dir="$1"
    [ -f "${local_dir}/quix-bridge" ] \
        || fail "There is no quix-bridge in '${local_dir}'. Publish one first, as docs/bridge/MACOS-PORT.md says (Building it). Nothing changed."

    local_app="${local_dir}/${MAC_APP_NAME}"
    app_work=""
    # on_exit deletes app_work on every exit, a failed install too.
    trap 'on_exit "$?"' EXIT
    if [ ! -d "$local_app" ]; then
        [ -f "$MAC_MAKE_APP" ] \
            || fail "'${local_dir}' holds no ${MAC_APP_NAME}, and the script found no make-app.sh at ${MAC_MAKE_APP} to build one. Run the script from the repository: sudo sh packaging/install.sh --from-local '${local_dir}'. Nothing changed."
        local_version="$("${local_dir}/quix-bridge" version)" \
            || fail "'${local_dir}/quix-bridge version' failed, so the script cannot name the app's version. Nothing changed."
        app_work="$(mktemp -d)"
        # An ad hoc signature seals the local bundle, as the release pipeline seals an unsigned one.
        if ! QUIX_BRIDGE_APP_SIGN="${QUIX_BRIDGE_APP_SIGN:--}" sh "$MAC_MAKE_APP" "${local_dir}/quix-bridge" "$local_version" "$app_work"; then
            fail "make-app.sh could not build ${MAC_APP_NAME}. Nothing changed."
        fi
        local_app="${app_work}/${MAC_APP_NAME}"
    fi

    echo "The script installs the local build in ${local_dir}."
    mac_install "${local_dir}/quix-bridge" "$local_app"
    [ -z "$app_work" ] || rm -rf "$app_work"
    app_work=""
}

# The uninstall: the twin of the MSI removal. It removes the service, the update job,
# the menu bar item for every person, the app and the binary, with the copies an update
# or an install keeps of them. The data goes too (config.yaml, the stored share
# credentials, the service user, the update folder and the logs), unless keep is "keep",
# the twin of KEEPDATA=1, which keeps the logs as well.
mac_uninstall() {
    keep="$1"
    binary="${PREFIX}/quix-bridge"

    # The update job goes first, as the MSI deletes the update task first: a run that
    # fired now would start the service the uninstall stops.
    mac_stop_update_job

    # The binary knows how to remove the service. A binary that is gone or does not run
    # cannot, so the script removes the service by hand (mac_remove_service_by_hand).
    binary_runs=""
    if [ -x "$binary" ] && "$binary" version > /dev/null 2>&1; then
        binary_runs="1"
    fi

    # The menu bar item goes next, as the MSI closes the trays first: the item for every
    # person and the one it started at the screen, then any item a person added for
    # themselves, then every item still running.
    if [ -n "$binary_runs" ] && [ -n "$MAC_ROLLBACK_FIRST" ]; then
        # A first install that failed may not have reached the login item, so "No login item
        # at ..." is noise in its rollback. Every other line of the command still shows.
        "$binary" tray login-item remove 2>&1 | grep -v '^No login item at ' || true
    elif [ -n "$binary_runs" ]; then
        "$binary" tray login-item remove || true
    fi
    for agent in "$MAC_USERS_DIR"/*/Library/LaunchAgents/"$MAC_TRAY_AGENT_NAME"; do
        [ -f "$agent" ] || continue
        rm -f "$agent"
        echo "The script deleted ${agent}."
    done
    for pid in $(mac_tray_pids); do
        kill "$pid" 2> /dev/null || true
    done

    # The item keeps its lock and its log in each person's folder. The lock goes with the
    # item, and the log goes with the data. The console-opened marker stays, as on Windows.
    for person in "$MAC_USERS_DIR"/*/"$MAC_PERSON_DIR"; do
        [ -d "$person" ] || continue
        rm -f "${person}/tray.lock"
        if [ "$keep" != "keep" ] && [ -d "${person}/logs" ]; then
            rm -rf "${person}/logs"
            echo "The script deleted ${person}/logs."
        fi
    done

    if [ -z "$binary_runs" ]; then
        mac_remove_service_by_hand "$keep"
    else
        # A stop of a service that does not run is a normal state, as in the MSI.
        "$binary" service stop || true
        if [ "$keep" = "keep" ]; then
            "$binary" service uninstall \
                || fail "The service uninstall failed. Run 'sudo quix-bridge service uninstall' to read why."
        else
            "$binary" service uninstall --purge \
                || fail "The service uninstall failed. Run 'sudo quix-bridge service uninstall --purge' to read why."
        fi
    fi

    # The binary removes the machine login item and the update plist itself. A binary
    # that is gone or does not run never did, so the script deletes them by hand.
    for leftover in "$MAC_TRAY_AGENT" "$MAC_UPDATE_PLIST"; do
        [ -f "$leftover" ] || continue
        rm -f "$leftover"
        echo "The script deleted ${leftover}."
    done

    # The data that sits apart from the config folder on macOS: the update folder (the
    # hold, the backoff, the cache) and the logs. --keep-data keeps both, as KEEPDATA=1
    # keeps the logs on Windows and Linux never deletes /var/log.
    if [ "$keep" != "keep" ]; then
        for data in "$MAC_UPDATE_DIR" "$MAC_LOG_DIR" "$MAC_SERVICE_LOG_DIR" "$MAC_UPDATE_LOG_DIR"; do
            [ -d "$data" ] || continue
            rm -rf "$data"
            echo "The script deleted ${data}."
        done
        rmdir "$(dirname "$MAC_LOG_DIR")" 2> /dev/null || true
    fi

    # The app goes with the binary: it is the Start-menu shortcut's twin, and the MSI
    # removes that too. So do the hidden copies an update or an install keeps.
    for app in "$MAC_APP_DIR" "$(mac_app_beside .new)" "$(mac_app_beside .old)" "$(mac_app_beside .installing)"; do
        [ -d "$app" ] || continue
        rm -rf "$app"
        echo "The script deleted ${app}."
    done

    for file in "$binary" "${binary}.old" "${binary}.new"; do
        [ -e "$file" ] || continue
        rm -f "$file"
        echo "The script deleted ${file}."
    done

    # The purge deleted the config folder, so the Quix folder above it may be empty now.
    rmdir "$MAC_SUPPORT_DIR" 2> /dev/null || true

    if [ "$keep" = "keep" ]; then
        echo "The bridge is removed. config.yaml and the stored share credentials stay, so a new install picks them up."
    else
        echo "The bridge is removed, with config.yaml and the stored share credentials."
    fi
}

# A test loads the functions above and runs them against stand-in tools. Nothing below
# runs then. The exit is for a run that executes the file instead of sourcing it.
if [ "${QUIX_BRIDGE_INSTALL_FUNCTIONS_ONLY:-}" = "1" ]; then
    # shellcheck disable=SC2317
    return 0 2> /dev/null || exit 0
fi

# ---- read the arguments -----------------------------------------------------

ACTION="install"
KEEP_DATA="purge"
FROM_LOCAL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --uninstall) ACTION="uninstall" ;;
        --keep-data) KEEP_DATA="keep" ;;
        --from-local)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--from-local takes the folder of a local build: --from-local out/osx-arm64. Nothing changed."
            FROM_LOCAL="$2"
            shift
            ;;
        --from-local=*) FROM_LOCAL="${1#--from-local=}" ;;
        -h|--help)
            echo "usage: install.sh [--uninstall [--keep-data]] [--from-local <folder>]"
            echo "  (no option)            install the bridge, or upgrade or repair it"
            echo "  --uninstall            macOS: remove the bridge, with config.yaml and the stored share credentials"
            echo "  --keep-data            with --uninstall: keep config.yaml and the stored share credentials"
            echo "  --from-local <folder>  macOS: install the quix-bridge a local AOT publish wrote to <folder>,"
            echo "                         and the app from it, instead of a release"
            exit 0
            ;;
        *) fail "install.sh takes --uninstall, --keep-data and --from-local <folder> only. It read '$1'." ;;
    esac
    shift
done
if [ "$KEEP_DATA" = "keep" ] && [ "$ACTION" != "uninstall" ]; then
    fail "--keep-data goes with --uninstall only. Nothing changed."
fi
if [ -n "$FROM_LOCAL" ] && [ "$ACTION" = "uninstall" ]; then
    fail "--from-local installs a build, so it does not go with --uninstall. Nothing changed."
fi

# ---- read the machine, and name the runtime -------------------------------

os="$(uname -s)"
machine="$(uname -m)"

case "$os" in
    Linux)  os_part="linux" ;;
    Darwin)
        os_part="osx"
        # A shell under Rosetta reads x86_64 from uname -m on an Apple Silicon Mac. The
        # kernel still answers for the hardware.
        if [ "$(sysctl -n hw.optional.arm64 2> /dev/null || true)" = "1" ]; then
            machine="arm64"
        fi
        ;;
    *) fail "This script installs the bridge on Linux and macOS. It read '$os'. On Windows, run install.ps1." ;;
esac

case "$machine" in
    x86_64|amd64)  arch_part="x64" ;;
    aarch64|arm64) arch_part="arm64" ;;
    *) fail "The bridge has no build for the architecture '$machine'." ;;
esac

RUNTIME="${os_part}-${arch_part}"

if [ "$RUNTIME" = "linux-arm64" ]; then
    fail "There is no linux-arm64 build of the bridge yet. Supported: linux-x64, osx-arm64, win-x64, win-arm64."
fi

# The macOS layer covers Intel as well, but no lane has run it on an Intel Mac.
if [ "$RUNTIME" = "osx-x64" ]; then
    fail "There is no osx-x64 build of the bridge yet. Supported: osx-arm64, linux-x64, win-x64, win-arm64."
fi
echo "This machine is $RUNTIME."

if [ "$ACTION" = "uninstall" ]; then
    if [ "$os_part" != "osx" ]; then
        # The Linux packages own the removal, as Settings > Apps owns it on Windows.
        fail "On Linux, remove the package: 'sudo apt remove quix-bridge' or 'sudo dnf remove quix-bridge'. A tar.gz install: run 'sudo quix-bridge service uninstall --purge', then delete ${PREFIX}/quix-bridge."
    fi
    if [ "$KEEP_DATA" = "keep" ]; then
        mac_require_root "uninstall" "--uninstall --keep-data"
    else
        mac_require_root "uninstall" "--uninstall"
    fi
    mac_uninstall "$KEEP_DATA"
    exit 0
fi

# A local build installs with no download and no SHA256SUMS: the person built it.
if [ -n "$FROM_LOCAL" ]; then
    [ "$os_part" = "osx" ] \
        || fail "--from-local is for macOS. On Linux, install the binary by hand: sudo install -m 0755 <folder>/quix-bridge ${PREFIX}/quix-bridge"
    # A piped script (curl ... | sudo sh -s --) has no file. Then $0 names the shell, and
    # MAC_MAKE_APP points into the current folder, so a make-app.sh there would run as root.
    [ -f "$0" ] \
        || fail "--from-local needs the script as a file, because it runs macos/make-app.sh next to it. Run it from the repository: sudo sh packaging/install.sh --from-local '${FROM_LOCAL}'. Nothing changed."
    if [ "$(id -u)" -ne 0 ]; then
        fail "The macOS install needs root rights, because the service and the menu bar item are for every person. Nothing changed. Run it again with sudo:
  sudo sh $0 --from-local '${FROM_LOCAL}'"
    fi
    mac_install_local "$FROM_LOCAL"
    echo "Done. Run 'quix-bridge status' to read the state."
    exit 0
fi

# The macOS install runs as root from the first step, so a run without it downloads
# nothing and changes nothing.
if [ "$os_part" = "osx" ]; then
    mac_require_root "install" ""
fi

# ---- resolve the version and the asset ------------------------------------

# The release tag carries a v, and the asset name does not. So a pinned install
# reads "download/v1.2.0/quix-bridge-1.2.0-linux-x64.deb". A tag with no v answers
# 404. install.ps1 builds the same URL.
if [ "$VERSION" = "latest" ]; then
    base="https://github.com/${REPO}/releases/latest/download"
else
    # A caller may type the tag or the number. The asset name needs the number.
    VERSION="${VERSION#v}"
    base="https://github.com/${REPO}/releases/download/v${VERSION}"
fi

# The version goes into every asset name, so a "latest" install must learn the
# real number first.
if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name" *: *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$VERSION" ] || fail "The script could not read the newest release of $REPO."
fi

echo "The newest version is $VERSION."

# Prefer the native package on Linux. The package manager then owns the upgrade
# and the removal.
kind="tar"
if [ "$os_part" = "linux" ]; then
    if command -v dpkg > /dev/null 2>&1; then
        kind="deb"
    elif command -v rpm > /dev/null 2>&1; then
        kind="rpm"
    fi
fi

case "$kind" in
    deb) asset="quix-bridge-${VERSION}-${RUNTIME}.deb" ;;
    rpm) asset="quix-bridge-${VERSION}-${RUNTIME}.rpm" ;;
    *)   asset="quix-bridge-${VERSION}-${RUNTIME}.tar.gz" ;;
esac

url="${base}/${asset}"
echo "Download $url"

work="$(mktemp -d)"
trap 'on_exit "$?"' EXIT
if ! curl -fSL -o "${work}/${asset}" "$url"; then
    # The first macOS release is the first one with an osx-arm64 asset. An older
    # release, or a pinned version before it, has none, and curl reads that as a 404.
    if [ "$os_part" = "osx" ]; then
        fail "The download of $url failed. Release $VERSION may hold no macOS build: macOS ships from a later release than Linux and Windows. Supported here: osx-arm64."
    fi
    fail "The download of $url failed."
fi

# ---- check the download before anything runs ------------------------------

# SHA256SUMS comes from the same release. It must name this asset, and the hash must
# match. Any other answer stops the script before the file installs.
curl -fsSL -o "${work}/SHA256SUMS" "${base}/SHA256SUMS" \
    || fail "The download of ${base}/SHA256SUMS failed. The script installed nothing."

expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "${work}/SHA256SUMS")"
[ -n "$expected" ] || fail "SHA256SUMS names no line for $asset. The script installed nothing."

if command -v sha256sum > /dev/null 2>&1; then
    actual="$(sha256sum "${work}/${asset}" | cut -d ' ' -f 1)"
elif command -v shasum > /dev/null 2>&1; then
    actual="$(shasum -a 256 "${work}/${asset}" | cut -d ' ' -f 1)"
else
    fail "This machine has no sha256sum and no shasum, so the script cannot check the download."
fi

expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
[ "$actual" = "$expected" ] \
    || fail "The SHA256 of $asset does not match SHA256SUMS. The script installed nothing. Download it again."
echo "The SHA256 of $asset matches SHA256SUMS."
if [ "$os_part" = "osx" ]; then
    echo "This build has no Developer ID signature. The script checked its SHA256, and it checks the ad hoc seal before it installs."
else
    echo "This build is unsigned. The script checked its SHA256 only."
fi

# ---- install --------------------------------------------------------------

sudo_if_needed() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo > /dev/null 2>&1; then
        sudo "$@"
    else
        fail "The install needs root rights, and this machine has no sudo. Run the script as root."
    fi
}

# THE INSTALL MUST RESOLVE DEPENDENCIES. The bridge needs ICU, OpenSSL and a CA
# trust store, and the package names all three. `dpkg -i` and `rpm -Uvh` install one
# file and resolve NOTHING, so on a plain machine they leave the package unconfigured
# or, worse, installed and unable to start. apt-get and dnf read the same file and
# pull what it needs, so the script prefers them and falls back only where neither
# exists.
case "$kind" in
    deb)
        if command -v apt-get > /dev/null 2>&1; then
            sudo_if_needed apt-get install -y "${work}/${asset}"
        else
            sudo_if_needed dpkg -i "${work}/${asset}"
        fi
        ;;
    rpm)
        if command -v dnf > /dev/null 2>&1; then
            sudo_if_needed dnf install -y "${work}/${asset}"
        elif command -v yum > /dev/null 2>&1; then
            sudo_if_needed yum install -y "${work}/${asset}"
        else
            sudo_if_needed rpm -Uvh "${work}/${asset}"
        fi
        ;;
    *)
        tar -xzf "${work}/${asset}" -C "$work"
        [ -f "${work}/quix-bridge" ] || fail "The archive holds no quix-bridge binary."
        if [ "$os_part" = "osx" ]; then
            # The whole install, as the MSI does it on Windows. See mac_install above.
            # The release carries Quix Lake Bridge.app next to the binary; an older one
            # carries none, and mac_install_app says so.
            mac_install "${work}/quix-bridge" "${work}/${MAC_APP_NAME}"
        else
            sudo_if_needed mkdir -p "$PREFIX"
            sudo_if_needed install -m 0755 "${work}/quix-bridge" "${PREFIX}/quix-bridge"
            echo "The script wrote ${PREFIX}/quix-bridge."
            # A tar.gz install has no package manager, so nothing pulls the three
            # libraries the bridge opens at start. Name them here, because the .NET
            # failure message names no package.
            echo "This machine needs ICU, OpenSSL and a CA trust store."
            echo "  RHEL family:      sudo dnf install libicu openssl-libs ca-certificates"
            echo "  Debian family:    sudo apt install libicu<N> libssl<N> ca-certificates"
            echo "Run 'quix-bridge version' now. It prints the version when all three are there."
            echo "Run 'sudo ${PREFIX}/quix-bridge service install' to register the service."
        fi
        ;;
esac

echo "Done. Run 'quix-bridge status' to read the state."
