import Darwin
import Foundation

/// Terminal input and output. Status lines redraw in place when standard output is a terminal.
enum Console {
    static let isInteractive = isatty(STDOUT_FILENO) == 1
    private static var statusVisible = false

    /// Prints a line, replacing a visible status line.
    static func say(_ text: String = "") {
        clearStatus()
        print(text)
        fflush(stdout)
    }

    /// Shows a one-line status that the next status or line replaces.
    static func status(_ text: String) {
        guard isInteractive else { return }
        let width = max(20, columns() - 1)
        let line = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        print("\r\u{1B}[K" + line, terminator: "")
        fflush(stdout)
        statusVisible = true
    }

    static func clearStatus() {
        guard statusVisible else { return }
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
        statusVisible = false
    }

    /// Reads a line; exits when input ends.
    static func ask(_ prompt: String, default fallback: String? = nil) -> String {
        clearStatus()
        print(prompt, terminator: "")
        fflush(stdout)
        guard let line = readLine() else {
            print()
            exit(1)
        }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? (fallback ?? "") : answer
    }

    /// Reads a line without echoing it.
    static func secret(_ prompt: String) -> String {
        clearStatus()
        var buffer = [CChar](repeating: 0, count: 1024)
        guard let result = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            // No terminal (for example, piped input): read a plain line instead.
            return ask(prompt)
        }
        let value = String(cString: result)
        buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) }
        return value
    }

    static func confirm(_ prompt: String, default yes: Bool) -> Bool {
        let answer = ask(prompt + (yes ? " [Y/n] " : " [y/N] ")).lowercased()
        if answer.isEmpty { return yes }
        return answer.hasPrefix("y")
    }

    /// Rings the terminal bell to get attention when input is needed mid-download.
    static func bell() {
        print("\u{07}", terminator: "")
        fflush(stdout)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }

    private static func columns() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return 80
    }
}
