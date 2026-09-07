import ChiakiNative
import Foundation

public struct ChiakiNativeRuntimeInfo: Equatable, Sendable {
    public let abiVersion: UInt32
    public let sessionSize: Int
    public let videoCallbackOffset: Int
    public let audioSinkOffset: Int
    public let displaySinkOffset: Int
    public let capabilityMask: UInt32

    public var hasValidSessionLayout: Bool {
        sessionSize > 0
            && videoCallbackOffset < sessionSize
            && audioSinkOffset < sessionSize
            && displaySinkOffset < sessionSize
    }

    public var supportsPlayStation5Wake: Bool {
        capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_WAKE_PS5) != 0
    }

    public var supportsPlayStation5Connect: Bool {
        capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_CONNECT_PS5) != 0
    }

    public var supportsMediaCallbacks: Bool {
        capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_MEDIA_CALLBACKS) != 0
    }

    public var supportsPlayStation5Registration: Bool {
        capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_REGISTER_PS5) != 0
    }
}

public enum ChiakiNativeRuntime {
    public static var info: ChiakiNativeRuntimeInfo {
        let nativeInfo = rp_chiaki_runtime_info()
        return ChiakiNativeRuntimeInfo(
            abiVersion: nativeInfo.abi_version,
            sessionSize: nativeInfo.session_size,
            videoCallbackOffset: nativeInfo.video_callback_offset,
            audioSinkOffset: nativeInfo.audio_sink_offset,
            displaySinkOffset: nativeInfo.display_sink_offset,
            capabilityMask: nativeInfo.capability_mask
        )
    }

    public static func allocationMatchesRuntime() -> Bool {
        guard let handle = rp_chiaki_session_handle_create() else {
            return false
        }
        defer { _ = rp_chiaki_session_handle_destroy(handle) }
        return rp_chiaki_session_handle_allocation_size(handle) == info.sessionSize
    }
}
