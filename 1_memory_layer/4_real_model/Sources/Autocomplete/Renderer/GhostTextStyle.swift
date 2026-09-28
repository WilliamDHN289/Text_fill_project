import AppKit

enum GhostTextStyle: String, CaseIterable {
    case gray
    case sunset
    case lavender
    case polar
    case chrome

    var displayName: String {
        switch self {
        case .gray: return "Gray"
        case .polar: return "Polar"
        case .sunset: return "Sunset"
        case .chrome: return "Chrome"
        case .lavender: return "Lavender"
        }
    }

    private struct ColorStop {
        let position: CGFloat
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
    }

    private var gradientStops: [ColorStop] {
        switch self {
        case .gray:
            return []
        case .polar:
            return [
                ColorStop(position: 0.0,  r: 40/255,  g: 180/255, b: 175/255), // teal
                ColorStop(position: 0.33, r: 60/255,  g: 140/255, b: 210/255), // blue
                ColorStop(position: 0.66, r: 140/255, g: 100/255, b: 200/255), // purple
                ColorStop(position: 1.0,  r: 200/255, g: 80/255,  b: 130/255), // rose
            ]
        case .sunset:
            return [
                ColorStop(position: 0.0,  r: 200/255, g: 160/255, b: 40/255),  // gold
                ColorStop(position: 0.25, r: 210/255, g: 130/255, b: 30/255),  // amber
                ColorStop(position: 0.5,  r: 200/255, g: 75/255,  b: 50/255),  // coral
                ColorStop(position: 0.75, r: 180/255, g: 30/255,  b: 30/255),  // red
                ColorStop(position: 1.0,  r: 185/255, g: 40/255,  b: 110/255), // magenta
            ]
        case .chrome:
            return [
                ColorStop(position: 0.0,  r: 140/255, g: 140/255, b: 140/255), // mid gray
                ColorStop(position: 0.2,  r: 100/255, g: 100/255, b: 100/255), // dark gray
                ColorStop(position: 0.4,  r: 130/255, g: 130/255, b: 130/255), // light gray
                ColorStop(position: 0.6,  r: 85/255,  g: 85/255,  b: 85/255),  // darker gray
                ColorStop(position: 0.8,  r: 120/255, g: 120/255, b: 120/255), // medium
                ColorStop(position: 1.0,  r: 95/255,  g: 95/255,  b: 95/255),  // steel
            ]
        case .lavender:
            return [
                ColorStop(position: 0.0, r: 50/255,  g: 140/255, b: 210/255), // blue
                ColorStop(position: 0.5, r: 140/255, g: 80/255,  b: 200/255), // purple
                ColorStop(position: 1.0, r: 200/255, g: 70/255,  b: 140/255), // pink
            ]
        }
    }

    func color(at progress: CGFloat) -> NSColor {
        if self == .gray {
            return NSColor.systemGray.withAlphaComponent(0.8)
        }

        let stops = gradientStops
        let t = max(0, min(1, progress))

        for i in 0..<stops.count - 1 {
            let s0 = stops[i]
            let s1 = stops[i + 1]
            if t <= s1.position {
                let localT = (t - s0.position) / (s1.position - s0.position)
                let r = s0.r + (s1.r - s0.r) * localT
                let g = s0.g + (s1.g - s0.g) * localT
                let b = s0.b + (s1.b - s0.b) * localT
                return NSColor(red: r, green: g, blue: b, alpha: 1.0)
            }
        }
        let last = stops.last!
        return NSColor(red: last.r, green: last.g, blue: last.b, alpha: 1.0)
    }

    static var current: GhostTextStyle {
        let raw = UserDefaults.standard.string(forKey: "autocomplete.ghostTextStyle") ?? "gray"
        return GhostTextStyle(rawValue: raw) ?? .gray
    }
}
