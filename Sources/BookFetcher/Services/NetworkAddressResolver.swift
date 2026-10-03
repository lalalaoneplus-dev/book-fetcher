import Foundation

public enum NetworkAddressResolver {
    public static func privateWiFiIPv4() -> String? {
        let result = try? ProcessRunner().run(
            executable: "/usr/sbin/ipconfig",
            arguments: ["getifaddr", "en0"]
        )
        guard let address = result?.output.trimmingCharacters(in: .whitespacesAndNewlines),
              isPrivateIPv4(address) else {
            return nil
        }
        return address
    }

    public static func isPrivateIPv4(_ address: String) -> Bool {
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") {
            return true
        }

        let components = address.split(separator: ".")
        guard components.count == 4,
              components[0] == "172",
              let second = Int(components[1]) else {
            return false
        }
        return (16...31).contains(second)
    }
}
