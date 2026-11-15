#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat >&2 <<'EOF'
Usage: scripts/build-macos.sh [debug|release] [--build-only|--no-install] [--no-run|--run] [--install-dir <dir>] [-- --vault <path> ...]

Options:
  debug | release        Build configuration (default: release)
  --build-only           Assemble and verify only in .build-app/Cozy Notes.app (skip install & launch)
  --no-install           Alias for --build-only
  --no-run               Install into /Applications/Cozy Notes.app without launching
  --run                  Launch the installed app after installation (default when installing)
  --install-dir <dir>    Override destination directory (default: /Applications)
  --                     Pass remaining arguments to Cozy Notes on launch
EOF
    exit 2
}

configuration="release"
do_install=1
do_run=1
install_dir="${COZY_INSTALL_DIR:-/Applications}"
launch_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release)
            configuration="$1"
            shift
            ;;
        --build-only|--no-install)
            do_install=0
            do_run=0
            shift
            ;;
        --no-run)
            do_run=0
            shift
            ;;
        --run)
            do_run=1
            shift
            ;;
        --install-dir)
            [[ $# -ge 2 ]] || usage
            install_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            launch_args=("$@")
            break
            ;;
        *)
            usage
            ;;
    esac
done

swift build -c "$configuration"
bin="$(swift build -c "$configuration" --show-bin-path)"

if [[ ! -f packaging/AppIcon.icns ]]; then
    swift packaging/generate-icon.swift
fi

build_root="$PWD/.build-app"
app="$build_root/Cozy Notes.app"
staging_app="$build_root/Cozy Notes.app.staging.$$"
rm -rf -- "$staging_app"
trap 'rm -rf -- "$staging_app" "${install_staging:-}"' EXIT

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
cp "$bin/CozyNotes" "$staging_app/Contents/MacOS/CozyNotes"
cp packaging/Info.plist "$staging_app/Contents/Info.plist"
cp packaging/AppIcon.icns "$staging_app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$staging_app"

# Verify staged bundle before replacing any existing bundle
plutil -lint "$staging_app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$staging_app"
test -x "$staging_app/Contents/MacOS/CozyNotes"
test -s "$staging_app/Contents/Resources/AppIcon.icns"

rm -rf -- "$app"
mv "$staging_app" "$app"
printf '\nBuilt App: %s\n' "$app"

if [[ "$do_install" -eq 0 ]]; then
    exit 0
fi

dest_app="$install_dir/Cozy Notes.app"
if [[ ! -d "$install_dir" ]]; then
    echo "Error: Install directory '$install_dir' does not exist." >&2
    exit 1
fi
if [[ ! -w "$install_dir" ]] || { [[ -e "$dest_app" ]] && [[ ! -w "$dest_app" ]]; }; then
    cat >&2 <<EOF
Error: No write permission for '$install_dir' (or existing '$dest_app').
The verified build remains ready at:
  $app
Grant write access with an administrator account or install to a user-writable directory:
  scripts/build-macos.sh $configuration --install-dir "\$HOME/Applications"
EOF
    exit 1
fi

# Request a graceful quit of any running Cozy Notes instance so applicationShouldTerminate
# persists all open windows and Quick Capture drafts. Never force-kill (-9).
running_pids=()
while IFS= read -r pid; do
    [[ -n "$pid" ]] && running_pids+=("$pid")
done < <(pgrep -x CozyNotes || true)
if [[ ${#running_pids[@]} -gt 0 ]]; then
    printf 'Requesting graceful quit of running Cozy Notes (PID: %s)...\n' "${running_pids[*]}"
    osascript -e 'tell application id "local.cozy.notes" to quit' >/dev/null 2>&1 || kill -TERM "${running_pids[@]}" 2>/dev/null || true
    waited=0
    while pgrep -x CozyNotes >/dev/null 2>&1; do
        if [[ "$waited" -ge 100 ]]; then
            echo "Error: Cozy Notes is still running (quit was cancelled or unsaved work blocked termination). Aborting install without modifying '$dest_app'." >&2
            exit 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
fi

install_staging="$install_dir/.Cozy Notes.app.staging.$$"
rm -rf -- "$install_staging"
ditto "$app" "$install_staging"
codesign --verify --deep --strict "$install_staging"
rm -rf -- "$dest_app"
mv "$install_staging" "$dest_app"
install_staging=""
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest_app" >/dev/null 2>&1 || true

printf 'Installed App: %s\n' "$dest_app"

if [[ "$do_run" -eq 1 ]]; then
    if [[ ${#launch_args[@]} -gt 0 ]]; then
        open -a "$dest_app" --args "${launch_args[@]}"
    else
        open -a "$dest_app"
    fi
    printf 'Launched App: %s\n' "$dest_app"
fi
