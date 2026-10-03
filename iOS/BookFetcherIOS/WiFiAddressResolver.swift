import Darwin
import Foundation

enum WiFiAddressResolver {
    enum Mode: Equatable { case hotspot, wifi }
    struct Resolved: Equatable { let ip: String; let mode: Mode }

    /// iOS Personal Hotspot always puts the hosting iPhone at 172.20.10.1 (on a
    /// bridge interface). That fixed address is the whole point of the hotspot
    /// path: the e-reader bookmarks it once and it never drifts.
    static let hotspotIP = "172.20.10.1"

    /// Prefer the hotspot address (fixed, e-reader-friendly) over a regular Wi-Fi IP.
    static func resolve() -> Resolved? {
        var hotspot: String?
        var wifi: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = String(cString: item.pointee.ifa_name)
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let value = numericHost(address) else { continue }

            if value == hotspotIP {
                hotspot = value                       // this iPhone is sharing its hotspot
            } else if interface == "en0", isPrivateIPv4(value) {
                wifi = value                          // joined a normal Wi-Fi network
            }
        }
        if let hotspot { return Resolved(ip: hotspot, mode: .hotspot) }
        if let wifi { return Resolved(ip: wifi, mode: .wifi) }
        return nil
    }

    /// Back-compat plain address, hotspot preferred.
    static func privateIPv4() -> String? { resolve()?.ip }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: host)
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}
