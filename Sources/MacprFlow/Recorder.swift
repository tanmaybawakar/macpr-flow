import AVFoundation
import AudioToolbox
import CoreAudio
import Speech

/// Microphone + on-device transcription, kept warm between dictations.
///
/// Speed comes from three things the old capture path rebuilt every time:
/// the audio engine is created once, the speech model is retained for the process lifetime,
/// and the next analyzer is prepared while you are idle, so pressing the shortcut only starts audio.
@MainActor
final class Recorder {
    /// Fast voice level for the orb, fed straight from the audio I/O cycle rather than the transcription tap.
    let signal = VoiceSignal()
    var microphone = AudioDevices.automatic
    var vocabulary: [String] = [] {
        didSet { if vocabulary != oldValue { prepared = nil } }
    }
    var onFailure: ((String) -> Void)?
    private(set) var lastFrameCount: UInt64 = 0
    private(set) var locale: Locale?

    private var engine = AVAudioEngine()
    /// The device this engine was built for; nil means it follows the system default input.
    private var engineDevice: AudioDeviceID?
    private var engineBuilt = false
    private var format: AVAudioFormat?
    private var prepared: Prepared?
    private var warming: Task<Void, Error>?
    private var live: Live?
    private var tapInstalled = false
    private var sink: AVAudioSinkNode?
    private var observer: NSObjectProtocol?

    var isLive: Bool { live != nil }
    var partialText: String { live?.text ?? "" }

    init() {}

    /// A device switch on a live engine is unreliable, so a different mic gets a fresh engine. Building one takes milliseconds.
    private func prepareEngine() {
        let wanted = AudioDevices.explicitDevice(for: microphone)
        guard !engineBuilt || wanted != engineDevice else { return }
        if engineBuilt {
            stopEngine()
            if let sink { engine.detach(sink) }
            sink = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            engine = AVAudioEngine()
        }
        engineBuilt = true
        engineDevice = wanted
        if let wanted {
            do { try engine.inputNode.auAudioUnit.setDeviceID(wanted) }
            catch { engineDevice = nil }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }
    }

    // MARK: Assets

    static func englishLocale() async throws -> Locale {
        let preferred = Locale.current.language.languageCode?.identifier == "en" ? Locale.current : Locale(identifier: "en_US")
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) { return supported }
        guard let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
            throw FlowError("Apple's on-device English transcriber isn't available on this Mac.")
        }
        return fallback
    }

    func installAssets(progress: @escaping @MainActor (Double?) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw FlowError("Apple's speech transcriber isn't available on this Mac.") }
        let locale = try await Self.englishLocale()
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { ticker.cancel() }
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        self.locale = locale
        progress(nil)
    }

    // MARK: Warm-up

    /// Prepares the next analyzer ahead of time. Safe to call repeatedly.
    func warm() async throws {
        if prepared != nil { return }
        if let warming { return try await warming.value }
        let task = Task { @MainActor in try await self.makePrepared() }
        warming = task
        defer { warming = nil }
        try await task.value
    }

    private func makePrepared() async throws {
        guard let locale else { throw FlowError("The English speech model isn't ready yet.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if format == nil { format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) }
        guard let format else { throw FlowError("The speech model has no compatible audio format.") }
        try await analyzer.prepareToAnalyze(in: format)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        prepared = Prepared(transcriber: transcriber, analyzer: analyzer)
    }

    // MARK: Session

    func start() async throws {
        guard live == nil else { return }
        if format == nil { try await warm() }
        guard let format else { throw FlowError("The speech model isn't ready yet.") }

        // Audio starts first and buffers, so the first word is captured even if the analyzer needs a moment.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let session = Live(continuation: continuation)
        live = session
        signal.reset()
        do { try startAudio(for: session, format: format) } catch {
            live = nil; continuation.finish(); throw error
        }
        do { try await warm() } catch {
            await cancel(); throw error
        }
        guard live === session, let ready = prepared else { return }
        prepared = nil
        session.analyzer = ready.analyzer
        session.resultTask = Task { @MainActor [weak session] in
            for try await result in ready.transcriber.results {
                session?.accept(String(result.text.characters), final: result.isFinal)
            }
        }
        session.analysisTask = Task { try await ready.analyzer.start(inputSequence: stream) }
    }

    func finish() async throws -> String {
        guard let session = live else { return "" }
        stopEngine()
        session.input?.close()
        lastFrameCount = session.input?.frames ?? 0
        session.continuation.finish()
        defer { if live === session { live = nil } }
        if let analyzer = session.analyzer {
            try await session.analysisTask?.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await session.resultTask?.value
        }
        return session.text
    }

    func cancel() async {
        guard let session = live else { return }
        live = nil
        stopEngine()
        session.input?.close()
        session.continuation.finish()
        session.resultTask?.cancel(); session.analysisTask?.cancel()
        await session.analyzer?.cancelAndFinishNow()
    }

    // MARK: Audio

    private func startAudio(for session: Live, format: AVAudioFormat) throws {
        stopEngine()
        prepareEngine()
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else {
            throw FlowError("No microphone is available. Check Sound settings.")
        }
        let input = try AudioInput(from: natural, to: format, continuation: session.continuation) { [weak self] message in
            Task { @MainActor in self?.onFailure?(message) }
        }
        session.input = input
        node.installTap(onBus: 0, bufferSize: 1024, format: natural) { @Sendable buffer, _ in input.append(buffer) }
        tapInstalled = true
        attachSink(format: natural)
        engine.prepare()
        try engine.start()
    }

    /// The transcription tap delivers audio in large chunks; a sink node sees every I/O cycle, so the orb moves with you.
    private func attachSink(format: AVAudioFormat) {
        let signal = signal
        let rate = Float(format.sampleRate)
        let node = sink ?? AVAudioSinkNode { @Sendable _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let stride = max(1, Int(first.mNumberChannels))
            signal.process(data, count: Int(frames), stride: stride, sampleRate: rate)
            return noErr
        }
        if sink == nil { engine.attach(node); sink = node }
        engine.disconnectNodeInput(node)
        engine.connect(engine.inputNode, to: node, format: format)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    /// A headset was plugged in or the input changed mid-dictation: keep going on the new device.
    private func configurationChanged() {
        guard let session = live, !engine.isRunning, let format else { return }
        session.input?.close()
        do { try startAudio(for: session, format: format) }
        catch { onFailure?("The microphone changed and couldn't restart.") }
    }
}

private struct Prepared {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
}

@MainActor
private final class Live {
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    var input: AudioInput?
    var analyzer: SpeechAnalyzer?
    var resultTask: Task<Void, Error>?
    var analysisTask: Task<Void, Error>?
    private var finalText = ""
    private var volatileText = ""

    init(continuation: AsyncStream<AnalyzerInput>.Continuation) { self.continuation = continuation }

    var text: String {
        [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func accept(_ raw: String, final: Bool) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if final {
            if !value.isEmpty { finalText += (finalText.isEmpty ? "" : " ") + value }
            volatileText = ""
        } else {
            volatileText = value
        }
    }
}

/// Runs on the audio thread. The lock serialises conversion against closing.
private final class AudioInput: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let failure: @Sendable (String) -> Void
    private var closed = false
    private var count: UInt64 = 0

    init(from: AVAudioFormat, to: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         failure: @escaping @Sendable (String) -> Void) throws {
        guard let converter = AVAudioConverter(from: from, to: to) else { throw FlowError("This microphone's audio format isn't supported.") }
        self.converter = converter; format = to; self.continuation = continuation; self.failure = failure
    }

    var frames: UInt64 { lock.withLock { count } }

    func close() { lock.withLock { closed = true } }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil else {
            closed = true
            failure("Microphone audio couldn't be read.")
            return
        }
        if output.frameLength > 0 {
            count += UInt64(output.frameLength)
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

}
