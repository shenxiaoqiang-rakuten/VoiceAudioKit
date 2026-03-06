//
//  DefaultVoiceChatCall.swift
//  VoiceAudioKit
//
//  Implementation using AudioComponentInstance (VoiceProcessingIO).
//

@preconcurrency import AVFoundation
import AudioToolbox
import Combine
import Foundation
import VoiceAudioProtocol

public final class DefaultVoiceChatCall: VoiceChatCall {

    public var localPcmPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        localPcmSubject
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .eraseToAnyPublisher()
    }

    public var statePublisher: AnyPublisher<VoiceChatCallState, Never> {
        stateSubject.removeDuplicates().eraseToAnyPublisher()
    }

    public func start() async throws {
        guard let manager else {
            stateQueue.sync { transition(to: .error(.managerUnavailable)) }
            throw VoiceChatCallError.managerUnavailable
        }

        let registerResult = await manager.register(requirement: .chatCall, clientId: clientId)

        var error: Error?
        stateQueue.sync {
            guard state == .idle else {
                if case .success = registerResult {
                    manager.unregister(clientId: clientId)
                }
                error = VoiceChatCallError.busy(String(describing: state))
                return
            }
            switch registerResult {
            case .success:
                error = performStartAfterRegister()
            case .failure(let e):
                let callError: VoiceChatCallError
                if case .permissionDenied = e { callError = .permissionDenied }
                else if case .chatCallActive = e { callError = .busy("ChatCall already active") }
                else if case .busy(let msg) = e { callError = .busy(msg) }
                else { callError = .configurationFailed }
                transition(to: .error(callError))
                error = callError
            }
        }
        if let error { throw error }
    }

    public func stop() {
        stateQueue.sync { [weak self] in
            guard let self else { return }
            if case .error = state {
                performStop()
            } else {
                stateQueue.async { self.performStop() }
            }
        }
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.state == .active || self.state == .deviceSwitching else { return }
            guard buffer.frameLength > 0 else { return }
            self.remoteQueueLock.lock()
            if self.remoteQueue.count >= Self.remoteQueueMaxCount {
                self.remoteQueue.removeFirst()
            }
            self.remoteQueue.append(buffer)
            self.remoteQueueLock.unlock()
            #if targetEnvironment(simulator)
            self.scheduleNextRemoteBufferSimulator()
            #endif
        }
    }

    public var playbackFormat: AVAudioFormat? {
        playbackFormatLock.lock()
        defer { playbackFormatLock.unlock() }
        return _playbackFormat
    }

    public init(configuration: VoiceChatCallConfiguration = .default, manager: VoiceSessionManager? = nil) {
        self.configuration = configuration
        self.manager = manager ?? DefaultVoiceSessionManager.shared
        self.localPcmSubject = PassthroughSubject()
        self.stateSubject = CurrentValueSubject(.idle)
        setupEventSubscriptions()
    }

    deinit {
        stateQueue.sync { [weak self] in
            guard let self else { return }
            stopEngine()
            manager?.unregister(clientId: clientId)
        }
        cancellables.removeAll()
    }

    // MARK: - Private

    private static let remoteQueueMaxCount = 256

    private let clientId = VoiceClientId()
    private let playbackFormatLock = NSLock()
    private let configuration: VoiceChatCallConfiguration
    private weak var manager: VoiceSessionManager?
    private let stateQueue = DispatchQueue(label: "com.masteraudio.chatcall.state", qos: .userInitiated)
    private var state: VoiceChatCallState = .idle {
        didSet { stateSubject.send(state) }
    }
    private let localPcmSubject: PassthroughSubject<AVAudioPCMBuffer, Never>
    private let stateSubject: CurrentValueSubject<VoiceChatCallState, Never>
    private var cancellables = Set<AnyCancellable>()
    private var remoteQueue: [AVAudioPCMBuffer] = []
    private let remoteQueueLock = NSLock()
    private var _playbackFormat: AVAudioFormat?

    /// Double buffer: current playback + prefetch to reduce lock contention in render callback.
    private var currentRemoteBuffer: AVAudioPCMBuffer?
    private var nextRemoteBuffer: AVAudioPCMBuffer?
    private var remoteBufferOffset: Int = 0

    #if targetEnvironment(simulator)
    private var simulatorInputTimer: DispatchSourceTimer?
    private var simulatorPhase: Float = 0
    private var simulatorEngine: AVAudioEngine?
    private var simulatorPlayerNode: AVAudioPlayerNode?
    #else
    private var audioUnit: AudioComponentInstance?
    private var inputBufferList: UnsafeMutableAudioBufferListPointer?
    private var inputAVFormat: AVAudioFormat?
    #endif

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
    }

    private func performStartAfterRegister() -> Error? {
        guard state == .idle else { return VoiceChatCallError.busy(String(describing: state)) }
        return startEngine()
    }

    private func performStop() {
        switch state {
        case .active, .deviceSwitching:
            stateQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                self.stopEngine()
                self.manager?.unregister(clientId: self.clientId)
                self.transition(to: .idle)
            }
        case .error:
            manager?.unregister(clientId: clientId)
            transition(to: .idle)
        case .idle:
            break
        }
    }

    private func startEngine() -> Error? {
        #if targetEnvironment(simulator)
        return startEngineSimulator()
        #else
        return startEngineDevice()
        #endif
    }

    // MARK: - Simulator

    #if targetEnvironment(simulator)
    private func startEngineSimulator() -> Error? {
        // Use 48kHz stereo for simulator to match typical output and avoid conversion issues
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        playbackFormatLock.lock()
        _playbackFormat = format
        playbackFormatLock.unlock()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        do {
            engine.prepare()
            try engine.start()
            simulatorEngine = engine
            simulatorPlayerNode = playerNode
        } catch {
            return VoiceChatCallError.configurationFailed
        }

        transition(to: .active)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return }
            buffer.frameLength = 1024
            if let channelData = buffer.floatChannelData {
                let freq: Float = 200
                let sr = Float(format.sampleRate)
                let chCount = Int(format.channelCount)
                for i in 0..<1024 {
                    let sample = sin(self.simulatorPhase) * 0.3
                    self.simulatorPhase += 2 * .pi * freq / sr
                    if self.simulatorPhase > 2 * .pi { self.simulatorPhase -= 2 * .pi }
                    for ch in 0..<chCount {
                        channelData[ch][i] = sample
                    }
                }
            }
            self.localPcmSubject.send(buffer)
        }
        timer.resume()
        simulatorInputTimer = timer
        return nil
    }

    private func stopEngineSimulator() {
        simulatorInputTimer?.cancel()
        simulatorInputTimer = nil
        simulatorPlayerNode?.stop()
        simulatorEngine?.stop()
        simulatorEngine = nil
        simulatorPlayerNode = nil
        remoteQueueLock.lock()
        remoteQueue.removeAll()
        remoteQueueLock.unlock()
    }

    /// Double buffer: fetch up to 2 buffers per lock for consecutive scheduling.
    private func scheduleNextRemoteBufferSimulator() {
        remoteQueueLock.lock()
        guard !remoteQueue.isEmpty, let player = simulatorPlayerNode else {
            remoteQueueLock.unlock()
            return
        }
        let buffer1 = remoteQueue.removeFirst()
        let buffer2 = remoteQueue.isEmpty ? nil : remoteQueue.removeFirst()
        remoteQueueLock.unlock()

        let scheduleNext = { [weak self] in
            self?.stateQueue.async { self?.scheduleNextRemoteBufferSimulator() }
        }
        if let b2 = buffer2 {
            player.scheduleBuffer(buffer1, completionHandler: nil)
            player.scheduleBuffer(b2) { scheduleNext() }
        } else {
            player.scheduleBuffer(buffer1) { scheduleNext() }
        }
        player.play()
    }
    #endif

    // MARK: - Device (AudioComponentInstance)

    #if !targetEnvironment(simulator)
    private func startEngineDevice() -> Error? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            return VoiceChatCallError.configurationFailed
        }

        var unit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(comp, &unit)
        guard status == noErr, let unit else {
            return VoiceChatCallError.configurationFailed
        }
        audioUnit = unit

        // Enable input (bus 1)
        var enable: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }

        // Get hardware format from input element input scope, use for our mic data.
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var inputASBD = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &inputASBD, &size)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }
        // Set our format on input element output scope (use hardware format for compatibility)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inputASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }
        inputAVFormat = AVAudioFormat(streamDescription: &inputASBD)

        // Get format on output element input scope (what we provide for playback)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var outputASBD = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputASBD, &size)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }
        playbackFormatLock.lock()
        _playbackFormat = AVAudioFormat(streamDescription: &outputASBD)
        playbackFormatLock.unlock()

        // Allocate input buffer for pulling mic data
        let channels = Int(inputASBD.mChannelsPerFrame)
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            list[i].mNumberChannels = 1
            list[i].mDataByteSize = 4096 * 4
            list[i].mData = UnsafeMutableRawPointer.allocate(byteCount: 4096 * 4, alignment: 16)
        }
        inputBufferList = list

        // Set INPUT callback - called when mic data is available (this is what delivers PCM!)
        var inputCallbackStruct = AURenderCallbackStruct(
            inputProc: Self.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            disposeInputBufferList()
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }

        // Set render callback (output - we provide audio to play)
        var callbackStruct = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            disposeInputBufferList()
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            disposeInputBufferList()
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            disposeInputBufferList()
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            return VoiceChatCallError.configurationFailed
        }

        transition(to: .active)
        return nil
    }

    private func disposeInputBufferList() {
        guard let list = inputBufferList else { return }
        let channels = Int(list.unsafePointer.pointee.mNumberBuffers)
        for i in 0..<channels {
            list[i].mData?.deallocate()
        }
        inputBufferList = nil
    }

    private func stopEngineDevice() {
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        disposeInputBufferList()
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        playbackFormatLock.lock()
        _playbackFormat = nil
        playbackFormatLock.unlock()
        remoteQueueLock.lock()
        remoteQueue.removeAll()
        remoteQueueLock.unlock()
        currentRemoteBuffer = nil
        nextRemoteBuffer = nil
    }

    private static let inputCallback: AURenderCallback = { refCon, _, inTimeStamp, _, inNumberFrames, _ in
        let `self` = Unmanaged<DefaultVoiceChatCall>.fromOpaque(refCon).takeUnretainedValue()
        self.performInputCallback(inTimeStamp: inTimeStamp, inNumberFrames: inNumberFrames)
        return noErr
    }

    private func performInputCallback(inTimeStamp: UnsafePointer<AudioTimeStamp>, inNumberFrames: UInt32) {
        guard let unit = audioUnit, let inputBuf = inputBufferList, let avFormat = inputAVFormat else { return }
        var ts = inTimeStamp.pointee
        let status = AudioUnitRender(unit, nil, &ts, 1, inNumberFrames, inputBuf.unsafeMutablePointer)
        guard status == noErr else { return }
        let frameCount = Int(inNumberFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: UInt32(frameCount)) else { return }
        buffer.frameLength = UInt32(frameCount)
        let channelCount = Int(avFormat.channelCount)
        for ch in 0..<channelCount where ch < inputBuf.unsafePointer.pointee.mNumberBuffers {
            if let src = inputBuf[ch].mData, let dst = buffer.floatChannelData?[ch] {
                memcpy(dst, src, frameCount * 4)
            }
        }
        localPcmSubject.send(buffer)
    }

    private static let renderCallback: AURenderCallback = { refCon, _, inTimeStamp, _, inNumberFrames, ioData in
        guard let ioData else { return noErr }
        let `self` = Unmanaged<DefaultVoiceChatCall>.fromOpaque(refCon).takeUnretainedValue()
        return self.performRender(inTimeStamp: inTimeStamp, inNumberFrames: inNumberFrames, ioData: ioData)
    }

    private func performRender(inTimeStamp: UnsafePointer<AudioTimeStamp>, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let _ = audioUnit else { return noErr }

        // Fill output with remote audio (non-interleaved: one buffer per channel)
        let ioList = UnsafeMutableAudioBufferListPointer(ioData)
        let numChannels = Int(ioList.unsafePointer.pointee.mNumberBuffers)
        let framesNeeded = Int(inNumberFrames)

        var frameOffset = 0
        while frameOffset < framesNeeded {
            if currentRemoteBuffer == nil || remoteBufferOffset >= Int(currentRemoteBuffer!.frameLength) {
                refillRemoteBuffers()
            }

            guard let buf = currentRemoteBuffer, let srcData = buf.floatChannelData?[0] else {
                for ch in 0..<numChannels {
                    if let dst = ioList[ch].mData {
                        memset(dst.advanced(by: frameOffset * 4), 0, (framesNeeded - frameOffset) * 4)
                    }
                }
                return noErr
            }

            let srcFrames = Int(buf.frameLength) - remoteBufferOffset
            let copyFrames = min(srcFrames, framesNeeded - frameOffset)
            let srcPtr = srcData.advanced(by: remoteBufferOffset)

            for ch in 0..<numChannels {
                if let dst = ioList[ch].mData {
                    let dstPtr = dst.advanced(by: frameOffset * 4).assumingMemoryBound(to: Float.self)
                    memcpy(dstPtr, srcPtr, copyFrames * 4)
                }
            }

            frameOffset += copyFrames
            remoteBufferOffset += copyFrames
            if remoteBufferOffset >= Int(buf.frameLength) {
                currentRemoteBuffer = nil
            }
        }

        return noErr
    }

    /// Double buffer prefetch: fetch up to 2 buffers (current + next) per lock.
    private func refillRemoteBuffers() {
        remoteQueueLock.lock()
        remoteBufferOffset = 0
        if let next = nextRemoteBuffer {
            currentRemoteBuffer = next
            nextRemoteBuffer = nil
        } else {
            currentRemoteBuffer = nil
        }
        if currentRemoteBuffer == nil, !remoteQueue.isEmpty {
            currentRemoteBuffer = remoteQueue.removeFirst()
        }
        if !remoteQueue.isEmpty {
            nextRemoteBuffer = remoteQueue.removeFirst()
        }
        remoteQueueLock.unlock()
    }
    #endif

    private func stopEngine() {
        remoteQueueLock.lock()
        remoteQueue.removeAll()
        remoteQueueLock.unlock()
        _playbackFormat = nil
        #if targetEnvironment(simulator)
        stopEngineSimulator()
        #else
        stopEngineDevice()
        #endif
    }

    private func handleInterrupt(_ event: VoiceInterruptEvent) {
        switch event {
        case .began:
            if state == .active {
                stopEngine()
                transition(to: .deviceSwitching)
            }
        case .ended(shouldResume: let resume):
            if resume, state == .deviceSwitching {
                _ = startEngine()
            } else if state == .deviceSwitching {
                transition(to: .idle)
                manager?.unregister(clientId: clientId)
            }
        }
    }

    private func handleDeviceSwitch(_ event: VoiceRouteChangeEvent) {
        guard state == .active else { return }
        guard shouldRestartForRouteChange(event.reason) else { return }

        transition(to: .deviceSwitching)
        stopEngine()

        stateQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.startEngine() == nil {
                // Engine resumed successfully.
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

    private func transition(to newState: VoiceChatCallState) {
        state = newState
    }
}
