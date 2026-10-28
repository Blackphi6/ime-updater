import SwiftUI
import AppKit
import UserNotifications

@main
struct IMEUpdaterApp: App {
    @StateObject private var appViewModel = AppViewModel()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appViewModel: appViewModel)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("IME Updater", id: "main") {
            WindowContentView(appViewModel: appViewModel)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - アイコン

struct MenuBarIcon: View {
    // NSStatusItem は NSImage 自体の size(論理ポイントサイズ)をもとに描画するため、
    // .frame() だけでは縮小できない。ピクセル解像度は保ったまま size だけ落とす。
    static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some View {
        if let icon = Self.icon {
            Image(nsImage: icon)
                .resizable()
                .renderingMode(.original)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "keyboard.fill")
        }
    }
}

private var projectIconCache: [String: NSImage] = [:]

func projectIcon(named name: String?) -> NSImage? {
    guard let name else { return nil }
    if let cached = projectIconCache[name] { return cached }
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 24, height: 24)
    projectIconCache[name] = image
    return image
}

// MARK: - モデル

struct UpdateProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var repoPath: String
    var postPullCommand: String
    var iconFileName: String?
}

enum UpdateStatus: String, Equatable {
    case idle, running, success, error

    var label: String {
        switch self {
        case .idle: "待機中"
        case .running: "実行中"
        case .success: "成功"
        case .error: "エラー"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .running: .blue
        case .success: .green
        case .error: .red
        }
    }
}

// MARK: - 各プロジェクトの実行状態(非永続、プロジェクトごとに1つ)

@MainActor
final class ProjectRunner: ObservableObject {
    @Published var status: UpdateStatus = .idle
    @Published var log: String = ""
    // 直近の実行結果。再起動しても「前回アップデートできたか」が分かるよう永続化する。
    @Published var lastResult: UpdateStatus?
    @Published var lastUpdatedAt: Date?
    // 実行中の進捗(0.0〜1.0)と推定残り時間。前回の所要時間が分かっているときだけ出す
    // (正確な進捗を報告してくれるコマンドではないので、あくまで前回実績ベースの目安)。
    @Published var progress: Double?
    @Published var estimatedRemaining: TimeInterval?
    private var runningProcess: Process?
    private var progressTimer: Timer?
    private var runStartedAt: Date?
    private var lastDuration: TimeInterval?

    private let projectID: UUID
    private let projectName: String
    private static func lastResultKey(_ id: UUID) -> String { "lastResult-\(id.uuidString)" }
    private static func lastUpdatedAtKey(_ id: UUID) -> String { "lastUpdatedAt-\(id.uuidString)" }
    private static func lastDurationKey(_ id: UUID) -> String { "lastDuration-\(id.uuidString)" }

    init(projectID: UUID, projectName: String) {
        self.projectID = projectID
        self.projectName = projectName
        if let raw = UserDefaults.standard.string(forKey: Self.lastResultKey(projectID)) {
            lastResult = UpdateStatus(rawValue: raw)
        }
        lastUpdatedAt = UserDefaults.standard.object(forKey: Self.lastUpdatedAtKey(projectID)) as? Date
        let storedDuration = UserDefaults.standard.double(forKey: Self.lastDurationKey(projectID))
        lastDuration = storedDuration > 0 ? storedDuration : nil
    }

    // ログインシェル (-l) で起動し、.zprofile 等で設定された PATH
    // (Homebrew, dotnet 等) を確実に読み込む。環境依存の "command not found" を防ぐため。
    // シェルに展開させず単一引数として渡すため、パスは変数展開なしで直接埋め込む。
    //
    // isRetry: 複数プロジェクトを同時実行すると、入力ソース登録などが稀に
    // 競合して失敗することがある(実際に確認済み)。1回だけ自動で再試行することで
    // この手の一過性の失敗を吸収する。2回目も失敗したら、そこで本当のエラーとして扱う。
    func run(repoPath: String, postPullCommand: String, isRetry: Bool = false) {
        guard isRetry || status != .running else { return }
        status = .running
        if isRetry {
            log += "\n--- 失敗したため、少し待って再試行します ---\n"
        } else {
            log = ""
        }
        startProgressTracking()

        // azooKey のように brew だけでアップデートが完結するプロジェクトは
        // リポジトリを持たないので、パスが空なら cd && git pull を省略する。
        let script: String
        if repoPath.isEmpty {
            script = postPullCommand
        } else {
            let escapedPath = repoPath.replacingOccurrences(of: "'", with: "'\\''")
            script = "cd '\(escapedPath)' && git pull && \(postPullCommand)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.forwardOutput(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.forwardOutput(data) }
        }

        process.terminationHandler = { [weak self] finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                let result: UpdateStatus = finished.terminationStatus == 0 ? .success : .error
                self.runningProcess = nil
                self.stopProgressTracking(success: result == .success)
                if result == .error, !isRetry {
                    self.scheduleRetry(repoPath: repoPath, postPullCommand: postPullCommand)
                    return
                }
                self.status = result
                self.recordResult(result)
                self.notifyCompletion(result: result)
            }
        }

        do {
            try process.run()
            runningProcess = process
        } catch {
            log += "起動に失敗しました: \(error.localizedDescription)\n"
            stopProgressTracking(success: false)
            if !isRetry {
                scheduleRetry(repoPath: repoPath, postPullCommand: postPullCommand)
                return
            }
            status = .error
            recordResult(.error)
            notifyCompletion(result: .error)
        }
    }

    private func scheduleRetry(repoPath: String, postPullCommand: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.run(repoPath: repoPath, postPullCommand: postPullCommand, isRetry: true)
        }
    }

    // 正確な進捗を報告してくれるコマンドではないので、前回の所要時間を基準に
    // 「経過時間 / 前回の所要時間」で進捗を推定する。前回実績がなければ何も出さない
    // (ProjectRow 側は進捗が nil ならただのスピナーを出す)。
    private func startProgressTracking() {
        runStartedAt = Date()
        progress = nil
        estimatedRemaining = nil
        guard let lastDuration, lastDuration > 0 else { return }

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress(lastDuration: lastDuration) }
        }
    }

    private func updateProgress(lastDuration: TimeInterval) {
        guard let runStartedAt else { return }
        let elapsed = Date().timeIntervalSince(runStartedAt)
        // 前回より時間がかかっても 99% で止めておき、終わっていないのに 100% と
        // 表示してしまわないようにする。
        progress = min(elapsed / lastDuration, 0.99)
        estimatedRemaining = max(lastDuration - elapsed, 0)
    }

    private func stopProgressTracking(success: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = nil
        estimatedRemaining = nil
        if success, let runStartedAt {
            let duration = Date().timeIntervalSince(runStartedAt)
            lastDuration = duration
            UserDefaults.standard.set(duration, forKey: Self.lastDurationKey(projectID))
        }
        self.runStartedAt = nil
    }

    private func forwardOutput(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        log += text
    }

    private func recordResult(_ result: UpdateStatus) {
        let now = Date()
        lastResult = result
        lastUpdatedAt = now
        UserDefaults.standard.set(result.rawValue, forKey: Self.lastResultKey(projectID))
        UserDefaults.standard.set(now, forKey: Self.lastUpdatedAtKey(projectID))
    }

    private func notifyCompletion(result: UpdateStatus) {
        let content = UNMutableNotificationContent()
        content.title = projectName
        content.body = result == .success ? "アップデートが完了しました" : "アップデートに失敗しました"
        if result == .error {
            content.sound = .default
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// 「自動で裏で更新する」頻度。日数そのものを値に持たせておくと計算が楽。
enum AutoUpdateInterval: Int, CaseIterable, Identifiable, Codable {
    case daily = 1
    case weekly = 7

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .daily: "毎日"
        case .weekly: "毎週"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue) * 86400 }
}

// MARK: - 全体の管理(プロジェクト一覧の永続化・自動更新)

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projects: [UpdateProject] {
        didSet { save() }
    }
    // バックグラウンドでの定期更新。有効にすると、アプリが起動している間
    // interval の間隔ですべてのプロジェクトを自動更新する。
    @Published var autoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUpdateEnabled, forKey: Self.autoUpdateEnabledKey) }
    }
    @Published var autoUpdateInterval: AutoUpdateInterval {
        didSet { UserDefaults.standard.set(autoUpdateInterval.rawValue, forKey: Self.autoUpdateIntervalKey) }
    }
    private var runners: [UUID: ProjectRunner] = [:]
    private var autoUpdateTimer: Timer?

    private static let storageKey = "projects"
    private static let autoUpdateEnabledKey = "autoUpdateEnabled"
    private static let autoUpdateIntervalKey = "autoUpdateInterval"
    private static let lastAutoUpdateAtKey = "lastAutoUpdateAt"
    // バックグラウンド更新が実際に必要かをこの間隔でチェックする。
    // Mac がスリープしていた間は Timer が進まないので、起動のたびにも別途チェックする。
    private static let checkInterval: TimeInterval = 3600

    static let defaultProjects: [UpdateProject] = [
        UpdateProject(
            name: "Karukan",
            repoPath: ("~/karukan" as NSString).expandingTildeInPath,
            postPullCommand: "cd karukan-im/macos && make install && (killall KarukanIME 2>/dev/null || true)",
            iconFileName: "KarukanIcon"
        ),
        UpdateProject(
            name: "Meltype",
            repoPath: ("~/Meltype" as NSString).expandingTildeInPath,
            // mac/build.sh 内の入力ソース登録処理が、macOS 側の挙動として「システム設定」を
            // 自動で開いてしまうことがある(Meltype 側も原因未特定の既知の挙動)。
            // pkill で強制終了させるとタイミングによっては入力ソースの登録自体が失敗する
            // (実際に確認済み)ため、ここでは手を出さずシステム設定が開くままにしている。
            // LIBRARY_PATH: Meltype の .NET(NativeAOT)ビルドが libssl/libcrypto をリンクする際、
            // clang のデフォルト検索パスに Homebrew の /opt/homebrew/lib が含まれておらず
            // "ld: library 'ssl' not found" で失敗することを実機で確認した。ライブラリ自体は
            // 存在するが、brew の openssl は keg-only で標準パスに入らないため明示する。
            postPullCommand: "LIBRARY_PATH=/opt/homebrew/lib bash mac/update.sh",
            iconFileName: "MeltypeIcon"
        ),
        // azooKey は Homebrew Cask で配布されているため、リポジトリの
        // クローンではなく brew コマンドだけでアップデートが完結する。
        UpdateProject(
            name: "azooKey",
            repoPath: "",
            postPullCommand: "brew update && brew upgrade --cask azookey",
            iconFileName: "AzooKeyIcon"
        ),
        // Shizuku も azooKey と同様、ソースをビルドするのではなく配布済みの
        // .pkg をそのつど取得してインストールする方式。開発元の GitHub Releases が
        // 常に最新版を指す固定 URL を提供しているため、パスは空のままコマンドだけ実行する。
        // installer の -target CurrentUserHomeDirectory は ~/Library/Input Methods への
        // ユーザーレベルインストールで、公式サイトにも「パスワードは求められません」とある
        // 通り sudo が要らない。
        UpdateProject(
            name: "Shizuku",
            repoPath: "",
            postPullCommand: "curl -fsSL -o /tmp/Shizuku.pkg https://github.com/n-seiji/shizuku-ime/releases/latest/download/Shizuku.pkg && installer -pkg /tmp/Shizuku.pkg -target CurrentUserHomeDirectory",
            iconFileName: "ShizukuIcon"
        ),
    ]

    init() {
        var loadedProjects: [UpdateProject]
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([UpdateProject].self, from: data),
           !decoded.isEmpty {
            loadedProjects = decoded
        } else {
            loadedProjects = Self.defaultProjects
        }
        // defaultProjects に後から追加したプロジェクト(名前で判定)は、
        // 既に projects を保存済みの環境にも反映する。そうしないと
        // 「コードに追記してビルドし直す」運用が、保存済みデータのある
        // 環境では一切効かなくなってしまう。
        let existingNames = Set(loadedProjects.map(\.name))
        for defaultProject in Self.defaultProjects where !existingNames.contains(defaultProject.name) {
            loadedProjects.append(defaultProject)
        }
        projects = loadedProjects

        if UserDefaults.standard.object(forKey: Self.autoUpdateEnabledKey) != nil {
            autoUpdateEnabled = UserDefaults.standard.bool(forKey: Self.autoUpdateEnabledKey)
        } else {
            autoUpdateEnabled = true // 手間なく最新を保てるのが目的なので、デフォルトは有効。
        }
        let storedInterval = UserDefaults.standard.integer(forKey: Self.autoUpdateIntervalKey)
        autoUpdateInterval = AutoUpdateInterval(rawValue: storedInterval) ?? .daily

        save() // init 内の最初の代入では didSet が呼ばれないため、明示的に保存する。

        // アプリを開いた瞬間に、まず全プロジェクトを一斉更新する。
        // これ自体がバックグラウンド更新を兼ねるので、基準時刻も更新しておく。
        runAll()
        UserDefaults.standard.set(Date(), forKey: Self.lastAutoUpdateAtKey)
        startAutoUpdateTimer()
    }

    func runner(for project: UpdateProject) -> ProjectRunner {
        if let existing = runners[project.id] { return existing }
        let runner = ProjectRunner(projectID: project.id, projectName: project.name)
        runners[project.id] = runner
        return runner
    }

    func removeProject(_ project: UpdateProject) {
        projects.removeAll { $0.id == project.id }
        runners.removeValue(forKey: project.id)
    }

    // すべてのプロジェクトを並行して更新する(各 ProjectRunner が独立した
    // プロセスを持つので、順番に待たず同時に走らせられる)。
    func runAll() {
        for project in projects {
            runner(for: project).run(repoPath: project.repoPath, postPullCommand: project.postPullCommand)
        }
    }

    private func startAutoUpdateTimer() {
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutoUpdate() }
        }
    }

    private func checkAutoUpdate() {
        guard autoUpdateEnabled else { return }
        let lastAutoUpdate = UserDefaults.standard.object(forKey: Self.lastAutoUpdateAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastAutoUpdate) >= autoUpdateInterval.seconds else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastAutoUpdateAtKey)
        runAll()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - UI

// メニューバーのポップオーバー。コンパクトに収め、ウィンドウを呼び出す導線だけ持つ。
struct MenuBarContentView: View {
    @ObservedObject var appViewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IME Updater")
                    .font(.headline)
                Spacer()
                UpdateAllButton(appViewModel: appViewModel)
                Button {
                    // LSUIElement アプリは openWindow だけだとアプリがアクティブ化されず、
                    // ウィンドウが他のウィンドウの裏に隠れて「何も起きない」ように見える。
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("ウィンドウで開く")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ProjectListView(appViewModel: appViewModel)

            Divider()

            AutoUpdateSettingsView(appViewModel: appViewModel)

            Divider()

            QuitButton()
                .padding(10)
        }
        .frame(width: 340)
    }
}

// 独立ウィンドウ。タイトルバーに既にアプリ名が出るので、本文に見出しは置かない。
// 「ウィンドウで開く」のような導線は(自分自身がウィンドウなので)不要。
struct WindowContentView: View {
    @ObservedObject var appViewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                UpdateAllButton(appViewModel: appViewModel)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ProjectListView(appViewModel: appViewModel)

            Divider()

            AutoUpdateSettingsView(appViewModel: appViewModel)

            Divider()

            QuitButton()
                .padding(10)
        }
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 420, minHeight: 120)
    }
}

// 「アプリを開いた瞬間の一斉更新」に加えて、裏で定期的に更新したい人向けの設定。
struct AutoUpdateSettingsView: View {
    @ObservedObject var appViewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $appViewModel.autoUpdateEnabled) {
                Text("バックグラウンドで自動更新")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if appViewModel.autoUpdateEnabled {
                Picker("頻度", selection: $appViewModel.autoUpdateInterval) {
                    ForEach(AutoUpdateInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// 待機中・エラーのプロジェクトをまとめて更新する。実行中のものは
// ProjectRunner.run() 側のガードでスキップされるだけなので、
// 一部が実行中でも気にせず押せる(無効化しない)。
struct UpdateAllButton: View {
    @ObservedObject var appViewModel: AppViewModel

    var body: some View {
        Button {
            appViewModel.runAll()
        } label: {
            Label("すべて更新", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .help("登録中のプロジェクトをまとめて更新します")
    }
}

struct QuitButton: View {
    var body: some View {
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
    }
}

// プロジェクト一覧。ポップオーバー/ウィンドウ両方で共有する。
// 件数が少ないときは余白なく自然な高さに収まり、多いときだけスクロールする。
struct ProjectListView: View {
    @ObservedObject var appViewModel: AppViewModel

    // 行の実際の高さは、進捗バー表示中かどうか・DisclosureGroup の展開状態で
    // 変動する。行数 × 固定高さで maxHeight を見積もると、進捗表示中の行がある
    // ときに ScrollView の高さ計算が破綻して要素が重なって表示されてしまう
    // (実際に確認した不具合)。.fixedSize でコンテンツの自然な高さに任せ、
    // maxHeight は「多くなりすぎたときだけスクロールさせる」十分大きい上限にする。
    private static let maxListHeight: CGFloat = 520

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array($appViewModel.projects.enumerated()), id: \.element.id) { index, $project in
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    ProjectRow(
                        project: $project,
                        runner: appViewModel.runner(for: project),
                        onDelete: { appViewModel.removeProject(project) }
                    )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: Self.maxListHeight)
    }
}

struct ProjectRow: View {
    @Binding var project: UpdateProject
    @ObservedObject var runner: ProjectRunner
    var onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("リポジトリのパス(空なら git pull をスキップ)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("例: ~/karukan(brew 等パス不要なら空のまま)", text: $project.repoPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .disabled(runner.status == .running)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("実行するコマンド")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("例: make install / brew upgrade --cask ...", text: $project.postPullCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .disabled(runner.status == .running)
                }

                ScrollView {
                    Text(runner.log.isEmpty ? "ログはここに表示されます" : runner.log)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(height: 140)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

                Button(role: .destructive, action: onDelete) {
                    Text("このプロジェクトを削除")
                        .font(.caption)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let icon = projectIcon(named: project.iconFileName) {
                        Image(nsImage: icon)
                            .resizable()
                            .renderingMode(.original)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "shippingbox")
                            .frame(width: 22, height: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                        if let lastUpdatedAt = runner.lastUpdatedAt {
                            Text(Self.relativeTimeString(lastUpdatedAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    resultBadge
                    Text(runner.status.label)
                        .font(.caption)
                        .foregroundColor(runner.status.color)
                    Button {
                        runner.run(repoPath: project.repoPath, postPullCommand: project.postPullCommand)
                    } label: {
                        if runner.status == .running {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(runner.status == .running)
                }

                if runner.status == .running {
                    progressArea
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // 実行中だけ出す進捗表示。前回の所要時間が分かっていればプログレスバーと
    // 「残り約◯分◯秒」を、分かっていなければ(初回実行など)計測中である旨だけ出す。
    @ViewBuilder
    private var progressArea: some View {
        if let progress = runner.progress {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress)
                if let remaining = runner.estimatedRemaining {
                    Text("残り約 \(Self.durationString(remaining))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } else {
            Text("初回実行のため所要時間を計測中…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded()), 0)
        if totalSeconds < 60 {
            return "\(totalSeconds)秒"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes)分" : "\(minutes)分\(seconds)秒"
    }

    // 「待機中」でも前回アップデートできたかが一目で分かるよう、
    // 直近の実行結果(成功/失敗)を小さいバッジで常に出す。
    @ViewBuilder
    private var resultBadge: some View {
        if runner.status != .running, let lastResult = runner.lastResult {
            Image(systemName: lastResult == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(lastResult == .success ? .green : .red)
                .font(.caption)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter
    }()

    // 更新直後は Date() の取得タイミングの誤差で「0秒後」のような
    // 未来形になってしまうことがあるため、ごく短い時間差は特別扱いする。
    private static func relativeTimeString(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 2 {
            return "たった今"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

