<p align="center">
  <img src="docs/app-icon.png" alt="CarCanvas" width="128" height="128" />
</p>

<h1 align="center">CarCanvas</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <strong>简体中文</strong> ·
  <a href="README.ja.md">日本語</a>
</p>

用自己的照片替换 CarPlay 壁纸，支持原始缓存备份与恢复。基于 [worse_query](https://github.com/forcequitOS/worse_query)。

## 使用要求

- iOS **26.0–26.7.2** 或 **27.0–27.2.1**。
- 未签名 IPA 需用支持 App Group 的工具签名，例如 SideStore、AltStore 或 Impactor。

## 五步上手

1. 在 CarPlay **设置 → 壁纸**中，将上两排 6 张图案壁纸各选一次，生成缓存。

   ![CarPlay 壁纸选择界面](docs/carplay-wallpaper-picker.png)

2. 打开 CarCanvas 的 **CarPlay** 页，点 **重试**。
3. 点目标文件的预览选择照片。每个文件单独修改，先在本地暂存。
4. 点 **应用**，写入待处理修改。
5. 等待界面重载后，重新连接 CarPlay 查看壁纸。

## 备份与维护

- 新发现的缓存会自动备份。单文件或统一 **恢复** 后，再点 **应用** 生效。
- 预览旁的 **清空** 只撤销待应用修改，不删除系统缓存。
- 设置中的 **清除缓存** 会永久删除壁纸缓存、全部备份及修改状态，保留旧导出和历史记录。这是维护操作，不是上手步骤。

## 构建

使用 Xcode 26 与 XcodeGen，或通过 GitHub Actions 构建。仓库只保存源码，IPA 由 CI 生成。

```sh
brew install xcodegen
xcodegen generate
bash scripts/build-unsigned-ipa.sh
```

## 许可与致谢

[GPL-3.0-or-later](LICENSE) · [组件许可](THIRD_PARTY_LICENSES/README.md)

感谢 [worse_query](https://github.com/forcequitOS/worse_query) 与 [原始 CarCanvas](https://github.com/Dcsyhi/CarCanvas)。

[Telegram 频道](https://t.me/linkpass666) · [爱发电](https://afdian.com/a/linkpass)

仅用于自己的设备，操作前请备份。非 Apple 官方产品。
