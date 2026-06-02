import SwiftUI
import AppKit

@main
struct MacVoxCPMApp: App {
    @State private var sidecar = SidecarManager()
    @State private var store = AudioStore()
    @State private var showOnboarding: Bool = true

    init() {
        // Ensure all our directories exist up-front.
        _ = AppPaths.applicationSupport
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sidecar)
                .environment(store)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    await sidecar.bootstrapIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    sidecar.shutdown()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Open Application Support Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.applicationSupport])
                }
            }
        }

        Settings {
            AppSettingsView()
                .environment(sidecar)
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(SidecarManager.self) private var sidecar

    var body: some View {
        switch sidecar.phase {
        case .ready:
            GeneratorView()
        case .failed:
            FailureView()
        default:
            OnboardingView()
        }
    }
}
