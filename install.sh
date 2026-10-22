#!/bin/bash
# ComfyNuke for macOS: installs, updates and repairs ComfyUI + ComfyUI-for-Nuke.
#
# Same design as comfynuke.ps1 (Windows):
# - Self-contained: ComfyUI, uv and Python live in one folder (default ~/ComfyNuke).
#   Git comes from Apple's Command Line Tools; nothing else system-wide is touched.
# - Pinned: versions come from versions.json. Nothing is upgraded unless picked in `update`.
# - Reversible: install/update/rollback take a snapshot first (git commits, pip freeze, menu.py).
# - Traceable: logs in ~/Library/Logs/ComfyNuke, plus a change list after every run.
#
# Usage:  bash install.sh [menu|install|update|status|start|rollback|doctor|uninstall|models|hf-login|self-update]
#         options: --root DIR  --latest  --dry-run  --yes
# Written for the bash 3.2 that ships with macOS (no associative arrays, no mapfile).

set -o pipefail

APP_VERSION="0.1.1"
REPO_SLUG="amsyeung/comfyui-nuke-setup"
PORT=8188
BLOCK_START="# >>> comfynuke >>>"
BLOCK_END="# <<< comfynuke <<<"

# --- arguments ---------------------------------------------------------------
COMMAND="menu"; ROOT=""; LATEST=0; DRY_RUN=0; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        menu|install|update|status|start|rollback|doctor|uninstall|models|hf-login|self-update|help) COMMAND="$1" ;;
        --root) shift; ROOT="$1" ;;
        --latest) LATEST=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --yes) YES=1 ;;
        -h|--help) COMMAND="help" ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

# --- locations -----------------------------------------------------------------
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
DATA_DIR="$HOME/Library/Application Support/ComfyNuke"
LOG_DIR="$HOME/Library/Logs/ComfyNuke"
CONFIG_FILE="$DATA_DIR/config"            # remembers where ComfyNuke was installed
NUKE_HOME="$HOME/.nuke"
DEFAULT_ROOT="$HOME/ComfyNuke"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR" "$DATA_DIR"
LOG_FILE="$LOG_DIR/$RUN_ID-$COMMAND.log"
CHANGES_FILE="$(mktemp "${TMPDIR:-/tmp}/comfynuke-changes.XXXXXX")"

# When piped from curl there is no versions.json next to the script: fetch the one for this version
MANIFEST="$APP_DIR/versions.json"
if [ ! -f "$MANIFEST" ]; then
    MANIFEST="$DATA_DIR/versions-$APP_VERSION.json"
    curl -fsSL "https://raw.githubusercontent.com/$REPO_SLUG/v$APP_VERSION/versions.json" -o "$MANIFEST" \
        || { echo "Cannot download versions.json"; exit 1; }
fi

# --- output, log and change list ---------------------------------------------------
c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_gray=$'\033[90m'; c_off=$'\033[0m'

log() {   # log LEVEL MESSAGE
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$level" "$*" >> "$LOG_FILE"
    case "$level" in
        STEP)  printf '\n%s==> %s%s\n' "$c_cyan" "$*" "$c_off" ;;
        OK)    printf '    %s%s%s\n' "$c_green" "$*" "$c_off" ;;
        WARN)  printf '    %s! %s%s\n' "$c_yellow" "$*" "$c_off" ;;
        ERROR) printf '    %sx %s%s\n' "$c_red" "$*" "$c_off" ;;
        DEBUG) printf '    %s%s%s\n' "$c_gray" "$*" "$c_off" ;;
        *)     printf '    %s\n' "$*" ;;
    esac
}

# Kind is shown to the user: Install / Update / Config / Backup / Restore / Delete
add_change() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CHANGES_FILE"
    log OK "[$1] $2  $3"
}

show_summary() {
    local lines=""
    if [ -s "$CHANGES_FILE" ]; then
        lines="$(awk -F'|' '{ printf "  %s  %-28s %s\n", $1, $2, $3 }' "$CHANGES_FILE")"
    else
        lines="  (no changes)"
    fi
    printf '\n%s==================== Changes in this run ====================%s\n%s\n' "$c_cyan" "$c_off" "$lines"
    printf '\n--- summary ---\n%s\n' "$lines" >> "$LOG_FILE"
    # history.log keeps one block per run next to the install
    if [ -n "$ROOT" ] && [ -d "$ROOT" ] && [ -s "$CHANGES_FILE" ]; then
        printf '\n[%s] %s (app %s, manifest %s)\n%s\n' "$RUN_ID" "$COMMAND" "$APP_VERSION" "$(mf manifestVersion)" "$lines" >> "$ROOT/history.log"
    fi
    printf '\n    %sFull log: %s%s\n' "$c_gray" "$LOG_FILE" "$c_off"
    : > "$CHANGES_FILE"
}

die() {
    log ERROR "$*"
    log WARN "Something went wrong. What was already done is kept. You can run it again, or choose \"Doctor\" to create a zip and send it to the person who helped you install."
    show_summary
    rm -f "$CHANGES_FILE"
    exit 1
}

# Prompts read from the terminal, so they also work with `curl ... | bash`
ask_yes_no() {   # ask_yes_no QUESTION DEFAULT(y|n)
    local q="$1" def="$2" a hint="[y/N]"
    [ "$def" = "y" ] && hint="[Y/n]"
    if [ "$YES" = 1 ]; then [ "$def" = "y" ]; return; fi
    while true; do
        printf '    %s %s ' "$q" "$hint"; read -r a < /dev/tty
        echo "    Q: $q -> '$a'" >> "$LOG_FILE"
        a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
        case "$a" in
            "") [ "$def" = "y" ]; return ;;
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "    Please type y (yes) or n (no)" ;;
        esac
    done
}

ask_text() {   # ask_text QUESTION DEFAULT -> stdout
    local q="$1" def="$2" a
    if [ "$YES" = 1 ]; then printf '%s' "$def"; return; fi
    printf '    %s [%s] ' "$q" "$def" > /dev/tty; read -r a < /dev/tty
    echo "    Q: $q -> '$a'" >> "$LOG_FILE"
    [ -z "$a" ] && a="$def"
    printf '%s' "$a"
}

# Run a command; its output goes to the screen and the log. Fails the run on error.
run() {
    log DEBUG "> $*"
    "$@" < /dev/null 2>&1 | while IFS= read -r line; do
        printf '      %s%s%s\n' "$c_gray" "$line" "$c_off"
        printf '      %s\n' "$line" >> "$LOG_FILE"
    done
    local code=${PIPESTATUS[0]}
    [ "$code" -eq 0 ] || die "$(basename "$1") failed (exit code $code). See the log for details."
}

# --- manifest (read with plutil, built into macOS) ---------------------------------
mf() { plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null; }
mf_list() {   # print every item of an array, one per line
    local i=0 v
    while v="$(mf "$1.$i")"; do printf '%s\n' "$v"; i=$((i + 1)); done
}
repo_keys() { mf_list repoOrder; }

# --- paths, settings and state -------------------------------------------------------
CLEARED_ENV=""   # PYTHON*/UV_* variables found in this user's environment (ignored)
set_paths() {
    # Another Python on this Mac must never leak in: PYTHONHOME/PYTHONPATH change even a venv's
    # Python, and UV_* settings change where packages come from. Cleared for this process only.
    local v
    for v in $(env | grep -E '^(PYTHON[A-Z_]*|UV_[A-Z_]*|VIRTUAL_ENV|CONDA_PREFIX)=' | cut -d= -f1); do
        unset "$v"; CLEARED_ENV="$CLEARED_ENV $v"
    done
    export PYTHONUTF8=1
    TOOLS="$ROOT/tools"
    UV="$ROOT/tools/uv/uv"
    COMFY="$ROOT/ComfyUI"
    VENV="$COMFY/.venv"
    PY="$VENV/bin/python"
    SNAPSHOTS="$ROOT/snapshots"
    BACKUPS="$ROOT/backups"
    APP_COPY="$ROOT/app"
    STATE="$ROOT/state.env"
    COMPLETE="$ROOT/.install-complete"   # written only after a verified install; the launcher checks it
    CONSTRAIN="$ROOT/tools/torch-constraints.txt"
    NUKE_LIBS="$NUKE_HOME/comfynuke_libs"
    MENU_PY="$NUKE_HOME/menu.py"
    # uv keeps Python and its cache inside the install folder
    export UV_PYTHON_INSTALL_DIR="$ROOT/tools/python"
    export UV_CACHE_DIR="$ROOT/tools/uv-cache"
    export UV_PYTHON_PREFERENCE="only-managed"
    export UV_NO_PROGRESS=1
    export UV_PYTHON_INSTALL_BIN=0   # never put python into ~/.local/bin (on PATH)
    export GIT_TERMINAL_PROMPT=0
    # git settings for this process only (never written to the user's global config)
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=advice.detachedHead GIT_CONFIG_VALUE_0=false
}

saved_root() { [ -f "$CONFIG_FILE" ] && sed -n 's/^root=//p' "$CONFIG_FILE"; }

# state.env holds simple key=value lines
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() {
    local tmp="$STATE.tmp"
    { [ -f "$STATE" ] && grep -v "^$1=" "$STATE"; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
    mv "$tmp" "$STATE"
}

repo_dir() { local t; t="$(mf "repos.$1.dir")"; t="${t//\{comfy\}/$COMFY}"; printf '%s' "${t//\{nuke\}/$NUKE_HOME}"; }

use_installed_root() {
    [ -z "$ROOT" ] && ROOT="$(saved_root)"
    [ -n "$ROOT" ] && [ -d "$ROOT" ] || die "Not installed yet. Please choose \"Install / Repair\" first."
    set_paths
}

# --- detection --------------------------------------------------------------------------
# One line per Nuke: name|major|python version|uv platform
find_nuke() {
    local app name major py ver arch plat
    for app in /Applications/Nuke*/Nuke*.app; do
        [ -d "$app" ] || continue
        name="$(basename "$app" .app)"
        major=0; [[ "$name" =~ Nuke([0-9]+) ]] && major="${BASH_REMATCH[1]}"
        py="$(find "$app/Contents" -maxdepth 6 -type f -name 'python3*' -perm -u+x 2>/dev/null | grep -E '/python3(\.[0-9]+)?$' | head -1)"
        ver=""; plat="aarch64-apple-darwin"
        if [ -n "$py" ]; then
            ver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
            arch="$(lipo -archs "$py" 2>/dev/null)"
            # Older Nuke builds are Intel-only and run under Rosetta
            case "$arch" in *arm64*) ;; *x86_64*) plat="x86_64-apple-darwin" ;; esac
        fi
        printf '%s|%s|%s|%s\n' "$name" "$major" "$ver" "$plat"
    done
}

running_blockers() {
    pgrep -qf '/Nuke[0-9][^/]*\.app/' && echo "Nuke is running"
    [ -n "$ROOT" ] && pgrep -qf "$ROOT/ComfyUI/.venv/bin/python" && echo "ComfyUI is running (Terminal window)"
}

wait_for_closed_apps() {
    local b
    while b="$(running_blockers)"; [ -n "$b" ]; do
        log WARN "Please close first: $(echo "$b" | paste -sd ',' -)"
        [ "$YES" = 1 ] && die "A program is still running, so we cannot continue"
        printf '    Press Enter after closing '; read -r _ < /dev/tty
    done
}

# Which device PyTorch will use, written to screen and log (for "why is it slow?" questions)
write_compute_device() {
    [ -x "$PY" ] || return 0
    local out
    out="$("$PY" -c 'import torch; print("mps" if torch.backends.mps.is_available() else "cpu", torch.__version__)' 2>/dev/null | tail -1)"
    case "$out" in
        mps*) log OK "Compute device: GPU (Apple MPS) — $(sysctl -n machdep.cpu.brand_string 2>/dev/null), torch ${out#mps }" ;;
        cpu*) log WARN "Compute device: CPU (the Apple GPU is not being used, so generating will be very slow), torch ${out#cpu }" ;;
        *) log WARN "Compute device: cannot tell (PyTorch could not load)" ;;
    esac
}

# What a running ComfyUI reports about itself (the most reliable answer to "GPU or CPU?")
write_comfy_device() {
    local f i name type
    f="$(mktemp "${TMPDIR:-/tmp}/comfynuke-stats.XXXXXX")"
    if curl -fs --max-time 2 "http://127.0.0.1:$PORT/system_stats" -o "$f" 2>/dev/null; then
        i=0
        while name="$(plutil -extract "devices.$i.name" raw -o - "$f" 2>/dev/null)"; do
            type="$(plutil -extract "devices.$i.type" raw -o - "$f" 2>/dev/null)"
            if [ "$type" = "cpu" ]; then log WARN "ComfyUI is using: $name ($type)"; else log OK "ComfyUI is using: $name ($type)"; fi
            i=$((i + 1))
        done
    fi
    rm -f "$f"
}

# Logs are small, but keep them bounded: 90 days and at most 200 files
remove_old_logs() {
    local n
    n="$(find "$LOG_DIR" -name '*.log' -mtime +90 2>/dev/null | wc -l | tr -d ' ')"
    find "$LOG_DIR" -name '*.log' -mtime +90 -delete 2>/dev/null
    ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +201 | while IFS= read -r f; do rm -f "$f"; done
    [ "${n:-0}" -gt 0 ] && log DEBUG "Cleaned up $n log files older than 90 days"
    return 0
}

# ComfyUI declares its minimum Python in pyproject.toml; check it before moving to a new commit
REQUIRED_PYTHON=""
python_requirement_ok() {   # python_requirement_ok DIR COMMIT INSTALLED_PYTHON
    [ -n "$3" ] || return 0
    REQUIRED_PYTHON="$(git -C "$1" show "$2:pyproject.toml" 2>/dev/null | sed -n 's/^requires-python *= *"*>= *\([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
    [ -n "$REQUIRED_PYTHON" ] || return 0
    awk -v have="$3" -v need="$REQUIRED_PYTHON" 'BEGIN { split(have, h, "."); split(need, n, "."); exit !((h[1] > n[1]) || (h[1] == n[1] && h[2] >= n[2])) }'
}

comfy_running() { curl -fs --max-time 2 "http://127.0.0.1:$PORT/system_stats" > /dev/null 2>&1; }

# --- building blocks ----------------------------------------------------------------------
install_uv() {
    local url sha ver dl existed=0
    url="$(mf macos.uv.url)"; sha="$(mf macos.uv.sha256)"; ver="$(mf macos.uv.version)"
    dl="$TOOLS/_download"; mkdir -p "$dl"
    run curl -fL --retry 3 --silent --show-error -o "$dl/uv.tar.gz" "$url"
    [ "$(shasum -a 256 "$dl/uv.tar.gz" | awk '{print $1}')" = "$sha" ] || { rm -f "$dl/uv.tar.gz"; die "The downloaded file failed its check (SHA256 does not match): $url"; }
    rm -rf "$dl/x" "$TOOLS/uv.new"; mkdir -p "$dl/x" "$TOOLS/uv.new"
    run tar -xzf "$dl/uv.tar.gz" -C "$dl/x"
    # The archive layout has changed between uv releases: just pick up the binaries
    find "$dl/x" -type f \( -name uv -o -name uvx \) -exec cp {} "$TOOLS/uv.new/" \;
    [ -x "$TOOLS/uv.new/uv" ] || die "Cannot find uv inside the uv archive"
    rm -rf "$dl/x"
    [ -d "$TOOLS/uv" ] && { existed=1; rm -rf "$TOOLS/uv"; }   # only our own private copy
    mv "$TOOLS/uv.new" "$TOOLS/uv"; rm -f "$dl/uv.tar.gz"
    state_set tool_uv "$ver"
    if [ $existed = 1 ]; then add_change Update uv "$ver (ComfyNuke private copy)"; else add_change Install uv "$ver (ComfyNuke private copy)"; fi
}

ensure_git() {
    if xcode-select -p > /dev/null 2>&1 && git --version > /dev/null 2>&1; then return; fi
    log WARN "Apple's \"Command Line Tools\" are needed (free, includes git)."
    ask_yes_no "Install now? (An Apple installer window will pop up)" y || die "Cannot continue without git"
    xcode-select --install > /dev/null 2>&1
    log INFO "In the window that pops up, click \"Install\". This will carry on by itself when it finishes..."
    local waited=0
    until xcode-select -p > /dev/null 2>&1 && git --version > /dev/null 2>&1; do
        sleep 10; waited=$((waited + 10))
        [ $waited -ge 3600 ] && die "Waited an hour and the Command Line Tools install still has not finished"
    done
    add_change Install "Command Line Tools" "Apple's developer tools (git)"
}

install_python() {
    local ver; ver="$(mf tools.python.version)"
    run "$UV" python install --no-bin "$ver"
    if [ -d "$VENV" ]; then rm -rf "$VENV"; add_change Delete "ComfyUI Python environment" "old environment (rebuilt right away)"; fi
    run "$UV" venv --seed --python "$ver" "$VENV"
    state_set python "$ver"; state_set torch_version ""
    add_change Install Python "$ver (for ComfyUI only)"
}

install_torch() {
    local ver old; ver="$(mf macos.torch.version)"; old="$(state_get torch_version)"
    log WARN "Downloading PyTorch (about 1 GB). The screen may not change for a few minutes; this is normal."
    run "$UV" pip install --python "$PY" "torch==$ver" torchvision torchaudio
    # Pin the exact torch build so later requirement installs never swap it out
    "$UV" pip freeze --python "$PY" | grep -E '^(torch|torchvision|torchaudio)==' > "$CONSTRAIN"
    state_set torch_version "$ver"; state_set torch_variant mps
    if [ -n "$old" ]; then add_change Update PyTorch "$ver (Apple GPU / MPS)"; else add_change Install PyTorch "$ver (Apple GPU / MPS)"; fi
}

install_requirements() {   # install_requirements DIR LABEL
    [ -f "$1/requirements.txt" ] || return 0
    if [ -f "$CONSTRAIN" ]; then run "$UV" pip install --python "$PY" -r "$1/requirements.txt" --constraint "$CONSTRAIN"
    else run "$UV" pip install --python "$PY" -r "$1/requirements.txt"; fi
    log OK "Python packages for $2 are ready"
}

# Clone or move a repo to an exact commit. Local edits are stashed, never lost.
# sync_repo KEY COMMIT REF [skip-requirements]; returns 0 if something changed
sync_repo() {
    local key="$1" commit="$2" ref="$3" skip_req="$4" dir url label before=""
    dir="$(repo_dir "$key")"; url="$(mf "repos.$key.url")"; label="$(mf "repos.$key.label")"
    if [ -d "$dir/.git" ]; then
        before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
        if [ "$before" = "$commit" ]; then log DEBUG "$label is already at $ref"; return 1; fi
        if [ -n "$(git -C "$dir" status --porcelain --ignore-submodules 2>/dev/null)" ]; then
            run git -C "$dir" stash push --include-untracked -m "comfynuke-$RUN_ID"
            add_change Backup "$label" "Local changes saved in git stash (comfynuke-$RUN_ID)"
        fi
        run git -C "$dir" fetch --tags --force origin
        if [ "$(mf "repos.$key.requirements")" = "true" ] && ! python_requirement_ok "$dir" "$commit" "$(state_get python)"; then
            die "$label $ref needs Python $REQUIRED_PYTHON or newer, but you have $(state_get python). Please update Python first (wait for a new tested version in versions.json), or pick a tested version instead."
        fi
    else
        if [ -e "$dir" ]; then
            # A folder that is not ours (e.g. an old manual install): keep it as a backup
            mv "$dir" "$dir.backup-$RUN_ID"
            add_change Backup "$label" "Old folder renamed to $(basename "$dir").backup-$RUN_ID"
        fi
        mkdir -p "$(dirname "$dir")"
        run git clone --filter=blob:none --no-checkout "$url" "$dir"
    fi
    run git -C "$dir" checkout --force --quiet "$commit"
    [ "$(mf "repos.$key.submodules")" = "true" ] && run git -C "$dir" submodule update --init --recursive --force
    [ "$(mf "repos.$key.requirements")" = "true" ] && [ "$skip_req" != "skip-requirements" ] && install_requirements "$dir" "$label"
    state_set "repo_${key}_ref" "$ref"; state_set "repo_${key}_commit" "$commit"
    if [ -n "$before" ]; then add_change Update "$label" "$ref (${commit:0:8})"; else add_change Install "$label" "$ref (${commit:0:8})"; fi
    return 0
}

# websocket-client etc. for Nuke's own Python, installed into ~/.nuke
nuke_targets() {   # "version|platform" lines; every supported version when no Nuke is found
    local min found=0 name major ver plat
    min="$(mf minNukeMajor)"
    while IFS='|' read -r name major ver plat; do
        [ -n "$ver" ] || continue
        [ "$major" -eq 0 ] || [ "$major" -ge "$min" ] || continue
        printf '%s|%s\n' "$ver" "$plat"; found=1
    done <<EOF
$(find_nuke)
EOF
    if [ $found = 0 ]; then for v in 3.9 3.10 3.11 3.12 3.13; do printf '%s|aarch64-apple-darwin\n' "$v"; done; fi
}

install_nuke_libs() {   # install_nuke_libs [force]
    local want ver plat key dir existed libs
    want="$(mf_list nukeLibs | paste -sd ',' -)"
    libs="$(mf_list nukeLibs | tr '\n' ' ')"
    while IFS='|' read -r ver plat; do
        [ -n "$ver" ] || continue
        key="py${ver//./}"; dir="$NUKE_LIBS/$key"
        if [ "$1" != "force" ] && [ -d "$dir" ] && [ "$(state_get "nukelibs_$key")" = "$want|$plat" ]; then continue; fi
        rm -rf "$dir.new"
        # shellcheck disable=SC2086  # $libs is a list of pinned requirement strings
        run "$UV" pip install --target "$dir.new" --python "$PY" --python-version "$ver" \
            --python-platform "$plat" --only-binary :all: --quiet $libs
        existed=0; [ -d "$dir" ] && { existed=1; rm -rf "$dir"; }
        mv "$dir.new" "$dir"
        state_set "nukelibs_$key" "$want|$plat"
        if [ $existed = 1 ]; then add_change Update "Nuke connection libraries (Python $ver)" "$want"; else add_change Install "Nuke connection libraries (Python $ver)" "$want"; fi
    done <<EOF
$(nuke_targets)
EOF
}

menu_block() {
    cat <<EOF
$BLOCK_START
# Managed by ComfyNuke (https://github.com/$REPO_SLUG). Changes inside this block are overwritten.
try:
    import os, sys
    _cn_lib = '$NUKE_LIBS/py%d%d' % sys.version_info[:2]
    if os.path.isdir(_cn_lib) and _cn_lib not in sys.path:
        sys.path.insert(0, _cn_lib)  # ahead of any PYTHONPATH packages, so the pinned versions win
    os.environ.setdefault('NUKE_COMFYUI_URL', '127.0.0.1:$PORT')
    os.environ.setdefault('INPUT_DIRECTORY', '$COMFY/input')
    os.environ.setdefault('OUTPUT_DIRECTORY', '$COMFY/output')
    import comfyui2nuke as comfyui
    comfyui.setup()
except Exception as _cn_err:
    import traceback
    traceback.print_exc()
    print('[ComfyNuke] ComfyUI menu not loaded: %s' % _cn_err)
$BLOCK_END
EOF
}

drop_trailing_blank_lines() {   # portable (BSD and GNU): buffer lines, print up to the last non-blank one
    awk '{ line[NR] = $0 } END { n = NR; while (n > 0 && line[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print line[i] }'
}

strip_menu_block() {   # print menu.py without our block
    awk -v s="$BLOCK_START" -v e="$BLOCK_END" '$0 == s { skip = 1; next } $0 == e { skip = 0; next } !skip' "$MENU_PY"
}

set_menu_block() {
    local tmp; mkdir -p "$NUKE_HOME"; tmp="$(mktemp "${TMPDIR:-/tmp}/comfynuke-menu.XXXXXX")"
    if [ -f "$MENU_PY" ]; then
        strip_menu_block | drop_trailing_blank_lines > "$tmp"
        [ -s "$tmp" ] && printf '\n' >> "$tmp"
    fi
    menu_block >> "$tmp"
    if [ -f "$MENU_PY" ] && cmp -s "$tmp" "$MENU_PY"; then rm -f "$tmp"; return; fi
    if [ -f "$MENU_PY" ]; then
        mkdir -p "$BACKUPS"; cp "$MENU_PY" "$BACKUPS/menu.py.$RUN_ID"
        add_change Backup menu.py "backups/menu.py.$RUN_ID"
    fi
    mv "$tmp" "$MENU_PY"
    add_change Config "Nuke menu.py" "Added the ComfyUI menu (only the marked section is changed)"
}

remove_menu_block() {
    [ -f "$MENU_PY" ] && grep -qF "$BLOCK_START" "$MENU_PY" || return 0
    mkdir -p "$BACKUPS"; cp "$MENU_PY" "$BACKUPS/menu.py.$RUN_ID"
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/comfynuke-menu.XXXXXX")"
    strip_menu_block | drop_trailing_blank_lines > "$tmp"; mv "$tmp" "$MENU_PY"
    add_change Delete "Nuke menu.py" "Removed the ComfyNuke section (original file backed up)"
}

install_launchers() {
    local wrote=0 f
    # Keep a copy of this tool inside the install folder so it works after the download is deleted
    if [ "$APP_DIR" != "$APP_COPY" ]; then
        mkdir -p "$APP_COPY"
        for f in install.sh model_sorter.py model_download.py versions.json README.md CHANGELOG.md; do [ -f "$APP_DIR/$f" ] && cp "$APP_DIR/$f" "$APP_COPY/"; done
        [ -d "$APP_DIR/assets" ] && cp -R "$APP_DIR/assets" "$APP_COPY/"
        [ -f "$APP_COPY/versions.json" ] || cp "$MANIFEST" "$APP_COPY/versions.json"
        # Started with `curl ... | bash`: there is no local install.sh to copy, fetch this version's
        [ -f "$APP_COPY/install.sh" ] || run curl -fsSL -o "$APP_COPY/install.sh" "https://raw.githubusercontent.com/$REPO_SLUG/v$APP_VERSION/install.sh"
        add_change Install "ComfyNuke tool" "$APP_VERSION → $APP_COPY"
    fi
    f="$ROOT/Start ComfyUI.command"
    if ! cmp -s <(start_command_text) "$f" 2>/dev/null; then
        start_command_text > "$f"
        chmod +x "$f"; wrote=1
    fi
    f="$ROOT/ComfyNuke.command"
    if [ ! -f "$f" ]; then
        printf '#!/bin/bash\nexec bash "$(dirname "$0")/app/install.sh" "$@"\n' > "$f"; chmod +x "$f"; wrote=1
    fi
    if [ ! -e "$HOME/Desktop/Start ComfyUI.command" ]; then
        ln -s "$ROOT/Start ComfyUI.command" "$HOME/Desktop/Start ComfyUI.command"; wrote=1
    fi
    [ $wrote = 1 ] && add_change Config Shortcuts "Desktop \"Start ComfyUI\", $ROOT/ComfyNuke.command"
    set_launcher_icons
    return 0
}

# Finder icons for the .command files: ComfyUI's logo (from the installed ComfyUI) and ComfyNuke's own.
# Best effort: a failure only means the default icon stays.
set_file_icon() {   # set_file_icon PNG FILE
    [ -f "$1" ] && [ -e "$2" ] || return 0
    osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) {
        var img = $.NSImage.alloc.initWithContentsOfFile(a[0]);
        return $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, a[1], 0); }' "$1" "$2" > /dev/null 2>&1
    return 0
}

set_launcher_icons() {
    local tool comfy
    tool="$APP_COPY/assets/comfynuke.png"
    if [ ! -f "$tool" ]; then
        mkdir -p "$APP_COPY/assets"
        curl -fsSL -o "$tool" "https://raw.githubusercontent.com/$REPO_SLUG/v$APP_VERSION/assets/comfynuke.png" 2>/dev/null || rm -f "$tool"
    fi
    comfy="$(find "$VENV/lib" -path '*comfyui_frontend_package/static/assets/images/comfy-icon-512.png' 2>/dev/null | head -1)"
    [ -n "$comfy" ] || comfy="$tool"
    set_file_icon "$comfy" "$ROOT/Start ComfyUI.command"
    set_file_icon "$tool" "$ROOT/ComfyNuke.command"
}

start_command_text() {
    cat <<EOF
#!/bin/bash
# Starts the ComfyUI server for Nuke. Keep this window open while working in Nuke.
# Ignore any other Python setup on this Mac (PYTHONHOME/PYTHONPATH would break ComfyUI's own Python)
unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONUSERBASE PYTHONEXECUTABLE VIRTUAL_ENV
export PYTHONNOUSERSITE=1
export OPENCV_IO_ENABLE_OPENEXR=1
export PYTORCH_ENABLE_MPS_FALLBACK=1   # run ops Apple GPUs lack on the CPU instead of failing
if [ ! -f "\$(dirname "\$0")/.install-complete" ]; then
    echo
    echo "The ComfyNuke install is not finished, so ComfyUI cannot start yet."
    echo "Open ComfyNuke and choose 1 \"Install / Repair\". If that keeps failing, choose 6 \"Doctor\"."
    echo
    read -r -p "Press Enter to close"
    exit 1
fi
cd "\$(dirname "\$0")/ComfyUI" || exit 1
# Moves models the browser downloads into ComfyUI/models; stops when this window closes
if [ -f ../app/model_sorter.py ]; then
    ./.venv/bin/python ../app/model_sorter.py --comfy "\$PWD" --log-dir "\$HOME/Library/Logs/ComfyNuke" &
    SORTER=\$!
    trap 'kill \$SORTER 2>/dev/null' EXIT
fi
./.venv/bin/python main.py --listen 127.0.0.1 --port $PORT "\$@"
echo; echo "ComfyUI has stopped. If this was unexpected, run ComfyNuke > Doctor."
read -r -p "Press Enter to close"
EOF
}

# Snapshot = everything needed to come back to this exact state
new_snapshot() {   # new_snapshot REASON
    [ -x "$PY" ] || return 0
    local id f k dir c base old
    id="$(date +%Y%m%d-%H%M%S)"; mkdir -p "$SNAPSHOTS"; f="$SNAPSHOTS/$id.env"
    {
        printf 'id=%s\nreason=%s\napp=%s\nmanifest=%s\npython=%s\ntorch_version=%s\n' \
            "$id" "$1" "$APP_VERSION" "$(mf manifestVersion)" "$(state_get python)" "$(state_get torch_version)"
        for k in $(repo_keys); do
            dir="$(repo_dir "$k")"; c="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
            [ -n "$c" ] && printf 'repo|%s|%s|%s\n' "$k" "$dir" "$c"
        done
        # Nodes the user added later (e.g. through ComfyUI-Manager) are recorded too
        for dir in "$COMFY"/custom_nodes/*/; do
            dir="${dir%/}"; [ -d "$dir/.git" ] || continue
            c="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
            [ -n "$c" ] && printf 'repo|custom_nodes/%s|%s|%s\n' "$(basename "$dir")" "$dir" "$c"
        done
    } > "$f.tmp"
    awk -F'|' '$1 != "repo" || !seen[$3]++' "$f.tmp" > "$f"; rm -f "$f.tmp"
    "$UV" pip freeze --python "$PY" > "$SNAPSHOTS/$id-pip.txt" 2>/dev/null
    [ -f "$MENU_PY" ] && cp "$MENU_PY" "$SNAPSHOTS/$id-menu.py"
    log OK "Created restore point $id ($1)"
    # Keep the newest 20 snapshots
    ls -1 "$SNAPSHOTS"/*.env 2>/dev/null | sort -r | tail -n +21 | while IFS= read -r old; do
        base="$(basename "$old" .env)"; rm -f "$SNAPSHOTS/$base"*
        add_change Delete "Old restore point" "$base (only the latest 20 are kept)"
    done
}

# --- preflight ---------------------------------------------------------------------------
PRE_ISSUES=""; PRE_WARNINGS=""
preflight() {
    local osv major free mem nukes n name nmajor ver plat min
    PRE_ISSUES=""; PRE_WARNINGS=""
    log STEP "Computer check"
    osv="$(sw_vers -productVersion 2>/dev/null)"; major="${osv%%.*}"
    if [ "$(uname -s)" != "Darwin" ]; then PRE_ISSUES="${PRE_ISSUES}This script only supports macOS (on Windows, use ComfyNuke.bat)\n"; fi
    if [ "$(uname -m)" != "arm64" ]; then PRE_ISSUES="${PRE_ISSUES}Needs a Mac with Apple Silicon (M1 or later): PyTorch no longer supports Intel Macs\n"; fi
    if [ -n "$major" ] && [ "$major" -lt "$(mf macos.minVersion | cut -d. -f1)" ]; then
        PRE_ISSUES="${PRE_ISSUES}macOS $osv is too old, macOS $(mf macos.minVersion) or newer is needed\n"
    fi
    mkdir -p "$(dirname "$ROOT")" 2>/dev/null
    free="$(df -g "$(dirname "$ROOT")" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$free" ] && [ "$free" -lt 25 ] && PRE_ISSUES="${PRE_ISSUES}Only ${free} GB of disk space left, at least 25 GB is needed (models are extra)\n"
    mem="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
    [ "$mem" -gt 0 ] && [ "$mem" -lt 16 ] && PRE_WARNINGS="${PRE_WARNINGS}Only ${mem} GB of memory, large models (SDXL/Flux/video) may not run\n"
    case "$ROOT" in *[!\ -~]*) PRE_WARNINGS="${PRE_WARNINGS}The install path has non-English or special characters, so some tools may fail. An English-only path is best\n" ;; esac
    curl -fsI --max-time 15 https://github.com > /dev/null 2>&1 || PRE_ISSUES="${PRE_ISSUES}Cannot reach github.com, please check your network\n"
    nukes="$(find_nuke)"; min="$(mf minNukeMajor)"
    if [ -z "$nukes" ]; then PRE_WARNINGS="${PRE_WARNINGS}Nuke not found (/Applications/Nuke*). You can still install; once Nuke is installed, run \"Install / Repair\" again\n"; fi

    log INFO "Mac: macOS $osv, $(uname -m), memory ${mem} GB"
    log INFO "PyTorch to be used: $(mf macos.torch.version) (Apple GPU / MPS)"
    while IFS='|' read -r name nmajor ver plat; do
        [ -n "$name" ] || continue
        log INFO "Nuke: $name (Python ${ver:-?}, $plat)"
        [ "$nmajor" -gt 0 ] && [ "$nmajor" -lt "$min" ] && PRE_WARNINGS="${PRE_WARNINGS}$name is too old, only Nuke $min or newer is supported\n"
    done <<EOF
$nukes
EOF
    log INFO "Install location: $ROOT (${free:-?} GB free)"
    # xcode-select, not `git --version`: on a Mac without the tools that pops up Apple's installer
    if xcode-select -p > /dev/null 2>&1; then n="yes"; else n="no (you will be asked to install Apple's Command Line Tools)"; fi
    log INFO "git: $n"
    [ -n "$CLEARED_ENV" ] && log DEBUG "Python-related settings found on this Mac and ignored by ComfyNuke:$CLEARED_ENV"
    printf '%b' "$PRE_WARNINGS" | while IFS= read -r n; do [ -n "$n" ] && log WARN "$n"; done
    printf '%b' "$PRE_ISSUES" | while IFS= read -r n; do [ -n "$n" ] && log ERROR "$n"; done
    return 0
}

# --- install health ------------------------------------------------------------------------
# Sync clients (Dropbox, OneDrive, Google Drive, iCloud) lock and upload files while they are being
# written; with tens of thousands of small Python files that leaves the install incomplete.
# Prints the provider's name and succeeds for a synced folder; fails for a normal local folder.
cloud_sync_provider() {   # cloud_sync_provider PATH
    local path="${1%/}/" seg dbx
    case "$path" in
        "$HOME/Library/CloudStorage/"*)
            seg="${path#"$HOME/Library/CloudStorage/"}"; seg="${seg%%/*}"
            case "$seg" in Dropbox*) echo Dropbox ;; OneDrive*) echo OneDrive ;; GoogleDrive*) echo "Google Drive" ;; Box*) echo Box ;; *) echo "$seg" ;; esac
            return 0 ;;
        "$HOME/Library/Mobile Documents/"*) echo "iCloud Drive"; return 0 ;;
    esac
    if [ -f "$HOME/.dropbox/info.json" ]; then
        for dbx in personal business; do
            seg="$(plutil -extract "$dbx.path" raw -o - "$HOME/.dropbox/info.json" 2>/dev/null)"
            if [ -n "$seg" ]; then
                case "$path" in "${seg%/}/"*) echo Dropbox; return 0 ;; esac
            fi
        done
    fi
    # Folder names the clients create, e.g. "Dropbox (Team)", "Company Dropbox", "OneDrive - Company"
    local IFS=/
    for seg in $path; do
        case "$seg" in
            Dropbox|"Dropbox ("*|*" Dropbox") echo Dropbox; return 0 ;;
            OneDrive|"OneDrive - "*) echo OneDrive; return 0 ;;
            "Google Drive"|GoogleDrive|"My Drive"|"Shared drives") echo "Google Drive"; return 0 ;;
            "iCloud Drive"|iCloudDrive) echo "iCloud Drive"; return 0 ;;
        esac
    done
    return 1
}

# Asks uv whether every requirements file is fully installed. Prints missing package names.
# Returns 0 when complete, 1 when something is missing, 2 when it could not check (e.g. offline).
package_health() {
    [ -x "$UV" ] && [ -x "$PY" ] || { echo "Python environment"; return 1; }
    local k req out missing="" code
    for k in $(repo_keys); do
        [ "$(mf "repos.$k.requirements")" = "true" ] || continue
        req="$(repo_dir "$k")/requirements.txt"
        [ -f "$req" ] || continue
        if [ -f "$CONSTRAIN" ]; then out="$("$UV" pip install --dry-run --python "$PY" -r "$req" --constraint "$CONSTRAIN" 2>&1)"; code=$?
        else out="$("$UV" pip install --dry-run --python "$PY" -r "$req" 2>&1)"; code=$?; fi
        [ $code -eq 0 ] || return 2
        echo "$out" | grep -q 'Would make no changes' && continue
        missing="$missing$(echo "$out" | sed -n 's/^ *+ *\([^ ]*\).*/\1/p')
"
    done
    missing="$(printf '%s' "$missing" | sed '/^$/d' | sort -u)"
    [ -z "$missing" ] && return 0
    echo "$missing"
    return 1
}

# The launcher refuses to start ComfyUI until this marker exists, so a half-finished install
# shows "run Install / Repair" instead of a Python traceback.
set_install_complete() {   # set_install_complete 0|1
    if [ "$1" != 1 ]; then rm -f "$COMPLETE"; return 0; fi
    local missing
    missing="$(package_health)"
    case $? in
        1) die "Some Python packages did not install: $(echo "$missing" | head -8 | paste -sd ',' -). Choose \"Install / Repair\" again; if it keeps failing, run \"Doctor\"." ;;
        2) log WARN "Could not double-check the Python packages (offline?); continuing." ;;
    esac
    printf 'Install verified by ComfyNuke %s on %s\n' "$APP_VERSION" "$(date +%Y-%m-%dT%H:%M:%S)" > "$COMPLETE"
}

# Shows the last error from the most recent install, update, rollback or download run
write_last_error() {
    local f n
    f="$(ls -1t "$LOG_DIR"/*-install.log "$LOG_DIR"/*-update.log "$LOG_DIR"/*-rollback.log "$LOG_DIR"/*-models.log 2>/dev/null | head -1)"
    [ -n "$f" ] || { log INFO "No install or update log found yet."; return 0; }
    n="$(grep -n '\[ERROR\]' "$f" | tail -1 | cut -d: -f1)"
    if [ -z "$n" ]; then log OK "The last run ($(basename "$f")) finished without errors."; return 0; fi
    log WARN "Last error, from $(basename "$f") (the lines just before it usually say why):"
    sed -n "$(( n > 8 ? n - 8 : 1 )),${n}p" "$f" | while IFS= read -r line; do
        printf '      %s%s%s\n' "$c_yellow" "$line" "$c_off"; printf '      %s\n' "$line" >> "$LOG_FILE"
    done
}

# --- commands -----------------------------------------------------------------------------
cmd_install() {
    local repair=0 k commit ref check
    if [ -z "$ROOT" ]; then
        ROOT="$(saved_root)"
        [ -z "$ROOT" ] && ROOT="$(ask_text "Where should it be installed? (Models are big, so an external SSD works well)" "$DEFAULT_ROOT")"
    fi
    ROOT="${ROOT/#\~/$HOME}"; ROOT="${ROOT%/}"
    local provider cloud_old=""
    while provider="$(cloud_sync_provider "$ROOT")"; do
        log WARN "$ROOT is inside $provider. $provider locks and uploads files while they are being written, which leaves the install incomplete, and it would upload many GB of models."
        [ "$YES" = 1 ] && die "Choose an install folder outside $provider"
        [ -z "$cloud_old" ] && cloud_old="$ROOT"
        ROOT="$(ask_text "Choose a local folder that is not synced" "$DEFAULT_ROOT")"
        ROOT="${ROOT/#\~/$HOME}"; ROOT="${ROOT%/}"
    done
    [ -n "$cloud_old" ] && [ "$(saved_root)" = "$cloud_old" ] && log WARN "Installing in $ROOT instead. Once it works, you can delete the old copy in $cloud_old."
    set_paths
    preflight
    [ -n "$PRE_ISSUES" ] && die "Please fix the problems shown in red above, then run it again"
    [ -f "$STATE" ] && repair=1

    log STEP "Plan"
    if [ $repair = 1 ]; then
        log INFO "Already installed: this run will \"repair\" it. It puts back anything that is missing and does not upgrade anything (to upgrade, use \"Check for updates\")"
    else
        log INFO "1. Make sure git is there (installs Apple Command Line Tools if not), then download a private uv and Python"
        log INFO "2. Install ComfyUI $(mf repos.comfyui.ref) and PyTorch (about 1 GB, takes 5–20 minutes)"
        log INFO "3. Install two ComfyUI nodes: VideoHelperSuite and HQ-Image-Save"
        log INFO "4. Install the Nuke plugin $(mf repos.comfyui2nuke.ref) into $NUKE_HOME and add a menu to menu.py"
        log INFO "5. Create \"Start ComfyUI\" on the Desktop"
        log INFO "First you are asked for a Hugging Face token (needed to download most models; you can skip it)."
    fi
    if [ "$DRY_RUN" = 1 ]; then log WARN "(DryRun: only showing the plan, nothing was changed)"; return; fi
    ask_yes_no "Ready to start?" y || return 0
    wait_for_closed_apps

    # Asked first, so the long part of the install can then run without anyone watching
    log STEP "Hugging Face sign-in"
    set_hf_signin

    mkdir -p "$ROOT" "$TOOLS" "$DATA_DIR"
    printf 'root=%s\n' "$ROOT" > "$CONFIG_FILE"
    set_install_complete 0
    [ $repair = 1 ] && new_snapshot "before repair"

    log STEP "Tools"
    ensure_git
    [ -x "$UV" ] || install_uv

    log STEP "Python environment"
    if [ ! -x "$PY" ]; then
        # ComfyUI must be cloned first: the venv lives inside its folder
        commit="$(state_get repo_comfyui_commit)"; ref="$(state_get repo_comfyui_ref)"
        [ -z "$commit" ] && { commit="$(mf repos.comfyui.commit)"; ref="$(mf repos.comfyui.ref)"; }
        [ -d "$COMFY/.git" ] || sync_repo comfyui "$commit" "$ref" skip-requirements
        install_python
    fi

    log STEP "PyTorch"
    if ! "$PY" -c 'import torch' > /dev/null 2>&1; then install_torch; else log DEBUG "torch is already installed"; fi

    log STEP "ComfyUI and nodes"
    for k in $(repo_keys); do
        # Repair keeps whatever version is installed; only a missing repo gets the tested pin
        commit="$(state_get "repo_${k}_commit")"; ref="$(state_get "repo_${k}_ref")"
        [ -z "$commit" ] && { commit="$(mf "repos.$k.commit")"; ref="$(mf "repos.$k.ref")"; }
        if ! sync_repo "$k" "$commit" "$ref"; then
            [ "$(mf "repos.$k.requirements")" = "true" ] && install_requirements "$(repo_dir "$k")" "$(mf "repos.$k.label")"
        fi
    done
    # The model downloader needs huggingface_hub; ComfyUI normally brings it, put it back if it is missing
    if ! "$PY" -c 'import huggingface_hub' > /dev/null 2>&1; then
        if [ -f "$CONSTRAIN" ]; then run "$UV" pip install --python "$PY" huggingface_hub --constraint "$CONSTRAIN"
        else run "$UV" pip install --python "$PY" huggingface_hub; fi
        add_change Install huggingface_hub "needed by \"Download missing models\""
    fi

    log STEP "Nuke connection"
    install_nuke_libs
    set_menu_block
    install_launchers
    [ -z "$(state_get manifest)" ] && state_set manifest "$(mf manifestVersion)"

    log STEP "Checks"
    write_compute_device
    check="$("$PY" -c 'import torch; print(torch.backends.mps.is_available())' 2>/dev/null)"
    case "$check" in *True) ;; *) log WARN "PyTorch cannot use the Apple GPU (MPS). Please run \"Doctor\" and send the zip it creates to the person who helped you install." ;; esac
    set_install_complete 1
    if [ $repair = 1 ]; then new_snapshot "after repair"; else new_snapshot "first install"; fi

    log STEP "All done! How to use it:"
    log INFO "1. Double-click \"Start ComfyUI\" on the Desktop (keep the Terminal window open)"
    log INFO "2. Open Nuke → the node menu now has ComfyUI → click \"Update all ComfyUI\" first"
    log INFO "3. Put models (checkpoints etc.) in: $COMFY/models"
}

# Newest upstream version: "ref commit" (highest version tag, or the branch head)
upstream_target() {   # upstream_target URL TRACK BRANCH
    if [ "$2" != "tag" ]; then
        git ls-remote "$1" "refs/heads/$3" 2>/dev/null | awk -v b="$3" 'NR==1 { print b, $1 }'
        return
    fi
    git ls-remote --tags "$1" 2>/dev/null | awk '
        { name = $2; sub("refs/tags/", "", name); peeled = sub(/\^\{\}$/, "", name)
          if (name !~ /^v?[0-9]+(\.[0-9]+)+$/) next
          if (peeled || !(name in sha)) sha[name] = $1 }
        END { for (n in sha) print n, sha[n] }' |
        awk '{ v = $1; sub(/^v/, "", v); split(v, p, "."); printf "%06d%06d%06d %s %s\n", p[1], p[2], p[3], $1, $2 }' |
        sort | tail -1 | awk '{ print $2, $3 }'
}

# Candidates are kept in parallel arrays (bash 3.2 has no associative arrays)
C_KEY=(); C_LABEL=(); C_FROM=(); C_TO=(); C_RISK=(); C_REF=(); C_COMMIT=(); C_TESTED=()
add_candidate() { local i=${#C_KEY[@]}; C_KEY[i]="$1"; C_LABEL[i]="$2"; C_FROM[i]="$3"; C_TO[i]="$4"; C_RISK[i]="$5"; C_REF[i]="$6"; C_COMMIT[i]="$7"; C_TESTED[i]="$8"; }

collect_candidates() {
    local have want k label from mref mcommit hc up uref ucommit libs ver plat key
    C_KEY=(); C_LABEL=(); C_FROM=(); C_TO=(); C_RISK=(); C_REF=(); C_COMMIT=(); C_TESTED=()
    have="$(state_get tool_uv)"; want="$(mf macos.uv.version)"
    [ "$have" != "$want" ] && add_candidate tool:uv uv "$have" "$want" "Low (just a tool)" "" "" 1
    have="$(state_get python)"; want="$(mf tools.python.version)"
    [ "$have" != "$want" ] && add_candidate python Python "$have" "$want" "Medium: rebuilds the Python environment (takes 5–20 minutes)" "" "" 1
    have="$(state_get torch_version)"; want="$(mf macos.torch.version)"
    [ "$have" != "$want" ] && add_candidate torch PyTorch "$have" "$want" "Medium: downloads about 1 GB" "" "" 1
    for k in $(repo_keys); do
        label="$(mf "repos.$k.label")"; mref="$(mf "repos.$k.ref")"; mcommit="$(mf "repos.$k.commit")"
        hc="$(state_get "repo_${k}_commit")"
        if [ -n "$hc" ]; then from="$(state_get "repo_${k}_ref") ${hc:0:8}"; else from="(not installed)"; fi
        [ "$hc" != "$mcommit" ] && add_candidate "repo:$k" "$label" "$from" "$mref ${mcommit:0:8}" "$(mf "repos.$k.risk")" "$mref" "$mcommit" 1
        if [ "$LATEST" = 1 ]; then
            up="$(upstream_target "$(mf "repos.$k.url")" "$(mf "repos.$k.track")" "$mref")"
            uref="${up%% *}"; ucommit="${up##* }"
            if [ -n "$up" ] && [ "$ucommit" != "$mcommit" ] && [ "$ucommit" != "$hc" ]; then
                add_candidate "repo:$k" "$label (latest, untested)" "$from" "$uref ${ucommit:0:8}" "Higher: $(mf "repos.$k.risk")" "$uref" "$ucommit" 0
            fi
        fi
    done
    libs="$(mf_list nukeLibs | paste -sd ',' -)"
    while IFS='|' read -r ver plat; do
        key="py${ver//./}"
        have="$(state_get "nukelibs_$key")"
        if [ -n "$have" ] && [ "${have%%|*}" != "$libs" ]; then
            add_candidate nukelibs "Nuke connection libraries" Old New Low "" "" 1; break
        fi
    done <<EOF
$(nuke_targets)
EOF
}

latest_app_release() {   # prints the path of the release JSON when a newer ComfyNuke exists
    local f tag; f="$(mktemp "${TMPDIR:-/tmp}/comfynuke-release.XXXXXX")"
    curl -fsSL --max-time 15 -H 'User-Agent: ComfyNuke' "https://api.github.com/repos/$REPO_SLUG/releases/latest" -o "$f" 2>/dev/null || { rm -f "$f"; return 1; }
    tag="$(plutil -extract tag_name raw -o - "$f" 2>/dev/null)"; tag="${tag#v}"
    if [ -n "$tag" ] && [ "$(printf '%s\n%s\n' "$APP_VERSION" "$tag" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$tag" ] && [ "$tag" != "$APP_VERSION" ]; then
        echo "$f"; return 0
    fi
    rm -f "$f"; return 1
}

cmd_self_update() {   # cmd_self_update [relaunch]
    use_installed_root
    local rel tag i name url digest tmp src
    if ! rel="$(latest_app_release)"; then log OK "The ComfyNuke tool is up to date ($APP_VERSION)"; return 0; fi
    tag="$(plutil -extract tag_name raw -o - "$rel")"
    i=0; url=""
    while name="$(plutil -extract "assets.$i.name" raw -o - "$rel" 2>/dev/null)"; do
        if [ "$name" = "ComfyNuke.zip" ]; then
            url="$(plutil -extract "assets.$i.browser_download_url" raw -o - "$rel")"
            digest="$(plutil -extract "assets.$i.digest" raw -o - "$rel" 2>/dev/null)"; break
        fi
        i=$((i + 1))
    done
    [ -n "$url" ] || { log WARN "The new version has no ComfyNuke.zip, skipping"; return 0; }
    log STEP "A new ComfyNuke version is available: $tag (you have $APP_VERSION)"
    log INFO "What is new: $(plutil -extract html_url raw -o - "$rel")"
    ask_yes_no "Update the ComfyNuke tool itself? (ComfyUI and Nuke are not touched)" y || return 0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/comfynuke.XXXXXX")"
    run curl -fL --retry 3 --silent --show-error -o "$tmp/ComfyNuke.zip" "$url"
    if [ -n "$digest" ] && [ "sha256:$(shasum -a 256 "$tmp/ComfyNuke.zip" | awk '{print $1}')" != "$digest" ]; then die "The downloaded file failed its check"; fi
    run ditto -x -k "$tmp/ComfyNuke.zip" "$tmp/x"
    src="$(dirname "$(find "$tmp/x" -name install.sh | head -1)")"
    [ -f "$src/install.sh" ] || die "The downloaded file is incomplete"
    if [ -d "$APP_COPY" ]; then
        mkdir -p "$BACKUPS/app-$APP_VERSION-$RUN_ID"; cp -R "$APP_COPY/." "$BACKUPS/app-$APP_VERSION-$RUN_ID/"
        add_change Backup "ComfyNuke tool" "backups/app-$APP_VERSION-$RUN_ID"
    fi
    mkdir -p "$APP_COPY"; cp -R "$src/." "$APP_COPY/"
    add_change Update "ComfyNuke tool" "$APP_VERSION → $tag"
    rm -rf "$tmp" "$rel"
    if [ "$1" = "relaunch" ]; then
        show_summary
        log STEP "Restarting with the new version..."
        exec bash "$APP_COPY/install.sh" update
    fi
}

cmd_update() {
    use_installed_root
    local i answer n picked="" k
    [ "$DRY_RUN" = 1 ] || cmd_self_update relaunch
    preflight
    collect_candidates
    log STEP "Available updates"
    if [ ${#C_KEY[@]} -eq 0 ]; then log OK "Everything is already at the tested versions, so nothing needs updating. (Add --latest to see the untested latest versions.)"; return; fi
    echo
    for ((i = 0; i < ${#C_KEY[@]}; i++)); do
        if [ "${C_TESTED[i]}" = 1 ]; then printf '    [%d] %s\n' $((i + 1)) "${C_LABEL[i]}"
        else printf '    %s[%d] %s%s\n' "$c_yellow" $((i + 1)) "${C_LABEL[i]}" "$c_off"; fi
        printf '        %s%s  →  %s    Risk: %s%s\n' "$c_gray" "${C_FROM[i]}" "${C_TO[i]}" "${C_RISK[i]}" "$c_off"
    done
    echo
    log WARN "Tip: if you have a Nuke project in progress, it is best not to update anything marked High risk yet. A restore point is created automatically before updating, so you can always roll back."
    if [ "$DRY_RUN" = 1 ]; then log WARN "(DryRun: nothing was changed)"; return; fi
    answer="$(ask_text "Enter the numbers to update (e.g. 1,3; all = everything tested; just press Enter = update nothing)" "")"
    [ -z "$answer" ] && { log OK "No updates selected"; return; }
    if [ "$answer" = "all" ]; then
        for ((i = 0; i < ${#C_KEY[@]}; i++)); do [ "${C_TESTED[i]}" = 1 ] && picked="$picked $i"; done
    else
        for n in $(echo "$answer" | tr ',' ' '); do
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#C_KEY[@]} ] && picked="$picked $((n - 1))"
        done
    fi
    [ -z "$picked" ] && { log WARN "No valid choice"; return; }
    # Tested versions are tested as a set: a newer ComfyUI may rely on the newer Python/PyTorch/tools next to it
    local deps="" has_repo=0
    for i in $picked; do case "${C_KEY[i]}" in repo:*) [ "${C_TESTED[i]}" = 1 ] && has_repo=1 ;; esac; done
    if [ $has_repo = 1 ]; then
        for ((i = 0; i < ${#C_KEY[@]}; i++)); do
            case "${C_KEY[i]}" in tool:*|python|torch) ;; *) continue ;; esac
            [ "${C_TESTED[i]}" = 1 ] || continue
            case " $picked " in *" $i "*) continue ;; esac
            picked="$picked $i"; deps="$deps${C_LABEL[i]}, "
        done
        [ -n "$deps" ] && log WARN "The tested new versions need to be updated together: ${deps%, } (added automatically)"
    fi
    log INFO "Will update: $(for i in $picked; do printf '%s, ' "${C_LABEL[i]}"; done | sed 's/, $//')"
    ask_yes_no "Are you sure?" y || return 0
    wait_for_closed_apps
    new_snapshot "before update"
    set_install_complete 0
    # Order matters: tools, then Python, then torch, then repos
    for k in tool: python torch repo: nukelibs; do
        for i in $picked; do
            case "${C_KEY[i]}" in "$k"*) ;; *) continue ;; esac
            log STEP "Updating ${C_LABEL[i]}"
            case "${C_KEY[i]}" in
                tool:uv) install_uv ;;
                python)
                    install_python; install_torch
                    for n in $(repo_keys); do
                        [ "$(mf "repos.$n.requirements")" = "true" ] && install_requirements "$(repo_dir "$n")" "$(mf "repos.$n.label")"
                    done ;;
                torch) install_torch ;;
                repo:*) sync_repo "${C_KEY[i]#repo:}" "${C_COMMIT[i]}" "${C_REF[i]}" ;;
                nukelibs) install_nuke_libs force ;;
            esac
        done
    done
    state_set manifest "$(mf manifestVersion)"
    set_install_complete 1
    new_snapshot "after update"
    run "$UV" cache prune   # drop downloads of versions no longer used
    for i in $picked; do case "${C_KEY[i]}" in python|torch) write_compute_device; break ;; esac; done
}

cmd_rollback() {
    use_installed_root
    local snaps i n f id reason comfy plug key dir commit line mref label
    snaps="$(ls -1 "$SNAPSHOTS"/*.env 2>/dev/null | sort -r)"
    [ -n "$snaps" ] || { log WARN "There are no restore points yet"; return; }
    log STEP "Restore points (newest first)"
    i=0
    while IFS= read -r f; do
        i=$((i + 1))
        reason="$(sed -n 's/^reason=//p' "$f")"
        comfy="$(awk -F'|' '$2 == "comfyui" { print substr($4, 1, 8) }' "$f")"
        plug="$(awk -F'|' '$2 == "comfyui2nuke" { print substr($4, 1, 8) }' "$f")"
        printf '    [%d] %s  %s   ComfyUI %s / Nuke plugin %s / torch %s\n' "$i" "$(basename "$f" .env)" "$reason" "${comfy:--}" "${plug:--}" "$(sed -n 's/^torch_version=//p' "$f")"
    done <<EOF
$snaps
EOF
    [ "$DRY_RUN" = 1 ] && return
    n="$(ask_text "Enter the number to restore (just press Enter = cancel)" "")"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || return 0
    f="$(echo "$snaps" | sed -n "${n}p")"; id="$(basename "$f" .env)"
    ask_yes_no "Restore to $id ($(sed -n 's/^reason=//p' "$f"))?" n || return 0
    wait_for_closed_apps
    new_snapshot "before restore"
    while IFS='|' read -r line key dir commit; do
        [ "$line" = "repo" ] || continue
        [ -d "$dir/.git" ] || { log WARN "$key no longer exists, skipping"; continue; }
        [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ] && continue
        [ -n "$(git -C "$dir" status --porcelain --ignore-submodules 2>/dev/null)" ] && run git -C "$dir" stash push --include-untracked -m "comfynuke-$RUN_ID"
        run git -C "$dir" fetch --tags --force origin
        run git -C "$dir" checkout --force --quiet "$commit"
        run git -C "$dir" submodule update --init --recursive --force
        label="$key"; mref="$(mf "repos.$key.commit")"
        if [ -n "$mref" ]; then
            label="$(mf "repos.$key.label")"
            if [ "$mref" = "$commit" ]; then state_set "repo_${key}_ref" "$(mf "repos.$key.ref")"; else state_set "repo_${key}_ref" snapshot; fi
            state_set "repo_${key}_commit" "$commit"
        fi
        add_change Restore "$label" "${commit:0:8}"
    done < "$f"
    if [ -f "$SNAPSHOTS/$id-pip.txt" ]; then
        run "$UV" pip sync --python "$PY" "$SNAPSHOTS/$id-pip.txt"
        grep -E '^(torch|torchvision|torchaudio)==' "$SNAPSHOTS/$id-pip.txt" > "$CONSTRAIN"
        state_set torch_version "$(sed -n 's/^torch_version=//p' "$f")"
        add_change Restore "Python packages" "same as $id"
        run "$UV" cache prune
    fi
    set_install_complete 1
}

cmd_status() {
    use_installed_root
    local k hc mark
    log STEP "ComfyNuke status"
    log INFO "Tool version: $APP_VERSION   Tested version list: $(mf manifestVersion) (installed: $(state_get manifest))"
    log INFO "Install location: $ROOT"
    log INFO "Python: $(state_get python)   PyTorch: $(state_get torch_version) mps"
    for k in $(repo_keys); do
        hc="$(state_get "repo_${k}_commit")"; mark=""
        [ "$hc" != "$(mf "repos.$k.commit")" ] && mark="  ← differs from the tested version"
        if [ -n "$hc" ]; then log INFO "$(mf "repos.$k.label"): $(state_get "repo_${k}_ref") (${hc:0:8})$mark"; else log INFO "$(mf "repos.$k.label"): not installed"; fi
    done
    log INFO "Nuke connection libraries: $(sed -n 's/^nukelibs_\([^=]*\)=.*/\1/p' "$STATE" | paste -sd ',' -)"
    if [ -f "$MENU_PY" ] && grep -qF "$BLOCK_START" "$MENU_PY"; then log INFO "menu.py setup: yes"; else log INFO "menu.py setup: no (please run \"Install / Repair\")"; fi
    if comfy_running; then log INFO "ComfyUI server: running (http://127.0.0.1:$PORT)"; else log INFO "ComfyUI server: not running"; fi
    local acct
    if acct="$(saved_hf_account)"; then
        IFS='|' read -r HF_NAME HF_TOKEN_NAME HF_CAN_WRITE <<EOF
$acct
EOF
        if [ "$HF_CAN_WRITE" = 1 ]; then log INFO "Hugging Face: signed in as $HF_NAME (token \"$HF_TOKEN_NAME\", can write: a Read-only token is safer)"
        else log INFO "Hugging Face: signed in as $HF_NAME (token \"$HF_TOKEN_NAME\", read-only)"; fi
    else
        log INFO "Hugging Face: not signed in (option 9)"
    fi
    write_comfy_device
    write_compute_device
}

cmd_start() {
    use_installed_root
    if comfy_running; then log OK "ComfyUI is already running: http://127.0.0.1:$PORT"; write_comfy_device; return; fi
    write_compute_device
    open -a Terminal "$ROOT/Start ComfyUI.command"
    log OK "Opened the ComfyUI window. The first start takes longer; when you see \"To see the GUI go to\", it is ready."
}

check_line() { if [ "$2" = 0 ]; then log OK "[OK] $1"; else log WARN "[X]  $1"; fi; }

cmd_doctor() {
    use_installed_root
    local b zip
    log STEP "Doctor"
    git --version > /dev/null 2>&1; check_line "git (Command Line Tools)" $?
    [ -x "$UV" ]; check_line uv $?
    [ -x "$PY" ]; check_line "Python environment" $?
    [ -f "$COMFY/main.py" ]; check_line ComfyUI $?
    [ -f "$NUKE_HOME/comfyui2nuke/__init__.py" ]; check_line "Nuke plugin" $?
    [ -n "$(ls -A "$NUKE_HOME/comfyui2nuke/nuke_util" 2>/dev/null)" ]; check_line "Nuke plugin submodule nuke_util" $?
    [ -f "$MENU_PY" ] && grep -qF "$BLOCK_START" "$MENU_PY"; check_line "menu.py setup" $?
    comfy_running; check_line "ComfyUI server running" $?
    [ -f "$COMPLETE" ]; check_line "Install finished and verified" $?
    local cloud missing
    if cloud="$(cloud_sync_provider "$ROOT")"; then
        log WARN "[X]  Install folder is inside $cloud: syncing breaks installs. Reinstall to a local folder (Install / Repair asks for one)."
    else
        log OK "[OK] Install folder is not cloud-synced"
    fi
    missing="$(package_health)"
    case $? in
        0) log OK "[OK] Python packages complete" ;;
        1) log WARN "[X]  Python packages missing: $(echo "$missing" | head -8 | paste -sd ',' -) (choose \"Install / Repair\")" ;;
        *) log WARN "[?]  Could not check the Python packages (offline?)" ;;
    esac
    write_last_error
    write_compute_device
    write_comfy_device
    # Where the disk space goes
    local label path
    while IFS='|' read -r label path; do
        [ -e "$path" ] && log INFO "Space: $label $(du -sh "$path" 2>/dev/null | awk '{print $1}')"
    done <<EOF
Models|$COMFY/models
uv download cache|$ROOT/tools/uv-cache
Python environment|$VENV
log|$LOG_DIR
EOF
    # Support bundle: logs and settings only (no models, images or projects)
    b="$(mktemp -d "${TMPDIR:-/tmp}/comfynuke-support.XXXXXX")/ComfyNuke-support-$RUN_ID"; mkdir -p "$b"
    ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -15 | while IFS= read -r f; do cp "$f" "$b/"; done
    for f in "$STATE" "$ROOT/history.log" "$MENU_PY"; do [ -f "$f" ] && cp "$f" "$b/"; done
    cp "$COMFY"/user/*.log "$b/" 2>/dev/null
    {
        echo "ComfyNuke $APP_VERSION / manifest $(mf manifestVersion)"
        echo "macOS $(sw_vers -productVersion) $(uname -m), RAM $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
        echo "Nuke: $(find_nuke | paste -sd ';' -)"
        echo "Free: $(df -g "$ROOT" | awk 'NR==2 {print $4}') GB"; echo "Root: $ROOT"; echo "NukeHome: $NUKE_HOME"
    } > "$b/system.txt"
    [ -x "$PY" ] && "$UV" pip freeze --python "$PY" > "$b/pip-freeze.txt" 2>/dev/null
    zip="$HOME/Desktop/ComfyNuke-support-$RUN_ID.zip"
    ditto -c -k --keepParent "$b" "$zip"; rm -rf "$(dirname "$b")"
    log OK "Created $(basename "$zip") on the Desktop. If something goes wrong, send it to the person who helped you install (it only has logs and settings, no images or projects)."
}

# Downloads a workflow's missing models with resume and fresh links (model_download.py does the work).
# Runs straight in this window so its questions and progress bars work.
# ---- Hugging Face sign-in ----------------------------------------------------------------
# The token is stored where every Hugging Face tool looks for it (~/.cache/huggingface/token, readable
# only by this user), never in an environment variable, a ComfyNuke file or a log.
hf_token_path() {
    if [ -n "${HF_TOKEN_PATH:-}" ]; then echo "$HF_TOKEN_PATH"; else echo "${HF_HOME:-$HOME/.cache/huggingface}/token"; fi
}

# Prints "name|token name|can write (1/0)" for a token, or fails when Hugging Face rejects it.
# The token goes to curl through a private temporary file, so it never appears in the process list.
hf_account() {
    local tmp hdr out name tname role write=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/comfynuke-hf.XXXXXX")"; chmod 700 "$tmp"
    hdr="$tmp/header"; out="$tmp/whoami.json"
    printf 'Authorization: Bearer %s\n' "$1" > "$hdr"
    if ! curl -fsS --max-time 20 -H "@$hdr" -o "$out" https://huggingface.co/api/whoami-v2 2>/dev/null; then rm -rf "$tmp"; return 1; fi
    name="$(plutil -extract name raw -o - "$out" 2>/dev/null)"
    tname="$(plutil -extract auth.accessToken.displayName raw -o - "$out" 2>/dev/null)"
    role="$(plutil -extract auth.accessToken.role raw -o - "$out" 2>/dev/null)"
    { [ "$role" = "write" ] || grep -q '\.write"' "$out"; } && write=1
    rm -rf "$tmp"
    [ -n "$name" ] || return 1
    printf '%s|%s|%s\n' "$name" "$tname" "$write"
}

saved_hf_account() {
    local f; f="$(hf_token_path)"
    [ -f "$f" ] || return 1
    hf_account "$(tr -d '[:space:]' < "$f")"
}

set_hf_signin() {   # set_hf_signin [change]
    local acct name tname write token path try=1
    if acct="$(saved_hf_account)" && [ "$1" != "change" ]; then
        IFS='|' read -r name tname write <<EOF
$acct
EOF
        log OK "Signed in to Hugging Face as $name (token \"$tname\")"
        [ "$write" = 1 ] && log WARN "This token can also change things on that Hugging Face account. A Read-only token is safer (menu option 9 replaces it)."
        return 0
    fi
    [ -f "$(hf_token_path)" ] && [ -z "$acct" ] && [ "$1" != "change" ] && log WARN "The saved Hugging Face sign-in no longer works; please sign in again."
    log INFO "Most models download from Hugging Face, which needs a free account and an access token:"
    log INFO "  1. Sign in at https://huggingface.co and open Settings > Access Tokens > Create new token."
    log INFO "  2. Choose \"Fine-grained\" with the \"Read-Only\" preset, name it (e.g. comfynuke) and create it."
    log INFO "  3. Copy the token (it starts with hf_) and paste it below. Nothing shows while you paste; then press Enter."
    if [ "$YES" = 1 ]; then log WARN "Skipped (--yes). Option 9 signs in later."; return 0; fi
    while [ $try -le 3 ]; do
        try=$((try + 1))
        printf '    Hugging Face token (or just Enter to skip for now): ' > /dev/tty
        IFS= read -rs token < /dev/tty; printf '\n' > /dev/tty
        token="$(printf '%s' "$token" | tr -d '[:space:]')"
        if [ -z "$token" ]; then log WARN "Skipped. You can sign in later with option 9, or when \"Download missing models\" asks."; return 0; fi
        if ! acct="$(hf_account "$token")"; then log WARN "Hugging Face did not accept that token. Check that you copied all of it, then paste it again."; continue; fi
        IFS='|' read -r name tname write <<EOF
$acct
EOF
        if [ "$write" = 1 ] && ! ask_yes_no "This token can also change or delete things on your Hugging Face account. A Read-only token is safer. Use it anyway?" n; then continue; fi
        path="$(hf_token_path)"
        mkdir -p "$(dirname "$path")"
        ( umask 077; printf '%s' "$token" > "$path" )
        add_change Config "Hugging Face sign-in" "$name, token \"$tname\" (saved in $path)"
        return 0
    done
    log WARN "Not signed in. You can try again later with option 9."
}

cmd_hf_login() { set_hf_signin change; }

cmd_models() {
    use_installed_root
    local script="$APP_COPY/model_download.py"
    [ -x "$PY" ] || die "ComfyUI is not installed yet. Choose \"Install / Repair\" first."
    [ -f "$script" ] || script="$APP_DIR/model_download.py"
    [ -f "$script" ] || die "model_download.py is missing. Choose \"Install / Repair\" to put it back."
    log DEBUG "Starting the model downloader ($script)"
    "$PY" "$script" --comfy "$COMFY" --log-dir "$LOG_DIR" < /dev/tty
    log DEBUG "Model downloader finished (exit code $?); details in the *-model-download.log file"
}

cmd_uninstall() {
    use_installed_root
    local bak d
    log STEP "Uninstall"
    log INFO "Will do: remove the ComfyUI menu and plugin from Nuke (moved to a backup folder) and delete the Desktop shortcut."
    log INFO "Will not do: delete $ROOT (it holds your models; delete it yourself once you are sure you do not need them)."
    [ "$DRY_RUN" = 1 ] && return
    ask_yes_no "Are you sure you want to uninstall?" n || return 0
    wait_for_closed_apps
    remove_menu_block
    bak="$BACKUPS/uninstalled-$RUN_ID"
    for d in "$NUKE_HOME/comfyui2nuke" "$NUKE_LIBS"; do
        if [ -e "$d" ]; then mkdir -p "$bak"; mv "$d" "$bak/"; add_change Delete "$(basename "$d")" "Moved from .nuke to $bak"; fi
    done
    if [ -L "$HOME/Desktop/Start ComfyUI.command" ]; then rm -f "$HOME/Desktop/Start ComfyUI.command"; add_change Delete Shortcut "Desktop \"Start ComfyUI\""; fi
    rm -f "$STATE"; add_change Delete state.env "Install record (recreated on the next install)"
    log WARN "To remove everything, delete $ROOT and $DATA_DIR by hand"
}

show_help() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

start_action() {
    log DEBUG "ComfyNuke $APP_VERSION  $1  (manifest $(mf manifestVersion))"
    log DEBUG "macOS $(sw_vers -productVersion 2>/dev/null); $(sysctl -n machdep.cpu.brand_string 2>/dev/null); memory $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
    remove_old_logs
    case "$1" in
        install) cmd_install ;;
        update) cmd_update ;;
        status) cmd_status ;;
        start) cmd_start ;;
        rollback) cmd_rollback ;;
        doctor) cmd_doctor ;;
        uninstall) cmd_uninstall ;;
        models) cmd_models ;;
        hf-login) cmd_hf_login ;;
        self-update) cmd_self_update ;;
        help) show_help ;;
    esac
    case "$1" in install|update|rollback|uninstall|self-update|hf-login) show_summary ;; *) printf '    %slog: %s%s\n' "$c_gray" "$LOG_FILE" "$c_off" ;; esac
}

show_menu() {
    local c saved
    while true; do
        saved="$(saved_root)"
        printf '\n  %sComfyNuke %s — ComfyUI for Nuke%s\n' "$c_cyan" "$APP_VERSION" "$c_off"
        if [ -n "$saved" ]; then printf '  %sInstalled at %s%s\n\n' "$c_gray" "$saved" "$c_off"; else printf '  %sNot installed yet%s\n\n' "$c_gray" "$c_off"; fi
        printf '   1  Install / Repair\n   2  Check for updates (you choose what to update)\n   3  Start ComfyUI\n   4  Status\n'
        printf '   5  Roll back to an earlier version\n   6  Doctor (creates a zip on the Desktop when something is wrong)\n   7  Uninstall\n   8  Download missing models (for a workflow; resumes if interrupted)\n   9  Sign in to Hugging Face (or change the saved token)\n   0  Exit\n'
        printf '  Choose '; read -r c < /dev/tty
        case "$c" in
            1) COMMAND=install ;; 2) COMMAND=update ;; 3) COMMAND=start ;; 4) COMMAND=status ;;
            5) COMMAND=rollback ;; 6) COMMAND=doctor ;; 7) COMMAND=uninstall ;; 8) COMMAND=models ;; 9) COMMAND=hf-login ;;
            0|"") break ;; *) continue ;;
        esac
        LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$COMMAND.log"
        start_action "$COMMAND"
        printf '  Press Enter to return to the menu '; read -r _ < /dev/tty
    done
}

# --- entry point -----------------------------------------------------------------------------
trap 'rm -f "$CHANGES_FILE"' EXIT
if [ "$COMMAND" = "menu" ]; then show_menu; else start_action "$COMMAND"; fi
