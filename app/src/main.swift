import SwiftUI
import AppKit
import SQLite3

// MARK: - Models

struct AuditEntry: Identifiable, Hashable {
    let id: Int
    let sessionId: String?
    let sourceType: String
    let originalPath: String
    let originalName: String
    let targetPath: String
    let targetName: String
    let status: String // "SUCCESS", "FAILED", "DRY_RUN"
    let errorReason: String?
    let timestamp: String
}

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
    
    // Audit Ledger state
    @Published var auditRecords: [AuditEntry] = []
    @Published var totalSuccessCount: Int = 0
    @Published var totalFailedCount: Int = 0
    @Published var auditFilter: String = "ALL" // "ALL", "FAILED", "SUCCESS"
    
    // Live Scan Streaming Progress State
    @Published var scanPhaseText: String = "대기 중"
    @Published var scanCurrent: Int = 0
    @Published var scanTotal: Int = 0
    @Published var scanFixedCount: Int = 0
    @Published var scanFailCount: Int = 0
    @Published var scanCurrentPath: String = ""
    @Published var liveConvertedItems: [String] = []
    
    private var currentScanProcess: Process?
    
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/finder-tools/nfc_watcher.log")
    private let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/finder-tools/hangul_guard.db").path
    private let plistLabel = "com.grive.hangulguard"
    private var timer: Timer?
    
    init() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshState()
            self?.refreshAuditDB()
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
    
    func refreshAuditDB() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard FileManager.default.fileExists(atPath: self.dbPath) else { return }
            
            var db: OpaquePointer?
            if sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                return
            }
            defer { sqlite3_close(db) }
            
            // 1. Get counts
            var successCount = 0
            var failCount = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT status, COUNT(*) FROM audit_records GROUP BY status;", -1, &countStmt, nil) == SQLITE_OK {
                while sqlite3_step(countStmt) == SQLITE_ROW {
                    let st = String(cString: sqlite3_column_text(countStmt, 0))
                    let cnt = sqlite3_column_int(countStmt, 1)
                    if st == "SUCCESS" { successCount = Int(cnt) }
                    if st == "FAILED" { failCount = Int(cnt) }
                }
            }
            sqlite3_finalize(countStmt)
            
            // 2. Fetch latest records
            var records = [AuditEntry]()
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, session_id, source_type, original_path, original_name, target_path, target_name, status, error_reason, timestamp
            FROM audit_records 
            ORDER BY id DESC 
            LIMIT 150;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int(stmt, 0)
                    let sid = sqlite3_column_text(stmt, 1) != nil ? String(cString: sqlite3_column_text(stmt, 1)) : nil
                    let source = String(cString: sqlite3_column_text(stmt, 2))
                    let origPath = String(cString: sqlite3_column_text(stmt, 3))
                    let origName = String(cString: sqlite3_column_text(stmt, 4))
                    let targetPath = String(cString: sqlite3_column_text(stmt, 5))
                    let targetName = String(cString: sqlite3_column_text(stmt, 6))
                    let status = String(cString: sqlite3_column_text(stmt, 7))
                    let err = sqlite3_column_text(stmt, 8) != nil ? String(cString: sqlite3_column_text(stmt, 8)) : nil
                    let time = sqlite3_column_text(stmt, 9) != nil ? String(cString: sqlite3_column_text(stmt, 9)) : ""
                    
                    records.append(AuditEntry(
                        id: Int(id),
                        sessionId: sid,
                        sourceType: source,
                        originalPath: origPath,
                        originalName: origName,
                        targetPath: targetPath,
                        targetName: targetName,
                        status: status,
                        errorReason: err,
                        timestamp: time
                    ))
                }
            }
            sqlite3_finalize(stmt)
            
            DispatchQueue.main.async {
                self.totalSuccessCount = successCount
                self.totalFailedCount = failCount
                self.auditRecords = records
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
                self.refreshAuditDB()
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
                self.refreshAuditDB()
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
            self.refreshAuditDB()
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
                self.refreshAuditDB()
            }
        }
    }
    
    func cancelScan() {
        if let proc = currentScanProcess, proc.isRunning {
            proc.terminate()
            currentScanProcess = nil
            scanPhaseText = "스캔이 사용자에 의해 안전하게 중단되었습니다."
            isScanning = false
            refreshState()
            refreshAuditDB()
        }
    }
    
    func runDeepScan(targetPath: String?) {
        isScanning = true
        scanResult = nil
        scanPhaseText = "1단계: 디렉터리 내 파일 탐색 및 인덱싱 중..."
        scanCurrent = 0
        scanTotal = 0
        scanFixedCount = 0
        scanFailCount = 0
        scanCurrentPath = ""
        liveConvertedItems = []
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let binaryPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/finder-tools/nfc_watcher").path
            
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: binaryPath)
            
            var args = ["scan", "--gui-progress"]
            if let path = targetPath {
                args.append(path)
            }
            task.arguments = args
            task.standardOutput = pipe
            task.standardError = pipe
            self.currentScanProcess = task
            
            var lineBuffer = ""
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self = self else { return }
                if let chunk = String(data: data, encoding: .utf8) {
                    lineBuffer += chunk
                    while let newlineRange = lineBuffer.range(of: "\n") {
                        let rawLine = String(lineBuffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        lineBuffer.removeSubrange(..<newlineRange.upperBound)
                        self.parseStreamLine(rawLine)
                    }
                }
            }
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.scanResult = "스캔 실행 실패: \(error.localizedDescription)"
                }
            }
            
            pipe.fileHandleForReading.readabilityHandler = nil
            
            DispatchQueue.main.async {
                self.isScanning = false
                self.currentScanProcess = nil
                self.refreshState()
                self.refreshAuditDB()
            }
        }
    }
    
    private func parseStreamLine(_ line: String) {
        guard line.hasPrefix("[STREAM:") && line.hasSuffix("]") else { return }
        let payload = String(line.dropFirst("[STREAM:".count).dropLast(1))
        let parts = payload.components(separatedBy: ":")
        guard let command = parts.first else { return }
        
        DispatchQueue.main.async {
            switch command {
            case "COLLECT":
                if parts.count >= 3 {
                    let count = Int(parts[1]) ?? 0
                    let path = parts.dropFirst(2).joined(separator: ":")
                    self.scanPhaseText = "1단계: 파일 수집 중 (\(count)개 발견)..."
                    self.scanCurrentPath = path
                }
            case "COLLECT_DONE":
                if parts.count >= 2 {
                    let total = Int(parts[1]) ?? 0
                    self.scanTotal = total
                    self.scanPhaseText = "2단계: 자모 분석 및 수복 중 (총 \(total)개)..."
                }
            case "PROGRESS":
                if parts.count >= 6 {
                    let curr = Int(parts[1]) ?? 0
                    let tot = Int(parts[2]) ?? 0
                    let fixed = Int(parts[3]) ?? 0
                    let failed = Int(parts[4]) ?? 0
                    let path = parts.dropFirst(5).joined(separator: ":")
                    
                    self.scanCurrent = curr
                    self.scanTotal = tot
                    self.scanFixedCount = fixed
                    self.scanFailCount = failed
                    self.scanCurrentPath = path
                    
                    let pct = tot > 0 ? Int((Double(curr) / Double(tot)) * 100.0) : 0
                    self.scanPhaseText = "2단계: 정밀 수복 중 \(pct)% (\(curr)/\(tot))"
                }
            case "CONVERTED":
                if parts.count >= 3 {
                    let orig = parts[1]
                    let nfc = parts[2]
                    self.liveConvertedItems.insert("✅ '\(orig)' ➔ '\(nfc)'", at: 0)
                    if self.liveConvertedItems.count > 6 {
                        self.liveConvertedItems.removeLast()
                    }
                }
            case "FAILED":
                if parts.count >= 3 {
                    let orig = parts[1]
                    let reason = parts[2]
                    self.liveConvertedItems.insert("❌ '\(orig)': \(reason)", at: 0)
                    if self.liveConvertedItems.count > 6 {
                        self.liveConvertedItems.removeLast()
                    }
                }
            case "DONE":
                if parts.count >= 5 {
                    let dur = parts[1]
                    let tot = parts[2]
                    let fixed = parts[3]
                    let failed = parts[4]
                    self.scanResult = "스캔 완료 (\(dur)초) | 검사: \(tot)개 | 수복 완료: \(fixed)개 | 실패: \(failed)개"
                    self.scanPhaseText = "수복 작업 완료"
                }
            default:
                break
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
    
    var filteredRecords: [AuditEntry] {
        switch state.auditFilter {
        case "FAILED":
            return state.auditRecords.filter { $0.status == "FAILED" }
        case "SUCCESS":
            return state.auditRecords.filter { $0.status == "SUCCESS" }
        default:
            return state.auditRecords
        }
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
                                Text("실시간 감시 전 이미 분리된 파일이나 외장하드의 한글을 일괄 결합하고 장부에 기록합니다.")
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
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(state.scanPhaseText)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    if state.scanTotal > 0 {
                                        Text("\(state.scanCurrent) / \(state.scanTotal)개 (\(Int((Double(state.scanCurrent) / Double(max(state.scanTotal, 1))) * 100))%)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                if state.scanTotal > 0 {
                                    ProgressView(value: Double(state.scanCurrent), total: Double(max(state.scanTotal, 1)))
                                        .progressViewStyle(.linear)
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }
                                
                                HStack(spacing: 8) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("수복: \(state.scanFixedCount)건")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.12)))
                                    
                                    HStack(spacing: 4) {
                                        Image(systemName: state.scanFailCount > 0 ? "xmark.octagon.fill" : "checkmark.seal")
                                            .foregroundColor(state.scanFailCount > 0 ? .red : .secondary)
                                        Text("실패: \(state.scanFailCount)건")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(state.scanFailCount > 0 ? .red : .secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(state.scanFailCount > 0 ? Color.red.opacity(0.12) : Color.primary.opacity(0.04)))
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        state.cancelScan()
                                    }) {
                                        Label("스캔 중단", systemImage: "stop.circle")
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                }
                                
                                if !state.scanCurrentPath.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(state.scanCurrentPath)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                
                                if !state.liveConvertedItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("실시간 수복 라이브 피드 (최근 항목)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        ForEach(state.liveConvertedItems, id: \.self) { item in
                                            Text(item)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color(NSColor.textBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                                    )
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.7))
                            )
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
                    
                    // Audit Ledger & Failure Tracker Card (Local DB)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            Label("수복 이력 및 실패 감사 장부 (Local DB)", systemImage: "tray.full.fill")
                                .font(.headline)
                            Spacer()
                            Button(action: {
                                state.refreshAuditDB()
                            }) {
                                Label("장부 새로고침", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                        }
                        
                        Text("어느 파일이 수복되었고, 어디서 권한 부족/잠금으로 실패했는지 즉시 확인하고 위치를 엽니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Summary Metrics & Filter Bar
                        HStack(spacing: 10) {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("수복 성공 \(state.totalSuccessCount)건")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.green.opacity(0.12))
                            )
                            
                            HStack(spacing: 5) {
                                Image(systemName: state.totalFailedCount > 0 ? "xmark.octagon.fill" : "checkmark.seal")
                                    .foregroundColor(state.totalFailedCount > 0 ? .red : .secondary)
                                Text("실패/미수복 \(state.totalFailedCount)건")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(state.totalFailedCount > 0 ? .red : .secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(state.totalFailedCount > 0 ? Color.red.opacity(0.12) : Color.primary.opacity(0.05))
                            )
                            
                            Spacer()
                            
                            Picker("", selection: $state.auditFilter) {
                                Text("전체").tag("ALL")
                                Text("실패만 (\(state.totalFailedCount))").tag("FAILED")
                                Text("성공만 (\(state.totalSuccessCount))").tag("SUCCESS")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        
                        // Audit Records Scroll List
                        ScrollView {
                            VStack(spacing: 8) {
                                if filteredRecords.isEmpty {
                                    VStack(spacing: 6) {
                                        Image(systemName: state.auditFilter == "FAILED" ? "checkmark.shield" : "tray")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                        Text(state.auditFilter == "FAILED" ? "권한 부족 또는 실패로 미수복된 파일이 없습니다! (전체 무결성 확보)" : "아직 기록된 수복 내역이 없습니다.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                } else {
                                    ForEach(filteredRecords) { entry in
                                        AuditRowView(entry: entry)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 190)
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
                        .frame(height: 110)
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
        .frame(width: 720, height: 760)
    }
}

// MARK: - Audit Row View

struct AuditRowView: View {
    let entry: AuditEntry
    
    var isSuccess: Bool {
        entry.status == "SUCCESS"
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundColor(isSuccess ? .green : .red)
                .font(.system(size: 15))
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    if isSuccess {
                        Text(entry.originalName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(entry.targetName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    } else {
                        Text(entry.originalName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.red)
                    }
                    
                    Spacer()
                    
                    Text("[\(entry.sourceType)] \(formatTimestamp(entry.timestamp))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                if let err = entry.errorReason, !err.isEmpty {
                    Text("사유: \(err)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                }
                
                Text(entry.originalPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Button("Finder에서 보기") {
                let targetToOpen = isSuccess ? entry.targetPath : entry.originalPath
                NSWorkspace.shared.selectFile(targetToOpen, inFileViewerRootedAtPath: "")
            }
            .controlSize(.mini)
            .padding(.top, 2)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSuccess ? Color.clear : Color.red.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSuccess ? Color.primary.opacity(0.04) : Color.red.opacity(0.2), lineWidth: 0.5)
        )
    }
    
    private func formatTimestamp(_ iso: String) -> String {
        if iso.count >= 19 {
            let sub = String(iso.prefix(19)).replacingOccurrences(of: "T", with: " ")
            return sub
        }
        return iso
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
