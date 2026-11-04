# MemLens

A macOS menu bar app that shows which apps use the most memory. Click an app to see its
processes; for Chrome, Brave, Edge and Safari it also lists the open tabs, and for the
Chromium browsers it can measure memory per tab.

## Build

Requires Xcode (Swift 6) and macOS 14 or later.

```bash
./build.sh            # build into build/MemLens.app
./build.sh --install  # build, copy to ~/Applications and launch
```

Sign with a stable identity (`SIGN_ID="<identity>" ./build.sh`) so macOS keeps the
Automation and Accessibility permissions across rebuilds. `--install` refuses ad-hoc builds.
"Launch at login" only works for the copy in `~/Applications` or `/Applications`.

## Permissions

- **Automation** (per browser): reads tab titles and URLs through Apple Events. Read-only.
- **Accessibility**: only for "Ukur memory per tab". MemLens reads the browser's own
  Task Manager window (Window → Task Manager), which you open yourself. It never presses
  or closes anything.

## Notes

- Memory numbers are the per-process footprint, the same figure as Activity Monitor's
  Memory column. A group's total includes compressed memory, so app totals can add up to
  more than the RAM in use.
- Processes owned by root (WindowServer, kernel_task) can't be read without admin rights.
- Per-tab memory is the tab's main renderer process. Cross-site iframes run in separate
  processes and aren't counted. Tabs that share a renderer show "dibagi N tab".
- Incognito URLs are hidden. Safari URLs are always hidden because Safari doesn't flag
  private windows to AppleScript.
- If the Task Manager layout isn't recognised, a redacted outline of its accessibility
  tree is written to `~/Library/Logs/MemLens/ax-dump.txt`.
