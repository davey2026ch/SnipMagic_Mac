import Foundation
import CoreGraphics

// MARK: - Pixel buffer

/// RGBA8 (premultiplied) pixel buffer. Memory row 0 is the TOP row of the image,
/// which matches CGImage's provider layout, so buffers can be stitched vertically
/// without any flipping.
struct PixelBuffer {
    let width: Int
    private(set) var bytes: [UInt8]

    var height: Int { width > 0 ? bytes.count / (width * 4) : 0 }
    var rowBytes: Int { width * 4 }

    init(width: Int, bytes: [UInt8]) {
        self.width = width
        self.bytes = bytes
    }

    init?(image: CGImage) {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        self.bytes = [UInt8](UnsafeBufferPointer(start: ptr, count: w * h * 4))
        self.width = w
    }
}

// MARK: - Frame data

/// A captured frame plus precomputed row signatures used for fast scroll detection.
/// Each row is summarized into `segments` brightness sums; two rows "match" when all
/// segment sums are within a tolerance — fuzzy enough to absorb anti-aliasing noise.
struct FrameData {
    static let segments = 16

    let buffer: PixelBuffer
    /// segments × height brightness sums (Int32), row-major.
    let signatures: [Int32]
    /// A row is "distinctive" when its segments differ enough to be useful for
    /// alignment (blank/gradient rows are excluded — they match every offset).
    let distinctive: [Bool]
    /// Pixels sampled per row for the signature (≤ 256).
    let samplesPerRow: Int

    var height: Int { buffer.height }
    var width: Int { buffer.width }

    /// Segment-match tolerance in sum space (≈ 14 luma per sampled pixel).
    var segmentTolerance: Int32 {
        Int32((samplesPerRow + FrameData.segments - 1) / FrameData.segments * 14)
    }

    init(buffer: PixelBuffer) {
        self.buffer = buffer
        let w = buffer.width
        let h = buffer.height
        let rowBytes = buffer.rowBytes
        let bytes = buffer.bytes

        let samples = min(w, 256)
        self.samplesPerRow = samples

        var sigs = [Int32](repeating: 0, count: h * FrameData.segments)
        var dist = [Bool](repeating: false, count: h)
        let segSpan = (samples + FrameData.segments - 1) / FrameData.segments

        for r in 0..<h {
            let rowStart = r * rowBytes
            var rowMin: Int32 = .max
            var rowMax: Int32 = .min
            for i in 0..<samples {
                let x = (i * w) / max(samples, 1)
                let idx = rowStart + x * 4
                let luma = (Int32(bytes[idx]) * 3 + Int32(bytes[idx + 1]) * 6 + Int32(bytes[idx + 2])) / 10
                let s = i * FrameData.segments / max(samples, 1)
                sigs[r * FrameData.segments + s] += luma
            }
            for s in 0..<FrameData.segments {
                let v = sigs[r * FrameData.segments + s]
                rowMin = min(rowMin, v)
                rowMax = max(rowMax, v)
            }
            // Spread large enough → row carries usable structure (text, edges…).
            dist[r] = (rowMax - rowMin) >= Int32(max(segSpan * 18, 300))
        }
        self.signatures = sigs
        self.distinctive = dist
    }
}

// MARK: - Scroll detector

enum ScrollDetectionResult {
    case noChange
    /// dy > 0: content scrolled up (new content at the bottom).
    /// topSticky / bottomSticky: leading/trailing rows that did NOT move
    /// (fixed page header / footer bands).
    case scrolled(dy: Int, topSticky: Int, bottomSticky: Int)
    /// No confident alignment found (fast fling, scene change, animation…).
    case unknown
}

enum ScrollDetector {
    static let minStep = 4          // px; smaller shifts accumulate on the anchor
    static let minOverlap = 40      // px of required overlap between frames
    static let rowSampleCount = 48  // rows sampled per offset candidate
    static let confidenceThreshold = 0.80
    static let pixelTolerance = 14
    static let verifyThreshold = 0.88
    static let maxVerifyCandidates = 24

    static func detect(anchor: FrameData, frame: FrameData) -> ScrollDetectionResult {
        let H = min(anchor.height, frame.height)
        guard H > minOverlap + 8 else { return .noChange }
        let segs = FrameData.segments

        // Fixed header/footer bands first — they sit at the same rows in both
        // frames, so they can be excluded from the alignment window up front.
        let topSticky = stickyBand(anchor: anchor, frame: frame, height: H, fromTop: true)
        let bottomSticky = stickyBand(anchor: anchor, frame: frame, height: H, fromTop: false)

        // Compare only the middle rows so neither viewport edges nor the
        // sticky bands bias the alignment toward dy = 0.
        let windowLo = max(H / 10, topSticky)
        let windowHi = min(H - H / 10, H - bottomSticky)

        @inline(__always) func rowMatch(_ fa: Int, _ fb: Int) -> Bool {
            let offA = fa * segs
            let offB = fb * segs
            let tol = anchor.segmentTolerance
            for s in 0..<segs {
                let diff = anchor.signatures[offA + s] - frame.signatures[offB + s]
                if diff > tol || -diff > tol { return false }
            }
            return true
        }

        @inline(__always) func ratio(dy: Int) -> (ratio: Double, count: Int) {
            // frame[r] corresponds to anchor[r + dy]. Both the frame row and
            // the anchor row must lie inside the scrollable content region
            // (between the sticky bands) — otherwise we'd compare against
            // fixed header/footer pixels and score valid offsets as mismatches.
            let contentHi = H - bottomSticky
            let lo = max(windowLo, topSticky, -dy, topSticky - dy)
            let hi = min(windowHi, contentHi, contentHi - dy)
            guard hi > lo else { return (0, 0) }
            let span = hi - lo
            let step = max(1, span / rowSampleCount)
            var matched = 0
            var total = 0
            var r = lo
            while r < hi {
                if frame.distinctive[r] && anchor.distinctive[r + dy] {
                    total += 1
                    if rowMatch(r + dy, r) { matched += 1 }
                }
                r += step
            }
            guard total >= 8 else { return (0, 0) }
            return (Double(matched) / Double(total), total)
        }

        // Static / sub-pixel-jitter frame: dy = 0 already explains it.
        if ratio(dy: 0).ratio >= confidenceThreshold {
            return .noChange
        }

        // Ambiguous content (runs of identical rows) can make several offsets
        // score perfectly. Collect all confident candidates, then verify them
        // with strict pixel checks — in order: ratio desc, |dy| asc — and take
        // the first that survives.
        var candidates: [(dy: Int, ratio: Double)] = []
        let maxDy = H - minOverlap
        for d in 1...maxDy {
            for dy in [d, -d] {
                let res = ratio(dy: dy)
                if res.ratio >= confidenceThreshold {
                    candidates.append((dy, res.ratio))
                }
            }
        }
        candidates.sort {
            $0.ratio != $1.ratio ? $0.ratio > $1.ratio : abs($0.dy) < abs($1.dy)
        }

        for cand in candidates.prefix(maxVerifyCandidates) {
            if verifyPixels(anchor: anchor, frame: frame, dy: cand.dy, height: H,
                            topSticky: topSticky, bottomSticky: bottomSticky) {
                return .scrolled(dy: cand.dy, topSticky: topSticky, bottomSticky: bottomSticky)
            }
        }
        return .unknown
    }

    /// Are two frames essentially the same image (used to avoid fake "gaps"
    /// when the page is static or merely animating a tiny area)?
    static func framesSimilar(_ a: FrameData, _ b: FrameData) -> Bool {
        let H = min(a.height, b.height)
        let W = min(a.width, b.width)
        guard H > 0, W > 0 else { return true }
        let rowStep = max(1, H / 24)
        let colStep = max(1, W / 24)
        var equal = 0
        var total = 0
        var r = 0
        while r < H {
            var c = 0
            while c < W {
                let ia = (r * W + c) * 4
                let ib = (r * W + c) * 4
                let d = abs(Int(a.buffer.bytes[ia]) - Int(b.buffer.bytes[ib]))
                    + abs(Int(a.buffer.bytes[ia + 1]) - Int(b.buffer.bytes[ib + 1]))
                    + abs(Int(a.buffer.bytes[ia + 2]) - Int(b.buffer.bytes[ib + 2]))
                if d <= pixelTolerance { equal += 1 }
                total += 1
                c += colStep
            }
            r += rowStep
        }
        guard total > 0 else { return true }
        return Double(equal) / Double(total) >= 0.90
    }

    // MARK: Private

    private static func verifyPixels(anchor: FrameData, frame: FrameData, dy: Int, height H: Int,
                                     topSticky: Int, bottomSticky: Int) -> Bool {
        // Only rows that are content in BOTH frames (sticky bands excluded —
        // they match at dy = 0 and would let wrong offsets pass).
        let contentHi = H - bottomSticky
        let lo = max(0, -dy, topSticky, topSticky - dy)
        let hi = min(H, H - dy, contentHi, contentHi - dy)
        guard hi - lo >= 8 else { return false }
        let W = min(anchor.width, frame.width)
        let rowStep = max(1, (hi - lo) / 24)
        let colStep = max(1, W / 16)
        var pass = 0
        var total = 0
        var r = lo
        while r < hi {
            var c = 0
            while c < W {
                let ia = ((r + dy) * W + c) * 4
                let ib = (r * W + c) * 4
                let dr = abs(Int(anchor.buffer.bytes[ia]) - Int(frame.buffer.bytes[ib]))
                let dg = abs(Int(anchor.buffer.bytes[ia + 1]) - Int(frame.buffer.bytes[ib + 1]))
                let db = abs(Int(anchor.buffer.bytes[ia + 2]) - Int(frame.buffer.bytes[ib + 2]))
                if dr <= pixelTolerance && dg <= pixelTolerance && db <= pixelTolerance { pass += 1 }
                total += 1
                c += colStep
            }
            r += rowStep
        }
        guard total > 0 else { return false }
        return Double(pass) / Double(total) >= verifyThreshold
    }

    /// Longest run of identical leading (or trailing) rows between the two frames.
    /// Only meaningful when the rest of the content has moved (dy ≠ 0).
    /// Bands made of uniform rows (blank page areas) are rejected — they look
    /// "sticky" between any two frames; a real fixed header/footer has structure.
    private static func stickyBand(anchor: FrameData, frame: FrameData, height H: Int, fromTop: Bool) -> Int {
        let W = min(anchor.width, frame.width)
        let colStep = max(1, W / 64)
        let maxBand = H / 3
        var count = 0
        var distinctiveRows = 0
        for i in 0..<maxBand {
            let r = fromTop ? i : H - 1 - i
            var equal = 0
            var total = 0
            var c = 0
            while c < W {
                let ia = (r * W + c) * 4
                let ib = (r * W + c) * 4
                let d = abs(Int(anchor.buffer.bytes[ia]) - Int(frame.buffer.bytes[ib]))
                    + abs(Int(anchor.buffer.bytes[ia + 1]) - Int(frame.buffer.bytes[ib + 1]))
                    + abs(Int(anchor.buffer.bytes[ia + 2]) - Int(frame.buffer.bytes[ib + 2]))
                if d <= pixelTolerance { equal += 1 }
                total += 1
                c += colStep
            }
            guard total > 0, Double(equal) / Double(total) >= 0.95 else { break }
            if frame.distinctive[r] { distinctiveRows += 1 }
            count += 1
        }
        guard count >= 8 else { return 0 }
        return count
    }
}

// MARK: - Stitch builder

/// Accumulates frames of a fixed-size viewport into one tall image.
///
/// Bookkeeping model: every frame row r (outside sticky bands) maps to a
/// "document" coordinate `docOffset + r`. `docOffset` advances by the detected
/// scroll dy each frame, which gives correct de-dup when the user scrolls up
/// and back down. The canvas covers a document range ending at `accEnd`.
final class LongScreenshotBuilder {
    enum Event {
        case started
        case appended(Int)   // rows appended
        case noChange
        case scrolledUp
        case gap(Int)        // discontinuity; rows appended after a separator
        case skipped         // changed content during gap cooldown (animation…)
        case capped          // max height reached → caller should finish
    }

    static let separatorRows = 8

    let width: Int
    let maxRows: Int

    private let canvas: NSMutableData
    private(set) var accEnd = 0          // document coordinate of canvas bottom
    private(set) var docOffset = 0       // document coordinate of current frame row 0
    private var anchor: FrameData?
    private var anchorTime: CFTimeInterval = 0
    private var lastGapTime: CFTimeInterval = -10
    private(set) var stickyTop = 0
    private(set) var stickyBottom = 0
    private(set) var gapCount = 0
    private(set) var capped = false

    private static let anchorStaleness: CFTimeInterval = 1.5
    private static let gapCooldown: CFTimeInterval = 1.5

    /// Seam refinement: pixel-exact re-alignment of the append position against
    /// the canvas tail. Absorbs any drift from ambiguous dy detection (regions
    /// with runs of identical rows) so seams never slip, frame after frame.
    private static let seamSearchRadius = 12
    private static let seamContextRows = 24
    private static let seamMaxAvgDiff = 48.0

    private var endsWithSeparator = false

    var canvasRows: Int {
        let rb = width * 4
        return rb > 0 ? canvas.length / rb : 0
    }

    init(width: Int) {
        self.width = max(1, width)
        self.canvas = NSMutableData()
        // Cap total memory around 320 MB.
        self.maxRows = max(600, min(30_000, 320_000_000 / (self.width * 4)))
    }

    // MARK: Processing

    func process(frame: FrameData, at time: CFTimeInterval) -> Event {
        guard frame.width == width else { return .skipped }
        let H = frame.height

        guard let anchorFrame = anchor else {
            canvas.setData(Data(frame.buffer.bytes))
            accEnd = H
            docOffset = 0
            anchor = frame
            anchorTime = time
            return .started
        }

        let result = ScrollDetector.detect(anchor: anchorFrame, frame: frame)

        switch result {
        case .noChange:
            if time - anchorTime > LongScreenshotBuilder.anchorStaleness {
                anchor = frame
                anchorTime = time
            }
            return .noChange

        case .scrolled(let dy, let topSticky, let bottomSticky):
            if dy < 0 {
                // Scrolled back up: nothing to append; doc bookkeeping keeps
                // de-dup correct when the user scrolls down again.
                docOffset += dy
                anchor = frame
                anchorTime = time
                return .scrolledUp
            }

            docOffset += dy

            if topSticky >= 8 {
                stickyTop = max(stickyTop, min(topSticky, H / 3))
            }
            if bottomSticky >= 8 {
                let newBottom = min(bottomSticky, H / 3)
                if newBottom > stickyBottom {
                    // The first frame included what turned out to be a fixed
                    // footer; trim it off the canvas so it doesn't end up in
                    // the middle of the stitched image.
                    if canvasRows >= newBottom && footerMatches(frame, band: newBottom) {
                        canvas.replaceBytes(in: NSRange(location: canvas.length - newBottom * width * 4, length: newBottom * width * 4), withBytes: nil, length: 0)
                        accEnd -= newBottom
                    }
                    stickyBottom = newBottom
                }
            }

            let e = H - stickyBottom
            var s = max(stickyTop, accEnd - docOffset)

            if docOffset + stickyTop > accEnd {
                // Content jumped past everything we have (shouldn't normally
                // happen when alignment succeeded) — stitch with a separator.
                appendSeparator()
                s = stickyTop
                docOffset = accEnd - s
                gapCount += 1
                lastGapTime = time
                appendRows(frame, from: s, to: e)
                accEnd = docOffset + e
                anchor = frame
                anchorTime = time
                return .gap(max(e - s, 0))
            }

            guard s < e else {
                anchor = frame
                anchorTime = time
                return .noChange
            }

            // Pixel-exact seam: find where the frame actually continues the
            // canvas tail, then rebase docOffset so drift cannot accumulate.
            if !endsWithSeparator {
                let refined = refineSeam(frame, estimate: s, end: e)
                s = refined
                docOffset = accEnd - s
            }

            appendRows(frame, from: s, to: e)
            accEnd = docOffset + e
            anchor = frame
            anchorTime = time
            endsWithSeparator = false

            if canvasRows >= maxRows {
                capped = true
                return .capped
            }
            return .appended(e - s)

        case .unknown:
            if ScrollDetector.framesSimilar(anchorFrame, frame) {
                if time - anchorTime > LongScreenshotBuilder.anchorStaleness {
                    anchor = frame
                    anchorTime = time
                }
                return .noChange
            }
            if time - lastGapTime < LongScreenshotBuilder.gapCooldown {
                // Likely animated content (video, lazy images). Re-anchor
                // without inserting a separator.
                anchor = frame
                anchorTime = time
                return .skipped
            }
            // Fast fling lost all overlap: append what we see behind a separator.
            appendSeparator()
            let s = stickyTop
            let e = H - stickyBottom
            if e > s {
                appendRows(frame, from: s, to: e)
                docOffset = accEnd - s
                accEnd = docOffset + e
            }
            gapCount += 1
            lastGapTime = time
            anchor = frame
            anchorTime = time
            return .gap(max(e - s, 0))
        }
    }

    /// Final image: canvas plus, if a fixed footer was detected, one clean copy
    /// of it at the very bottom.
    func finish(with lastFrame: FrameData?) -> CGImage? {
        if let frame = lastFrame, stickyBottom > 0, frame.width == width {
            let H = frame.height
            let from = H - stickyBottom
            if from >= 0 {
                appendRows(frame, from: from, to: H)
            }
        }
        return makeImage()
    }

    func makeImage() -> CGImage? {
        let h = canvasRows
        guard h > 0 else { return nil }
        guard let provider = CGDataProvider(data: canvas as CFData) else { return nil }
        return CGImage(
            width: width,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Small preview image. Rendered immediately (on the caller's queue) so the
    /// returned image owns its bytes and later canvas mutations are safe.
    func makePreviewImage(maxPixelWidth: Int) -> CGImage? {
        guard let full = makeImage() else { return nil }
        let w = full.width
        let h = full.height
        guard w > 0, h > 0 else { return nil }
        let targetW = min(maxPixelWidth, w)
        let targetH = max(1, Int(Double(h) * Double(targetW) / Double(w)))
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        // Image is huge compared to the preview — skip drawing if it would be
        // excessively expensive more than ~every refresh interval.
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage()
    }

    // MARK: Private

    private func appendRows(_ frame: FrameData, from: Int, to: Int) {
        guard from < to, from >= 0 else { return }
        let rowBytes = width * 4
        let start = from * rowBytes
        let count = (to - from) * rowBytes
        frame.buffer.bytes.withUnsafeBytes { raw in
            canvas.append(raw.baseAddress!.advanced(by: start), length: count)
        }
    }

    private func appendSeparator() {
        let rowBytes = width * 4
        var row = [UInt8](repeating: 255, count: rowBytes)
        let half = LongScreenshotBuilder.separatorRows / 2
        for _ in 0..<half {
            canvas.append(&row, length: rowBytes) // white
        }
        for i in 0..<rowBytes {
            row[i] = (i % 4 == 3) ? 255 : 225    // light gray, opaque
        }
        for _ in 0..<(LongScreenshotBuilder.separatorRows - half) {
            canvas.append(&row, length: rowBytes)
        }
    }

    /// Find the frame row that pixel-exactly continues the canvas tail, searching
    /// around the bookkeeping estimate. Returns the estimate unchanged when no
    /// candidate correlates well (e.g. the content genuinely changed).
    private func refineSeam(_ frame: FrameData, estimate s: Int, end e: Int) -> Int {
        let N = min(LongScreenshotBuilder.seamContextRows, canvasRows)
        guard N >= 12, frame.height > 0 else { return s }
        let colStep = max(1, width / 64)
        let rows = canvasRows
        let canvasBytes = UnsafeRawPointer(canvas.bytes)
        let frameBytes = frame.buffer.bytes
        let frameH = frame.height

        let lo = max(0, s - LongScreenshotBuilder.seamSearchRadius)
        let hi = min(e, s + LongScreenshotBuilder.seamSearchRadius)
        guard lo <= hi else { return s }

        var bestS = s
        var bestScore = Int64.max
        for cand in lo...hi {
            guard cand - N >= 0, cand <= frameH else { continue }
            var score: Int64 = 0
            var count = 0
            for i in 0..<N {
                let cr = (rows - N + i) * width * 4
                let fr = (cand - N + i) * width * 4
                var c = 0
                while c < width {
                    let cc = cr + c * 4
                    let ff = fr + c * 4
                    score &+= Int64(abs(Int(canvasBytes.load(fromByteOffset: cc, as: UInt8.self)) - Int(frameBytes[ff])))
                    score &+= Int64(abs(Int(canvasBytes.load(fromByteOffset: cc + 1, as: UInt8.self)) - Int(frameBytes[ff + 1])))
                    score &+= Int64(abs(Int(canvasBytes.load(fromByteOffset: cc + 2, as: UInt8.self)) - Int(frameBytes[ff + 2])))
                    count += 3
                    c += colStep
                }
            }
            guard count > 0 else { continue }
            let avg = Double(score) / Double(count)
            // Strictly better keeps the smaller offset on ties (no duplicates).
            if score < bestScore, avg < LongScreenshotBuilder.seamMaxAvgDiff {
                bestScore = score
                bestS = cand
            }
        }
        return bestS
    }

    /// Does the bottom `band` rows of the canvas match the frame's fixed footer?
    private func footerMatches(_ frame: FrameData, band: Int) -> Bool {
        let rows = canvasRows
        guard rows >= band, frame.height >= band else { return false }
        let W = width
        let frameH = frame.height
        let colStep = max(1, W / 64)
        var equal = 0
        var total = 0
        let canvasBytes = UnsafeRawPointer(canvas.bytes)
        for i in 0..<band {
            let canvasRow = rows - band + i
            let frameRow = frameH - band + i
            var c = 0
            while c < W {
                let ic = canvasRow * W * 4 + c * 4
                let ifr = frameRow * W * 4 + c * 4
                let d = abs(Int(canvasBytes.load(fromByteOffset: ic, as: UInt8.self)) - Int(frame.buffer.bytes[ifr]))
                    + abs(Int(canvasBytes.load(fromByteOffset: ic + 1, as: UInt8.self)) - Int(frame.buffer.bytes[ifr + 1]))
                    + abs(Int(canvasBytes.load(fromByteOffset: ic + 2, as: UInt8.self)) - Int(frame.buffer.bytes[ifr + 2]))
                if d <= ScrollDetector.pixelTolerance { equal += 1 }
                total += 1
                c += colStep
            }
        }
        guard total > 0 else { return false }
        return Double(equal) / Double(total) >= 0.90
    }
}
