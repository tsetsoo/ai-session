import SwiftUI

#if os(macOS)
/// Settings → Notifications, "On this Mac": what happens when a conversation arrives in Needs
/// you or To review. Sounds and the Dock badge work whether or not notifications are on; banners
/// need them on.
struct MacAttentionSettingsSection: View {
    @AppStorage(AttentionSound.needsYouKey) private var needsYouSound = AttentionSound.defaultChoice
    @AppStorage(AttentionSound.reviewKey) private var reviewSound = AttentionSound.defaultChoice
    @AppStorage(NotificationCenterCoordinator.macBannersKey) private var banners = true
    @AppStorage(DockBadge.enabledKey) private var dockBadge = true

    var body: some View {
        Section {
            soundPicker("Needs you sound", selection: $needsYouSound, kind: .needsYou)
            soundPicker("Ready for review sound", selection: $reviewSound, kind: .review)
            Toggle("Show banners when the app is in the background", isOn: $banners)
            Toggle("Badge the Dock icon", isOn: $dockBadge)
        } header: {
            Text("On this Mac")
        } footer: {
            Text("Sounds follow the Mac's volume, so a muted Mac stays silent.")
        }
    }

    private func soundPicker(_ title: String, selection: Binding<String>, kind: AttentionKind) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text("Chime").tag(AttentionSound.defaultChoice)
                Divider()
                ForEach(AttentionSound.systemNames, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("None").tag(AttentionSound.noneChoice)
            }
            Button {
                AttentionSound.preview(selection.wrappedValue, kind: kind)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Play")
            .accessibilityLabel("Play \(title)")
            .disabled(selection.wrappedValue == AttentionSound.noneChoice)
        }
    }
}
#endif
