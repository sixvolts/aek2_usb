#pragma once
/* Keep QMK's suspend logic from consuming usbSofCount or parking the main loop */
#define NO_USB_STARTUP_CHECK

/* Latch a flag whenever V-USB decodes a packet from the host (SETUP/DATA).
 * This header is also pulled into the V-USB assembler file, so guard C. */
#ifndef __ASSEMBLER__
extern volatile unsigned char diag_rx_seen;
#endif
#define USB_RX_USER_HOOK(data, len) diag_rx_seen = 1;
