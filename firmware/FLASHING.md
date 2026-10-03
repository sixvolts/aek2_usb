# Flashing a Blank AEK2 USB Board

A guide for bringing up a freshly-assembled board with a factory-blank ATmega32A. There are two stages:

1. **Burn the USBaspLoader bootloader** onto the chip over ISP (one-time, requires an external programmer).
2. **Flash the QMK firmware** over USB using that bootloader (every subsequent time, no programmer needed).

---

## Prerequisites

### Hardware
- An ISP programmer: USBasp, USBtinyISP, or an Arduino running "Arduino as ISP". Any of them is fine.
- A 2x3 2.54mm ribbon cable (or jumpers) to connect the programmer to the board's `AVR1` ISP header.
- A USB cable for the keyboard itself.

### Software (already installed if you followed the earlier setup)
- `qmk` CLI (Homebrew: `qmk/qmk/qmk`)
- AVR toolchain: `avr-gcc@8`, `avrdude` (installed as QMK dependencies)
- QMK firmware tree at `~/qmk_firmware`

Make sure the AVR toolchain is on your PATH each time you open a new shell:

```sh
export PATH="/opt/homebrew/opt/avr-gcc@8/bin:$PATH"
```

### Verify
```sh
qmk --version
avr-gcc --version
avrdude -? 2>&1 | head -1
```

---

## Stage 1 — Burn the Bootloader

### 1.1 Locate the bootloader hex

A prebuilt binary ships in this repo at `firmware/bootloader/aek2_usb_bootloader.hex` — use that one. It's compiled from the USBaspLoader source in `firmware/bootloader/firmware/` and targets the ATmega32A at 16 MHz with bootloader address `0x7000`.

If you ever want to rebuild it (e.g. after tweaking `bootloaderconfig.h`):

```sh
cd firmware/bootloader/firmware
make
cp main.hex ../aek2_usb_bootloader.hex
```

### 1.2 Connect the ISP programmer

Plug the programmer into your Mac via USB, then connect its 6-pin ISP cable to the **AVR1** header on the keyboard PCB. Pay attention to pin 1 orientation on both ends (there's usually a notch or a red stripe on the ribbon).

Standard AVR ICSP 2x3 pinout:

```
   MISO  1 ●  ● 2  VCC
    SCK  3 ●  ● 4  MOSI
  RESET  5 ●  ● 6  GND
```

**Power**: USBasp and USBtinyISP both supply 5V on pin 2, which powers the keyboard during flashing. **Do not plug the keyboard's USB cable in at the same time** — you'll back-feed two power sources together. Keep the keyboard's USB cable unplugged for Stage 1.

### 1.3 Verify ISP communication

Replace `-c usbasp` with `-c usbtiny` (or `-c stk500v1 -P /dev/cu.usbmodem...` for Arduino-as-ISP) if that's what you have.

```sh
avrdude -c usbasp -p atmega32 -v
```

Expected: a readable device signature (`0x1e9502` for ATmega32A). If you get `initialization failed, rc=-1`, see Troubleshooting below.

### 1.4 Set fuses

For ATmega32A @ 16 MHz external crystal, with bootloader at `0x7000` and JTAG disabled (JTAG shares pins C2–C5 which are used for the matrix — this step is mandatory, or the keyboard won't scan correctly):

```sh
avrdude -c usbasp -p atmega32 \
  -U lfuse:w:0x1f:m \
  -U hfuse:w:0xc0:m \
  -U lock:w:0x3f:m
```

Fuse meanings:
- `lfuse 0x1f`: external crystal, high-frequency, slow start-up, brown-out detect enabled at 4.0V.
- `hfuse 0xc0`: JTAG disabled, SPI enabled, boot section = 2048 words at `0x3800` (= byte address `0x7000`), reset vector points to bootloader.
- `lock 0x3f`: fully unlocked (needed so the bootloader can self-program later).

### 1.5 Flash the bootloader

From the repo root:

```sh
avrdude -c usbasp -p atmega32 \
  -U flash:w:firmware/bootloader/aek2_usb_bootloader.hex:i
```

You should see "verifying ... X bytes of flash verified". The bootloader is now installed at `0x7000`–`0x7FFF`.

### 1.6 Disconnect the programmer

Unplug the ISP cable from the board. Stage 1 is done — you shouldn't ever need the external programmer again (unless the fuses get corrupted).

---

## Stage 2 — Flash QMK Firmware over USB

### 2.1 Build the QMK hex

If you haven't already, symlink this repo's keyboard definition into QMK and compile:

```sh
ln -s "$(pwd)/firmware/qmk" ~/qmk_firmware/keyboards/kb_elmo/aek2_usb
cd ~/qmk_firmware
qmk compile -kb kb_elmo/aek2_usb -km default
```

(Note: the upstream QMK tree already ships this keyboard. If the symlink already exists or there's a directory in the way, `rm` it first — your local copy and upstream are in sync.)

Output: `~/qmk_firmware/kb_elmo_aek2_usb_default.hex`.

### 2.2 Enter bootloader mode

Bootmagic Lite is enabled on matrix position `[0,0]` (the **Esc** key):

1. Unplug the keyboard from USB.
2. Hold **Esc**.
3. Plug the USB cable back in.
4. Keep holding Esc for ~1 second, then release.

The board now enumerates as a USBasp programmer instead of a keyboard. Verify:

```sh
system_profiler SPUSBDataType | grep -i usbasp
```

### 2.3 Flash

```sh
cd ~/qmk_firmware
qmk flash -kb kb_elmo/aek2_usb -km default
```

This runs `avrdude -c usbasp -p atmega32 -U flash:w:<hex>:i` under the hood. Expect ~5–10 seconds of writing and verifying.

### 2.4 Return to keyboard mode

Unplug and replug (without holding Esc). The board should now enumerate as "AEK II USB" and type normally.

---

## Subsequent Updates

For every future firmware change, you only need Stage 2 steps 2.2–2.4. The bootloader stays resident at `0x7000` and the fuses never need to be touched again.

---

## Troubleshooting

**`avrdude: initialization failed, rc=-1`**
- Check cable orientation (pin 1 on both ends).
- Check solder joints on the ISP header, crystal, and the ATmega32A itself.
- Try a lower SPI speed: `avrdude -c usbasp -p atmega32 -B 10 ...` (useful if the chip is still running on its 1 MHz internal oscillator — slow the programmer below ¼ of the clock).

**`avrdude: Device signature = 0x000000` or `0xFFFFFF`**
- No chip response. Usually MISO/MOSI/SCK/RESET cable issue, or VCC not reaching the chip. Verify 5V on pin 2 of AVR1 while connected.

**After flashing bootloader, holding Esc at plug-in doesn't enter bootloader**
- You probably didn't actually set the fuses before flashing. The reset vector needs to point at `0x7000`, which `hfuse 0xc0` does. Re-run step 1.4.
- Could also be that the Esc key or its matrix row/col isn't connecting — check with a multimeter at matrix `[row 0, col 0]` which is pins `D5` (row) and `A1` (col) on the MCU.

**Board enumerates as USBasp but `qmk flash` can't find it**
- macOS libusb permission issue. Try running `avrdude` manually — if it works, there's a PATH issue in the `qmk` wrapper. Prepend `/opt/homebrew/opt/avr-gcc@8/bin` to PATH.

**JTAG pins stuck high / certain keys don't register**
- `hfuse` was left at the factory default of `0x99` (JTAG enabled). JTAG claims PC2–PC5, which the matrix uses. Re-run step 1.4.
