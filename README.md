<p align="center">
  <img src="docs/app-icon.png" alt="CarCanvas" width="128" height="128" />
</p>

<h1 align="center">CarCanvas</h1>

<p align="center">
  <strong>English</strong> ·
  <a href="README.zh.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a>
</p>

<p align="center">A tool that overwrites the CarPlay wallpaper cache with a custom CPBitmap.</p>

## 1. What this is

CarCanvas is a tool for overwriting the CarPlay wallpaper cache. CarPlay does not render wallpapers from scratch on every start: it reads cache files that were generated earlier. This app overwrites that cache with a custom CPBitmap. If no cache file exists on the device, there is nothing to overwrite.

## 2. What this repository is now

This is a complete open-source source project rewritten from scratch in Swift + SwiftUI + Objective-C. It is no longer a release tree that only ships a prebuilt IPA.

- This repository contains **no IPA of any kind**. `*.ipa` is ignored by `.gitignore`, and `build/` contains only a placeholder README.
- The IPA is built on GitHub Actions by `.github/workflows/build-ipa.yml` and is downloaded as a workflow artifact. It is not committed to the repository.

## 3. Backend: worse_query

The container-access backend is [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query), vendored under `vendor/worse_query/`. It replaces the old MobileHouseArrest / FilzaSlop route based on the `com.apple.mobile.MobileHouseArrest` identity.

| Item | Status |
| --- | --- |
| Upstream compatibility claim | iOS 26.0 – 26.7.2; upstream also mentions 27.2 |
| Range enabled by this project | iOS 26.0 – 26.7.2 only |
| Apple confirmation | None; this is an upstream PoC compatibility claim, not an Apple announcement |
| CVE identifier | None confirmed |
| Out-of-range or unrecognized versions | Fail-closed at startup; no container access attempted |

The app performs a version gate at startup. Any system version outside the enabled range, or any version it cannot identify, **fails closed (fail-closed)**: it does not try to obtain a sandbox extension and does not access the container.

This is **not** a kernel exploit, **not** a jailbreak, provides no root, does not inject into other processes, does not use the network and uploads no data.

Security boundary: the app only locates and overwrites `.cpbitmap` files that already exist in the `com.apple.CarPlayWallpaper` cache directory on the device. It offers no arbitrary path input, provides no general-purpose file manager and does not read other apps' data. Before writing it automatically backs the target files up into the app's Documents directory; after overwriting it verifies the file size; every overwrite target requires an explicit, per-item confirmation; the backup makes the operation rollback-able. Public information about the affected system behaviour is insufficient, and on-device verification is required.

## 4. How CPBitmap is generated

Apple does not publish documentation of the `.cpbitmap` format. Public decoders disagree with each other about the channel order (BGRA / RGBA), row alignment (4 / 8 / 16 pixels) and trailer length (24 / 78 bytes), and no public encoder was found. Public information is insufficient to implement a from-scratch writer with confidence.

This project therefore uses a **template method**: it reads a cache file that already exists on the device as a template, mathematically infers width, height, row alignment and trailer length from `fileSize = width × rowStride × height + trailerLength`, replaces only the pixel region and keeps the trailing metadata byte-for-byte. The output therefore follows the layout used by the current system version. A BGRA / RGBA channel-order switch and a built-in preview are provided so the user can check the result visually. This step must be verified on a real device; this repository makes no claim that real-device testing has been completed.

## 5. Version requirements

| Item | Requirement |
| --- | --- |
| Supported iOS | 26.0 – 26.7.2 |
| Deployment target | 26.0 |
| Build toolchain | Xcode 26.x |
| Older iOS versions | Not supported; the backend was replaced |

Older iOS versions are no longer supported because the container-access backend changed. The supported range comes from the upstream claim described in section 3.

## 6. Signing and App Group (important)

You must register an App Group with **your own** Apple Developer account and set the same `group.<your-name>.xxx` value in both places below. The CI verification script checks that the two values match.

```text
CarCanvas/CarCanvas.entitlements  ->  com.apple.security.application-groups = [ group.<your-name>.xxx ]
CarCanvas/Info.plist             ->  CCAppGroupIdentifier                 = group.<your-name>.xxx
```

- The default placeholder is `group.example.carcanvas.wq`; leaving it unchanged cannot work.
- CI produces an **unsigned IPA**. It cannot be installed as-is; you must sign it yourself. Entitlements exist only in the code signature, so an unsigned package has no App Group and `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil at runtime.
- A free personal team in practice cannot obtain a usable App Group entitlement (Xcode reports "Personal development teams do not support the App Groups capability"). Plan for a paid Apple Developer Program membership or an equivalent signing capability.
- Older CarCanvas required an enterprise certificate. This version no longer impersonates the `com.apple.mobile.MobileHouseArrest` identity, so an enterprise certificate is theoretically no longer mandatory, but a certificate and provisioning profile that can sign the App Group entitlement are still required.
- Sideloading tools copy entitlements from the original package when re-signing. Make sure your re-signing flow preserves `com.apple.security.application-groups`.

## 7. Building

Locally:

```sh
brew install xcodegen && xcodegen generate && open CarCanvas.xcodeproj
```

CI runs the same toolchain automatically through `.github/workflows/build-ipa.yml`. `scripts/build-unsigned-ipa.sh` compiles first, then manually injects the `en`, `ja` and `zh-Hans` `.strings` sets into the bundle, packages the result into a `Payload/` IPA and runs an integrity self-check.

`scripts/verify-repository.py` is the acceptance script you can run locally. It checks, among other things, that no IPA is present, that 159+ localization keys and their placeholders match across the three `.strings` files, and that the App Group identifier is identical in both places.

```sh
python3 scripts/verify-repository.py
```

## 8. Usage (4 steps)

1. In CarPlay **Settings → Wallpaper**, select each of the six patterned wallpapers in the top two rows once so that the cache files are generated. The solid-color wallpapers in the bottom row do not generate cache files.

   ![CarPlay wallpaper picker](docs/carplay-wallpaper-picker.png)

   | Position | Wallpapers | Cache files |
   | --- | --- | --- |
   | Top two rows | Six patterned wallpapers (Blue, Purple, Gray, Green, Brown, Red) | Generated as Dark / Light `.cpbitmap` pairs |
   | Bottom row | Three solid colors | Not created |

   The `-14` suffix in file names may differ by environment; the app uses the file names actually found on the device. The in-app setup guide walks through the same four steps.

2. In the app, pick an image and generate a local CPBitmap. Nothing changes on the CarPlay side at this point.
3. Open **History**, choose the export and overwrite the matching Dark / Light cache pair. Each target requires an explicit confirmation, and a backup is written before the overwrite.
4. **Power the iPhone off and back on once** so that CarPlay reloads the overwritten cache.

## 9. Simplified Chinese support

The UI ships three localizations — `en`, `ja` and `zh-Hans` — as `.strings` files under `CarCanvas/Resources/`. `CFBundleLocalizations` declares `zh-Hans`, and the photo-library permission text is localized as well. When the system language is Simplified Chinese, it takes effect automatically; no in-app language switch is needed.

## 10. License and credits

Because this project uses `worse_query` (`GPL-3.0-or-later`), the whole project is released under `GPL-3.0-or-later`. See [LICENSE](LICENSE) for the full GPL-3.0 text and [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/README.md) for the vendored component.

Credits:

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query) for the container-access backend.
- [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop) for the earlier container-access research.
- [Dcsyhi/CarCanvas](https://github.com/Dcsyhi1998/CarCanvas) for the original CarCanvas.

The images under `docs/` come from the upstream public repository. That upstream repository has no explicit license, so the rights status of those images must be confirmed by you. This repository contains no upstream closed-source binaries.

## 11. Disclaimer

Use this only on a device you own and have backed up. The authors are not responsible for data loss, device malfunction, or any breach of service terms. This is not an Apple official or Apple-authorized product, and no claim of Apple endorsement or of completed real-device testing is made here.
