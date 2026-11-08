import AVFoundation
import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // .playback: the click track is heard even with the silent switch on.
        // .mixWithOthers: a backing track playing from another app keeps playing.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // Keep the screen on for the whole rehearsal.
        application.isIdleTimerDisabled = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .black
        window.rootViewController = StageViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Hardware keyboards, page-turner pedals and clickers send keys to the first responder.
        stage.webView.becomeFirstResponder()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
