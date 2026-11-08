import PhotoCache
import SwiftUI

/// The shared maximum cache size: a slider over the `CacheBudget` range and its size.
struct CacheSizeSlider: View {
    var label = "Maximum size"
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $preferences.budgetFraction, in: 0...1)
                Text(ByteCountFormatter.string(fromByteCount: CacheBudget.bytes(at: preferences.budgetFraction),
                                               countStyle: .file))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
    }
}
