import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
}
let h2d: [String: Any] = ["state": 2, "info": [
    ["id": 0, "snow": 3, "info": 1134],
    ["id": 1, "snow": 65024, "info": 1118]
]]
var routes = BambuFilamentRoutes()
routes.update(extruder: h2d, legacyTray: "3", dualNozzle: true)
check(routes.currentSource?.trayID == "0-3", "Active right AMS spool 4 survives inactive left external route")
check(routes.currentExtruderID == 0, "Physical right is extruder 0")
check(routes.sources[1] == .external, "Keep the left external route separately")
var reversed = BambuFilamentRoutes()
reversed.update(extruder: ["state": 2, "info": [
    ["id": "1", "snow": "65024"], ["id": "0", "snow": "3"]
]], legacyTray: "255", dualNozzle: true)
check(reversed.currentSource?.trayID == "0-3", "Entry ordering and legacy sentinel cannot change H2D selection")
routes.update(extruder: ["info": [["id": 1, "snow": 65024]]], legacyTray: "254", dualNozzle: true)
check(routes.currentSource?.trayID == "0-3", "Inactive-only incremental report preserves the active route")
routes.update(extruder: ["state": 18], legacyTray: nil, dualNozzle: true)
check(routes.currentExtruderID == 1 && routes.currentSource == .external, "State-only switch to left uses its cached route")
routes.update(extruder: ["state": 2], legacyTray: nil, dualNozzle: true)
check(routes.currentSource?.trayID == "0-3", "State-only switch back restores spool 4")
routes.update(extruder: nil, legacyTray: "255", dualNozzle: true)
check(routes.currentSource?.trayID == "0-3", "Legacy-only H2D packet cannot clear spool 4")
routes.update(extruder: ["state": 242], legacyTray: nil, dualNozzle: true)
check(routes.currentExtruderID == nil && routes.currentSource == nil, "Unknown current toolhead must not select the other toolhead")
var single = BambuFilamentRoutes()
for index in 0..<4 {
    single.update(extruder: nil, legacyTray: index, dualNozzle: false)
    check(single.currentSource?.trayID == "0-\(index)", "Legacy single-head spool \(index + 1)")
}
single.update(extruder: nil, legacyTray: "255", dualNozzle: false)
check(single.currentSource == .external, "Single-head external sentinel clears AMS")
single.update(extruder: ["state": 1, "info": [["id": 0, "snow": 3]]], legacyTray: "255", dualNozzle: false)
check(single.currentSource?.trayID == "0-3", "Nested active route outranks conflicting legacy field")
for (snow, source) in [(3, BambuFilamentRoutes.Source.ams(0, 3)), (0x8000, .ams(128, 0)), (0xFE00, .external), (0xFF00, .external), (0xFFFF, .empty)] {
    check(BambuFilamentRoutes.decode(snow) == source, "Decode physical/virtual/empty route")
}
check(BambuFilamentRoutes.decode(-1) == nil, "Ignore invalid negative route")
check(BambuFilamentRoutes.decode(65536) == nil, "Ignore oversized route")

for hours in 1...48 {
    let fields = BambuAMSDryingProtocol.fields(enabled: true, amsID: 0, durationHours: hours, temperature: 45, filament: "PETG")!
    check(fields["duration"] as? Int == hours, "Drying command must use hours, never minutes")
    check(fields["mode"] as? Int == 1, "Enabled drying mode")
    check(fields["rotate_tray"] as? Bool == false, "Keep drying without spool rotation")
    let encoded = try JSONSerialization.data(withJSONObject: fields)
    let decoded = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    check(decoded["duration"] as? Int == hours, "Wire JSON preserves integer hours")
}
let stop = BambuAMSDryingProtocol.fields(enabled: false, amsID: 0, durationHours: 8, temperature: 45, filament: "PETG")!
check(stop["duration"] as? Int == 0 && stop["mode"] as? Int == 0 && stop["temp"] as? Int == 0, "Stop drying sends zero duration/mode/temperature")
for hours in [0, 49, 480] {
    check(BambuAMSDryingProtocol.fields(enabled: true, amsID: 0, durationHours: hours, temperature: 45, filament: "") == nil, "Reject invalid hours")
}
check(BambuAMSDryingProtocol.fields(enabled: true, amsID: -1, durationHours: 8, temperature: 45, filament: "") == nil, "Reject invalid AMS")
check(BambuAMSDryingProtocol.fields(enabled: true, amsID: 0, durationHours: 8, temperature: 44, filament: "") == nil, "Reject invalid temperature")
print("Bambu AMS routing/drying regression: \(checks) checks passed; no printer connection")
