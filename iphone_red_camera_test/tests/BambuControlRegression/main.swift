import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    checks += 1
}
for command in ["pause", "resume", "stop"] {
    let body = BambuControlProtocol.commandFields(section: "print", command: command, fields: [:])
    check(body["param"] as? String == "", "Empty parameter missing: \(command)")
    check(body.count == 1, "Unexpected task fields")
}
check(BambuControlProtocol.commandFields(section: "print", command: "resume", fields: ["param": "reserve"])["param"] as? String == "reserve", "Preserve explicit parameters")
check(BambuControlProtocol.commandFields(section: "system", command: "stop", fields: [:]).isEmpty, "Do not alter system commands")
check(BambuControlProtocol.commandFields(section: "print", command: "ams_control", fields: ["param": "done"])["param"] as? String == "done", "Preserve filament control")

func reply(_ fields: [String: Any]) -> BambuControlProtocol.Reply? {
    BambuControlProtocol.reply(fields, sequence: "200001", command: "pause")
}
let correlated: [String: Any] = ["sequence_id": "200001", "command": "pause"]
func report(_ extra: [String: Any]) -> [String: Any] {
    correlated.merging(extra) { _, value in value }
}
for result in ["success", "OK", "0", " success "] {
    check(reply(report(["result": result]))?.succeeded == true, "String success")
}
check(reply(report(["result": 0]))?.succeeded == true, "Numeric success")
check(reply(report(["sequence_id": 200001, "result": 0]))?.succeeded == true, "Numeric sequence")
check(reply(report(["sequence_id": "other", "result": "success"])) == nil, "Ignore other sequence")
check(reply(report(["command": "stop", "result": "success"])) == nil, "Ignore other command")
check(reply(["result": "success"]) == nil, "Ignore uncorrelated acknowledgement")
check(reply(correlated) == nil, "An echo is not success")
check(reply(report(["err_code": 84033543]))?.succeeded == false, "Reject code-only authorization error")
check(reply(report(["error_code": "84033543", "result": "success"]))?.succeeded == false, "Error overrides success")
check(reply(report(["error_code": 0])) == nil, "Zero error alone is not success")
check(reply(report(["print_error": 123])) == nil, "Printer error is not command error")
check(reply(report(["result": "fail", "reason": "denied"]))?.reason == "denied", "Preserve failure reason")
check(reply(report(["result": 1]))?.succeeded == false, "Numeric rejection")

func transition(_ command: String, _ before: String, _ fields: [String: Any]) -> Bool {
    BambuControlProtocol.confirmsPrintState(command: command, initialState: before,
        report: fields, jobID: "job-1", subtaskID: "42")
}
check(transition("pause", "RUNNING", ["gcode_state": "PAUSE"]), "Pause transition without result")
check(transition("pause", "PREPARE", ["gcode_state": "paused"]), "Preparation can pause")
check(!transition("pause", "RUNNING", ["gcode_state": "RUNNING"]), "Unchanged state is not success")
check(!transition("pause", "PAUSE", ["gcode_state": "PAUSE"]), "Old paused state is not a transition")
check(!transition("pause", "RUNNING", ["gcode_state": "PAUSE", "job_id": "job-2"]), "Do not confirm another job")
check(!transition("pause", "RUNNING", ["gcode_state": "PAUSE", "subtask_id": 43]), "Do not confirm another subtask")
check(transition("resume", "PAUSED", ["gcode_state": "RUNNING", "subtask_id": 42]), "Numeric matching subtask")
check(!transition("resume", "RUNNING", ["gcode_state": "RUNNING"]), "Already running is not resume success")
check(transition("stop", "RUNNING", ["gcode_state": "FAILED"]), "Cancelled job")
check(transition("stop", "PAUSE", ["gcode_state": "IDLE", "job_id": ""]), "Cancelled job may clear its ID")
check(!transition("stop", "RUNNING", ["gcode_state": "FINISH"]), "Natural completion is not stop confirmation")
check(!transition("stop", "IDLE", ["gcode_state": "IDLE"]), "Already idle is not stop success")
check(!transition("stop", "RUNNING", ["mc_percent": 0]), "No state, no confirmation")
check(!transition("ams_control", "RUNNING", ["gcode_state": "PAUSE"]), "Do not infer filament success from print state")

for (vi, en) in [
    ("Máy in đã nhận lệnh • chờ đổi trạng thái…", "Printer accepted the command • waiting for a state change…"),
    ("Máy in đã đổi trạng thái: Tạm dừng bản in", "Printer changed state: Pause print"),
    ("Máy in không xác nhận lệnh • kiểm tra kết nối và LAN Developer Mode", "Printer did not confirm the command • check the connection and LAN Developer Mode")
] {
    check(SEStatusCopy.render(vi, languageCode: "en") == en, "English command feedback")
    check(SEStatusCopy.render(en, languageCode: "vi") == vi, "Vietnamese command feedback")
}
print("PASS: \(checks) offline task-command, reply, state-transition and feedback checks; no printer connection.")
