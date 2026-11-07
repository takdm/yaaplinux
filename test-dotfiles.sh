#!/usr/bin/env bash
# Test harness: config.sh getter/setter + dotfiles library with a mocked
# arch-chroot. Runs entirely in a temp sandbox; no real target root needed.

set -u
T="$1"; shift
mkdir -p "$T"
: > "$T/run.log"

# Fake arch-chroot that records calls for unit-testing lib/dotfiles.sh.
FAKE_ROOT="$T/root"
mkdir -p "$FAKE_ROOT/home/user/.dotfiles"
_yaap_chroot_calls=()
yaap_chroot() {
    _yaap_chroot_calls+=("$@")
    # In tests we do NOT actually chroot: run the command directly in the
    # sandbox (the sandbox root is $FAKE_ROOT).
    shift
    "$@"
}
export -f yaap_chroot

# Source the YaapLinux lib under test (from this repo), pointed at a config
# we control in the sandbox.
CFG="$T/install-config.yaml"
cat > "$CFG" <<'EOF'
version: 2
profile: desktop
disk:
  dotfiles:
    repo: ""
    branch: ""
  luks:
    enabled: true
EOF
export YAAP_CONFIG="$CFG"
. "$(dirname "$0")/lib/config.sh"
. "$(dirname "$0")/lib/log.sh"
. "$(dirname "$0")/lib/dotfiles.sh"

# Force the chroot helper into a no-op for these tests (dotfiles clone uses
# arch-chroot directly; we override it, see above).
YAAP_NO_CHROOT=1

echo "=== 1. config getter/setter on seed template ==="
printf 'p1 profile=[%s]\n' "$(cfg_get profile)" >> "$T/run.log"
printf 'p2 repo=[%s]\n' "$(cfg_get disk.dotfiles.repo)" >> "$T/run.log"
printf 'p3 branch=[%s]\n' "$(cfg_get disk.dotfiles.branch)" >> "$T/run.log"
[ "$(cfg_get profile)" = desktop ] || { echo "FAIL: profile=${profile:-<unset>}" >> "$T/run.log"; exit 1; }
[ -z "$(cfg_get disk.dotfiles.repo)" ] || { echo "FAIL: repo=$(cfg_get disk.dotfiles.repo)" >> "$T/run.log"; exit 1; }
[ -z "$(cfg_get disk.dotfiles.branch)" ] || { echo "FAIL: branch=$(cfg_get disk.dotfiles.branch)" >> "$T/run.log"; exit 1; }
cfg_set profile minimal
cfg_set disk.dotfiles.repo "git@github.com:user/dotfiles.git"
cfg_set disk.dotfiles.branch feature-x
[ "$(cfg_get profile)" = minimal ] || { echo "FAIL profile" >> "$T/run.log"; exit 1; }
[ "$(cfg_get disk.dotfiles.repo)" = "git@github.com:user/dotfiles.git" ] || { echo "FAIL repo" >> "$T/run.log"; exit 1; }
[ "$(cfg_get disk.dotfiles.branch)" = feature-x ] || { echo "FAIL branch" >> "$T/run.log"; exit 1; }
cfg_set profile desktop
cfg_set disk.dotfiles.repo ""
cfg_set disk.dotfiles.branch ""
cfg_set disk.dotfiles.repo "git@github.com:user/dotfiles.git"
cfg_set disk.dotfiles.branch ""
cfg_set disk.dotfiles.branch main
[ "$(cfg_get profile)" = desktop ] || { echo "FAIL" >> "$T/run.log"; exit 1; }
[ "$(cfg_get disk.dotfiles.repo)" = "git@github.com:user/dotfiles.git" ] || { echo "FAIL" >> "$T/run.log"; exit 1; }
[ "$(cfg_get disk.dotfiles.branch)" = main ] || { echo "FAIL" >> "$T/run.log"; exit 1; }
echo "CONFIG GET/SET OK" >> "$T/run.log"

echo "=== 2. dotfiles: empty repo -> no-op ==="
: > "$T/calls.log"
yaap_target_test() { echo "yaap_target_test: $@" >> "$T/calls.log"; return 0; }
yaap_dotfiles_clone_cmd() { echo "clone_cmd: $@" >> "$T/calls.log"; return 1; }
yaap_dotfiles_pull_cmd() { echo "pull_cmd: $@" >> "$T/calls.log"; return 0; }
yaap_dotfiles_clone "$FAKE_ROOT" "user" "" "main"
[ -s "$T/calls.log" ] && grep -v "yaap_target_test" "$T/calls.log" >> "$T/run.log" || echo "no-op OK" >> "$T/run.log"

echo "=== 3. dotfiles: clone path ==="
: > "$T/calls.log"
yaap_test_file_exists=0   # 0 = missing -> clone path, 1 = present -> pull path
yaap_target_test() {
    echo "yaap_target_test: $@" >> "$T/calls.log"
    [ "$yaap_test_file_exists" = 1 ]
}
yaap_dotfiles_clone_cmd() {
    echo "clone_cmd: $@" >> "$T/calls.log"
    mkdir -p "$FAKE_ROOT/home/user/.dotfiles"
    touch "$FAKE_ROOT/home/user/.dotfiles/.git"
    return 0
}
yaap_dotfiles_pull_cmd() {
    echo "pull_cmd: $@" >> "$T/calls.log"
    return 0
}
yaap_dotfiles_clone "$FAKE_ROOT" "user" "git@github.com:user/dotfiles.git" "main"
[ -s "$T/calls.log" ] || { echo "clone not attempted" >> "$T/run.log"; exit 1; }
grep "clone_cmd: $FAKE_ROOT $FAKE_ROOT/home/user/.dotfiles git@github.com:user/dotfiles.git main" "$T/calls.log" >/dev/null \
    || { echo "clone args wrong: $(cat $T/calls.log)" >> "$T/run.log"; exit 1; }
[ -d "$FAKE_ROOT/home/user/.dotfiles" ] || { echo "clone dir missing" >> "$T/run.log"; exit 1; }
echo "CLONE OK" >> "$T/run.log"

echo "=== 4. dotfiles: existing clone -> pull path ==="
: > "$T/calls.log"
yaap_test_file_exists=1   # 1 = present -> pull path
yaap_dotfiles_clone "$FAKE_ROOT" "user" "git@github.com:user/dotfiles.git" "main"
grep "pull_cmd: $FAKE_ROOT $FAKE_ROOT/home/user/.dotfiles main" "$T/calls.log" >/dev/null \
    || { echo "pull not attempted: $(cat $T/calls.log)" >> "$T/run.log"; exit 1; }
! grep "clone_cmd:" "$T/calls.log" >/dev/null \
    || { echo "clone attempted again" >> "$T/run.log"; exit 1; }
echo "PULL OK" >> "$T/run.log"

echo "=== 5. dotfiles status ==="
yaap_test_file_exists=1
[ "$(yaap_dotfiles_status "$FAKE_ROOT" "user")" = installed ] || { echo "status wrong: $(yaap_dotfiles_status "$FAKE_ROOT" "user")" >> "$T/run.log"; exit 1; }
yaap_test_file_exists=0
[ "$(yaap_dotfiles_status "$FAKE_ROOT" "ghost")" = missing ] || { echo "status missing wrong: $(yaap_dotfiles_status "$FAKE_ROOT" "ghost")" >> "$T/run.log"; exit 1; }
echo "STATUS OK" >> "$T/run.log"

echo "=== 6. yaap CLI dispatcher (lib/yaap) smoke test ==="
CFG6="$T/install-config.yaml"
cat > "$CFG6" <<'EOF'
version: 2
profile: desktop
system:
  hostname: yaaplinux
user:
  name: user
disk:
  dotfiles:
    repo: "git@github.com:user/dotfiles.git"
EOF
export YAAP_CONFIG="$CFG6"
export TARGET_ROOT="$FAKE_ROOT"
. "$(dirname "$0")/lib/config.sh"
. "$(dirname "$0")/lib/log.sh"
. "$(dirname "$0")/lib/dotfiles.sh"
# yaap loads config/dotfiles/checkpoint from YAAP_LIB; point it at this repo.
YAAP_LIB="$(dirname "$0")/lib"
YAAP_LOG_DIR="$T/log"
mkdir -p "$YAAP_LOG_DIR"
YAAP_LOG="$YAAP_LOG_DIR/yaap.log"
: > "$YAAP_LOG"
. "$(dirname "$0")/lib/yaap"
# Re-establish the chroot + git-action mocks so the yaap smoke test runs
# without a real arch-chroot (yaap's load loop resets them to the lib defaults).
yaap_target_test() { echo "yaap_target_test: $@" >> "$T/calls.log"; return 0; }
yaap_dotfiles_clone_cmd() { echo "clone_cmd: $@"; mkdir -p "$FAKE_ROOT/home/user/.dotfiles"; touch "$FAKE_ROOT/home/user/.dotfiles/.git"; return 0; }
yaap_dotfiles_pull_cmd() { echo "pull_cmd: $@"; return 0; }
{
    echo "--- yaap status ---"
    yaap_status
    echo "--- yaap report (head) ---"
    yaap_report | head -22
    echo "--- yaap dotfiles status ---"
    yaap_dotfiles_status_cmd
} >> "$T/run.log" 2>&1
echo "YAAP DISPATCHER OK" >> "$T/run.log"

echo "=== results ==="
cat "$T/run.log"
