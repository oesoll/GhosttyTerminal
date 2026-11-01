import Foundation

/// 터미널 색. 두 앱의 팔레트가 xterm.js 시절의 이름(background, foreground, cursor, cursorAccent,
/// selectionBackground, selectionForeground, black … brightWhite)을 그대로 쓰므로 그 이름으로 받는다.
///
/// 값은 `#rrggbb`, `#rgb`, `rgb(…)`, `rgba(…)`. Ghostty 설정은 색에 투명도를 받지 않으므로 바탕의
/// 알파는 `background-opacity`로 옮긴다(Fine의 홈 장면 위 탭은 바탕이 비어 있다).
public struct GhosttyTheme: Hashable, Sendable {
    public var colors: [String: String]
    /// 팔레트가 닿지 않는 truecolor 글자(Codex의 문법 강조)를 읽히게 끌어올리는 대비(1이면 끈다).
    public var minimumContrast: Double

    public init(colors: [String: String], minimumContrast: Double = 1) {
        self.colors = colors
        self.minimumContrast = minimumContrast
    }

    /// 앱이 아직 테마를 주지 않았을 때(런타임 생성) 쓰는 중립 다크.
    public static let fallback = GhosttyTheme(colors: [
        "background": "#1e1e1e",
        "foreground": "#e4e4e6",
    ])

    /// 바탕이 어두운가(바탕색의 상대 휘도 0.4 미만). 바탕을 모르면 어둡다고 본다.
    public var isDark: Bool {
        guard let color = colors["background"].flatMap(Self.parse) else { return true }
        let luminance = (0.2126 * Double(color.red) + 0.7152 * Double(color.green) + 0.0722 * Double(color.blue)) / 255
        return luminance < 0.4
    }

    static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                            "brightBlack", "brightRed", "brightGreen", "brightYellow",
                            "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]

    /// Ghostty 설정 줄로 옮긴 색. 읽지 못한 값은 빼서 Ghostty 기본값에 맡긴다.
    var configLines: [String] {
        var lines: [String] = []
        if let background = colors["background"].flatMap(Self.parse) {
            lines.append("background = \(background.hex)")
            if background.alpha < 1 {
                lines.append("background-opacity = \(Self.format(background.alpha))")
            }
        }
        let pairs = [("foreground", "foreground"), ("cursor", "cursor-color"), ("cursorAccent", "cursor-text"),
                     ("selectionBackground", "selection-background"),
                     ("selectionForeground", "selection-foreground")]
        for (name, key) in pairs {
            if let color = colors[name].flatMap(Self.parse) { lines.append("\(key) = \(color.hex)") }
        }
        for (index, name) in Self.ansiNames.enumerated() {
            if let color = colors[name].flatMap(Self.parse) { lines.append("palette = \(index)=\(color.hex)") }
        }
        lines.append("minimum-contrast = \(Self.format(minimumContrast))")
        return lines
    }

    struct Color: Equatable {
        var red: Int, green: Int, blue: Int
        var alpha: Double
        var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    static func parse(_ text: String) -> Color? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let number = Int(digits, radix: 16) else { return nil }
            return Color(red: number >> 16 & 0xff, green: number >> 8 & 0xff, blue: number & 0xff, alpha: 1)
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")"),
              value.hasPrefix("rgb") else { return nil }
        let parts = value[value.index(after: open)..<value.index(before: value.endIndex)]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4,
              let red = Int(parts[0]), let green = Int(parts[1]), let blue = Int(parts[2]) else { return nil }
        let alpha = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
        return Color(red: red, green: green, blue: blue, alpha: min(max(alpha, 0), 1))
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
