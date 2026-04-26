import Foundation

/// Lightweight runtime tuning for older iPads (notably 2018 12.9" A12X).
enum DevicePerformanceProfile {
    case standard
    case ipadPro2018A12X

    static var current: DevicePerformanceProfile {
        let model = hardwareIdentifier()
        // 2018 iPad Pro 12.9": iPad8,5 iPad8,6 iPad8,7 iPad8,8
        if model.hasPrefix("iPad8,") {
            return .ipadPro2018A12X
        }
        return .standard
    }

    var isConstrained: Bool {
        switch self {
        case .standard: return false
        case .ipadPro2018A12X: return true
        }
    }

    var preferredFPS: Int {
        isConstrained ? 30 : 60
    }

    var enableEnvironmentTexturing: Bool {
        !isConstrained
    }

    var handTrackingInterval: TimeInterval {
        // 2018 iPad Pro: keep Vision hand work above ~12 Hz so pinch/grab stays responsive.
        isConstrained ? (1.0 / 22.0) : (1.0 / 30.0)
    }

    var placementTickInterval: TimeInterval {
        isConstrained ? (1.0 / 20.0) : (1.0 / 30.0)
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}
