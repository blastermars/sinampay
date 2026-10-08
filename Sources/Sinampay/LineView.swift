import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                if line.banderitasOn {
                    Banderitas(width: width, cardXs: line.items.indices.map {
                        Layout.x(index: $0, count: line.items.count, width: width)
                    })
                        .transition(.opacity)
                }
                Rope(width: width)

                if line.items.isEmpty {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: line.items.count, width: width)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            .animation(.easeInOut(duration: 0.3), value: line.banderitasOn)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot or copy something, and it will hang here",
               fil: "Mag-screenshot o kumopya, at isasampay ko rito",
               es: "Haz una captura o copia algo, y se quedará colgado aquí"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

/// A quiet nod to the fiesta: a few small paper pennants on the line,
/// spaced well apart in soft colours. They step aside wherever a photo
/// hangs, so they only show in the gaps and never sit behind your work.
struct Banderitas: View {
    let width: CGFloat
    /// Where the cards hang; no pennant is drawn behind one.
    let cardXs: [CGFloat]

    static let spacing: CGFloat = 44
    static let flagWidth: CGFloat = 7
    static let flagHeight: CGFloat = 8

    var body: some View {
        Canvas { context, _ in
            let clearance = Layout.cardWidth / 2 + 12
            let count = Int(width / Self.spacing) + 1
            for i in 0..<count {
                let x = CGFloat(i) * Self.spacing + Self.spacing / 2
                guard !cardXs.contains(where: { abs($0 - x) < clearance }) else { continue }
                let y = Layout.ropeY(x: x, width: width)
                // A fixed wobble per flag, so they look hand strung but never move by themselves.
                let wobble = Double((i * 37) % 11 - 5) * 0.8
                var flag = Path()
                flag.move(to: CGPoint(x: -Self.flagWidth / 2, y: 0))
                flag.addLine(to: CGPoint(x: Self.flagWidth / 2, y: 0))
                flag.addLine(to: CGPoint(x: 0, y: Self.flagHeight))
                flag.closeSubpath()
                var ctx = context
                ctx.translateBy(x: x, y: y)
                ctx.rotate(by: .degrees(wobble))
                let color = Palette.banderitas[i % Palette.banderitas.count].swiftUI
                ctx.fill(flag, with: .color(color.opacity(0.55)))
            }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .animation(.easeInOut(duration: 0.3), value: cardXs)
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
