#if targetEnvironment(simulator)
import Foundation

/// Deterministic UI fixtures, compiled only for Simulator. They never connect
/// to a printer or change the device build's behavior.
enum SEInterfaceCheck {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--se-interface-check")
    }
    static var isTimelapse: Bool {
        ProcessInfo.processInfo.arguments.contains("--se-interface-check-timelapse")
    }
    static var isIdle: Bool {
        ProcessInfo.processInfo.arguments.contains("--se-interface-check-idle")
    }
    static var isPaused: Bool {
        ProcessInfo.processInfo.arguments.contains("--se-interface-check-paused")
    }
    static var showsControlFailure: Bool {
        ProcessInfo.processInfo.arguments.contains("--se-interface-check-control-failure")
    }
    static let profile = BambuPrinterProfile(
        profileID: "interface-check-h2d", kind: .h2d,
        ip: "192.0.2.1", serial: "094-INTERFACE-CHECK"
    )

    static func prepareDefaults() {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        BambuPrinterProfileStore.save(profile)
        H2DAccessCodeStore.save("12345678", forProfileID: profile.id)
        defaults.set(profile.ip, forKey: "SE.H2D.printerIP")
        defaults.set(profile.serial, forKey: "SE.H2D.printerSerial")
        defaults.set("Interface check", forKey: "SE.H2D.wifiSSID")
        defaults.set(true, forKey: "SE.H2D.configurationSaved")
        defaults.set(false, forKey: "SE.Bambu.printerCameraEnabled")
        defaults.set("en", forKey: "SE.AppLanguage")
        defaults.set(753.2, forKey: "SE.Bambu.lifetimePrintHours.094-INTERFACE-CHECK")
    }

    static var snapshot: BambuDirectSnapshot {
        var value = BambuDirectSnapshot()
        value.printState = isIdle ? "IDLE" : (isPaused ? "PAUSED" : "RUNNING")
        value.printPercent = 38
        value.currentLayer = 91
        value.totalLayers = 242
        value.remainingMinutes = 72
        value.nozzleTemperature = 250
        value.nozzleTargetTemperature = 250
        value.leftNozzleTemperature = 215
        value.leftNozzleTargetTemperature = 220
        value.bedTemperature = 58
        value.bedTargetTemperature = 60
        value.printSpeedLevel = 2
        value.printStage = 0
        value.extruderCount = 2
        value.currentExtruderID = 0
        value.externalSpoolExtruderID = 1
        value.externalFilamentPresent = true
        value.filamentPresentByExtruder = [0: true, 1: true]
        value.filamentMaterialByExtruder = [0: "PETG", 1: "PLA"]
        value.filamentColorHexByExtruder = [0: "087D55", 1: "479CEB"]
        value.chamberLightOn = true
        value.hasAMS = true
        value.amsDryerUnitID = 0
        value.amsDrying = true
        value.amsDryingRemainingMinutes = 420
        value.amsHumidityPercentByUnit = [0: 39]
        value.currentAMSTrayID = "0-1"
        let colors = ["FAFAFA", "087D55", "FD8A33", "F23142"]
        value.amsTrays = colors.enumerated().map { index, color in
            BambuAMSTraySnapshot(
                amsID: 0, slotID: index, material: "PETG", colorHex: color,
                isPresent: true, extruderID: 0, dryingTemperature: 55, dryingHours: 8
            )
        }
        value.receivedAt = Date()
        return value
    }
}
#endif
