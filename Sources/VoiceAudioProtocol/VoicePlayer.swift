//
//  VoicePlayer.swift
//  VoiceAudioKit
//
//  Interface for audio playback. Implementation: DefaultVoicePlayer
//

@preconcurrency import AVFoundation
import Combine
import Foundation

// MARK: - VoicePlaybackProgress

/// Playback progress: current time and total duration (nil for PCM stream).
public struct VoicePlaybackProgress: Equatable, Sendable {
    public let currentTime: TimeInterval
    public let duration: TimeInterval?

    public init(currentTime: TimeInterval, duration: TimeInterval?) {
        self.currentTime = currentTime
        self.duration = duration
    }
}

// MARK: - VoicePlayer (Protocol)

/// Public interface for audio playback.
/// Supports URL (file) and PCM buffer input; emits PCM currently being played.
public protocol VoicePlayer: AnyObject {

    /// PCM buffer stream of audio currently being played. Emits only when playing.
    var pcmBufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { get }

    /// State stream. Emits on every state change.
    var statePublisher: AnyPublisher<VoicePlayerState, Never> { get }

    /// Playback progress stream. Emits when playing; duration is nil for PCM stream.
    var progressPublisher: AnyPublisher<VoicePlaybackProgress, Never> { get }

    /// Play from URL (file). Throws if file invalid or configuration failed.
    func play(url: URL) async throws

    /// Play from PCM stream. Call write(_:) to queue buffers, then play() to start.
    func play() async throws

    /// Queue PCM buffer for playback. Call play() after queuing to start.
    func write(_ buffer: AVAudioPCMBuffer)

    /// Pause playback. Keeps position; can resume.
    func pause()

    /// Resume playback from paused state.
    func resume()

    /// Stop playback. Clears queue and resets to idle.
    func stop()
}

// MARK: - VoicePlayerConfiguration

/// Configuration for VoicePlayer at initialization
public struct VoicePlayerConfiguration: Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public static let `default` = VoicePlayerConfiguration(
        sampleRate: 48000,
        channelCount: 1
    )

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

// MARK: - VoicePlayerState

/// Player state machine states
public enum VoicePlayerState: Equatable, Sendable {
    case idle
    case playing
    case paused
    case stopped
    case deviceSwitching
    case error(VoicePlayerError)
}
