# Flashing a Blank AEK2 USB Board

A guide for bringing up a freshly-assembled board with a factory-blank ATmega32A. There are two stages:

1. **One-shot bring-up over ISP** — fuses, firmware, and bootloader in one command. Requires an external programmer.
2. **Normal firmware updates over USB** — once the bootloader is on the chip, no programmer needed.

---

## Prerequisites

### Hardware
- An ISP programmer: USBasp, USBtinyISP, or an Arduino running "Arduino as ISP".
- A 2x3 2.54mm ribbon cable (or jumpers) to the board's `AVR1` ISP header.
- A USB cable for the keyboard.

### Software
- `qmk` CLI (Homebrew: `qmk/qmk/qmk`)
- AVR toolchain `avr-gcc@8` + `avrdude` (installed as QMK dependencies)
- `qmk_firmware` tree at `~/qmk_firmware` (`qmk setup`)

### ISP header pinout

```
   MISO  1 ●  ● 2  VCC
    SCK  3 ●  ● 4  MOSI
  RESET  5 ●  ● 6  GND
```

Mind pin 1 orientation on both ends of the cable. **Do not plug the keyboard's USB cable in while the ISP programmer is connected** — USBasp and USBtinyISP both supply 5V on pin 2.

---

## Stage 1 — One-shot bring-up

### The easy way

Connect your ISP programmer to `AVR1`, then run:

```sh
./firmware/flash-isp.sh
```

That compiles the firmware, verifies the chip signature, sets the fuses, flashes the QMK firmware, and flashes the USBaspLoader bootloader at `0x7000`. ~30 seconds end-to-end.

Overrides via env vars:

| Variable      | Default   | Purpose |
|---------------|-----------|---------|
| `PROGRAMMER`  | `usbasp`  | avrdude `-c` value — e.g. `usbtiny`, `stk500v1` |
| `PORT`        | *(unset)* | avrdude `-P` value — needed for Arduino-as-ISP (e.g. `/dev/cu.usbmodem14101`) |
| `KEYMAP`      | `default` | Which keymap to compile — e.g. `via` |
| `SKIP_BUILD`  | *(unset)* | Set to re-flash without recompiling |

Example — Arduino-as-ISP with the VIA keymap:

```sh
PROGRAMMER=stk500v1 PORT=/dev/cu.usbmodem14101 KEYMAP=via ./firmware/flash-isp.sh
```

When it finishes, unplug the ISP programmer and plug the keyboard in via its USB port.

### What the script does, step by step

If you prefer to do it manually (or something in the script failed and you want to drive each step), here are the equivalent commands.

**Compile the firmware**:
```sh
cd ~/qmk_firmware
qmk compile -kb kb_elmo/aek2_usb -km default
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
- `lock 0x3f`: fully unlocked.

**Flash firmware** (chip erase + write):
```sh
avrdude -c usbasp -p atmega32 \
  -U flash:w:~/qmk_firmware/kb_elmo_aek2_usb_default.hex:i
```

**Flash bootloader** (no erase, so firmware stays intact):
```sh
avrdude -c usbasp -p atmega32 -D \
  -U flash:w:firmware/bootloader/aek2_usb_bootloader.hex:i
```

---

## Stage 2 — Firmware updates over USB

Once the bootloader is on the chip, you never need the ISP programmer again.

1. Unplug the keyboard.
2. Hold **Esc** (bootmagic lite on matrix `[0,0]`).
3. Plug the USB cable back in — the board enumerates as a USBasp device.
4. Flash:
   ```sh
   cd ~/qmk_firmware
   qmk flash -kb kb_elmo/aek2_usb -km default
   ```
5. Unplug and replug (without holding Esc) — the board enumerates as "AEK II USB".

Verify bootloader mode with `system_profiler SPUSBDataType | grep -i usbasp`.

---

## Troubleshooting

**`avrdude: initialization failed, rc=-1`**
- Check cable orientation (pin 1 on both ends).
- Check solder joints on the ISP header, crystal, and the ATmega32A itself.
- Try a lower SPI speed: `avrdude -c usbasp -p atmega32 -B 10 ...` — useful on a fresh chip still running the 1 MHz internal oscillator (the programmer clock must be < ¼ of CPU clock).

**`Device signature = 0x000000` or `0xFFFFFF`**
- No chip response. MISO/MOSI/SCK/RESET wiring issue, or VCC not reaching the chip. Verify 5V on pin 2 of AVR1 while connected.

**After flashing, holding Esc at plug-in doesn't enter bootloader**
- Fuses weren't set correctly — the reset vector must point to `0x7000`, which requires `hfuse 0xc0`. Re-run the fuse step.
- Esc key or its matrix row/col not connecting — check continuity at MCU pins `D5` (row) and `A1` (col).

**Board enumerates as USBasp but `qmk flash` can't find it**
- macOS libusb permission issue. Try `avrdude` manually — if that works, prepend `/opt/homebrew/opt/avr-gcc@8/bin` to PATH.

**JTAG pins stuck high / certain keys don't register**
- `hfuse` left at the factory default of `0x99` (JTAG enabled). JTAG claims PC2–PC5, which the matrix uses. Re-run the fuse step.
