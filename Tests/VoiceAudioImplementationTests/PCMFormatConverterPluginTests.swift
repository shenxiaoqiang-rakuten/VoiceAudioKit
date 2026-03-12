import AVFoundation
import Combine
import XCTest
@testable import VoiceAudioImplementation

final class PCMFormatConverterPluginTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testPassThroughWhenFormatMatches() {
        let plugin = PCMFormatConverterPlugin(targetSampleRate: 16_000, targetChannelCount: 1)
        let input = makeBuffer(sampleRate: 16_000, channels: 1, frameLength: 160)

        let exp = expectation(description: "receives converted buffer")
        plugin.convertedBufferPublisher
            .sink { output in
                XCTAssertTrue(output === input)
                XCTAssertEqual(output.format.channelCount, 1)
                XCTAssertEqual(output.frameLength, 160)
                exp.fulfill()
            }
            .store(in: &cancellables)

        plugin.write(input)
        wait(for: [exp], timeout: 1.0)
    }

    func testResampleAndDownmixToTargetFormat() {
        let plugin = PCMFormatConverterPlugin(targetSampleRate: 16_000, targetChannelCount: 1)
        let input = makeBuffer(sampleRate: 48_000, channels: 2, frameLength: 480)

        let exp = expectation(description: "receives resampled buffer")
        plugin.convertedBufferPublisher
            .sink { output in
                XCTAssertEqual(output.format.channelCount, 1)
                XCTAssertEqual(output.format.sampleRate, 16_000, accuracy: 0.5)
                XCTAssertEqual(Int(output.frameLength), 160)
                XCTAssertNotNil(output.floatChannelData)
                exp.fulfill()
            }
            .store(in: &cancellables)

        plugin.write(input)
        wait(for: [exp], timeout: 1.0)
    }

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
        buffer.frameLength = frameLength
        if let channelData = buffer.floatChannelData {
            let frames = Int(frameLength)
            for ch in 0..<Int(channels) {
                for i in 0..<frames {
                    channelData[ch][i] = Float(i % 32) / 32.0 + Float(ch) * 0.1
                }
            }
        }
        return buffer
    }
}
