# CLAUDE.md

Guidance for AI agents working on this repository.

## What this is

An Omarchy shell plugin (`abagonhishead.amdpower`): a read-only bar widget that shows AMD Ryzen SMU power, current and temperature limits and live readings. It runs inside Omarchy's Quickshell process (`omarchy-shell`) and is written in QML and JavaScript. There's no build step.

- `manifest.json`: the Omarchy plugin manifest (id, bar widget metadata, setting defaults).
- `Panel.qml`: the bar button, the popup and the settings view.
- `Model.js`: decoding the power table, plus the per-version table layouts.
- `i18n/en.json`: every user-visible string. Read them through `strings.t()`, and never hard-code text in QML.
- `assets/screenshot.png`: the README screenshot.

## Data source

The plugin reads `/sys/kernel/ryzen_smu_drv/pm_table` and `pm_table_version`, which the `ryzen_smu` kernel module exposes world-readable. The table is little-endian float32. Its layout depends on the table version, so `Model.js` keys every layout by version. An unknown version must decode to "unsupported", never to guessed numbers.

The layouts are generated from RyzenAdj's `lib/api.c` `get_*` readers. Only layouts marked `verified: true` have been checked against `sudo ryzenadj --info` on real hardware; at present that's only `0x4C0009` (Phoenix). When adding or fixing a layout:

- Mark it `verified: true` only after comparing it with `ryzenadj --info` on that chip.
- Leave out a reading rather than guess its offset.
- Two readings must never share an offset, because the same number would show twice.

The plugin is read-only. Don't add anything that writes SMU commands or changes limits.

## Testing changes

- Validate the manifest: `omarchy plugin validate .`
- Hot reload doesn't reliably pick up edits to this plugin. Run `omarchy restart shell` after each change.
- Check the shell log for QML errors and binding loops: `journalctl --user -b --since "-1min" | grep -iE 'amdpower|TypeError|ReferenceError|Binding loop'`
- Open the popup with `omarchy-shell abagonhishead.amdpower open`, and check it on screen (`grim`) before calling a change done.

## Conventions

- Always use braces on `if`/`else`/loops, with the body on its own line.
- Set `textFormat: Text.PlainText` on all text (use the `PlainText` component). This follows Omarchy's plugin safety guidance.
- Follow Omarchy's look: use `qs.Ui` components (`KeyboardPanel`, `PanelSeparator`, `PanelSectionHeader`, `PanelActionButton`, `ToggleSwitch`, `PanelToolTip`), `Style` sizes and `Style.duration()` for animation, and theme colours from `root.bar.foreground` and `Commons.Color`.
- Settings live in the widget's `shell.json` entry, written through `setSetting()`. Every new setting needs a default in `manifest.json`.
- List models must be stable across refreshes, such as the static key arrays from `Model.groupKeys()`. A new array on every refresh rebuilds the delegates and kills hover tooltips.
- Don't put code between a comment and the code it describes.

## Commits

- Write detailed commit messages that say what changed and why.
- Don't add Claude trailers (Co-Authored-By, "Generated with Claude Code" and so on) to commits or PRs.
- Don't commit until the maintainer has tested the change and approved it.
