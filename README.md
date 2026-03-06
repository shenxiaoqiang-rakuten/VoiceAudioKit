# VoiceAudioKit

A Swift Package for iOS audio recording, playback, and voice call with AEC (Acoustic Echo Cancellation). Provides protocol-based abstractions and default implementations built on AVFoundation and AudioUnit.

## Architecture

VoiceAudioKit follows a **protocol-first, stream-based** design:

### Protocol-First Abstraction

- **VoiceRecorder**, **VoicePlayer**, **VoiceChatCall** are protocols; **DefaultVoiceRecorder**, **DefaultVoicePlayer**, **DefaultVoiceChatCall** are default implementations.
- Depend on protocols to allow custom backends, mocking, and testing.
- **VoiceSessionManager** centralizes `AVAudioSession` lifecycle (permission, interruption, route change) and enforces single-client-per-type.

### PCM Streams via Combine

- All audio data flows as `AVAudioPCMBuffer` through Combine publishers (`pcmBufferPublisher`, `localPcmPublisher`).
- Reactive, composable: use `.sink`, `.map`, `.buffer` for backpressure and chaining.
- No encoding in core—PCM is the universal format; format conversion is a plugin.

### Plugin Pattern

- Plugins are stateless processors: `write(buffer)` in, publisher out.
- No dependency on Recorder/Player—any PCM source can feed a plugin.
- Chainable: Recorder → FormatConverter → FilePlugin, or Recorder → VAD + Visualization in parallel.

### Session Coordination

- Only one active client per type (Recorder, Player, or ChatCall).
- ChatCall takes over when started; Recorder/Player transition to `.error(.chatCallActive)`.
- Interruptions (phone call, alarm) and route changes (Bluetooth, headphone) are propagated; clients restart or reset as needed.

### Layering

```
┌─────────────────────────────────────────────────────────────────┐
│  App: Recorder/Player/ChatCall + Plugins + UI                    │
├─────────────────────────────────────────────────────────────────┤
│  VoiceAudioProtocol: VoiceRecorder, VoicePlayer, VoiceChatCall   │
│  VoiceSessionManager (session lifecycle)                         │
├─────────────────────────────────────────────────────────────────┤
│  VoiceAudioImplementation: DefaultVoice*, PCM*Plugin              │
├─────────────────────────────────────────────────────────────────┤
│  AVFoundation (AVAudioEngine, AVAudioFile) / AudioUnit            │
└─────────────────────────────────────────────────────────────────┘
```

## Requirements

- iOS 17.0+
- Swift 5.9+
- Xcode 15.0+

## Installation

### Swift Package Manager

Add VoiceAudioKit to your project:

1. In Xcode: **File → Add Package Dependencies**
2. For local development: Click **Add Local** and select the `VoiceAudioKit` folder
3. For remote: Enter the package URL (when published)
4. Add `VoiceAudioImplementation` and optionally `VoiceAudioProtocol` to your target

```swift
// In Package.swift
dependencies: [
    .package(path: "../VoiceAudioKit")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "VoiceAudioImplementation", package: "VoiceAudioKit"),
            .product(name: "VoiceAudioProtocol", package: "VoiceAudioKit")
        ]
    )
]
```

## Package Structure

```
VoiceAudioKit/
├── Sources/
│   ├── VoiceAudioProtocol/     # Protocol definitions and shared types
│   │   ├── VoiceTypes.swift
│   │   ├── VoiceSessionManager.swift
│   │   ├── VoicePlayer.swift
│   │   ├── VoiceRecorder.swift
│   │   └── VoiceChatCall.swift
│   └── VoiceAudioImplementation/
│       ├── Core/                # Default implementations
│       │   ├── DefaultVoiceSessionManager.swift
│       │   ├── DefaultVoicePlayer.swift
│       │   ├── DefaultVoiceRecorder.swift
│       │   └── DefaultVoiceChatCall.swift
│       ├── Plugins/             # PCM processing plugins
│       │   ├── PCMVADPlugin.swift
│       │   ├── PCMVisualizationPlugin.swift
│       │   └── PCMFilePlugin.swift
│       └── UI/                  # SwiftUI visualization components
│           ├── SpectrumView.swift
│           └── SpectrumShape.swift
└── Package.swift
```

## Data Flow

### Recorder → Plugin → Output

```
                         pcmBufferPublisher
┌─────────────┐
│   Recorder  │     .sink { converter.write($0) }     ┌──────────────────┐
│ (mic input) │ ───────────────────────────────────► │ FormatConverter   │
└─────────────┘                                      │ (optional)        │
       │                                             └────────┬──────────┘
       │                                                      │ convertedBufferPublisher
       │                                                      ▼
       │                                             ┌──────────────────┐
       │                                             │ PCMFilePlugin     │
       │                                             └──────────────────┘
       │
       │     .sink { vadPlugin.write($0) }           ┌──────────────────┐
       └───────────────────────────────────────────► │ PCMVADPlugin      │
       │                                             └──────────────────┘
       │     .sink { vizPlugin.write($0) }           ┌──────────────────┐
       └───────────────────────────────────────────► │ PCMVisualization  │
                                                    └──────────────────┘
```

Recorder outputs native-format PCM. Use FormatConverter when output needs fixed sample rate (e.g. file). Plugins subscribe in parallel.

### Player → Plugin

```
┌─────────────┐     pcmBufferPublisher      ┌──────────────────────┐
│   Player    │ ─────────────────────────► │ PCMVisualizationPlugin│ ──► spectrumPublisher
│ (file/PCM)  │     .sink { write($0) }     │ PCMVADPlugin          │ ──► vadPublisher
└─────────────┘                             └──────────────────────┘
```

Player emits currently-playing PCM via `pcmBufferPublisher`; connect to visualization, VAD, or other plugins.

### Voice Call (AEC)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         VoiceChatCall (AEC)                              │
│  ┌─────────────┐                    ┌─────────────────┐                 │
│  │  Mic Input  │ ──► VoiceProcessingIO ──► localPcmPublisher ──► Local PCM│
│  └─────────────┘                    └─────────────────┘                 │
│                                            ▲                            │
│  ┌─────────────┐                    ┌─────┴─────┐                      │
│  │ Remote PCM  │ ◄── write(buffer) ──│  Speaker  │ ◄── Remote audio in   │
│  └─────────────┘                    └───────────┘                      │
└─────────────────────────────────────────────────────────────────────────┘
```

ChatCall uses VoiceProcessingIO for echo cancellation; `localPcmPublisher` emits local mic PCM (AEC applied); `write()` feeds remote audio for playback.

## Products

| Product | Description |
|---------|-------------|
| **VoiceAudioProtocol** | Protocol definitions (`VoiceSessionManager`, `VoicePlayer`, `VoiceRecorder`, `VoiceChatCall`) and shared types (`VoiceClientId`, `VoiceSessionRequirement`, errors, states). Use when you need to implement custom backends. |
| **VoiceAudioImplementation** | Default implementations, PCM plugins, and SwiftUI views. Depends on `VoiceAudioProtocol`. |

## Usage

### Recording

```swift
import VoiceAudioImplementation
import VoiceAudioProtocol

let recorder = DefaultVoiceRecorder(configuration: .default)
try await recorder.start()

recorder.pcmBufferPublisher
    .sink { buffer in
        // Process PCM data
    }
    .store(in: &cancellables)

recorder.stop()
```

### Playback

```swift
let player = DefaultVoicePlayer()
try await player.play(url: fileURL)

// Or PCM stream
player.write(pcmBuffer)
try await player.play()
```

### Voice Call (AEC)

```swift
let chatCall = DefaultVoiceChatCall(configuration: .default)
try await chatCall.start()

// Local mic PCM (AEC applied)
chatCall.localPcmPublisher.sink { buffer in ... }.store(in: &cancellables)

// Remote audio playback
chatCall.write(remotePcmBuffer)
```

### PCM Plugins

- **PCMFormatConverterPlugin**: Converts PCM from native format to target sample rate/channels (e.g. 48kHz → 16kHz)

```swift
// Recorder outputs native format; convert to 16kHz for voice recognition
let converter = PCMFormatConverterPlugin(targetSampleRate: 16000, targetChannelCount: 1)
recorder.pcmBufferPublisher
    .sink { converter.write($0) }
    .store(in: &cancellables)
converter.convertedBufferPublisher
    .sink { buffer in /* 16kHz mono PCM */ }
    .store(in: &cancellables)
```
- **PCMVADPlugin**: Voice activity detection (speech/silence) using RMS and adaptive threshold
- **PCMVisualizationPlugin**: Converts PCM to bar values (RMS waveform or FFT spectrum)
- **PCMFilePlugin**: Saves PCM buffers to `.caf` files

### SwiftUI Spectrum View

```swift
import VoiceAudioImplementation

SpectrumView(spectrum: magnitudes, color: .orange)
    .frame(height: 120)
```

## Simulator Support

On the iOS Simulator, `DefaultVoiceRecorder`, `DefaultVoicePlayer`, and `DefaultVoiceChatCall` use synthetic audio instead of hardware. This allows development and UI testing without a physical device.

## Concurrency and Lifecycle

### Concurrency Limits

Only one active client per type at a time:

- **Recorder**: One `DefaultVoiceRecorder` (recordOnly or recordAndPlayback) can be active.
- **Player**: One `DefaultVoicePlayer` (playbackOnly) can be active.
- **ChatCall**: One `DefaultVoiceChatCall` can be active.

Starting a second client of the same type returns `VoiceSessionError.busy` or the corresponding `VoiceRecorderError`/`VoicePlayerError`/`VoiceChatCallError`.

### PCM Subscribers

`pcmBufferPublisher` and `localPcmPublisher` deliver buffers on a background queue. Subscribers should avoid heavy work in the callback; offload to another queue if needed.

### Lifecycle

- **ChatCall**: Call `stop()` before releasing. `deinit` performs a synchronous stop; ensure no other references prevent deallocation.
- **PCMFilePlugin**: Call `stopRecording()` before releasing to ensure the file is closed cleanly.

### Testing

`DefaultVoiceSessionManager` can be injected for testing:

```swift
let manager = DefaultVoiceSessionManager()
let recorder = DefaultVoiceRecorder(manager: manager)
let player = DefaultVoicePlayer(manager: manager)
```

## License

See the project license file.
