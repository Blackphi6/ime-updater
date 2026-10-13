import SwiftUI
import AppKit

@main
struct IMEUpdaterApp: App {
    @StateObject private var appViewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            RootView(appViewModel: appViewModel)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("IME Updater", id: "main") {
            RootView(appViewModel: appViewModel)
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
            Image(systemName: "textformat")
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

enum UpdateStatus: Equatable {
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
    private var runningProcess: Process?

    // ログインシェル (-l) で起動し、.zprofile 等で設定された PATH
    // (Homebrew, dotnet 等) を確実に読み込む。環境依存の "command not found" を防ぐため。
    // シェルに展開させず単一引数として渡すため、パスは変数展開なしで直接埋め込む。
    func run(repoPath: String, postPullCommand: String) {
        guard status != .running else { return }
        status = .running
        log = ""

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
                self?.status = finished.terminationStatus == 0 ? .success : .error
                self?.runningProcess = nil
            }
        }

        do {
            try process.run()
            runningProcess = process
        } catch {
            log += "起動に失敗しました: \(error.localizedDescription)\n"
            status = .error
        }
    }

    private func forwardOutput(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        log += text
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
        let runner = ProjectRunner()
        runners[project.id] = runner
        return runner
    }

    func addProject(name: String, repoPath: String, postPullCommand: String) {
        projects.append(UpdateProject(name: name, repoPath: repoPath, postPullCommand: postPullCommand))
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

struct RootView: View {
    @ObservedObject var appViewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IME Updater")
                    .font(.headline)
                Spacer()
                Button("ウィンドウで開く") {
                    openWindow(id: "main")
                }
                .font(.caption)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($appViewModel.projects) { $project in
                        ProjectRow(
                            project: $project,
                            runner: appViewModel.runner(for: project),
                            onDelete: { appViewModel.removeProject(project) }
                        )
                    }
                }
            }
            .frame(maxHeight: 420)

            Button {
                showingAddSheet = true
            } label: {
                Label("プロジェクトを追加", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }

            Divider()

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(width: 380)
        .sheet(isPresented: $showingAddSheet) {
            AddProjectSheet { name, path, command in
                appViewModel.addProject(name: name, repoPath: path, postPullCommand: command)
            }
        }
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
        } label: {
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
                Text(project.name)
                Spacer()
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
        }
    }
}

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var repoPath = ""
    @State private var postPullCommand = ""

    var onAdd: (String, String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロジェクトを追加")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("名前").font(.caption).foregroundColor(.secondary)
                TextField("例: MyIME", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("リポジトリのパス").font(.caption).foregroundColor(.secondary)
                TextField("例: ~/myime", text: $repoPath)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("git pull 後に実行するコマンド").font(.caption).foregroundColor(.secondary)
                TextField("例: make install", text: $postPullCommand)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("追加") {
                    onAdd(name, repoPath, postPullCommand)
                    dismiss()
                }
                .disabled(name.isEmpty || repoPath.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
