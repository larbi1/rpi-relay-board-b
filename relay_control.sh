#!/bin/bash
###################################################################
##   Waveshare RPi Relay Board (B) — Controller v1.6.0           ##
##   Raspberry Pi 5 · libgpiod v2.x / v1.x                      ##
###################################################################
##  Board:    Waveshare RPi Relay Board (B)  — 8 channels        ##
##  Pins:     CH1=BCM5   CH2=BCM6   CH3=BCM13  CH4=BCM16        ##
##            CH5=BCM19  CH6=BCM20  CH7=BCM21  CH8=BCM26        ##
##  Logic:    Active-low  (GPIO 0 = relay ON, GPIO 1 = OFF)       ##
##  Requires: gpiod package  (sudo apt install gpiod)             ##
###################################################################

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
readonly VERSION="1.6.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly STATE_DIR="/tmp/relay_board_b"
readonly LOG_FILE="/tmp/relay_board_b.log"
readonly MAX_LOG_KB=2048

# Waveshare RPi Relay Board (B) BCM pin mapping (index 0 unused)
# Source: RPi_Relay_Board_(B)_User_Manual_EN.pdf, Interface table
readonly -a CH_PINS=(0 5 6 13 16 19 20 21 26)   # CH1-CH8
readonly -a CHANNELS=(1 2 3 4 5 6 7 8)

# Active-low logic: 0 = relay ON (energized), 1 = relay OFF (released)
readonly GPIO_ON=0
readonly GPIO_OFF=1

# ── Colors ($'...' = real ESC byte; single-quote '\033' is a literal string) ──
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m'      DIM=$'\033[2m'  RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ── Logging ──────────────────────────────────────────────────────
_log() {
    if [[ -f "$LOG_FILE" ]] && (( $(du -k "$LOG_FILE" 2>/dev/null | cut -f1) >= MAX_LOG_KB )); then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}
info()  { echo -e "${GREEN}[INFO]${RESET}  $*";  _log INFO  "$*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; _log WARN  "$*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; _log ERROR "$*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*";  _log OK    "$*"; }
die()   { error "$*"; exit 1; }

# ── Dependency check ─────────────────────────────────────────────
check_deps() {
    local missing=() dep
    for dep in gpioset gpioget gpiodetect; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    (( ${#missing[@]} == 0 )) || die "Missing: ${missing[*]}. Run: sudo apt install gpiod"
}

# ── libgpiod version + hold mechanism ────────────────────────────
#
# CRITICAL API BREAK between libgpiod v1.x and v2.x:
#
#   v1.x: chip is a POSITIONAL argument:
#         gpioset gpiochip0 26=0
#
#   v2.x: chip requires the --chip / -c FLAG:
#         gpioset --chip gpiochip0 26=0
#
# Without --chip in v2.x, 'gpiochip0' is parsed as an invalid line
# value — prints error to stderr but may still exit 0 (fork happened
# before validation in the daemonized child). set -e cannot catch it.
#
# Hold mechanism differences:
#   v1.x: --mode=signal   runs in foreground until SIGTERM
#   v2.x: --daemonize     forks; child holds GPIO until killed
#
# NOTE: pgrep -x / pkill -x cannot find daemonized gpioset on RPi OS
# (process moves to a new session after setsid; pgrep's -x match
# fails against the daemonized process name). We use 'ps ax' + awk
# with pin-specific matching instead — confirmed reliable via ps aux.

GPIOD_MAJOR=1
GPIOD_V2_HOLD=""   # "daemonize" | "interactive"

detect_gpiod_version() {
    local ver
    ver=$(gpioset --version 2>&1 | grep -oP 'v\K\d+' | head -1 || echo "1")
    GPIOD_MAJOR=${ver:-1}

    if (( GPIOD_MAJOR >= 2 )); then
        local help_text
        help_text=$(gpioset --help 2>&1 || true)
        if grep -qE '\-\-interactive|-i,' <<< "$help_text"; then
            GPIOD_V2_HOLD="interactive"
        elif grep -qE '\-\-daemonize|-z,' <<< "$help_text"; then
            GPIOD_V2_HOLD="daemonize"
        else
            die "libgpiod v${GPIOD_MAJOR}: gpioset has neither --interactive nor --daemonize.
       Cannot hold GPIO lines persistently. Try: sudo apt install --reinstall gpiod"
        fi
    fi
    _log INFO "libgpiod v${GPIOD_MAJOR}  hold=${GPIOD_V2_HOLD:-signal(v1)}"
}

# ── GPIO chip detection (RPi 5 aware) ────────────────────────────
GPIO_CHIP=""

detect_gpio_chip() {
    local detect_out
    detect_out=$(gpiodetect 2>/dev/null) || die "gpiodetect failed — is gpiod installed?"

    # Primary: label match for RPi 5 RP1 chip
    GPIO_CHIP=$(grep -oP '^gpiochip\d+(?=.*(?:rp1-gpio|pinctrl-rp1))' <<< "$detect_out" | head -1 || true)

    # Fallback: chip with the most GPIO lines (need >= 27 for BCM 26)
    if [[ -z "$GPIO_CHIP" ]]; then
        local best_chip="" best_count=0 chip num_lines
        while IFS= read -r line; do
            chip=$(grep -oP '^gpiochip\d+' <<< "$line" || true)
            num_lines=$(grep -oP '\(\K\d+(?= lines\))' <<< "$line" || echo "0")
            [[ -z "$chip" ]] && continue
            (( num_lines > best_count )) && { best_count=$num_lines; best_chip=$chip; }
        done <<< "$detect_out"
        [[ -n "$best_chip" ]] && GPIO_CHIP="$best_chip"
    fi

    [[ -n "$GPIO_CHIP" ]] || {
        error "No GPIO chip found. Available:"
        echo "$detect_out" >&2
        die "Connect the board and verify: gpiodetect"
    }
    _log INFO "GPIO chip: $GPIO_CHIP"
}

# ── gpioset / gpioget wrappers (handles v1/v2 chip argument) ─────
_gpioset() {
    if (( GPIOD_MAJOR >= 2 )); then
        gpioset --chip "$GPIO_CHIP" "$@"
    else
        gpioset "$GPIO_CHIP" "$@"
    fi
}

_gpioget() {
    if (( GPIOD_MAJOR >= 2 )); then
        gpioget --chip "$GPIO_CHIP" "$@"
    else
        gpioget "$GPIO_CHIP" "$@"
    fi
}

# ── Process finder (ps-based; pgrep -x fails on daemonized gpioset) ──
#
# After gpioset --daemonize, the child calls setsid() and moves to a
# new session. pgrep -x / pkill -x cannot see it on RPi OS (confirmed).
# ps ax searches all processes regardless of session — reliable.
# The daemon's argv shows the pin as "26 0" (= replaced with space),
# so we match on " ${pin}" (space-prefix avoids partial matches like 260).

_find_gpioset_pid() {
    local pin=$1
    # grep -w matches pin as a whole word — avoids false matches on PIDs that
    # start with the same digits (e.g. searching for pin 6 must not hit PID 6175).
    ps ax -o pid,args 2>/dev/null \
        | grep "gpioset" \
        | grep -v grep \
        | grep -w "$pin" \
        | awk '{print $1; exit}' \
        || true
}

# ── PID / state / FIFO file helpers ──────────────────────────────
_pidfile()   { echo "${STATE_DIR}/ch${1}.pid"; }
_fifofile()  { echo "${STATE_DIR}/ch${1}.fifo"; }
_statefile() { echo "${STATE_DIR}/ch${1}.state"; }

_save_state() { echo "$2" > "$(_statefile "$1")"; }
_read_state() {
    local sf; sf=$(_statefile "$1")
    [[ -f "$sf" ]] && cat "$sf" || echo "unknown"
}

# ── GPIO daemon lifecycle ─────────────────────────────────────────
_gpio_release() {
    local ch=$1
    local pin=${CH_PINS[$ch]}
    local pf; pf=$(_pidfile "$ch")
    local ff; ff=$(_fifofile "$ch")

    # Kill via saved PID file
    if [[ -f "$pf" ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done < "$pf"
        rm -f "$pf"
    fi

    # Kill any stray gpioset holding this pin (handles stale PID files
    # and daemonized processes that pgrep can't see but ps can)
    local stray; stray=$(_find_gpioset_pid "$pin")
    [[ -n "$stray" ]] && kill "$stray" 2>/dev/null || true

    [[ -p "$ff" ]] && rm -f "$ff" || true
    sleep 0.05   # brief pause so kernel can release the line
}

_gpio_set() {
    local ch=$1 value=$2
    local pin=${CH_PINS[$ch]}
    local pf; pf=$(_pidfile "$ch")
    local ff; ff=$(_fifofile "$ch")

    # Idempotency: skip restart if daemon is alive and state already matches
    local target_state; target_state=$([[ "$value" -eq "$GPIO_ON" ]] && echo "on" || echo "off")
    local current_state; current_state=$(_read_state "$ch")
    if [[ "$current_state" == "$target_state" ]]; then
        local existing_pid; existing_pid=$(_find_gpioset_pid "$pin")
        if [[ -n "$existing_pid" ]]; then
            _log INFO "CH${ch} already ${target_state} (PID ${existing_pid}), no restart needed"
            return 0
        fi
    fi

    _gpio_release "$ch"

    local err_tmp; err_tmp=$(mktemp)

    if (( GPIOD_MAJOR >= 2 )); then
        case "$GPIOD_V2_HOLD" in
            daemonize)
                # --daemonize: parent forks and exits 0; child holds the GPIO line
                # until killed. Check stderr for immediate failures. Use ps-based
                # PID discovery (pgrep -x cannot find daemonized processes on RPi OS).
                _gpioset --daemonize "${pin}=${value}" 2>"$err_tmp" || true

                if [[ -s "$err_tmp" ]]; then
                    error "gpioset failed: $(cat "$err_tmp")"
                    rm -f "$err_tmp"
                    return 1
                fi

                sleep 0.25   # allow daemon to fully start and open the GPIO line
                local daemon_pid; daemon_pid=$(_find_gpioset_pid "$pin")

                if [[ -n "$daemon_pid" ]]; then
                    echo "$daemon_pid" > "$pf"
                else
                    error "gpioset --daemonize started but daemon not visible in ps."
                    error "Check: ps aux | grep gpioset"
                    error "Check: gpiodetect && gpioinfo -c $GPIO_CHIP"
                    rm -f "$err_tmp"
                    return 1
                fi
                ;;

            interactive)
                # --interactive: blocks reading stdin commands.
                # A FIFO kept open by sleep-infinity prevents EOF — gpioset stays alive.
                rm -f "$ff" && mkfifo "$ff"
                _gpioset --interactive "${pin}=${value}" < "$ff" 2>"$err_tmp" &
                local gs_pid=$!
                sleep infinity > "$ff" &
                local feeder_pid=$!
                printf '%s\n%s\n' "$gs_pid" "$feeder_pid" > "$pf"

                sleep 0.15
                if [[ -s "$err_tmp" ]] || ! kill -0 "$gs_pid" 2>/dev/null; then
                    error "gpioset --interactive failed: $(cat "$err_tmp" 2>/dev/null)"
                    _gpio_release "$ch"
                    rm -f "$err_tmp"
                    return 1
                fi
                ;;
        esac
    else
        # v1.x: --mode=signal holds until SIGTERM; backgrounded so we get the PID
        _gpioset --mode=signal "${pin}=${value}" 2>"$err_tmp" &
        local v1_pid=$!
        echo "$v1_pid" > "$pf"

        sleep 0.1
        if [[ -s "$err_tmp" ]] || ! kill -0 "$v1_pid" 2>/dev/null; then
            error "gpioset --mode=signal failed: $(cat "$err_tmp" 2>/dev/null)"
            _gpio_release "$ch"
            rm -f "$err_tmp"
            return 1
        fi
    fi

    rm -f "$err_tmp"
    _log INFO "CH${ch} BCM${pin}=${value} (${target_state})"
}

# ── Relay operations ──────────────────────────────────────────────
relay_on() {
    _validate_channel "$1"
    local pin=${CH_PINS[$1]}
    _gpio_set "$1" "$GPIO_ON" || return 1
    _save_state "$1" "on"
    ok "CH${1}  BCM ${pin}  ->  ON  (relay energized)"
}

relay_off() {
    _validate_channel "$1"
    local pin=${CH_PINS[$1]}
    _gpio_set "$1" "$GPIO_OFF" || return 1
    _save_state "$1" "off"
    ok "CH${1}  BCM ${pin}  ->  OFF  (relay released)"
}

relay_toggle() {
    _validate_channel "$1"
    [[ "$(_read_state "$1")" == "on" ]] && relay_off "$1" || relay_on "$1"
}

relay_pulse() {
    local ch=$1 ms=${2:-1000}
    _validate_channel "$ch"
    [[ "$ms" =~ ^[0-9]+$ ]] || die "Duration must be a positive integer (ms). Got: $ms"
    info "CH${ch}  pulse  ${ms}ms ..."
    relay_on "$ch"
    sleep "$(awk "BEGIN{printf \"%.3f\", $ms/1000}")"
    relay_off "$ch"
    ok "CH${ch}  pulse complete"
}

# ── Status display ────────────────────────────────────────────────
relay_status() {
    local hold_method="${GPIOD_V2_HOLD:-mode=signal (v1.x)}"

    echo ""
    echo "${BOLD}Waveshare RPi Relay Board (B)  v${VERSION}${RESET}"
    echo "  Chip: ${GPIO_CHIP}   libgpiod v${GPIOD_MAJOR}.x   hold: ${hold_method}"
    echo "  ----------------------------------------"

    for ch in "${CHANNELS[@]}"; do
        local pin=${CH_PINS[$ch]}
        local state; state=$(_read_state "$ch")
        local daemon_pid; daemon_pid=$(_find_gpioset_pid "$pin")
        local daemon_info="no daemon"
        [[ -n "$daemon_pid" ]] && daemon_info="PID ${daemon_pid}"

        local color="$YELLOW"
        [[ "$state" == "on"  ]] && color="$GREEN"
        [[ "$state" == "off" ]] && color="$RED"

        printf "  CH%d  BCM %-3d  %b%-8s%b  %s\n" \
            "$ch" "$pin" "$color" "${state^^}" "$RESET" "$daemon_info"
    done

    echo "  ----------------------------------------"
    echo "  Log: ${LOG_FILE}"
    echo ""
}

# ── All-channel helpers ───────────────────────────────────────────
_stop_all() {
    info "Stopping all relay daemon processes ..."
    for ch in "${CHANNELS[@]}"; do
        _gpio_release "$ch"
        _save_state "$ch" "unknown"
    done
    # Kill any remaining gpioset (safety net for stale daemons)
    local remaining
    remaining=$(ps ax -o pid,args 2>/dev/null | grep "gpioset" | grep -v grep | awk '{print $1}' || true)
    if [[ -n "$remaining" ]]; then
        echo "$remaining" | xargs kill 2>/dev/null || true
    fi
    ok "All daemons stopped. GPIO lines released."
}

_reset_all() {
    info "Resetting all relays to OFF ..."
    for ch in "${CHANNELS[@]}"; do relay_off "$ch"; done
    ok "All relays OFF."
}

# ── Validation & routing ──────────────────────────────────────────
_validate_channel() {
    [[ "${1:-}" =~ ^[1-8]$ ]] || die "Invalid channel '${1:-}'. Valid: 1 2 3 4 5 6 7 8"
}

_resolve_target() {
    local cmd=$1; shift
    (( $# > 0 )) || die "Missing channel. Usage: ${SCRIPT_NAME} ${cmd} <1-8 ...| all>"
    if [[ "$1" == "all" ]]; then
        [[ "$cmd" =~ ^(on|off)$ ]] || die "'all' is only valid for on/off"
        for ch in "${CHANNELS[@]}"; do "relay_${cmd}" "$ch"; done
    else
        for target in "$@"; do
            _validate_channel "$target"
            "relay_${cmd}" "$target"
        done
    fi
}

# ── Help ──────────────────────────────────────────────────────────
print_help() {
    cat <<EOF

${BOLD}Waveshare RPi Relay Board (B) Controller  v${VERSION}${RESET}
Raspberry Pi 5 - libgpiod

${BOLD}USAGE${RESET}
  ${SCRIPT_NAME} <command> [channel] [options]

${BOLD}COMMANDS${RESET}
  on     <1-8 ...| all>        Turn relay(s) ON  (GPIO goes LOW)
  off    <1-8 ...| all>        Turn relay(s) OFF (GPIO goes HIGH)
  toggle <1-8 ...>             Toggle relay state(s)
  pulse  <1-8> [ms]            Pulse ON for duration (default: 1000 ms)
  status                      Show all relay states and daemon health
  reset                       Turn all relays OFF (safe shutdown)
  stop                        Kill all daemons; lines float to default
  help                        Show this message

${BOLD}EXAMPLES${RESET}
  ${SCRIPT_NAME} on 1 3 5 7        # Turn CH1 CH3 CH5 CH7 ON
  ${SCRIPT_NAME} off 2 4 6         # Turn CH2 CH4 CH6 OFF
  ${SCRIPT_NAME} off all           # Turn all 8 relays OFF
  ${SCRIPT_NAME} toggle 1 3        # Toggle CH1 and CH3
  ${SCRIPT_NAME} pulse 3 500       # Pulse CH3 for 500 ms
  ${SCRIPT_NAME} status            # Current states + daemon PIDs

${BOLD}BOARD PINOUT${RESET}
  CH1->BCM5  CH2->BCM6  CH3->BCM13 CH4->BCM16
  CH5->BCM19 CH6->BCM20 CH7->BCM21 CH8->BCM26
  Logic: active-low  (GPIO LOW = relay ON / energized)

${BOLD}LIBGPIOD v1 vs v2${RESET}
  v1.x:  gpioset CHIP PIN=VAL        (positional chip)
  v2.x:  gpioset --chip CHIP PIN=VAL (chip requires --chip flag)
  Script auto-detects version and uses the correct syntax.

${BOLD}DEBUG${RESET}
  DEBUG=1 ${SCRIPT_NAME} status     # verbose chip/version/daemon info
  ps aux | grep gpioset             # check daemon processes

EOF
}

# ── Initialisation ────────────────────────────────────────────────
init() {
    mkdir -p "$STATE_DIR"
    check_deps
    detect_gpiod_version
    detect_gpio_chip
    if [[ "${DEBUG:-0}" == "1" ]]; then
        info "chip=${GPIO_CHIP}  libgpiod_v${GPIOD_MAJOR}  hold=${GPIOD_V2_HOLD:-signal(v1)}  state=${STATE_DIR}"
    fi
}

# ── Entry point ───────────────────────────────────────────────────
main() {
    (( $# > 0 )) || { print_help; exit 0; }

    local cmd=$1; shift

    case "$cmd" in
        help|--help|-h) print_help; exit 0 ;;
        on|off|toggle|pulse|status|reset|stop) ;;
        *) error "Unknown command: '${cmd}'"; print_help; exit 1 ;;
    esac

    init

    case "$cmd" in
        on|off)   _resolve_target "$cmd" "$@" ;;
        toggle)
            (( $# > 0 )) || die "Missing channel. Usage: ${SCRIPT_NAME} toggle <1-8> [...]"
            for ch in "$@"; do _validate_channel "$ch"; relay_toggle "$ch"; done
            ;;
        pulse)
            [[ -n "${1:-}" ]] || die "Missing channel. Usage: ${SCRIPT_NAME} pulse <1-8> [ms]"
            relay_pulse "$1" "${2:-1000}"
            ;;
        status) relay_status  ;;
        reset)  _reset_all    ;;
        stop)   _stop_all     ;;
    esac
}

main "$@"
