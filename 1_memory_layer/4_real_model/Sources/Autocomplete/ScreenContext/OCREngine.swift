import Vision
import CoreGraphics
import CoreImage

/// One recognized text line plus its position. `bbox` is normalized 0–1
/// with top-left origin (Vision's native bottom-left origin is flipped at
/// the OCREngine boundary so downstream attribution code can read it in
/// familiar UI coordinates).
struct OCRLine {
    let text: String
    let bbox: CGRect
    /// WeChat SPIKE only: whether this line sits on a green (self) bubble, set by
    /// ScreenContextManager via pixel sampling of the screenshot. nil = unsampled
    /// (non-WeChat) → Attribution falls back to geometry.
    var bubbleIsGreen: Bool? = nil
}

enum OCREngine {
    /// Recognize text in the image as structured lines sorted top-to-bottom.
    /// Each line is per-line-normalized (whitespace collapsed); empty lines dropped.
    /// Automatically inverts dark-background images for better OCR accuracy.
    static func recognizeLines(in image: CGImage) async -> [OCRLine] {
        await Task.detached(priority: .userInitiated) {
            performOCR(on: image)
        }.value
    }

    /// Convenience: lines joined with `\n`. Preserved for callers that don't need bbox.
    static func recognizeText(in image: CGImage) async -> String {
        let lines = await recognizeLines(in: image)
        return lines.map { $0.text }.joined(separator: "\n")
    }

    private static func performOCR(on image: CGImage) -> [OCRLine] {
        let ocrImage = isDarkBackground(image) ? (invertColors(image) ?? image) : image

        var lines: [OCRLine] = []
        let request = VNRecognizeTextRequest { req, err in
            if let err = err {
                Log.error("OCR request failed: \(err)")
                return
            }
            guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
            // Vision returns bbox in normalized 0–1 with bottom-left origin.
            // Flip Y to top-left, normalize the text, and sort top-to-bottom.
            let candidates: [OCRLine] = obs.compactMap { ob in
                guard let raw = ob.topCandidates(1).first?.string else { return nil }
                let normalized = TextNormalize.collapseToSingleLine(raw)
                guard !normalized.isEmpty else { return nil }
                let v = ob.boundingBox
                let flipped = CGRect(x: v.origin.x, y: 1 - v.origin.y - v.height,
                                     width: v.width, height: v.height)
                return OCRLine(text: normalized, bbox: flipped)
            }
            lines = candidates.sorted { $0.bbox.minY < $1.bbox.minY }
            let totalChars = lines.reduce(0) { $0 + $1.text.count }
            Log.debug("OCR recognized \(lines.count) lines, \(totalChars) chars total")
        }
        request.recognitionLevel = .accurate
        // Chinese must be first per Apple docs; English can be paired with it
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.0

        do {
            let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
            try handler.perform([request])
        } catch {
            Log.error("OCR perform failed: \(error)")
            return []
        }
        return lines
    }

    /// Check if the image has a predominantly dark background by sampling corner pixels.
    private static func isDarkBackground(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }

        let bpp = image.bitsPerPixel / 8
        let bpr = image.bytesPerRow
        guard bpp >= 3 else { return false }

        // Sample a few pixels from the top-left area
        var totalBrightness: CGFloat = 0
        let sampleCount = 4
        let positions: [(Int, Int)] = [(5, 5), (20, 5), (5, 20), (20, 20)]

        for (x, y) in positions {
            guard x < image.width, y < image.height else { continue }
            let offset = y * bpr + x * bpp
            let r = CGFloat(ptr[offset])
            let g = CGFloat(ptr[offset + 1])
            let b = CGFloat(ptr[offset + 2])
            totalBrightness += (r + g + b) / 3.0
        }

        let avgBrightness = totalBrightness / CGFloat(sampleCount)
        return avgBrightness < 80 // dark if average brightness < ~31%
    }

    /// Invert colors using CoreImage.
    private static func invertColors(_ image: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        return context.createCGImage(output, from: output.extent)
    }
}
