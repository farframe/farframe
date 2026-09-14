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
    @State private var manualIsExpanded: Bool

    public init(
        target: PlayStationConsoleAddressesTarget,
        onSave: @escaping @MainActor (String, String?, PlayStationConnectionRoute) async throws -> Void
    ) {
        self.target = target
        self.onSave = onSave
        _hostAddress = State(initialValue: target.hostAddress)
        _awayHostAddress = State(initialValue: target.awayHostAddress ?? "")
        _connectionRoute = State(initialValue: target.connectionRoute)
        _manualIsExpanded = State(initialValue: target.awayHostAddress != nil)
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

                Section("Away Play") {
                    Text("Automatic Away Play is not available yet.")
                    Text("Your home pairing stays saved. Re-registering won’t enable Away Play.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced: Manual Address", isExpanded: $manualIsExpanded) {
                        addressField("Console address", text: $awayHostAddress)
                        Text("For an existing network route to your console. This address does not set up automatic Away Play.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if normalizedAway != nil {
                            Picker("Connect using", selection: $connectionRoute) {
                                Text("Home").tag(PlayStationConnectionRoute.home)
                                Text("Manual").tag(PlayStationConnectionRoute.away)
                            }
                            .pickerStyle(.segmented)
                            .disabled(isSaving)
                            Text("Wake and Connect use the selected address after you save.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Connect using", value: "Home")
                            Text("Enter a manual address above to choose it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
