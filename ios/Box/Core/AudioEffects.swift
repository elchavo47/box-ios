import Accelerate
import AVFoundation
import MediaToolbox

/// Ekolayzer ve ses seviyesi eşitleme. AVPlayer'ın ses akışına bir "tap" ile girer.
enum AudioEffects {
    /// Ayarlar kapalıysa nil (ek işlem yok).
    static func audioMix(for item: AVPlayerItem, preset: EQPreset, normalize: Bool) async -> AVAudioMix? {
        guard preset != .flat || normalize else { return nil }
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return nil }

        let context = TapContext(gains: preset.gains, normalize: normalize)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

/// Tap içinde çalışan durum: kanal başına 5 bantlı biquad filtre ve otomatik kazanç.
final class TapContext {
    let gains: [Float]
    let normalize: Bool
    var setup: vDSP_biquad_Setup?
    var delays: [[Float]] = []
    var usable = false
    var agcGain: Float = 1

    init(gains: [Float], normalize: Bool) {
        self.gains = gains
        self.normalize = normalize
    }

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
    }

    func prepare(sampleRate: Double, channels: Int, isFloat: Bool, nonInterleaved: Bool) {
        usable = isFloat && nonInterleaved && sampleRate > 0
        guard usable else { return }
        var coefficients: [Double] = []
        for (index, frequency) in EQPreset.frequencies.enumerated() {
            let f = min(Double(frequency), sampleRate * 0.45)
            coefficients += Self.peaking(frequency: f, gainDB: Double(gains[index]), q: index == 0 || index == 4 ? 0.7 : 1.0, sampleRate: sampleRate)
        }
        if let setup { vDSP_biquad_DestroySetup(setup) }
        setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(EQPreset.frequencies.count))
        delays = Array(repeating: [Float](repeating: 0, count: 2 * EQPreset.frequencies.count + 2), count: max(channels, 1))
    }

    /// RBJ "peaking EQ" katsayıları: b0, b1, b2, a1, a2 (a0'a bölünmüş).
    static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return [(1 + alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha / a) / a0]
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard usable, frames > 0 else { return }
        let flat = gains.allSatisfy { $0 == 0 }

        // Ses eşitleme: kısa süreli RMS'e göre kazancı yavaşça hedefe (-16 dBFS) çek.
        if normalize {
            var sum: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var rms: Float = 0
                vDSP_rmsqv(data, 1, &rms, vDSP_Length(frames))
                sum += rms
            }
            let rms = sum / Float(max(buffers.count, 1))
            if rms > 0.0005 {
                let target: Float = 0.158 // ~ -16 dBFS
                let wanted = min(max(target / rms, 0.5), 2.0)
                agcGain += (wanted - agcGain) * 0.02
            }
        }

        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if !flat, let setup, channel < delays.count {
                delays[channel].withUnsafeMutableBufferPointer { delay in
                    vDSP_biquad(setup, delay.baseAddress!, data, 1, data, 1, vDSP_Length(frames))
                }
            }
            // EQ yükseltmesinde taşmayı önlemek için hafif ön kısma + eşitleme kazancı.
            var scale: Float = (flat ? 1 : 0.8) * (normalize ? agcGain : 1)
            if scale != 1 { vDSP_vsmul(data, 1, &scale, data, 1, vDSP_Length(frames)) }
            var low: Float = -1, high: Float = 1
            vDSP_vclip(data, 1, &low, &high, data, 1, vDSP_Length(frames))
        }
    }
}

// MARK: - C geri çağırmaları

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let asbd = format.pointee
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    context.prepare(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), isFloat: isFloat, nonInterleaved: nonInterleaved)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
    guard status == noErr else { return }
    let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
}
