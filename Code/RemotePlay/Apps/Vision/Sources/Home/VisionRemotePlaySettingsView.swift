import ExperienceDomain
import FarframeCommerceUI
import FarframeStorefront
import Foundation
import PlayStationRemotePlayUI
import SwiftUI

struct VisionRemotePlaySettingsView: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    @Environment(\.dismiss) private var dismiss
    @State private var whatsNewIsPresented = false
    @State private var accessIsPresented = false
    @State private var legalIsExpanded = false
    /// Set when a play style is applied, so the sheet can say which half of it
    /// landed on the live stream and which half waits for the next connection.
    @State private var playStyleNotice: String?

    /// Derived, never stored: the style whose two settings are the ones
    /// currently set, if any. Nudging quality or smooth motion by hand simply
    /// leaves nothing marked, which is the truth.
    private var currentPlayStyle: StreamPlayStyle? {
        StreamPlayStyle.matching(
            quality: coordinator.streamQuality,
            smoothMotionEnabled: coordinator.smoothMotionEnabled
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Farframe Pro") {
                    LabeledContent("Status", value: accessStore.statusTitle)
                    Text(accessStore.statusDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        accessIsPresented = true
                    } label: {
                        Label(
                            accessStore.allowsConnect ? "View Access" : "Upgrade to Pro",
                            systemImage: accessStore.entrySymbol
                        )
                    }

                    Button {
                        Task { await accessStore.restorePurchases() }
                    } label: {
                        Label(
                            accessStore.isRestoring ? "Restoring Purchases…" : "Restore Purchases",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(
                        accessStore.isRestoring
                            || accessStore.purchaseInProgressID != nil
                    )

                    if let notice = accessStore.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(StreamPlayStyle.question) {
                    ForEach(StreamPlayStyle.allCases) { style in
                        Button {
                            coordinator.apply(style)
                            playStyleNotice = style.appliedNotice(
                                hasActiveSession: coordinator.activeSessionID != nil
                            )
                        } label: {
                            StreamPlayStyleRow(style: style, isCurrent: style == currentPlayStyle)
                        }
                        .buttonStyle(.plain)
                    }
                    if let playStyleNotice {
                        Text(playStyleNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Each one sets the quality and smooth motion below. You can still change either by hand.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Stream Quality") {
                    Picker("Quality", selection: $coordinator.streamQuality) {
                        ForEach(VisionStreamQuality.allCases) { quality in
                            StreamQualityPresetRow(preset: quality)
                                .tag(quality)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(VisionStreamQuality.ladderFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(
                        VisionStreamQuality.changeNotice(
                            selected: coordinator.streamQuality,
                            active: coordinator.activeStreamQuality
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Toggle("Smooth motion", isOn: $coordinator.smoothMotionEnabled)
                    Text("Holds a few frames so a busy Wi-Fi network does not stutter. Costs about 50 ms of input lag, and up to about 200 ms while the network is rough. Turn off for the fastest response.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if FarframeReleaseFeatures.advancedMedia {
                        Toggle("Controller feedback", isOn: $coordinator.controllerFeedbackEnabled)
                        Text("Plays the game's rumble, light bar colour, and DualSense trigger resistance on your controller.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("Video enhancement", selection: $coordinator.videoEnhancement) {
                            ForEach(StreamUpscaling.allCases) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.displayName)
                                    Text(mode.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(mode)
                            }
                        }
                        Text(StreamUpscaling.settingFootnote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Session") {
                    Toggle("Rest PS5 when player closes", isOn: $coordinator.restOnPlayerClose)
                    Text("Off disconnects Remote Play and leaves the console awake.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Headset off ends session after", selection: $coordinator.backgroundDisconnectMinutes) {
                        Text("Immediately").tag(0)
                        Text("1 minute").tag(1)
                        Text("2 minutes").tag(2)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("Never").tag(-1)
                    }
                    Text("The game keeps running while the headset is off, so you can put it back on and continue. After this long, Farframe ends the session the same way closing the player does: Rest PS5 if the toggle above is on, otherwise Disconnect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Audio") {
                    Toggle("Mute", isOn: $coordinator.audioIsMuted)
                    Slider(
                        value: Binding(
                            get: { Double(coordinator.audioVolume) },
                            set: { coordinator.audioVolume = Float($0) }
                        ),
                        in: 0...1
                    ) {
                        Text("Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .disabled(coordinator.audioIsMuted)
                    LabeledContent("Volume", value: "\(Int(coordinator.audioVolume * 100))%")
                }

                Section("Controller") {
                    let connection = coordinator.controllerSource.connectionSnapshot()
                    LabeledContent("Status", value: connection.isConnected ? "Connected" : "Not Connected")
                    if let name = connection.name {
                        LabeledContent("Controller", value: name)
                    }
                    Text("DualSense labels use their standard PS5 mapping: right Options, left Create.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    Button {
                        whatsNewIsPresented = true
                    } label: {
                        Label("What's New", systemImage: "sparkles")
                    }
                    LabeledContent("Version", value: appVersion)
                    Text("\(appDisplayName) for Apple Vision Pro")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(
                        "Farframe Support",
                        destination: URL(string: "https://unshackledpursuit.com/farframe#support")!
                    )
                    DisclosureGroup("Privacy, source, and licenses", isExpanded: $legalIsExpanded) {
                        Link(
                            "Privacy Policy",
                            destination: URL(string: "https://unshackledpursuit.com/farframe#privacy")!
                        )
                        Link(
                            "Terms of Use",
                            destination: URL(string: "https://unshackledpursuit.com/farframe#terms")!
                        )
                        Link(
                            "Apple Standard EULA",
                            destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
                        )
                        Link(
                            "Source & Build Materials",
                            destination: URL(string: "https://unshackledpursuit.com/farframe#faq")!
                        )
                        NavigationLink {
                            FarframeThirdPartyNoticesView()
                        } label: {
                            Label("Third-Party Notices", systemImage: "doc.badge.gearshape")
                        }
                    }
                    Text("Farframe is an independent application. It is not affiliated with, endorsed by, or sponsored by Sony Group Corporation, Sony Interactive Entertainment, PlayStation, PlayStation Network, or any of their affiliates. PlayStation, PS5, and PlayStation Network are trademarks or registered trademarks of their respective owners and are used only to describe compatibility with user-owned equipment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .sheet(isPresented: $whatsNewIsPresented) {
            FarframeWhatsNewView()
        }
        .sheet(isPresented: $accessIsPresented) {
            FarframePaywallView(accessStore: accessStore)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Farframe"
    }

}
