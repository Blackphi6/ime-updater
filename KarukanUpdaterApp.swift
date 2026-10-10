import SwiftUI
import AppKit

@main
struct KarukanUpdaterApp: App {
    @StateObject private var viewModel = UpdaterViewModel()

    var body: some Scene {
        MenuBarExtra {
            UpdaterView(viewModel: viewModel)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("Karukan Updater", id: "main") {
            UpdaterView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}

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
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }
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

@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published var status: UpdateStatus = .idle
    @Published var log: String = ""
    @Published var repoPath: String {
        didSet { UserDefaults.standard.set(repoPath, forKey: Self.repoPathKey) }
    }

    private static let repoPathKey = "repoPath"
    private static let defaultRepoPath = ("~/karukan" as NSString).expandingTildeInPath

    init() {
        repoPath = UserDefaults.standard.string(forKey: Self.repoPathKey) ?? Self.defaultRepoPath
    }

    // ログインシェル (-l) で起動し、.zprofile 等で設定された PATH
    // (Homebrew 等) を確実に読み込む。環境依存の "command not found" を防ぐため。
    // make install が内部で既に KarukanIME を kill するため、ここでの再 kill は
    // 対象プロセスなしで失敗しうる。exit code を潰して全体の成否に影響させない。
    // シェルに展開させず単一引数として渡すため、パスは変数展開なしで直接埋め込む。
    private var script: String {
        let escapedPath = repoPath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        cd '\(escapedPath)' && git pull origin main && cd karukan-im/macos && make install && (killall KarukanIME 2>/dev/null || true)
        """
    }

    private var runningProcess: Process?

    func runUpdate() {
        guard status != .running else { return }
        status = .running
        log = ""

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

struct UpdaterView: View {
    @ObservedObject var viewModel: UpdaterViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Karukan Updater")
                    .font(.headline)
                Spacer()
                Text(viewModel.status.label)
                    .font(.caption)
                    .foregroundColor(viewModel.status.color)
            }

            Button("ウィンドウで開く") {
                openWindow(id: "main")
            }
            .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text("リポジトリのパス")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("例: ~/karukan", text: $viewModel.repoPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(viewModel.status == .running)
            }

            Button(action: viewModel.runUpdate) {
                if viewModel.status == .running {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("アップデート中...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("アップデートを実行")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(viewModel.status == .running)

            ScrollView {
                Text(viewModel.log.isEmpty ? "ログはここに表示されます" : viewModel.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(width: 320)
    }
}
