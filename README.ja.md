<p align="center">
  <img src="docs/app-icon.png" alt="CarCanvas" width="128" height="128" />
</p>

<h1 align="center">CarCanvas</h1>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh.md">简体中文</a> ·
  <strong>日本語</strong>
</p>

<p align="center">CarPlay の壁紙キャッシュをカスタム CPBitmap で上書きするツールです。</p>

## 1. これは何か

CarCanvas は CarPlay の壁紙キャッシュを上書きするためのツールです。CarPlay は起動のたびに壁紙を一から生成するのではなく、事前に生成済みのキャッシュファイルを読み込みます。本アプリはそのファイルをカスタム CPBitmap で上書きします。デバイスにキャッシュファイルが存在しない場合、上書き対象はありません。

## 2. このリポジトリの現在の姿

これは Swift + SwiftUI + Objective-C でゼロから書き直した、完全なオープンソースのソースコードプロジェクトです。プリビルド IPA だけを配布するリリースツリーではありません。

- このリポジトリには **いかなる IPA も含まれません**。`*.ipa` は `.gitignore` で除外され、`build/` にはプレースホルダの README だけが置かれています。
- IPA は `.github/workflows/build-ipa.yml` により GitHub Actions 上でビルドされ、workflow artifact としてダウンロードします。リポジトリにはコミットされません。

## 3. バックエンド：worse_query

コンテナアクセス用バックエンドとして [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query) を `vendor/worse_query/` に vendored として組み込みました。`com.apple.mobile.MobileHouseArrest` の identity に依存していた旧版の MobileHouseArrest / FilzaSlop 方式を置き換えるものです。

| 項目 | 状態 |
| --- | --- |
| 上流が主張する互換範囲 | iOS 26.0 – 26.7.2、別途 27.2 との記述あり |
| 本プロジェクトが有効にする範囲 | iOS 26.0 – 26.7.2 のみ |
| Apple による確認 | なし。上流 PoC の互換性主張であり、Apple の公式発表ではない |
| CVE 番号 | 確認されたものはなし |
| 範囲外・未判別のバージョン | 起動時に fail-closed、コンテナアクセスは試行しない |

アプリは起動時にバージョンゲートを行います。有効範囲外のシステムバージョン、および判別できないシステムバージョンでは一律**失敗閉じ（fail-closed）**となり、サンドボックス拡張の取得もコンテナアクセスも試みません。

これはカーネル脆弱性を利用するものでは**なく**、脱獄でも**なく**、root を提供せず、他プロセスへのインジェクションを行わず、ネットワークに接続せず、データをアップロードしません。

セキュリティ境界：デバイス上の `com.apple.CarPlayWallpaper` キャッシュディレクトリに**すでに存在する** `.cpbitmap` ファイルの場所を特定して上書きするだけです。任意パスの入力欄はなく、汎用ファイルマネージャも提供しません。CarPlayWallpaper コンテナを特定するため、アプリデータコンテナの第 1 階層を列挙し、各コンテナの `.com.apple.mobile_container_manager.metadata.plist` を読み取りますが、各 App の文書内容は読み取りません。書き込み前に App の Documents へ自動バックアップし、上書き後にファイルサイズを検証し、選択した Dark/Light の対象を明示した確認ダイアログでユーザーの確認を要求します。バックアップによりロールバック可能です。関連するシステム挙動についての公開情報は不足しており、**実機検証が必要**です。

## 4. CPBitmap の生成方法

Apple は `.cpbitmap` 形式のドキュメントを公開していません。公開されているデコーダ同士でも、チャンネル順（BGRA / RGBA）、行アライメント（4 / 8 / 16 ピクセル）、末尾の長さ（24 / 78 バイト）について記述が矛盾し、公開エンコーダは見つかりませんでした。公開情報が不足しており、ゼロから確実なライターを実装することはできません。

そのため本プロジェクトは**テンプレート方式**を採用します。デバイス上に既存のキャッシュファイルをテンプレートとして読み込み、`fileSize = width × rowStride × height + trailerLength` から幅・高さ・行アライメント・末尾長を数学的に逆算し、ピクセル領域だけを置き換えて**末尾のメタデータはバイト単位でそのまま保持**します。これにより現在のシステムバージョンが使うレイアウトに合わせられます。BGRA / RGBA のチャンネル順切り替えと内蔵プレビューを用意し、ユーザーが目視で確認できます。この手順は実機での検証が必須です。本リポジトリは実機テスト完了を主張しません。

## 5. バージョン要件

| 項目 | 要件 |
| --- | --- |
| 対応 iOS | 26.0 – 26.7.2 |
| Deployment target | 26.0 |
| ビルド環境 | Xcode 26.x |
| 旧版 iOS | 非対応（バックエンドを変更したため） |

旧版 iOS はコンテナアクセス用バックエンドが変わったため非対応です。対応範囲は第 3 節の**上流の主張**に基づきます。

## 6. 署名と App Group（重要）

**グループ名は重要ではありません。署名したツールが入れたものが使われます。** CarCanvas は実行時に `SecTaskCopyValueForEntitlement` で自分自身の署名から `com.apple.security.application-groups` を読み取り、`containerURL(forSecurityApplicationGroupIdentifier:)` を順に試して実際に開けたものを使います。WQFiles と Regitela と同じ方式なので、ソース内のプレースホルダを書き換える必要はありません。

- CI が生成するのは**未署名 IPA** で、そのままではインストールできません。entitlement はコード署名の中にあるため、未署名ビルドには App Group がなく、コンテナに到達できません。
- **推奨**: [Impactor](https://github.com/claration/impactor/releases)、AltStore、SideStore で署名します。Apple ID 用の App Group を自動で作成し保持します。
- 証明書（`.p12`）+ profile で署名する場合、profile に App Group が必要です。市販の多くはワイルドカード profile（App ID `*`）で App Group を含められず、署名に失敗するか実行時に "no accessible app group" になります。
- Sideloadly は App Group を**付与しません**。それで署名したビルドは "NONE" と表示します。
- 自分のアカウントで行う場合: Developer ポータル → Identifiers → App Groups で作成 → そのグループを有効にした明示的 App ID を作成 → profile を生成 → その profile で署名。
- `CarCanvas/CarCanvas.entitlements` の `group.example.carcanvas.wq` は Xcode 用の既定値にすぎません。自分のチームのグループに置き換えるか、署名ツールによる注入に任せてください。
- 前回の実行が中断された場合、App Group の `Library/Caches` がシンボリックリンクのまま残り、以降のクエリがすべて失敗します。起動時に検出し、邪魔なものを**リネームして退避**（削除はしない）してからディレクトリを作り直します。

## 7. ビルド

ローカル：

```sh
brew install xcodegen && xcodegen generate && open CarCanvas.xcodeproj
```

CI は `.github/workflows/build-ipa.yml` で同じツールチェーンを自動実行します。`scripts/build-unsigned-ipa.sh` はコンパイル後に `en` / `ja` / `zh-Hans` の 3 セットの `.strings` を手動で bundle に注入し、`Payload/` 構造の ipa にパッケージして完全性のセルフチェックを行います。

`scripts/verify-repository.py` はローカルで実行できる検収スクリプトです。IPA が存在しないこと、3 つの `.strings` 間で 159 以上のローカライズ key とプレースホルダが一致すること、App Group 識別子が 2 か所で一致することなどを確認します。

```sh
python3 scripts/verify-repository.py
```




> **注:** `xcodegen generate` の後に Xcode から直接実行すると `.lproj` は注入されず、`L(...)` のキー名がそのまま表示されます。ローカライズ済みビルドには `scripts/build-unsigned-ipa.sh` または CI ワークフローを使用してください。

## 8. 使い方（4 ステップ）

1. CarPlay の**設定 → 壁紙**で、上 2 段の模様付き壁紙 6 枚をそれぞれ 1 回ずつ選択し、キャッシュファイルを生成します。下段の単色壁紙はキャッシュファイルを生成しません。

   ![CarPlay の壁紙選択画面](docs/carplay-wallpaper-picker.png)

   | 位置 | 壁紙 | キャッシュファイル |
   | --- | --- | --- |
   | 上 2 段 | 模様付き 6 枚（青・紫・グレー・緑・茶・赤） | Dark / Light の `.cpbitmap` ペアとして生成 |
   | 下段 | 単色 3 枚 | 生成されない |

   ファイル名の `-14` サフィックスは環境により異なる場合があります。アプリは実機で実際に見つかったファイル名を使用します。アプリ内の設定ガイドも同じ 4 ステップを案内します。

2. アプリで画像を選び、ローカル CPBitmap を生成します。この時点では CarPlay 側は変化しません。
3. **履歴**を開き、履歴項目から書き出し先を選んで対応する Dark / Light のキャッシュペアを上書きします。対象ごとに明示的な確認が必要で、上書き前にバックアップが作成されます。
4. **iPhone の電源を切って 1 回だけ再起動**し、CarPlay に上書き後のキャッシュを読み込ませます。

## 9. 中国語（簡体字）対応

UI には `en` / `ja` / `zh-Hans` の 3 セットのローカライズを `CarCanvas/Resources/` 配下の `.strings` として同梱しています。`CFBundleLocalizations` に `zh-Hans` を宣言済みで、フォトライブラリの権限文言もローカライズ済みです。システム言語が簡体字中国語なら自動的に適用され、アプリ内での言語切り替えは不要です。

## 10. ライセンスと謝辞

本プロジェクトは `worse_query`（`GPL-3.0-or-later`）を利用しているため、全体を `GPL-3.0-or-later` で公開します。GPL-3.0 の全文は [LICENSE](LICENSE)、vendored コンポーネントの説明は [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/README.md) を参照してください。

謝辞：

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)：コンテナアクセス用バックエンド。
- [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop)：先行するコンテナアクセスの研究。
- [Dcsyhi/CarCanvas](https://github.com/Dcsyhi1998/CarCanvas)：オリジナルの CarCanvas。

`docs/` 配下の画像は上流の公開リポジトリ由来です。上流リポジトリには明示的なライセンスがなく、権利関係は各自で確認する必要があります。本リポジトリは上流のクローズドソースバイナリを含みません。

## 11. 免責事項

自分が所有し、バックアップ済みのデバイスにのみ使用してください。データ消失、デバイスの不具合、サービス利用規約違反について作者は責任を負いません。これは Apple の公式製品でも Apple が認可した製品でもなく、Apple の承認や実機テスト完了を主張するものでもありません。
