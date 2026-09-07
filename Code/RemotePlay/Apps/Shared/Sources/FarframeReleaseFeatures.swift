// Conservative first-release scope. Re-enable only after hardware acceptance.
// Both UI and runtime use these gates; saved development preferences cannot
// activate deferred features in the customer candidate.
enum FarframeReleaseFeatures {
    static let advancedMedia = false
    static let externalDisplay = false
}
