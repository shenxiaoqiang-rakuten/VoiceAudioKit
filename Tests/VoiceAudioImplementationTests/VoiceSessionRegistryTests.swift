import XCTest
@testable import VoiceAudioImplementation
import VoiceAudioProtocol

final class VoiceSessionRegistryTests: XCTestCase {

    func testRecorderRegistrationConflictsWithExistingRecorder() async {
        let registry = VoiceSessionRegistry()
        let recorder1 = VoiceClientId()
        let recorder2 = VoiceClientId()

        let first = await registry.register(requirement: .recordOnly, clientId: recorder1)
        let second = await registry.register(requirement: .recordAndPlayback, clientId: recorder2)

        switch first {
        case .success(let result):
            XCTAssertEqual(result.mergedCategory, .record)
            XCTAssertFalse(result.shouldEmitTakeover)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }

        switch second {
        case .success:
            XCTFail("expected busy for second recorder")
        case .failure(let error):
            guard case .busy(let message) = error else {
                return XCTFail("expected busy error")
            }
            XCTAssertEqual(message, "Recorder already active")
        }
    }

    func testChatCallTakeoverAndChatCallActiveRejection() async {
        let takeoverRegistry = VoiceSessionRegistry()
        let recorder = VoiceClientId()
        let chatCall = VoiceClientId()
        _ = await takeoverRegistry.register(requirement: .recordOnly, clientId: recorder)

        let chatCallResult = await takeoverRegistry.register(requirement: .chatCall, clientId: chatCall)
        switch chatCallResult {
        case .success(let result):
            XCTAssertTrue(result.shouldEmitTakeover)
            XCTAssertEqual(result.mergedCategory, .playAndRecord)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }

        let chatCallOnlyRegistry = VoiceSessionRegistry()
        let firstChatCall = VoiceClientId()
        let extraPlayer = VoiceClientId()
        _ = await chatCallOnlyRegistry.register(requirement: .chatCall, clientId: firstChatCall)

        let rejected = await chatCallOnlyRegistry.register(requirement: .playbackOnly, clientId: extraPlayer)
        switch rejected {
        case .success:
            XCTFail("expected chatCallActive rejection")
        case .failure(let error):
            guard case .chatCallActive = error else {
                return XCTFail("expected chatCallActive error")
            }
        }
    }

    func testUnregisterReturnsChatCallReleaseSignalAndEmptyState() async {
        let registry = VoiceSessionRegistry()
        let chatCall = VoiceClientId()

        _ = await registry.register(requirement: .chatCall, clientId: chatCall)
        let result = await registry.unregister(clientId: chatCall)

        XCTAssertTrue(result.wasChatCall)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.mergedCategory, .ambient)
    }
}
