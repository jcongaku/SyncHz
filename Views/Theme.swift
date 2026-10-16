import SwiftUI
import AppKit

// MARK: - Palette

/// SyncHz's flat palette: warm washi/sumi neutrals, hairlines instead of
/// shadows, and a single 利休 (Rikyū) green-gold accent. Plain fills only — no
/// Liquid Glass or materials — so the panel looks the same on macOS 15 and 26
/// and composites cheaply.
enum Theme {
    /// 利休 — the one accent: play, progress, toggles, the EQ curve.
    static let accent = dynamic(light: 0x646C36, dark: 0xB6C07A)
    /// 藍鼠 — muted indigo, used only for the live spectrum.
    static let indigo = dynamic(light: 0x4F6373, dark: 0x8FA3B3)
    /// 苔 — moss green for "in sync".
    static let ok = dynamic(light: 0x3E8758, dark: 0x7BCB93)
    static let warn = dynamic(light: 0xA5640F, dark: 0xE8B467)

    static let background = dynamic(light: 0xF5F4F0, dark: 0x18181A)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x222224)
    /// Quiet fill for chips, tracks and inline fields.
    static let fill = dynamic(light: 0xECEBE6, dark: 0x2D2D30)
    static let hairline = dynamic(light: NSColor(white: 0.11, alpha: 0.10),
                                  dark: NSColor(white: 1, alpha: 0.09))

    static let textPrimary = dynamic(light: 0x1C1B18, dark: 0xEDEBE6)
    static let textSecondary = dynamic(light: 0x5F5C55, dark: 0xB3AFA6)
    static let textMuted = dynamic(light: 0x8F8B82, dark: 0x85827A)
    /// Text and glyphs drawn on an `accent` fill.
    static let onAccent = dynamic(light: 0xF5F4F0, dark: 0x18181A)

    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 7

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Surfaces

extension View {
    /// A flat card: solid fill and a hairline rim, no shadow or blur.
    func themeCard(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

/// A 0.5 pt divider in the palette's hairline colour.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
    }
}

/// Small sentence-case caption above a value ("Source", "Output").
struct SectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textMuted)
    }
}

/// A tinted capsule with a status dot: "In sync", "Switching", …
struct StatusPill: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Buttons

/// Borderless icon button: no chrome at rest, a quiet fill on hover/press.
struct GhostButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, size: size)
    }

    private struct GhostButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Theme.fill.opacity(configuration.isPressed ? 1 : (isHovering ? 0.75 : 0)))
                )
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
        }
    }
}

/// Filled tool button for toolbars (import, add, reset).
struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration)
    }

    private struct ToolButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Theme.fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(Color.black.opacity(configuration.isPressed ? 0.08 : 0))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

// MARK: - Signal flow

/// The animated arrow between source and output: dots travel along a short
/// track into an arrowhead while the signal is flowing.
///
/// Cheap by construction — a tiny `Canvas` in a `TimelineView` capped at
/// 30 fps, paused whenever nothing is flowing, and static under Reduce Motion.
/// Only this view redraws per frame; the card around it does not.
struct SignalFlowArrow: View {
    let color: Color
    let isFlowing: Bool
    /// Track lengths per second; slightly faster while switching.
    var speed: Double = 0.55

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isFlowing && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
            Canvas { context, size in
                draw(in: context, size: size,
                     phase: animates ? timeline.date.timeIntervalSinceReferenceDate * speed : nil)
            }
        }
        .frame(width: 52, height: 14)
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, phase: Double?) {
        let midY = size.height / 2
        let x0: CGFloat = 2
        let tip = size.width - 2
        let x1 = tip - 4

        var track = Path()
        track.move(to: CGPoint(x: x0, y: midY))
        track.addLine(to: CGPoint(x: x1, y: midY))
        context.stroke(track, with: .color(color.opacity(phase == nil ? 0.55 : 0.18)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        var head = Path()
        head.move(to: CGPoint(x: tip - 5, y: midY - 4))
        head.addLine(to: CGPoint(x: tip, y: midY))
        head.addLine(to: CGPoint(x: tip - 5, y: midY + 4))
        context.stroke(head, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        guard let phase else { return }
        let dots = 3
        for i in 0..<dots {
            let t = (phase + Double(i) / Double(dots)).truncatingRemainder(dividingBy: 1)
            let x = x0 + (x1 - x0) * CGFloat(t)
            let r: CGFloat = 1.9
            // Fade in from the source and out into the arrowhead.
            let alpha = sin(.pi * t)
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: midY - r, width: r * 2, height: r * 2)),
                         with: .color(color.opacity(alpha)))
        }
    }
}
