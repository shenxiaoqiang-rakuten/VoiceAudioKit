//
//  ChatCallTestView.swift
//  MasterAudio
//
//  Test UI for VoiceChatCall (voice call with AEC).
//

@preconcurrency import AVFoundation
import Combine
import VoiceAudioImplementation
@preconcurrency import VoiceAudioProtocol
import SwiftUI

// MARK: - ChatCallViewModel

@MainActor
final class ChatCallViewModel: ObservableObject {
    @Published var state: VoiceChatCallState = .idle
    @Published var spectrum: [Float] = []
    @Published var spectrumMode: PCMVisualizationMode = .rmsWaveform
    @Published var isSimulatingRemote = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var isSpeech = false

    private let chatCall: VoiceChatCall = DefaultVoiceChatCall(configuration: .default)
    private let visualizationPlugin = PCMVisualizationPlugin(barCount: 32)
    private let vadPlugin = PCMVADPlugin()
    private var cancellables = Set<AnyCancellable>()
    private var simulateCacheSubscription: AnyCancellable?
    private var simulatePlayTimer: DispatchSourceTimer?
    /// 延迟队列：(buffer, 播放时间)，本地麦克风 → 1 秒后播放
    private var delayedQueue: [(AVAudioPCMBuffer, Date)] = []

    init() {
        visualizationPlugin.mode = .rmsWaveform

        chatCall.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.state = newState
                if case .idle = newState { self?.stopSimulateRemote() }
                else if case .error = newState { self?.stopSimulateRemote() }
            }
            .store(in: &cancellables)

        chatCall.localPcmPublisher
            .sink { [weak self] buffer in
                self?.visualizationPlugin.write(buffer)
                self?.vadPlugin.write(buffer)
            }
            .store(in: &cancellables)

        vadPlugin.vadPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                self?.isSpeech = (result == .speech)
            }
            .store(in: &cancellables)

        visualizationPlugin.spectrumPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSpectrum in
                self?.spectrum = newSpectrum
            }
            .store(in: &cancellables)

        $spectrumMode
            .dropFirst()
            .sink { [weak self] mode in
                self?.visualizationPlugin.mode = mode
            }
            .store(in: &cancellables)
    }

    var canStart: Bool {
        state == .idle || (state.isError)
    }

    var canStop: Bool {
        state == .active || state == .deviceSwitching
    }

    var stateText: String {
        switch state {
        case .idle: return "待机"
        case .active: return "通话中"
        case .deviceSwitching: return "设备切换中..."
        case .error(let e): return userFriendlyError(e)
        }
    }

    private func userFriendlyError(_ e: VoiceChatCallError) -> String {
        switch e {
        case .permissionDenied: return "麦克风权限未开启"
        case .managerUnavailable, .configurationFailed: return "配置失败，请重试"
        case .busy: return "系统繁忙，请稍后再试"
        }
    }

    func start() {
        if case .error = state {
            chatCall.stop()
        }
        vadPlugin.reset()
        Task {
            do {
                try await chatCall.start()
            } catch let e as VoiceChatCallError {
                errorMessage = userFriendlyError(e)
                showError = true
            } catch {
                errorMessage = "启动失败"
                showError = true
            }
        }
    }

    func stop() {
        stopSimulateRemote()
        chatCall.stop()
    }

    func toggleSimulateRemote() {
        if isSimulatingRemote {
            stopSimulateRemote()
        } else {
            startSimulateRemote()
        }
    }

    private func startSimulateRemote() {
        guard case .active = state else { return }
        guard chatCall.playbackFormat != nil else { return }

        isSimulatingRemote = true
        delayedQueue = []

        // 本地麦克风 → 入队，1 秒后播放
        simulateCacheSubscription = chatCall.localPcmPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffer in
                guard let self, self.isSimulatingRemote else { return }
                if let copy = copyPCMBuffer(buffer) {
                    self.delayedQueue.append((copy, Date().addingTimeInterval(1.0)))
                }
            }

        // 定时检查：到点的 buffer 写入远端播放
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            self?.flushDelayedBuffers()
        }
        timer.resume()
        simulatePlayTimer = timer
    }

    private func flushDelayedBuffers() {
        guard isSimulatingRemote else { return }
        let now = Date()
        while let first = delayedQueue.first, first.1 <= now {
            let (buffer, _) = delayedQueue.removeFirst()
            if let target = convertToPlaybackFormat(buffer) {
                chatCall.write(target)
            }
        }
    }

    private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            let chCount = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            for ch in 0..<chCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        }
        return copy
    }

    private func convertToPlaybackFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = chatCall.playbackFormat else { return nil }
        let srMatch = abs(buffer.format.sampleRate - targetFormat.sampleRate) < 1
        if srMatch && buffer.format.channelCount == targetFormat.channelCount {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(targetFrames, 4096)) else { return nil }

        var bufferUsed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if bufferUsed {
                outStatus.pointee = .noDataNow
                return nil
            }
            bufferUsed = true
            outStatus.pointee = .haveData
            return buffer
        }
        var error: NSError?
        _ = converter.convert(to: target, error: &error, withInputFrom: inputBlock)
        guard error == nil, target.frameLength > 0 else { return nil }
        return target
    }

    private func stopSimulateRemote() {
        simulateCacheSubscription?.cancel()
        simulateCacheSubscription = nil
        simulatePlayTimer?.cancel()
        simulatePlayTimer = nil
        delayedQueue = []
        isSimulatingRemote = false
    }

    deinit {
        simulatePlayTimer?.cancel()
        let call = chatCall
        DispatchQueue.main.async { call.stop() }
    }
}

extension VoiceChatCallState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - ChatCallTestView

struct ChatCallTestView: View {
    @StateObject private var viewModel = ChatCallViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                headerSection
                stateCard
                controlsSection
                spectrumSection
                vadSection
                simulateRemoteSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 6) {
            Image(systemName: "phone.badge.waveform.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.4, green: 0.6, blue: 1),
                                 Color(red: 0.2, green: 0.5, blue: 0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("语音通话")
                .font(.title2)
                .fontWeight(.bold)
            Text("测试 VoiceProcessingIO + AEC")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if targetEnvironment(simulator)
            Text("模拟器：使用模拟音频")
                .font(.caption2)
                .foregroundStyle(.orange)
            #endif
        }
        .padding(.top, 8)
    }

    private var stateCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(stateColor)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle()
                        .stroke(stateColor.opacity(0.5), lineWidth: 2)
                )
            Text(viewModel.stateText)
                .font(.headline)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        )
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .idle: return .gray
        case .active: return Color(red: 0.2, green: 0.7, blue: 0.4)
        case .deviceSwitching: return .orange
        case .error: return .red
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 16) {
            Button(action: { viewModel.start() }) {
                Label("开始通话", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.2, green: 0.6, blue: 0.95))
            .disabled(!viewModel.canStart)

            Button(action: { viewModel.stop() }) {
                Label("挂断", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canStop)
        }
    }

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本地麦克风")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Picker("", selection: $viewModel.spectrumMode) {
                    Text("波形").tag(PCMVisualizationMode.rmsWaveform)
                    Text("频谱").tag(PCMVisualizationMode.fftSpectrum)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            SpectrumView(
                spectrum: viewModel.spectrum,
                color: Color(red: 0.25, green: 0.55, blue: 0.95)
            )
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
            )
        }
    }

    private var vadSection: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(viewModel.isSpeech ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 12, height: 12)
            Text(viewModel.isSpeech ? "语音" : "静音")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(viewModel.isSpeech ? .primary : .secondary)
            Spacer()
            Text("VAD")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        )
    }

    private var simulateRemoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("测试远端音频")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("本地麦克风实时延迟 1 秒播放，用于测试 write() 播放")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: { viewModel.toggleSimulateRemote() }) {
                HStack {
                    Image(systemName: viewModel.isSimulatingRemote ? "speaker.wave.3.fill" : "speaker.wave.2")
                        .font(.title3)
                    Text(viewModel.isSimulatingRemote ? "停止模拟" : "播放模拟音")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isSimulatingRemote ? .orange : Color(red: 0.3, green: 0.5, blue: 0.8))
            .disabled(!viewModel.canStop)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        )
    }
}

#Preview {
    ChatCallTestView()
}
