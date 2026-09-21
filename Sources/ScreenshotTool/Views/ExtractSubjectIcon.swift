import AppKit

/// 工具栏「提取矢量图」按钮的图标。
///
/// 图案来自仓库里的 `logo/提取矢量图-黑色-128.png`（虚线选框 + 人形主体，
/// 正好对应"把主体从画面里框出来抠掉"这个动作），**以 base64 内嵌在这里**。
///
/// 为什么不放进 `.app` 当普通资源文件：这个项目是 SwiftPM 可执行产物 + 手工组装的
/// `.app`，`Resources/` 里只有 Info.plist 和 AppIcon.icns，并不会被当成 bundle 资源
/// 拷进去。走 `Bundle.main` 找文件的话，本地直接跑 `swift build` 出来的二进制就会
/// 拿不到图标；走 SwiftPM 的 `Bundle.module` 又要在打包脚本里额外保证资源 bundle
/// 落在可执行文件旁边，找不到会直接 fatalError。内嵌几十行 base64 是最省事、
/// 也最不可能在打包环节丢图的做法。
///
/// 想换图：重新导出 PNG 覆盖 `logo/` 下同名文件，然后重跑
/// `tools/embed_extract_icon.py`（见仓库说明）即可，不要手改下面的 base64。
enum ExtractSubjectIcon {

    /// 工具栏按钮用。`pointSize` 对齐旁边那些 SF Symbol 的字号（13）。
    ///
    /// 拿不到图就返回 nil —— 调用方会退化成"只有文字没有图标"，
    /// 而不是整块空白或崩掉。
    static func toolbarImage(pointSize: CGFloat = 13) -> NSImage? {
        guard let data = Data(base64Encoded: embeddedPNG, options: .ignoreUnknownCharacters),
              let source = NSImage(data: data) else { return nil }

        // 画面上要显示的点尺寸（= 字号大小的方框，与位图无关）
        let side = pointSize + 2
        let image = NSImage(size: NSSize(width: side, height: side))
        image.isTemplate = true          // 黑色稿只当"遮罩"用，颜色交给系统按主题染
        for scale in [1, 2] {
            let pixels = Int((side * CGFloat(scale)).rounded())
            guard let rep = downscaled(source, to: pixels) else { continue }
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
        }
        return image.representations.isEmpty ? nil : image
    }

    /// 把原图缩到 `pixels` 见方。原稿是 128×128，缩到 15/30 像素时等于
    /// 做了 4~8 倍超采样，边缘比分两次缩放更干净。
    private static func downscaled(_ source: NSImage, to pixels: Int) -> NSBitmapImageRep? {
        guard pixels > 0, let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let output = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output)
    }

    /// `logo/提取矢量图-黑色-128.png` 的原样字节（base64）。
    private static let embeddedPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAA" +
        "DsMAAA7DAcdvqGQAAAlYSURBVHhe7V0tcOU2ED5YWHiwsLCweXbmFR48GFh4MPBgWGDhwcCDgQcPBgY+GHiwsLCdL1078lrW" +
        "SrZkr36+mW/m5vIkWdZaWu2uVu/eNTQ0NGzC+Xz++fr6+s+u6772ff+967offd//u8Su6/7u+/4LyvG6bMDv8HsqN6svkJeu" +
        "6z7zNpZwdXX1a9d1j5Z61hDv5nfexhL6vr/p+/5lKE/9Rx3fuq67xbPxMrvhfD7/dDqdPuGBLB315ROvlwPt9H3/bCm7lfe8" +
        "LY7z+fxL13X/WMpuoo8Q0LudlbUQAn2HZ+V1JAEGBNInfeUBvOFtmAh4EcE8n8/veXsmaEablYtAUfBXvl/Mqs4+bcLpdPpt" +
        "5YO5+BdvxwQ6ZSkTix95eybwdVnKbCZmFd6WCUztvIwvUTdmBF7nZtDgp5gOnesxpmpeJhalqRhfKi8Tg/iIeFsmMJ3zMqGE" +
        "3uKrY3khxXQIgYJg8bZM4O+8XCS+YDnj7ZnAUmcpF4POWQ+IpHheoimKG5U9K/GCeTs2xB4IfIHS1z8g0kCYfJIED6BZYPMS" +
        "hJ2D9JF5IWQGID0BAoMty52NoZJJ27FZPSt4Gzo1Qlew1BNMbJV53S4Y2+tv9D7XCgRmu6A+z9D3/QdLxSNJQG42N9QggsYC" +
        "dpEQhVxcdkTQ9m+iCGKKjDLFNAQDHxvNLj7K+QsvvwpYm7A3P9wS1TDCU1+48HINBYFmA+gKfOAHfuFlGgoDmc1ttovtSmBD" +
        "HiBT/edhFwblL6l5uKEwmHtebDf43xsKxoLVqykPNQAWJ8vgD3R6zRoKgGsLgZmB/76hMJihRxZ+579vKAyWQW8zQEGAQj8o" +
        "9jNvpEcAQnGKIFnO/hhY6l6Zoou4cWgaJyAJACRnUmuGwACTa/VRcJ7AhQ2X8T5BlolhGfyBz+NMULIABHrMONMGWSaGFFs4" +
        "enFLFQBa90J85jNS2NonXncOoHMFsz4NHANUShSA2GFkOepBgm2nXAEgbXfWj63MbTdUpQBI014EiieKtKA6AUh1dsHCLJxk" +
        "1QnAgjMrOqFYzowpClGVAMCYw587JX3PNByJ2gRgl6/fYJwo24SoRgAoDGqPtX9C7eHw1QgA4hX4M+9B7e8lRADe8z/m1NFU" +
        "+36J2u0C3gIAuNKvTH6oEIlzCLgoJno4EqECsPQViceoj8YBCuBA1YpgkADQoQKejOGiXdEBXOFsiVmOAAyAQkhBEl7n5zWg" +
        "7/sH3rmdWM4SkDMcy1dSalcCJb9IMQIgdTQhVTuGvANCcgdF/exuCMphmXSEhF20K/dBSJHDyEUp05cW0CwwyR2AZy/m6x9w" +
        "gDVQ9fRvgnZ4N6QrlZvGJ1FK2RlzcQdXh4Q5BSfMNUhUxJAZe0jzloPPmyNBMOiEyIbG2ywC0GhtmnSOHU7oG/BK8pglXOsn" +
        "LIP899qB1Ci8H1sYPfeuJtCFDLNOG513JnTWCkpnN5vVVnB7kkXNyD0gxAWKdVjrK/he3H7ZhpIFYAAZRODtlBIqIk8C0rCq" +
        "t/L5gvoOvQjGsnnfahAAE4bHE3w9M49/l5j5lPpmWwbfbmqpTQBqAQXLWg/HIgJsVGqbAJQJyTA27u6aAJQJ74CQJgBloglA" +
        "5WgCUDmaAFSOJgCVowlA5WgC4AC5v8dEkTl6PCU0ASBTqGEHX3R5M8IfgN/DiYQYuixjAKoUgCEAEoPnOvAaQrqQ+REvLKfE" +
        "kSECkH08AIWzed9uuoU4i5jDkuEtAICQLl5tVizy96cKAXMSs4JmD2KoACwdr1J5VwDNWvcLrs69qTKncJAAAKQwvc4E9GLR" +
        "MXVxcHTIIcr6HoukJ6iKog4WgBxAARyzzigiPhoVu4aiBICCG3ZR8iIQ4eOHz5wex+XeooI0gxQ93z28Fr4cHVAqJf/SrMCO" +
        "oPg9a1iTdpJecOh2cSkiOosDP2TUye3Ln5Bi7w67fmbYLbHnetCwRIk4MPtXbB6ejIF0KFyOdehzeMMitVlTez6hCeApO3KK" +
        "8NBec6XupBKw+ZuWNdi897ZwoT0l1r1U1GlWx0FKy8OCb/fL7YCC1v0lPvM+q4Cw1drl9nDpIENB1GWAkQwGe8UDVPD1v1Jd" +
        "jiENASHkiJq1XSpVOY6UCEDWBp9Q7jkLkFNoOBZ/mQX4HC0A2HbyNmvgHtnGHN7Tty3p0QJQmtHHl9hm83cRE1IK3dFErUAA" +
        "pKwdRRKDk9Lg5nGV3v+7uyMFQGq7AibbEnoHhEiDkFIAoJDw9irjA38nsZCFAOyd5VsbyV2cZDegXgDI3z9rrzbOsnZFQg4C" +
        "4Gy3IiYxtasXAA8ttQqmsgeoFwDHYZSqmOr9qheA1KndM2KSnYB6AajVAmhhkuN3OQiANWS5Ql74u4mBEAFwbsdUuS4bvOEt" +
        "AIDLIHP0CZeGdQgSAEqwYDtxqzuStWERQQIAUGgYztz/oIOYOiNYG7wQLAD4DxYcmscRogYrggTAERZe7k1ZhcPD0vpmghbC" +
        "wttSkCHoPKA1ImgSjCJlCUPWC155Qx5YsrZObDse5wLyOdjYMAOF3A/XyD/NlD/60WzgDSYxVTYogiswM3X0aoMCuBwzzRRc" +
        "AUgRtM0Cu54ObjgQpAzi0mUoDEgYed8Gv6GhoSEnYCYnMzDuOjgsQ1nDASB/jpnmB7kK1af7b4gAwfkTz5yPHUObWnTBcQx8" +
        "mAm223LIu2RuFbFbSHKoocEPlFdpMZrL4La4Q7ply+pZaoKwPzDwIdnTN+cG9kngRArHV0xHpIxMrmUbuDbIBMsOryuUvE5f" +
        "0Auf1efLtXGVQ4pXxGvQNI/rcVzX+1i5tv0Raxp1MSQJJaWQsVkp19LbwEUv3hYrGUzUY/XEWUCW2Shh81FM+YY7MSZFMzNl" +
        "Do0yAIxisGvCo2uiRh7rIqwogw8sBRZEoFN3cDmptpAiYpzClzBzmdO97hGgI5I+Gue7DQIdHoGfYNbYFkqnjnx0j7WU1kX+" +
        "+1jE4PC2TGDN52UC+ZTsNhB6uGhfhrQmphC6gZIyGlvvMejMFywd1Vsi4jql9xkNlNJ9k15AyRKdg0Da99L2czV9tkWp8hf5" +
        "5AOAkszLOfiCJVpa0pIA0koh5T7GiJF0+MQrNUrsewJpB+IUvAGxNHGDovIJkGve9YFhV3QvLWO7g+2X7xYYfHUJTYsfLXWF" +
        "8NZX6EygT2TX4PV5E0K8Zl2m93hL29HX98p/swX/AWRocY148x2PAAAAAElFTkSuQmCC"
}
