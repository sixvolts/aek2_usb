# Flashing a Blank AEK2 USB Board

A guide for bringing up a freshly-assembled board with a factory-blank ATmega32A. There are two stages:

1. **One-shot bring-up over ISP** — fuses, firmware, and bootloader in one command. Requires an external programmer.
2. **Normal firmware updates over USB** — once the bootloader is on the chip, no programmer needed.

---

## Prerequisites

### Hardware
- An ISP programmer: USBasp, USBtinyISP, AVRISP mkII, or an Arduino running "Arduino as ISP".
- A 2x3 2.54mm ribbon cable (or jumpers) to the board's `AVR1` ISP header.
- A USB cable **that carries data** (charge-only cables power the board but it will never enumerate).

### Software
- `qmk` CLI (Homebrew: `qmk/qmk/qmk`)
- AVR toolchain `avr-gcc@8` + `avrdude` (installed as QMK dependencies)
- `qmk_firmware` tree at `~/qmk_firmware` (`qmk setup`)

The firmware built is this repo's `firmware/qmk`, symlinked into QMK as `kb_elmo/aek2_usb_local` (the script does this for you). QMK's own upstream `kb_elmo/aek2_usb` is left untouched.

### ISP header pinout

```
   MISO  1 ●  ● 2  VCC
    SCK  3 ●  ● 4  MOSI
  RESET  5 ●  ● 6  GND
```

Mind pin 1 orientation on both ends of the cable.

**Power**: USBasp and USBtinyISP supply 5V on pin 2 — **don't** also plug in the keyboard's USB cable while they're connected. The AVRISP mkII does *not* supply power: it needs the board powered (plug in the keyboard's USB), and its LED turns green once it sees target voltage.

---

## Stage 1 — One-shot bring-up

### The easy way

Connect your ISP programmer to `AVR1`, then run:

```sh
./firmware/flash-isp.sh
```

That links and compiles the firmware, verifies the chip signature, sets the fuses, flashes the QMK firmware, and flashes the USBaspLoader bootloader at `0x7000`. ~30 seconds end-to-end.

Overrides via env vars:

| Variable      | Default   | Purpose |
|---------------|-----------|---------|
| `PROGRAMMER`  | `usbasp`  | avrdude `-c` value — e.g. `usbtiny`, `avrispmkII`, `stk500v1` |
| `PORT`        | *(unset)* | avrdude `-P` value — needed for Arduino-as-ISP (e.g. `/dev/cu.usbmodem14101`) |
| `KEYMAP`      | `default` | Which keymap to compile — `default`, `via`, or `diag` (see [Diagnostics](#diagnostics)) |
| `SKIP_BUILD`  | *(unset)* | Set to re-flash without recompiling |

Examples:

```sh
PROGRAMMER=avrispmkII ./firmware/flash-isp.sh
PROGRAMMER=stk500v1 PORT=/dev/cu.usbmodem14101 KEYMAP=via ./firmware/flash-isp.sh
```

When it finishes, unplug the ISP programmer.

### What the script does, step by step

If you prefer to do it manually (or something in the script failed and you want to drive each step), here are the equivalent commands, run from the repo root.

**Link and compile the firmware**:
```sh
ln -sfn "$(pwd)/firmware/qmk" ~/qmk_firmware/keyboards/kb_elmo/aek2_usb_local
cd ~/qmk_firmware
qmk compile -kb kb_elmo/aek2_usb_local -km default
cd -
```

**Verify ISP comms**:
```sh
avrdude -c usbasp -p atmega32 -v
```
Expect device signature `0x1e9502`.

**Set fuses** — ATmega32A @ 16 MHz external crystal, boot section at `0x7000`, JTAG disabled (JTAG shares PC2–PC5 with the matrix — mandatory):
```sh
avrdude -c usbasp -p atmega32 \
  -U lfuse:w:0x1f:m \
  -U hfuse:w:0xc0:m \
  -U lock:w:0x3f:m
```

Fuse meanings:
- `lfuse 0x1f`: external crystal, high-frequency, slow start-up, brown-out detect at 4.0V.
- `hfuse 0xc0`: JTAG disabled, SPI enabled, boot section = 2048 words at word `0x3800` (byte `0x7000`), reset vector points to bootloader.
- `lock 0x3f`: fully unlocked. (Reads back as `0xff` — the ATmega32 only has 6 lock bits; the top two always read 1.)

**Flash firmware** (chip erase + write):
```sh
avrdude -c usbasp -p atmega32 \
  -U flash:w:$HOME/qmk_firmware/kb_elmo_aek2_usb_local_default.hex:i
```

**Flash bootloader** (no erase, so firmware stays intact):
```sh
avrdude -c usbasp -p atmega32 -D \
  -U flash:w:firmware/bootloader/aek2_usb_bootloader.hex:i
```

---

## Stage 2 — Firmware updates over USB

Once the bootloader is on the chip, you never need the ISP programmer again.

1. With the keyboard plugged in, hold **BOOT** (BOOT1, pulls PD4 low), tap **RESET** (RESET1), then release BOOT. The board re-enumerates as a USBasp device.
   - Once switches are installed, holding **Esc** while plugging in also works (Bootmagic Lite on matrix `[0,0]`).
2. Flash:
   ```sh
   cd ~/qmk_firmware
   qmk flash -kb kb_elmo/aek2_usb_local -km default
   ```
3. Tap **RESET** (or unplug/replug) — the board enumerates as "AEK II USB".

Verify bootloader mode with `system_profiler SPUSBDataType | grep -i usbasp`.

---

## Diagnostics

The `diag` keymap is the normal keymap plus USB bring-up instrumentation on the three lock LEDs. It still works as a keyboard if USB comes up. Flash it with:

```sh
PROGRAMMER=avrispmkII KEYMAP=diag ./firmware/flash-isp.sh
```

Then tap **RESET** and watch the LEDs (left to right: Num LED1, Caps LED2, Scroll LED3):

| LED | Meaning |
|-----|---------|
| All three flash 3× at boot | MCU started. Flashing **over and over** = it's resetting in a loop (power / reset circuit). |
| **Scroll** (right) | On while USB bus activity (keep-alives) is seen on D-. |
| **Caps** (middle) | Latches on once the MCU has decoded any packet from the host. |
| **Num** (left) | Latches on once the host has assigned a USB address. |

How to read it:
- **Boot flash, then all dark** — the MCU sees nothing from the host. D- isn't toggling at the chip: check D- voltage, data-capable cable, R1, zeners.
- **Scroll flickers, Caps never lights** — the MCU sees traffic but can't decode it. Almost always **D+ and D- swapped** (the host then treats the board as a full-speed device and talks 8× too fast), D+ not reaching PD2 (pin 16), or a wrong clock.
- **Caps on, Num off** — the MCU decodes requests but the host rejects its replies: TX levels / signal integrity.
- **All on** — enumerated; it should show up on the host. Flash `default` back when done.

---

## Troubleshooting

**`avrdude: initialization failed, rc=-1`**
- Check cable orientation (pin 1 on both ends).
- AVRISP mkII: `Target not detected` means the board isn't powered — plug in the keyboard's USB.
- Check solder joints on the ISP header, crystal, and the ATmega32A itself.
- Try a lower SPI speed: `avrdude -c usbasp -p atmega32 -B 10 ...` — useful on a fresh chip still running the 1 MHz internal oscillator (the programmer clock must be < ¼ of CPU clock).

**`Device signature = 0x000000` or `0xFFFFFF`**
- No chip response. MISO/MOSI/SCK/RESET wiring issue, or VCC not reaching the chip. Verify 5V on pin 2 of AVR1 while connected.

**Board doesn't show up on USB**

Flash the `diag` keymap first (above) — it tells you which stage fails. Then:

- **D+/D- swapped.** The most common cause. Cable wire colors are not reliable, and USB-A pin diagrams are easy to read mirror-image. Identify pins by position instead: on the plug, the outer contact that beeps to +5V is VBUS; the inner contact **next to VBUS is D-**, the inner contact next to GND is D+. The board's D- (R3, J1 pin 2, U1 pin 17 / PD3) must reach the D- contact. (J1: 1 GND, 2 D-, 3 D+, 4 VCC.)
- **Charge-only cable.** The board powers up but there's no data. Use a cable you know syncs a phone.
- **D- idle voltage.** With the board plugged in, D- (U1 pin 17) should idle at ~2.8–3.6 V and D+ (pin 16) near 0 V.
  - Well under 2.8 V: the 3.6 V zeners (D1/D2) are leaking. Use **≤500 mW** zeners — BZX55C3V6, 1N5227B, BZX79-C3V6. 1 W+ parts such as BZX85C3V6 or 1N47xx leak heavily at R1's ~1 mA (BZX85C3V6 measured 2.2 V idle on this board).
  - Around 0.7 V: D2 installed backwards (band goes on the D-/JST side).
  - 0 V with the MCU held in RESET: something on the host/cable side is pulling D- low — swapped lines (a host's reset termination pulls the line to ~0.3–0.4 V), a short, or a host port stuck after repeated failed enumerations (try another port).
  - 0 V everywhere: R1 (1.5k to +5V) missing or open.
- **Continuity through R2/R3.** 68 Ω won't make a meter beep — use resistance mode from the cable's D+/D- contact to the top of the ATmega's pin 16/17 legs (catches bad DIP socket contacts).
- Without D1/D2 fitted the board still enumerates on many hosts, but the data lines then swing to 5 V, which is out of spec. Fit the 500 mW zeners for a permanent build.

**BOOT+RESET (or Esc at plug-in) doesn't enter the bootloader**
- Fuses weren't set correctly — the reset vector must point to `0x7000`, which requires `hfuse 0xc0`. Re-run the fuse step.
- BOOT1 not pulling PD4 (U1 pin 18) to GND — check the switch's solder joints.
- For Esc: key or its matrix row/col not connecting — check continuity at MCU pins `D5` (row) and `A1` (col).

**Board enumerates as USBasp but `qmk flash` can't find it**
- macOS libusb permission issue. Try `avrdude` manually — if that works, prepend `/opt/homebrew/opt/avr-gcc@8/bin` to PATH.

**JTAG pins stuck high / certain keys don't register**
- `hfuse` left at the factory default of `0x99` (JTAG enabled). JTAG claims PC2–PC5, which the matrix uses. Re-run the fuse step.
