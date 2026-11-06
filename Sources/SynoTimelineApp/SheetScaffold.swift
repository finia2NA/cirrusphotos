import SwiftUI

/// The layout every sheet shares, after the album sharing sheet: a title and subtitle,
/// the content, and a footer with secondary actions leading and the default action last.
struct SheetScaffold<Content: View, Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 440
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, width: CGFloat = 440,
         @ViewBuilder content: () -> Content,
         @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.content = content()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            Divider()
            HStack(spacing: 8) {
                leading
                Spacer()
                trailing
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: width)
    }
}

/// A centred loading or failure state for sheet bodies, with a stable minimum height so
/// the sheet does not jump when the content arrives.
struct SheetPlaceholder: View {
    enum State {
        case loading(String)
        case failure(String)
    }

    let state: State
    var minHeight: CGFloat = 120

    var body: some View {
        Group {
            switch state {
            case .loading(let text):
                ProgressView(text)
            case .failure(let text):
                ContentUnavailableView {
                    Label("Could Not Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(text).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

extension View {
    /// Centres a placeholder in the visible detail area below the toolbar.
    func detailPlaceholder(topInset: CGFloat) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, topInset)
    }
}
