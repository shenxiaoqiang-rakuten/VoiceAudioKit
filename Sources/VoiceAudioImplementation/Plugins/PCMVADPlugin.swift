//
//  PCMVADPlugin.swift
//  MasterAudioKit
//
//  PCM Voice Activity Detection plugin. Energy-based VAD with adaptive threshold.
//

import Accelerate
import AVFoundation
import Combine
import Foundation

/// Voice activity detection result.
public enum VADResult: Equatable {
    case silence
    case speech
}

/// PCM voice activity detection plugin. Energy-based VAD with adaptive threshold.
/// Suitable for speech detection in quiet environments.
public final class PCMVADPlugin {

    /// Whether speech is currently detected.
    public var isSpeech: Bool { _isSpeech }

    /// VAD result stream. Emits only when state changes.
    public var vadPublisher: AnyPublisher<VADResult, Never> {
        vadSubject.eraseToAnyPublisher()
    }

    /// Threshold coefficient. Actual threshold = noise floor * sensitivity. Default 2.5; higher = less sensitive.
    public var sensitivity: Float = 2.5

    /// Frames to keep speech state after energy drops below threshold. Prevents tail clipping. Default 8.
    public var hangoverFrames: Int = 8

    /// Noise floor update rate (0...1). EMA tracks ambient noise when silent. Higher = faster adaptation. Default 0.002.
    public var noiseFloorRiseRate: Float = 0.002

    private let minNoiseFloor: Float = 1e-6

    public init() {}

    /// Write PCM buffer. Thread-safe. Throttled to avoid queue buildup.
    public func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.processBufferThrottled(buffer)
        }
    }

    /// Reset internal state (e.g. when switching environments).
    public func reset() {
        queue.async { [weak self] in
            self?.noiseFloor = self?.minNoiseFloor ?? 1e-6
            self?._isSpeech = false
            self?.hangoverCounter = 0
        }
    }

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.masteraudio.pcmvadplugin", qos: .userInitiated)
    private let vadSubject = PassthroughSubject<VADResult, Never>()
    private var _isSpeech = false
    private var noiseFloor: Float = 1e-6
    private var hangoverCounter: Int = 0
    private var lastPublishTime: CFTimeInterval = 0
    private let minPublishInterval: CFTimeInterval = 1.0 / 30.0
    private var lastProcessTime: CFTimeInterval = 0
    private let minProcessInterval: CFTimeInterval = 1.0 / 50.0

    private func processBufferThrottled(_ buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= minProcessInterval else { return }
        lastProcessTime = now
        processBuffer(buffer)
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameLength))

        let threshold = noiseFloor * sensitivity
        let isAboveThreshold = rms > threshold

        if isAboveThreshold {
            hangoverCounter = hangoverFrames
            if !_isSpeech {
                _isSpeech = true
                publishIfNeeded(.speech)
            }
        } else {
            if hangoverCounter > 0 {
                hangoverCounter -= 1
            } else {
                if _isSpeech {
                    _isSpeech = false
                    publishIfNeeded(.silence)
                }
                noiseFloor = noiseFloor * (1 - noiseFloorRiseRate) + rms * noiseFloorRiseRate
                noiseFloor = max(noiseFloor, minNoiseFloor)
            }
        }
    }

    private func publishIfNeeded(_ result: VADResult) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime >= minPublishInterval else { return }
        lastPublishTime = now
        vadSubject.send(result)
    }
}
