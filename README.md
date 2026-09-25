# Halfwin

Halfwin is a native macOS 14+ menu-bar app for window snapping, mouse controls, Dock previews, and keeping your Mac awake.

## Snapping and layouts

- Drag a window to a screen edge or corner to preview a placement. Release to snap.
- The default landscape map maximizes at the top edge, puts the outer thirds at the top corners, and splits the left and right edges into halves. Near a side's top or bottom corner, that half becomes a top or bottom half. The bottom corners are quarters. The bottom edge selects thirds, with two-thirds panes available during the same drag. Portrait screens use quarter corners, maximize at the top, left and right halves along the bottom, and vertical thirds on the sides.
- Hover at the top center of a display to open the layout menu, or drag a window there to place it. Tiles are Left Half, Right Half, Center, Normal, Maximize, Left + Stack, Thirds, and Command Center. Left + Stack has a large left pane and two stacked right panes. Click a part of a multi-part tile or drop a dragged window on that part. Normal restores the previous frame when Halfwin has one saved.
- Halfwin remembers windows in multi-window layouts for the current session. Snap Assist offers other visible windows for empty parts. Snapping into an occupied part minimizes the window already there. Snap Assist is on by default.
- Snap Groups brings paired left and right half windows forward as you switch between them. It is off by default.

## Other window actions

- The green zoom button and a double-click on a title bar toggle maximize and restore the previous frame.
- Click the bottom-right screen corner to hide open apps, then click it again to show them.
- Command-Left and Command-Right snap to halves. Command-Up maximizes. Command-Down restores a saved frame or centers the window.

## Mouse

- Windows scroll direction applies to trackpads and mouse wheels, including horizontal mouse-wheel scrolling.
- Side buttons send Back and Forward shortcuts in Finder, Safari, Safari Technology Preview, Firefox, Arc, Slack, System Settings, App Store, Music, and Help Viewer.

## Dock previews

- Hover over a running app's Dock icon to see its windows. Click a preview to restore and raise that window.
- Windows minimize into their app's Dock icon. Click the frontmost app's Dock icon to minimize its windows, then click again to restore them.
- With Screen Recording access, previews show window pictures. Halfwin captures pictures before minimizing, so minimized windows keep their last captured picture.

## Keyboard and Finder

- Hold Command-V for 0.45 seconds to open a non-key-focusing picker of up to 20 recent text and URL copies. History stays in memory.
- In Finder, Command-X marks selected files for cutting. Command-V moves them only if the next clipboard change is the matching file URL copy made by Halfwin's Command-C. The cut mark clears on another clipboard change, leaving Finder, Escape in Finder, Command-Option-V in any app, or after 60 seconds. While a cut is pending, Halfwin adds ✂︎ to its menu-bar title.
- Enter opens selected files. Clicking a filename still renames it.
- Command-W or a window's close button quits regular apps after window counts reach zero at both 0.4 and 1.0 seconds. Minimized windows and windows on other Spaces count. Finder, Halfwin, Music, Mail, Messages, Calendar, Notes, Reminders, Podcasts, TV, Photos, System Settings, Activity Monitor, and Terminal are excluded. Terminal keeps sessions alive after its last window closes.

## Keep Awake

Keep your Mac awake indefinitely or for 15 minutes, 30 minutes, 1 hour, 2 hours, or 5 hours. Separate options keep it awake with the lid closed and require an administrator password.

## Menu, Settings, and permissions

- Each optional feature listed in Halfwin's menu has its own switch. Drag-to-edge snapping and the top-center hover menu have separate on/off controls in Settings.
- Settings controls whether edge snapping is on, the eight-position snap map, and a button to restore the default map. Edge snapping defaults to on.
- The hover menu defaults to on, with a 0.35-second dwell delay and a 400-point top-center zone. Command Center side panes default to 25% each, adjustable from 15% to 35%.
- Dock preview hover delay defaults to 0 seconds. Preview size defaults to 100%.
- Accessibility access is needed for snapping, mouse controls, window actions, keyboard and Finder features, and Dock previews. Screen Recording access is needed for Dock window pictures. Grant access from Halfwin's Permissions menu.

## Build from source

```sh
bash Scripts/build.sh
```

If macOS blocks a downloaded build, choose **Open Anyway** under System Settings > Privacy & Security.

## License

MIT. See [LICENSE](LICENSE).
