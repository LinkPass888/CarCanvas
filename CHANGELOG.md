# Changelog

**English** · [简体中文](CHANGELOG.zh.md) · [日本語](CHANGELOG.ja.md)

## 2.1.2 — build 7

### Changed
- **High-contrast adaptive crop frame.** Redesigned the crop overlay with dual-contrast borders, bold corner brackets and rule-of-thirds guides over an adaptive light/dark stage and 50% outer scrim, staying legible across pure white, pure black and busy wallpapers while highlighting the active size or ratio preset.
- **Smoother crop dragging.** Cached the static crop overlay during gestures and lowered the drag activation threshold to 1pt to eliminate initial stutter.
- **Versioned release IPA filename.** Packaged unsigned IPA artifacts now include the version string (`CarCanvas-v<version>-unsigned.ipa`, e.g. `CarCanvas-v2.1.2-unsigned.ipa`).

## 2.1.1 — build 6

### Added
- **Remembered crop resolution.** Confirming a custom pixel size or aspect-ratio preset saves that resolution for subsequent crops across launches. Confirming **System size** clears the saved resolution and restores per-file defaults.

### Fixed
- **Crop frame, presets and CJK input.** Narrow portrait ratios no longer overflow the preview area, switching between aspect-ratio presets no longer shrinks the resolution, and full-width digits or pasted spaces are accepted.
- **Panoramic photo support.** Source images wider or taller than 16,384 pixels are downsampled cleanly instead of failing on confirmation.
- **Reload overlay recovery.** The interface-reload overlay stops when backgrounded so returning from the lock screen does not re-trigger it, and exposes a **Close** button after 5 seconds if the reload does not occur.
- **Accurate staged metadata and version display.** Pending edits show their staged byte size, photo preparation displays a loading state, and Settings reads the live app version instead of a stale label.

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