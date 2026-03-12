//
//  VoiceChatCall.swift
//  VoiceAudioKit
//
//  Interface for voice call with echo cancellation. Implementation: DefaultVoiceChatCall
//

@preconcurrency import AVFoundation
import Combine
import Foundation

// MARK: - VoiceChatCall (Protocol)

/// Public interface for voice call with AEC (Acoustic Echo Cancellation).
/// Uses AudioUnit VoiceProcessingIO under the hood.
public protocol VoiceChatCall: AnyObject {

    /// PCM buffer stream of local microphone input (AEC applied). Emits when call is active.
    var localPcmPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { get }

    /// State stream. Emits on every state change.
    var statePublisher: AnyPublisher<VoiceChatCallState, Never> { get }

    /// Start the call. Throws if configuration failed, permission denied, or invalid state.
    func start() async throws

    /// Stop the call. Safe to call from any thread.
    func stop()

    /// Write remote audio buffer to play through speaker. Call when receiving audio from peer.
    func write(_ buffer: AVAudioPCMBuffer)

    /// Playback format for remote audio. Nil when not active. Use for creating test buffers.
    var playbackFormat: AVAudioFormat? { get }
}

// MARK: - VoiceChatCallConfiguration

/// Configuration for VoiceChatCall at initialization
public struct VoiceChatCallConfiguration: Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public static let `default` = VoiceChatCallConfiguration(
        sampleRate: 16000,
        channelCount: 1
    )

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

// MARK: - VoiceChatCallState

public enum VoiceChatCallState: Equatable, Sendable {
    case idle
    case active
    case deviceSwitching
    case error(VoiceChatCallError)
}
