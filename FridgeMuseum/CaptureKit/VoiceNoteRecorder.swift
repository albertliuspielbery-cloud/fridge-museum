import AVFoundation
import Foundation
import Observation
import Speech

/// Records a short voice note ("這是我和媽媽去動物園…") and transcribes it on-device.
@MainActor
@Observable
final class VoiceNoteRecorder {
    var isRecording = false
    var isTranscribing = false
    var isPlaying = false
    var message: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var fileURL: URL?

    func start() async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = String(localized: "沒有麥克風權限，請到「設定」開啟")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record(forDuration: 120) else {
                message = String(localized: "無法開始錄音")
                return
            }
            recorder = r
            fileURL = url
            isRecording = true
            message = nil
        } catch {
            message = String(localized: "無法開始錄音")
        }
    }

    /// Stops recording and returns the audio data (m4a).
    func stop() -> Data? {
        guard isRecording, let r = recorder else { return nil }
        r.stop()
        isRecording = false
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        guard let url = fileURL else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    func play(_ data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            player = p
            isPlaying = p.play()
        } catch {
            message = String(localized: "無法播放")
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    func transcribe(_ data: Data) async -> String? {
        isTranscribing = true
        defer { isTranscribing = false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stt-\(UUID().uuidString).m4a")
        do { try data.write(to: url) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let text = await SpeechTranscriber.transcribe(fileURL: url)
        if text == nil { message = String(localized: "這台手機無法離線辨識語音，已保留錄音") }
        return text
    }
}

/// On-device only speech recognition (no audio leaves the phone). Returns nil if on-device recognition is unavailable.
enum SpeechTranscriber {
    static func transcribe(fileURL: URL, locale: Locale = Locale(identifier: AppLanguage.isChinese ? "zh-TW" : "en-US")) async -> String? {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        let once = ResumeOnce()
        let text: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    once.run { c.resume(returning: nil) }
                } else if let result, result.isFinal {
                    let s = result.bestTranscription.formattedString
                    once.run { c.resume(returning: s) }
                }
            }
        }
        withExtendedLifetime(recognizer) {}
        return text
    }
}

/// Guards a continuation against double resume from callback-style APIs.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock {
            if done { return false }
            done = true
            return true
        }
        if first { body() }
    }
}
