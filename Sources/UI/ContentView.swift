import SwiftUI

struct ContentView: View {
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var isPlaying = false

    var body: some View {
        VStack {
            HStack {
                Text("Bluetooth Speakers")
                    .font(.headline)
                Spacer()
                Button(action: syncDelays) {
                    Image(systemName: "arrow.2.circlepath")
                }
                    Image(systemName: "arrow.2.circlepath")
                }
            }
            .padding(.horizontal)

            List(deviceManager.bluetoothDevices) { device in
                HStack {
                    Text(device.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(AudioEngine.shared.getDelay(for: device.uid)) },
                        set: { AudioEngine.shared.setDelay(for: device.uid, milliseconds: Float($0 * 1000)) }
                    ), in: 0...1)
                        .frame(width: 150)
                    Text(String(format: "%.0f ms", AudioEngine.shared.getDelay(for: device.uid) * 1000))
                        .frame(width: 60, alignment: .trailing)
                }
            }
            .listStyle(PlainListStyle())

            HStack {
                Button(isPlaying ? "Stop" : "Play") {
                    if isPlaying {
                        AudioEngine.shared.stop()
                    } else {
                        guard let url = Bundle.main.url(forResource: "sample", withExtension: "mp3") else { return }
                        try? AudioEngine.shared.loadFile(url: url)
                        try? AudioEngine.shared.setup(with: deviceManager.bluetoothDevices)
                        AudioEngine.shared.play()
                    }
                    isPlaying.toggle()
                }
                .padding(.horizontal)
            }
        }
        .onChange(of: deviceManager.bluetoothDevices) { _ in
            if isPlaying {
                try? AudioEngine.shared.setup(with: deviceManager.bluetoothDevices)
            }
        }
        .onAppear {
            // Ensure devices are refreshed
            deviceManager.refresh()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
