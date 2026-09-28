import CoreGraphics
import AppKit

enum ImageCropper {
    /// Crop the window image to the conversation area above the input band.
    /// `inputBandFrame` is the bounding box of the full input row (text field + buttons).
    /// `windowFrame` is in AX screen coordinates (top-left origin, points).
    static func cropAboveInput(image: CGImage, inputBandFrame: CGRect, windowFrame: CGRect) -> CGImage? {
        // Derive scale from actual image pixels vs window point dimensions
        let scale = CGFloat(image.width) / windowFrame.width

        // Convert input band frame from screen coords to window-relative coords
        let relativeX = inputBandFrame.origin.x - windowFrame.origin.x
        let relativeY = inputBandFrame.origin.y - windowFrame.origin.y
        // Height above the input band within the window
        let cropHeight = relativeY
        guard cropHeight > 10 else { return nil }

        // Use the input band's horizontal bounds to exclude sidebars
        let cropRect = CGRect(
            x: relativeX * scale,
            y: 0,
            width: inputBandFrame.width * scale,
            height: cropHeight * scale
        ).integral

        // Clamp to image bounds
        let clampedRect = cropRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clampedRect.isEmpty else { return nil }

        return image.cropping(to: clampedRect)
    }
}
