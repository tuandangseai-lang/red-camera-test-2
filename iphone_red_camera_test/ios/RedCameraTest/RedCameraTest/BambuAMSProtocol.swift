import Foundation

/// Routing is per physical toolhead. An external spool on the inactive H2D
/// toolhead must never replace the AMS source of the current toolhead.
struct BambuFilamentRoutes {
    enum Source: Equatable {
        case ams(Int, Int)
        case external
        case empty

        var trayID: String? {
            if case let .ams(unit, slot) = self { return "\(unit)-\(slot)" }
            return nil
        }
    }

    private(set) var extruderCount = 1
    private(set) var currentExtruderID: Int?
    private(set) var sources: [Int: Source] = [:]

    var currentSource: Source? {
        currentExtruderID.flatMap { sources[$0] }
    }

    static func decode(_ snow: Int) -> Source? {
        guard (0...0xFFFF).contains(snow) else { return nil }
        if snow == 0xFFFF { return .empty }
        let unit = (snow >> 8) & 0xFF
        let slot = snow & 0xFF
        if unit == 254 || unit == 255 { return .external }
        guard slot < 255 else { return .empty }
        return .ams(unit, slot)
    }

    /// Keeps routes across incremental packets, including state-only toolhead
    /// switches. Legacy tray_now is only authoritative on single-head models.
    @discardableResult
    mutating func update(extruder: [String: Any]?, legacyTray: Any?, dualNozzle: Bool) -> Bool {
        func number(_ value: Any?) -> Int? {
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }
        if dualNozzle { extruderCount = max(2, extruderCount) }
        var changed = false
        if let state = number(extruder?["state"]), state >= 0 {
            extruderCount = max(1, state & 0xF)
            let current = (state >> 4) & 0xF
            currentExtruderID = current < extruderCount ? current : nil
            changed = true
        } else if !dualNozzle {
            currentExtruderID = 0
        }
        var reportedActiveRoute = false
        for (index, entry) in (extruder?["info"] as? [[String: Any]] ?? []).enumerated() {
            let id = number(entry["id"]) ?? index
            guard (0..<extruderCount).contains(id),
                  let snow = number(entry["snow"]), let source = Self.decode(snow) else { continue }
            sources[id] = source
            reportedActiveRoute = reportedActiveRoute || id == currentExtruderID
            changed = true
        }
        if !dualNozzle, extruderCount == 1, !reportedActiveRoute,
           let tray = number(legacyTray), (0...255).contains(tray) {
            sources[0] = tray < 254 ? .ams(tray >> 2, tray & 3) : .external
            changed = true
        }
        return changed
    }
}

enum BambuAMSDryingProtocol {
    static func fields(enabled: Bool, amsID: Int, durationHours: Int,
                       temperature: Int, filament: String) -> [String: Any]? {
        guard amsID >= 0, (1...48).contains(durationHours), (45...90).contains(temperature) else { return nil }
        return [
            "ams_id": amsID,
            "cooling_temp": enabled ? 45 : 40,
            // Command duration / dry_setting.dry_duration are HOURS.
            // Status dry_time is remaining MINUTES; do not convert the command.
            "duration": enabled ? durationHours : 0,
            "humidity": enabled ? 20 : 0,
            "mode": enabled ? 1 : 0,
            "rotate_tray": false,
            "temp": enabled ? temperature : 0,
            "filament": enabled ? filament : "",
            "close_power_conflict": false
        ]
    }
}
