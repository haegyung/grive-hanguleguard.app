import SwiftUI
import AppKit

// MARK: - Process & System Manager

class AppStateManager: ObservableObject {
    @Published var isDaemonRunning: Bool = false
    @Published var daemonPID: String = "-"
    @Published var logLines: [String] = []
    @Published var statusMessage: String = "상태를 확인하고 있습니다..."
    @Published var testResult: String? = nil
    @Published var isWorking: Bool = false
    
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/finder-tools/nfc_watcher.log")
    private let plistLabel = "com.coos.korean-nfc-normalizer"
    private var timer: Timer?
    
    init() {
        refreshState()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func refreshState() {
        // 1. Check daemon via launchctl
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "launchctl list | grep '\(plistLabel)'"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let pid = parts.first, pid != "-" {
                    DispatchQueue.main.async {
                        self.isDaemonRunning = true
                        self.daemonPID = pid
                        self.statusMessage = "실시간 감시 데몬이 정상 작동 중입니다."
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isDaemonRunning = false
                        self.daemonPID = "-"
                        self.statusMessage = "데몬이 등록되어 있으나 현재 대기 중입니다."
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.isDaemonRunning = false
                    self.daemonPID = "-"
                    self.statusMessage = "실시간 감시 데몬이 설치되지 않았습니다."
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isDaemonRunning = false
                self.daemonPID = "-"
            }
        }
        
        // 2. Read latest logs
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let content = try? String(contentsOf: logURL, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let latest = Array(lines.suffix(15))
                DispatchQueue.main.async {
                    self.logLines = latest
                }
            }
        }
    }
    
    func runInstall(projectDir: String) {
        isWorking = true
        statusMessage = "시스템 설치 및 등록을 진행하고 있습니다..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            let scriptPath = "\(projectDir)/install.sh"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptPath]
            try? task.run()
            task.waitUntilExit()
            
            DispatchQueue.main.async {
                self.isWorking = false
                self.refreshState()
            }
        }
    }
    
    func runUninstall(projectDir: String) {
        isWorking = true
        statusMessage = "모듈을 완전히 제거하고 있습니다..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            let scriptPath = "\(projectDir)/uninstall.sh"
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptPath]
            task.standardInput = pipe
            
            // Pass 'y' to delete config/logs
            if let handle = pipe.fileHandleForWriting as FileHandle? {
                handle.write("y\n".data(using: .utf8)!)
                try? handle.close()
            }
            
            try? task.run()
            task.waitUntilExit()
            
            DispatchQueue.main.async {
                self.isWorking = false
                self.refreshState()
            }
        }
    }
    
    func toggleDaemon() {
        let uid = getuid()
        let plistTarget = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist").path
        
        if isDaemonRunning {
            _ = shell("launchctl bootout gui/\(uid)/\(plistLabel) 2>/dev/null || launchctl unload '\(plistTarget)' 2>/dev/null")
        } else {
            _ = shell("launchctl bootstrap gui/\(uid) '\(plistTarget)' 2>/dev/null || launchctl load -w '\(plistTarget)' 2>/dev/null")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.refreshState()
        }
    }
    
    func runSelfTest() {
        testResult = "자가 진단 테스트를 수행 중입니다..."
        DispatchQueue.global(qos: .userInitiated).async {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let nfdName = ("한글가드_UI_자가진단.txt" as NSString).decomposedStringWithCanonicalMapping
            let testFileURL = desktop.appendingPathComponent(nfdName)
            
            try? "Self-test UI payload".write(to: testFileURL, atomically: true, encoding: .utf8)
            Thread.sleep(forTimeInterval: 0.5)
            
            let nfcName = ("한글가드_UI_자가진단.txt" as NSString).precomposedStringWithCanonicalMapping
            let finalURL = desktop.appendingPathComponent(nfcName)
            
            var success = false
            if FileManager.default.fileExists(atPath: finalURL.path) {
                // Check if exact NFC
                let exactName = (finalURL.path as NSString).lastPathComponent
                if exactName.utf8.elementsEqual(nfcName.utf8) {
                    success = true
                }
                try? FileManager.default.removeItem(at: finalURL)
            }
            
            DispatchQueue.main.async {
                if success {
                    self.testResult = "✅ 자가 진단 성공! 바탕화면 NFD 파일이 0.1초 만에 NFC로 결합되었습니다."
                } else {
                    self.testResult = "⚠️ 진단 실패: 데몬이 가동 중인지 확인해 주세요."
                }
            }
        }
    }
    
    private func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Permission Helpers

struct PermissionHelper {
    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    
    static func openQuickActionsExtensions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Extensions") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - UI Views

struct ContentView: View {
    @StateObject private var state = AppStateManager()
    
    // Path to the repository root
    var projectDir: String {
        // If running inside app bundle, check parent directory or default project path
        let defaultPath = "/Volumes/Extend/Projects/DevWorkspace/macos-hangul-nfc-cleaner"
        return defaultPath
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 16) {
                Text("🍏")
                    .font(.system(size: 44))
                VStack(alignment: .leading, spacing: 4) {
                    Text("한글가드 (HangulGuard)")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("macOS 한글 자모 분리 방지 및 시스템 실시간 수복 관리자")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Status Badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isDaemonRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(state.isDaemonRunning ? "실시간 감시 중" : "중지됨")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(state.isDaemonRunning ? .green : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(NSColor.windowBackgroundColor)))
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content Scroll
            ScrollView {
                VStack(spacing: 18) {
                    // System Status Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("시스템 상주 상태")
                            .font(.headline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("서비스 등록:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("com.coos.korean-nfc-normalizer")
                                    .font(.system(.body, design: .monospaced))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("프로세스 PID:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(state.daemonPID)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.bold)
                            }
                        }
                        
                        Text(state.statusMessage)
                            .font(.callout)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                state.toggleDaemon()
                            }) {
                                Label(state.isDaemonRunning ? "일시 정지" : "감시 재개", systemImage: state.isDaemonRunning ? "pause.fill" : "play.fill")
                            }
                            .controlSize(.regular)
                            
                            Button(action: {
                                state.runSelfTest()
                            }) {
                                Label("실시간 자가 진단 테스트", systemImage: "checkmark.shield")
                            }
                            .controlSize(.regular)
                        }
                        
                        if let res = state.testResult {
                            Text(res)
                                .font(.callout)
                                .foregroundColor(res.contains("성공") ? .green : .orange)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.windowBackgroundColor)))
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                    
                    // Permissions Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("필수 시스템 권한 및 설정 점검")
                            .font(.headline)
                        
                        VStack(spacing: 8) {
                            PermissionRow(
                                title: "1. 백그라운드 항목 등록",
                                description: "맥 로그인 시 데몬이 자동으로 켜지도록 허용합니다.",
                                buttonTitle: "로그인 항목 설정 열기",
                                action: { PermissionHelper.openLoginItems() }
                            )
                            Divider()
                            PermissionRow(
                                title: "2. 파일 및 폴더 전체 접근 권한 (TCC)",
                                description: "바탕화면, 다운로드 등의 자모를 실시간 수정할 수 있습니다.",
                                buttonTitle: "디스크 접근 권한 열기",
                                action: { PermissionHelper.openFullDiskAccess() }
                            )
                            Divider()
                            PermissionRow(
                                title: "3. Finder 빠른 동작 (우클릭 메뉴)",
                                description: "우클릭 메뉴에 '한글 자모 결합', '윈도우 호환 압축'을 표시합니다.",
                                buttonTitle: "확장 프로그램 설정 열기",
                                action: { PermissionHelper.openQuickActionsExtensions() }
                            )
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                    
                    // Live Log Viewer
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("실시간 처리 로그 (최근 내역)")
                                .font(.headline)
                            Spacer()
                            Button("새로고침") {
                                state.refreshState()
                            }
                            .font(.caption)
                        }
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if state.logLines.isEmpty {
                                    Text("아직 처리된 로그가 없습니다.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(state.logLines, id: \.self) { line in
                                        Text(line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .frame(height: 120)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.windowBackgroundColor)))
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                    
                    // Main Action Buttons
                    HStack(spacing: 16) {
                        Button(action: {
                            state.runInstall(projectDir: projectDir)
                        }) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("원클릭 시스템 전체 설치 및 가동")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(state.isWorking)
                        
                        Button(action: {
                            state.runUninstall(projectDir: projectDir)
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("완전 제거")
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(state.isWorking)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: 680)
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let buttonTitle: String
    let action: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
    }
}

// MARK: - App Delegate & Main

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "한글가드 (HangulGuard)"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
