import XCTest
@testable import Teleop

final class AxisSpeechRecognizerTests: XCTestCase {
    func testNoRecognizedSpeechEndsTheWindowWithoutReportingUnavailable() {
        let emptyResult = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
        guard case .ended = AxisSpeechRecognizer.completion(for: emptyResult) else {
            return XCTFail("A silent recognition window should end normally")
        }
    }

    func testRealSpeechErrorsRemainFailures() {
        let disconnected = NSError(domain: "kAFAssistantErrorDomain", code: 1101)
        guard case .failed(.unavailable) = AxisSpeechRecognizer.completion(for: disconnected) else {
            return XCTFail("An invalidated speech process is unavailable")
        }

        let unauthorized = NSError(domain: "kAFAssistantErrorDomain", code: 1700)
        guard case .failed(.permission) = AxisSpeechRecognizer.completion(for: unauthorized) else {
            return XCTFail("An unauthorized request is a permission failure")
        }
    }
}
