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
    func run(repoPath: String, postPullCommand: String) {
        guard status != .running else { return }
        status = .running
        log = ""
        startProgressTracking()

        let escapedPath = repoPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "cd '\(escapedPath)' && git pull && \(postPullCommand)"

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
                self.status = result
                self.runningProcess = nil
                self.stopProgressTracking(success: result == .success)
                self.recordResult(result)
                self.notifyCompletion(result: result)
            }
        }

        do {
            try process.run()
            runningProcess = process
        } catch {
            log += "起動に失敗しました: \(error.localizedDescription)\n"
            status = .error
            stopProgressTracking(success: false)
            recordResult(.error)
            notifyCompletion(result: .error)
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

// MARK: - 全体の管理(プロジェクト一覧の永続化)

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projects: [UpdateProject] {
        didSet { save() }
    }
    private var runners: [UUID: ProjectRunner] = [:]

    private static let storageKey = "projects"

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
            postPullCommand: "bash mac/update.sh",
            iconFileName: "MeltypeIcon"
        ),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([UpdateProject].self, from: data),
           !decoded.isEmpty {
            projects = decoded
        } else {
            projects = Self.defaultProjects
        }
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
            ProjectListView(appViewModel: appViewModel)
                .padding(.top, 10)

            Divider()

            QuitButton()
                .padding(10)
        }
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 420, minHeight: 120)
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

    private static let rowHeight: CGFloat = 50
    private static let maxVisibleRows: CGFloat = 6

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
        .frame(maxHeight: min(CGFloat(appViewModel.projects.count), Self.maxVisibleRows) * Self.rowHeight + 24)
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
                    Text("リポジトリのパス")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("例: ~/karukan", text: $project.repoPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .disabled(runner.status == .running)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("git pull 後に実行するコマンド")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("例: make install", text: $project.postPullCommand)
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

