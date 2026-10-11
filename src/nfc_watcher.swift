import Foundation
import CoreServices
import Darwin

// ==============================================================================
// macos-hangul-nfc-cleaner: Universal Native Swift Engine
// - POSIX C-level rename() to bypass Cocoa URL NFD decomposition
// - Mode 1 (daemon): Real-time FSEvents watcher with crash recovery & file stability
// - Mode 2 (fix): Batch recursive Hangul Jamo normalizer for selected paths
// - Mode 3 (zip): Windows-compatible clean ZIP compressor using native ditto
// ==============================================================================

let fm = FileManager.default
let homeURL = fm.homeDirectoryForCurrentUser

let logDir = homeURL.appendingPathComponent(".local/state/finder-tools")
let logFileURL = logDir.appendingPathComponent("nfc_watcher.log")

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

@discardableResult
func safeRenameToNFC(path: String) -> Bool {
    processingLock.lock()
    if processingSet.contains(path) {
        processingLock.unlock()
        return false
    }
    processingSet.insert(path)
    processingLock.unlock()
    
    defer {
        processingLock.lock()
        processingSet.remove(path)
        processingLock.unlock()
    }
    
    guard fm.fileExists(atPath: path) else { return false }
    let nsPath = path as NSString
    let originalName = nsPath.lastPathComponent
    guard isDecomposed(originalName) else { return false }
    
    guard isFileReady(path: path) else {
        log("File not ready yet, deferring: \(originalName)")
        return false
    }
    
    let parent = nsPath.deletingLastPathComponent
    let nfcName = (originalName as NSString).precomposedStringWithCanonicalMapping
    
    // Intent-Preserving Temp Name for Crash Recovery: .__nfc_tmp_<UUID>_<nfcName>
    let tmpName = ".__nfc_tmp_\(UUID().uuidString)_\(nfcName)"
    let tmpPath = "\(parent)/\(tmpName)"
    let finalPath = "\(parent)/\(nfcName)"
    
    // POSIX C rename() preserves exact UTF-8 NFC byte sequence on APFS
    if rename(path, tmpPath) != 0 {
        log("Rename step 1 failed for '\(originalName)': errno \(errno)")
        return false
    }
    
    if rename(tmpPath, finalPath) != 0 {
        log("Rename step 2 failed for '\(originalName)': errno \(errno)")
        // Rollback
        rename(tmpPath, path)
        return false
    }
    
    log("Normalized: '\(originalName)' -> '\(nfcName)' at \(parent)")
    return true
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

// MARK: - Subcommand: Scan (Deep Recursive Full Normalizer)

func runScanCommand(args: [String]) {
    var isDryRun = false
    var targetPaths = [String]()
    
    for arg in args {
        if arg == "--dry-run" || arg == "-n" {
            isDryRun = true
        } else {
            targetPaths.append(arg)
        }
    }
    
    if targetPaths.isEmpty {
        targetPaths = loadMonitoredPaths()
    }
    
    print("============================================================")
    print("  🔍 Grive한글가드: 기존 파일 한글 자모 전수 스캔 및 수복")
    if isDryRun {
        print("  ⚠️  [미리보기 모드] 실제 파일명은 변경되지 않습니다.")
    }
    print("============================================================")
    
    var totalScanned = 0
    var totalFixed = 0
    let startTime = Date()
    
    for rawPath in targetPaths {
        let path = (rawPath as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: path) else {
            print("❌ 경로가 존재하지 않습니다: \(path)")
            continue
        }
        
        print("\n📂 대상 디렉터리: \(path)")
        
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
            if collected.count % 500 == 0 {
                print("\r  📂 \(collected.count)개 파일 탐색 중...", terminator: "")
                fflush(stdout)
            }
        }
        
        // Bottom-up traversal: 자식 파일/폴더를 먼저 처리하여 상위 디렉터리 이름 변경 시 경로 단절 방지
        collected.sort { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }
        
        for (idx, p) in collected.enumerated() {
            totalScanned += 1
            let name = (p as NSString).lastPathComponent
            if isDecomposed(name) {
                let nfc = (name as NSString).precomposedStringWithCanonicalMapping
                totalFixed += 1
                if isDryRun {
                    print("\r  🔍 [발견] '\(name)' ➔ '\(nfc)'")
                } else {
                    if safeRenameToNFC(path: p) {
                        print("\r  ✅ [수복] '\(name)' ➔ '\(nfc)'")
                    }
                }
            }
            if idx % 200 == 0 {
                print("\r  🔍 \(totalScanned)/\(collected.count)개 항목 검사 중 (자모 분리: \(totalFixed)건)...", terminator: "")
                fflush(stdout)
            }
        }
    }
    
    let duration = String(format: "%.2f", Date().timeIntervalSince(startTime))
    print("\n============================================================")
    print("  🎉 스캔 완료 (\(duration)초) | 검사 항목: \(totalScanned)개 | \(isDryRun ? "발견: " : "수복 완료: ")\(totalFixed)개")
    print("============================================================")
    
    if !isDryRun {
        showNotification(
            title: "기존 파일 자모 전수 수복 완료",
            subtitle: "총 \(totalFixed)개 항목 정상 결합됨",
            message: "검사 항목: \(totalScanned)개 (소요시간: \(duration)초)"
        )
    }
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
    case "zip", "--zip":
        runZipCommand(args: remainingArgs)
    case "help", "--help", "-h":
        print("""
        GriveHangulGuard macOS Universal Engine 🍏🇰🇷
        Usage:
          nfc_watcher [daemon]              Run real-time background normalizer
          nfc_watcher scan [paths...]       Deep scan & recover existing files (add --dry-run for preview)
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
