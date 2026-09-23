# Halfwin working rules

Halfwin is one native macOS menu-bar app that gives a Mac the Windows usability features its owner used
to get from four separate apps: drag-to-edge window snapping (Rectangle), a top-center hover menu of
preset layouts, mouse tuning (LinearMouse), Dock hover window previews (DockDoor and DockView), and
keep-awake (Jolt).

## Licensing boundary

- Halfwin is MIT. Rectangle and LinearMouse are MIT: their techniques and code may be adapted with
  attribution in `NOTICE`.
- DockDoor, Loop and AltTab are GPL-3.0. Never copy, paste, translate or closely paraphrase their code.
  Read them only to learn which system APIs exist; write Halfwin's own implementation.

## Stack and build

- Swift, AppKit for the menu bar and system hooks, SwiftUI for the Settings window. SwiftPM executable,
  no Xcode project. This Mac has Command Line Tools only.
- Minimum macOS 14.
- `bash Scripts/build.sh` compiles, assembles `build/Halfwin.app`, and signs it with the local
  "Apple Development" identity so Accessibility and Screen Recording grants survive rebuilds. It falls
  back to ad-hoc signing on machines without that identity.
- No third-party dependencies without Lance's yes.

## Defaults

Shipped defaults are Lance's own setup: his Rectangle snap map and his LinearMouse device schemes. Every
default must be changeable in Settings by someone else.
