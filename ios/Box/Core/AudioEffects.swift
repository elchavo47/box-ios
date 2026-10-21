import Accelerate
import AVFoundation
import MediaToolbox
import QuartzCore

/// Ekolayzer ve ses seviyesi eşitleme. AVPlayer'ın ses akışına bir "tap" ile girer.
enum AudioEffects {
    /// Ses akışına girer: ekolayzer, ses eşitleme ve görselleştirici için seviye ölçümü.
    /// `eq` nil ise ekolayzer kapalıdır (ya da kullanıcının hakkı yoktur). Ayarlar sonradan
    /// `TapContext.update` ile şarkı çalarken değiştirilebilir.
    static func audioMix(for item: AVPlayerItem, eq: EQSettings?, normalize: Bool, meter: Bool) async -> (AVAudioMix, TapContext)? {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return nil }

        let context = TapContext(eq: eq, normalize: normalize, meter: meter)
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
        return (mix, context)
    }
}

/// Tap içinde çalışan durum: kanal başına 10 bantlı biquad filtre, ses yükseltme, yumuşak
/// sınırlayıcı ve otomatik kazanç. Ayarlar ana iş parçacığından `update` ile değişir; ses iş
/// parçacığı bir sonraki parçada yeni filtreleri kurar.
final class TapContext {
    private(set) var gains: [Float]
    private(set) var boost: Float
    private(set) var normalize: Bool
    let meter: Bool
    private var pending: (gains: [Float], boost: Float, normalize: Bool)?
    private let settingsLock = NSLock()
    private var channels = 1
    var setup: vDSP_biquad_Setup?

    // Görselleştirici: 1024 örneklik FFT, 9 bant (log aralıklı), %50 örtüşmeli (512 örnekte bir).
    // Ses parça parça (ör. 4096 örnek) geldiği için her ölçüm çalınacağı ana göre zaman damgalanır;
    // ekran her karede o anın değerini ara değerle bulur (çubuklar kesik kesik zıplamaz).
    static let bandCount = 9
    private let fftSize = 1024
    private let hop = 512
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var ring: [Float] = []
    private var ringFill = 0
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitudes: [Float] = []
    private var bandBins: [(Int, Int)] = []
    private var bands = [Float](repeating: 0, count: TapContext.bandCount)
    private let lock = NSLock()
    private var outputLatency: Double = 0
    private var timelineEnd: Double = 0

    private struct Snapshot {
        var time: Double
        var bands: [Float]
    }
    private var snapshots: [Snapshot] = []
    private let snapshotCapacity = 64

    /// 0...1 arası bant seviyeleri (ana iş parçacığından okunur).
    func levels() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return bands
    }

    /// Verilen andaki (CACurrentMediaTime) bant seviyeleri: iki ölçüm arasında doğrusal ara değer.
    func levels(at time: Double) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard !snapshots.isEmpty else { return nil }
        let t = time - outputLatency
        guard let next = snapshots.firstIndex(where: { $0.time > t }) else {
            // Yeni ölçüm gelmedi (duraklatıldı / takıldı): son değer.
            return snapshots.last?.bands
        }
        guard next > 0 else { return snapshots[0].bands }
        let a = snapshots[next - 1], b = snapshots[next]
        let span = max(b.time - a.time, 0.0001)
        let f = Float(min(max((t - a.time) / span, 0), 1))
        var out = [Float](repeating: 0, count: Self.bandCount)
        for i in 0..<Self.bandCount { out[i] = a.bands[i] + (b.bands[i] - a.bands[i]) * f }
        return out
    }
    var delays: [[Float]] = []
    var usable = false
    var agcGain: Float = 1

    init(eq: EQSettings?, normalize: Bool, meter: Bool) {
        self.gains = Self.effectiveGains(eq)
        self.boost = Self.effectiveBoost(eq)
        self.normalize = normalize
        self.meter = meter
        if meter {
            fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
            window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            ring = [Float](repeating: 0, count: fftSize)
            windowed = [Float](repeating: 0, count: fftSize)
            real = [Float](repeating: 0, count: fftSize / 2)
            imag = [Float](repeating: 0, count: fftSize / 2)
            magnitudes = [Float](repeating: 0, count: fftSize / 2)
            snapshots.reserveCapacity(snapshotCapacity)
            outputLatency = AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
        }
    }

    deinit {
        if let setup { vDSP_biquad_DestroySetup(setup) }
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    private var sampleRate: Double = 44100

    /// Gelen örnekleri kayan pencereye ekler; her 512 örnekte bir son 1024 örneğin bantlarını ölçer.
    private func analyze(_ data: UnsafeMutablePointer<Float>, frames: Int) {
        guard fftSetup != nil, ring.count == fftSize else { return }
        let secondsPerFrame = 1 / max(sampleRate, 1)
        // Parçalar arka arkaya çalınır: bir öncekinin bittiği andan devam et (çok sapmadıysa).
        let now = CACurrentMediaTime()
        let start = timelineEnd > now && timelineEnd - now < 0.5 ? timelineEnd : now
        timelineEnd = start + Double(frames) * secondsPerFrame
        var index = 0
        while index < frames {
            let take = min(hop - ringFill, frames - index)
            ring.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                // Pencereyi sola kaydır, yeni örnekleri sona ekle.
                memmove(base, base + take, (fftSize - take) * MemoryLayout<Float>.size)
                memcpy(base + (fftSize - take), data + index, take * MemoryLayout<Float>.size)
            }
            ringFill += take
            index += take
            if ringFill >= hop {
                ringFill = 0
                let next = measure()
                // Bu ölçümün temsil ettiği an: parçanın başından bu yana geçen örnek kadar sonra.
                let time = start + Double(index) * secondsPerFrame
                lock.lock()
                for band in 0..<Self.bandCount {
                    bands[band] = next[band] > bands[band] ? next[band] : bands[band] * 0.82 + next[band] * 0.18
                }
                if let last = snapshots.last, last.time > time { snapshots.removeAll(keepingCapacity: true) }
                snapshots.append(Snapshot(time: time, bands: next))
                if snapshots.count > snapshotCapacity { snapshots.removeFirst(snapshots.count - snapshotCapacity) }
                lock.unlock()
            }
        }
    }

    private func measure() -> [Float] {
        guard let fftSetup else { return [Float](repeating: 0, count: Self.bandCount) }
        let half = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        if bandBins.isEmpty {
            // 40 Hz – 16 kHz arası log aralıklı bantlar.
            let binHz = Float(sampleRate) / Float(fftSize)
            for band in 0..<Self.bandCount {
                let low = 40 * pow(400, Float(band) / Float(Self.bandCount))
                let high = 40 * pow(400, Float(band + 1) / Float(Self.bandCount))
                let start = max(1, Int(low / binHz)), end = min(half - 1, max(start + 1, Int(high / binHz)))
                bandBins.append((start, end))
            }
        }
        var next = [Float](repeating: 0, count: Self.bandCount)
        for (band, range) in bandBins.enumerated() {
            var sum: Float = 0
            for bin in range.0..<range.1 { sum += magnitudes[bin] }
            let average = sum / Float(range.1 - range.0)
            let db = 10 * log10(max(average, 1e-12))
            next[band] = min(max((db + 20) / 70, 0), 1)
        }
        return next
    }

    static func effectiveGains(_ eq: EQSettings?) -> [Float] {
        guard let eq, eq.enabled, eq.gains.count == EQSettings.bandCount else { return [Float](repeating: 0, count: EQSettings.bandCount) }
        return eq.gains.map { min(max($0, EQSettings.range.lowerBound), EQSettings.range.upperBound) }
    }

    static func effectiveBoost(_ eq: EQSettings?) -> Float {
        guard let eq, eq.enabled else { return 0 }
        return min(max(eq.boost, EQSettings.boostRange.lowerBound), EQSettings.boostRange.upperBound)
    }

    /// Ana iş parçacığından: yeni ekolayzer / eşitleme ayarı. Çalan şarkıya hemen uygulanır.
    func update(eq: EQSettings?, normalize: Bool) {
        settingsLock.lock()
        pending = (Self.effectiveGains(eq), Self.effectiveBoost(eq), normalize)
        settingsLock.unlock()
    }

    func prepare(sampleRate: Double, channels: Int, isFloat: Bool, nonInterleaved: Bool) {
        usable = isFloat && nonInterleaved && sampleRate > 0
        bandBins = []
        guard usable else { return }
        self.sampleRate = sampleRate
        self.channels = max(channels, 1)
        rebuildFilters()
    }

    private func rebuildFilters() {
        var coefficients: [Double] = []
        let count = EQSettings.frequencies.count
        for (index, frequency) in EQSettings.frequencies.enumerated() {
            let f = min(Double(frequency), sampleRate * 0.45)
            // Oktav aralıklı bantlar: Q ≈ 1.4; uçlar biraz daha geniş.
            let q = index == 0 || index == count - 1 ? 0.9 : 1.4
            coefficients += Self.peaking(frequency: f, gainDB: Double(gains[index]), q: q, sampleRate: sampleRate)
        }
        if let setup { vDSP_biquad_DestroySetup(setup) }
        setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(count))
        if delays.count != channels || delays.first?.count != 2 * count + 2 {
            delays = Array(repeating: [Float](repeating: 0, count: 2 * count + 2), count: channels)
        }
    }

    /// Yükseltilen bantlarda taşmayı azaltan ön kısma ile ses yükseltmenin toplam kazancı.
    private var outputScale: Float {
        let peak = gains.max() ?? 0
        let headroom = max(peak, 0) * 0.6
        return pow(10, (boost - headroom) / 20)
    }

    /// Yumuşak sınırlayıcı: 0.8'e kadar dokunmaz, üstünü tanh ile ±1'e yaklaştırır (sert kırpma yok).
    private static func softLimit(_ data: UnsafeMutablePointer<Float>, frames: Int) {
        let knee: Float = 0.8
        let room: Float = 1 - knee
        for i in 0..<frames {
            let x = data[i]
            let a = abs(x)
            if a > knee {
                let y = knee + room * tanh((a - knee) / room)
                data[i] = x < 0 ? -y : y
            }
        }
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
        settingsLock.lock()
        let next = pending
        pending = nil
        settingsLock.unlock()
        if let next {
            let changed = next.gains != gains
            gains = next.gains
            boost = next.boost
            normalize = next.normalize
            if changed { rebuildFilters() }
        }
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
            // Ön kısma / ses yükseltme + eşitleme kazancı, ardından yumuşak sınırlayıcı.
            var scale: Float = ((flat && boost == 0) ? 1 : outputScale) * (normalize ? agcGain : 1)
            if scale != 1 { vDSP_vsmul(data, 1, &scale, data, 1, vDSP_Length(frames)) }
            if !flat || boost > 0 || normalize { Self.softLimit(data, frames: frames) }
            var low: Float = -1, high: Float = 1
            vDSP_vclip(data, 1, &low, &high, data, 1, vDSP_Length(frames))
            if meter && channel == 0 { analyze(data, frames: frames) }
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
