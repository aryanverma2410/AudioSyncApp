import SwiftUI
import AppKit

// MARK: - Mini Floating Widget

/// Compact always-on-top panel for quick access to core controls.
/// Shown/hidden via toggle button in main window toolbar.
struct MiniWidgetView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("AudioSync")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(appState.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Start/Stop
            Button {
                if appState.isActive { appState.stop() } else { Task { await appState.start() } }
            } label: {
                HStack {
                    Image(systemName: appState.isActive ? "stop.fill" : "play.fill")
                    Text(appState.isActive ? "Stop" : "Start")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(appState.isActive ? Color.red : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Master volume
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { Double(appState.masterVolume) },
                    set: { appState.setMasterVolume(Float($0)) }
                ), in: 0...1, step: 0.01)
                Text("\(Int(appState.masterVolume * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 30, alignment: .trailing)
            }

            // Audio mode
            Picker("", selection: Binding(
                get: { appState.audioMode },
                set: { appState.setAudioMode($0) }
            )) {
                Text("Normal").tag(AudioMode.normal)
                Label("Karaoke", systemImage: "music.mic").tag(AudioMode.karaoke)
                Label("Vocal+", systemImage: "person.wave.2").tag(AudioMode.vocalBoost)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            // Sleep timer
            if appState.sleepTimerMinutes != nil {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("\(appState.sleepTimerRemaining / 60):\(String(format: "%02d", appState.sleepTimerRemaining % 60))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange)
                    Spacer()
                    Button("×") { appState.setSleepTimer(minutes: nil) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 220)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Mini Widget Panel Controller

class MiniWidgetPanelController: NSPanel {
    static let shared = MiniWidgetPanelController()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    func show(_ appState: AppState) {
        let hostingView = NSHostingView(rootView: MiniWidgetView().environmentObject(appState))
        self.contentView = hostingView
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        self.setFrameOrigin(NSPoint(x: frame.maxX - 240, y: frame.maxY - 200))
        self.orderFrontRegardless()
    }

    func hide() {
        self.orderOut(nil)
    }
}
