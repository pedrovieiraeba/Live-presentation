import XCTest
@testable import Diagnostics

final class RedactorTests: XCTestCase {
    func testRedactsKeyValueSecrets() {
        let input = #"POST /token access_token=abc123&refresh_token=zzz {"client_secret": "s3cr3t"}"#
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("abc123"))
        XCTAssertFalse(output.contains("zzz"))
        XCTAssertFalse(output.contains("s3cr3t"))
        XCTAssertTrue(output.contains("access_token=\(Redactor.mask)"))
    }

    func testRedactsBearerAndGoogleTokens() {
        let output = Redactor.redact("Authorization: Bearer ya29.A0ARrdaM-xyz and 1//0gAbCdEfGhIjKlMn")
        XCTAssertFalse(output.contains("A0ARrdaM"))
        XCTAssertFalse(output.contains("0gAbCdEfGhIjKlMn"))
    }

    func testRedactsRTMPStreamKey() {
        let output = Redactor.redact("connecting rtmp://a.rtmp.youtube.com/live2/abcd-efgh-ijkl-mnop")
        XCTAssertFalse(output.contains("abcd-efgh"))
        XCTAssertTrue(output.contains("rtmp://a.rtmp.youtube.com/live2/"))
    }

    func testLeavesOrdinaryMessagesUntouched() {
        let message = "Slide 3 de 'Grande é o Senhor' enviado ao ar"
        XCTAssertEqual(Redactor.redact(message), message)
    }
}

final class LogBufferTests: XCTestCase {
    func testBufferIsBoundedAndRedacted() {
        let buffer = LogBuffer(capacity: 3)
        let logger = AppLogger(category: "test", buffer: buffer)
        for i in 0..<5 { logger.info("mensagem \(i)") }
        logger.error("falhou com token=supersecret", code: "E-TEST")

        let entries = buffer.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.last?.code, "E-TEST")
        XCTAssertFalse(entries.last!.message.contains("supersecret"))
        XCTAssertEqual(buffer.entries(minimumLevel: .error).count, 1)
    }
}
