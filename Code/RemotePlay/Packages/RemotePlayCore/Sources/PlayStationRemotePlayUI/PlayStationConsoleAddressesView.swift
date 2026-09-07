import Foundation
import PlayStationRemotePlay
import SwiftUI

/// Non-secret input for the shared Home/Away address editor.
public struct PlayStationConsoleAddressesTarget: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let consoleName: String
    public let hostAddress: String
    public let awayHostAddress: String?
    public let connectionRoute: PlayStationConnectionRoute

    public init(
        id: UUID,
        consoleName: String,
        hostAddress: String,
        awayHostAddress: String?,
        connectionRoute: PlayStationConnectionRoute
    ) {
        self.id = id
        self.consoleName = consoleName
        self.hostAddress = hostAddress
        self.awayHostAddress = awayHostAddress
        self.connectionRoute = connectionRoute
    }
}

/// Shared editor for a saved console's Home (local) and Away addresses plus the
/// active route. Saving never touches the registration envelope, so no new Link
/// Device code is needed. Used by the iPhone/iPad, Mac, and Vision shells.
public struct PlayStationConsoleAddressesView: View {
    @Environment(\.dismiss) private var dismiss

    private let target: PlayStationConsoleAddressesTarget
    private let onSave: @MainActor (String, String?, PlayStationConnectionRoute) async throws -> Void

    @State private var hostAddress: String
    @State private var awayHostAddress: String
    @State private var connectionRoute: PlayStationConnectionRoute
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var helpIsExpanded = false

    public init(
        target: PlayStationConsoleAddressesTarget,
        onSave: @escaping @MainActor (String, String?, PlayStationConnectionRoute) async throws -> Void
    ) {
        self.target = target
        self.onSave = onSave
        _hostAddress = State(initialValue: target.hostAddress)
        _awayHostAddress = State(initialValue: target.awayHostAddress ?? "")
        _connectionRoute = State(initialValue: target.connectionRoute)
    }

    private var normalizedAway: String? {
        SavedPlayStationConsole.normalizedAwayAddress(awayHostAddress)
    }

    private var effectiveRoute: PlayStationConnectionRoute {
        normalizedAway == nil ? .home : connectionRoute
    }

    private var canSave: Bool {
        isSaving == false
            && hostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Home") {
                    addressField("PS5 local IP address", text: $hostAddress)
                    Text("Used on your home network. This is the address captured when you paired.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Away") {
                    addressField("PS5 address reachable from your network", text: $awayHostAddress)
                    Text("Optional. Used when you choose the Away route. Your network must already provide a path to your PS5. Farframe connects directly to this address; it does not provide a VPN or automatic internet connection setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("How to reach your PS5 from away", isExpanded: $helpIsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Existing home-network access: if you separately configured a VPN to your home network, enter the PS5 address reachable through it. Farframe does not install, configure, or operate that VPN. Same-home-network play does not need a VPN.")
                            Text("Port forwarding: forward UDP 9295–9304 and TCP 9295 on your router to the PS5, and UDP 9302 for Wake. Enter your public IP or dynamic DNS name here.")
                            Text("Keep the PS5 set to stay connected to the internet in Rest Mode so Wake works.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Route") {
                    Picker("Connect using", selection: $connectionRoute) {
                        ForEach(PlayStationConnectionRoute.allCases, id: \.self) { route in
                            Text(route.title).tag(route)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(normalizedAway == nil)
                    Text(
                        normalizedAway == nil
                            ? "Add an Away address to enable the Away route."
                            : "Wake and Connect use the \(effectiveRoute.title) address. Switch back to Home when you return."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(target.consoleName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(canSave == false)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS) || os(visionOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func addressField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            #if os(iOS)
            .keyboardType(.URL)
            #endif
            .disabled(isSaving)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(
                    hostAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                    normalizedAway,
                    effectiveRoute
                )
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
