# shellcheck shell=bash disable=SC2034  # variables here are read by the installer
# Test doubles loaded by tests/lib/panel.sh AFTER the installer: dialogs are
# recorded instead of drawn, answers come from a queue, and a few system
# probes can be steered from the tests. Everything else (mysql, mysqldump,
# gzip, flock, the restore logic itself) is the real thing.
KEI_S=/run/kei-mock
mkdir -p "$KEI_S"

# ---- dialogs ---------------------------------------------------------
_kei_dialog() { printf '%s\n' "$*" >> "$KEI_S/dialogs.log"; }
whiptail()       { _kei_dialog "whiptail $*"; return 0; }
msg_info()       { _kei_dialog "INFO [$1] $2"; }
msg_ok()         { _kei_dialog "OK $1"; }
msg_error()      { _kei_dialog "ERROR [$1] $2"; }
clear()          { :; }
pause_terminal() { :; }
show_validation_report()     { :; }
show_restore_transfer_help() { :; }
validate_complete_system()   { _kei_dialog "VALIDATE $*"; V_FAIL=0; V_WARN=0; V_OK=1; return 0; }

# Yes/no answers are read from $KEI_S/answers, one per line ("yes"/"no");
# when the queue is empty the answer is ${KEI_DEFAULT_ANSWER:-yes}.
prompt_yes_no() {
    local ans=""
    if [ -s "$KEI_S/answers" ]; then
        ans=$(head -n1 "$KEI_S/answers")
        sed -i '1d' "$KEI_S/answers"
    fi
    ans="${ans:-${KEI_DEFAULT_ANSWER:-yes}}"
    _kei_dialog "PROMPT [$1] $2 => $ans"
    [ "$ans" = "yes" ]
}
select_file()      { printf '%s' "${KEI_SELECT_FILE:-}"; [ -n "${KEI_SELECT_FILE:-}" ]; }
select_directory() { printf '%s' "${KEI_SELECT_DIR:-}";  [ -n "${KEI_SELECT_DIR:-}" ]; }

# ---- packages and platform --------------------------------------------
apt_install()        { printf 'apt_install %s\n' "$*" >> "$KEI_S/calls.log"; return 0; }
apt_update_indices() { return 0; }
wait_for_apt_locks() { return 0; }

# "dpkg -s PKG" succeeds when $KEI_S/pkgs/PKG exists; the architecture comes
# from $KEI_ARCH. Everything else goes to the real dpkg.
dpkg() {
    case "${1:-}" in
        -s) [ -e "$KEI_S/pkgs/${2:-}" ] ;;
        --print-architecture) printf '%s\n' "${KEI_ARCH:-amd64}" ;;
        *) command dpkg "$@" ;;
    esac
}
uname() {
    if [ "${1:-}" = "-m" ] && [ -n "${KEI_MACHINE:-}" ]; then printf '%s\n' "$KEI_MACHINE"; else command uname "$@"; fi
}

# Shorter waits keep the "MariaDB is down" scenarios fast.
DB_WAIT_SECONDS="${KEI_DB_WAIT_SECONDS:-2}"
