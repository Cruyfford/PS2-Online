import SwiftUI
import UIKit

@main
struct PS2OnlineApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

struct RootView: View {
    @StateObject private var app = AppModel()
    @ObservedObject private var account = Account.shared
    @AppStorage("smooth") private var smooth = false

    var body: some View {
        Group {
            if account.isLoggedIn {
                home
            } else {
                AuthView().environmentObject(account)
            }
        }
        .onAppear { account.refresh() }
        .onChange(of: account.user) { _ in app.connectLobby() }
        .onChange(of: account.isLoggedIn) { inn in if !inn { app.logoutCleanup() } }
    }

    private var home: some View {
        HomeView()
            .environmentObject(app)
            .environmentObject(app.lobby)
            .environmentObject(account)
            .onAppear { app.connectLobby() }
            .onChange(of: app.runner == nil) { _ in app.connectLobby() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                app.connectLobby()
            }
            .onOpenURL { url in _ = app.importROM(url) }
            .fullScreenCover(isPresented: Binding(get: { app.runner != nil },
                                                  set: { if !$0 { app.stop() } })) {
                if let r = app.runner {
                    GameView(runner: r, smooth: smooth, onExit: { app.stop() })
                }
            }
    }
}
