#!/usr/bin/env bash
#
# One-shot bring-up for a freshly-assembled AEK2 USB board.
# Via an ISP programmer connected to AVR1, this sets fuses, flashes the
# QMK firmware, and flashes the USBaspLoader bootloader.
#
# It builds this repo's firmware/qmk (not the upstream copy inside
# qmk_firmware) by symlinking it into QMK as kb_elmo/aek2_usb_local.
#
# After this script succeeds, future firmware updates can be done over
# USB (hold BOOT, tap RESET, release BOOT, then `qmk flash`) — no ISP needed.
#
# Overrides:
#   PROGRAMMER   avrdude -c value (default: usbasp)
#   PORT         avrdude -P value (optional; needed for Arduino-as-ISP etc.)
#   KEYMAP       QMK keymap name: default, via, diag (default: default)
#   SKIP_BUILD   if set, uses the existing compiled hex instead of recompiling

set -euo pipefail

PROGRAMMER="${PROGRAMMER:-usbasp}"
PORT="${PORT:-}"
KEYMAP="${KEYMAP:-default}"
MCU="atmega32"
KB="kb_elmo/aek2_usb_local"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTLOADER_HEX="$SCRIPT_DIR/bootloader/aek2_usb_bootloader.hex"
QMK_HOME="${QMK_HOME:-$HOME/qmk_firmware}"
KB_LINK="$QMK_HOME/keyboards/$KB"
FIRMWARE_HEX="$QMK_HOME/${KB//\//_}_${KEYMAP}.hex"

# Put the AVR toolchain on PATH (Apple Silicon + Intel Homebrew)
for prefix in /opt/homebrew /usr/local; do
    if [ -d "$prefix/opt/avr-gcc@8/bin" ]; then
        export PATH="$prefix/opt/avr-gcc@8/bin:$PATH"
        break
    fi
done

AVRDUDE_ARGS=(-c "$PROGRAMMER" -p "$MCU")
[ -n "$PORT" ] && AVRDUDE_ARGS+=(-P "$PORT")

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31merror:\033[0m %s\n" "$*" >&2; exit 1; }

command -v avrdude >/dev/null || die "avrdude not found; install via Homebrew (comes with qmk/qmk/qmk)"
command -v qmk     >/dev/null || die "qmk CLI not found; brew install qmk/qmk/qmk"
[ -f "$BOOTLOADER_HEX" ] || die "bootloader hex missing: $BOOTLOADER_HEX"
[ -d "$QMK_HOME" ]       || die "qmk_firmware not found at $QMK_HOME; run \`qmk setup\`"

if [ -z "${SKIP_BUILD:-}" ]; then
    if [ "$(readlink "$KB_LINK" 2>/dev/null)" != "$SCRIPT_DIR/qmk" ]; then
        [ -e "$KB_LINK" ] && [ ! -L "$KB_LINK" ] && die "$KB_LINK exists and is not a symlink; move it aside"
        step "Linking $SCRIPT_DIR/qmk into QMK as $KB"
        ln -sfn "$SCRIPT_DIR/qmk" "$KB_LINK"
    fi
    step "Compiling QMK firmware ($KB:$KEYMAP)"
    ( cd "$QMK_HOME" && qmk compile -kb "$KB" -km "$KEYMAP" )
fi
[ -f "$FIRMWARE_HEX" ] || die "firmware hex missing: $FIRMWARE_HEX"

step "Verifying ISP comms with $MCU via $PROGRAMMER"
avrdude "${AVRDUDE_ARGS[@]}" -v 2>&1 | grep -E "Device signature|AVR Part" || die "ISP read failed — check wiring and programmer"

step "Writing fuses (lfuse=0x1f hfuse=0xc0 lock=0x3f)"
avrdude "${AVRDUDE_ARGS[@]}" \
    -U lfuse:w:0x1f:m \
    -U hfuse:w:0xc0:m \
    -U lock:w:0x3f:m

step "Flashing QMK firmware (chip erase + write)"
avrdude "${AVRDUDE_ARGS[@]}" \
    -U flash:w:"$FIRMWARE_HEX":i

step "Flashing bootloader at 0x7000 (no erase)"
avrdude "${AVRDUDE_ARGS[@]}" -D \
    -U flash:w:"$BOOTLOADER_HEX":i

step "Done. Disconnect the ISP programmer and connect the keyboard's USB if it isn't already."
printf "   Future firmware updates: hold BOOT, tap RESET, release BOOT, then \`qmk flash -kb %s -km %s\`.\n" "$KB" "$KEYMAP"
