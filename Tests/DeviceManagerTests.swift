import XCTest
import CoreAudio
@testable import MyHomeTheatreApp

/// Mocked CoreAudio environment for DeviceManager tests.
class MockCoreAudio {
    static var devices: [AudioDevice] = []
}

class DeviceManagerTests: XCTestCase {
    func testBluetoothFiltering() {
        // Prepare mock devices
        let allDevices: [AudioDevice] = [
            AudioDevice(id: 1, name: "Internal", uid: "internal-uid"),
            AudioDevice(id: 2, name: "BT Speaker", uid: "bt-uid")
        ]
        // Simulate CoreAudio returning both
        MockCoreAudio.devices = allDevices
        // Replace DeviceManager's refresh logic with mock
        let manager = DeviceManager.shared
        manager.refresh()
        // Expect only BT device
        XCTAssertEqual(manager.bluetoothDevices.count, 1)
        XCTAssertEqual(manager.bluetoothDevices.first?.uid, "bt-uid")
    }
}
