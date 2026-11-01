import ReplayKit
import SwiftUI

/// Apple's broadcast control is a fixed system button that cannot be styled, so
/// EWP keeps it off screen and triggers it from its own button. The same path
/// serves an MCP client, which has no finger to tap with.
struct HiddenBroadcastPicker: UIViewRepresentable {
    let model: CompanionModel

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = "com.unlikeotherai.ewp.Broadcast"
        picker.showsMicrophoneButton = false
        model.broadcastPicker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

extension View {
    /// Keeps the picker in the view hierarchy, where its action still fires,
    /// without it appearing in the layout.
    func broadcastTrigger(_ model: CompanionModel) -> some View {
        background {
            HiddenBroadcastPicker(model: model)
                .frame(width: 44, height: 44)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
