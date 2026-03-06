//
//  VoiceSessionManager.swift
//  VoiceAudioKit
//
//  Interface for audio session management. Implementation: DefaultVoiceSessionManager
//

@preconcurrency import AVFoundation
import Combine
import Foundation

// MARK: - VoiceSessionManager (Protocol)

/// Internal interface for audio session management. Not exposed to external consumers.
public protocol VoiceSessionManager: AnyObject {

    /// Register a client's session requirement. Called when Recorder/Player starts.
    /// Requests microphone permission if recording is needed.
    func register(requirement: VoiceSessionRequirement, clientId: VoiceClientId) async -> Result<Void, VoiceSessionError>

    /// Unregister a client. Called when Recorder/Player/ChatCall stops or deallocates.
    func unregister(clientId: VoiceClientId)

    /// Publisher for audio session interruption events (phone call, alarm, etc.)
    var interruptPublisher: AnyPublisher<VoiceInterruptEvent, Never> { get }

    /// Publisher for audio route change events (headphone plug, Bluetooth, etc.)
    var deviceSwitchPublisher: AnyPublisher<VoiceRouteChangeEvent, Never> { get }

    /// Publisher for ChatCall takeover: when ChatCall starts, recorder and player must stop.
    var chatCallTakeoverPublisher: AnyPublisher<Void, Never> { get }

    /// Publisher for ChatCall release: when ChatCall ends (unregisters), recorder/player in .error(.chatCallActive) can reset to idle.
    var chatCallReleasedPublisher: AnyPublisher<Void, Never> { get }
}
