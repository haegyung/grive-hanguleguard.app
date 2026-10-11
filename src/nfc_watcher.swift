import Foundation
import CoreServices
import Darwin
import SQLite3

// ==============================================================================
// macos-hangul-nfc-cleaner: Universal Native Swift Engine
// - POSIX C-level rename() to bypass Cocoa URL NFD decomposition
// - Mode 1 (daemon): Real-time FSEvents watcher with crash recovery & file stability
// - Mode 2 (fix): Batch recursive Hangul Jamo normalizer for selected paths
// - Mode 3 (scan): Deep recursive scanner with persistent SQLite audit ledger
// - Mode 4 (zip): Windows-compatible clean ZIP compressor using native ditto
// - Mode 5 (history/failures): Local DB query & failure tracking CLI
// ==============================================================================

let fm = FileManager.default
let homeURL = fm.homeDirectoryForCurrentUser

let logDir = homeURL.appendingPathComponent(".local/state/finder-tools")
let logFileURL = logDir.appendingPathComponent("nfc_watcher.log")
let dbFileURL = logDir.appendingPathComponent("hangul_guard.db")

let configDir = homeURL.appendingPathComponent(".config/finder-tools")
let configFileURL = configDir.appendingPathComponent("watcher_config.json")

let excludePrefixes = [".__nfc_tmp_", "._", ".DS_Store"]
let excludeExtensions = Set(["crdownload", "download", "part", "tmp", "swp"])
let excludeDirNames = Set([".git", "node_modules", ".venv", "__pycache__"])

// MARK: - Logging & Notifications

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) [GRIVE-HANGUL-GUARD] \(message)\n"
    fputs(line, stderr)
    
    if let data = line.data(using: .utf8) {
        if fm.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            try? data.write(to: logFileURL)
        }
    }
}

func showNotification(title: String, subtitle: String, message: String = "") {
    let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedSubtitle = subtitle.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
    
    let script = "display notification \"\(escapedMessage)\" with title \"\(escapedTitle)\" subtitle \"\(escapedSubtitle)\""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try? task.run()
}

// MARK: - Native SQLite3 Audit Database

final class AuditDatabase {
    static let shared = AuditDatabase()
    private var db: OpaquePointer?
    private let lock = NSLock()
    
    private init() {
        open()
        createTables()
    }
    
    deinit {
        close()
    }
    
    private func open() {
        let path = dbFileURL.path
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        if sqlite3_open(path, &db) != SQLITE_OK {
            log("Failed to open SQLite database at \(path)")
            db = nil
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
    }
    
    private func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    private func createTables() {
        guard let db = db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS scan_sessions (
            session_id TEXT PRIMARY KEY,
            target_path TEXT,
            total_scanned INTEGER DEFAULT 0,
            total_converted INTEGER DEFAULT 0,
            total_failed INTEGER DEFAULT 0,
            is_dry_run INTEGER DEFAULT 0,
            start_time TEXT,
            end_time TEXT,
            duration_sec REAL DEFAULT 0.0
        );
        CREATE TABLE IF NOT EXISTS audit_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            source_type TEXT,
            original_path TEXT,
            original_name TEXT,
            target_path TEXT,
            target_name TEXT,
            status TEXT,
            error_reason TEXT,
            timestamp TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_audit_status ON audit_records(status);
        CREATE INDEX IF NOT EXISTS idx_audit_session ON audit_records(session_id);
        CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_records(timestamp);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }
    
    func startSession(targetPath: String, isDryRun: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let sessionId = UUID().uuidString
        guard let db = db else { return sessionId }
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = "INSERT INTO scan_sessions (session_id, target_path, is_dry_run, start_time) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (targetPath as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, isDryRun ? 1 : 0)
            sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return sessionId
    }
    
    func recordAudit(
        sessionId: String?,
        sourceType: String,
        originalPath: String,
        originalName: String,
        targetPath: String,
        targetName: String,
        status: String,
        errorReason: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = db else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO audit_records 
        (session_id, source_type, original_path, original_name, target_path, target_name, status, error_reason, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if let sid = sessionId {
                sqlite3_bind_text(stmt, 1, (sid as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, (sourceType as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (originalPath as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (originalName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (targetPath as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (targetName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 7, (status as NSString).utf8String, -1, nil)
            if let err = errorReason {
                sqlite3_bind_text(stmt, 8, (err as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_text(stmt, 9, (now as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func endSession(sessionId: String, scanned: Int, converted: Int, failed: Int, duration: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = db else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        UPDATE scan_sessions 
        SET total_scanned = ?, total_converted = ?, total_failed = ?, end_time = ?, duration_sec = ?
        WHERE session_id = ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(scanned))
            sqlite3_bind_int(stmt, 2, Int32(converted))
            sqlite3_bind_int(stmt, 3, Int32(failed))
            sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, duration)
            sqlite3_bind_text(stmt, 6, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func getRecentSessions(limit: Int = 10) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        var results = [[String: Any]]()
        guard let db = db else { return results }
        let sql = "SELECT session_id, target_path, total_scanned, total_converted, total_failed, is_dry_run, start_time, duration_sec FROM scan_sessions ORDER BY start_time DESC LIMIT ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sid = String(cString: sqlite3_column_text(stmt, 0))
                let target = String(cString: sqlite3_column_text(stmt, 1))
                let scanned = sqlite3_column_int(stmt, 2)
                let converted = sqlite3_column_int(stmt, 3)
                let failed = sqlite3_column_int(stmt, 4)
                let isDry = sqlite3_column_int(stmt, 5)
                let start = sqlite3_column_text(stmt, 6) != nil ? String(cString: sqlite3_column_text(stmt, 6)) : ""
                let dur = sqlite3_column_double(stmt, 7)
                results.append([
                    "session_id": sid,
                    "target_path": target,
                    "total_scanned": Int(scanned),
                    "total_converted": Int(converted),
                    "total_failed": Int(failed),
                    "is_dry_run": isDry != 0,
                    "start_time": start,
                    "duration_sec": dur
                ])
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
    
    func getFailures(limit: Int = 50) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        var results = [[String: Any]]()
        guard let db = db else { return results }
        let sql = "SELECT id, original_path, original_name, error_reason, timestamp FROM audit_records WHERE status = 'FAILED' ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int(stmt, 0)
                let path = String(cString: sqlite3_column_text(stmt, 1))
                let name = String(cString: sqlite3_column_text(stmt, 2))
                let reason = sqlite3_column_text(stmt, 3) != nil ? String(cString: sqlite3_column_text(stmt, 3)) : "알 수 없는 에러"
                let time = sqlite3_column_text(stmt, 4) != nil ? String(cString: sqlite3_column_text(stmt, 4)) : ""
                results.append([
                    "id": Int(id),
                    "original_path": path,
                    "original_name": name,
                    "error_reason": reason,
                    "timestamp": time
                ])
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
    
    func getOverallStats() -> (totalConverted: Int, totalFailed: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let db = db else { return (0, 0) }
        var successCount = 0
        var failCount = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT status, COUNT(*) FROM audit_records GROUP BY status;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let st = String(cString: sqlite3_column_text(stmt, 0))
                let cnt = sqlite3_column_int(stmt, 1)
                if st == "SUCCESS" { successCount = Int(cnt) }
                if st == "FAILED" { failCount = Int(cnt) }
            }
        }
        sqlite3_finalize(stmt)
        return (successCount, failCount)
    }
}

// MARK: - Unicode & POSIX Crash-Safe 2-Step Rename

func isDecomposed(_ string: String) -> Bool {
    let nfc = (string as NSString).precomposedStringWithCanonicalMapping
    return !string.utf8.elementsEqual(nfc.utf8)
}

func shouldIgnore(path: String) -> Bool {
    let nsPath = path as NSString
    let name = nsPath.lastPathComponent
    for prefix in excludePrefixes {
        if name.hasPrefix(prefix) { return true }
    }
    let ext = nsPath.pathExtension.lowercased()
    if excludeExtensions.contains(ext) {
        return true
    }
    for component in nsPath.pathComponents {
        if excludeDirNames.contains(component) { return true }
    }
    return false
}

func isFileReady(path: String) -> Bool {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
    if isDir.boolValue { return true }
    
    // Check if file is readable and not locked by exclusive write
    let fd = open(path, O_RDONLY | O_NONBLOCK)
    if fd < 0 { return false }
    close(fd)
    return true
}

var processingSet = Set<String>()
let processingLock = NSLock()

enum RenameResult {
    case success(targetName: String, targetPath: String)
    case failed(reason: String)
    case skippedNotDecomposed
    case skippedBusy
    case skippedNotExists
}

func safeRenameToNFCWithResult(
    path: String,
    sessionId: String? = nil,
    sourceType: String = "WATCHER"
) -> RenameResult {
    processingLock.lock()
    if processingSet.contains(path) {
        processingLock.unlock()
        return .skippedBusy
    }
    processingSet.insert(path)
    processingLock.unlock()
    
    defer {
        processingLock.lock()
        processingSet.remove(path)
        processingLock.unlock()
    }
    
    guard fm.fileExists(atPath: path) else { return .skippedNotExists }
    let nsPath = path as NSString
    let originalName = nsPath.lastPathComponent
    guard isDecomposed(originalName) else { return .skippedNotDecomposed }
    
    guard isFileReady(path: path) else {
        log("File not ready yet, deferring: \(originalName)")
        return .skippedBusy
    }
    
    let parent = nsPath.deletingLastPathComponent
    let nfcName = (originalName as NSString).precomposedStringWithCanonicalMapping
    
    let tmpName = ".__nfc_tmp_\(UUID().uuidString)_\(nfcName)"
    let tmpPath = "\(parent)/\(tmpName)"
    let finalPath = "\(parent)/\(nfcName)"
    
    // Step 1: Atomic move to intent-preserving temp journal name
    if rename(path, tmpPath) != 0 {
        let errCode = errno
        let errStr = String(cString: strerror(errCode))
        let reason = "임시 경로 변경 실패: \(errStr) (errno \(errCode))"
        log("Rename step 1 failed for '\(originalName)': \(reason)")
        AuditDatabase.shared.recordAudit(
            sessionId: sessionId,
            sourceType: sourceType,
            originalPath: path,
            originalName: originalName,
            targetPath: finalPath,
            targetName: nfcName,
            status: "FAILED",
            errorReason: reason
        )
        return .failed(reason: reason)
    }
    
    // Step 2: Atomic move to clean NFC final name
    if rename(tmpPath, finalPath) != 0 {
        let errCode = errno
        let errStr = String(cString: strerror(errCode))
        let reason = "완성형 최종 변경 실패: \(errStr) (errno \(errCode))"
        log("Rename step 2 failed for '\(originalName)': \(reason)")
        // Rollback
        rename(tmpPath, path)
        AuditDatabase.shared.recordAudit(
            sessionId: sessionId,
            sourceType: sourceType,
            originalPath: path,
            originalName: originalName,
            targetPath: finalPath,
            targetName: nfcName,
            status: "FAILED",
            errorReason: reason
        )
        return .failed(reason: reason)
    }
    
    log("Normalized: '\(originalName)' -> '\(nfcName)' at \(parent)")
    AuditDatabase.shared.recordAudit(
        sessionId: sessionId,
        sourceType: sourceType,
        originalPath: path,
        originalName: originalName,
        targetPath: finalPath,
        targetName: nfcName,
        status: "SUCCESS",
        errorReason: nil
    )
    return .success(targetName: nfcName, targetPath: finalPath)
}

@discardableResult
func safeRenameToNFC(path: String) -> Bool {
    switch safeRenameToNFCWithResult(path: path, sessionId: nil, sourceType: "WATCHER") {
    case .success: return true
    default: return false
    }
}

// MARK: - Crash Recovery & Sweep

func recoverOrphanTempFiles(at rootPath: String) {
    guard let subpaths = try? fm.subpathsOfDirectory(atPath: rootPath) else { return }
    let prefix = ".__nfc_tmp_"
    for sub in subpaths {
        let name = (sub as NSString).lastPathComponent
        if name.hasPrefix(prefix) {
            let remainder = String(name.dropFirst(prefix.count))
            if let firstUnderscore = remainder.firstIndex(of: "_") {
                let targetName = String(remainder[remainder.index(after: firstUnderscore)...])
                let fullPath = (rootPath as NSString).appendingPathComponent(sub)
                let parentPath = (fullPath as NSString).deletingLastPathComponent
                let finalPath = (parentPath as NSString).appendingPathComponent(targetName)
                if !fm.fileExists(atPath: finalPath) {
                    if rename(fullPath, finalPath) == 0 {
                        log("Crash recovery restored: '\(name)' -> '\(targetName)'")
                        AuditDatabase.shared.recordAudit(
                            sessionId: nil,
                            sourceType: "RECOVERY",
                            originalPath: fullPath,
                            originalName: name,
                            targetPath: finalPath,
                            targetName: targetName,
                            status: "SUCCESS",
                            errorReason: "Crash recovery"
                        )
                    }
                } else {
                    unlink(fullPath)
                    log("Cleaned stale redundant temp file: '\(name)'")
                }
            }
        }
    }
}

@discardableResult
func sweepDirectory(rootPath: String) -> Int {
    recoverOrphanTempFiles(at: rootPath)
    
    let rootURL = URL(fileURLWithPath: rootPath)
    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsPackageDescendants]
    ) else { return 0 }
    
    var collectedPaths = [String]()
    for case let fileURL as URL in enumerator {
        let p = fileURL.path
        if shouldIgnore(path: p) { continue }
        collectedPaths.append(p)
    }
    
    // Bottom-up traversal
    collectedPaths.sort { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }
    var count = 0
    for p in collectedPaths {
        let name = (p as NSString).lastPathComponent
        if isDecomposed(name) {
            if safeRenameToNFC(path: p) {
                count += 1
            }
        }
    }
    return count
}

// MARK: - Subcommand: Fix (Manual Batch Normalizer)

func runFixCommand(args: [String]) {
    guard !args.isEmpty else {
        showNotification(title: "자모 결합 실패", subtitle: "선택된 파일이나 폴더가 없습니다.")
        exit(1)
    }
    
    var totalFixed = 0
    for rawPath in args {
        let path = (rawPath as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: path) else { continue }
        
        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        
        if isDir.boolValue {
            totalFixed += sweepDirectory(rootPath: path)
            let name = (path as NSString).lastPathComponent
            if isDecomposed(name) {
                if safeRenameToNFC(path: path) {
                    totalFixed += 1
                }
            }
        } else {
            let name = (path as NSString).lastPathComponent
            if isDecomposed(name) {
                if safeRenameToNFC(path: path) {
                    totalFixed += 1
                }
            }
        }
    }
    
    if totalFixed > 0 {
        showNotification(
            title: "한글 자모 결합 완료",
            subtitle: "총 \(totalFixed)개 항목 결합됨",
            message: "NFD 자모 분리가 NFC 완성형으로 정상 변환되었습니다."
        )
    } else {
        showNotification(
            title: "한글 자모 확인",
            subtitle: "변환할 항목 없음",
            message: "선택한 모든 파일과 폴더명이 이미 완성형(NFC)입니다."
        )
    }
}

// MARK: - Subcommand: Scan (Deep Recursive Full Normalizer with Audit DB)

func runScanCommand(args: [String]) {
    var isDryRun = false
    var isGuiProgress = false
    var targetPaths = [String]()
    
    for arg in args {
        if arg == "--dry-run" || arg == "-n" {
            isDryRun = true
        } else if arg == "--gui-progress" {
            isGuiProgress = true
        } else {
            targetPaths.append(arg)
        }
    }
    
    if targetPaths.isEmpty {
        targetPaths = loadMonitoredPaths()
    }
    
    if !isGuiProgress {
        print("============================================================")
        print("  🔍 Grive한글가드: 기존 파일 한글 자모 전수 스캔 및 감사 장부 기록")
        if isDryRun {
            print("  ⚠️  [미리보기 모드] 실제 파일명은 변경되지 않습니다.")
        }
        print("  💾 로컬 감사 DB: \(dbFileURL.path)")
        print("============================================================")
    }
    
    var totalScanned = 0
    var totalFixed = 0
    var totalFailed = 0
    let startTime = Date()
    
    for rawPath in targetPaths {
        let path = (rawPath as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: path) else {
            if isGuiProgress {
                print("[STREAM:ERROR:경로가 존재하지 않습니다: \(path)]")
                fflush(stdout)
            } else {
                print("❌ 경로가 존재하지 않습니다: \(path)")
            }
            continue
        }
        
        let sessionId = AuditDatabase.shared.startSession(targetPath: path, isDryRun: isDryRun)
        if !isGuiProgress {
            print("\n📂 대상 디렉터리: \(path) (세션: \(sessionId.prefix(8)))")
        }
        
        if !isDryRun {
            recoverOrphanTempFiles(at: path)
        }
        
        let rootURL = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { continue }
        
        var collected = [String]()
        for case let fileURL as URL in enumerator {
            let p = fileURL.path
            if shouldIgnore(path: p) { continue }
            collected.append(p)
            if isGuiProgress {
                if collected.count % 25 == 0 {
                    print("[STREAM:COLLECT:\(collected.count):\(p)]")
                    fflush(stdout)
                }
            } else {
                if collected.count % 500 == 0 {
                    print("\r  📂 \(collected.count)개 파일 탐색 중...", terminator: "")
                    fflush(stdout)
                }
            }
        }
        
        if isGuiProgress {
            print("[STREAM:COLLECT_DONE:\(collected.count)]")
            fflush(stdout)
        }
        
        // Bottom-up traversal: 자식 파일/폴더를 먼저 처리하여 상위 디렉터리 이름 변경 시 경로 단절 방지
        collected.sort { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }
        
        var sessionScanned = 0
        var sessionFixed = 0
        var sessionFailed = 0
        
        for (idx, p) in collected.enumerated() {
            totalScanned += 1
            sessionScanned += 1
            let name = (p as NSString).lastPathComponent
            
            if isGuiProgress && (idx % 10 == 0 || isDecomposed(name)) {
                print("[STREAM:PROGRESS:\(idx + 1):\(collected.count):\(totalFixed):\(totalFailed):\(p)]")
                fflush(stdout)
            }
            
            if isDecomposed(name) {
                let nfc = (name as NSString).precomposedStringWithCanonicalMapping
                if isDryRun {
                    totalFixed += 1
                    sessionFixed += 1
                    AuditDatabase.shared.recordAudit(
                        sessionId: sessionId,
                        sourceType: "SCAN",
                        originalPath: p,
                        originalName: name,
                        targetPath: "\(NSString(string: p).deletingLastPathComponent)/\(nfc)",
                        targetName: nfc,
                        status: "DRY_RUN",
                        errorReason: nil
                    )
                    if isGuiProgress {
                        print("[STREAM:CONVERTED:\(name):\(nfc):\(p)]")
                        fflush(stdout)
                    } else {
                        print("\r  🔍 [발견] '\(name)' ➔ '\(nfc)'")
                    }
                } else {
                    let result = safeRenameToNFCWithResult(path: p, sessionId: sessionId, sourceType: "SCAN")
                    switch result {
                    case .success:
                        totalFixed += 1
                        sessionFixed += 1
                        if isGuiProgress {
                            print("[STREAM:CONVERTED:\(name):\(nfc):\(p)]")
                            fflush(stdout)
                        } else {
                            print("\r  ✅ [수복] '\(name)' ➔ '\(nfc)'")
                        }
                    case .failed(let reason):
                        totalFailed += 1
                        sessionFailed += 1
                        if isGuiProgress {
                            print("[STREAM:FAILED:\(name):\(reason):\(p)]")
                            fflush(stdout)
                        } else {
                            print("\r  ❌ [실패] '\(name)' (\(reason))")
                        }
                    default:
                        break
                    }
                }
            }
            if !isGuiProgress && idx % 200 == 0 {
                print("\r  🔍 \(totalScanned)/\(collected.count)개 항목 검사 중 (수복: \(totalFixed)건, 실패: \(totalFailed)건)...", terminator: "")
                fflush(stdout)
            }
        }
        
        let sessionDuration = Date().timeIntervalSince(startTime)
        AuditDatabase.shared.endSession(
            sessionId: sessionId,
            scanned: sessionScanned,
            converted: sessionFixed,
            failed: sessionFailed,
            duration: sessionDuration
        )
    }
    
    let duration = String(format: "%.2f", Date().timeIntervalSince(startTime))
    if isGuiProgress {
        print("[STREAM:DONE:\(duration):\(totalScanned):\(totalFixed):\(totalFailed)]")
        fflush(stdout)
    } else {
        print("\n============================================================")
        print("  🎉 스캔 완료 (\(duration)초) | 검사 항목: \(totalScanned)개 | ✅ 수복 완료: \(totalFixed)개 | ❌ 실패: \(totalFailed)개")
        if totalFailed > 0 {
            print("  ⚠️  실패한 항목의 상세 사유는 'nfc_watcher failures' 명령으로 확인하세요.")
        }
        print("============================================================")
    }
    
    if !isDryRun && !isGuiProgress {
        showNotification(
            title: "기존 파일 자모 전수 수복 완료",
            subtitle: "성공: \(totalFixed)건 / 실패: \(totalFailed)건",
            message: "검사 항목: \(totalScanned)개 (소요시간: \(duration)초)"
        )
    }
}

// MARK: - Subcommand: History & Failures (Audit CLI)

func runHistoryCommand() {
    print("════════════════════════════════════════════════════════════════════════════")
    print("  📋 Grive한글가드 최근 스캔 세션 이력 (Local DB)")
    print("  경로: \(dbFileURL.path)")
    print("════════════════════════════════════════════════════════════════════════════")
    
    let sessions = AuditDatabase.shared.getRecentSessions(limit: 15)
    if sessions.isEmpty {
        print("  아직 저장된 스캔 세션이 없습니다.")
        return
    }
    
    print(String(format: "%-10@ %-20@ %-6@ %-6@ %-6@ %-8@ %-30@", "세션ID", "일시", "검사", "성공", "실패", "소요", "대상 경로"))
    print("────────────────────────────────────────────────────────────────────────────")
    for s in sessions {
        let sid = String((s["session_id"] as? String ?? "-").prefix(8))
        let time = String((s["start_time"] as? String ?? "-").prefix(19)).replacingOccurrences(of: "T", with: " ")
        let scanned = s["total_scanned"] as? Int ?? 0
        let converted = s["total_converted"] as? Int ?? 0
        let failed = s["total_failed"] as? Int ?? 0
        let dur = String(format: "%.1fs", s["duration_sec"] as? Double ?? 0.0)
        let target = s["target_path"] as? String ?? ""
        let dry = (s["is_dry_run"] as? Bool ?? false) ? " [미리보기]" : ""
        print(String(format: "%-10@ %-20@ %-6d %-6d %-6d %-8@ %-30@", sid, time, scanned, converted, failed, dur, "\(target)\(dry)"))
    }
    
    let stats = AuditDatabase.shared.getOverallStats()
    print("════════════════════════════════════════════════════════════════════════════")
    print("  📊 누적 수복 총계: ✅ 성공 \(stats.totalConverted)건 | ❌ 실패 \(stats.totalFailed)건")
    print("════════════════════════════════════════════════════════════════════════════\n")
}

func runFailuresCommand() {
    print("════════════════════════════════════════════════════════════════════════════")
    print("  ❌ Grive한글가드 수복 실패 및 미수복 상세 장부 (최근 50건)")
    print("  경로: \(dbFileURL.path)")
    print("════════════════════════════════════════════════════════════════════════════")
    
    let failures = AuditDatabase.shared.getFailures(limit: 50)
    if failures.isEmpty {
        print("  🎉 실패 또는 권한 부족으로 미수복된 파일이 없습니다! (전체 무결성 확보)")
        return
    }
    
    for f in failures {
        let id = f["id"] as? Int ?? 0
        let time = f["timestamp"] as? String ?? ""
        let path = f["original_path"] as? String ?? ""
        let reason = f["error_reason"] as? String ?? "알 수 없음"
        print("  [#\(id)] \(time)")
        print("    📂 파일: \(path)")
        print("    ⚠️  사유: \(reason)")
        print("  ────────────────────────────────────────────────────────────────────────")
    }
    print("  총 \(failures.count)건의 실패 항목이 조회되었습니다.\n")
}

// MARK: - Subcommand: Zip (Windows-Compatible Clean Compressor)

func getUniqueZipPath(basePath: String) -> String {
    if !fm.fileExists(atPath: basePath) { return basePath }
    let ns = basePath as NSString
    let parent = ns.deletingLastPathComponent
    let stem = (ns.lastPathComponent as NSString).deletingPathExtension
    var counter = 1
    while true {
        let candidate = "\(parent)/\(stem) (\(counter)).zip"
        if !fm.fileExists(atPath: candidate) { return candidate }
        counter += 1
    }
}

func patchZipUTF8(zipPath: String) -> Bool {
    guard let handle = try? FileHandle(forUpdating: URL(fileURLWithPath: zipPath)) else { return false }
    defer { try? handle.close() }
    
    guard let data = try? handle.readToEnd() else { return false }
    var bytes = [UInt8](data)
    let len = bytes.count
    var modified = false
    
    var i = 0
    while i < len - 4 {
        // Local File Header: PK\x03\x04
        if bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x03 && bytes[i+3] == 0x04 {
            let flagIndex = i + 6
            if flagIndex + 1 < len {
                bytes[flagIndex + 1] |= 0x08 // Set 0x0800 UTF-8 flag
                modified = true
            }
            i += 30
            continue
        }
        // Central Directory Header: PK\x01\x02
        if bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x01 && bytes[i+3] == 0x02 {
            let flagIndex = i + 8
            if flagIndex + 1 < len {
                bytes[flagIndex + 1] |= 0x08 // Set 0x0800 UTF-8 flag
                modified = true
            }
            i += 46
            continue
        }
        i += 1
    }
    
    if modified {
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: bytes)
        return true
    }
    return false
}

func cleanJunkFiles(at rootPath: String) {
    guard let subpaths = try? fm.subpathsOfDirectory(atPath: rootPath) else { return }
    for sub in subpaths {
        let name = (sub as NSString).lastPathComponent
        if name == ".DS_Store" || name.hasPrefix("._") {
            let fullPath = (rootPath as NSString).appendingPathComponent(sub)
            try? fm.removeItem(atPath: fullPath)
        }
    }
}

func runZipCommand(args: [String]) {
    guard !args.isEmpty else {
        showNotification(title: "압축 실패", subtitle: "선택된 파일이나 폴더가 없습니다.")
        exit(1)
    }
    
    let validPaths = args
        .map { ($0 as NSString).expandingTildeInPath }
        .filter { fm.fileExists(atPath: $0) }
        .filter { ($0 as NSString).lastPathComponent != ".DS_Store" }
    
    guard !validPaths.isEmpty else {
        showNotification(title: "압축 실패", subtitle: "유효한 파일이 없습니다.")
        exit(1)
    }
    
    // 1. Pre-normalize all targets to NFC & strip OS junk (.DS_Store, ._*)
    for path in validPaths {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            cleanJunkFiles(at: path)
            sweepDirectory(rootPath: path)
            let name = (path as NSString).lastPathComponent
            if isDecomposed(name) {
                safeRenameToNFC(path: path)
            }
        } else {
            let name = (path as NSString).lastPathComponent
            if isDecomposed(name) {
                safeRenameToNFC(path: path)
            }
        }
    }
    
    let firstItem = validPaths[0] as NSString
    let parentDir = firstItem.deletingLastPathComponent
    let zipName: String
    if validPaths.count == 1 {
        zipName = "\(firstItem.lastPathComponent).zip"
    } else {
        let pName = (parentDir as NSString).lastPathComponent
        zipName = "\(pName)_윈도우호환.zip"
    }
    
    let outputZipPath = getUniqueZipPath(basePath: "\(parentDir)/\(zipName)")
    
    // 2. Use native /usr/bin/ditto with --norsrc to strip resource forks & .DS_Store
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    
    var dittoArgs = ["-c", "-k", "--norsrc"]
    for p in validPaths {
        dittoArgs.append(p)
    }
    dittoArgs.append(outputZipPath)
    task.arguments = dittoArgs
    
    do {
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus == 0 {
            // 3. Post-patch zip headers with 0x0800 UTF-8 flag
            _ = patchZipUTF8(zipPath: outputZipPath)
            
            showNotification(
                title: "윈도우 호환 압축 완료",
                subtitle: (outputZipPath as NSString).lastPathComponent,
                message: "NFC 표준 파일명 및 .DS_Store 제거 완료"
            )
            log("Zip created with clean UTF-8 headers: \(outputZipPath)")
        } else {
            showNotification(title: "압축 실패", subtitle: "오류 코드 \(task.terminationStatus)")
        }
    } catch {
        showNotification(title: "압축 오류", subtitle: error.localizedDescription)
    }
}

// MARK: - Subcommand: Daemon (FSEvents Watcher)

func loadMonitoredPaths() -> [String] {
    let defaultPaths = [
        homeURL.appendingPathComponent("Desktop").path,
        homeURL.appendingPathComponent("Downloads").path,
        homeURL.appendingPathComponent("Documents").path
    ].filter { fm.fileExists(atPath: $0) }
    
    if fm.fileExists(atPath: configFileURL.path),
       let data = try? Data(contentsOf: configFileURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let customPaths = json["watch_paths"] as? [String] {
        let valid = customPaths
            .map { NSString(string: $0).expandingTildeInPath as String }
            .filter { fm.fileExists(atPath: $0) }
        if !valid.isEmpty { return valid }
    }
    return defaultPaths
}

let eventCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
    
    for i in 0..<numEvents {
        let path = paths[i]
        let flag = flags[i]
        
        let mustScan = (flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0
        if mustScan {
            log("FSEvents buffer overflow flag received, triggering sweep: \(path)")
            DispatchQueue.global(qos: .utility).async {
                sweepDirectory(rootPath: path)
            }
            continue
        }
        
        if shouldIgnore(path: path) { continue }
        
        let isInteresting = (flag & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemInodeMetaMod
        )) != 0
        
        let name = (path as NSString).lastPathComponent
        if isInteresting || isDecomposed(name) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.08) {
                safeRenameToNFC(path: path)
            }
        }
    }
}

func runDaemonCommand() {
    let pathsToWatch = loadMonitoredPaths()
    guard !pathsToWatch.isEmpty else {
        log("No valid paths to monitor. Exiting.")
        exit(1)
    }
    
    log("GriveHangulGuard Native Swift Engine starting (daemon mode).")
    log("Monitored paths: \(pathsToWatch)")
    log("Audit database active: \(dbFileURL.path)")
    
    // Initial Sweep & Crash Recovery
    for path in pathsToWatch {
        sweepDirectory(rootPath: path)
    }
    
    let pathsToWatchCF = pathsToWatch as CFArray
    var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    
    let streamFlags = UInt32(
        kFSEventStreamCreateFlagUseCFTypes |
        kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagNoDefer
    )
    
    guard let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        eventCallback,
        &context,
        pathsToWatchCF,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.05,
        streamFlags
    ) else {
        log("Failed to create FSEventStream.")
        exit(1)
    }
    
    let queue = DispatchQueue(label: "com.grive.hangulguard.fsevents", qos: .utility)
    FSEventStreamSetDispatchQueue(stream, queue)
    
    if !FSEventStreamStart(stream) {
        log("Failed to start FSEventStream.")
        exit(1)
    }
    
    log("FSEventStream successfully bound. Daemon active.")
    dispatchMain()
}

// MARK: - Entry Point Router (Multi-call Binary Support)

func main() {
    let args = CommandLine.arguments
    let invokedName = (args[0] as NSString).lastPathComponent
    
    // BusyBox multi-call binary routing
    if invokedName == "winzip" {
        runZipCommand(args: Array(args.dropFirst()))
        return
    }
    if invokedName == "fix-korean-jamo" || invokedName == "fix_korean_jamo" {
        runFixCommand(args: Array(args.dropFirst()))
        return
    }
    if invokedName == "grive-scan" || invokedName == "hangul-scan" {
        runScanCommand(args: Array(args.dropFirst()))
        return
    }

    if args.count <= 1 {
        runDaemonCommand()
        return
    }
    
    let subcommand = args[1]
    let remainingArgs = Array(args.dropFirst(2))
    
    switch subcommand {
    case "daemon":
        runDaemonCommand()
    case "fix", "--fix":
        runFixCommand(args: remainingArgs)
    case "scan", "--scan":
        runScanCommand(args: remainingArgs)
    case "history", "--history", "sessions":
        runHistoryCommand()
    case "failures", "--failures", "failed":
        runFailuresCommand()
    case "zip", "--zip":
        runZipCommand(args: remainingArgs)
    case "help", "--help", "-h":
        print("""
        GriveHangulGuard macOS Universal Engine 🍏🇰🇷
        Usage:
          nfc_watcher [daemon]              Run real-time background normalizer
          nfc_watcher scan [paths...]       Deep scan & recover existing files (add --dry-run for preview)
          nfc_watcher history               View recent scan sessions and overall statistics
          nfc_watcher failures              View failed / permission-denied files from local DB
          nfc_watcher fix <paths...>        Batch normalize NFD Hangul filenames to NFC
          nfc_watcher zip <paths...>        Create clean, Windows-compatible zip without junk
          nfc_watcher --help                Show this help message
        """)
    default:
        if fm.fileExists(atPath: (subcommand as NSString).expandingTildeInPath) {
            runFixCommand(args: Array(args.dropFirst(1)))
        } else {
            print("Unknown command: \(subcommand). Use --help for usage.")
            exit(1)
        }
    }
}

main()
