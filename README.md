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
- If ChatCall is already active, new Recorder/Player starts are rejected with `.chatCallActive`.
- If ChatCall starts while Recorder/Player is running, a takeover event is emitted and default Recorder/Player implementations stop and return to `.idle`.
- Interruptions (phone call, alarm) and route changes (Bluetooth, headphone) are propagated; clients restart or reset as needed.

### Layering

```
┌─────────────────────────────────────────────────────────────────┐
│  App: Recorder/Player/ChatCall + Plugins (+ optional custom UI)  │
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
└── Package.swift
```

> Note: `SpectrumView`/`SpectrumShape` are in the `Example` app target, not in the SPM library products.

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
| **VoiceAudioImplementation** | Default implementations and PCM plugins. Depends on `VoiceAudioProtocol`. |

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

`SpectrumView` is provided in `Example/VoiceAudioExample` for demo usage. It is not exported by `VoiceAudioImplementation`.

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

- **ChatCall**: `stop()` is serialized onto the internal state queue; call it before releasing to ensure orderly teardown/unregister.
- **PCMFilePlugin**: Call `stopRecording()` before releasing; plugin teardown closes file resources on its internal queue.

### State Transition Tables

The tables below summarize key runtime transitions for the three default state machines.

#### Recorder (`DefaultVoiceRecorder`)

| Trigger | From | To | Notes |
|--------|------|----|------|
| `start()` success | `idle` | `recording` | Registers session with `.recordOnly` or `.recordAndPlayback` |
| `start()` failure | `idle` | `error(*)` | Includes permission denied, busy, chat call active |
| `stop()` | `recording` / `stopped` / `deviceSwitching` | `idle` | Stops engine, unregisters client |
| Interruption began | `recording` | `stopped` | Engine stops immediately |
| Interruption ended (`shouldResume = true`) | `stopped` | `recording` | Restarts engine without re-register |
| Interruption ended (`shouldResume = false`) | `stopped` | `idle` | Unregisters client |
| Route change (restart reasons) | `recording` | `deviceSwitching -> recording` or `idle` | Restart on `.newDeviceAvailable` / `.oldDeviceUnavailable` / `.wakeFromSleep` |
| Chat takeover event | `recording` / `stopped` / `deviceSwitching` | `idle` | ChatCall preempts recorder and forces unregister |

#### Player (`DefaultVoicePlayer`)

| Trigger | From | To | Notes |
|--------|------|----|------|
| `play()` / `play(url:)` success | `idle` / `stopped` | `playing` | Registers session with `.playbackOnly` |
| `play*` failure | `idle` / `stopped` | `error(*)` | Includes busy/chat call active/configuration failures |
| `pause()` | `playing` | `paused` | Keeps session active |
| `resume()` | `paused` | `playing` | Continues playback |
| `stop()` / playback completed | `playing` / `paused` / `stopped` / `deviceSwitching` | `idle` | Clears queue, unregisters client |
| Interruption began | `playing` | `stopped` | Pauses node/timer |
| Interruption ended (`shouldResume = true`) | `stopped` | `playing` | Resumes playback |
| Interruption ended (`shouldResume = false`) | `stopped` | `idle` | Performs full stop + unregister |
| Route change (restart reasons) | `playing` / `paused` | `deviceSwitching -> playing` or `idle` | Rebuilds engine and restarts queued playback |
| Chat takeover event | `playing` / `paused` / `stopped` / `deviceSwitching` | `idle` | ChatCall preempts player |
| Chat released event | `error(.chatCallActive)` | `idle` | Allows retry after ChatCall stops |

#### ChatCall (`DefaultVoiceChatCall`)

| Trigger | From | To | Notes |
|--------|------|----|------|
| `start()` success | `idle` | `active` | Registers `.chatCall`; can emit takeover event to Recorder/Player |
| `start()` failure | `idle` | `error(*)` | Includes permission denied and busy |
| `stop()` | `active` / `deviceSwitching` / `error` | `idle` | Stops engine and unregisters client |
| Interruption began | `active` | `deviceSwitching` | Engine stops and waits for ended event |
| Interruption ended (`shouldResume = true`) | `deviceSwitching` | `active` | Restarts engine |
| Interruption ended (`shouldResume = false`) | `deviceSwitching` | `idle` | Unregisters client |
| Route change (restart reasons) | `active` | `deviceSwitching -> active` or `idle` | Restarts call pipeline after device switch |

### Testing

`DefaultVoiceSessionManager` can be injected for testing:

```swift
let manager = DefaultVoiceSessionManager()
let recorder = DefaultVoiceRecorder(manager: manager)
let player = DefaultVoicePlayer(manager: manager)
```

## License

See the project license file.
