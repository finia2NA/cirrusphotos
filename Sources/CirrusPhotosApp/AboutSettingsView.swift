import AppKit
import SwiftUI

enum AppVersion {
    /// "Version 0.1 (1)", or "development build" when the bundle has no version keys.
    static func text(bundle: Bundle = .main) -> String {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "development build"
        }
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "Version \(version)\(build.map { " (\($0))" } ?? "")"
    }
}

/// One third-party component, loaded from the bundled `ThirdPartyNotices.json`.
struct ThirdPartyNotice: Codable, Identifiable, Equatable {
    let name: String
    let url: URL
    let license: String
    let licenseText: String
    var id: String { name }

    static func load(from url: URL? = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "json")) -> [ThirdPartyNotice] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ThirdPartyNotice].self, from: data)) ?? []
    }
}

enum AboutLinks {
    static let website = URL(string: "https://cirrusphotos.richardhanss.de")!
    static let source = URL(string: "https://github.com/finia2NA/syno")!
    static let issues = URL(string: "https://github.com/finia2NA/syno/issues/new")!
    static let license = URL(string: "https://github.com/finia2NA/syno/blob/main/LICENSE")!
}

struct AboutSettingsView: View {
    private let notices = ThirdPartyNotice.load()

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("Cirrus Photos").font(.title2.bold())
                    Text(AppVersion.text()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Section {
                Link("Website", destination: AboutLinks.website)
                Link("Source Code", destination: AboutLinks.source)
                Link("Report an Issue", destination: AboutLinks.issues)
            }
            Section("License") {
                LabeledContent("Licensed under the GNU General Public License v3.0") {
                    Link("View License", destination: AboutLinks.license)
                }
            }
            if !notices.isEmpty {
                Section("Acknowledgements") {
                    ForEach(notices) { notice in
                        DisclosureGroup {
                            Text(notice.licenseText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                Link(notice.name, destination: notice.url)
                                Spacer()
                                Text(notice.license).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text("Cirrus Photos is not affiliated with or endorsed by Synology Inc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
