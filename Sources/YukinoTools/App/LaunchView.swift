import SwiftUI

struct LaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @FocusState private var focused: Bool
    let completion: () -> Void

    private let particles: [(symbol: String, x: CGFloat, y: CGFloat, angle: Double)] = [
        ("curlybraces", -98, -62, -14),
        ("terminal", 98, -56, 13),
        ("shippingbox", -105, 57, 10),
        ("doc.text", 103, 64, -12)
    ]
    private let squares: [(x: CGFloat, y: CGFloat, opacity: Double)] = [
        (-11.5, -11.5, 0.7), (15.5, -11.5, 0.95),
        (-11.5, 15.5, 0.32), (15.5, 15.5, 0.5)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let elapsed = reduceMotion ? 1.8 : max(0, context.date.timeIntervalSince(startedAt ?? context.date))
            scene(at: elapsed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Yukino Tools. A little more productive.")
        .task {
            focused = true
            startedAt = Date()
            do {
                try await Task.sleep(for: .seconds(reduceMotion ? 0.15 : 1.8))
            } catch { return }
            completion()
        }
        .onExitCommand(perform: completion)
    }

    private func scene(at time: Double) -> some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color.purple.opacity(0.09), .clear], center: .center, startRadius: 0, endRadius: 140))
                .frame(width: 280, height: 240)
                .offset(y: -42)
                .scaleEffect(0.7 + 0.3 * eased(time, from: 0.4, duration: 0.9))
                .opacity(eased(time, from: 0.4, duration: 0.9))

            VStack(spacing: 0) {
                mark(at: time).padding(.bottom, 23)
                Text("Yukino Tools")
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.7)
                    .blur(radius: 3 * (1 - eased(time, from: 0.85, duration: 0.5)))
                    .opacity(eased(time, from: 0.85, duration: 0.5))
                    .offset(y: 9 * (1 - eased(time, from: 0.85, duration: 0.5)))
                Text("A little more productive.")
                    .font(.system(size: 12))
                    .tracking(0.25)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .opacity(eased(time, from: 1.05, duration: 0.42))
                    .offset(y: 5 * (1 - eased(time, from: 1.05, duration: 0.42)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Text("Made for your everyday.")
                .font(.system(size: 11))
                .tracking(0.45)
                .foregroundStyle(.secondary)
                .padding(.bottom, 26)
                .opacity(eased(time, from: 1.4, duration: 0.4))
        }
    }

    private func mark(at time: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.43, blue: 0.7), Color(red: 0.25, green: 0.27, blue: 0.47)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .purple.opacity(0.12), radius: 12, y: 8)
                .scaleEffect(markScale(at: time))
                .opacity(eased(time, from: 0.48, duration: 0.54))

            ForEach(squares.indices, id: \.self) { index in
                let square = squares[index]
                let progress = eased(time, from: 0.63 + Double(index) * 0.045, duration: 0.35)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(square.opacity))
                    .frame(width: 23, height: 23)
                    .scaleEffect(0.4 + 0.6 * progress)
                    .opacity(progress)
                    .offset(x: square.x, y: square.y)
            }

            ForEach(particles.indices, id: \.self) { index in
                let particle = particles[index]
                let localTime = time - Double(index) * 0.04
                let gathering = eased(localTime, from: 0.16, duration: 0.5)
                let disappearing = eased(localTime, from: 0.55, duration: 0.27)
                Image(systemName: particle.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(red: 0.47, green: 0.44, blue: 0.7))
                    .frame(width: 44, height: 44)
                    .background(Color.canvas, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.08)))
                    .scaleEffect(0.85 + 0.15 * eased(localTime, from: 0, duration: 0.16) - 0.5 * gathering)
                    .rotationEffect(.degrees(particle.angle * (1 - gathering)))
                    .offset(x: particle.x * (1 - gathering), y: particle.y * (1 - gathering))
                    .opacity(eased(localTime, from: 0, duration: 0.16) * (1 - disappearing))
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityHidden(true)
    }

    private func eased(_ time: Double, from start: Double, duration: Double) -> Double {
        let progress = min(1, max(0, (time - start) / duration))
        return 1 - pow(1 - progress, 3)
    }

    private func markScale(at time: Double) -> Double {
        if time < 0.912 { return 0.72 + 0.305 * eased(time, from: 0.48, duration: 0.432) }
        return 1.025 - 0.025 * eased(time, from: 0.912, duration: 0.108)
    }
}
