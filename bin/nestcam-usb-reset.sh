#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# nestcam-usb-reset.sh - FR7b: USB-level device reset, tried in a fixed
# order of preference (uhubctl per-port power cycle -> sysfs unbind/bind ->
# USBDEVFS_RESET ioctl), starting from watchdog.usb_reset.method and
# falling through the rest of the chain if the starting method fails or
# isn't usable on this hardware.
#
# Invoked by nestcam-watchdog.sh after a plain restart fails to clear a
# stall; safe to run manually too (e.g. `nestcam-usb-reset.sh` by hand).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/nestcam-common.sh
source "$SCRIPT_DIR/../lib/nestcam-common.sh"

NESTCAM_LOG_TAG="nestcam-usb-reset"

# derive_usb_path <device> - walks the udev symlink to sysfs and prints the
# USB bus-port id (e.g. "3-4.1.4"), so we don't have to trust a configured
# usb_path that can go stale across reboots (config.example.yaml: "the bus
# number can change across reboots even when the physical port doesn't").
derive_usb_path() {
    local device="$1" syspath part
    syspath=$(udevadm info -q path -n "$device" 2>/dev/null) || return 1
    # e.g. .../usb2/2-1/2-1.4/2-1.4:1.0/video4linux/video0 - walk backwards
    # from the video4linux leaf and take the first component that looks
    # like a bare USB bus-port id, skipping the ":<iface>" suffixed one.
    local -a parts
    IFS='/' read -ra parts <<< "$syspath"
    local i
    for (( i=${#parts[@]}-1; i>=0; i-- )); do
        part="${parts[$i]}"
        if [[ "$part" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; then
            printf '%s' "$part"
            return 0
        fi
    done
    return 1
}

try_uhubctl() {
    local hub="$1" port="$2"
    if [[ -z "$hub" || -z "$port" ]]; then
        log_info "uhubctl: hub_location/port not configured, skipping"
        return 1
    fi
    if ! command -v uhubctl >/dev/null 2>&1; then
        log_warn "uhubctl: not installed, skipping"
        return 1
    fi
    log_info "uhubctl: power-cycling hub=$hub port=$port"
    uhubctl -l "$hub" -p "$port" -a cycle
}

try_unbind() {
    local usb_path="$1" drv=/sys/bus/usb/drivers/usb
    if [[ -z "$usb_path" ]]; then
        log_info "unbind: no usb_path available, skipping"
        return 1
    fi
    if [[ ! -e "$drv/$usb_path" ]]; then
        log_warn "unbind: $drv/$usb_path does not exist, skipping"
        return 1
    fi
    log_info "unbind/bind: $usb_path"
    if ! echo "$usb_path" > "$drv/unbind" 2>/dev/null; then
        log_warn "unbind failed for $usb_path"
        return 1
    fi
    sleep 2
    if ! echo "$usb_path" > "$drv/bind" 2>/dev/null; then
        log_warn "bind failed for $usb_path"
        return 1
    fi
}

try_usbreset() {
    local usb_path="$1" syspath bus dev node
    if [[ -z "$usb_path" ]]; then
        log_info "usbreset: no usb_path available, skipping"
        return 1
    fi
    syspath="/sys/bus/usb/devices/$usb_path"
    if [[ ! -e "$syspath/busnum" || ! -e "$syspath/devnum" ]]; then
        log_warn "usbreset: $syspath busnum/devnum not found, skipping"
        return 1
    fi
    bus=$(cat -- "$syspath/busnum")
    dev=$(cat -- "$syspath/devnum")
    node=$(printf '/dev/bus/usb/%03d/%03d' "$bus" "$dev")
    log_info "usbreset: USBDEVFS_RESET on $node"
    python3 "$SCRIPT_DIR/../lib/nestcam-usbreset.py" "$node"
}

main() {
    local configured_method usb_path hub port
    configured_method=$(cfg '.watchdog.usb_reset.method' uhubctl)
    usb_path=$(cfg '.watchdog.usb_reset.usb_path' "")
    hub=$(cfg '.watchdog.usb_reset.hub_location' "")
    port=$(cfg '.watchdog.usb_reset.port' "")

    if [[ -z "$usb_path" ]]; then
        local device
        device=$(cfg '.camera.device' /dev/nestcam)
        if usb_path=$(derive_usb_path "$device"); then
            log_info "derived usb_path=$usb_path from $device"
        else
            usb_path=""
            log_warn "could not derive usb_path from $device; unbind/usbreset fallbacks unavailable"
        fi
    fi

    # Fixed preference order (FR7b), starting from whichever method is
    # configured so hardware that doesn't support e.g. uhubctl can skip
    # straight to unbind instead of wasting a cycle on it every time.
    local -a order=()
    case "$configured_method" in
        uhubctl)  order=(uhubctl unbind usbreset) ;;
        unbind)   order=(unbind usbreset) ;;
        usbreset) order=(usbreset) ;;
        *)
            log_warn "unknown watchdog.usb_reset.method '$configured_method', using full chain"
            order=(uhubctl unbind usbreset)
            ;;
    esac

    local m
    for m in "${order[@]}"; do
        case "$m" in
            uhubctl)
                if try_uhubctl "$hub" "$port"; then
                    log_event USB_RESET_ESCALATION "uhubctl power-cycle succeeded"
                    exit 0
                fi
                ;;
            unbind)
                if try_unbind "$usb_path"; then
                    log_event USB_RESET_ESCALATION "sysfs unbind/bind succeeded"
                    exit 0
                fi
                ;;
            usbreset)
                if try_usbreset "$usb_path"; then
                    log_event USB_RESET_ESCALATION "USBDEVFS_RESET succeeded"
                    exit 0
                fi
                ;;
        esac
    done

    log_event USB_RESET_ESCALATION "all reset methods failed or were unavailable (tried: ${order[*]})"
    exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
