import CoreGraphics
import Foundation

/// GIF 编解码内核（不依赖任何 UI）。
///
/// 只做两件事：
/// 1. **量化**：BGRA → ≤256 色的索引像素 + 局部调色板（中位切分，不做抖动）；
/// 2. **写出**：GIF89a 文件（每帧整幅替换 + 局部调色板 + LZW）。
///
/// 为什么不用 ImageIO 直接写：ImageIO 每帧都要我们给一张 24 位图，它会自己重新量化，
/// 调色板与延迟都不受控（延迟还会被部分播放器钳到 100ms）。自己写可以精确控制
/// 每帧调色板与 centisecond 延迟，且播放页可以直接把索引像素画出来，省掉解压步骤。
enum GifCodec {

    // MARK: - 量化（中位切分）

    /// BGRA（每像素 4 字节，alpha 忽略）→ 索引像素 + 调色板。
    /// - 直方图：RGB 各取高 5 位 → 32768 个桶，桶内累计 样本数 / Σr / Σg / Σb；
    /// - 反复挑「样本数最多且桶数 ≥ 2」的盒子，沿跨度最大通道按样本数中位切分；
    /// - 每个桶切分时就已归属某个盒子，所以映射不需要最近邻搜索（这是能跑到 24fps 的关键）。
    static func quantize(bgra: [UInt8], width: Int, height: Int, maxColors: Int = 256)
        -> (indices: [UInt8], palette: [UInt32], minCodeSize: Int) {
        let pixelCount = width * height
        guard pixelCount > 0, bgra.count >= pixelCount * 4 else {
            return ([], [0], 2)
        }

        let bucketTotal = 32768
        var counts = [Int32](repeating: 0, count: bucketTotal)
        var sumR = [Int32](repeating: 0, count: bucketTotal)
        var sumG = [Int32](repeating: 0, count: bucketTotal)
        var sumB = [Int32](repeating: 0, count: bucketTotal)

        bgra.withUnsafeBufferPointer { buf in
            counts.withUnsafeMutableBufferPointer { c in
                sumR.withUnsafeMutableBufferPointer { sr in
                    sumG.withUnsafeMutableBufferPointer { sg in
                        sumB.withUnsafeMutableBufferPointer { sb in
                            var i = 0
                            for _ in 0..<pixelCount {
                                let b = Int(buf[i]) >> 3
                                let g = Int(buf[i + 1]) >> 3
                                let r = Int(buf[i + 2]) >> 3
                                let idx = (r << 10) | (g << 5) | b
                                c[idx] += 1
                                sr[idx] += Int32(buf[i + 2])
                                sg[idx] += Int32(buf[i + 1])
                                sb[idx] += Int32(buf[i])
                                i += 4
                            }
                        }
                    }
                }
            }
        }

        var nonEmpty: [Int] = []
        nonEmpty.reserveCapacity(1024)
        for i in 0..<bucketTotal where counts[i] > 0 { nonEmpty.append(i) }

        // 纯色画面：只有一个桶，直接用。
        if nonEmpty.count <= maxColors {
            var palette = [UInt32]()
            palette.reserveCapacity(nonEmpty.count)
            for b in nonEmpty {
                palette.append(Self.averageColor(b, counts: counts, r: sumR, g: sumG, b: sumB))
            }
            var lut = [UInt8](repeating: 0, count: bucketTotal)
            for (i, b) in nonEmpty.enumerated() { lut[b] = UInt8(i) }
            let bits = Self.bitsForColorCount(max(2, palette.count))
            let indices = Self.mapIndices(bgra: bgra, pixelCount: pixelCount, lut: lut)
            return (indices, Self.padded(palette, bits: bits), bits)
        }

        // 盒子 = 一组桶。逐个切分到 maxColors 个盒子。
        var boxes: [(buckets: [Int], total: Int32)] = [(nonEmpty, Int32(pixelCount))]
        while boxes.count < maxColors {
            // 选「样本数最多、且至少有两个桶」的盒子
            var pick: Int?
            var bestTotal: Int32 = -1
            for (i, box) in boxes.enumerated() where box.buckets.count > 1 {
                if box.total > bestTotal {
                    bestTotal = box.total
                    pick = i
                }
            }
            guard let index = pick else { break }

            let box = boxes[index]
            // 找跨度最大的通道
            var minR = 31, maxR = 0, minG = 31, maxG = 0, minB = 31, maxB = 0
            for b in box.buckets {
                let r = (b >> 10) & 31
                let g = (b >> 5) & 31
                let bl = b & 31
                if r < minR { minR = r }; if r > maxR { maxR = r }
                if g < minG { minG = g }; if g > maxG { maxG = g }
                if bl < minB { minB = bl }; if bl > maxB { maxB = bl }
            }
            let spanR = maxR - minR, spanG = maxG - minG, spanB = maxB - minB
            let shift: Int = (spanR >= spanG && spanR >= spanB) ? 10 : (spanG >= spanB ? 5 : 0)
            let sorted = box.buckets.sorted { a, b in ((a >> shift) & 31) < ((b >> shift) & 31) }

            // 按样本数中位切分（保证两侧都非空）
            let half = box.total / 2
            var acc: Int32 = 0
            var split = 1
            for (i, b) in sorted.enumerated() {
                acc += counts[b]
                if acc >= half {
                    split = i + 1
                    break
                }
            }
            if split <= 0 { split = 1 }
            if split >= sorted.count { split = sorted.count - 1 }

            let left = Array(sorted[0..<split])
            let right = Array(sorted[split...])
            let leftTotal = left.reduce(Int32(0)) { $0 + counts[$1] }
            let rightTotal = right.reduce(Int32(0)) { $0 + counts[$1] }
            boxes[index] = (left, leftTotal)
            boxes.append((right, rightTotal))
        }

        // 每个盒子出一个调色板色；桶 → 盒子序号直接当索引。
        var palette = [UInt32]()
        palette.reserveCapacity(boxes.count)
        var lut = [UInt8](repeating: 0, count: bucketTotal)
        for (i, box) in boxes.enumerated() {
            var nr = 0, ng = 0, nb = 0
            for b in box.buckets {
                nr += Int(sumR[b]); ng += Int(sumG[b]); nb += Int(sumB[b])
            }
            let n = max(Int(box.total), 1)
            palette.append(UInt32((nr / n) << 16 | (ng / n) << 8 | (nb / n)))
            let index = UInt8(i)
            for b in box.buckets { lut[b] = index }
        }

        let bits = Self.bitsForColorCount(max(2, palette.count))
        let indices = Self.mapIndices(bgra: bgra, pixelCount: pixelCount, lut: lut)
        return (indices, Self.padded(palette, bits: bits), bits)
    }

    /// CGImage → 量化（动图页签上叠了标注的帧要重新量化时用）。
    /// 渲染到 BGRA 缓冲后复用上面那条快路径。
    static func quantize(image: CGImage, width: Int, height: Int, maxColors: Int = 256)
        -> (indices: [UInt8], palette: [UInt32], minCodeSize: Int)? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return quantize(bgra: bytes, width: width, height: height, maxColors: maxColors)
    }

    private static func averageColor(_ bucket: Int, counts: [Int32], r: [Int32], g: [Int32], b: [Int32]) -> UInt32 {
        let n = max(Int(counts[bucket]), 1)
        let rr = Int(r[bucket]) / n
        let gg = Int(g[bucket]) / n
        let bb = Int(b[bucket]) / n
        return UInt32(rr << 16 | gg << 8 | bb)
    }

    private static func mapIndices(bgra: [UInt8], pixelCount: Int, lut: [UInt8]) -> [UInt8] {
        var indices = [UInt8](repeating: 0, count: pixelCount)
        bgra.withUnsafeBufferPointer { src in
            indices.withUnsafeMutableBufferPointer { dst in
                lut.withUnsafeBufferPointer { table in
                    var i = 0
                    for p in 0..<pixelCount {
                        let b = Int(src[i]) >> 3
                        let g = Int(src[i + 1]) >> 3
                        let r = Int(src[i + 2]) >> 3
                        dst[p] = table[(r << 10) | (g << 5) | b]
                        i += 4
                    }
                }
            }
        }
        return indices
    }

    /// 调色板长度 = 2 的幂，且至少 4 色（minCodeSize 最小 2）。
    static func bitsForColorCount(_ count: Int) -> Int {
        var bits = 2
        while (1 << bits) < count, bits < 8 { bits += 1 }
        return bits
    }

    private static func padded(_ palette: [UInt32], bits: Int) -> [UInt32] {
        let target = 1 << bits
        if palette.count == target { return palette }
        var out = palette
        if out.count > target { out = Array(out.prefix(target)) }
        while out.count < target { out.append(0) }
        return out
    }

    // MARK: - LZW

    /// 索引像素 → GIF 图像数据块（minCodeSize + ≤255 字节分块 + 结束 0）。
    ///
    /// ★ 最容易写错的是**码长升位点**：
    /// - 编码端：每插入一个新码、nextCode 自增后，判断 `nextCode == (1 << codeSize) + 1` 才升位；
    /// - 解码端：每新增一项、next 自增后，判断 `next == (1 << codeSize)` 才升位。
    /// 编码端比解码端早一步（字典领先一项），所以阈值差 1。写错一位 → 自己的解码器"自洽"，
    /// 但系统解码器全部解错（前几百像素正常、之后错位）。
    static func lzwCompress(indices: [UInt8], minCodeSize: Int) -> [UInt8] {
        guard !indices.isEmpty else {
            return [UInt8(minCodeSize), 0]
        }
        let clearCode = 1 << minCodeSize
        let eoiCode = clearCode + 1
        var codeSize = minCodeSize + 1
        var nextCode = eoiCode + 1

        var out = [UInt8]()
        out.reserveCapacity(indices.count / 2 + 64)
        out.append(UInt8(minCodeSize))

        var block = [UInt8]()
        block.reserveCapacity(255)
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        func flushBlock() {
            guard !block.isEmpty else { return }
            out.append(UInt8(block.count))
            out.append(contentsOf: block)
            block.removeAll(keepingCapacity: true)
        }

        func putByte(_ byte: UInt8) {
            block.append(byte)
            if block.count == 255 { flushBlock() }
        }

        func emit(_ code: Int) {
            bitBuffer |= UInt32(code) << UInt32(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                putByte(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        var dict = [Int: Int](minimumCapacity: 4096)
        emit(clearCode)

        var prefix = Int(indices[0])
        if indices.count > 1 {
            for i in 1..<indices.count {
                let c = Int(indices[i])
                let key = (prefix << 8) | c
                if let code = dict[key] {
                    prefix = code
                    continue
                }
                emit(prefix)
                if nextCode < 4096 {
                    dict[key] = nextCode
                    nextCode += 1
                    if nextCode == (1 << codeSize) + 1, codeSize < 12 {
                        codeSize += 1
                    }
                } else {
                    emit(clearCode)
                    dict.removeAll(keepingCapacity: true)
                    codeSize = minCodeSize + 1
                    nextCode = eoiCode + 1
                }
                prefix = c
            }
        }
        emit(prefix)
        emit(eoiCode)

        while bitCount > 0 {
            putByte(UInt8(bitBuffer & 0xFF))
            bitBuffer >>= 8
            bitCount -= 8
        }
        flushBlock()
        out.append(0)   // 块终止符
        return out
    }

    // MARK: - GIF89a 写出

    /// 写整段 GIF89a。每帧都是整幅替换（disposal=1 + 局部调色板 + 全画幅），不做帧间差分。
    static func encode(_ anim: GifAnimation) -> Data {
        var data = Data()
        guard anim.width > 0, anim.height > 0, !anim.frames.isEmpty else { return data }

        data.append(contentsOf: Array("GIF89a".utf8))

        // 逻辑屏描述符：packed = 0xF7（有全局色表 / 256 色 / 色深 8）
        appendUInt16(&data, anim.width)
        appendUInt16(&data, anim.height)
        data.append(0xF7)
        data.append(0)      // 背景色索引
        data.append(0)      // 像素宽高比

        // 全局调色板 256×3：用第一帧调色板兜底，只为兼容老解码器。
        var global = [UInt32](repeating: 0, count: 256)
        let first = anim.frames[0].palette
        for i in 0..<min(first.count, 256) { global[i] = first[i] }
        for color in global {
            data.append(UInt8((color >> 16) & 0xFF))
            data.append(UInt8((color >> 8) & 0xFF))
            data.append(UInt8(color & 0xFF))
        }

        if anim.loop {
            // NETSCAPE2.0 扩展块，循环次数 0 = 无限
            data.append(contentsOf: [0x21, 0xFF, 0x0B])
            data.append(contentsOf: Array("NETSCAPE2.0".utf8))
            data.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        }

        for frame in anim.frames {
            // 图形控制块：disposal=1（留在原位）、无透明
            let delay = max(2, Int((Double(frame.delayMs) / 10.0).rounded()))
            data.append(contentsOf: [0x21, 0xF9, 0x04, 0x04])
            appendUInt16(&data, min(delay, 65535))
            data.append(0)      // 透明色索引
            data.append(0)

            // 图像描述符：整幅画、带局部调色板
            data.append(0x2C)
            appendUInt16(&data, 0)
            appendUInt16(&data, 0)
            appendUInt16(&data, anim.width)
            appendUInt16(&data, anim.height)
            data.append(UInt8(0x80 | max(0, min(7, frame.minCodeSize - 1))))

            // 局部调色板
            let count = 1 << frame.minCodeSize
            for i in 0..<count {
                let color = i < frame.palette.count ? frame.palette[i] : 0
                data.append(UInt8((color >> 16) & 0xFF))
                data.append(UInt8((color >> 8) & 0xFF))
                data.append(UInt8(color & 0xFF))
            }

            data.append(contentsOf: lzwCompress(indices: frame.indices, minCodeSize: frame.minCodeSize))
        }

        data.append(0x3B)   // trailer
        return data
    }

    private static func appendUInt16(_ data: inout Data, _ value: Int) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}
