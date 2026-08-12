import Foundation

struct SavedScanProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let subjectKind: ScanSubjectKind
    let referenceImages: [Data]
    /// Ảnh crop thật từ 7 góc và các khung đại diện của video 10 giây. Dùng cho
    /// nhánh nhận diện cá nhân cùng với model tên lửa/chai có sẵn.
    let contextImages: [Data]?
    /// Số ảnh tĩnh nằm ở đầu `referenceImages` / `contextImages`. Phần còn lại là
    /// khung lấy từ video mẫu 10 giây. Tách nguồn để một góc video lặp lại không
    /// được tính thành nhiều phiếu độc lập khi xác minh danh tính.
    let photoReferenceCount: Int?
    let photoContextCount: Int?
    let surfacePointCount: Int
    let voxelOccupancy: [Bool]?
    let classificationLabel: String?

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
        // Bản cũ lưu tên lửa nước trong tab Vật. Tự chuyển những mẫu có nhãn
        // tên lửa/chai sang tab chuyên dụng để người dùng không phải chụp lại.
        let migratedProfiles = profiles.map { profile -> SavedScanProfile in
            let label = profile.classificationLabel?.lowercased() ?? ""
            let isLegacyRocket = profile.subjectKind == .object
                && (label.contains("tên lửa")
                    || label.contains("rocket")
                    || label.contains("chai")
                    || label.contains("bottle"))
            guard isLegacyRocket else { return profile }
            return SavedScanProfile(
                id: profile.id,
                name: profile.name,
                createdAt: profile.createdAt,
                subjectKind: .waterRocket,
                referenceImages: profile.referenceImages,
                contextImages: profile.contextImages,
                photoReferenceCount: profile.photoReferenceCount,
                photoContextCount: profile.photoContextCount,
                surfacePointCount: profile.surfacePointCount,
                voxelOccupancy: profile.voxelOccupancy,
                classificationLabel: profile.classificationLabel
            )
        }
        return Array(
            migratedProfiles
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

    @discardableResult
    func rename(id: UUID, to name: String) -> [SavedScanProfile] {
        let profiles = load().map { profile in
            guard profile.id == id else { return profile }
            return SavedScanProfile(
                id: profile.id,
                name: name,
                createdAt: profile.createdAt,
                subjectKind: profile.subjectKind,
                referenceImages: profile.referenceImages,
                contextImages: profile.contextImages,
                photoReferenceCount: profile.photoReferenceCount,
                photoContextCount: profile.photoContextCount,
                surfacePointCount: profile.surfacePointCount,
                voxelOccupancy: profile.voxelOccupancy,
                classificationLabel: profile.classificationLabel
            )
        }
        persist(profiles)
        return profiles
    }

    private func persist(_ profiles: [SavedScanProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
