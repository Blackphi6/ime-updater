# IME Updater

自作の日本語入力(IME)をローカルで最新化してビルド・インストールする作業を、メニューバーからワンクリックで実行する macOS 常駐アプリです。[Karukan](https://github.com/togatoga/karukan) 専用の更新ツールとして作りましたが、[Meltype](https://github.com/yksr-melt/Meltype) 用にも同じものが必要になったため、複数プロジェクトを登録できるオールインワン構成に作り直しました。

- メニューバーのアイコンをクリックするとポップオーバーが開き、登録済みのプロジェクトが一覧表示されます。
- 各プロジェクトの行をクリックすると展開し、リポジトリのパス・実行コマンド・ログを確認できます。更新ボタンで次を実行します。

  ```sh
  cd <リポジトリのパス> && git pull && <プロジェクトごとの post-pull コマンド>
  ```

- 実行中はボタンが無効化され、進捗インジケーターと標準出力/標準エラーのログが表示されます。各プロジェクトは独立してステータス・ログを持つので、同時に動かしても混ざりません。
- リポジトリのパス・`git pull` 後に実行するコマンドは各プロジェクトの行から編集でき、変更内容は `UserDefaults` に保存されて次回起動時にも残ります。
- 独立したウィンドウでも同じ画面を開けます(ポップオーバー内の「ウィンドウで開く」ボタン)。

## 対応プロジェクト

| プロジェクト | デフォルトのパス | post-pull コマンド |
| --- | --- | --- |
| [Karukan](https://github.com/togatoga/karukan) | `~/karukan` | `cd karukan-im/macos && make install && (killall KarukanIME 2>/dev/null \|\| true)` |
| [Meltype](https://github.com/yksr-melt/Meltype) | `~/Meltype` | `bash mac/update.sh` |

パスは環境に合わせてアプリ内で変更してください。新しい IME に対応させたい場合は `IMEUpdaterApp.swift` の `AppViewModel.defaultProjects` に追記してビルドし直してください(アプリ内から動的に追加する UI はあえて持たせていません)。

## インストール方法

### ビルド済みアプリとして

本リポジトリは Xcode プロジェクトを含みません。`IMEUpdaterApp.swift` 1ファイルのみで、`swiftc` で直接ビルドできます。

```sh
git clone <このリポジトリ>
cd ime-updater
xcrun swiftc -parse-as-library -O -o "IME Updater" IMEUpdaterApp.swift

APP="/Applications/IME Updater.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "IME Updater" "$APP/Contents/MacOS/"
cp Resources/*.icns Resources/*.png "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

open "$APP"
```

### Xcode で開発する場合

1. Xcode で新規 macOS App プロジェクトを作成し、`IMEUpdaterApp.swift` の内容で置き換える。
2. Deployment Target を macOS 13 以降に設定(`MenuBarExtra` を使用しているため)。
3. **App Sandbox を無効化**(必須): Target → *Signing & Capabilities* → 「App Sandbox」capability を `-` ボタンで削除。
   - サンドボックス下では `Process` によるシェルコマンド実行自体が許可されないため、エンタイトルメントの個別許可では解決できません。
4. Team を自分の Apple ID に設定し、「Sign to Run Locally」を選択。
5. Info.plist に `LSUIElement` (`Application is agent (UIElement)`) を `YES` に設定し、Dock アイコンを非表示にする。
6. `Resources/AppIcon.icns` をアプリアイコンとして、`Resources/MenuBarIcon.png` をメニューバーアイコンとして使用する(`Info.plist` の `CFBundleIconFile` に `AppIcon` を指定)。

## 仕組みのメモ

- シェルは `/bin/zsh -l` (ログインシェル) で起動し、`.zprofile` 等の PATH 設定(Homebrew, dotnet など)を確実に読み込みます。
- プロジェクトの一覧・パス・コマンドは `UpdateProject` (`Codable`) として `UserDefaults` に JSON で保存しています。実行時の状態(ステータス・ログ)は永続化せず、プロジェクトごとの `ProjectRunner` インスタンスがアプリ起動中だけ保持します。
- メニューバーの `NSStatusItem` は `NSImage` の `size` プロパティを基準に描画するため、SwiftUI の `.frame()` だけでは縮小できません。`MenuBarIcon` では `NSImage.size` 自体を `18x18` に設定しています。
- メニューバーアイコンは背景なしのキーボードのシルエットのみにしています。背景の角丸四角を付けたまま 18px に縮小すると背景の存在感が勝って形が潰れるためです(アプリアイコン側は 1024px から表示されるので背景・バッジ付きのままで問題ありません)。当初は「あ」の文字を使っていましたが、実際の入力ソース切り替えアイコン(「あ」「A」)と見分けがつかず誤解を招くため、キーボードのモチーフに変更しました。
- Karukan の post-pull コマンドで `make install` の後にもう一度 `killall KarukanIME` を呼んでいるのは、`make install` が内部で既に同じ kill を実行しているためです。2 回目の kill は対象プロセスなしで失敗しうるので、`(killall KarukanIME 2>/dev/null || true)` として失敗を握りつぶしています。

## アイコンについて

- `Resources/AppIcon.icns`: キーボード + 更新矢印のバッジ(`make_keyboard_icon.swift` 参照)。
- `Resources/MenuBarIcon.png`: 背景なしのキーボードのシルエットのみ(`make_menubar_symbol.swift` 参照)。
- `Resources/KarukanIcon.png`: [Karukan 公式リポジトリ](https://github.com/togatoga/karukan) の `icon.png` を元に生成。
- `Resources/MeltypeIcon.png`: [Meltype 公式リポジトリ](https://github.com/yksr-melt/Meltype) の公式ロゴ内の雪の結晶モチーフを切り出して生成。
