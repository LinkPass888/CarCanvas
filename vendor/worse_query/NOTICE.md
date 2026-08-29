# NOTICE — 本目录来源与修改

- **来源**：[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)，作者 Taj C (forcequit)。commit 信息以 forcequitOS/worse_query 上游仓库为准。
- **许可证**：`GPL-3.0-or-later`，全文见 [`../../THIRD_PARTY_LICENSES/worse_query-GPL-3.0.txt`](../../THIRD_PARTY_LICENSES/worse_query-GPL-3.0.txt)。
- **取用方式与唯一修改**：原样 vendored，仅对 `pathleak.m` 把私有头文件 `#include <sys/fsgetpath.h>` 换成显式声明 `extern ssize_t fsgetpath(char *, size_t, fsid_t *, uint64_t);`，以便用公开 iOS SDK 编译（`fsid_t` 来自公开的 `<sys/mount.h>`）。详见 [`../../THIRD_PARTY_LICENSES/README.md`](../../THIRD_PARTY_LICENSES/README.md)。
- 本目录 4 个文件 `worse_query.h`、`worse_query.m`、`pathleak.h`、`pathleak.m` 均保留原版权声明与 GPL 头（Copyright (C) 2026 Taj C (forcequit)）。
