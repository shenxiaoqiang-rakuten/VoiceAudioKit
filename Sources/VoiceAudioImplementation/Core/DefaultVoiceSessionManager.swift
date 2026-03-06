//
//  DefaultVoiceSessionManager.swift
//  VoiceAudioKit
//
//  Default implementation of VoiceSessionManager
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import VoiceAudioProtocol

public final class DefaultVoiceSessionManager: VoiceSessionManager {

    public nonisolated(unsafe) static let shared = DefaultVoiceSessionManager()

    public func register(requirement: VoiceSessionRequirement, clientId: VoiceClientId) async -> Result<Void, VoiceSessionError> {
        await state.register(requirement: requirement, clientId: clientId) { [weak self] shouldEmitTakeover in
            if shouldEmitTakeover {
                self?.chatCallTakeoverSubject.send(())
            }
        }
    }

    public func unregister(clientId: VoiceClientId) {
        Task {
            let wasChatCall = await state.unregister(clientId: clientId)
            if wasChatCall {
                chatCallReleasedSubject.send(())
            }
        }
    }

    public var interruptPublisher: AnyPublisher<VoiceInterruptEvent, Never> {
        interruptSubject.eraseToAnyPublisher()
    }

    public var deviceSwitchPublisher: AnyPublisher<VoiceRouteChangeEvent, Never> {
        deviceSwitchSubject.eraseToAnyPublisher()
    }

    public var chatCallTakeoverPublisher: AnyPublisher<Void, Never> {
        chatCallTakeoverSubject.eraseToAnyPublisher()
    }

    public var chatCallReleasedPublisher: AnyPublisher<Void, Never> {
        chatCallReleasedSubject.eraseToAnyPublisher()
    }

    public init() {
        interruptSubject = PassthroughSubject()
        deviceSwitchSubject = PassthroughSubject()
        chatCallTakeoverSubject = PassthroughSubject()
        chatCallReleasedSubject = PassthroughSubject()
        setupSessionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Private

    private let state = VoiceSessionState()
    private let interruptSubject: PassthroughSubject<VoiceInterruptEvent, Never>
    private let deviceSwitchSubject: PassthroughSubject<VoiceRouteChangeEvent, Never>
    private let chatCallTakeoverSubject: PassthroughSubject<Void, Never>
    private let chatCallReleasedSubject: PassthroughSubject<Void, Never>

    private func setupSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            interruptSubject.send(.began)
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            interruptSubject.send(.ended(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        deviceSwitchSubject.send(VoiceRouteChangeEvent(reason: reason, previousRoute: previousRoute))
    }
}

// MARK: - VoiceSessionState (Actor)

private actor VoiceSessionState {

    private var registry: [VoiceClientId: VoiceSessionRequirement] = [:]
    private var currentCategory: SessionCategory?

    func register(requirement: VoiceSessionRequirement, clientId: VoiceClientId, onTakeover: @escaping (Bool) -> Void) async -> Result<Void, VoiceSessionError> {
        if requirement == .recordOnly || requirement == .recordAndPlayback {
            let hasRecord = registry.values.contains { $0 == .recordOnly || $0 == .recordAndPlayback }
            if hasRecord {
                return .failure(.busy("Recorder already active"))
            }
        }
        if requirement == .playbackOnly {
            let hasPlayback = registry.values.contains { $0 == .playbackOnly }
            if hasPlayback {
                return .failure(.busy("Player already active"))
            }
        }
        if requirement == .chatCall {
            let hasChatCall = registry.values.contains { $0 == .chatCall }
            if hasChatCall {
                return .failure(.busy("ChatCall already active"))
            }
        }

        if requirement == .recordOnly || requirement == .playbackOnly || requirement == .recordAndPlayback {
            let hasChatCall = registry.values.contains { $0 == .chatCall }
            if hasChatCall {
                return .failure(.chatCallActive)
            }
        }

        var shouldEmitTakeover = false
        if requirement == .chatCall {
            let hasRecorderOrPlayer = registry.values.contains {
                $0 == .recordOnly || $0 == .playbackOnly || $0 == .recordAndPlayback
            }
            shouldEmitTakeover = hasRecorderOrPlayer
        }

        registry[clientId] = requirement
        let merged = mergeRequirements(Array(registry.values))

        onTakeover(shouldEmitTakeover)
        return await migrateTo(merged)
    }

    func unregister(clientId: VoiceClientId) -> Bool {
        let requirement = registry[clientId]
        registry[clientId] = nil
        let wasChatCall = requirement == .chatCall
        if registry.isEmpty {
            currentCategory = nil
            #if !targetEnvironment(simulator)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        } else {
            let merged = mergeRequirements(Array(registry.values))
            Task { await migrateTo(merged) }
        }
        return wasChatCall
    }

    private func mergeRequirements(_ reqs: [VoiceSessionRequirement]) -> SessionCategory {
        let hasRecord = reqs.contains { $0 == .recordOnly || $0 == .recordAndPlayback || $0 == .chatCall }
        let hasPlayback = reqs.contains { $0 == .playbackOnly || $0 == .recordAndPlayback || $0 == .chatCall }

        if hasRecord && hasPlayback {
            return .playAndRecord
        }
        if hasRecord {
            return .record
        }
        if hasPlayback {
            return .playback
        }
        return .ambient
    }

    private func migrateTo(_ target: SessionCategory) async -> Result<Void, VoiceSessionError> {
        if currentCategory == target {
            return .success(())
        }
        if target.requiresRecordPermission {
            let granted = await requestRecordPermission()
            if !granted {
                return .failure(.permissionDenied)
            }
        }
        let result = await MainActor.run { () -> Result<Void, VoiceSessionError> in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(target.category, mode: target.mode, options: target.options)
                try session.setActive(true)
                return .success(())
            } catch {
                return .failure(.migrationFailed(error.localizedDescription))
            }
        }
        if case .success = result {
            currentCategory = target
        }
        return result
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

// MARK: - Session Category
private enum SessionCategory: Equatable {
    case ambient
    case record
    case playback
    case playAndRecord

    var requiresRecordPermission: Bool {
        switch self {
        case .record, .playAndRecord: return true
        case .ambient, .playback: return false
        }
    }

    var category: AVAudioSession.Category {
        switch self {
        case .ambient: return .ambient
        case .record: return .record
        case .playback: return .playback
        case .playAndRecord: return .playAndRecord
        }
    }

    var mode: AVAudioSession.Mode {
        switch self {
        case .playAndRecord: return .voiceChat
        default: return .default
        }
    }

    var options: AVAudioSession.CategoryOptions {
        switch self {
        case .playAndRecord: return [.defaultToSpeaker, .allowBluetoothHFP]
        default: return []
        }
    }
}
