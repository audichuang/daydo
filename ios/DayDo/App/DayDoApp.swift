import MachO
import os
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications
import DayDoCore

@main
struct DayDoApp: App {
    @State private var model: AppModel
    @State private var suspensionCoordinator = DatabaseSuspensionCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    private let appDefaults: UserDefaults

    init() {
        let (store, tokenStore, defaults, sharedDefaults) = Self.makeStorage()
        self.appDefaults = defaults
#if DEBUG
        let useStub = ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub")
        let effectiveTokenStore: any SyncTokenStore = useStub ? InMemorySyncTokenStore() : tokenStore
        let m = AppModel(
            store: store,
            tokenStore: effectiveTokenStore,
            transport: useStub ? DebugStubTransport() : nil,
            defaults: defaults,
            sharedDefaults: sharedDefaults
        )
#else
        let m = AppModel(
            store: store,
            tokenStore: tokenStore,
            defaults: defaults,
            sharedDefaults: sharedDefaults
        )
#endif
        _model = State(initialValue: m)
        // Match the always-dark LaunchBackground (#0E0F10) on the connecting scene before the
        // first frame; RootView switches to `model.appearance` once SplashOverlay finishes dismissing.
        AppearanceApplier.applyStyle(.dark)
        UNUserNotificationCenter.current().delegate = m.notificationDelegate
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    @MainActor
    static func handleScenePhaseChange(
        from oldPhase: ScenePhase,
        to phase: ScenePhase,
        model: AppModel,
        coordinator: DatabaseSuspensionCoordinator
    ) {
        if phase == .background {
            coordinator.enterBackground()
            return
        }
        if oldPhase == .background {
            coordinator.leaveBackground()
        }
        if phase == .active && model.ready && model.isSignedIn {
            Task { await model.reloadData() }
            model.triggerSyncNow()
        }
    }

    nonisolated static let isMacDebug: Bool = {
#if DEBUG
        Platform.isMac
#else
        false
#endif
    }()

    static func makeStorage() -> (DeviceStore, KeychainSyncTokenStore, UserDefaults, UserDefaults?) {
        let isMacDebug = Self.isMacDebug
        let dir: URL = isMacDebug
            ? URL.applicationSupportDirectory.appendingPathComponent("DayDo-Debug", isDirectory: true)
            : DayDoStorage.defaultDirectory()
        let tokenStore = KeychainSyncTokenStore()
        let defaultsSuite: String? = isMacDebug
            ? (Bundle.main.bundleIdentifier ?? "com.audichuang.daydo") + ".debug"
            : nil
        let defaults: UserDefaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        let sharedDefaults: UserDefaults? = isMacDebug ? nil : UserDefaults(suiteName: DayDoStorage.appGroup)

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DayDoReset") {
            try? FileManager.default.removeItem(at: dir)
            if let suite = defaultsSuite {
                defaults.removePersistentDomain(forName: suite)
            } else if let bundle = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundle)
            }
            tokenStore.clearAll()
        }
#endif
        do {
            let store = try DayDoStorage.openForApp(in: dir)
            return (store, tokenStore, defaults, sharedDefaults)
        } catch {
            fatalError("Cannot open database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.accent, model.accent)
                .environment(\.textScale, CGFloat(model.textScale) * (Platform.isMac ? 0.86 : 1))
                .defaultAppStorage(appDefaults)
                .tint(model.accent.color)
                .task {
                    await model.launch()
                }
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    if let code = SyncEngine.parseInviteCode(from: url) {
                        model.handleIncomingInvite(code: code)
                        return
                    }
                    if let link = WidgetDeepLink(url: url) {
                        model.handleWidgetDeepLink(link)
                    }
                }
                // Database suspension & foreground refresh/sync.
                .onChange(of: scenePhase) { oldPhase, phase in
                    Self.handleScenePhaseChange(
                        from: oldPhase,
                        to: phase,
                        model: model,
                        coordinator: suspensionCoordinator
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    if model.ready && model.isSignedIn { Task { await model.reloadData() } }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增任務") {
                    guard model.isSignedIn, !model.hasActiveRootSheet, model.canComposeForCurrentScope else { return }
                    model.openComposerForCurrentScope()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isSignedIn || model.hasActiveRootSheet || !model.canComposeForCurrentScope)
            }
            CommandMenu("前往") {
                Button("任務") { model.tab = .tasks }
                    .keyboardShortcut("1", modifiers: .command)
                Button("日曆") { model.tab = .calendar }
                    .keyboardShortcut("2", modifiers: .command)
                Button("搜尋") {
                    guard model.isSignedIn, !model.hasActiveRootSheet else { return }
                    model.tab = .search
                    model.searchFocusTrigger += 1
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!model.isSignedIn || model.hasActiveRootSheet)
                Button("搜尋任務") {
                    guard model.isSignedIn, !model.hasActiveRootSheet else { return }
                    model.tab = .search
                    model.searchFocusTrigger += 1
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!model.isSignedIn || model.hasActiveRootSheet)
                Button("設定") { model.tab = .settings }
                    .keyboardShortcut("4", modifiers: .command)
                if Platform.isMac {
                    Divider()
                    Button("上一頁") {
                        model.triggerCalendarCommand(.previous)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.isSignedIn || model.hasActiveRootSheet || model.tab != .calendar)
                    Button("下一頁") {
                        model.triggerCalendarCommand(.next)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.isSignedIn || model.hasActiveRootSheet || model.tab != .calendar)
                    Button("回到今天") {
                        model.triggerCalendarCommand(.today)
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!model.isSignedIn || model.hasActiveRootSheet || model.tab != .calendar)
                }
            }
        }
    }
}
