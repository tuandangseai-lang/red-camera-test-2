import XCTest

final class SEInterfaceTests: XCTestCase {
    private func launch(timelapse: Bool = false, idle: Bool = false, paused: Bool = false, controlFailure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--se-interface-check"]
        if timelapse { app.launchArguments.append("--se-interface-check-timelapse") }
        if idle { app.launchArguments.append("--se-interface-check-idle") }
        if paused { app.launchArguments.append("--se-interface-check-paused") }
        if controlFailure { app.launchArguments.append("--se-interface-check-control-failure") }
        app.launch()
        XCTAssertTrue(app.staticTexts["38%"].waitForExistence(timeout: 12))
        return app
    }

    private func saveScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWaitingRoomAndControls() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Print status"].exists)
        XCTAssertTrue(app.staticTexts["Printer camera"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "đang in"
        )).count, 0)
        saveScreenshot("waiting-room", app: app)

        let scroll = app.scrollViews.firstMatch
        scroll.swipeUp(velocity: .slow)
        XCTAssertTrue(app.buttons["se.nozzle.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["se.print.pause-resume"].isEnabled)
        XCTAssertTrue(app.buttons["se.print.stop"].isEnabled)
        app.buttons["se.nozzle.0"].tap()
        XCTAssertTrue(app.buttons["se.nozzle.0"].isSelected)
        XCTAssertTrue(app.staticTexts["PETG"].firstMatch.exists)
        app.buttons["se.nozzle.1"].tap()
        XCTAssertTrue(app.buttons["se.nozzle.1"].isSelected)
        let material = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "PLA"
        )).firstMatch
        let humidity = app.buttons["se.ams.humidity-drying"]
        XCTAssertTrue(material.exists)
        XCTAssertTrue(humidity.exists)
        XCTAssertEqual(humidity.label, "AMS humidity 39 percent")
        XCTAssertGreaterThanOrEqual(humidity.frame.width, 60)
        XCTAssertGreaterThanOrEqual(humidity.frame.height, 64)
        saveScreenshot("printer-controls", app: app)

        for element in [app.staticTexts["Controls H2D"], humidity, material] {
            guard element.exists else {
                XCTFail("Missing expected control text")
                continue
            }
            XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
        }
    }

    func testIdleQuickActionsStayVisibleAndDisabled() {
        let app = launch(idle: true)
        app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        let pause = app.buttons["se.print.pause-resume"]
        let stop = app.buttons["se.print.stop"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.exists)
        XCTAssertTrue(pause.frame.intersects(app.frame))
        XCTAssertTrue(stop.frame.intersects(app.frame))
        XCTAssertFalse(pause.isEnabled)
        XCTAssertFalse(stop.isEnabled)
        XCTAssertTrue(app.buttons["se.ams.humidity-drying"].isEnabled)
        saveScreenshot("idle-controls", app: app)
    }

    func testPausedQuickActionsUseResume() {
        let app = launch(paused: true)
        app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        let resume = app.buttons["se.print.pause-resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.isEnabled)
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertTrue(app.buttons["se.print.stop"].isEnabled)
    }

    func testTimelapseLayout() {
        let app = launch(timelapse: true)
        XCTAssertTrue(app.staticTexts["iPhone camera"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Controls H2D"].exists)
        XCTAssertTrue(app.buttons["Stop capture"].exists)
        saveScreenshot("timelapse", app: app)
    }

    func testCommandFailureIsVisibleAndLocalized() {
        let app = launch(controlFailure: true)
        app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        let feedback = app.staticTexts["se.control.feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.label, "Printer blocked the command • enable LAN Mode > Developer Mode")
        XCTAssertGreaterThanOrEqual(feedback.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(feedback.frame.maxX, app.frame.maxX)
        saveScreenshot("command-feedback", app: app)
    }
}
