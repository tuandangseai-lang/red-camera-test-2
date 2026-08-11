import Foundation

struct SavedScanProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let subjectKind: ScanSubjectKind
    let referenceImages: [Data]
    let surfacePointCount: Int

    var shortName: String {
        name
    }
}

final class ScanProfileStore {
    private let maximumProfileCount = 5
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent(
            "RocketTracker",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("scan-profiles.json")
    }

    func load() -> [SavedScanProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode(
                [SavedScanProfile].self,
                from: data
              ) else { return [] }
        return Array(
            profiles
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(maximumProfileCount)
        )
    }

    @discardableResult
    func save(_ profile: SavedScanProfile) -> [SavedScanProfile] {
        var profiles = load().filter { $0.id != profile.id }
        profiles.insert(profile, at: 0)
        profiles = Array(profiles.prefix(maximumProfileCount))
        persist(profiles)
        return profiles
    }

    @discardableResult
    func delete(id: UUID) -> [SavedScanProfile] {
        let profiles = load().filter { $0.id != id }
        persist(profiles)
        return profiles
    }

    private func persist(_ profiles: [SavedScanProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
