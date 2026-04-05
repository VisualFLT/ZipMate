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
    }
}
