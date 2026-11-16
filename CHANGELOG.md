# Changelog

**English** · [简体中文](CHANGELOG.zh.md) · [日本語](CHANGELOG.ja.md)

## 2.1.0 — build 5

### Added
- **Custom crop size.** Two pixel inputs above the crop frame set the export size, defaulting to the system wallpaper resolution. An invalid size disables confirmation.
- **Aspect-ratio presets.** Common landscape, portrait and square ratios are offered below the frame.

### Changed
- **Actual resolution is shown.** The metadata row lists the file size, the wallpaper's true resolution and the pending status in that order.
- **The log survives backgrounding.** The in-memory log is cleared only when the app terminates, so it can still be copied out after a trip to the background.

### Known limitations
- **Vehicle separation is not possible.** CarPlay's pairing record is not inside any app container and the current sandbox capability cannot read it, so all caches are listed together.
- **At most six wallpapers are cached.** CarPlay keeps only the wallpapers currently selected in its picker.