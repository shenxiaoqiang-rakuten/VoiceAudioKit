//
//  PCMFilePlugin.swift
//  MasterAudioKit
//
//  Plugin to save PCM buffers to audio file. Only receives PCM data, no recorder dependency.
//

import AVFoundation
import Combine
import Foundation

/// Plugin that saves PCM buffers to an audio file. Receives PCM via `write(buffer:)` only.
public final class PCMFilePlugin {

    /// Whether currently recording to file
    public var isRecording: Bool { _isRecording }

    /// Publisher for recording state changes
    public var statePublisher: AnyPublisher<State, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// Initialize. PCM is received via `write(buffer:)` - connect any PCM source to it.
    public init() {
        queue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
    }

    /// Write PCM buffer. Only writes when recording has been started. Thread-safe.
    public func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.writeInternal(buffer)
        }
    }

    /// Start recording to the given URL. Creates file on first buffer.
    public func startRecording(to url: URL) {
        syncOnQueue {
            guard !_isRecording else { return }
            outputURL = url
            _isRecording = true
            stateSubject.send(.recording(url))
        }
    }

    /// Stop recording and close the file.
    /// Call before releasing the plugin to ensure the file is closed cleanly.
    public func stopRecording() {
        syncOnQueue {
            let wasRecording = _isRecording
            _isRecording = false
            closeFile()
            if wasRecording, let url = outputURL {
                stateSubject.send(.stopped(url))
            }
            outputURL = nil
        }
    }

    /// Create a unique recording URL in Documents directory. Each call returns a different file path.
    public static func defaultRecordingURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let uniqueId = UUID().uuidString.prefix(8)
        let name = "recording_\(timestamp)_\(uniqueId).caf"
        return documents.appendingPathComponent(name)
    }

    deinit {
        syncOnQueue {
            _isRecording = false
            closeFile()
            outputURL = nil
        }
    }

    // MARK: - State

    public enum State {
        case idle
        case recording(URL)
        case stopped(URL)
        case error(Error)
    }

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.masteraudio.pcmfileplugin", qos: .userInitiated)
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private let queueSpecificValue: UInt8 = 1
    private var _isRecording = false
    private var outputURL: URL?
    private var audioFile: AVAudioFile?
    private let stateSubject = PassthroughSubject<State, Never>()

    private func writeInternal(_ buffer: AVAudioPCMBuffer) {
        guard _isRecording, let url = outputURL else { return }

        do {
            if audioFile == nil {
                let format = buffer.format
                let settings = settingsFromFormat(format)
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            }
            if let file = audioFile {
                try file.write(from: buffer)
            }
        } catch {
            _isRecording = false
            closeFile()
            outputURL = nil
            stateSubject.send(.error(error))
        }
    }

    private func settingsFromFormat(_ format: AVAudioFormat) -> [String: Any] {
        let isFloat = format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: isFloat ? 32 : 16,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
    }

    private func closeFile() {
        audioFile = nil
    }

    private func syncOnQueue(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue {
            block()
        } else {
            queue.sync(execute: block)
        }
    }
}
