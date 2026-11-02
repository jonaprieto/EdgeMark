import ActivityKit
import AVFoundation
import Speech
import SwiftUI

enum VoiceLanguage: String, CaseIterable {
    case es, en

    /// Candidates in order: the transcriber offers a fixed list of regions.
    var locales: [Locale] {
        switch self {
        case .es: ["es-CO", "es-MX", "es-US", "es-ES"].map(Locale.init(identifier:))
        case .en: ["en-US", "en-GB"].map(Locale.init(identifier:))
        }
    }
}

/// Live speech to text with Apple's on-device transcriber. No audio is kept. Where the
/// transcriber is refused, `problem` says so and the keyboard's mic still works.
@MainActor @Observable
final class Dictation {
    private struct Refused: Error {
        let reason: String
    }

    private(set) var isListening = false
    private(set) var isPreparing = false
    /// Everything heard so far in this take, the part still being revised included.
    private(set) var text = ""
    private(set) var problem: String?
    /// Finished phrases also go to the draft, for a take iOS might end before it is saved.
    var keepsDraft: Bool

    private var settled = ""
    /// What the draft held when this take began.
    private var kept = ""
    private let engine = AVAudioEngine()
    private var format: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// In Caches, out of backups like the notes. The notes stay sealed while the phone is locked and
    /// a take does not, so this file is readable after the first unlock.
    private static let draft = URL.cachesDirectory.appendingPathComponent("dictation-draft.txt")

    /// A take that never reached a note.
    static var unsaved: String? {
        try? String(contentsOf: draft, encoding: .utf8)
    }

    init(keepsDraft: Bool = false) {
        self.keepsDraft = keepsDraft
    }

    /// A sheet can close mid take.
    isolated deinit {
        guard isListening else { return }
        turnOff()
        Task { await Self.endActivities() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discardDraft() {
        keepsDraft = false
        try? FileManager.default.removeItem(at: Self.draft)
    }

    /// A take iOS killed leaves its activity behind, so launching clears it too.
    static func endActivities() async {
        for activity in Activity<DictationActivity>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func start(_ language: VoiceLanguage) async {
        guard !isListening, !isPreparing else { return }
        problem = nil
        text = ""
        settled = ""
        kept = keepsDraft ? Self.unsaved ?? "" : ""
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await listen(language)
        } catch let refused as Refused {
            problem = refused.reason
        } catch {
            problem = error.localizedDescription
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func listen(_ language: VoiceLanguage) async throws {
        guard SpeechTranscriber.isAvailable else { throw Refused(reason: "Speech is not available here; use the keyboard's mic") }
        guard await AVAudioApplication.requestRecordPermission() else { throw Refused(reason: "Microphone access is off") }
        var locale: Locale?
        for candidate in language.locales where locale == nil {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate)
        }
        guard let locale else { throw Refused(reason: "No speech model for this language; use the keyboard's mic") }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Refused(reason: "No audio format for speech")
        }
        let session = AVAudioSession.sharedInstance()
        // The category and mode Apple asks of voice in CarPlay.
        try session.setCategory(.playAndRecord, mode: .default, options: .allowBluetoothHFP)
        try session.setActive(true)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try Self.feed(engine, into: input, as: format)
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.input = input
        self.format = format
        isListening = true
        watchRoute()
        StopDictationIntent.stop = { [weak self] in await self?.stop() }
        _ = try? Activity.request(attributes: DictationActivity(started: Date()), content: .init(state: .init(), staleDate: nil))
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    private func receive(_ words: String, isFinal: Bool) {
        if isFinal {
            settled += words
            text = settled
            if keepsDraft {
                let whole = kept.isEmpty ? settled : kept + " " + settled
                try? Data(whole.utf8).write(to: Self.draft, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } else {
            text = settled + words
        }
    }

    private func watchRoute() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.ended.rawValue else { return }
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
    }

    /// A new route stops the engine, as when the car connects mid take, and so does an interruption.
    /// The take carries on if iOS lets it, which it may not on a locked phone.
    private func resume() {
        guard isListening, let input, let format else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try Self.feed(engine, into: input, as: format)
            engine.prepare()
            try engine.start()
        } catch {
            problem = "Listening stopped; what you said so far is still here"
            Task { await stop() }
        }
    }

    private func turnOff() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func stop() async {
        guard isListening else { return }
        isListening = false
        turnOff()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        await results?.value
        results = nil
        await Self.endActivities()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Runs on the audio thread, so nothing here may touch the main actor.
    private nonisolated static func feed(_ engine: AVAudioEngine, into input: AsyncStream<AnalyzerInput>.Continuation, as format: AVAudioFormat) throws {
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        // A route in the middle of changing reports no rate, and a tap on that would crash.
        guard natural.sampleRate > 0, let converter = AVAudioConverter(from: natural, to: format) else { throw Refused(reason: "No audio converter for speech") }
        node.installTap(onBus: 0, bufferSize: 4096, format: natural) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / natural.sampleRate) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var handed = false
            var failure: NSError?
            converter.convert(to: converted, error: &failure) { _, status in
                if handed {
                    status.pointee = .noDataNow
                    return nil
                }
                handed = true
                status.pointee = .haveData
                return buffer
            }
            if failure == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }
}

/// Mic and language toggle for any text field. Speech lands after what is already typed.
struct MicButton: View {
    let dictation: Dictation
    @Binding var text: String
    /// Opens listening, for a widget's voice button.
    var startsListening = false

    @AppStorage("voice.language") private var language = VoiceLanguage.es
    @State private var typed = ""

    var body: some View {
        HStack {
            Button(language.rawValue.uppercased()) {
                language = language == .es ? .en : .es
            }
            .disabled(dictation.isListening)
            .buttonStyle(.borderless)
            Button(dictation.isListening ? "Stop" : "Dictate", systemImage: dictation.isListening ? "stop.circle" : "mic") {
                Task { await toggle() }
            }
            .disabled(dictation.isPreparing)
            // In a Form row, a tap would otherwise fire both buttons.
            .buttonStyle(.borderless)
        }
        .onChange(of: dictation.text) { _, heard in
            text = typed.isEmpty || heard.isEmpty ? typed + heard : typed + " " + heard
        }
        .task {
            if startsListening { await listen() }
        }
    }

    private func toggle() async {
        if dictation.isListening {
            await dictation.stop()
        } else {
            await listen()
        }
    }

    private func listen() async {
        typed = text
        await dictation.start(language)
    }
}
