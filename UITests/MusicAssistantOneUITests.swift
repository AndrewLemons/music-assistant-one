import XCTest

final class MusicAssistantOneUITests: XCTestCase {
    @MainActor
    private func allowLocalDiscoveryPrompt() {
        addUIInterruptionMonitor(withDescription: "Local network discovery") { alert in
            let networkText = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'local network'"))
            guard networkText.firstMatch.exists, alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].activate()
            return true
        }
    }

    @MainActor
    func testOnboardingHasConfigurableServerAndAccessibleSignIn() {
        allowLocalDiscoveryPrompt()
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding"]
        app.launch()
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectButton"].exists)
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Setup - Account"
        initial.lifetime = .keepAlways
        add(initial)
        address.activate()
        address.typeText("https://music.example.com")
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Onboarding"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #if os(iOS)
            // Return should advance through the account fields without submitting early.
            address.typeText("\n")
            app.typeText("listener\n")
            XCTAssertEqual(app.textFields["username"].value as? String, "listener")
            app.typeText("example-password")
            XCTAssertTrue(app.buttons["connectButton"].isEnabled)
            app.buttons["Access token"].activate()
            XCTAssertTrue(app.secureTextFields["accessToken"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["connectButton"].isEnabled)
            app.secureTextFields["accessToken"].typeText("example-token")
            XCTAssertTrue(app.buttons["connectButton"].isEnabled)
            let token = XCTAttachment(screenshot: app.screenshot())
            token.name = "Setup - Token"
            token.lifetime = .keepAlways
            add(token)
        #endif
    }

    @MainActor
    func testLibraryAndNowPlayingPresentation() {
        allowLocalDiscoveryPrompt()
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Recently Added"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["miniPlayer"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Connection settings").count, 1)
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Library"
        library.lifetime = .keepAlways
        add(library)
        app.buttons["miniPlayer"].activate()
        XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: 5))
        #if os(macOS)
            XCTAssertEqual(app.sheets.count, 0, "Now Playing must occupy the main window")
        #endif
        XCTAssertTrue(app.buttons["Next track"].exists)
        let player = XCTAttachment(screenshot: app.screenshot())
        player.name = "Now Playing"
        player.lifetime = .keepAlways
        add(player)
        app.buttons["Close Now Playing"].activate()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
    }

    #if os(iOS)
        @MainActor
        func testLiveReviewAccountCanSignInAndEraseLocalData() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let server = environment["MA_REVIEW_SERVER"],
                  let username = environment["MA_REVIEW_USERNAME"],
                  let password = environment["MA_REVIEW_PASSWORD"]
            else { throw XCTSkip("Set MA_REVIEW_SERVER, MA_REVIEW_USERNAME, and MA_REVIEW_PASSWORD to run") }

            let app = XCUIApplication()
            app.launchArguments = ["--onboarding"]
            app.launch()
            let address = app.textFields["serverAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 10))
            address.activate()
            if app.buttons["Clear server address"].exists {
                app.buttons["Clear server address"].activate()
            }
            address.typeText(server)
            app.textFields["username"].activate()
            app.textFields["username"].typeText(username)
            app.secureTextFields["password"].activate()
            app.secureTextFields["password"].typeText(password)
            app.buttons["connectButton"].activate()

            let library = app.staticTexts["Recently Added"]
            guard library.waitForExistence(timeout: 30) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Live sign-in failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("The review account did not reach the library")
                return
            }
            XCTAssertTrue(app.staticTexts["Review Samples"].waitForExistence(timeout: 15))
            if app.buttons["Not Now"].waitForExistence(timeout: 2) {
                app.buttons["Not Now"].activate()
            }
            let playersTab = app.buttons["Players"]
            playersTab.activate()
            let enableSendspin = app.switches["Enable Sendspin"]
            if !enableSendspin.waitForExistence(timeout: 5) {
                playersTab.activate()
            }
            XCTAssertTrue(enableSendspin.waitForExistence(timeout: 5))
            enableSendspin.activate()
            guard app.staticTexts["Ready to play"].waitForExistence(timeout: 30) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Review playback setup failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("The review device did not become a player")
                return
            }
            app.buttons["Library"].activate()
            let playSamples = app.buttons["Play Review Samples, Various Artists"]
            XCTAssertTrue(playSamples.waitForExistence(timeout: 10))
            playSamples.activate()
            playersTab.activate()
            guard app.staticTexts["Playing on this device"].waitForExistence(timeout: 20) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Review playback failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("Sample music did not stream to the review device")
                return
            }
            app.buttons["Library"].activate()
            let settings = app.buttons["Connection settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            if settings.isHittable {
                settings.tap()
            } else {
                // iOS 27 can report the visible navigation bar item with an invalid hit point.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.10)).tap()
            }
            XCTAssertTrue(app.buttons["Erase Local App Data"].waitForExistence(timeout: 5))
            app.buttons["Erase Local App Data"].activate()
            app.alerts.buttons["Erase Data"].activate()
            XCTAssertTrue(address.waitForExistence(timeout: 10))
        }
    #endif

    #if os(macOS)
        @MainActor
        func testLibraryFilterSurvivesNowPlaying() {
            let app = XCUIApplication()
            app.launchArguments = ["--demo"]
            app.launch()
            XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
            app.outlines.staticTexts["Songs"].firstMatch.click()
            let search = app.searchFields.firstMatch
            search.click()
            search.typeText("First")
            XCTAssertTrue(app.buttons["media-track-First Light"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["media-track-Open Water"].exists)
            app.buttons["miniPlayer"].click()
            XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: 5))
            app.buttons["Close Now Playing"].click()
            XCTAssertTrue(app.buttons["media-track-First Light"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["media-track-Open Water"].exists)
            XCTAssertEqual(app.searchFields.firstMatch.value as? String, "First")
        }
    #endif

    @MainActor
    func testSearchFiltersAndStablePlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
        #if os(macOS)
            app.outlines.staticTexts["Search"].firstMatch.activate()
        #else
            app.buttons["Search"].firstMatch.activate()
        #endif
        XCTAssertTrue(app.buttons["Filter: All"].waitForExistence(timeout: 5))
        let playerY = app.buttons["miniPlayer"].frame.midY
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "Search - Browse"
        empty.lifetime = .keepAlways
        add(empty)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.activate()
        search.typeText("Open")
        XCTAssertTrue(app.buttons["media-track-Open Water"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["media-album-Open Water"].exists)
        #if os(macOS)
            XCTAssertEqual(
                playerY,
                app.buttons["miniPlayer"].frame.midY,
                accuracy: 2,
                "The player must stay at the bottom when search content changes"
            )
        #endif
        app.buttons["Filter: Albums"].activate()
        XCTAssertTrue(app.buttons["media-album-Open Water"].exists)
        XCTAssertFalse(app.buttons["media-track-Open Water"].exists)
        #if os(macOS)
            let resultsGap = app.buttons["media-album-Open Water"].frame.minY - app.buttons["Filter: Albums"].frame.maxY
            XCTAssertLessThan(resultsGap, 80, "Search filters must not inherit the floating player's bottom margin")
        #endif
        app.buttons["Filter: Songs"].activate()
        XCTAssertTrue(app.buttons["media-track-Open Water"].exists)
        XCTAssertFalse(app.buttons["media-album-Open Water"].exists)
        #if os(iOS)
            // The scroll view extends under the navigation bar. Drag on the visible
            // chips so the gesture doesn't land in the search field above them.
            let start = app.buttons["Filter: Artists"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.buttons["Filter: All"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        #endif
        app.buttons["Filter: Radio"].activate()
        XCTAssertTrue(app.staticTexts["No Radio Found"].exists)
        app.buttons["Show All Results"].activate()
        XCTAssertTrue(app.buttons["media-track-Open Water"].exists)
        let results = XCTAttachment(screenshot: app.screenshot())
        results.name = "Search - Results"
        results.lifetime = .keepAlways
        add(results)
    }
}

private extension XCUIElement {
    func activate() {
        #if os(macOS)
            click()
        #else
            tap()
        #endif
    }
}
