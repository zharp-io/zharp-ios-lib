import Foundation
import ZharpCore

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC
#endif

/// Screen views, two ways:
///
/// - UIKit: automatic. `viewWillAppear`/`viewDidAppear` are swizzled once on UIViewController, so
///   every screen the app's own view controllers show is recorded under the class name, with the
///   time it took to appear. Container controllers (navigation, tab bar, split, page) and system
///   controllers (alerts, keyboards, SwiftUI's hosting controllers) are skipped.
/// - SwiftUI: `.zharpScreen("Checkout")` on the screen's root view. SwiftUI screens all live in
///   the same `UIHostingController` class, so swizzling can't tell them apart or name them; an
///   explicit name is the only reliable source.
enum ScreenTracking {
    private static let lock = NSLock()
    private static var installed = false

    static func installUIKit() {
        #if canImport(UIKit) && !os(watchOS)
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swizzle(#selector(UIViewController.viewWillAppear(_:)), with: #selector(UIViewController.zharp_viewWillAppear(_:)))
        swizzle(#selector(UIViewController.viewDidAppear(_:)), with: #selector(UIViewController.zharp_viewDidAppear(_:)))
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private static func swizzle(_ original: Selector, with replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, original),
              let replacementMethod = class_getInstanceMethod(UIViewController.self, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// The app's own content controllers.
    static func shouldTrack(_ controller: UIViewController) -> Bool {
        if controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController {
            return false
        }
        let bundlePath = Bundle(for: type(of: controller)).bundlePath
        return bundlePath.hasPrefix(Bundle.main.bundlePath)
    }
    #endif
}

#if canImport(UIKit) && !os(watchOS)
private var zharpAppearStartKey: UInt8 = 0

extension UIViewController {
    // After the swizzle these names point at UIKit's originals, so the calls below are the
    // original viewWillAppear / viewDidAppear, not recursion.
    @objc func zharp_viewWillAppear(_ animated: Bool) {
        zharp_viewWillAppear(animated)
        guard ScreenTracking.shouldTrack(self) else { return }
        objc_setAssociatedObject(self, &zharpAppearStartKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc func zharp_viewDidAppear(_ animated: Bool) {
        zharp_viewDidAppear(animated)
        guard ScreenTracking.shouldTrack(self), let runtime = ZharpRuntime.shared else { return }
        let start = objc_getAssociatedObject(self, &zharpAppearStartKey) as? Date
        objc_setAssociatedObject(self, &zharpAppearStartKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        runtime.screenDidAppear(ScreenNaming.name(fromClassName: String(describing: type(of: self))), start: start)
    }
}
#endif

#if canImport(SwiftUI)
struct ZharpScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.onAppear { Zharp.trackScreen(name) }
    }
}

public extension View {
    /// Records a screen view named `name` each time this view appears. Put it on each screen's
    /// root view:
    ///
    /// ```swift
    /// CheckoutView().zharpScreen("Checkout")
    /// ```
    func zharpScreen(_ name: String) -> some View {
        modifier(ZharpScreenModifier(name: name))
    }
}
#endif
