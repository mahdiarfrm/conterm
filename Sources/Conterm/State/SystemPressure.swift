import Foundation

/// Publishes whether the machine is under power or thermal pressure:
/// Low Power Mode, or a thermal state of `.serious` or worse. Views
/// with purely decorative per-frame animation (the agent pill sweep)
/// drop to their low-animation rendering while this is true — on a
/// fanless machine the ornament is exactly what keeps the case hot,
/// so it must yield first.
@MainActor
final class SystemPressure: ObservableObject {
    static let shared = SystemPressure()

    @Published private(set) var wantsLowAnimation: Bool

    private var observers: [NSObjectProtocol] = []

    private init() {
        wantsLowAnimation = Self.evaluate()
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
        ]
        for n in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: n, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
    }

    private func reevaluate() {
        let v = Self.evaluate()
        if v != wantsLowAnimation { wantsLowAnimation = v }
    }

    private static func evaluate() -> Bool {
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled
            || p.thermalState == .serious
            || p.thermalState == .critical
    }
}
