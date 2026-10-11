import Foundation
import CoreServices

// MARK: - Constants & Configuration

let fm = FileManager.default
let homeURL = fm.homeDirectoryForCurrentUser

let logDir = homeURL.appendingPathComponent(".local/state/finder-tools")
let logFileURL = logDir.appendingPathComponent("nfc_watcher.log")

let configDir = homeURL.appendingPathComponent(".config/finder-tools")
let configFileURL = configDir.appendingPathComponent("watcher_config.json")

let excludePrefixes = [".__nfc_tmp_", "._", ".DS_Store"]
let excludeExtensions = Set(["crdownload", "download", "part", "tmp", "swp"])
let excludeDirNames = Set([".git", "node_modules", ".venv", "__pycache__"])

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) [SWIFT-NFC] \(message)\n"
    
    // Console output
    fputs(line, stderr)
    
    // File output
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

// MARK: - Unicode & Rename Logic

func isDecomposed(_ string: String) -> Bool {
    let nfc = string.precomposedStringWithCanonicalMapping
    return !string.utf8.elementsEqual(nfc.utf8)
}

func shouldIgnore(url: URL) -> Bool {
    let name = url.lastPathComponent
    for prefix in excludePrefixes {
        if name.hasPrefix(prefix) { return true }
    }
    if excludeExtensions.contains(url.pathExtension.lowercased()) {
        return true
    }
    for component in url.pathComponents {
        if excludeDirNames.contains(component) { return true }
    }
    return false
}

var processingSet = Set<String>()
let processingLock = NSLock()

func safeRenameToNFC(at url: URL) {
    let path = url.path
    
    processingLock.lock()
    if processingSet.contains(path) {
        processingLock.unlock()
        return
    }
    processingSet.insert(path)
    processingLock.unlock()
    
    defer {
        processingLock.lock()
        processingSet.remove(path)
        processingLock.unlock()
    }
    
    guard fm.fileExists(atPath: path) else { return }
    let originalName = url.lastPathComponent
    guard isDecomposed(originalName) else { return }
    
    let parent = url.deletingLastPathComponent()
    let nfcName = originalName.precomposedStringWithCanonicalMapping
    let tmpName = ".__nfc_tmp_\(UUID().uuidString)"
    let tmpURL = parent.appendingPathComponent(tmpName)
    let finalURL = parent.appendingPathComponent(nfcName)
    
    // APFS 2-Step Rename
    do {
        try fm.moveItem(at: url, to: tmpURL)
        try fm.moveItem(at: tmpURL, to: finalURL)
        log("Normalized: '\(originalName)' -> '\(nfcName)' at \(parent.path)")
    } catch {
        if fm.fileExists(atPath: tmpURL.path) && !fm.fileExists(atPath: url.path) {
            try? fm.moveItem(at: tmpURL, to: url)
        }
        log("Rename failed for '\(originalName)': \(error.localizedDescription)")
    }
}

// MARK: - Initial Sweep

func initialSweep(paths: [String]) {
    for rootPath in paths {
        let rootURL = URL(fileURLWithPath: rootPath)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { continue }
        
        var collectedURLs = [URL]()
        for case let fileURL as URL in enumerator {
            if shouldIgnore(url: fileURL) { continue }
            collectedURLs.append(fileURL)
        }
        
        // Process deepest items first (bottom-up) so child paths stay valid
        collectedURLs.sort { $0.pathComponents.count > $1.pathComponents.count }
        for url in collectedURLs {
            if isDecomposed(url.lastPathComponent) {
                safeRenameToNFC(at: url)
            }
        }
    }
}

// MARK: - Configuration Loader

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
            .map { NSString(string: $0).expandingTildeInPath }
            .filter { fm.fileExists(atPath: $0) }
        if !valid.isEmpty { return valid }
    }
    
    return defaultPaths
}

// MARK: - FSEvents Callback

let eventCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
    
    for i in 0..<numEvents {
        let path = paths[i]
        let flag = flags[i]
        
        let url = URL(fileURLWithPath: path)
        if shouldIgnore(url: url) { continue }
        
        // Check for Created, Modified, Renamed, ItemInodeMetaMod flags
        let isInteresting = (flag & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemInodeMetaMod
        )) != 0
        
        if isInteresting || isDecomposed(url.lastPathComponent) {
            // Slight delay (50ms) to allow file writes to close
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                safeRenameToNFC(at: url)
            }
        }
    }
}

// MARK: - Main Runner

func main() {
    let pathsToWatch = loadMonitoredPaths()
    guard !pathsToWatch.isEmpty else {
        log("No valid paths to monitor. Exiting.")
        exit(1)
    }
    
    log("Co-OS Swift NFC Normalizer Daemon starting.")
    log("Monitored paths: \(pathsToWatch)")
    
    // 1. Initial sweep
    initialSweep(paths: pathsToWatch)
    
    // 2. Setup FSEventStream
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
        0.05, // 50ms latency
        streamFlags
    ) else {
        log("Failed to create FSEventStream.")
        exit(1)
    }
    
    let queue = DispatchQueue(label: "com.coos.nfc-normalizer.fsevents", qos: .utility)
    FSEventStreamSetDispatchQueue(stream, queue)
    
    if !FSEventStreamStart(stream) {
        log("Failed to start FSEventStream.")
        exit(1)
    }
    
    log("FSEventStream started successfully. Dispatch loop running.")
    dispatchMain()
}

main()
