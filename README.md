# Halfwin

**Windows usability features for your Mac, in one small native menu-bar app.**

Halfwin is being built. Planned features:

- **Snap windows** by dragging them to screen edges and corners. Built in v0.2.
- **Layout menu**: rest the pointer at the top center of the screen to pick a preset layout.
- **Mouse tuning**: turn off pointer acceleration and reverse scrolling per mouse.
- **Dock previews**: hover a Dock icon to see that app's open windows.
- **Keep awake**: stop your Mac from sleeping, even with the lid closed.
- **Clipboard history**: hold Cmd-V to pick from the last 20 text or URL copies, kept in memory.
- **Finder shortcuts**: Cmd-X marks selected files as cut; Cmd-V moves them when the next clipboard change contains the same file URLs. A different clipboard change clears the cut state. Enter opens selected files. Click a filename to rename it.
- **Quit after the last window**: Cmd-W or the close button quits regular apps after 0.4 seconds if their Accessibility window count reaches zero. Minimized windows count; other windows an app does not expose through Accessibility do not. Finder and Halfwin are excluded.

Keyboard and Finder features stay stopped until Accessibility is granted.

## Build from source

```sh
bash Scripts/build.sh
```

## License

MIT, see [LICENSE](LICENSE).
