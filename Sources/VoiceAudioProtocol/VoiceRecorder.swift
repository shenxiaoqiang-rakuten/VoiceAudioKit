//
//  VoiceRecorder.swift
//  VoiceAudioKit
//
//  Interface for audio recording. Implementation: DefaultVoiceRecorder
//

@preconcurrency import AVFoundation
import Combine
import Foundation

// MARK: - VoiceRecorder (Protocol)

/// Public interface for audio recording.
public protocol VoiceRecorder: AnyObject, Sendable {

    /// PCM buffer stream. Emits only when recording. Use buffer/drop operators for backpressure.
    var pcmBufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { get }

    /// State stream. Emits on every state change.
    var statePublisher: AnyPublisher<VoiceRecorderState, Never> { get }

    /// Start recording. Throws if configuration failed, permission denied, or invalid state.
    func start() async throws

    /// Stop recording. Safe to call from any thread.
    func stop()
}

// MARK: - VoiceRecorderConfiguration

/// Configuration for VoiceRecorder at initialization
public struct VoiceRecorderConfiguration: Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    /// Enables voice processing (AEC + noise reduction) on inputNode. Use recordAndPlayback session for AEC.
    public let enableVoiceProcessing: Bool

    public static let `default` = VoiceRecorderConfiguration(
        sampleRate: 16000,
        channelCount: 1,
        enableVoiceProcessing: true
    )

    public init(sampleRate: Double, channelCount: Int, enableVoiceProcessing: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.enableVoiceProcessing = enableVoiceProcessing
    }
}

// MARK: - VoiceRecorderState

/// Recorder state machine states
public enum VoiceRecorderState: Equatable, Sendable {
    case idle
    case recording
    case stopped
    case deviceSwitching
    case error(VoiceRecorderError)
}
