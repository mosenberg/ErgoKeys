# ErgoKeys

ErgoKeys is a small macOS background app for the Microsoft Natural Ergonomic Keyboard 4000. Those extra keys never arrive as normal keystrokes. They show up on a second USB interface, and this app listens there.

## Documentation language

Write code comments, the README, commit messages, and any other documentation in English.

## Behavior that is easy to break

- Open only the consumer-control interface (HID usage page `0x0C`, vendor `0x045E`, product `0x00DB` or `0x00DC`). Do not seize the device. Seizing it would take over typing, volume, and play/pause.
- Switch desktops by posting Control+Left and Control+Right. Do not call `SLSManagedDisplaySetCurrentSpace`. On current macOS that moves the frontmost window and leaves the visible desktop where it is.
- The app icon is `assets/AppIcon.icns`, built from `assets/ergokeys-icon.png` by `scripts/make-icon.sh`. `make install` puts it in `~/Applications/ErgoKeys.app`.
- User config stays at `~/Library/Application Support/ergokeys/config.json`. Do not overwrite an existing config during install.

## Build

Requirements: macOS 13 or later, and the Xcode Command Line Tools (`swift`, `sips`, `iconutil`).

```bash
make install
.build/release/ergokeys selftest
```
