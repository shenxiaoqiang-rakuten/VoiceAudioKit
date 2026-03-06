//
//  ContentView.swift
//  MasterAudio
//
//  Created by Shen, Xiaoqiang | CNTD on 2026/3/4.
//

import AVFoundation
import Combine
import VoiceAudioImplementation
import VoiceAudioProtocol
import SwiftUI
import UIKit

// MARK: - ContentView (Tab Container)

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordingView()
                .tabItem {
                    Label("录音", systemImage: "mic.fill")
                }
                .tag(0)

            ChatCallTestView()
                .tabItem {
                    Label("语音通话", systemImage: "phone.fill")
                }
                .tag(1)
        }
        .tint(Color(red: 0.25, green: 0.55, blue: 0.95))
    }
}

// MARK: - RecordingView

struct RecordingView: View {
    @StateObject private var viewModel = RecordDemoViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    stateCard
                    voiceProcessingToggle
                    recordControls
                    recordingStatusView
                    spectrumSection
                    vadSection
                    recordingFilesSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { viewModel.refreshRecordings() }
            .alert("错误", isPresented: $viewModel.showError) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .confirmationDialog("确定要删掉这条录音吗？", isPresented: $viewModel.showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { viewModel.confirmDeleteRecording() }
                Button("不删了", role: .cancel) { viewModel.cancelDelete() }
            } message: {
                Text("删了就找不回来了")
            }
            .sheet(isPresented: $viewModel.showShareSheet, onDismiss: { viewModel.shareURL = nil }) {
                if let url = viewModel.shareURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.3, green: 0.65, blue: 0.95),
                                 Color(red: 0.2, green: 0.5, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("录音")
                .font(.title2)
                .fontWeight(.bold)
            Text("录制并保存 PCM 音频")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if targetEnvironment(simulator)
            Text("模拟器：使用模拟音频")
                .font(.caption2)
                .foregroundStyle(.orange)
            #endif
        }
        .padding(.top, 12)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.stateText)
                    .font(.headline)
                    .fontWeight(.semibold)
                if case .error = viewModel.state {
                    Text(viewModel.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
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
        case .recording: return Color(red: 0.95, green: 0.3, blue: 0.25)
        case .stopped: return .orange
        case .deviceSwitching: return .yellow
        case .error: return .red
        }
    }

    private var voiceProcessingToggle: some View {
        HStack {
            Image(systemName: "waveform.badge.mic")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("语音处理 (AEC/降噪)")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            Toggle("", isOn: $viewModel.enableVoiceProcessing)
                .labelsHidden()
                .disabled(!viewModel.canToggleVoiceProcessing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
    }

    private var recordControls: some View {
        HStack(spacing: 16) {
            Button(action: { viewModel.start() }) {
                Label("开始录", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.95, green: 0.3, blue: 0.25))
            .disabled(!viewModel.canStart)

            Button(action: { viewModel.stop() }) {
                Label("停止", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canStop)
        }
    }

    @ViewBuilder
    private var recordingStatusView: some View {
        Group {
            if viewModel.filePluginRecording {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text("正在保存...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if viewModel.savedFileURL != nil {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(red: 0.2, green: 0.7, blue: 0.4))
                    Text("保存好了")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("声音")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Picker("", selection: $viewModel.spectrumMode) {
                    Text("条状").tag(PCMVisualizationMode.rmsWaveform)
                    Text("图形").tag(PCMVisualizationMode.fftSpectrum)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            SpectrumView(spectrum: viewModel.spectrum, color: Color(red: 0.25, green: 0.6, blue: 0.95))
                .frame(height: 120)
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

    @ViewBuilder
    private var recordingFilesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("我的录音")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { viewModel.refreshRecordings() }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
            }

            if viewModel.recordingFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("还没有录音")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("点上面「开始录」开始录制")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.recordingFiles.enumerated()), id: \.element.path) { index, url in
                        RecordingFileRow(
                            url: url,
                            displayName: viewModel.displayName(for: url, at: index),
                            isPlaying: viewModel.playingURL == url,
                            isPaused: viewModel.isPlaybackPaused,
                            progress: viewModel.playingURL == url ? viewModel.playbackProgress : nil,
                            durationCache: viewModel.durationCache,
                            onPlay: { viewModel.playRecording(url: url) },
                            onPause: { viewModel.pausePlayback() },
                            onResume: { viewModel.resumePlayback() },
                            onDelete: { viewModel.deleteRecording(url: url) },
                            onShare: { viewModel.shareRecording(url: url) }
                        )
                        if url != viewModel.recordingFiles.last {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                )
            }
        }
    }
}

// MARK: - Recording File Row

struct RecordingFileRow: View {
    let url: URL
    var displayName: String = ""
    var isPlaying: Bool = false
    var isPaused: Bool = false
    var progress: VoicePlaybackProgress? = nil
    var durationCache: [URL: TimeInterval] = [:]
    var onPlay: () -> Void = {}
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onDelete: () -> Void = {}
    var onShare: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying && !isPaused ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(isPlaying ? Color(red: 0.95, green: 0.3, blue: 0.25) : Color(red: 0.25, green: 0.55, blue: 0.95))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isPlaying {
                    Button(action: isPaused ? onResume : onPause) {
                        Image(systemName: isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.95))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName.isEmpty ? url.deletingPathExtension().lastPathComponent : displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(fileSizeString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !durationString.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(durationString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()

                HStack(spacing: 8) {
                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isPlaying, let progress, let duration = progress.duration, duration > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: 0.25, green: 0.55, blue: 0.95))
                                .frame(width: max(0, geo.size.width * min(1, progress.currentTime / duration)))
                        }
                    }
                    .frame(height: 4)
                    Text("\(formatTime(progress.currentTime)) / \(formatTime(duration))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private var durationString: String {
        if let cached = durationCache[url], cached.isFinite, cached >= 0 {
            let mins = Int(cached) / 60
            let secs = Int(cached) % 60
            return String(format: "%d:%02d", mins, secs)
        }
        guard let file = try? AVAudioFile(forReading: url) else { return "" }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ViewModel

/// Delay (seconds) before stopping file plugin after recorder stops. Allows final PCM buffers to flush.
private let filePluginStopDelay: TimeInterval = 0.25

@MainActor
final class RecordDemoViewModel: ObservableObject {
    @Published var state: VoiceRecorderState = .idle
    @Published var pcmCount = 0
    @Published var filePluginRecording = false
    @Published var savedFileURL: URL?
    @Published var recordingFiles: [URL] = []
    @Published var spectrum: [Float] = []
    @Published var spectrumMode: PCMVisualizationMode = .rmsWaveform
    @Published var playingURL: URL?
    @Published var isPlaybackPaused = false
    @Published var playbackProgress: VoicePlaybackProgress = VoicePlaybackProgress(currentTime: 0, duration: nil)
    @Published var durationCache: [URL: TimeInterval] = [:]
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var enableVoiceProcessing = true
    @Published var isSpeech = false

    private let recorder: DefaultVoiceRecorder = DefaultVoiceRecorder(configuration: .default)
    private let player: VoicePlayer = DefaultVoicePlayer()
    private let formatConverter = PCMFormatConverterPlugin(targetSampleRate: 16000, targetChannelCount: 1)
    private let filePlugin = PCMFilePlugin()
    private let visualizationPlugin = PCMVisualizationPlugin(barCount: 32)
    private let vadPlugin = PCMVADPlugin()
    private var cancellables = Set<AnyCancellable>()

    init() {
        visualizationPlugin.mode = .rmsWaveform
        recorder.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.state = newState
                if case .idle = newState {
                    self?.pcmCount = 0
                    self?.spectrum = []
                    self?.vadPlugin.reset()
                }
            }
            .store(in: &cancellables)

        recorder.pcmBufferPublisher
            .sink { [weak self] buffer in
                self?.formatConverter.write(buffer)
                self?.visualizationPlugin.write(buffer)
                self?.vadPlugin.write(buffer)
            }
            .store(in: &cancellables)

        formatConverter.convertedBufferPublisher
            .sink { [weak self] buffer in
                self?.filePlugin.write(buffer)
            }
            .store(in: &cancellables)

        vadPlugin.vadPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                self?.isSpeech = (result == .speech)
            }
            .store(in: &cancellables)

        player.pcmBufferPublisher
            .sink { [weak self] buffer in
                self?.visualizationPlugin.write(buffer)
            }
            .store(in: &cancellables)

        player.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playerState in
                switch playerState {
                case .playing:
                    self?.isPlaybackPaused = false
                case .paused:
                    self?.isPlaybackPaused = true
                case .idle, .stopped, .error:
                    self?.playingURL = nil
                    self?.isPlaybackPaused = false
                    self?.playbackProgress = VoicePlaybackProgress(currentTime: 0, duration: nil)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        player.progressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.playbackProgress = progress
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

        recorder.pcmBufferPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pcmCount += 1
            }
            .store(in: &cancellables)

        filePlugin.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pluginState in
                switch pluginState {
                case .recording:
                    self?.filePluginRecording = true
                case .stopped(let url):
                    self?.filePluginRecording = false
                    self?.savedFileURL = url
                    self?.refreshRecordings()
                    self?.invalidateDurationCache(for: url)
                case .idle, .error:
                    self?.filePluginRecording = false
                }
            }
            .store(in: &cancellables)

        refreshRecordings()
    }

    func refreshRecordings() {
        recordingFiles = recordingFileURLs()
        buildDurationCache()
    }

    func displayName(for url: URL, at index: Int) -> String {
        let n = index + 1
        return n == 1 ? "第1条（最新）" : "第\(n)条"
    }

    private func buildDurationCache() {
        var cache: [URL: TimeInterval] = [:]
        for url in recordingFiles {
            if let file = try? AVAudioFile(forReading: url) {
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                if seconds.isFinite, seconds >= 0 {
                    cache[url] = seconds
                }
            }
        }
        durationCache = cache
    }

    private func invalidateDurationCache(for url: URL) {
        if let file = try? AVAudioFile(forReading: url) {
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            if seconds.isFinite, seconds >= 0 {
                durationCache[url] = seconds
            }
        }
    }

    private func recordingFileURLs() -> [URL] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix("recording_") }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return date1 > date2
            }
    }

    var canStart: Bool {
        state == .idle || state == .stopped
    }

    var canToggleVoiceProcessing: Bool {
        state == .idle || state == .stopped
    }

    var canStop: Bool {
        state == .recording
    }

    var stateText: String {
        switch state {
        case .idle: return "可以录音了"
        case .recording: return "正在录"
        case .stopped: return "录完了"
        case .deviceSwitching: return "等一下..."
        case .error(let e): return userFriendlyError(e)
        }
    }

    private func userFriendlyError(_ e: VoiceRecorderError) -> String {
        switch e {
        case .permissionDenied: return "没开麦克风权限"
        case .chatCallActive: return "正在通话，先挂断"
        case .managerUnavailable, .configurationFailed: return "出错了，重试一下"
        case .busy, .invalidTransition: return "稍后再试"
        }
    }

    func start() {
        recorder.enableVoiceProcessing = enableVoiceProcessing
        Task {
            do {
                try await recorder.start()
                filePlugin.startRecording(to: PCMFilePlugin.defaultRecordingURL())
            } catch {
                errorMessage = userFriendlyError(from: error)
                showError = true
            }
        }
    }

    func stop() {
        recorder.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + filePluginStopDelay) { [weak self] in
            self?.filePlugin.stopRecording()
        }
    }

    func pausePlayback() {
        player.pause()
    }

    func resumePlayback() {
        player.resume()
    }

    func deleteRecording(url: URL) {
        pendingDeleteURL = url
        showDeleteConfirm = true
    }

    func confirmDeleteRecording() {
        guard let url = pendingDeleteURL else { return }
        if playingURL == url {
            player.stop()
            playingURL = nil
        }
        try? FileManager.default.removeItem(at: url)
        durationCache[url] = nil
        refreshRecordings()
        pendingDeleteURL = nil
        showDeleteConfirm = false
    }

    func cancelDelete() {
        pendingDeleteURL = nil
        showDeleteConfirm = false
    }

    @Published var pendingDeleteURL: URL?
    @Published var showDeleteConfirm = false

    func shareRecording(url: URL) {
        shareURL = url
        showShareSheet = true
    }

    @Published var shareURL: URL?
    @Published var showShareSheet = false

    func playRecording(url: URL) {
        if playingURL == url {
            player.stop()
            playingURL = nil
            return
        }
        player.stop()
        playingURL = url
        Task {
            do {
                try await player.play(url: url)
            } catch {
                playingURL = nil
                errorMessage = userFriendlyError(from: error)
                showError = true
            }
        }
    }

    private func userFriendlyError(from error: Error) -> String {
        if let e = error as? VoiceRecorderError {
            return userFriendlyError(e)
        }
        if let e = error as? VoicePlayerError {
            switch e {
            case .invalidURL, .fileLoadFailed: return "这个录音打不开"
            case .chatCallActive: return "正在通话，先挂断"
            case .busy: return "播放器正在使用中"
            default: return "出错了，重试一下"
            }
        }
        return "出错了，重试一下"
    }
}

#Preview {
    ContentView()
}
