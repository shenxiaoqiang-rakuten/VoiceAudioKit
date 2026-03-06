//
//  PCMVisualizationPlugin.swift
//  MasterAudioKit
//
//  Plugin that converts PCM to visualization data.
//  Dual mode: RMS waveform (responsive) + FFT spectrum (frequency).
//

import Accelerate
import AVFoundation
import Combine
import Foundation

/// Visualization mode.
public enum PCMVisualizationMode: String, CaseIterable {
    case rmsWaveform  // RMS per segment - responsive, voice-level
    case fftSpectrum  // FFT frequency - spectrum
}

/// Plugin that processes PCM buffers and outputs bar values for visualization.
/// Supports RMS (waveform) and FFT (spectrum) modes.
public final class PCMVisualizationPlugin {

    /// Visualization mode. RMS is more responsive for voice.
    public var mode: PCMVisualizationMode = .rmsWaveform

    /// Spectrum/bar values (0...1 normalized).
    public var spectrumPublisher: AnyPublisher<[Float], Never> {
        spectrumSubject.eraseToAnyPublisher()
    }

    public let barCount: Int

    /// Smoothing (0...1). Lower = smoother, less jumpy.
    public var smoothingFactor: Float = 0.55

    public init(barCount: Int = 32) {
        self.barCount = min(max(barCount, 1), 64)
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.processBuffer(buffer)
        }
    }

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.masteraudio.pcmvisualizationplugin", qos: .userInitiated)
    private let spectrumSubject = PassthroughSubject<[Float], Never>()
    private var lastPublishTime: CFTimeInterval = 0
    private let minPublishInterval: CFTimeInterval = 1.0 / 25.0
    private var smoothedSpectrum: [Float] = []
    private var referenceLevel: Float = 0.01

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime >= minPublishInterval else { return }
        lastPublishTime = now

        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channel = 0
        let baseAddress = channelData[channel]

        let bars: [Float]
        switch mode {
        case .rmsWaveform:
            bars = computeRMSBars(baseAddress: baseAddress, frameLength: frameLength)
        case .fftSpectrum:
            bars = computeFFTBars(baseAddress: baseAddress, frameLength: frameLength, sampleRate: buffer.format.sampleRate)
        }

        let smoothed = applySmoothing(bars)
        spectrumSubject.send(smoothed)
    }

    /// RMS per segment - responsive waveform bars. Uses buffer pointer directly to avoid copy.
    private func computeRMSBars(baseAddress: UnsafeMutablePointer<Float>, frameLength: Int) -> [Float] {
        guard frameLength >= barCount else {
            return [Float](repeating: 0, count: barCount)
        }

        let segmentSize = frameLength / barCount
        var result = [Float](repeating: 0, count: barCount)

        for bar in 0..<barCount {
            let start = bar * segmentSize
            let count = min(segmentSize, frameLength - start)
            guard count > 0 else { continue }

            var rms: Float = 0
            vDSP_rmsqv(baseAddress.advanced(by: start), 1, &rms, vDSP_Length(count))
            result[bar] = rms
        }

        return normalizeBars(result)
    }

    /// FFT spectrum with log frequency mapping. Uses pre-allocated buffers.
    private func computeFFTBars(baseAddress: UnsafeMutablePointer<Float>, frameLength: Int, sampleRate: Double) -> [Float] {
        let fftSize = 1024
        guard frameLength >= fftSize else { return [Float](repeating: 0, count: barCount) }

        guard let magnitudes = runFFT(baseAddress: baseAddress, frameLength: fftSize) else {
            return [Float](repeating: 0, count: barCount)
        }

        let halfCount = Self.fftSize / 2 + 1
        let lowFreq: Double = 20
        let highFreq = min(20000.0, sampleRate / 2)
        let logLow = log10(lowFreq)
        let logHigh = log10(highFreq)
        let logRange = logHigh - logLow

        var result = [Float](repeating: 0, count: barCount)
        for bar in 0..<barCount {
            let t = Double(bar) / Double(barCount)
            let targetFreq = pow(10, logLow + t * logRange)
            let bin = min(Int(targetFreq * Double(Self.fftSize) / sampleRate), halfCount - 1)
            let binStart = max(0, bin - 1)
            let binEnd = min(bin + 2, halfCount)
            var maxVal: Float = 0
            for i in binStart..<binEnd {
                maxVal = max(maxVal, magnitudes[i])
            }
            result[bar] = maxVal
        }
        return normalizeBars(result)
    }

    private static let fftSize = 1024

    private lazy var fftRealBuffer = [Float](repeating: 0, count: Self.fftSize)
    private lazy var fftImagBuffer = [Float](repeating: 0, count: Self.fftSize)
    private lazy var fftMagnitudesBuffer = [Float](repeating: 0, count: Self.fftSize)

    private func runFFT(baseAddress: UnsafeMutablePointer<Float>, frameLength: Int) -> [Float]? {
        guard frameLength == Self.fftSize else { return nil }

        let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
        memcpy(&fftRealBuffer, baseAddress, Self.fftSize * MemoryLayout<Float>.size)

        fftRealBuffer.withUnsafeMutableBufferPointer { rp in
            fftImagBuffer.withUnsafeMutableBufferPointer { ip in
                let input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                var output = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                fft.forward(input: input, output: &output)
                vDSP.absolute(output, result: &fftMagnitudesBuffer)
            }
        }

        return Array(fftMagnitudesBuffer.prefix(Self.fftSize / 2 + 1))
    }

    private func normalizeBars(_ bars: [Float]) -> [Float] {
        let currentMax = bars.max() ?? 0
        if currentMax > 1e-6 {
            referenceLevel = max(referenceLevel * 0.997, currentMax)
        } else {
            referenceLevel *= 0.998
        }
        let scale = 1.0 / max(referenceLevel, 1e-6)
        return bars.map { v in
            let x = max(0, v * scale)
            return min(1, pow(x, 0.55))
        }
    }

    private func applySmoothing(_ new: [Float]) -> [Float] {
        if smoothedSpectrum.count != new.count {
            smoothedSpectrum = new
            return new
        }
        let alpha = smoothingFactor
        for i in 0..<new.count {
            smoothedSpectrum[i] = alpha * new[i] + (1 - alpha) * smoothedSpectrum[i]
        }
        return smoothedSpectrum
    }
}
