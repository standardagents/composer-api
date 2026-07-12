import Foundation

final class CursorSDKBridgePortPreference: @unchecked Sendable {
    static let defaultsKey = "CursorAPI.sdkBridgePort.v1"
    static let defaultPort: UInt16 = 8792
    private static let allowedPorts: [UInt16] = Array(8792...8892).compactMap(UInt16.init(exactly:))

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preferredPort() -> UInt16 {
        lock.withLock {
            resolvedPort(from: defaults.object(forKey: Self.defaultsKey)) ?? Self.defaultPort
        }
    }

    func candidatePorts() -> [UInt16] {
        let preferred = preferredPort()
        return [preferred] + Self.allowedPorts.filter { $0 != preferred }
    }

    func recordSuccessfulPort(_ port: UInt16) {
        guard Self.allowedPorts.contains(port) else { return }
        lock.withLock {
            defaults.set(Int(port), forKey: Self.defaultsKey)
        }
    }

    private func resolvedPort(from rawValue: Any?) -> UInt16? {
        if let number = rawValue as? NSNumber,
           let port = UInt16(exactly: number.intValue),
           Self.allowedPorts.contains(port) {
            return port
        }
        if let text = rawValue as? String,
           let value = Int(text),
           let port = UInt16(exactly: value),
           Self.allowedPorts.contains(port) {
            return port
        }
        return nil
    }
}
