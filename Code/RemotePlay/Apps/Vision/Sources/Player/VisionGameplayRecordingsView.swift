import AppleMediaCore
import SwiftUI

/// Transient capture/save status, shared by the player and Home after a session
/// ends. No library, browsing, deletion or additional recording settings.
struct VisionGameplayRecordingStatus: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCollapsed = false

    var body: some View {
        Group {
            if coordinator.gameplayRecording.isBusy {
                HStack(spacing: 10) {
                    if isCollapsed && coordinator.gameplayRecording.canStop {
                        Button {
                            isCollapsed = false
                        } label: {
                            HStack(spacing: 8) {
                                recordingDot
                                elapsedTime
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recording. Show recording controls")
                    } else {
                        recordingDot
                        Text(coordinator.gameplayRecording.phase == .finishing ? "Saving…" : coordinator.gameplayRecording.phase == .starting ? "Starting…" : "Recording")
                        elapsedTime
                        Button("Stop", systemImage: "stop.fill") { coordinator.toggleGameplayRecording() }
                            .disabled(!coordinator.gameplayRecording.canStop)
                        if coordinator.gameplayRecording.canStop {
                            Button("Collapse recording status", systemImage: "chevron.up") { isCollapsed = true }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, isCollapsed ? 8 : 12)
                .background(.regularMaterial, in: Capsule())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isCollapsed)
            } else if coordinator.recordingPhotoOperationIsBusy {
                ProgressView(coordinator.recordingNotice ?? "Allow access to Photos…")
                    .padding(12).background(.regularMaterial, in: Capsule())
            } else if let url = coordinator.pendingPhotoMovie {
                VStack(spacing: 8) {
                    Text(coordinator.recordingNotice ?? "A video is waiting to save to Photos.")
                        .font(.callout)
                    HStack {
                        Button("Retry Save", systemImage: "photo") { coordinator.retryPhotoSave() }
                        ShareLink("Share Video", item: url)
                    }
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if let notice = coordinator.recordingNotice {
                HStack {
                    Text(notice).font(.callout)
                    Button("Dismiss", systemImage: "xmark") { coordinator.recordingNotice = nil }
                        .labelStyle(.iconOnly)
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onChange(of: coordinator.gameplayRecording.fileURL) { _, _ in
            isCollapsed = false
        }
        .task(id: CollapseTaskID(fileURL: coordinator.gameplayRecording.fileURL,
                                canStop: coordinator.gameplayRecording.canStop,
                                isCollapsed: isCollapsed)) {
            guard coordinator.gameplayRecording.canStop, !isCollapsed else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, coordinator.gameplayRecording.canStop else { return }
            isCollapsed = true
        }
    }

    // Re-expansion starts a fresh timer; elapsed-time updates never reset it.
    private struct CollapseTaskID: Equatable {
        let fileURL: URL?
        let canStop: Bool
        let isCollapsed: Bool
    }

    private var recordingDot: some View {
        Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
    }
    private var elapsedTime: some View {
        Text(Duration.seconds(coordinator.gameplayRecording.duration).formatted(.time(pattern: .minuteSecond)))
            .monospacedDigit()
    }
}
