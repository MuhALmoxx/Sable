import XCTest

/// Settings › Translation shows the signed-out "Sign in with ChatGPT" block. The button is never
/// tapped: CI has no ChatGPT account or network login, and there is no fake signed-in mode.
final class ChatGPTSignInUITests: SableUITestCase {
    func testSettingsShowsSignedOutChatGPTPlanBlock() throws {
        launch(Launch.clean)
        waitFor(AX.Library.settings).tap()
        waitFor(AX.Settings.screen)

        // The block sits below the Claude settings; scroll (slowly, towards it) until it is on screen.
        let signIn = element(AX.ChatGPT.signIn)
        for _ in 0..<16 where !isVisible(signIn) {
            if signIn.exists, signIn.frame.maxY < app.frame.minY + 80 {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(signIn.waitForExistence(timeout: Timeout.control), "The Sign in with ChatGPT button is missing")
        XCTAssertTrue(isVisible(signIn), "The Sign in with ChatGPT button could not be scrolled into view")
        XCTAssertEqual(signIn.label, "Sign in with ChatGPT")

        let disclosure = waitFor(AX.ChatGPT.disclosure, timeout: Timeout.control)
        XCTAssertTrue(disclosure.label.contains("ChatGPT Plus or Pro plan"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("count toward your ChatGPT usage limits"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("not OpenAI API access"), disclosure.label)
        XCTAssertTrue(element(AX.ChatGPT.previewTag).exists, "The OpenAI preview tag is missing")

        // A clean launch is signed out: no account controls.
        XCTAssertFalse(element(AX.ChatGPT.signOut).exists)
        XCTAssertFalse(element(AX.ChatGPT.status).exists)
        attachScreenshot("11-settings-chatgpt")
    }
}
