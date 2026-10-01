import XCTest

final class SEInterfaceTests: XCTestCase {
    private func launch(timelapse: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--se-interface-check"]
        if timelapse { app.launchArguments.append("--se-interface-check-timelapse") }
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
        app.buttons["se.nozzle.0"].tap()
        XCTAssertTrue(app.buttons["se.nozzle.0"].isSelected)
        XCTAssertTrue(app.staticTexts["PETG"].firstMatch.exists)
        app.buttons["se.nozzle.1"].tap()
        XCTAssertTrue(app.buttons["se.nozzle.1"].isSelected)
        let material = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "PLA"
        )).firstMatch
        let humidity = app.staticTexts["AMS humidity 39 percent"]
        XCTAssertTrue(material.exists)
        XCTAssertTrue(humidity.exists)
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

    func testTimelapseLayout() {
        let app = launch(timelapse: true)
        XCTAssertTrue(app.staticTexts["iPhone camera"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Controls H2D"].exists)
        XCTAssertTrue(app.buttons["Stop capture"].exists)
        saveScreenshot("timelapse", app: app)
    }
}
