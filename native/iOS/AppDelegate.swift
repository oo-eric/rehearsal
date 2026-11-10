import AVFoundation
import UIKit
import WebKit

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

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = StageViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

final class StageViewController: UIViewController {
    private let stage = Stage()

    override func loadView() {
        view = stage.webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        stage.load()
        RehearsalApplication.onKey = { [weak self] name, detail in self?.stage.sendKey(name, detail: detail) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Hardware keyboards, page-turner pedals and clickers send keys to the first responder.
        stage.webView.becomeFirstResponder()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
