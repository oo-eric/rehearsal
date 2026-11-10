import UIKit

// Custom UIApplication so hardware key presses (Bluetooth page-turner pedals,
// keyboards) can be caught before WebKit, which only delivers them to the page
// when its hidden content view holds keyboard focus.
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
                  NSStringFromClass(RehearsalApplication.self),
                  NSStringFromClass(AppDelegate.self))
