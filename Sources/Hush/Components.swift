import SwiftUI

/// Small shared building blocks so every tab lays out the same way.
enum UI {
    static let labelWidth: CGFloat = 96
    static let valueWidth: CGFloat = 64
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
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 2)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum Format {
    static func hz(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) Hz" : String(format: "%.1f Hz", value)
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
