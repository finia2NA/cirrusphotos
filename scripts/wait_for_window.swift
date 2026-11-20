// Waits until a process shows a normal on-screen window and no Keychain prompt
// (SecurityAgent) is open, both for two seconds in a row, so a recording skips launch and
// sign-in. Usage: wait_for_window.swift PID [TIMEOUT_SECONDS]
// Exit status: 0 ready, 1 timed out, 2 bad arguments, 3 the process quit.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1, let pid = Int32(arguments[1]) else {
    FileHandle.standardError.write(Data("Usage: wait_for_window.swift PID [TIMEOUT_SECONDS]\n".utf8))
    exit(2)
}
let timeout = arguments.count > 2 ? TimeInterval(arguments[2]) ?? 300 : 300
let deadline = Date().addingTimeInterval(timeout)
var readySince: Date?

while Date() < deadline {
    guard kill(pid, 0) == 0 || errno == EPERM else { exit(3) }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let hasWindow = windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return rect.width >= 400 && rect.height >= 300
    }
    let keychainPrompt = windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "SecurityAgent" }
    if hasWindow && !keychainPrompt {
        let since = readySince ?? Date()
        readySince = since
        if Date().timeIntervalSince(since) >= 2 { exit(0) }
    } else {
        readySince = nil
    }
    Thread.sleep(forTimeInterval: 0.25)
}
exit(1)
