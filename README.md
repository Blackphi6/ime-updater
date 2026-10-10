# Karukan Updater

[Karukan](https://github.com/togatoga/karukan) をローカルで最新化してビルド・インストールする、macOS のメニューバー常駐アプリです。

- メニューバーのアイコンをクリックするとポップオーバーが開き、「アップデートを実行」ボタンひとつで次を実行します。

  ```sh
  cd <リポジトリのパス> && git pull origin main && cd karukan-im/macos && make install && killall KarukanIME
  ```

- 実行中はボタンが無効化され、進捗インジケーターと標準出力/標準エラーのログが表示されます。
- 独立したウィンドウでも同じ画面を開けます(ポップオーバー内の「ウィンドウで開く」ボタン)。
- リポジトリのパスはポップオーバー内で変更でき、設定は次回起動時にも保持されます(デフォルトは `~/karukan`)。

## インストール方法

### ビルド済みアプリとして

本リポジトリは Xcode プロジェクトを含みません。`KarukanUpdaterApp.swift` 1ファイルのみで、`swiftc` で直接ビルドできます。

```sh
git clone <このリポジトリ>
cd karukan-updater
xcrun swiftc -parse-as-library -O -o KarukanUpdater KarukanUpdaterApp.swift

APP=/Applications/KarukanUpdater.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp KarukanUpdater "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

open "$APP"
```

### Xcode で開発する場合

1. Xcode で新規 macOS App プロジェクトを作成し、`KarukanUpdaterApp.swift` の内容で置き換える。
2. Deployment Target を macOS 13 以降に設定(`MenuBarExtra` を使用しているため)。
3. **App Sandbox を無効化**(必須): Target → *Signing & Capabilities* → 「App Sandbox」capability を `-` ボタンで削除。
   - サンドボックス下では `Process` によるシェルコマンド実行自体が許可されないため、エンタイトルメントの個別許可では解決できません。
4. Team を自分の Apple ID に設定し、「Sign to Run Locally」を選択。
5. Info.plist に `LSUIElement` (`Application is agent (UIElement)`) を `YES` に設定し、Dock アイコンを非表示にする。
6. `Resources/AppIcon.icns` をアプリアイコンとして、`Resources/MenuBarIcon.png` をメニューバーアイコンとして使用する(`Info.plist` の `CFBundleIconFile` に `AppIcon` を指定)。

## 仕組みのメモ

- シェルは `/bin/zsh -l` (ログインシェル) で起動し、`.zprofile` 等の PATH 設定(Homebrew など)を確実に読み込みます。
- `make install` が内部で `killall KarukanIME` を実行するため、スクリプト末尾の再 kill は `(killall KarukanIME 2>/dev/null || true)` として失敗を握りつぶしています(でないと毎回「成功しているのにエラー表示」になります)。
- メニューバーの `NSStatusItem` は `NSImage` の `size` プロパティを基準に描画するため、SwiftUI の `.frame()` だけでは縮小できません。`MenuBarIcon` では `NSImage.size` 自体を `18x18` に設定しています。

## アイコンについて

`Resources/AppIcon.icns` と `Resources/MenuBarIcon.png` は [Karukan 公式リポジトリ](https://github.com/togatoga/karukan) の `icon.png` を元に生成しています(`make_icon.swift` 参照)。
