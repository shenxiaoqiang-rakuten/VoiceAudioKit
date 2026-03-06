//
//  VoiceTypes.swift
//  VoiceAudioKit
//
//  Shared types for VoiceRecorder, VoicePlayer, VoiceChatCall, and VoiceSessionManager
//

@preconcurrency import AVFoundation
import Combine
import Foundation

// MARK: - Voice Client Identification

/// Unique identifier for audio clients (Recorder/Player/ChatCall) registered with VoiceSessionManager
public struct VoiceClientId: Hashable, Sendable {
    private let id = UUID()

    public init() {}
}

// MARK: - Voice Session Requirement

/// Describes what session configuration a client needs
public enum VoiceSessionRequirement: Equatable, Sendable {
    case recordOnly
    case playbackOnly
    case recordAndPlayback
    /// Voice call with AEC. Highest priority; preempts recorder and player.
    case chatCall
}

// MARK: - Voice Interrupt Event

/// Audio session interruption event from system
public enum VoiceInterruptEvent: Sendable {
    case began
    case ended(shouldResume: Bool)
}

// MARK: - Voice Route Change Event

/// Audio route change event (e.g. headphone plug, Bluetooth switch)
public struct VoiceRouteChangeEvent: Sendable {
    public let reason: AVAudioSession.RouteChangeReason
    public let previousRoute: AVAudioSessionRouteDescription?

    public init(reason: AVAudioSession.RouteChangeReason, previousRoute: AVAudioSessionRouteDescription?) {
        self.reason = reason
        self.previousRoute = previousRoute
    }
}

// MARK: - Voice Session Errors

public enum VoiceSessionError: Error, Sendable {
    case migrationFailed(String)
    case permissionDenied
    case configurationConflict
    /// ChatCall is active; recorder/player requests are rejected
    case chatCallActive
    /// Another client of the same type is already active (e.g. only one Recorder/Player/ChatCall at a time)
    case busy(String)
}

// MARK: - Voice Recorder Errors

public enum VoiceRecorderError: Error, Equatable, Sendable {
    case managerUnavailable
    case configurationFailed
    case permissionDenied
    case busy(String)
    case invalidTransition
    case chatCallActive
}

// MARK: - Voice Player Errors

public enum VoicePlayerError: Error, Equatable, Sendable {
    case managerUnavailable
    case configurationFailed
    case invalidURL
    case fileLoadFailed
    case busy(String)
    case invalidTransition
    case chatCallActive
}

// MARK: - Voice ChatCall Errors

public enum VoiceChatCallError: Error, Equatable, Sendable {
    case managerUnavailable
    case configurationFailed
    case permissionDenied
    case busy(String)
}
