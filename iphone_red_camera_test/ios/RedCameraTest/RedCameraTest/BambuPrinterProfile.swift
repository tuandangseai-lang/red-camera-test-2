import Foundation

enum BambuPrinterKind: String, Codable, CaseIterable, Identifiable {
    case a1 = "A1"
    case h2d = "H2D"
    case p2s = "P2S"
    case unknown = "Bambu"

    var id: String { rawValue }

    static func detect(serial: String) -> BambuPrinterKind {
        let normalized = serial
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if normalized.hasPrefix("039") || normalized.hasPrefix("030") { return .a1 }
        if normalized.hasPrefix("094") { return .h2d }
        if normalized.hasPrefix("22E") { return .p2s }
        return .unknown
    }

    var cameraDescription: String {
        switch self {
        case .h2d: return "RTSPS trực tiếp • cổng 322"
        case .a1: return "Live View LAN • cổng 6000"
        case .p2s: return "Live View phụ thuộc firmware/khu vực của P2S"
        case .unknown: return "Nhập serial để SE chọn đúng camera"
        }
    }
}

struct BambuPrinterProfile: Codable, Equatable, Identifiable {
    var kind: BambuPrinterKind
    var ip: String
    var serial: String

    var id: String { kind.rawValue }
}

enum BambuPrinterProfileStore {
    private static let key = "SE.Bambu.printerProfiles.v1"

    static func load() -> [BambuPrinterProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profiles = try? JSONDecoder().decode([BambuPrinterProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func save(_ profile: BambuPrinterProfile) {
        guard profile.kind != .unknown else { return }
        var profiles = load().filter { $0.kind != profile.kind }
        profiles.append(profile)
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func profile(for kind: BambuPrinterKind) -> BambuPrinterProfile? {
        load().first { $0.kind == kind }
    }
}
