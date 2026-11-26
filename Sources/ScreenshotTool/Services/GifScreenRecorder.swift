import AppKit
import CoreMedia
import ScreenCaptureKit

/// 按帧率抓取屏幕某块区域，并就地量化成 GIF 帧（压缩态）。
///
/// 用 `SCStream` 而不是每帧 `SCScreenshotManager`：后者每次都有几十毫秒开销，
/// 24fps（41.7ms 一帧）根本追不上。流式抓帧由系统按 `minimumFrameInterval` 推帧。
///
/// ⚠️ 每帧时长**不能**用"定时器采样"来算（早期版本这么写，实测 24fps 只录到 19 帧/秒）：
/// 定时器跑在编码线程上，量化一帧要几毫秒，会把下一次触发往后推、丢帧；而且首帧要等流
/// 预热（约 250ms），第一帧凭空多停留 250ms。现在改成 **系统送来几帧就处理几帧**，
/// 每帧时长 = 与上一张进画面的帧的时间差 —— 编码慢只会晚一点出结果，时间轴依然精确。
final class GifScreenRecorder: @unchecked Sendable {
    /// 抓帧区的屏幕坐标（全局、左下原点、单位点）。
    private let screen: NSScreen
    private let region: CGRect
    /// 用户在设置里选的帧率。
    private let requestedFps: Int
    /// 实际抓帧用的帧率：GIF 的帧延迟最小是 2/100 秒（约 50fps），
    /// 超过 50 只能把延迟压到 20ms —— 那样 3 秒的录像会播成 3.6 秒（慢 20%）。
    /// 所以这里**按 50 抓**，时间轴才准；界面仍显示用户设的值。
    private let fps: Int
    /// 是否把鼠标箭头录进画面（设置里「录制鼠标箭头 - GIF录制」，默认开）。
    private let showsCursor: Bool

    let pixelWidth: Int
    let pixelHeight: Int

    private var stream: SCStream?
    private var output: FrameOutput?
    private let captureQueue = DispatchQueue(label: "com.mimo.snipmagic.gif.capture", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "com.mimo.snipmagic.gif.encode", qos: .userInitiated)
    private var statsTimer: Timer?

    // 抓帧侧（captureQueue 写、workQueue 读）
    private let frameLock = NSLock()
    private var pendingFrames: [(pixels: [UInt8], time: CFTimeInterval)] = []
    private var isDraining = false
    /// 暂停/续录后重新建立时间基准（否则暂停那段时间会算进某帧的停留时长）。
    private var needsNewBaseline = false
    /// 暂停期间抓到的帧直接丢。
    private var isPaused = false

    // 编码结果（workQueue 写；主线程只读快照）
    private let statsLock = NSLock()
    private var frames: [GifFrame] = []

    private var lastPixels: [UInt8]?
    /// 最后一张**进画面**的帧的出现时间。与"下一件事"的差就是它的停留时长。
    private var lastKeptTime: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartedAt: CFTimeInterval?
    private var finished = false

    /// 主线程回调：已录秒数 + 当前帧数（0.2s 一次）。
    var onStats: ((_ seconds: TimeInterval, _ frameCount: Int) -> Void)?

    init(screen: NSScreen, region: CGRect, fps: Int, showsCursor: Bool = true) {
        self.screen = screen
        self.region = region
        self.showsCursor = showsCursor
        let clamped = max(1, min(60, fps))
        self.requestedFps = clamped
        self.fps = min(clamped, GifScreenRecorder.maxGifFps)
        let scale = screen.backingScaleFactor
        // 宽高取偶数，避免编码时的半像素问题（实际比选区少 1px 是正常的）。
        self.pixelWidth = max(2, Int((region.width * scale).rounded()) & ~1)
        self.pixelHeight = max(2, Int((region.height * scale).rounded()) & ~1)
    }

    /// GIF 格式能表达的最高帧率（延迟 2/100 秒）。
    static let maxGifFps = 50

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    /// 设置值被 GIF 上限压过时，界面用它提示。
    var fpsNote: String? {
        requestedFps > fps ? "GIF 上限 \(fps)" : nil
    }

    private var defaultIntervalMs: Int { max(1, Int((1000.0 / Double(fps)).rounded())) }

    // MARK: - 生命周期

    /// 开始抓帧。`excludingWindowNumbers` 传自己的窗口 —— 录制区本来就是窗口上
    /// 挖出来的"洞"，排除只是双保险（洞里的像素本来就是桌面）。
    func start(excludingWindowNumbers numbers: [Int]) async throws {
        let filter = try await ScreenCaptureService.shared.contentFilter(
            screen: screen,
            excludingWindowNumbers: numbers
        )

        let scale = screen.backingScaleFactor
        // sourceRect 用「点」、左上原点；width/height 用像素。
        let local = CGRect(
            x: region.minX - screen.frame.minX,
            y: screen.frame.maxY - region.maxY,
            width: CGFloat(pixelWidth) / scale,
            height: CGFloat(pixelHeight) / scale
        )

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = pixelWidth
        config.height = pixelHeight
        // 这里才是"帧率设置"真正生效的地方：每秒最多推几帧。
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let output = FrameOutput(width: pixelWidth, height: pixelHeight) { [weak self] pixels in
            self?.enqueue(pixels: pixels)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()

        self.stream = stream
        self.output = output

        resetBuffers()
        startedAt = CACurrentMediaTime()
        pausedAccumulated = 0
        pauseStartedAt = nil
        finished = false
        isPaused = false
        needsNewBaseline = true

        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.emitStats()
        }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    private func elapsedSeconds() -> TimeInterval {
        let now = CACurrentMediaTime()
        return max(0, (pauseStartedAt ?? now) - startedAt - pausedAccumulated)
    }

    private func emitStats() {
        statsLock.lock()
        let n = frames.count
        statsLock.unlock()
        onStats?(elapsedSeconds(), n)
    }

    func pause() {
        guard !finished, pauseStartedAt == nil else { return }
        pauseStartedAt = CACurrentMediaTime()
        isPaused = true
        // 暂停这一刻把最后一帧的停留时长定死，别把暂停时间算进去。
        // 先把已经抓到的帧处理完（它们的时间都早于暂停时刻），再收尾。
        workQueue.async { [weak self] in
            guard let self else { return }
            self.drainPending()
            self.closeLastFrame(at: CACurrentMediaTime())
        }
        emitStats()
    }

    func resume() {
        guard !finished, let pausedAt = pauseStartedAt else { return }
        pausedAccumulated += CACurrentMediaTime() - pausedAt
        pauseStartedAt = nil
        isPaused = false
        frameLock.lock()
        needsNewBaseline = true
        pendingFrames.removeAll()
        frameLock.unlock()
        emitStats()
    }

    /// 停止抓帧并返回录到的动画（可能一帧都没有，例如刚点录制就停止）。
    func finish(completion: @escaping (GifAnimation) -> Void) {
        guard !finished else { return }
        finished = true
        isPaused = true
        statsTimer?.invalidate()
        statsTimer = nil

        let stream = self.stream
        self.stream = nil
        self.output = nil
        let endedAt = CACurrentMediaTime()

        let build: () -> Void = { [weak self] in
            guard let self else { return }
            self.workQueue.async {
                self.drainPending()
                self.closeLastFrame(at: endedAt)

                self.statsLock.lock()
                let out = self.frames
                self.frames.removeAll()
                self.statsLock.unlock()

                let anim = GifAnimation(width: self.pixelWidth, height: self.pixelHeight, frames: out, loop: true)
                DispatchQueue.main.async { completion(anim) }
            }
        }

        if let stream {
            stream.stopCapture { _ in build() }
        } else {
            build()
        }
    }

    /// 直接丢弃（取消录制）：停流、清空已录帧，不生成动画。
    func abort() {
        guard !finished else { return }
        finished = true
        isPaused = true
        statsTimer?.invalidate()
        statsTimer = nil
        let stream = self.stream
        self.stream = nil
        self.output = nil
        stream?.stopCapture { _ in }
        resetBuffers()
    }

    // MARK: - 抓帧 → 量化

    private func resetBuffers() {
        statsLock.lock()
        frames.removeAll()
        statsLock.unlock()
        frameLock.lock()
        pendingFrames.removeAll()
        isDraining = false
        frameLock.unlock()
        lastPixels = nil
        lastKeptTime = 0
    }

    /// 抓帧线程：只入队，不做重活（量化在 workQueue 上）。
    private func enqueue(pixels: [UInt8]) {
        guard !finished, !isPaused else { return }
        let now = CACurrentMediaTime()
        frameLock.lock()
        pendingFrames.append((pixels, now))
        // 编码万一跟不上（超大区域 + 高帧率），只保留最近的 240 帧，
        // 避免内存无限涨；时间轴靠时间戳算，不会因此变短。
        if pendingFrames.count > 240 {
            pendingFrames.removeFirst(pendingFrames.count - 240)
        }
        let shouldSchedule = !isDraining
        isDraining = true
        frameLock.unlock()
        if shouldSchedule {
            workQueue.async { [weak self] in self?.drainPending() }
        }
    }

    private func drainPending() {
        while true {
            frameLock.lock()
            let next = pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
            if next == nil { isDraining = false }
            frameLock.unlock()
            guard let next else { return }
            process(pixels: next.pixels, at: next.time)
        }
    }

    /// 一帧画面。画面与上一张相同就不新增帧（合并），不同的才落一帧并把上一帧时长定死。
    private func process(pixels: [UInt8], at time: CFTimeInterval) {
        if frames.isEmpty || needsNewBaseline {
            needsNewBaseline = false
            if let last = lastPixels, last == pixels {
                // 续录后的第一帧和暂停前一样：只更新时间基准。
                lastKeptTime = time
                return
            }
            append(pixels, delay: defaultIntervalMs)
            lastPixels = pixels
            lastKeptTime = time
            return
        }

        guard pixels != lastPixels else { return }

        closeLastFrame(at: time, clampingFirst: true)
        append(pixels, delay: defaultIntervalMs)
        lastPixels = pixels
        lastKeptTime = time
    }

    /// 把最后一帧的停留时长定为 `time - lastKeptTime`（5ms–2s）。
    /// `clampingFirst`：第一帧到第二帧之间的空档多半是"抓流预热"（实测偶发 700ms+），
    /// 不是真实画面停留 —— 原样记下来会让 GIF 一开头就卡一下，所以压到两三帧以内。
    private func closeLastFrame(at time: CFTimeInterval, clampingFirst: Bool = false) {
        guard lastKeptTime > 0 else { return }
        var ms = Int(((time - lastKeptTime) * 1000).rounded())
        if clampingFirst, frames.count == 1 {
            ms = min(ms, max(defaultIntervalMs * 2, 100))
        }
        let delay = min(2000, max(5, ms))
        statsLock.lock()
        if !frames.isEmpty { frames[frames.count - 1].delayMs = delay }
        statsLock.unlock()
    }

    private func append(_ pixels: [UInt8], delay: Int) {
        let q = GifCodec.quantize(bgra: pixels, width: pixelWidth, height: pixelHeight)
        guard !q.indices.isEmpty else { return }
        let frame = GifFrame(indices: q.indices, palette: q.palette, minCodeSize: q.minCodeSize, delayMs: delay)
        statsLock.lock()
        frames.append(frame)
        statsLock.unlock()
    }
}

// MARK: - SCStreamOutput

private final class FrameOutput: NSObject, SCStreamOutput {
    private let width: Int
    private let height: Int
    private let onFrame: ([UInt8]) -> Void

    init(width: Int, height: Int, onFrame: @escaping ([UInt8]) -> Void) {
        self.width = width
        self.height = height
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // 只取完整帧：idle / blank / suspended 的帧不参与录制。
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pw = CVPixelBufferGetWidth(pixelBuffer)
        let ph = CVPixelBufferGetHeight(pixelBuffer)
        guard pw > 0, ph > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            let src = base.assumingMemoryBound(to: UInt8.self)
            // rowBytes 常常大于 width*4，必须按行拷。
            let copyW = min(width, pw) * 4
            for y in 0..<min(height, ph) {
                memcpy(dstBase + y * width * 4, src + y * bytesPerRow, copyW)
            }
        }
        onFrame(out)
    }
}
