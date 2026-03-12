import AVFoundation
import Combine
import XCTest
@testable import VoiceAudioImplementation

final class PCMVADPluginTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testEmitsSpeechThenSilenceStateTransitions() {
        let plugin = PCMVADPlugin()
        plugin.hangoverFrames = 1
        plugin.sensitivity = 2.5

        var events: [VADResult] = []
        let exp = expectation(description: "receives speech and silence transitions")
        exp.expectedFulfillmentCount = 2

        plugin.vadPublisher
            .sink { result in
                events.append(result)
                exp.fulfill()
            }
            .store(in: &cancellables)

        plugin.write(makeBuffer(amplitude: 0.2))
        usleep(50_000)

        plugin.write(makeBuffer(amplitude: 0))
        usleep(50_000)

        plugin.write(makeBuffer(amplitude: 0))

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(events, [.speech, .silence])
        XCTAssertFalse(plugin.isSpeech)
    }

    func testResetClearsSpeechState() {
        let plugin = PCMVADPlugin()
        plugin.write(makeBuffer(amplitude: 0.2))
        usleep(60_000)
        XCTAssertTrue(plugin.isSpeech)

        plugin.reset()
        usleep(60_000)
        XCTAssertFalse(plugin.isSpeech)
    }

    private func makeBuffer(amplitude: Float, frameLength: AVAudioFrameCount = 1024) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
        buffer.frameLength = frameLength
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameLength) {
                data[i] = amplitude
            }
        }
        return buffer
    }
}
