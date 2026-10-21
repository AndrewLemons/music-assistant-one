import XCTest

final class MusicAssistantOneUITests: XCTestCase {
    @MainActor
    private func allowLocalDiscoveryPrompt() {
        addUIInterruptionMonitor(withDescription: "Local network discovery") { alert in
            let networkText = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'local network'"))
            guard networkText.firstMatch.exists, alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].trigger()
            return true
        }
    }

    @MainActor
    func testOnboardingHasConfigurableServerAndAccessibleSignIn() {
        allowLocalDiscoveryPrompt()
        let app = launchApp("--onboarding")
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectButton"].exists)
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Setup - Account"
        initial.lifetime = .keepAlways
        add(initial)
        address.trigger()
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
            app.buttons["Access Token"].trigger()
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
        let app = launchApp("--demo")
        XCTAssertTrue(text(app, "Recently Added").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["miniPlayer"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "settingsButton").count, 1)
        let library = XCTAttachment(screenshot: app.screenshot())
        library.name = "Library"
        library.lifetime = .keepAlways
        add(library)
        app.buttons["miniPlayer"].trigger()
        XCTAssertTrue(app.buttons["Close Now Playing"].waitForExistence(timeout: 5))
        #if os(macOS)
            XCTAssertEqual(app.sheets.count, 0, "Now Playing must occupy the main window")
        #endif
        XCTAssertTrue(app.buttons["Next track"].exists)
        let player = XCTAttachment(screenshot: app.screenshot())
        player.name = "Now Playing"
        player.lifetime = .keepAlways
        add(player)
        app.buttons["Close Now Playing"].trigger()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCollectionNavigationAndCurrentSongActions() {
        let app = launchApp("--demo")
        let album = app.buttons["Open Water, The Quiet Hours"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        album.trigger()
        XCTAssertTrue(app.buttons["media-track-First Light"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["playCollection"].exists)
        XCTAssertEqual(app.buttons["miniPlayer"].value as? String, "Open Water")
        #if os(iOS)
            app.collectionViews.firstMatch.swipeUp()
        #endif
        menu(app, "More options for First Light").trigger()
        XCTAssertTrue(menuItem(app, "Play Next").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem(app, "Add to Favorites").exists)
        menuItem(app, "Add to Playlist…").trigger()
        XCTAssertTrue(text(app, "A slow morning").waitForExistence(timeout: 5))
        let playlistSearch = app.searchFields.firstMatch
        XCTAssertTrue(playlistSearch.waitForExistence(timeout: 5))
        playlistSearch.trigger()
        playlistSearch.typeText("home")
        XCTAssertTrue(text(app, "On the way home").waitForExistence(timeout: 5))
        XCTAssertFalse(text(app, "A slow morning").exists)
        playlistSearch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(text(app, "A slow morning").waitForExistence(timeout: 5))
        #if os(iOS)
            app.buttons["Close"].trigger() // Leave the native expanded search field.
        #endif
        app.buttons["Cancel"].trigger()
        app.buttons["miniPlayer"].trigger()
        menu(app, "Track options").trigger()
        XCTAssertTrue(menuItem(app, "Add to Favorites").waitForExistence(timeout: 5))
        XCTAssertFalse(menuItem(app, "Play Next").exists)
        XCTAssertFalse(menuItem(app, "Add to Queue").exists)
        menuItem(app, "Add to Playlist…").trigger()
        XCTAssertTrue(text(app, "A slow morning").waitForExistence(timeout: 5))
        app.buttons["Cancel"].trigger()
        #if os(iOS)
            app.buttons["Queue"].trigger()
            menu(app, "Current song options").trigger()
            menuItem(app, "Add to Playlist…").trigger()
            XCTAssertTrue(text(app, "A slow morning").waitForExistence(timeout: 5))
            app.buttons["Cancel"].trigger()
        #endif
    }

    #if os(iOS)
        /// Each album card opens its own album, and Back returns to the page it came from.
        @MainActor
        func testRecentlyAddedOpensTheChosenAlbumAndReturns() {
            let app = launchApp("--demo")
            XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
            app.tabBars.buttons["Library"].trigger()
            for (album, artist) in [("After the Rain", "June & August"), ("Open Water", "The Quiet Hours")] {
                let card = app.buttons["card-album-\(album)"].firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 5))
                card.trigger()
                XCTAssertTrue(app.buttons["playCollection"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["collectionTitle"].label, album, "\(album) must open its own page")
                XCTAssertTrue(text(app, artist).exists)
                app.navigationBars.buttons.firstMatch.trigger()
                XCTAssertTrue(
                    app.buttons["category-Albums"].waitForExistence(timeout: 5),
                    "Back must return to the library, not another album"
                )
                XCTAssertFalse(app.buttons["playCollection"].exists)
            }
        }
    #endif

    @MainActor
    func testDownloadsIsDiscoverableAndHasAccessibleStorageControls() {
        let app = launchApp("--demo")
        #if os(macOS)
            let downloaded = app.outlines.staticTexts["Downloaded"].firstMatch
        #else
            XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
            app.tabBars.buttons["Library"].trigger()
            let downloaded = app.buttons["category-Downloaded"].firstMatch
        #endif
        XCTAssertTrue(downloaded.waitForExistence(timeout: 10))
        downloaded.trigger()
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Downloaded - Empty"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #if os(macOS)
            // Toolbar menus are menu buttons on macOS, and their entries are menu items.
            app.menuButtons["Download Options"].trigger()
            let removeAll = app.menuItems["Remove All Downloads"]
        #else
            app.buttons["Download Options"].trigger()
            let removeAll = app.buttons["Remove All Downloads"]
        #endif
        XCTAssertTrue(removeAll.waitForExistence(timeout: 5))
        XCTAssertFalse(removeAll.isEnabled)
    }

    @MainActor
    func testGroupedSettingsAndDataNavigation() {
        let app = launchApp("--demo")
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.trigger()
        #if os(macOS)
            // Mac settings live in a tabbed Settings window.
            let about = app.toolbars.buttons["About"]
            XCTAssertTrue(about.waitForExistence(timeout: 5))
            about.trigger()
        #endif
        XCTAssertTrue(app.staticTexts["Music Assistant One"].waitForExistence(timeout: 5))
        let erase = app.buttons["Erase Local Data…"]
        #if os(iOS)
            if !erase.exists || !erase.isHittable {
                app.swipeUp()
            }
        #endif
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        erase.trigger()
        #if os(macOS)
            // macOS presents the alert as a sheet on the Settings window.
            let alert = app.sheets.firstMatch
        #else
            let alert = app.alerts["Erase Local Data?"]
        #endif
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].trigger()
        XCTAssertTrue(erase.exists)
    }

    #if os(iOS)
        @MainActor
        func testLiveReviewAccountCanSignInAndEraseLocalData() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let server = environment["MA_REVIEW_SERVER"],
                  let username = environment["MA_REVIEW_USERNAME"],
                  let password = environment["MA_REVIEW_PASSWORD"]
            else { throw XCTSkip("Set MA_REVIEW_SERVER, MA_REVIEW_USERNAME, and MA_REVIEW_PASSWORD to run") }

            let app = launchApp("--onboarding")
            let address = app.textFields["serverAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 10))
            address.trigger()
            if app.buttons["Clear server address"].exists {
                app.buttons["Clear server address"].trigger()
            }
            address.typeText(server)
            app.textFields["username"].trigger()
            app.textFields["username"].typeText(username)
            app.secureTextFields["password"].trigger()
            app.secureTextFields["password"].typeText(password)
            app.buttons["connectButton"].trigger()

            let library = app.tabBars.buttons["Library"]
            guard library.waitForExistence(timeout: 30) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Live sign-in failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("The review account did not reach the library")
                return
            }
            if app.buttons["Not Now"].waitForExistence(timeout: 2) {
                app.buttons["Not Now"].trigger()
            }
            library.trigger()
            XCTAssertTrue(text(app, "Review Samples").waitForExistence(timeout: 15))
            let players = app.buttons["miniPlayerOutput"]
            players.trigger()
            let enableSendspin = app.buttons["selectThisDevice"]
            XCTAssertTrue(enableSendspin.waitForExistence(timeout: 5))
            enableSendspin.trigger()
            guard enableSendspin.staticTexts["Not Playing"].waitForExistence(timeout: 30) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Review playback setup failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("The review device did not become a player")
                return
            }
            let samples = app.buttons["Review Samples, Various Artists"].firstMatch
            XCTAssertTrue(samples.waitForExistence(timeout: 10))
            samples.trigger()
            let playSamples = app.buttons["playCollection"]
            XCTAssertTrue(playSamples.waitForExistence(timeout: 10))
            playSamples.trigger()
            players.trigger()
            guard enableSendspin.staticTexts["Playing"].waitForExistence(timeout: 20) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Review playback failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail("Sample music did not stream to the review device")
                return
            }
            // Selecting the current tab again returns to the library index.
            app.tabBars.buttons["Library"].trigger()
            app.tabBars.buttons["Library"].trigger()
            let settings = app.buttons["settingsButton"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            if settings.isHittable {
                settings.tap()
            } else {
                // iOS 27 can report the visible navigation bar item with an invalid hit point.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.10)).tap()
            }
            let erase = app.buttons["Erase Local Data…"]
            if !erase.waitForExistence(timeout: 5) || !erase.isHittable {
                app.swipeUp()
            }
            erase.trigger()
            app.alerts.buttons["Erase"].trigger()
            XCTAssertTrue(address.waitForExistence(timeout: 10))
        }
    #endif

    #if os(macOS)
        @MainActor
        func testLibraryFilterSurvivesNowPlaying() {
            let app = launchApp("--demo")
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
    func testPlayersHasOneExplicitLocalSelection() {
        let app = launchApp("--demo")
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
        #if os(macOS)
            app.buttons["Choose player"].firstMatch.trigger()
        #else
            app.buttons["miniPlayerOutput"].trigger()
        #endif
        XCTAssertTrue(app.buttons["selectThisDevice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "selectThisDevice").count, 1)
        XCTAssertFalse(app.switches["Enable Sendspin"].exists)
        XCTAssertFalse(app.staticTexts["Listen here"].exists)
    }

    @MainActor
    func testSearchFiltersAndStablePlayer() {
        let app = launchApp("--demo")
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
        #if os(macOS)
            app.outlines.staticTexts["Search"].firstMatch.trigger()
        #else
            app.buttons["Search"].firstMatch.trigger()
        #endif
        XCTAssertTrue(app.buttons["Search Albums"].waitForExistence(timeout: 5))
        let playerY = app.buttons["miniPlayer"].frame.midY
        let empty = XCTAttachment(screenshot: app.screenshot())
        empty.name = "Search - Browse"
        empty.lifetime = .keepAlways
        add(empty)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.trigger()
        search.typeText("Open")
        XCTAssertTrue(app.buttons["media-track-Open Water"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["media-album-Open Water"].exists)
        XCTAssertTrue(app.buttons["filter-All"].isSelected)
        #if os(macOS)
            XCTAssertEqual(
                playerY,
                app.buttons["miniPlayer"].frame.midY,
                accuracy: 2,
                "The player must stay at the bottom when search content changes"
            )
        #endif
        app.buttons["filter-Albums"].trigger()
        XCTAssertTrue(app.buttons["media-album-Open Water"].exists)
        XCTAssertFalse(app.buttons["media-track-Open Water"].exists)
        #if os(macOS)
            let resultsGap = app.buttons["media-album-Open Water"].frame.minY - app.buttons["filter-Albums"].frame.maxY
            XCTAssertLessThan(resultsGap, 80, "Search filters must not inherit the floating player's bottom margin")
        #endif
        app.buttons["filter-Songs"].trigger()
        XCTAssertTrue(app.buttons["media-track-Open Water"].exists)
        XCTAssertFalse(app.buttons["media-album-Open Water"].exists)
        #if os(iOS)
            // Drag on the visible chips so the gesture doesn't land in the search field above them.
            let start = app.buttons["filter-Artists"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.buttons["filter-All"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        #endif
        app.buttons["filter-Radio"].trigger()
        XCTAssertTrue(app.buttons["Show All Results"].waitForExistence(timeout: 5))
        app.buttons["Show All Results"].trigger()
        XCTAssertTrue(app.buttons["media-track-Open Water"].exists)
        let results = XCTAttachment(screenshot: app.screenshot())
        results.name = "Search - Results"
        results.lifetime = .keepAlways
        add(results)
    }
}

private extension MusicAssistantOneUITests {
    /// Visible text, whether exposed as static text or within a combined row label.
    func text(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix))
            .firstMatch
    }

    /// A "•••" menu: a menu button on macOS, a button on iOS.
    func menu(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        #if os(macOS)
            app.menuButtons[label].firstMatch
        #else
            app.buttons[label].firstMatch
        #endif
    }

    /// An entry in an open menu: a menu item on macOS, a button on iOS.
    func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        #if os(macOS)
            app.menuItems[label].firstMatch
        #else
            app.buttons[label].firstMatch
        #endif
    }

    @MainActor
    func launchApp(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        #if os(macOS)
            // A test-launched Mac app may not open its window until it receives a reopen
            // event (such as a Dock click). File › New Window opens one directly.
            if !app.windows.firstMatch.waitForExistence(timeout: 3) {
                app.activate()
                app.typeKey("n", modifierFlags: .command)
            }
        #endif
        return app
    }
}

private extension XCUIElement {
    /// Click on macOS, tap on iOS.
    func trigger() {
        #if os(macOS)
            click()
        #else
            tap()
        #endif
    }
}
