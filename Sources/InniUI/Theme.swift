import SwiftUI

/// Nord palette (nordtheme.com), shared with Kveikur: dark only, frost accent, monospaced lists.
public enum Nord {
    public static let n0 = Color(hex: 0x2E3440)
    public static let n1 = Color(hex: 0x3B4252)
    public static let n2 = Color(hex: 0x434C5E)
    public static let n3 = Color(hex: 0x4C566A)
    public static let n4 = Color(hex: 0xD8DEE9)
    public static let n6 = Color(hex: 0xECEFF4)
    public static let n7 = Color(hex: 0x8FBCBB)
    public static let n8 = Color(hex: 0x88C0D0)
    public static let n9 = Color(hex: 0x81A1C1)
    public static let n10 = Color(hex: 0x5E81AC)
    public static let n11 = Color(hex: 0xBF616A)
    public static let n12 = Color(hex: 0xD08770)
    public static let n13 = Color(hex: 0xEBCB8B)
    public static let n14 = Color(hex: 0xA3BE8C)
    public static let n15 = Color(hex: 0xB48EAD)

    public static let background = n0
    public static let raised = n1
    public static let bar = Color(hex: 0x272C36)
    public static let separator = n2
    public static let text = n4
    public static let secondary = Color(hex: 0x7B88A1)
    public static let accent = n8
    public static let selection = n8
    public static let selectionText = n0
    public static let inactiveSelection = n2
    public static let folder = n8
    public static let filtered = n15

    public static let new = n9
    public static let learn = n12
    public static let review = n14

    public static func rating(_ r: Int) -> Color {
        switch r {
        case 1: return n11
        case 2: return n13
        case 3: return n14
        default: return n8
        }
    }

    public static func flag(_ f: Int) -> Color {
        switch f {
        case 1: return n11
        case 2: return n12
        case 3: return n14
        case 4: return n9
        case 5: return Color(hex: 0xE275AD)
        case 6: return n7
        case 7: return n15
        default: return .clear
        }
    }

    #if os(macOS)
    public static let listFont = Font.system(size: 12, design: .monospaced)
    public static let listBold = Font.system(size: 12, weight: .semibold, design: .monospaced)
    #else
    public static let listFont = Font.body
    public static let listBold = Font.body.weight(.semibold)
    #endif
    public static let mono = Font.system(size: 11, design: .monospaced)
}

extension Color {
    public init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The three due counts, coloured like Anki.
public struct CountsView: View {
    let counts: (Int, Int, Int)
    var highlight: Int? = nil

    public init(new: Int, learn: Int, review: Int, highlight: Int? = nil) {
        counts = (new, learn, review)
        self.highlight = highlight
    }

    public var body: some View {
        HStack(spacing: 6) {
            cell(counts.0, Nord.new, 0)
            cell(counts.1, Nord.learn, 1)
            cell(counts.2, Nord.review, 2)
        }
        .font(Nord.listFont.monospacedDigit())
    }

    private func cell(_ n: Int, _ c: Color, _ i: Int) -> some View {
        Text("\(n)")
            .foregroundStyle(n == 0 ? Nord.n3 : c)
            .fontWeight(highlight == i ? .bold : .regular)
            .underline(highlight == i)
            .frame(minWidth: 34, alignment: .trailing)
    }
}

/// yazi-style selection: a rounded pill behind the selected row.
struct PillBackground: View {
    var selected: Bool
    var active = true

    var body: some View {
        Capsule().fill(selected ? (active ? Nord.selection : Nord.inactiveSelection) : .clear)
    }
}

/// Rounded, softly filled button in one colour, used for study and rating actions.
struct NordButtonStyle: ButtonStyle {
    var color: Color = Nord.n8
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Nord.n0 : color)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? color : color.opacity(configuration.isPressed ? 0.3 : 0.16))
            )
            .opacity(configuration.isPressed && prominent ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A grouped form with Nord rows instead of the system greys.
struct NordForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Group { content }.listRowBackground(Nord.raised.opacity(0.7))
        }
        .formStyle(.grouped)
        .nordList()
    }
}

extension View {
    /// Nord background for lists and forms, replacing the system grouped greys.
    func nordList() -> some View {
        scrollContentBackground(.hidden).background(Nord.background)
    }

    /// Dark Nord look for a whole window or sheet.
    public func nordWindow() -> some View {
        preferredColorScheme(.dark).tint(Nord.accent).background(Nord.background)
    }
}

enum Prefs {
    static let defaults = UserDefaults.standard
    static var fontScale: Double {
        get { let v = defaults.double(forKey: "fontScale"); return v > 0 ? v : 1 }
        set { defaults.set(newValue, forKey: "fontScale") }
    }
}
