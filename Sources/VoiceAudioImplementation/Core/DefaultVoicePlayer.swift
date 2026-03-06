//
//  DefaultVoicePlayer.swift
//  VoiceAudioKit
//
//  Default implementation of VoicePlayer
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import VoiceAudioProtocol

public final class DefaultVoicePlayer: VoicePlayer {

    public var pcmBufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        pcmBufferSubject
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .eraseToAnyPublisher()
    }

    public var statePublisher: AnyPublisher<VoicePlayerState, Never> {
        stateSubject.removeDuplicates().eraseToAnyPublisher()
    }

    public var progressPublisher: AnyPublisher<VoicePlaybackProgress, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    public func play(url: URL) async throws {
        guard let manager else {
            stateQueue.sync { transition(to: .error(.managerUnavailable)) }
            throw VoicePlayerError.managerUnavailable
        }

        let registerResult = await manager.register(requirement: .playbackOnly, clientId: clientId)

        var error: Error?
        stateQueue.sync {
            guard state == .idle || state == .stopped else {
                if case .success = registerResult {
                    manager.unregister(clientId: clientId)
                }
                error = VoicePlayerError.busy(String(describing: state))
                return
            }
            switch registerResult {
            case .success:
                error = performPlayURL(url)
            case .failure(let e):
                if case .chatCallActive = e {
                    transition(to: .error(.chatCallActive))
                    error = VoicePlayerError.chatCallActive
                } else if case .busy(let msg) = e {
                    transition(to: .error(.busy(msg)))
                    error = VoicePlayerError.busy(msg)
                } else {
                    transition(to: .error(.configurationFailed))
                    error = VoicePlayerError.configurationFailed
                }
            }
        }
        if let error { throw error }
    }

    public func play() async throws {
        guard let manager else {
            stateQueue.sync { transition(to: .error(.managerUnavailable)) }
            throw VoicePlayerError.managerUnavailable
        }

        let registerResult = await manager.register(requirement: .playbackOnly, clientId: clientId)

        var error: Error?
        stateQueue.sync {
            guard state == .idle || state == .stopped else {
                if case .success = registerResult {
                    manager.unregister(clientId: clientId)
                }
                error = VoicePlayerError.busy(String(describing: state))
                return
            }
            switch registerResult {
            case .success:
                error = performPlayPCM()
            case .failure(let e):
                if case .chatCallActive = e {
                    transition(to: .error(.chatCallActive))
                    error = VoicePlayerError.chatCallActive
                } else if case .busy(let msg) = e {
                    transition(to: .error(.busy(msg)))
                    error = VoicePlayerError.busy(msg)
                } else {
                    transition(to: .error(.configurationFailed))
                    error = VoicePlayerError.configurationFailed
                }
            }
        }
        if let error { throw error }
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.pcmQueue.count >= Self.pcmQueueMaxCount {
                self.pcmQueue.removeFirst()
            }
            self.pcmQueue.append(buffer)
        }
    }

    public func pause() {
        stateQueue.async { [weak self] in
            self?.performPause()
        }
    }

    public func resume() {
        stateQueue.async { [weak self] in
            self?.performResume()
        }
    }

    public func stop() {
        stateQueue.async { [weak self] in
            self?.performStop()
        }
    }

    public init(configuration: VoicePlayerConfiguration = .default, manager: VoiceSessionManager? = nil) {
        self.configuration = configuration
        self.manager = manager ?? DefaultVoiceSessionManager.shared
        self.pcmBufferSubject = PassthroughSubject()
        self.stateSubject = CurrentValueSubject(.idle)
        self.progressSubject = PassthroughSubject()
        setupEventSubscriptions()
    }

    deinit {
        cancellables.removeAll()
        manager?.unregister(clientId: clientId)
    }

    // MARK: - Private

    private static let pcmQueueMaxCount = 256

    private let clientId = VoiceClientId()
    private let configuration: VoicePlayerConfiguration
    private weak var manager: VoiceSessionManager?
    private let stateQueue = DispatchQueue(label: "com.masteraudio.player.state", qos: .userInitiated)
    private var state: VoicePlayerState = .idle {
        didSet { stateSubject.send(state) }
    }
    private let pcmBufferSubject: PassthroughSubject<AVAudioPCMBuffer, Never>
    private let stateSubject: CurrentValueSubject<VoicePlayerState, Never>
    private let progressSubject: PassthroughSubject<VoicePlaybackProgress, Never>
    private var cancellables = Set<AnyCancellable>()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var pcmQueue: [AVAudioPCMBuffer] = []
    private var playbackFormat: AVAudioFormat?
    private var totalDuration: TimeInterval?
    private var isPaused = false
    private var progressTimer: DispatchSourceTimer?

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
        if state == .playing || state == .paused || state == .stopped || state == .deviceSwitching {
            performStop()
        }
    }

    private func performPlayURL(_ url: URL) -> Error? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            transition(to: .error(.invalidURL))
            return VoicePlayerError.invalidURL
        }

        guard let file = try? AVAudioFile(forReading: url) else {
            transition(to: .error(.fileLoadFailed))
            return VoicePlayerError.fileLoadFailed
        }

        let format = file.processingFormat
        playbackFormat = format

        #if targetEnvironment(simulator)
        return performPlayURLSimulator(url: url, format: format)
        #else
        return performPlayURLDevice(file: file, format: format)
        #endif
    }

    #if targetEnvironment(simulator)
    private var simulatorPlaybackTimer: DispatchSourceTimer?
    private var simulatorFramesPlayed: Int64 = 0

    private func performPlayURLSimulator(url: URL, format: AVAudioFormat) -> Error? {
        guard let file = try? AVAudioFile(forReading: url) else { return VoicePlayerError.fileLoadFailed }
        let bufferSize: AVAudioFrameCount = 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { return VoicePlayerError.fileLoadFailed }

        totalDuration = Double(file.length) / format.sampleRate
        simulatorFramesPlayed = 0
        transition(to: .playing)
        startProgressTimer()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: Double(bufferSize) / format.sampleRate)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else {
                    timer.cancel()
                    self.stateQueue.async { self.performStop() }
                    return
                }
                self.simulatorFramesPlayed += Int64(buffer.frameLength)
                self.pcmBufferSubject.send(buffer)
            } catch {
                timer.cancel()
                self.stateQueue.async { self.performStop() }
            }
        }
        timer.resume()
        simulatorPlaybackTimer = timer
        return nil
    }
    #endif

    private func performPlayURLDevice(file: AVAudioFile, format: AVAudioFormat) -> Error? {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: format)

        let bufferSize: AVAudioFrameCount = 4096
        mainMixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.pcmBufferSubject.send(buffer)
        }

        do {
            try engine.start()
            totalDuration = Double(file.length) / file.processingFormat.sampleRate
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                self?.stateQueue.async {
                    self?.onPlaybackFinished()
                }
            }
            playerNode.play()

            audioEngine = engine
            self.playerNode = playerNode
            playbackFormat = format
            transition(to: .playing)
            startProgressTimer()
            return nil
        } catch {
            mainMixer.removeTap(onBus: 0)
            transition(to: .error(.configurationFailed))
            return error
        }
    }

    private func performPlayPCM() -> Error? {
        guard let firstBuffer = pcmQueue.first else {
            transition(to: .idle)
            manager?.unregister(clientId: clientId)
            return nil
        }

        let format = firstBuffer.format
        playbackFormat = format

        #if targetEnvironment(simulator)
        return performPlayPCMSimulator(format: format)
        #else
        return performPlayPCMDevice(format: format)
        #endif
    }

    #if targetEnvironment(simulator)
    private func performPlayPCMSimulator(format: AVAudioFormat) -> Error? {
        transition(to: .playing)
        scheduleNextPCMSimulator()
        return nil
    }

    private func scheduleNextPCMSimulator() {
        guard state == .playing, !pcmQueue.isEmpty else {
            if state == .playing {
                performStop()
            }
            return
        }
        let buffer = pcmQueue.removeFirst()
        pcmBufferSubject.send(buffer)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        stateQueue.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.scheduleNextPCMSimulator()
        }
    }
    #endif

    private func performPlayPCMDevice(format: AVAudioFormat) -> Error? {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: format)

        let bufferSize: AVAudioFrameCount = 4096
        mainMixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.pcmBufferSubject.send(buffer)
        }

        do {
            try engine.start()
            audioEngine = engine
            self.playerNode = playerNode
            transition(to: .playing)
            scheduleNextPCMBuffer()
            return nil
        } catch {
            mainMixer.removeTap(onBus: 0)
            transition(to: .error(.configurationFailed))
            return error
        }
    }

    private func scheduleNextPCMBuffer() {
        guard state == .playing || state == .paused else { return }
        guard !pcmQueue.isEmpty else {
            if state == .playing {
                onPlaybackFinished()
            }
            return
        }

        let buffer = pcmQueue.removeFirst()
        playerNode?.scheduleBuffer(buffer) { [weak self] in
            self?.stateQueue.async {
                self?.scheduleNextPCMBuffer()
            }
        }

        if !isPaused {
            playerNode?.play()
        }
    }

    private func performPause() {
        guard state == .playing else { return }
        #if targetEnvironment(simulator)
        simulatorPlaybackTimer?.suspend()
        #else
        playerNode?.pause()
        #endif
        isPaused = true
        transition(to: .paused)
    }

    private func performResume() {
        guard state == .paused else { return }
        #if targetEnvironment(simulator)
        simulatorPlaybackTimer?.resume()
        #else
        playerNode?.play()
        #endif
        isPaused = false
        transition(to: .playing)
    }

    private func performStop() {
        switch state {
        case .playing, .paused, .stopped, .deviceSwitching:
            stopProgressTimer()
            progressSubject.send(VoicePlaybackProgress(currentTime: 0, duration: nil))
            #if targetEnvironment(simulator)
            simulatorPlaybackTimer?.cancel()
            simulatorPlaybackTimer = nil
            #else
            if let engine = audioEngine {
                engine.mainMixerNode.removeTap(onBus: 0)
            }
            playerNode?.stop()
            audioEngine?.stop()
            audioEngine = nil
            playerNode = nil
            #endif
            pcmQueue.removeAll()
            totalDuration = nil
            isPaused = false
            manager?.unregister(clientId: clientId)
            transition(to: .idle)
        case .idle, .error:
            break
        }
    }

    private func onPlaybackFinished() {
        #if targetEnvironment(simulator)
        if state == .playing || state == .paused {
            performStop()
        }
        #else
        if pcmQueue.isEmpty {
            performStop()
        } else {
            scheduleNextPCMBuffer()
        }
        #endif
    }

    private func handleInterrupt(_ event: VoiceInterruptEvent) {
        switch event {
        case .began:
            if state == .playing {
                playerNode?.pause()
                isPaused = true
                transition(to: .stopped)
            }
        case .ended(shouldResume: let resume):
            if resume, state == .stopped {
                playerNode?.play()
                isPaused = false
                transition(to: .playing)
            } else if state == .stopped {
                performStop()
            }
        }
    }

    private func handleDeviceSwitch(_ event: VoiceRouteChangeEvent) {
        guard state == .playing || state == .paused else { return }
        guard shouldRestartForRouteChange(event.reason) else { return }

        transition(to: .deviceSwitching)
        if let engine = audioEngine {
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil

        stateQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if let format = self.playbackFormat, !self.pcmQueue.isEmpty {
                _ = self.performPlayPCMDevice(format: format)
            } else {
                self.performStop()
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

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in
            self?.emitProgress()
        }
        timer.resume()
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func emitProgress() {
        guard state == .playing || state == .paused else { return }
        guard let format = playbackFormat else { return }

        #if targetEnvironment(simulator)
        let current = Double(simulatorFramesPlayed) / format.sampleRate
        progressSubject.send(VoicePlaybackProgress(currentTime: current, duration: totalDuration))
        #else
        guard let playerNode else { return }
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let current = Double(playerTime.sampleTime) / format.sampleRate
            let capped = min(current, totalDuration ?? .infinity)
            progressSubject.send(VoicePlaybackProgress(currentTime: capped, duration: totalDuration))
        }
        #endif
    }

    private func transition(to newState: VoicePlayerState) {
        state = newState
    }
}
