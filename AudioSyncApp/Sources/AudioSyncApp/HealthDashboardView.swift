import SwiftUI

// MARK: - Health Dashboard View

struct HealthDashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "heart.text.clipboard")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Device Health Dashboard")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Per-device health
            if appState.deviceDiscovery.devices.isEmpty {
                Text("No devices connected")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(appState.orderedDevicesForHealth, id: \.uid) { device in
                        DeviceHealthRow(device: device)
                            .environmentObject(appState)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Device Health Row

struct DeviceHealthRow: View {
    let device: AudioOutputDevice
    @EnvironmentObject var appState: AppState

    private var health: DeviceHealth {
        appState.outputEngine.healthReport(for: device.uid)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(health.isHealthy ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            // Device info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(device.transportType.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(width: 140, alignment: .leading)

            Divider()
                .frame(height: 30)

            // Metrics
            HealthMetric(label: "Buffer", value: String(format: "%.0f%%", health.bufferFillPercent), color: health.bufferFillPercent < 20 ? .red : health.bufferFillPercent > 90 ? .orange : .green)
            HealthMetric(label: "Underruns", value: "\(health.underrunCount)", color: health.underrunCount > 0 ? .orange : .green)
            HealthMetric(label: "Drift", value: String(format: "%.0f", health.avgDrift), color: abs(health.avgDrift) > 200 ? .red : abs(health.avgDrift) > 50 ? .orange : .green)
            HealthMetric(label: "Latency", value: String(format: "%.0fms", health.latencyMs), color: health.latencyMs > 300 ? .red : health.latencyMs > 150 ? .orange : .green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(health.isHealthy ? Color.green.opacity(0.2) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

struct HealthMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(width: 62)
    }
}
