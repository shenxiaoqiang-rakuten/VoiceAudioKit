//
//  PCMFormatConverterPlugin.swift
//  VoiceAudioKit
//
//  Plugin that converts PCM buffers from current format to target sample rate and channels.
//  Uses vDSP linear interpolation for resampling (standard, reliable algorithm).
//

import Accelerate
import AVFoundation
import Combine
import Foundation

/// Plugin that converts PCM buffers to a target format (sample rate, channel count).
/// Pass-through when input already matches target; otherwise uses vDSP linear interpolation.
public final class PCMFormatConverterPlugin {

    /// Converted PCM buffer stream. Emits on the same queue as write().
    public var convertedBufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        convertedSubject.eraseToAnyPublisher()
    }

    private let targetFormat: AVAudioFormat
    private let convertedSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let queue = DispatchQueue(label: "com.masteraudio.pcmformatconverter", qos: .userInitiated)

    /// Initialize with target sample rate and channel count.
    /// - Parameters:
    ///   - targetSampleRate: e.g. 16000 for voice recognition, 48000 for playback
    ///   - targetChannelCount: Default 1 (mono)
    public init(targetSampleRate: Double, targetChannelCount: Int = 1) {
        self.targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannelCount)
        )!
    }

    /// Write PCM buffer. Converts to target format if needed; emits via convertedBufferPublisher.
    public func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.processBuffer(buffer)
        }
    }

    // MARK: - Private

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        if formatsMatch(buffer.format, targetFormat) {
            convertedSubject.send(buffer)
            return
        }

        guard let converted = resampleBuffer(buffer, to: targetFormat) else { return }
        convertedSubject.send(converted)
    }

    private func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        abs(a.sampleRate - b.sampleRate) < 0.5 && a.channelCount == b.channelCount
    }

    private func resampleBuffer(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        let inputFrames = Int(buffer.frameLength)
        guard inputFrames > 0 else { return nil }

        // 1. Extract float mono samples from input
        let inputSamples: [Float]
        if let floatData = buffer.floatChannelData {
            inputSamples = extractMonoFloat(floatData, channelCount: Int(inputFormat.channelCount), frameCount: inputFrames, interleaved: inputFormat.isInterleaved)
        } else if let int16Data = buffer.int16ChannelData {
            inputSamples = int16ToFloatMono(int16Data, channelCount: Int(inputFormat.channelCount), frameCount: inputFrames, interleaved: inputFormat.isInterleaved)
        } else {
            return nil
        }

        // 2. Anti-aliasing filter when downsampling
        let filteredSamples: [Float]
        if outputFormat.sampleRate < inputFormat.sampleRate - 100 {
            filteredSamples = lowPassFilter(input: inputSamples, cutoffRatio: outputFormat.sampleRate / inputFormat.sampleRate)
        } else {
            filteredSamples = inputSamples
        }

        // 3. Resample
        let outputFrameCount = Int(ceil(Double(filteredSamples.count) * outputFormat.sampleRate / inputFormat.sampleRate))
        guard outputFrameCount > 0 else { return nil }

        let outputSamples: [Float]
        if abs(inputFormat.sampleRate - outputFormat.sampleRate) < 0.5 {
            outputSamples = filteredSamples
        } else {
            outputSamples = resampleLinear(input: filteredSamples, inputRate: inputFormat.sampleRate, outputRate: outputFormat.sampleRate, outputCount: outputFrameCount)
        }

        // 4. Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputSamples.count + 1024)) else { return nil }
        outputBuffer.frameLength = AVAudioFrameCount(outputSamples.count)

        guard let outChannelData = outputBuffer.floatChannelData else { return nil }
        outputSamples.withUnsafeBufferPointer { ptr in
            outChannelData[0].update(from: ptr.baseAddress!, count: outputSamples.count)
        }

        return outputBuffer
    }

    private func extractMonoFloat(_ channelData: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount: Int, interleaved: Bool) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        let ch0 = channelData[0]

        if channelCount == 1 {
            for i in 0..<frameCount { result[i] = ch0[i] }
        } else if interleaved {
            // Interleaved: ch0 points to L,R,L,R,...
            for i in 0..<frameCount {
                result[i] = (ch0[i * 2] + ch0[i * 2 + 1]) * 0.5
            }
        } else if channelCount >= 2 {
            let ch1 = channelData[1]
            for i in 0..<frameCount {
                result[i] = (ch0[i] + ch1[i]) * 0.5
            }
        } else {
            for i in 0..<frameCount { result[i] = ch0[i] }
        }
        return result
    }

    private func int16ToFloatMono(_ channelData: UnsafePointer<UnsafeMutablePointer<Int16>>, channelCount: Int, frameCount: Int, interleaved: Bool) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        let ch0 = channelData[0]
        let scale: Float = 1.0 / 32768.0

        if channelCount == 1 {
            for i in 0..<frameCount { result[i] = Float(ch0[i]) * scale }
        } else if interleaved {
            for i in 0..<frameCount {
                result[i] = (Float(ch0[i * 2]) + Float(ch0[i * 2 + 1])) * scale * 0.5
            }
        } else if channelCount >= 2 {
            let ch1 = channelData[1]
            for i in 0..<frameCount {
                result[i] = (Float(ch0[i]) + Float(ch1[i])) * scale * 0.5
            }
        } else {
            for i in 0..<frameCount { result[i] = Float(ch0[i]) * scale }
        }
        return result
    }

    /// Simple low-pass filter (moving average) to prevent aliasing when downsampling.
    private func lowPassFilter(input: [Float], cutoffRatio: Double) -> [Float] {
        guard cutoffRatio < 1 else { return input }
        let n = input.count
        let taps = min(Int(ceil(3.0 / cutoffRatio)), 31) // ~3 taps per octave of cutoff
        let halfTaps = taps / 2
        var result = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            var count: Float = 0
            for j in -halfTaps...halfTaps {
                let idx = i + j
                if idx >= 0, idx < n {
                    sum += input[idx]
                    count += 1
                }
            }
            result[i] = count > 0 ? sum / count : input[i]
        }
        return result
    }

    /// Linear interpolation resampling using vDSP.
    private func resampleLinear(input: [Float], inputRate: Double, outputRate: Double, outputCount: Int) -> [Float] {
        let ratio = inputRate / outputRate
        // For each output index i, source index = i * ratio (in input sample units)
        let controlVector = (0..<outputCount).map { Float($0) * Float(ratio) }
        return vDSP.linearInterpolate(elementsOf: input, using: controlVector)
    }
}
