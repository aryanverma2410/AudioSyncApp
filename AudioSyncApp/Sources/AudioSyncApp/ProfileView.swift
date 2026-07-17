import SwiftUI

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var editName: String = ""
    @State private var isEditing = false
    @State private var showDeleteConfirm = false

    var body: some View {
        Group {
            if let profile = appState.profileManager.selectedProfile {
                profileContent(profile)
            } else {
                emptyProfileView
            }
        }
    }

    // MARK: - Profile Content

    private func profileContent(_ profile: AudioProfile) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Profile header
            HStack {
                if isEditing {
                    TextField("Profile name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveName(profile) }
                } else {
                    Text(profile.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Spacer()

                Button {
                    if isEditing {
                        saveName(profile)
                    } else {
                        editName = profile.name
                        isEditing = true
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()

            // Device settings in this profile
            List {
                Section("Device Settings") {
                    if profile.deviceSettings.isEmpty {
                        Text("No device settings saved in this profile.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(Array(profile.deviceSettings.keys.sorted()), id: \.self) { deviceUID in
                            if let settings = profile.deviceSettings[deviceUID] {
                                HStack {
                                    Image(systemName: "hifispeaker")
                                        .foregroundColor(.accentColor)
                                    Text(deviceUID)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Delay: \(Int(settings.delayMs))ms")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Vol: \(Int(settings.volume * 100))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            // Actions
            HStack(spacing: 12) {
                Button {
                    appState.applyProfile(profile)
                } label: {
                    Label("Apply Profile", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    _ = appState.profileManager.saveAsProfile(
                        named: "Snapshot \(Date().formatted(date: .abbreviated, time: .shortened))",
                        deviceSettings: appState.deviceSettings
                    )
                } label: {
                    Label("Save Current State", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .confirmationDialog("Delete Profile?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                appState.profileManager.deleteProfile(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Empty State

    private var emptyProfileView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Profile Selected")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Select a profile from the sidebar or create a new one.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func saveName(_ profile: AudioProfile) {
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appState.profileManager.renameProfile(profile, to: trimmed)
        }
        isEditing = false
    }
}
