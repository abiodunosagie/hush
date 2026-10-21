import SwiftUI

/// Small shared building blocks so every tab lays out the same way.
enum UI {
    static let labelWidth: CGFloat = 96
    static let valueWidth: CGFloat = 64
    /// Fill for unselected tiles and the disabled play button.
    static let quietFill = Color.secondary.opacity(0.12)

    static func grid(_ columns: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: columns)
    }
}

struct Panel<Content: View>: View {
    let title: String
    var toggle: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    init(_ title: String, toggle: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.toggle = toggle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let toggle {
                    Toggle(title, isOn: toggle).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }
            if toggle?.wrappedValue ?? true {
                content()
            }
        }
    }
}

struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack {
            Text(title).frame(width: UI.labelWidth, alignment: .leading)
            content()
        }
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The main action button in brand colours. Drawn by hand instead of .borderedProminent, because the system
/// style turns grey whenever the window is in the background (most of the night), which hid the label.
struct PrimaryButtonStyle: ButtonStyle {
    /// Whether the button has keyboard focus. Passed in from the caller's @FocusState, because the
    /// style's own focus environment describes the view around the button, not the button.
    var isFocused = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, isFocused: isFocused)
    }

    /// A view, not inline in makeBody, so it can read the button's enabled state.
    private struct PrimaryButton: View {
        let configuration: Configuration
        let isFocused: Bool
        @Environment(\.isEnabled) private var isEnabled
        private static let shape = RoundedRectangle(cornerRadius: 10)

        var body: some View {
            configuration.label
                .padding(.vertical, 12)
                .foregroundStyle(isEnabled ? AnyShapeStyle(Brand.onAccent) : AnyShapeStyle(.tertiary))
                .background(isEnabled ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(UI.quietFill), in: Self.shape)
                // Keyboard focus ring (Full Keyboard Access). Drawn here because a ring in the accent colour
                // would vanish against the accent fill: primary text colour, just outside the button.
                .overlay {
                    if isFocused {
                        Self.shape.inset(by: -3).stroke(.primary, lineWidth: 2)
                    }
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Selectable tile used for tone and preset grids.
struct Tile: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(selected ? Brand.onAccent : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 2)
            .foregroundStyle(selected ? Brand.onAccent : .primary)
            .background(selected ? Brand.accent : UI.quietFill,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum Format {
    /// Whole numbers print plain ("852 Hz"), anything else to one decimal ("2.5 Hz").
    static func hz(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths)) Hz" : String(format: "%.1f Hz", tenths)
    }

    static func minutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
