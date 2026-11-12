import AVFoundation
import SwiftUI
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // .playback: the click track is heard even with the silent switch on.
        // .mixWithOthers: a backing track playing from another app keeps playing.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // Keep the screen on for the whole rehearsal.
        application.isIdleTimerDisabled = true
        return true
    }

    // iOS 27 terminates apps that haven't adopted the UIScene lifecycle (it crashed on
    // launch on an iPhone on 27.0), so the window lives in SceneDelegate. UIScene is iOS 13+.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var core: AppCore?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let core = AppCore()
        self.core = core
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = StageController(rootView: StageView(model: core.model))
        window.makeKeyAndVisible()
        self.window = window
        // Hardware keys (Bluetooth page-turner pedals, keyboards) are caught app-wide.
        RehearsalApplication.onKey = { [weak core] name, detail in core?.model.key(name, detail: detail) }
        #if DEBUG
        // Tests: `simctl launch <device> <bundle id> -ooKeys "Enter,],ArrowRight,p"` presses
        // those keys a beat apart after launch.
        if let i = CommandLine.arguments.firstIndex(of: "-ooKeys"), i + 1 < CommandLine.arguments.count {
            for (n, k) in CommandLine.arguments[i + 1].split(separator: ",").enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(n) * 0.4) { [weak core] in
                    core?.model.key(String(k), detail: "test")
                }
            }
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

/// Full screen, no status bar, home indicator tucked away.
final class StageController: UIHostingController<StageView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}
