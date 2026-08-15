import Combine
import Foundation
import Sparkle
import SwiftUI

struct AppUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicEDKey: String

    static func load(from bundle: Bundle) -> AppUpdateConfiguration? {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return nil
        }
        return validated(feed: feed, publicEDKey: key)
    }

    static func validated(feed: String, publicEDKey: String) -> AppUpdateConfiguration? {
        guard let url = URL(string: feed.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        let trimmedKey = publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedKey.contains("$(") else { return nil }
        return AppUpdateConfiguration(feedURL: url, publicEDKey: trimmedKey)
    }
}

@MainActor
final class AppUpdateCoordinator: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    let configuration: AppUpdateConfiguration?
    @Published private(set) var canCheckForUpdates = false

    private var cancellable: AnyCancellable?

    init(bundle: Bundle = .main) {
        configuration = AppUpdateConfiguration.load(from: bundle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: \.canCheckForUpdates, on: self)
        if configuration != nil {
            updaterController.startUpdater()
        }
    }

    var isConfigured: Bool { configuration != nil }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            guard isConfigured else { return }
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        guard isConfigured, canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var coordinator: AppUpdateCoordinator

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(AppLanguage.localized("检查更新…", english: "Check for Updates…")) {
                coordinator.checkForUpdates()
            }
            .disabled(!coordinator.isConfigured || !coordinator.canCheckForUpdates)
        }
    }
}
