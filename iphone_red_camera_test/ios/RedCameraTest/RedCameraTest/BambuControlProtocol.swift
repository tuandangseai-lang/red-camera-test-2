import Foundation

/// Pure protocol rules, shared by the LAN client and offline regression tests.
/// Nothing here opens a connection or replays a physical printer command.
enum BambuControlProtocol {
    struct Reply: Equatable {
        let succeeded: Bool
        let reason: String?
    }

    static func commandFields(section: String, command: String, fields: [String: Any]) -> [String: Any] {
        var body = fields
        if section == "print", ["pause", "resume", "stop"].contains(command), body["param"] == nil {
            // Match Bambu Studio's task controls, including the empty parameter.
            body["param"] = ""
        }
        return body
    }

    static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func reply(_ report: [String: Any], sequence: String, command: String) -> Reply? {
        guard text(report["sequence_id"]) == sequence,
              report["command"] as? String == command else { return nil }
        let reason = text(report["reason"]) ?? text(report["error_message"]) ?? text(report["error_msg"])
        // Some firmware reports an error code without a result. Do not turn
        // unrelated telemetry's print_error into a command acknowledgement.
        for key in ["err_code", "error_code"] {
            if let code = text(report[key]), let numeric = Int64(code), numeric != 0 {
                return Reply(succeeded: false, reason: [reason, "mã \(code)"].compactMap { $0 }.joined(separator: " • "))
            }
        }
        if let result = report["result"] as? String {
            let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["success", "ok", "0"].contains(normalized) {
                return Reply(succeeded: true, reason: nil)
            }
            return Reply(succeeded: false, reason: reason ?? result)
        }
        if let result = report["result"] as? NSNumber {
            return Reply(succeeded: result.intValue == 0,
                         reason: result.intValue == 0 ? nil : (reason ?? "mã \(result.intValue)"))
        }
        // A bare echo, MQTT PUBACK, or an ordinary status packet is not proof
        // that the requested physical action succeeded.
        return nil
    }

    static func confirmsPrintState(
        command: String, initialState: String, report: [String: Any],
        jobID: String, subtaskID: String
    ) -> Bool {
        guard let state = report["gcode_state"] as? String else { return false }
        let stateValue = state.uppercased()
        let initial = initialState.uppercased()
        for (key, expected) in [("job_id", jobID), ("subtask_id", subtaskID)] {
            if !expected.isEmpty, expected != "0", let actual = text(report[key]),
               !actual.isEmpty, actual != "0", actual != expected { return false }
        }
        switch command {
        case "pause":
            return ["RUNNING", "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING"].contains(initial) &&
                ["PAUSE", "PAUSED"].contains(stateValue)
        case "resume":
            return ["PAUSE", "PAUSED"].contains(initial) && stateValue == "RUNNING"
        case "stop":
            return ["RUNNING", "PREPARE", "PREPARING", "PAUSE", "PAUSED", "SLICING", "INIT", "HEATING"].contains(initial) &&
                ["FAILED", "IDLE"].contains(stateValue)
        default:
            return false
        }
    }
}
