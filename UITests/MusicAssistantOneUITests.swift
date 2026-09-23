import XCTest

final class MusicAssistantOneUITests: XCTestCase {
    @MainActor
    private func allowLocalDiscoveryPrompt() {
        addUIInterruptionMonitor(withDescription: "Local network discovery") { alert in
            let networkText = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'local network'"))
            guard networkText.count > 0, alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
    }
    @MainActor
    func testOnboardingHasConfigurableServerAndAccessibleSignIn() throws {
        allowLocalDiscoveryPrompt()
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding"]
        app.launch()
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectButton"].exists)
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        address.tap()
        address.typeText("https://music.example.com")
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Onboarding"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLibraryAndNowPlayingPresentation() throws {
        allowLocalDiscoveryPrompt()
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Recently Added"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["miniPlayer"].exists)
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Library"
        library.lifetime = .keepAlways
        add(library)
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["Now Playing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Next track"].exists)
        let player = XCTAttachment(screenshot: app.screenshot())
        player.name = "Now Playing"
        player.lifetime = .keepAlways
        add(player)
    }
}
