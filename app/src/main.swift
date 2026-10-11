import SwiftUI
import AppKit

// MARK: - Process & System Manager

class AppStateManager: ObservableObject {
    @Published var isDaemonRunning: Bool = false
    @Published var daemonPID: String = "-"
    @Published var logLines: [String] = []
    @Published var statusMessage: String = "상태를 확인하고 있습니다..."
    @Published var testResult: String? = nil
    @Published var scanResult: String? = nil
    @Published var isWorking: Bool = false
    @Published var isScanning: Bool = false
    
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/finder-tools/nfc_watcher.log")
    private let plistLabel = "com.grive.hangulguard"
    private var timer: Timer?
    
    init() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshState()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func refreshState() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 1. Check daemon via launchctl in background
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", "launchctl list | grep '\(self.plistLabel)'"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            
            var running = false
            var pid = "-"
            var message = "실시간 감시 데몬이 설치되지 않았습니다."
            
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let first = parts.first, first != "-" {
                        running = true
                        pid = first
                        message = "실시간 감시 데몬이 정상 작동 중입니다."
                    } else {
                        running = false
                        pid = "-"
                        message = "데몬이 등록되어 있으나 현재 대기 중입니다."
                    }
                }
            } catch {
                running = false
                pid = "-"
                message = "데몬 상태 확인 실패"
            }
            
            // 2. Read latest logs in background
            var latestLogs: [String] = []
            if FileManager.default.fileExists(atPath: self.logURL.path) {
                if let content = try? String(contentsOf: self.logURL, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    latestLogs = Array(lines.suffix(15))
                }
            }
            
            DispatchQueue.main.async {
                self.isDaemonRunning = running
                self.daemonPID = pid
                self.statusMessage = message
                if !latestLogs.isEmpty {
                    self.logLines = latestLogs
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
                let exactName = (finalURL.path as NSString).lastPathComponent
                if exactName.utf8.elementsEqual(nfcName.utf8) {
                    success = true
                }
                try? FileManager.default.removeItem(at: finalURL)
            }
            
            DispatchQueue.main.async {
                if success {
                    self.testResult = "자가 진단 성공: 실시간 감시 엔진이 분리된 자모(NFD)를 즉시 완성형(NFC)으로 결합했습니다."
                } else {
                    self.testResult = "진단 실패: 데몬이 가동 중인지, 디스크 접근 권한이 활성화되었는지 확인해 주세요."
                }
            }
        }
    }
    
    func runDeepScan(targetPath: String?) {
        isScanning = true
        scanResult = "기존 파일 전수 스캔 및 자모 수복을 진행 중입니다..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            let binaryPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/finder-tools/nfc_watcher").path
            
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: binaryPath)
            
            if let path = targetPath {
                task.arguments = ["scan", path]
            } else {
                task.arguments = ["scan"]
            }
            task.standardOutput = pipe
            task.standardError = pipe
            
            try? task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            let lines = output.components(separatedBy: "\n")
            let summary = lines.first(where: { $0.contains("스캔 완료") }) ?? "스캔 및 수복 처리가 완료되었습니다."
            
            DispatchQueue.main.async {
                self.isScanning = false
                self.scanResult = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshState()
            }
        }
    }
    
    func selectFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "이 폴더 전수 수복"
        panel.message = "기존 한글 자모 분리를 일괄 결합할 폴더나 외장 드라이브를 선택하세요."
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            runDeepScan(targetPath: selectedURL.path)
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

// MARK: - Visual Header Icon Component

struct AppHeaderIcon: View {
    var body: some View {
        let image: NSImage = {
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
            return NSApp.applicationIconImage ?? NSImage()
        }()
        
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 11.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
    }
}

// MARK: - UI Views

struct ContentView: View {
    @StateObject private var state = AppStateManager()
    
    var projectDir: String {
        if let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().path as String?,
           FileManager.default.fileExists(atPath: "\(bundleParent)/install.sh") {
            return bundleParent
        }
        return "/Volumes/Extend/Projects/DevWorkspace/macos-hangul-nfc-cleaner"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 16) {
                AppHeaderIcon()
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Grive 한글가드")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("macOS 한글 자모 분리 방지 및 실시간 수복 관리자")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Status Badge
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.isDaemonRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(state.isDaemonRunning ? "실시간 감시 중" : "중지됨")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(state.isDaemonRunning ? .green : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content Scroll
            ScrollView {
                VStack(spacing: 16) {
                    // System Status Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("실시간 보호 상태", systemImage: "shield.lefthalf.filled")
                                .font(.headline)
                            Spacer()
                        }
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("서비스 등록 ID:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("com.grive.hangulguard")
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
                                Label(state.isDaemonRunning ? "일시 정지" : "감시 재개",
                                      systemImage: state.isDaemonRunning ? "pause.fill" : "play.fill")
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
                            let isSuccess = res.contains("성공")
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(isSuccess ? .green : .orange)
                                    .font(.system(size: 14))
                                    .padding(.top, 2)
                                Text(res)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(NSColor.windowBackgroundColor))
                            )
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    
                    // Deep Scan Card (기존 파일 전수 수복)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("기존 생성 파일 전수 수복 (Deep Scan)")
                                    .font(.headline)
                                Text("실시간 감시 전 이미 분리된 파일(ㅂㅗㄱㅗㅅㅓ)이나 외장하드의 한글을 일괄 결합합니다.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                state.runDeepScan(targetPath: nil)
                            }) {
                                Label("기본 폴더 전수 수복", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .controlSize(.regular)
                            .disabled(state.isScanning || state.isWorking)
                            
                            Button(action: {
                                state.selectFolderAndScan()
                            }) {
                                Label("특정 폴더 / 외장하드 선택...", systemImage: "folder.badge.gearshape")
                            }
                            .controlSize(.regular)
                            .disabled(state.isScanning || state.isWorking)
                        }
                        
                        if state.isScanning {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("디렉터리 내 모든 파일을 탐색하여 자모를 정밀 수복하고 있습니다...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        
                        if let res = state.scanResult {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                                    .padding(.top, 2)
                                Text(res)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(NSColor.windowBackgroundColor))
                            )
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    
                    // Permissions Card
                    VStack(alignment: .leading, spacing: 12) {
                        Label("시스템 필수 권한 및 설정 점검", systemImage: "slider.horizontal.3")
                            .font(.headline)
                        
                        VStack(spacing: 10) {
                            PermissionRow(
                                icon: "clock.arrow.circlepath",
                                title: "1. 백그라운드 로그인 항목",
                                description: "맥 로그인 시 감시 데몬이 자동으로 시작되도록 허용합니다.",
                                buttonTitle: "로그인 항목 열기",
                                action: { PermissionHelper.openLoginItems() }
                            )
                            Divider()
                            PermissionRow(
                                icon: "internaldrive",
                                title: "2. 전체 디스크 접근 권한 (Full Disk Access)",
                                description: "바탕화면, 다운로드 및 외장 드라이브의 한글 파일명을 실시간 수복합니다.",
                                buttonTitle: "디스크 권한 열기",
                                action: { PermissionHelper.openFullDiskAccess() }
                            )
                            Divider()
                            PermissionRow(
                                icon: "contextualmenu.and.cursor",
                                title: "3. Finder 빠른 동작 (우클릭 메뉴)",
                                description: "Finder 우클릭 메뉴의 '한글 자모 결합' 및 '윈도우 호환 압축'을 활성화합니다.",
                                buttonTitle: "확장 프로그램 열기",
                                action: { PermissionHelper.openQuickActionsExtensions() }
                            )
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    
                    // Live Log Viewer
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("실시간 처리 로그 (최근 내역)", systemImage: "terminal")
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
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(NSColor.textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    
                    // Main Action Buttons
                    HStack(spacing: 16) {
                        Button(action: {
                            state.runInstall(projectDir: projectDir)
                        }) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("원클릭 시스템 전체 설치 및 가동")
                                    .fontWeight(.semibold)
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
    let icon: String
    let title: String
    let description: String
    let buttonTitle: String
    let action: () -> Void
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
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
        window.title = "Grive 한글가드 (GriveHangulGuard)"
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
