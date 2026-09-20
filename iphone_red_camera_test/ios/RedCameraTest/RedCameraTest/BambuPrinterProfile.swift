import Foundation

enum BambuPrinterKind: String, Codable, CaseIterable, Hashable, Identifiable {
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
}

struct BambuPrinterProfile: Codable, Equatable, Identifiable {
    var profileID: String?
    var kind: BambuPrinterKind
    var ip: String
    var serial: String
    var customName: String?

    var id: String {
        if let profileID, !profileID.isEmpty { return profileID }
        return "legacy-\(serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
    }

    var displayName: String {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? kind.rawValue : trimmed
    }

    init(
        profileID: String = UUID().uuidString,
        kind: BambuPrinterKind,
        ip: String,
        serial: String,
        customName: String? = nil
    ) {
        self.profileID = profileID
        self.kind = kind
        self.ip = ip
        self.serial = serial
        self.customName = customName
    }
}

enum BambuPrinterProfileStore {
    static let maximumProfiles = 3
    private static let key = "SE.Bambu.printerProfiles.v2"
    private static let legacyKey = "SE.Bambu.printerProfiles.v1"

    static func load() -> [BambuPrinterProfile] {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: key) ?? defaults.data(forKey: legacyKey)
        guard let data,
              var profiles = try? JSONDecoder().decode([BambuPrinterProfile].self, from: data) else {
            return []
        }
        var changed = defaults.data(forKey: key) == nil
        for index in profiles.indices where profiles[index].profileID?.isEmpty != false {
            profiles[index].profileID = UUID().uuidString
            changed = true
        }
        if profiles.count > maximumProfiles {
            profiles = Array(profiles.prefix(maximumProfiles))
            changed = true
        }
        if changed { write(profiles) }
        return profiles
    }

    static func save(_ profile: BambuPrinterProfile) {
        guard profile.kind != .unknown else { return }
        var normalized = profile
        if normalized.profileID?.isEmpty != false {
            normalized.profileID = UUID().uuidString
        }
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == normalized.id }) {
            profiles[index] = normalized
        } else if profiles.count < maximumProfiles {
            profiles.append(normalized)
        }
        write(profiles)
    }

    static func profile(for kind: BambuPrinterKind) -> BambuPrinterProfile? {
        load().first { $0.kind == kind }
    }

    static func profile(id: String) -> BambuPrinterProfile? {
        load().first { $0.id == id }
    }

    static func profile(serial: String) -> BambuPrinterProfile? {
        let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return load().first {
            $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalized
        }
    }

    static func remove(id: String) {
        write(load().filter { $0.id != id })
    }

    static func reorder(movingID: String, before targetID: String) -> [BambuPrinterProfile] {
        var profiles = load()
        guard movingID != targetID,
              let source = profiles.firstIndex(where: { $0.id == movingID }),
              let target = profiles.firstIndex(where: { $0.id == targetID }) else {
            return profiles
        }
        let moved = profiles.remove(at: source)
        let destination = source < target ? target - 1 : target
        profiles.insert(moved, at: max(0, min(destination, profiles.count)))
        write(profiles)
        return profiles
    }

    private static func write(_ profiles: [BambuPrinterProfile]) {
        guard let data = try? JSONEncoder().encode(Array(profiles.prefix(maximumProfiles))) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
