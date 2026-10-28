# IME Updater

自作の日本語入力(IME)をローカルで最新化してビルド・インストールする作業を、メニューバーからワンクリックで実行する macOS 常駐アプリです。[Karukan](https://github.com/togatoga/karukan) 専用の更新ツールとして作りましたが、[Meltype](https://github.com/yksr-melt/Meltype) 用にも同じものが必要になったため、複数プロジェクトを登録できるオールインワン構成に作り直しました。

- **アプリを起動した瞬間に、登録されている全プロジェクトを自動で一斉更新します。** 手動でボタンを押さなくても、起動するだけで最新の状態になります。
- **バックグラウンドでの自動更新**にも対応しています(デフォルトで有効、「毎日」/「毎週」から頻度を選べます)。アプリを起動しっぱなしにしておけば、間隔を過ぎた時点で自動的に更新されます。設定はポップオーバー/ウィンドウ内の「バックグラウンドで自動更新」トグルから変更できます。
- メニューバーのアイコンをクリックするとポップオーバーが開き、登録済みのプロジェクトが一覧表示されます。
- ヘッダーの「すべて更新」ボタンで、登録済み全プロジェクトをまとめて更新できます(自動更新を待たずに手動で今すぐ更新したいときに)。
- 各プロジェクトの行をクリックすると展開し、リポジトリのパス・実行コマンド・ログを確認できます。行ごとの更新ボタンで、そのプロジェクトだけ実行することもできます。

  ```sh
  cd <リポジトリのパス> && git pull && <プロジェクトごとの post-pull コマンド>
  ```

- 実行中はボタンが無効化され、進捗インジケーターと標準出力/標準エラーのログが表示されます。各プロジェクトは独立してステータス・ログを持つので、同時に動かしても混ざりません。
- 複数プロジェクトを完全に同時実行すると、入力ソース登録などが稀に競合して失敗することがあります(実機で確認済み)。失敗した場合は3秒待って自動的に1回だけ再試行するので、通常は気にする必要はありません(2回目も失敗した場合だけ「エラー」として表示されます)。
- 実行中は進捗バーと「残り約◯分◯秒」も表示されます。コマンド自体は進捗率を教えてくれないので、前回その場所にかかった時間を基準にした目安です。初回実行時はまだ実績がないので、計測中であることだけを表示します。
- アップデートが完了すると macOS の通知(バナー)で成功/失敗を知らせます。ポップオーバーを閉じていても気づけます。
- 各プロジェクトの行には、成功/失敗を示す丸いバッジと「最終更新: ◯分前」が常に表示されます。ポップオーバーを開いた瞬間に、前回アップデートできたかどうかが分かります(結果はアプリを再起動しても残ります)。
- リポジトリのパス・`git pull` 後に実行するコマンドは各プロジェクトの行から編集でき、変更内容は `UserDefaults` に保存されて次回起動時にも残ります。
- 独立したウィンドウでも同じ画面を開けます(ポップオーバー内の「ウィンドウで開く」ボタン)。

## 対応プロジェクト

| プロジェクト | デフォルトのパス | 実行するコマンド |
| --- | --- | --- |
| [Karukan](https://github.com/togatoga/karukan) | `~/karukan` | `cd karukan-im/macos && make install && (killall KarukanIME 2>/dev/null \|\| true)` |
| [Meltype](https://github.com/yksr-melt/Meltype) | `~/Meltype` | `LIBRARY_PATH=/opt/homebrew/lib bash mac/update.sh` |
| [azooKey](https://github.com/azooKey/azooKey-Desktop) | (なし) | `brew update && brew upgrade --cask azookey` |
| [Shizuku](https://github.com/n-seiji/shizuku-ime) | (なし) | `curl -fsSL -o /tmp/Shizuku.pkg https://github.com/n-seiji/shizuku-ime/releases/latest/download/Shizuku.pkg && installer -pkg /tmp/Shizuku.pkg -target CurrentUserHomeDirectory` |

パスは環境に合わせてアプリ内で変更してください。azooKey のように Homebrew Cask だけでアップデートが完結するプロジェクトは、パスを空のままにしておけば `cd` と `git pull` をスキップしてコマンドだけ実行します。新しい IME に対応させたい場合は `IMEUpdaterApp.swift` の `AppViewModel.defaultProjects` に追記してビルドし直してください(アプリ内から動的に追加する UI はあえて持たせていません)。

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

### 権限ダイアログが毎回出る場合

ビルド済みアプリとして配布している上記の手順は `codesign --force --sign -` (ad-hoc 署名)を使っています。ビルドするたびに署名が変わるため、macOS が毎回「新しいプログラム」とみなし、リムーバブルボリュームへのアクセス許可などのダイアログが繰り返し出ることがあります。

気になる場合は、固定の自己署名証明書を作って使ってください。

```sh
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 36500 -nodes \
  -subj "/CN=IME Updater Local Signing" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:true"
openssl pkcs12 -export -out signing.p12 -inkey key.pem -in cert.pem -passout pass:
```

生成された `signing.p12` をダブルクリックしてキーチェーンに追加したら(パスワードは空欄のまま)、ビルドスクリプトの `codesign --force --sign -` を `codesign --force --sign "IME Updater Local Signing"` に変えてください。この証明書はローカル署名専用で、配布や公開鍵基盤としての信頼性はありません。**各自のマシンで一度だけ作成する必要があり、証明書(とくに秘密鍵)を他の人と共有しないでください。**

## 仕組みのメモ

- シェルは `/bin/zsh -l` (ログインシェル) で起動し、`.zprofile` 等の PATH 設定(Homebrew, dotnet など)を確実に読み込みます。
- プロジェクトの一覧・パス・コマンドは `UpdateProject` (`Codable`) として `UserDefaults` に JSON で保存しています。実行中のログは永続化せず、プロジェクトごとの `ProjectRunner` インスタンスがアプリ起動中だけ保持します。一方で直近の実行結果(成功/失敗)・実行日時・所要時間は `UserDefaults` に保存しており、アプリを再起動しても「前回アップデートできたか」や進捗の目安が分かるようにしています。
- 進捗バーは、前回成功時の所要時間を基準に「経過時間 ÷ 前回の所要時間」で進捗率を推定しています(`Timer` で 0.3 秒ごとに再計算)。実際の進捗を報告してくれるコマンドではないので目安に過ぎず、前回より時間がかかっても 99% で止めて「終わっていないのに 100% 表示」にならないようにしています。
- アップデート完了時は `UNUserNotificationCenter` でローカル通知を出します。初回起動時に通知の許可を求めるダイアログが出るので、許可しないと通知は届きません(許可しなくてもアプリ自体の動作には影響しません)。
- メニューバーの `NSStatusItem` は `NSImage` の `size` プロパティを基準に描画するため、SwiftUI の `.frame()` だけでは縮小できません。`MenuBarIcon` では `NSImage.size` 自体を `18x18` に設定しています。
- メニューバーアイコンは背景なしのキーボードのシルエットのみにしています。背景の角丸四角を付けたまま 18px に縮小すると背景の存在感が勝って形が潰れるためです(アプリアイコン側は 1024px から表示されるので背景・バッジ付きのままで問題ありません)。当初は「あ」の文字を使っていましたが、実際の入力ソース切り替えアイコン(「あ」「A」)と見分けがつかず誤解を招くため、キーボードのモチーフに変更しました。
- Karukan の post-pull コマンドで `make install` の後にもう一度 `killall KarukanIME` を呼んでいるのは、`make install` が内部で既に同じ kill を実行しているためです。2 回目の kill は対象プロセスなしで失敗しうるので、`(killall KarukanIME 2>/dev/null || true)` として失敗を握りつぶしています。
- ポップオーバー(`MenuBarContentView`)とウィンドウ(`WindowContentView`)は見た目のコンテナを分けています。プロジェクト一覧(`ProjectListView`)は共有していますが、「ウィンドウで開く」ボタンはポップオーバー側にしか出しません(ウィンドウの中に「ウィンドウで開く」ボタンがあっても意味がないため)。
- `Window` シーンは `.windowResizability(.contentSize)` にしているため、常にコンテンツの実サイズにウィンドウが追従します(`.contentMinSize` だと `idealWidth`/`maxWidth` の指定が尊重されず、ウィンドウが想定外に大きく開くことがありました)。`ProjectListView` の `ScrollView` には `.fixedSize(horizontal: false, vertical: true)` を付けて、プロジェクト数が少ないときに余分な空白ができないようにしています。
- 起動時の一斉更新とバックグラウンド更新は同じ `AppViewModel.runAll()` を使っています。`AppViewModel.init()` で即座に 1 回呼び、以降は 1 時間おきの `Timer` で「最後の自動更新から `autoUpdateInterval`(毎日/毎週)以上経っているか」をチェックします。Mac がスリープしている間は `Timer` が進まないため、厳密な周期ではなく「起きている時間ベースで、間隔を過ぎたらなるべく早く実行する」という緩い保証です。
- `ProjectRunner.run()` は失敗すると 3 秒待って 1 回だけ自動的に再試行します(`isRetry` フラグ)。複数プロジェクトを完全に同時実行すると、入力ソース登録などが稀に競合して失敗することを実機で確認したための対策です。Meltype の `mac/build.sh` が「システム設定」を自動で開いてしまう既知の挙動(開発者も原因未特定)を `pkill` で強制的に閉じようとしたところ、タイミングによっては Meltype 自身の入力ソース登録が失敗することも分かったため、その対応は見送っています。
- Meltype の postPullCommand に `LIBRARY_PATH=/opt/homebrew/lib` を付けているのは、Meltype 側が .NET(NativeAOT)でネイティブライブラリをビルドする際、`clang` のデフォルトのライブラリ検索パスに Homebrew の `/opt/homebrew/lib` が含まれておらず `ld: library 'ssl' not found` で失敗することを実機で確認したためです(`openssl` は Homebrew では keg-only で標準パスに入らないため)。ライブラリ自体は存在するので、検索パスを明示するだけで解決します。

## アイコンについて

- `Resources/AppIcon.icns`: キーボード + 更新矢印のバッジ(`make_keyboard_icon.swift` 参照)。
- `Resources/MenuBarIcon.png`: 背景なしのキーボードのシルエットのみ(`make_menubar_symbol.swift` 参照)。
- `Resources/KarukanIcon.png`: [Karukan 公式リポジトリ](https://github.com/togatoga/karukan) の `icon.png` を元に生成。
- `Resources/MeltypeIcon.png`: [Meltype 公式リポジトリ](https://github.com/yksr-melt/Meltype) の公式ロゴ内の雪の結晶モチーフを切り出して生成。
- `Resources/AzooKeyIcon.png`: [azooKey-Desktop 公式リポジトリ](https://github.com/azooKey/azooKey-Desktop) のアプリアイコンをそのまま使用。
