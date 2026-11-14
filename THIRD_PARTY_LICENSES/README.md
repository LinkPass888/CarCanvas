# Third-party licenses

This directory records the third-party components vendored into this repository. CarCanvas itself is released under `GPL-3.0-or-later`; the full text is in [../LICENSE](../LICENSE).

## worse_query

| Field | Value |
| --- | --- |
| Component | `worse_query` (including `pathleak`) |
| Upstream URL | https://github.com/forcequitOS/worse_query |
| License | `GPL-3.0-or-later` (full text: [worse_query-GPL-3.0.txt](worse_query-GPL-3.0.txt); GitHub reports SPDX `GPL-3.0`) |
| Author / copyright | Copyright (C) 2026 Taj C (forcequit), forcequitOS |
| Vendored location | `vendor/worse_query/` |
| How it was taken | Vendored verbatim (原样 vendored): `worse_query.h`, `worse_query.m`, `pathleak.h`, `pathleak.m`, with the single source change documented below |

The vendored files keep their original copyright notices and GPL headers.

### The only modification: `pathleak.m`

Upstream `pathleak.m` contains the private SDK header:

```c
#include <sys/fsgetpath.h>
#include <sys/mount.h>
```

That private header is not available in the public iOS SDK. The only change made for this repository is replacing the private include with an explicit declaration of the same function:

```c
#include <sys/mount.h>

extern ssize_t fsgetpath(char *, size_t, fsid_t *, uint64_t);
```

`fsid_t` comes from the public `<sys/mount.h>`. This allows the file to be compiled with the public iOS SDK; no logic, behaviour, copyright notice, or GPL header was changed. The other three files are unmodified.

### GPL-3.0 obligations

GPL-3.0 requires, in particular:

- When distributing a binary, you must also provide the complete corresponding source code and the license text.
- Copyright notices must be preserved.
- Derivative works must be released under the same license (`GPL-3.0-or-later`).

For this repository that means any IPA or other binary you distribute must be accompanied by this complete source tree and by the GPL-3.0 text in `LICENSE`.

### UI intentionally not imported

We **deliberately do not import** the upstream `worse_query` `ContentView.swift`. That file contains an arbitrary target-path text field (`TextField("Target", text: $path)`), a "Share Contents" link, and general path enumeration / directory-browsing utilities. CarCanvas does not expose arbitrary path input or a general-purpose file browser: its only target is the `com.apple.CarPlayWallpaper` cache directory and the `.cpbitmap` files already present there. See the security boundary described in [../README.md](../README.md#3-backend-worse_query).

## Other attributions

- `docs/app-icon.png` and `docs/carplay-wallpaper-picker.png` come from the upstream public CarCanvas repository (https://github.com/Dcsyhi1998/CarCanvas). That repository has no explicit license (GitHub reports `license: null`), so the rights status of these images must be confirmed by the user; they are not covered by this project's GPL grant.
- [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop) and [Dcsyhi/CarCanvas](https://github.com/Dcsyhi1998/CarCanvas) are credited for prior research and the original app. No closed-source binaries from either project are included in this repository.

## Design references (not vendored)

The runtime App Group discovery in `CarCanvas/Features/Backend/CCAppGroup.m` and
the interrupted-swap recovery follow the publicly documented approach used by:

- [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles) — `wq_app_group()` and
  `WQRecoverCacheSwapAtPath()`
- [ichitaso/Regitela](https://github.com/ichitaso/Regitela) — `worse_query_group()`

No source from either project is copied into this repository; only the technique
of reading `com.apple.security.application-groups` from the app's own signature
via `SecTaskCopyValueForEntitlement` is reimplemented here.
