# Repo Updater

ローカルの git リポジトリを「`git pull` してビルド・インストールする」作業を、メニューバーからワンクリックで実行する macOS 常駐アプリです。

もとは [Karukan](https://github.com/togatoga/karukan) 専用の更新ツールでしたが、[Meltype](https://github.com/yksr-melt/Meltype) 用にも同じものを作る必要が出たため、複数プロジェクトを登録できるオールインワン構成に作り直しました。

- メニューバーのアイコンをクリックするとポップオーバーが開き、登録済みのプロジェクトが一覧表示されます。
- 各プロジェクトの行をクリックすると展開し、リポジトリのパス・実行コマンド・ログを確認できます。更新ボタンで次を実行します。

  ```sh
  cd <リポジトリのパス> && git pull && <プロジェクトごとの post-pull コマンド>
  ```

- 実行中はボタンが無効化され、進捗インジケーターと標準出力/標準エラーのログが表示されます。各プロジェクトは独立してステータス・ログを持つので、同時に動かしても混ざりません。
- 「プロジェクトを追加」から、名前・リポジトリのパス・`git pull` 後に実行するコマンドを入力して新しいプロジェクトを登録できます。登録内容は `UserDefaults` に保存され、次回起動時にも残ります。
- 独立したウィンドウでも同じ画面を開けます(ポップオーバー内の「ウィンドウで開く」ボタン)。

## 最初から登録されているプロジェクト

| プロジェクト | デフォルトのパス | post-pull コマンド |
| --- | --- | --- |
| [Karukan](https://github.com/togatoga/karukan) | `~/karukan` | `cd karukan-im/macos && make install && (killall KarukanIME 2>/dev/null \|\| true)` |
| [Meltype](https://github.com/yksr-melt/Meltype) | `~/Meltype` | `bash mac/update.sh` |

パスは環境に合わせてアプリ内で変更してください。

## インストール方法

### ビルド済みアプリとして

本リポジトリは Xcode プロジェクトを含みません。`RepoUpdaterApp.swift` 1ファイルのみで、`swiftc` で直接ビルドできます。

```sh
git clone <このリポジトリ>
cd karukan-updater
xcrun swiftc -parse-as-library -O -o RepoUpdater RepoUpdaterApp.swift

APP=/Applications/RepoUpdater.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp RepoUpdater "$APP/Contents/MacOS/"
cp Resources/*.icns Resources/*.png "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

open "$APP"
```

### Xcode で開発する場合

1. Xcode で新規 macOS App プロジェクトを作成し、`RepoUpdaterApp.swift` の内容で置き換える。
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
- Karukan の post-pull コマンドで `make install` の後にもう一度 `killall KarukanIME` を呼んでいるのは、`make install` が内部で既に同じ kill を実行しているためです。2 回目の kill は対象プロセスなしで失敗しうるので、`(killall KarukanIME 2>/dev/null || true)` として失敗を握りつぶしています。

## アイコンについて

- `Resources/AppIcon.icns` / `Resources/MenuBarIcon.png`(アプリ本体): SF Symbol `square.stack.3d.up.fill` から生成(`make_app_icon.swift` 参照)。
- `Resources/KarukanIcon.png`: [Karukan 公式リポジトリ](https://github.com/togatoga/karukan) の `icon.png` を元に生成。
- `Resources/MeltypeIcon.png`: [Meltype 公式リポジトリ](https://github.com/yksr-melt/Meltype) の公式ロゴ内の雪の結晶モチーフを切り出して生成。
