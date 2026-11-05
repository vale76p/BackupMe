import SwiftUI

// Liquid Glass needs macOS 26; the app still runs on 14, where these fall back to materials and stock buttons.
extension View {
    @ViewBuilder func glassPanel(in shape: some Shape = RoundedRectangle(cornerRadius: 14)) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
