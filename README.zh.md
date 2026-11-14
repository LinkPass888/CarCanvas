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
| 上游声称的兼容范围 | iOS 26.0 – 26.7.2，以及 27.2 |
| 本项目启用的范围 | iOS 26.0 – 26.7.2，以及 27.0 – 27.2（下游实测到 27.2.1） |
| Apple 官方确认 | 无；这是上游 PoC 的兼容性声明，不是 Apple 官方公告 |
| CVE 编号 | 没有确认的 CVE 编号 |
| 超出范围或未识别的版本 | 启动时失败关闭（fail-closed），不尝试访问容器 |

应用在启动时做版本门禁。任何超出启用范围的系统版本，或无法识别的系统版本，一律**失败关闭（fail-closed）**：不尝试获取沙盒扩展，也不访问容器。

这**不再是内核漏洞**、**不是越狱**、不提供 root、不注入其他进程、不联网、不上传数据。

安全边界：照片替换只写入已识别 `com.apple.CarPlayWallpaper` 容器中明确选定、已存在的白名单缓存文件。通过查询／LaunchServices 映射和限域身份探测确认容器身份，不浏览其他 App 文档。不提供任意路径输入或通用文件管理器。照片和恢复都先在应用内暂存，用户确认“应用”后才逐文件写入；替换前备份，写入后做字节读回校验。只有明确的恢复操作可以在现有固定缓存目录中重建其备份对应的文件名。待应用／已应用状态在触发 NeoSpring 前落盘；部分失败时保留成功状态和失败／剩余暂存，不自动注销。**需真机验证。**

## 4. CPBitmap 怎么生成

Apple 没有公开 `.cpbitmap` 格式文档，公开解码器的结论也不一致。现有缓存预览先使用系统读取器，再用经过校验的原始模板解码兜底，只保留小尺寸缩略图。

选取的照片在后台编码，优先调用动态解析的系统 `writeToCPBitmapFile:flags:`；方法不可用或失败时，只读取**明确选中的缓存文件**作为有效模板，替换像素区域并原样保留完整元数据／尾部，不拿另一个深浅文件代替。设置页 BGRA／RGBA 通道顺序仅用于模板回退。编码结果和小预览保存在应用本地 `StagedWallpapers/` 中，点“应用”之前不写系统缓存。两条路径都必须在真机上验证。

## 5. 版本要求

| 项目 | 要求 |
| --- | --- |
| 支持的 iOS | 26.0 – 26.7.2，27.0 – 27.2 |
| 部署目标 | 26.0 |
| 构建工具链 | Xcode 26.x |
| 旧版 iOS | 不再支持，因为后端换了 |

旧版 iOS 不再支持，原因是容器访问后端已经更换。支持范围来自第 3 节所述的**上游声称**。

## 6. 签名与 App Group（重要）

**App Group 名字不重要，谁签名就用谁的。** CarCanvas 在运行时用 `SecTaskCopyValueForEntitlement` 读取自己被签进去的 `com.apple.security.application-groups`，逐个尝试 `containerURL(forSecurityApplicationGroupIdentifier:)`，取第一个真正能打开的。这与 WQFiles、Regitela 的做法一致。所以不需要改代码里的占位值。

- CI 产出的是**未签名 IPA**，不能直接安装；必须自己签名。entitlement 只存在于代码签名里，未签名包没有 App Group，运行时拿不到容器。
- **推荐**：用 [Impactor](https://github.com/claration/impactor/releases)、AltStore 或 SideStore 签，它们会按你的 Apple ID 自动创建并保留 App Group。
- 用证书（`.p12`）+ profile 签时，profile 必须带 App Group。市面上大量卖的是通配符 profile（App ID `*`），无法包含 App Group，会签名失败或运行时报 "no accessible app group"。
- Sideloadly **不会**加 App Group，用它签的包会提示 "NONE"。
- 自己账号签：开发者后台 → Identifiers → App Groups 建一个 → 建显式 App ID 并勾上该 Group → 生成 profile → 用该 profile 签名。
- `CarCanvas/CarCanvas.entitlements` 里的 `group.example.carcanvas.wq` 只是给 Xcode 用的默认值，改成你自己团队的即可，也可以完全依赖签名工具注入。
- 若上次运行被中断，App Group 的 `Library/Caches` 可能残留成符号链接，导致后续 query 全部失败。应用启动时会检测并把挡路的东西**改名移开**（不删除），再重建目录。

## 7. 构建

本地：

```sh
brew install xcodegen && xcodegen generate && open CarCanvas.xcodeproj
```

CI 通过 `.github/workflows/build-ipa.yml` 自动跑同样的工具链。`scripts/build-unsigned-ipa.sh` 会在编译后把 `en`、`ja`、`zh-Hans` 三套 `.strings` 手动注入 bundle，再打包成 `Payload/` 结构的 ipa，并做完整性自检。

`scripts/verify-repository.py` 是本地验收脚本，检查禁止的发布产物、三语 key／占位符一致性、运行时 App Group 识别及缓存修改 UI／安全边界回归规则；不代替 iOS 编译或真机测试。

```sh
python3 scripts/verify-repository.py
```


> **注意：** 直接执行 `xcodegen generate` 并在 Xcode 里运行时不会注入 `.lproj` 资源，界面上的 `L(...)` 键名会原样显示。需要完整本地化时请使用 `scripts/build-unsigned-ipa.sh` 或 CI 工作流。



## 8. 使用步骤（5 步）

1. 在 CarPlay **设置 → 壁纸**中，将上两排 6 张带图案壁纸各选一次。底部 3 张纯色壁纸不生成缓存文件。

   ![CarPlay 壁纸选择界面](docs/carplay-wallpaper-picker.png)

   打开 CarCanvas 的 **CarPlay** 页，点“重试”。保留设备上的完整文件名及数字后缀；同名深浅文件只归组显示，不自动配对覆盖。页签仅保留 **CarPlay／设置**。
2. 点要替换的**明确文件左侧缓存预览**选择照片，无需单独设置深浅色。后台编码后本地暂存，重新打开应用仍保留选择和预览；此时不改变系统缓存。
3. 右上角“重试”变为带待处理文件数量角标的**应用**，数量也包含恢复。预览右侧**清空**只撤销该待应用修改，不删除系统缓存或备份。确认“应用”后只写待处理文件，成功状态落盘后才尝试通过 NeoSpring 重载界面。部分失败时不自动注销：成功文件保持已应用，失败和剩余文件继续待应用。NeoSpring 不等于完整系统注销，也不保证每次成功。
4. 预览右侧**恢复**仅在替换已应用且原件备份有效时可用。**备份**标题右侧只有一个统一**恢复**按钮，下面仅显示备份信息；统一恢复将所有已保存原件的恢复暂存。恢复也需“应用”写入，可在之前“清空”撤销。旧副本／恢复索引的副本会标明来源，不保证是系统原版。
5. **设置 → 清除CarPlay壁纸缓存**会永久删除白名单系统缓存、本地全部备份及索引、待应用修改和已应用状态；保留旧版本地导出文件和历史记录，不自动注销。完成后手动注销、重连 CarPlay、重新选 6 张系统图案，再点“重试”。必要时正常重启手机，默认壁纸重建结果需真机确认。

## 9. 中文适配

界面内置 `en` / `ja` / `zh-Hans` 三套本地化，对应 `CarCanvas/Resources/` 下的 `.strings` 文件；`CFBundleLocalizations` 已声明 `zh-Hans`，相册权限文案也已本地化。系统语言为简体中文时自动生效，不需要应用内切换语言。

## 10. 许可证与致谢

本仓库维护者的联系与支持入口：

- Telegram 频道：[t.me/linkpass666](https://t.me/linkpass666)
- 爱发电：[afdian.com/a/linkpass](https://afdian.com/a/linkpass)

本项目因使用 `worse_query`（`GPL-3.0-or-later`）而以 `GPL-3.0-or-later` 发布。GPL-3.0 全文见 [LICENSE](LICENSE)，vendored 组件说明见 [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/README.md)。

致谢：

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)：容器访问后端。
- [Dcsyhi/CarCanvas](https://github.com/Dcsyhi1998/CarCanvas)：原始 CarCanvas。

`docs/` 下的图片来自上游公开仓库，上游仓库没有显式许可证，权利状态需自行确认；本仓库不含上游闭源二进制。

## 11. 免责声明

仅用于你自己拥有并已备份的设备。作者不承担数据丢失、设备异常或违反服务条款的风险。这不是 Apple 官方或授权产品，也不声称获得 Apple 认可；本仓库不声称已完成真机测试。
