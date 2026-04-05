import SwiftUI

@main
struct ZipMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()
    private let launchCommand = LaunchCommandParser.parse(arguments: CommandLine.arguments)

    init() {
        DebugLogger.reset()
        DebugLogger.log("App launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 920, minHeight: 680)
                .task {
                    viewModel.handleLaunchCommand(launchCommand)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ZipMate") {
                    showAboutPanel()
                }
            }
        }
    }

    private func showAboutPanel() {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ZipMate",
            .applicationVersion: "Version \(shortVersion) (\(build))",
            .credits: NSAttributedString(string: "Minimal 7-Zip UI for macOS")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
