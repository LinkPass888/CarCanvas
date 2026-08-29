<p align="center">
  <img src="docs/app-icon.png" alt="CarCanvas" width="128" height="128" />
</p>

<h1 align="center">CarCanvas</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <strong>简体中文</strong> ·
  <a href="README.ja.md">日本語</a>
</p>

<p align="center">用自定义 CPBitmap 覆盖 CarPlay 壁纸缓存的工具。</p>

## 1. 这是什么

CarCanvas 是一个覆盖 CarPlay 壁纸缓存的工具。CarPlay 启动时不会每次重新生成壁纸，而是读取此前已经生成的缓存文件；本应用用自定义 CPBitmap 覆盖它。如果设备上没有缓存文件，就没有可覆盖的对象。

## 2. 本仓库现在是什么

这是从零重写的完整开源源码工程（Swift + SwiftUI + Objective-C），不再是只有预编译 IPA 的发布树。

- 仓库**不含任何 IPA**。`*.ipa` 已被 `.gitignore` 忽略，`build/` 目录只保留一个占位说明文件。
- IPA 由 `.github/workflows/build-ipa.yml` 在 GitHub Actions 上构建，作为 workflow artifact 下载，不提交到仓库。

## 3. 后端：worse_query

容器访问后端接入 [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)，源码 vendored 在 `vendor/worse_query/`，替换旧版基于 `com.apple.mobile.MobileHouseArrest` 身份的 MobileHouseArrest / FilzaSlop 路线。

| 项目 | 状态 |
| --- | --- |
| 上游声称的兼容范围 | iOS 26.0 – 26.7.2；另有 27.2 的说法 |
| 本项目启用的范围 | 仅 iOS 26.0 – 26.7.2 |
| Apple 官方确认 | 无；这是上游 PoC 的兼容性声明，不是 Apple 官方公告 |
| CVE 编号 | 没有确认的 CVE 编号 |
| 超出范围或未识别的版本 | 启动时失败关闭（fail-closed），不尝试访问容器 |

应用在启动时做版本门禁。任何超出启用范围的系统版本，或无法识别的系统版本，一律**失败关闭（fail-closed）**：不尝试获取沙盒扩展，也不访问容器。

这**不再是内核漏洞**、**不是越狱**、不提供 root、不注入其他进程、不联网、不上传数据。

安全边界：只定位并覆盖设备上**已经存在**的 `com.apple.CarPlayWallpaper` 缓存目录里的 `.cpbitmap` 文件；不提供任意路径输入、不提供通用文件管理器、不读取其他 App 数据。写入前自动备份到 App 的 Documents；覆盖后校验文件大小；每个覆盖目标都需要用户显式逐项确认；备份使操作可回滚。关于相关系统行为的公开资料不足，**需真机验证**。

## 4. CPBitmap 怎么生成

Apple 没有公开 `.cpbitmap` 格式文档。公开解码器在通道顺序（BGRA / RGBA）、行对齐（4 / 8 / 16 像素）、尾部长度（24 / 78 字节）上互相冲突，也找不到公开编码器。公开资料不足，无法可靠地从零实现写入器。

因此本项目采用**模板法**：读取设备上已存在的缓存文件作为模板，用数学方式按 `fileSize = width × rowStride × height + trailerLength` 反推宽高、行对齐与尾部长度，只替换像素区，**原样保留尾部元数据**，从而贴合当前系统版本的布局。同时提供 BGRA / RGBA 通道顺序开关和内建预览，供用户肉眼校验。这一步必须在真机上验证；本仓库不声称已完成真机测试。

## 5. 版本要求

| 项目 | 要求 |
| --- | --- |
| 支持的 iOS | 26.0 – 26.7.2 |
| 部署目标 | 26.0 |
| 构建工具链 | Xcode 26.x |
| 旧版 iOS | 不再支持，因为后端换了 |

旧版 iOS 不再支持，原因是容器访问后端已经更换。支持范围来自第 3 节所述的**上游声称**。

## 6. 签名与 App Group（重要）

需要你**自己**的 Apple Developer 账号注册 App Group，并把同一个 `group.<你的名字>.xxx` 写入下面两处。CI 的校验脚本会检查两者一致。

```text
CarCanvas/CarCanvas.entitlements  ->  com.apple.security.application-groups = [ group.<你的名字>.xxx ]
CarCanvas/Info.plist             ->  CCAppGroupIdentifier                 = group.<你的名字>.xxx
```

- 默认占位值是 `group.example.carcanvas.wq`，不改无法工作。
- CI 产出的是**未签名 IPA**，不能直接安装；必须自己签名。entitlement 只存在于代码签名里，未签名包没有 App Group，运行时 `containerURL(forSecurityApplicationGroupIdentifier:)` 会返回 nil。
- 个人免费账号在实践中拿不到可用的 App Group entitlement（Xcode 报 "Personal development teams do not support the App Groups capability"）；按「需要付费 ADP 或等效签名能力」准备。
- 旧版 CarCanvas 要求企业证书。本版因为不再冒用 `com.apple.mobile.MobileHouseArrest` 身份，理论上不再强制企业证书，但仍需能签 App Group 的证书/profile。
- 侧载工具重签时会从原包复制 entitlements，请确保你的重签流程保留 `com.apple.security.application-groups`。

## 7. 构建

本地：

```sh
brew install xcodegen && xcodegen generate && open CarCanvas.xcodeproj
```

CI 通过 `.github/workflows/build-ipa.yml` 自动跑同样的工具链。`scripts/build-unsigned-ipa.sh` 会在编译后把 `en`、`ja`、`zh-Hans` 三套 `.strings` 手动注入 bundle，再打包成 `Payload/` 结构的 ipa，并做完整性自检。

`scripts/verify-repository.py` 是本地可跑的验收脚本，检查内容包括：无 IPA、三套 `.strings` 的 159+ 本地化 key 与占位符一致、App Group 两处一致等。

```sh
python3 scripts/verify-repository.py
```

## 8. 使用步骤（4 步）

1. 在 CarPlay **设置 → 壁纸**里，把上两排 6 张带图案壁纸各选一次，以生成缓存文件；底部纯色壁纸不生成缓存文件。

   ![CarPlay 壁纸选择界面](docs/carplay-wallpaper-picker.png)

   | 位置 | 壁纸 | 缓存文件 |
   | --- | --- | --- |
   | 上两排 | 6 张带图案壁纸（蓝、紫、灰、绿、棕、红） | 生成深色 / 浅色 `.cpbitmap` 对 |
   | 底部一排 | 3 张纯色 | 不生成 |

   文件名中的 `-14` 后缀可能随环境不同；应用使用设备上实际找到的文件名。应用内的设置引导会带用户走完同样这 4 步。

2. 在 App 里选图并生成本地 CPBitmap。此时 CarPlay 侧不会有任何变化。
3. 打开**历史记录**，从历史记录选择导出并覆盖对应的深色 / 浅色缓存对。每个目标都需要显式确认，覆盖前会写入备份。
4. **关机重启 iPhone 一次**，让 CarPlay 重新加载被覆盖的缓存。

## 9. 中文适配

界面内置 `en` / `ja` / `zh-Hans` 三套本地化，对应 `CarCanvas/Resources/` 下的 `.strings` 文件；`CFBundleLocalizations` 已声明 `zh-Hans`，相册权限文案也已本地化。系统语言为简体中文时自动生效，不需要应用内切换语言。

## 10. 许可证与致谢

本项目因使用 `worse_query`（`GPL-3.0-or-later`）而以 `GPL-3.0-or-later` 发布。GPL-3.0 全文见 [LICENSE](LICENSE)，vendored 组件说明见 [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/README.md)。

致谢：

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)：容器访问后端。
- [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop)：更早的容器访问研究。
- [Dcsyhi/CarCanvas](https://github.com/Dcsyhi1998/CarCanvas)：原始 CarCanvas。

`docs/` 下的图片来自上游公开仓库，上游仓库没有显式许可证，权利状态需自行确认；本仓库不含上游闭源二进制。

## 11. 免责声明

仅用于你自己拥有并已备份的设备。作者不承担数据丢失、设备异常或违反服务条款的风险。这不是 Apple 官方或授权产品，也不声称获得 Apple 认可；本仓库不声称已完成真机测试。
