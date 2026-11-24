import UIKit
import Zharp

// E2E_ACTION (SIMCTL_CHILD_E2E_ACTION when launched with simctl):
//   segv     — a null pointer write in C (orders.c) 1.5 s after launch
//   cxx      — an uncaught std::runtime_error from C++ (cart.cpp)
//   relaunch — start, send the last run's crash, then stay up
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        Zharp.start { options in
            options.key = "zpk_e2e"
            options.service = "native-e2e"
            options.environment = "ci"
            options.endpoint = environment["ZHARP_ENDPOINT"]
            options.debug = true
        }
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()

        let action = environment["E2E_ACTION"] ?? "relaunch"
        print("native e2e: \(action)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            switch action {
            case "segv": native_e2e_null_write()
            case "cxx": native_e2e_cxx_throw()
            default: break
            }
        }
        return true
    }
}
