# Changelog

## 2.1.0 — build 5

### Changed
- **Custom crop size.** Two pixel inputs above the crop frame set the export geometry, defaulting to the system wallpaper resolution. An invalid size disables confirmation.
- **Aspect-ratio presets.** Common landscape, portrait and square ratios are offered below the frame.
- **Actual resolution beside each cache.** The metadata row now shows file size, true wallpaper resolution and the pending status in that order.
- **Session log survives backgrounding.** The in-memory log is now cleared only when the app terminates, so it can still be copied out after a trip to the background.
- **Guides and empty states state the cache limit.** Setup instructions say that CarPlay caches at most six wallpapers.

### Removed
- **Vehicle menu.** CarPlay's pairing list is unreachable from this sandbox capability, so the per-vehicle switcher never had data to show.
- **Paired wallpaper workflows.** The unused dark/light paired preview, create, export and overwrite path is gone; editing a cache file is independent.

### Fixed
- **Crop dimming overlay leaked into the frame.** The dimming mask was drawn against the whole viewport with an even-odd fill, so portrait and square frames showed it inside the kept area. The mask is gone.
- **Query failures now log their cause.** A refused sandbox query reports the target's `lstat` and open errno instead of a bare negative code.

### Known limitations
- Vehicle separation is not possible: `/var/mobile/Library/Preferences/com.apple.carplay.plist` is outside every app container, so no sandbox extension is issued for it and `cfprefsd` refuses the domain. All caches are listed together.
- At most six wallpapers are cached, because CarPlay keeps only what is currently selected in its wallpaper picker.
