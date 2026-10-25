import SecureDevice
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set the delegate before launch finishes so a tap on a notification that launched the app isn't lost.
        NotificationService.shared.configure()
        return true
    }
}

@main
struct SecureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    /// The additional features (credit score, accounts, markets) run beside the wallet with their own store.
    @State private var connected = ConnectedModel()
    /// Phone-to-phone payments, active while the Nearby screen is open.
    @State private var nearby = NearbyModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(connected)
                .environment(nearby)
                .task { await model.start() }
                .task { await connected.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Opening wallet…")
        case .failed(let message):
            ContentUnavailableView("Wallet unavailable", systemImage: "lock.trianglebadge.exclamationmark", description: Text(message))
        case .ready:
            TabView {
                Tab("Wallet", systemImage: "wallet.bifold") { HomeView() }
                Tab("Accounts", systemImage: "building.columns") { AccountsView() }
                Tab("Markets", systemImage: "chart.line.uptrend.xyaxis") { MarketsView() }
                Tab("Learn", systemImage: "book") { LearnView() }
                Tab("Profile", systemImage: "person.crop.circle") { ProfileView() }
            }
        }
    }
}
