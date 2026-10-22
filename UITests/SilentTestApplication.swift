import XCTest

@MainActor
func silentTestApplication() -> XCUIApplication {
    let app = XCUIApplication()
    // UI app runs in another process: XCTest detection does not cross over,
    // so every launch needs this explicit flag. It stays independent of
    // POMODOROUGH_UI_TEST_RESET on purpose; callers may clear RESET later
    // and silence must survive. Key must match TestAudioSuppression.silenceKey.
    app.launchEnvironment["POMODOROUGH_SILENCE_AUDIO"] = "1"
    return app
}
