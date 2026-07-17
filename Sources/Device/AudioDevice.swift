import Foundation

/// Simple model representing an audio device.
public struct AudioDevice: Identifiable, Hashable {
    public let id: UInt32 // CoreAudio device ID
    public let name: String
    public let uid: String

    public init(id: UInt32, name: String, uid: String) {
        self.id = id
        self.name = name
        self.uid = uid
    }
}
