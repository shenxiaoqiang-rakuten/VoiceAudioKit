//
//  DefaultVoiceRecorder.swift
//  VoiceAudioKit
//
//  Default implementation of VoiceRecorder
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import VoiceAudioProtocol

public final class DefaultVoiceRecorder: VoiceRecorder, @unchecked Sendable {

    public var pcmBufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        pcmBufferSubject
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .eraseToAnyPublisher()
    }

    public var statePublisher: AnyPublisher<VoiceRecorderState, Never> {
        stateSubject.removeDuplicates().eraseToAnyPublisher()
    }

    public func start() async throws {
        guard let manager else {
            stateQueue.sync { transition(to: .error(.managerUnavailable)) }
            throw VoiceRecorderError.managerUnavailable
        }

        let requirement: VoiceSessionRequirement = enableVoiceProcessing ? .recordAndPlayback : .recordOnly
        let registerResult = await manager.register(requirement: requirement, clientId: clientId)

        var error: Error?
        stateQueue.sync {
            guard state == .idle else {
                if case .success = registerResult {
                    manager.unregister(clientId: clientId)
                }
                error = VoiceRecorderError.busy(String(describing: state))
                return
            }
            switch registerResult {
            case .success:
                error = performStartAfterRegister()
            case .failure(let e):
                let recorderError: VoiceRecorderError
                if case .permissionDenied = e { recorderError = .permissionDenied }
                else if case .chatCallActive = e { recorderError = .chatCallActive }
                else if case .busy(let msg) = e { recorderError = .busy(msg) }
                else { recorderError = .configurationFailed }
                transition(to: .error(recorderError))
                error = recorderError
            }
        }
        if let error { throw error }
    }

    public func stop() {
        stateQueue.async { [weak self] in
            self?.performStop()
        }
    }

    /// Voice processing (AEC + noise reduction). Can be toggled before each start for A/B comparison.
    public var enableVoiceProcessing: Bool

    public init(configuration: VoiceRecorderConfiguration = .default, manager: VoiceSessionManager? = nil) {
        self.configuration = configuration
        self.enableVoiceProcessing = configuration.enableVoiceProcessing
        self.manager = manager ?? DefaultVoiceSessionManager.shared
        self.pcmBufferSubject = PassthroughSubject()
        self.stateSubject = CurrentValueSubject(.idle)
        setupEventSubscriptions()
    }

    deinit {
        cancellables.removeAll()
        manager?.unregister(clientId: clientId)
    }

    // MARK: - Private

    private let clientId = VoiceClientId()
    private let configuration: VoiceRecorderConfiguration
    private weak var manager: VoiceSessionManager?
    private let stateQueue = DispatchQueue(label: "com.masteraudio.recorder.state", qos: .userInitiated)
    private var state: VoiceRecorderState = .idle {
        didSet { stateSubject.send(state) }
    }
    private let pcmBufferSubject: PassthroughSubject<AVAudioPCMBuffer, Never>
    private let stateSubject: CurrentValueSubject<VoiceRecorderState, Never>
    private var cancellables = Set<AnyCancellable>()
    private var audioEngine: AVAudioEngine?

    private func setupEventSubscriptions() {
        guard let manager else { return }

        manager.interruptPublisher
            .receive(on: stateQueue)
            .sink { [weak self] event in
                self?.handleInterrupt(event)
            }
            .store(in: &cancellables)

        manager.deviceSwitchPublisher
            .receive(on: stateQueue)
            .sink { [weak self] event in
                self?.handleDeviceSwitch(event)
            }
            .store(in: &cancellables)

        manager.chatCallTakeoverPublisher
            .receive(on: stateQueue)
            .sink { [weak self] in
                self?.handleChatCallTakeover()
            }
            .store(in: &cancellables)

        manager.chatCallReleasedPublisher
            .receive(on: stateQueue)
            .sink { [weak self] in
                self?.handleChatCallReleased()
            }
            .store(in: &cancellables)
    }

    private func handleChatCallReleased() {
        if case .error(.chatCallActive) = state {
            transition(to: .idle)
        }
    }

    private func handleChatCallTakeover() {
        if state == .recording || state == .stopped || state == .deviceSwitching {
            stopEngine()
            manager?.unregister(clientId: clientId)
            transition(to: .idle)
        }
    }

    private func performStartAfterRegister() -> Error? {
        switch state {
        case .idle:
            return startEngine(register: false)
        case .recording:
            return nil
        case .stopped, .deviceSwitching:
            return VoiceRecorderError.busy(String(describing: state))
        case .error:
            return VoiceRecorderError.configurationFailed
        }
    }

    private func performStop() {
        switch state {
        case .recording, .stopped, .deviceSwitching:
            stateQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.stopEngine()
                self.manager?.unregister(clientId: self.clientId)
                self.transition(to: .idle)
            }
        case .idle, .error:
            break
        }
    }

    private func startEngine(register: Bool = true) -> Error? {
        #if targetEnvironment(simulator)
        return startEngineSimulator()
        #else
        return startEngineDevice()
        #endif
    }

    #if targetEnvironment(simulator)
    private var simulatorTimer: DispatchSourceTimer?

    private func startEngineSimulator() -> Error? {
        transition(to: .recording)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return }
            buffer.frameLength = 1024
            self.pcmBufferSubject.send(buffer)
        }
        timer.resume()
        simulatorTimer = timer
        return nil
    }

    private func stopEngineSimulator() {
        simulatorTimer?.cancel()
        simulatorTimer = nil
    }
    #endif

    private func startEngineDevice() -> Error? {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let bufferSize: AVAudioFrameCount = 1024

        if enableVoiceProcessing {
            try? inputNode.setVoiceProcessingEnabled(true)
            // If above fails (e.g. some simulators), recording continues without AEC
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.pcmBufferSubject.send(buffer)
        }

        do {
            engine.prepare()

            try engine.start()
            audioEngine = engine
            transition(to: .recording)
            return nil
        } catch {
            inputNode.removeTap(onBus: 0)
            transition(to: .error(.configurationFailed))
            return error
        }
    }

    private func stopEngine() {
        #if targetEnvironment(simulator)
        stopEngineSimulator()
        #else
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        #endif
    }

    private func handleInterrupt(_ event: VoiceInterruptEvent) {
        switch event {
        case .began:
            if state == .recording {
                stopEngine()
                transition(to: .stopped)
            }
        case .ended(shouldResume: let resume):
            if resume, state == .stopped {
                _ = startEngine(register: false)
            } else if state == .stopped {
                transition(to: .idle)
                manager?.unregister(clientId: clientId)
            }
        }
    }

    private func handleDeviceSwitch(_ event: VoiceRouteChangeEvent) {
        guard state == .recording else { return }
        guard shouldRestartForRouteChange(event.reason) else { return }

        transition(to: .deviceSwitching)
        stopEngine()

        stateQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.startEngine(register: false) == nil {
                // success
            } else {
                self.transition(to: .idle)
                self.manager?.unregister(clientId: self.clientId)
            }
        }
    }

    private func shouldRestartForRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep:
            return true
        case .categoryChange, .override, .routeConfigurationChange, .noSuitableRouteForCategory:
            return false
        @unknown default:
            return false
        }
    }

    private func transition(to newState: VoiceRecorderState) {
        state = newState
    }
}
