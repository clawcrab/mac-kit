import Foundation
import ImageIO
import Vision

// MARK: - OCR (Vision framework, fully on-device)

let defaultOCRLanguages = ["zh-Hans", "en-US"]

/// Load a raster image (PNG/JPEG/HEIC/TIFF/...) via ImageIO. CGImageSource
/// handles HEIC natively, unlike NSImage-free CGImage(pngDataProvider:) paths.
private func loadCGImage(path: String) throws -> CGImage {
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else {
        throw ToolError("File not found: \(expanded)")
    }
    let url = URL(fileURLWithPath: expanded) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else {
        throw ToolError("Could not open \(expanded) as an image (unreadable or not a supported format)")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ToolError("Could not decode image data in \(expanded) — supported formats: PNG, JPEG, HEIC, TIFF, GIF, BMP")
    }
    return image
}

func ocrText(path: String, languages: [String]) throws -> String {
    let image = try loadCGImage(path: path)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // Use the newest text-recognition model this OS supports (revision 3 on
    // macOS 13 adds proper Chinese/Japanese/Korean support).
    if let latest = VNRecognizeTextRequest.supportedRevisions.max() {
        request.revision = latest
    }
    // automaticallyDetectsLanguage lets newer OSes pick scripts on their own,
    // but detection is unreliable on short or mixed-script text, so we still
    // seed recognitionLanguages explicitly — this guarantees the CJK model is
    // loaded for zh-Hans+en-US content either way.
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = languages

    let handler = VNImageRequestHandler(cgImage: image)
    do {
        try handler.perform([request])
    } catch {
        throw ToolError("Vision text recognition failed: \(error.localizedDescription)")
    }

    let observations = request.results ?? []
    struct Line {
        let text: String
        let confidence: Float
        let box: CGRect
    }
    let lines: [Line] = observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return Line(text: candidate.string, confidence: candidate.confidence, box: observation.boundingBox)
    }
    if lines.isEmpty {
        return "No text found in \(path)."
    }

    // Reading order: Vision's boundingBox is normalized with origin at the
    // bottom-left, so larger midY = higher on the page. Bucket observations
    // into visual rows top-to-bottom, then sort each row left-to-right.
    let topToBottom = lines.sorted { $0.box.midY > $1.box.midY }
    var rows: [[Line]] = []
    for line in topToBottom {
        if let reference = rows.last?.first,
           abs(line.box.midY - reference.box.midY) < max(line.box.height, reference.box.height) / 2 {
            rows[rows.count - 1].append(line)
        } else {
            rows.append([line])
        }
    }
    let ordered = rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }

    return ordered
        .map { String(format: "%@  [confidence %.2f]", $0.text, $0.confidence) }
        .joined(separator: "\n")
}
