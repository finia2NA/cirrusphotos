import Foundation

/// From the Info.plist embedded in the binary (MARKETING_VERSION in project.yml).
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

if CommandLine.arguments.dropFirst().contains(where: { ["-h", "--help", "-v", "--version"].contains($0) }) {
    print("""
    Album Downloader \(version)

    Downloads every photo and video of a shared Synology Photos album, one file at a time.
    Works with public links and with albums shared with your Synology account.
    Run it without arguments and answer the questions. Interrupted downloads continue
    when you run it again with the same download location.
    """)
    exit(0)
}

Console.say("Album Downloader \(version)")
Console.say()

var link: ShareLink?
while link == nil {
    link = ShareLink(Console.ask("Album link: "))
    if link == nil {
        Console.say("That doesn't look like a Synology Photos album link (for example https://nas.example.com:5001/mo/sharing/AbCd1234).")
    }
}
let share = link!
let api = Synology(server: share.server)

/// Runs a setup request, waiting through network problems and asking about untrusted certificates.
/// Other errors are passed on.
func patiently<T>(_ work: () throws -> T) throws -> T {
    while true {
        do {
            return try work()
        } catch TransferError.untrustedCertificate(let fingerprint) {
            guard let fingerprint else {
                Console.say("The server's certificate is not trusted and could not be read.")
                exit(1)
            }
            Console.say("The certificate of \(share.server.host ?? "the server") is not trusted by macOS.")
            Console.say("SHA-256 fingerprint: \(fingerprint)")
            guard Console.confirm("Trust it for this download?", default: false) else { exit(1) }
            api.http.trust(fingerprint: fingerprint)
        } catch TransferError.network(let message) {
            Console.say("Could not reach \(share.server.absoluteString): \(message)")
            for left in stride(from: 10, to: 0, by: -1) {
                Console.status("Trying again in \(left) s (Ctrl-C to quit)")
                Thread.sleep(forTimeInterval: 1)
            }
            Console.clearStatus()
        }
    }
}

/// `patiently`, but any other error ends the program with an explanation.
func required<T>(_ work: () throws -> T) -> T {
    do {
        return try patiently(work)
    } catch let error as TransferError {
        Console.say("This link doesn't open an album (\(error.message)).")
    } catch SignInError.rejected(let message) {
        Console.say(message)
    } catch {
        Console.say("This link doesn't open an album (\(error.localizedDescription)).")
    }
    exit(1)
}

// A public link opens without an account; otherwise sign in.
var linkPassword: String?
var needsAccount = false
opening: while true {
    switch required({ try api.openLink(reference: share.reference, password: linkPassword) }) {
    case .opened:
        break opening
    case .accountNeeded:
        needsAccount = true
        break opening
    case .passwordNeeded:
        if linkPassword != nil { Console.say("That link password was not accepted.") }
        let answer = Console.secret("Link password (or press Return to sign in with a Synology account): ")
        if answer.isEmpty {
            needsAccount = true
            break opening
        }
        linkPassword = answer
    }
}

var account: String?
if needsAccount {
    let username = Console.ask("Synology username: ")
    var password = Console.secret("Password: ")
    var code: String?
    signingIn: while true {
        do {
            try patiently { try api.signIn(username: username, password: password, code: code) }
            break signingIn
        } catch SignInError.codeRequired {
            code = Console.ask("Two-factor code: ")
        } catch SignInError.wrongCode {
            Console.say("That code was not accepted.")
            code = Console.ask("Two-factor code: ")
        } catch SignInError.rejected(let message) {
            Console.say(message)
            guard message.contains("password is wrong") else { exit(1) }
            password = Console.secret("Password: ")
            code = nil
        } catch {
            Console.say("Sign-in failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    account = username
}

// Check the album and the permission to download it.
let album = required { try api.album(reference: share.reference) }
guard required({ try api.canDownload(reference: share.reference) }) else {
    if let account {
        Console.say("“\(album.name)” is shared with \(account), but not with permission to download.")
        Console.say("Ask the owner to give this account the Downloader role.")
    } else {
        Console.say("This link lets you view “\(album.name)”, but not download it.")
        Console.say("Ask the owner to allow downloads for the link.")
    }
    exit(1)
}
let items = required { try api.items(reference: share.reference, expected: album.itemCount) }

guard !items.isEmpty else {
    Console.say("“\(album.name)” has no photos or videos.")
    exit(0)
}

let totalBytes = items.reduce(Int64(0)) { $0 + $1.filesize }
let videos = items.filter { $0.type == "video" }.count
Console.say()
Console.say("“\(album.name)”" + (album.ownerName.map { " from \($0)" } ?? ""))
Console.say("\(items.count - videos) photos and \(videos) videos, about \(Console.bytes(totalBytes)).")
Console.say()

// Choose where to save it.
func folderPath(_ input: String) -> URL {
    var text = input
    if text.count >= 2, let first = text.first, let last = text.last, (first == "'" || first == "\""), first == last {
        text = String(text.dropFirst().dropLast())
    } else {
        // A folder dragged into Terminal arrives with escaped spaces.
        text = text.replacingOccurrences(of: "\\ ", with: " ")
    }
    return URL(fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory())
let albumFolderName = DownloadState.safeName(album.name, fallback: "Album")
var state: DownloadState?
while state == nil {
    let location = folderPath(Console.ask("Download location [\(downloads.path)]: ", default: downloads.path))
    let folder = location.appendingPathComponent(albumFolderName, isDirectory: true)
    do {
        state = try DownloadState(folder: folder, reference: share.reference)
    } catch {
        Console.say("Can't use \(folder.path): \(error.localizedDescription)")
    }
}
let downloadState = state!

let already = items.filter { downloadState.isComplete($0.id) }
let neededBytes = totalBytes - already.reduce(Int64(0)) { $0 + $1.filesize }
if already.count == items.count {
    Console.say("All \(items.count) files of “\(album.name)” are already in \(downloadState.folder.path).")
    exit(0)
}
if !already.isEmpty {
    Console.say("\(already.count) of \(items.count) files are already in this folder; continuing with the rest.")
}
if let values = try? downloadState.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
   let free = values.volumeAvailableCapacityForImportantUsage, free < neededBytes {
    Console.say("Only \(Console.bytes(free)) are free on this disk, but about \(Console.bytes(neededBytes)) are needed.")
    guard Console.confirm("Download anyway?", default: false) else { exit(1) }
}
Console.say("Saving to \(downloadState.folder.path)")
Console.say("You can stop with Ctrl-C and continue later by running this again with the same location.")
Console.say()

// Keep the Mac awake and say how to continue when interrupted.
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                     reason: "Downloading an album")
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler {
    Console.say()
    Console.say("Stopped. Run Album Downloader again with the same location to continue.")
    exit(130)
}
interrupt.resume()

let summary = Downloader(api: api, reference: share.reference, state: downloadState, items: items).run()
ProcessInfo.processInfo.endActivity(activity)

Console.say()
Console.say("Downloaded \(summary.downloaded) files to \(downloadState.folder.path).")
if summary.givenUp.isEmpty {
    Console.say("All \(items.count) files of “\(album.name)” are there.")
    exit(0)
}
Console.say("\(summary.givenUp.count) files could not be downloaded:")
for failure in summary.givenUp {
    Console.say("  \(failure.item.filename): \(failure.reason)")
}
Console.say("Run Album Downloader again with the same location to retry them.")
exit(1)
