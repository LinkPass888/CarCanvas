<p align="center">
  <img src="docs/app-icon.png" alt="CarCanvas" width="128" height="128" />
</p>

<h1 align="center">CarCanvas</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh.md">简体中文</a> ·
  <strong>日本語</strong>
</p>

自分の写真で CarPlay の壁紙を置き換え、元のキャッシュをバックアップ・復元できます。[worse_query](https://github.com/forcequitOS/worse_query) を使用しています。

## 動作要件

- iOS **26.0–26.7.2** または **27.0–27.2.1**。
- 未署名 IPA は App Group を保持するツール（SideStore、AltStore、Impactor など）で署名してください。

## インストール

署名されていない IPA は、ご自身の Apple ID で署名する必要があります。ソースを使うのが一番簡単で、一度入れればその後も同じ場所から更新できます：

```
https://linkpass888.github.io/Sideload/source.json
```

[AltStore](https://altstore.io/)、SideStore、Feather のいずれかにこのソースを追加すると、そこからインストールと更新ができます。[サイドロード用ページ](https://linkpass888.github.io/Sideload/) を開いてボタンを押しても追加できます。ソースには Kazumi と AirBeep も含まれます。

または [Releases](https://github.com/LinkPass888/CarCanvas/releases/latest) から `CarCanvas-v*-unsigned.ipa` をダウンロードし、App Group を保持できるツールで署名してインストールしてください。

## 5 ステップで使う

1. CarPlay の **設定 → 壁紙** で模様付き壁紙を選び、キャッシュを生成します。**キャッシュは最大 6 枚までです。**

   ![CarPlay の壁紙選択画面](docs/carplay-wallpaper-picker.png)

2. CarCanvas の **CarPlay** タブで **再試行**をタップします。
3. 対象ファイルのプレビューから写真を選びます。ファイルごとに変更し、アプリ内に一時保存します。
4. **適用**をタップして保留中の変更を書き込みます。
5. 画面の再読み込み後、CarPlay に再接続して壁紙を確認します。

## 既知の制限

- **車載機を区別できません。** CarPlay のペアリング記録は `/var/mobile/Library/Preferences/com.apple.carplay.plist` にあり、どのアプリコンテナにも属していません。`worse_query` はコンテナのパスにしかサンドボックス拡張を発行せず、`cfprefsd` もこのドメインを拒否するため、どのキャッシュがどの車載機のものかを判別できません。すべてのキャッシュがまとめて表示されます。
- **キャッシュされる壁紙は最大 6 枚です。** CarPlay は壁紙ピッカーで現在選択されている壁紙のみを保持するため、キャッシュディレクトリのファイルは最大 6 個です。

## バックアップとメンテナンス

- 新しく見つかったキャッシュは自動でバックアップします。個別または一括の **復元**を選び、**適用**で書き込みます。
- プレビュー横の **クリア**は保留中の変更だけを取り消し、システムキャッシュは削除しません。
- **設定**のキャッシュ削除は、壁紙キャッシュ、全バックアップと変更状態を完全に削除します。以前の書き出しと履歴は残ります。初回設定には不要なメンテナンス操作です。

## ビルド

Xcode 26 と XcodeGen、または GitHub Actions を使用します。リポジトリにはソースのみを保存し、IPA は CI で生成します。

```sh
brew install xcodegen
xcodegen generate
bash scripts/build-unsigned-ipa.sh
```

## ライセンスと謝辞

[GPL-3.0-or-later](LICENSE) · [コンポーネントのライセンス](THIRD_PARTY_LICENSES/README.md)

[worse_query](https://github.com/forcequitOS/worse_query) と [オリジナルの CarCanvas](https://github.com/Dcsyhi1998/CarCanvas) に感謝します。

[Telegram](https://t.me/linkpass666) · [Afdian](https://afdian.com/a/linkpass)

自分のデバイスでのみ使用し、操作前にバックアップしてください。Apple の公式製品ではありません。
