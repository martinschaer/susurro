import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Config

/// `~/.susurro/config.json`, read once when capture is enabled. Toggle off/on to reload.
/// Every field is optional in the file; missing keys keep the default.
struct Config {
    var model = "ggml-large-v3-turbo.bin"
    var rmsThreshold: Float = 0.01
    var silenceMs = 700
    var maxSegmentSec = 25.0

    /// Max cosine distance for two segments to count as the same person. Hardware- and
    /// codec-dependent like `rmsThreshold`: FluidAudio suggests 0.6–0.7 for clean audio
    /// and 0.7–0.8 for noisy, and a conference codec counts as noisy.
    var speakerThreshold: Float = 0.65

    /// Silence on both streams for longer than this starts a new transcript file, so one
    /// file is one meeting. Toggling Listening off/on always starts a new one too.
    var sessionGapMin = 5.0

    /// Hand-rolled rather than Decodable: a custom `init(from:)` would need an explicit
    /// CodingKeys enum to tolerate partial JSON, which is more code than this.
    static func load() -> Config {
        var c = Config()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.susurro/config.json")
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return c }
        if let v = o["model"] as? String { c.model = v }
        if let v = o["rmsThreshold"] as? Double { c.rmsThreshold = Float(v) }
        if let v = o["silenceMs"] as? Int { c.silenceMs = v }
        if let v = o["maxSegmentSec"] as? Double { c.maxSegmentSec = v }
        if let v = o["speakerThreshold"] as? Double { c.speakerThreshold = Float(v) }
        if let v = o["sessionGapMin"] as? Double { c.sessionGapMin = v }
        return c
    }
}

// MARK: - Segmenter

/// Cuts a continuous 16 kHz mono stream into utterances with an RMS gate.
///
/// The gate only decides *when* to cut; whisper's Silero VAD then decides whether the cut
/// contains speech at all. Two cheap layers beat one expensive one.
///
/// Not thread-safe by design — each capture source owns its own instance and pushes from
/// a single audio thread.
final class Segmenter {
    private let frame = 320            // 20 ms @ 16 kHz
    private let prerollFrames = 15     // 300 ms of lead-in, so we don't clip the first phoneme
    private let minSpeechFrames = 15   // ignore anything under 300 ms of voiced audio
    private let silenceFrames: Int
    private let maxSamples: Int
    private let threshold: Float
    private let emit: ([Float]) -> Void

    private var pending: [Float] = []  // sub-frame remainder between pushes
    private var buf: [Float] = []
    private var preroll: [Float] = []
    private var speaking = false
    private var silent = 0
    private var voiced = 0

    init(config: Config, emit: @escaping ([Float]) -> Void) {
        silenceFrames = max(1, config.silenceMs / 20)
        maxSamples = Int(config.maxSegmentSec * 16000)
        threshold = config.rmsThreshold
        self.emit = emit
    }

    func push(_ samples: [Float]) {
        pending += samples
        while pending.count >= frame {
            let f = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            step(f)
        }
    }

    private func step(_ f: [Float]) {
        var sum: Float = 0
        for v in f { sum += v * v }
        let rms = (sum / Float(f.count)).squareRoot()

        if rms > threshold {
            if !speaking {
                speaking = true
                buf = preroll          // lead-in becomes the head of the segment
                preroll = []
            }
            buf += f
            voiced += 1
            silent = 0
        } else if speaking {
            buf += f                   // keep the trailing silence, whisper reads better with it
            silent += 1
            if silent >= silenceFrames { flush() }
        } else {
            preroll += f
            let cap = prerollFrames * frame
            if preroll.count > cap { preroll.removeFirst(preroll.count - cap) }
        }

        if speaking && buf.count >= maxSamples { flush() }
    }

    private func flush() {
        if voiced >= minSpeechFrames { emit(buf) }
        buf = []; preroll = []; speaking = false; silent = 0; voiced = 0
    }
}

// MARK: - Resampler

/// Anything → 16 kHz mono Float32, whisper's native input format.
/// `AVAudioConverter` is stateful across calls, which is what makes resampling continuous.
final class Resampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                     channels: 1, interleaved: false)!
    private let conv: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: Resampler.target) else { return nil }
        conv = c
    }

    func push(_ input: AVAudioPCMBuffer) -> [Float] {
        let ratio = Resampler.target.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Resampler.target, frameCapacity: cap)
        else { return [] }

        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

// MARK: - Microphone

/// What you say.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let seg: Segmenter
    private var resampler: Resampler?

    init(seg: Segmenter) { self.seg = seg }

    func start() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw CaptureError("no usable input device")
        }
        guard let r = Resampler(from: fmt) else {
            throw CaptureError("cannot convert \(fmt.sampleRate) Hz input")
        }
        resampler = r
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let r = self.resampler else { return }
            let s = r.push(buf)
            if !s.isEmpty { self.seg.push(s) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        resampler = nil
    }
}

// MARK: - System audio

/// What you hear, via a global Core Audio process tap (macOS 14.2+).
///
/// Measured tap output: 48 kHz, 2 ch, interleaved Float32 — the `Resampler` handles the
/// downmix and rate conversion. Do not assume 16 kHz mono here.
final class SystemCapture {
    private let seg: Segmenter
    private let q = DispatchQueue(label: "dev.susurro.tap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var resampler: Resampler?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(seg: Segmenter) { self.seg = seg }

    func start() throws {
        try build()
        // The aggregate device is pinned to the output device UID captured in build().
        // Switching output (Bluetooth <-> speakers) silently stops delivering audio with
        // no error, so rebuild whenever the default output changes.
        var addr = Self.addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.teardown()
            try? self.build()
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, q, listener)
    }

    func stop() {
        if let l = deviceListener {
            var addr = Self.addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, q, l)
            deviceListener = nil
        }
        teardown()
    }

    // MARK: private

    private func build() throws {
        guard #available(macOS 14.2, *) else { throw CaptureError("needs macOS 14.2+") }

        guard let outID: AudioDeviceID = Self.read(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultSystemOutputDevice, AudioDeviceID(0)),
            let outUID = Self.readString(outID, kAudioDevicePropertyDeviceUID)
        else { throw CaptureError("no default output device") }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted        // you must still hear the audio
        desc.isPrivate = true
        desc.name = "SusurroTap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapErr == noErr else {
            throw CaptureError("tap refused (err \(tapErr)) — check System Audio Recording permission")
        }
        tapID = tap

        guard var asbd: AudioStreamBasicDescription = Self.read(
            tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
            let fmt = AVAudioFormat(streamDescription: &asbd),
            let r = Resampler(from: fmt)
        else { teardown(); throw CaptureError("unusable tap format") }
        tapFormat = fmt
        resampler = r

        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SusurroAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,       // hidden from Sound settings
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg) == noErr else {
            teardown(); throw CaptureError("aggregate device creation failed")
        }
        aggID = agg

        var proc: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, q) {
            [weak self] _, inData, _, _, _ in
            guard let self, let fmt = self.tapFormat, let r = self.resampler,
                  let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData)
            else { return }
            let s = r.push(pcm)
            if !s.isEmpty { self.seg.push(s) }
        }
        guard ioErr == noErr, let proc else {
            teardown(); throw CaptureError("io proc creation failed")
        }
        procID = proc

        guard AudioDeviceStart(agg, proc) == noErr else {
            teardown(); throw CaptureError("could not start aggregate device")
        }
    }

    /// Verified-clean order: stop -> destroy io proc -> destroy aggregate -> destroy tap.
    private func teardown() {
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            if let p = procID {
                AudioDeviceStop(aggID, p)
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapFormat = nil
        resampler = nil
    }

    // MARK: Core Audio property helpers

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                _ fallback: T) -> T? {
        var a = addr(sel), size = UInt32(MemoryLayout<T>.size), v = fallback
        let err = withUnsafeMutablePointer(to: &v) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        return err == noErr ? v : nil
    }

    private static func readString(_ id: AudioObjectID,
                                   _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel), size = UInt32(MemoryLayout<CFString?>.size)
        var ref: CFString?
        let err = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        return err == noErr ? ref as String? : nil
    }
}

struct CaptureError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
