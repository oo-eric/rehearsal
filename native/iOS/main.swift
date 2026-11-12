import UIKit

// Custom UIApplication so hardware key presses (Bluetooth page-turner pedals,
// keyboards) are caught app-wide, whatever has focus.
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
                  NSStringFromClass(RehearsalApplication.self),
                  NSStringFromClass(AppDelegate.self))
