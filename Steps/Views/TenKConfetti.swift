import SwiftUI
import UIKit
import CoreHaptics

enum TenKCelebration {
    static let threshold = 10_000
    private static let key = "steps.celebrated10kDay.v5"

    /// True until confetti has actually played for this day. Crossing while the app is closed still counts.
    static func shouldCelebrate(steps: Int, day: Date, isSample: Bool) -> Bool {
        guard !isSample, steps >= threshold else { return false }
        return !isCelebrated(day)
    }

    static func isCelebrated(_ day: Date) -> Bool {
        UserDefaults.standard.string(forKey: key) == WalkCache.dayKey(day)
    }

    static func markCelebrated(_ day: Date) {
        UserDefaults.standard.set(WalkCache.dayKey(day), forKey: key)
    }
}

struct TenKOriginKey: PreferenceKey {
    static var defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}

struct TenKConfetti: View {
    var origin: CGPoint
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let duration = 9.0

    var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                ConfettiBurst(origin: origin)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            TenKHaptic.play()
        }
        .onDisappear {
            TenKHaptic.end()
        }
        .task {
            let wait = reduceMotion ? 0.4 : duration
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                return
            }
            onFinished()
        }
    }
}

/// Pieces shoot out from the 10k mark on the chart, tumble, then fall.
private struct ConfettiBurst: UIViewRepresentable {
    var origin: CGPoint

    func makeUIView(context: Context) -> ConfettiBurstView {
        let view = ConfettiBurstView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.origin = origin
        return view
    }

    func updateUIView(_ uiView: ConfettiBurstView, context: Context) {
        uiView.origin = origin
        uiView.startIfNeeded()
    }
}

private final class ConfettiBurstView: UIView {
    var origin: CGPoint = .zero
    private var started = false
    private let foreground = CAEmitterLayer()
    private let background = CAEmitterLayer()
    private var pieces: [ConfettiPiece] = []
    private var ticker: CADisplayLink?
    private var tickerProxy: ConfettiTicker?
    private var startTime: CFTimeInterval = 0
    private var lastTime: CFTimeInterval = 0
    private var screenTop: CGFloat = 0
    private var screenMinX: CGFloat = 0
    private var screenMaxX: CGFloat = 0
    private var screenBottom: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        startIfNeeded()
    }

    deinit {
        ticker?.invalidate()
    }

    func startIfNeeded() {
        guard !started, bounds.width > 1, bounds.height > 1 else { return }
        guard bounds.insetBy(dx: -40, dy: -40).contains(origin) else { return }
        started = true
        install(background, depth: .far)
        install(foreground, depth: .near)
        layer.addSublayer(background)
        layer.addSublayer(foreground)
        beginRaindrops()
    }

    /// CAEmitterLayer does not report particle positions, so a twin of the same
    /// launch is integrated here and a drop plays as each piece crosses the glass.
    private func beginRaindrops() {
        let edges = screenEdges()
        screenTop = edges.top
        screenMinX = edges.minX
        screenMaxX = edges.maxX
        screenBottom = edges.bottom
        pieces = ConfettiRain.makePieces()
        markExits()
        let proxy = ConfettiTicker()
        proxy.owner = self
        tickerProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(ConfettiTicker.step(_:)))
        link.add(to: .main, forMode: .common)
        ticker = link
    }

    fileprivate func step(_ link: CADisplayLink) {
        let now = link.timestamp
        if startTime == 0 {
            startTime = now
            lastTime = now
            return
        }
        let dt = min(max(now - lastTime, 1.0 / 120.0), 0.05)
        lastTime = now
        let t = now - startTime
        var landed: [(speed: CGFloat, far: Bool)] = []
        var pending = false
        for piece in pieces where !piece.resolved {
            if t < piece.birth {
                pending = true
                continue
            }
            let age = CGFloat(t - piece.birth)
            let previousAge = max(0, age - CGFloat(dt))
            if let exitAge = piece.exitAge {
                if age >= exitAge {
                    piece.resolved = true
                    if previousAge < exitAge {
                        landed.append((piece.exitSpeed, piece.far))
                    }
                } else {
                    pending = true
                }
            } else if TimeInterval(age) > piece.lifetime {
                piece.resolved = true
            } else {
                pending = true
            }
        }
        if let drop = Self.loudest(landed) {
            TenKHaptic.raindrop(impactSpeed: drop.speed, far: drop.far, extra: drop.extra)
        }
        if !pending {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// Several pieces can cross the glass in one frame. The taptic engine
    /// speaks that as one drop, a little heavier when more than one lands.
    private static func loudest(_ landed: [(speed: CGFloat, far: Bool)]) -> (speed: CGFloat, far: Bool, extra: Int)? {
        guard let first = landed.max(by: { $0.speed < $1.speed }) else { return nil }
        let near = landed.contains { !$0.far }
        return (first.speed, far: near ? false : first.far, extra: landed.count - 1)
    }

    /// The first edge a piece crosses while it is still on the glass: bottom, left, or right.
    private func markExits() {
        for piece in pieces {
            guard let exit = exit(for: piece) else { continue }
            piece.exitAge = exit.age
            piece.exitSpeed = exit.speed
        }
    }

    private func exit(for piece: ConfettiPiece) -> (age: CGFloat, speed: CGFloat)? {
        var bestAge = CGFloat.greatestFiniteMagnitude
        var bestSpeed: CGFloat = 0

        func consider(_ age: CGFloat, speed: CGFloat) {
            guard age > 0, age < CGFloat(piece.lifetime), age < bestAge else { return }
            bestAge = age
            bestSpeed = speed
        }

        if abs(piece.vx) > 0.5 {
            let edge: CGFloat = piece.vx < 0 ? screenMinX : screenMaxX
            let age = (edge - origin.x) / piece.vx
            let y = origin.y + piece.vy0 * age + 0.5 * piece.ay * age * age
            if y >= screenTop, y <= screenBottom {
                let vertical = piece.vy0 + piece.ay * age
                consider(age, speed: hypot(piece.vx, vertical))
            }
        }

        let a = 0.5 * piece.ay
        let b = piece.vy0
        let c = origin.y - screenBottom
        if a != 0 {
            let discriminant = b * b - 4 * a * c
            if discriminant >= 0 {
                let root = sqrt(discriminant)
                for age in [(-b - root) / (2 * a), (-b + root) / (2 * a)] {
                    let impact = piece.vy0 + piece.ay * age
                    guard impact > 0 else { continue }
                    let x = origin.x + piece.vx * age
                    guard x >= screenMinX, x <= screenMaxX else { continue }
                    consider(age, speed: impact)
                }
            }
        }

        guard bestAge < .greatestFiniteMagnitude else { return nil }
        return (bestAge, bestSpeed)
    }

    private func screenEdges() -> (top: CGFloat, minX: CGFloat, maxX: CGFloat, bottom: CGFloat) {
        guard let window else {
            return (0, 0, bounds.width, bounds.height)
        }
        let topLeft = convert(CGPoint.zero, from: window)
        let bottomRight = convert(
            CGPoint(x: window.bounds.width, y: window.bounds.height),
            from: window
        )
        return (topLeft.y, topLeft.x, bottomRight.x, bottomRight.y)
    }

    private func install(_ emitter: CAEmitterLayer, depth: ConfettiDepth) {
        emitter.emitterShape = .point
        emitter.emitterMode = .outline
        emitter.renderMode = .unordered
        emitter.frame = bounds
        emitter.emitterPosition = origin
        emitter.birthRate = 0
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = ConfettiArtwork.cells(depth: depth)
        if depth == .far {
            emitter.opacity = 0.55
            emitter.speed = 0.72
        }

        let burst = CABasicAnimation(keyPath: #keyPath(CAEmitterLayer.birthRate))
        burst.fromValue = 1
        burst.toValue = 0
        burst.duration = ConfettiArtwork.burstDuration
        burst.timingFunction = CAMediaTimingFunction(name: .easeIn)
        burst.fillMode = .forwards
        burst.isRemovedOnCompletion = false
        emitter.add(burst, forKey: "burst")
    }
}

private enum ConfettiDepth {
    case near
    case far
}

private enum ConfettiArtwork {
    private static let colors: [UIColor] = [
        UIColor(red: 149 / 255, green: 58 / 255, blue: 255 / 255, alpha: 1),
        UIColor(red: 255 / 255, green: 195 / 255, blue: 41 / 255, alpha: 1),
        UIColor(red: 255 / 255, green: 101 / 255, blue: 26 / 255, alpha: 1),
        UIColor(red: 123 / 255, green: 92 / 255, blue: 255 / 255, alpha: 1),
        UIColor(red: 76 / 255, green: 126 / 255, blue: 255 / 255, alpha: 1),
        UIColor(red: 71 / 255, green: 192 / 255, blue: 255 / 255, alpha: 1),
        UIColor(red: 255 / 255, green: 47 / 255, blue: 39 / 255, alpha: 1),
        UIColor(red: 255 / 255, green: 91 / 255, blue: 134 / 255, alpha: 1),
        UIColor(red: 233 / 255, green: 122 / 255, blue: 208 / 255, alpha: 1)
    ]

    static var cellCount: Int { colors.count * 2 }
    static let burstDuration = 0.42
    static let lifetime = 12.0
    static let emissionLongitude = -CGFloat.pi / 2
    static let emissionRange = 40 * CGFloat.pi / 180

    struct Flight {
        var birthRate: CGFloat
        var velocity: CGFloat
        var velocityRange: CGFloat
        var yAcceleration: CGFloat
        var speed: CGFloat
        var far: Bool
    }

    static func flight(_ depth: ConfettiDepth) -> Flight {
        switch depth {
        case .near:
            Flight(birthRate: 10, velocity: 470, velocityRange: 200, yAcceleration: 175, speed: 1, far: false)
        case .far:
            Flight(birthRate: 6, velocity: 245, velocityRange: 110, yAcceleration: 100, speed: 0.72, far: true)
        }
    }

    static func cells(depth: ConfettiDepth) -> [CAEmitterCell] {
        let flight = flight(depth)
        return colors.flatMap { color in
            [image(color: color, circle: false), image(color: color, circle: true)].map { contents in
                let cell = CAEmitterCell()
                cell.contents = contents
                cell.birthRate = Float(flight.birthRate)
                cell.lifetime = Float(lifetime)
                cell.lifetimeRange = 0
                cell.velocity = flight.velocity
                cell.velocityRange = flight.velocityRange
                cell.emissionLongitude = emissionLongitude
                cell.emissionRange = emissionRange
                cell.yAcceleration = flight.yAcceleration
                cell.xAcceleration = 0
                cell.spin = flight.far ? 1.8 : 3.3
                cell.spinRange = flight.far ? 3.5 : 7
                cell.scale = flight.far ? 0.22 : 0.42
                cell.scaleRange = flight.far ? 0.08 : 0.15
                cell.setValue("plane", forKey: "particleType")
                cell.setValue(Double.pi, forKey: "orientationRange")
                cell.setValue(Double.pi / 2, forKey: "orientationLongitude")
                cell.setValue(Double.pi / 2, forKey: "orientationLatitude")
                return cell
            }
        }
    }

    private static func image(color: UIColor, circle: Bool) -> CGImage? {
        let size = circle ? CGSize(width: 10, height: 10) : CGSize(width: 17, height: 11)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            color.setFill()
            if circle {
                context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            } else {
                context.cgContext.fill(CGRect(origin: .zero, size: size))
            }
        }
        return image.cgImage
    }
}

private final class ConfettiPiece {
    let birth: TimeInterval
    let lifetime: TimeInterval
    let vx: CGFloat
    let vy0: CGFloat
    let ay: CGFloat
    let far: Bool
    var exitAge: CGFloat?
    var exitSpeed: CGFloat = 0
    var resolved = false

    init(birth: TimeInterval, lifetime: TimeInterval, vx: CGFloat, vy0: CGFloat, ay: CGFloat, far: Bool) {
        self.birth = birth
        self.lifetime = lifetime
        self.vx = vx
        self.vy0 = vy0
        self.ay = ay
        self.far = far
    }
}

private final class ConfettiTicker: NSObject {
    weak var owner: ConfettiBurstView?

    @objc func step(_ link: CADisplayLink) {
        owner?.step(link)
    }
}

/// Same launch as the emitter: birth window, speed, and gravity.
private enum ConfettiRain {
    static func makePieces() -> [ConfettiPiece] {
        [ConfettiDepth.near, .far].flatMap { depth in
            let flight = ConfettiArtwork.flight(depth)
            let mean = Double(ConfettiArtwork.cellCount)
                * Double(flight.birthRate)
                * birthIntegral
            return (0..<poisson(mean)).map { _ in
                let localBirth = sampleBirth()
                let speed = Double(flight.speed)
                let velocity = flight.velocity + CGFloat.random(in: -flight.velocityRange / 2...flight.velocityRange / 2)
                let angle = ConfettiArtwork.emissionLongitude
                    + CGFloat.random(in: -ConfettiArtwork.emissionRange / 2...ConfettiArtwork.emissionRange / 2)
                let scale = flight.speed
                return ConfettiPiece(
                    birth: localBirth / speed,
                    lifetime: ConfettiArtwork.lifetime / speed,
                    vx: velocity * cos(angle) * scale,
                    vy0: velocity * sin(angle) * scale,
                    ay: flight.yAcceleration * scale * scale,
                    far: flight.far
                )
            }
        }
    }

    /// Integral of the ease-in burst, which holds the birth rate up and then cuts it.
    private static let birthIntegral: Double = {
        let steps = 240
        let duration = ConfettiArtwork.burstDuration
        var sum = 0.0
        for index in 0..<steps {
            let u = (Double(index) + 0.5) / Double(steps)
            sum += birthWeight(u)
        }
        return duration * sum / Double(steps)
    }()

    private static func sampleBirth() -> TimeInterval {
        let duration = ConfettiArtwork.burstDuration
        while true {
            let u = Double.random(in: 0..<1)
            if Double.random(in: 0..<1) <= birthWeight(u) {
                return u * duration
            }
        }
    }

    /// Ease-in from 1 down to 0. `u` is the fraction of the burst.
    private static func birthWeight(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2
            let oneMinus = 1 - t
            let curveX = 3 * oneMinus * oneMinus * t * 0.42
                + 3 * oneMinus * t * t
                + t * t * t
            if curveX < x {
                low = t
            } else {
                high = t
            }
        }
        let t = (low + high) / 2
        let oneMinus = 1 - t
        let curveY = 3 * oneMinus * t * t + t * t * t
        return 1 - curveY
    }

    private static func poisson(_ mean: Double) -> Int {
        guard mean > 0 else { return 0 }
        let limit = exp(-mean)
        var count = 0
        var product = 1.0
        repeat {
            count += 1
            product *= Double.random(in: 0..<1)
        } while product > limit
        return count - 1
    }
}

enum TenKHaptic {
    private static var engine: CHHapticEngine?

    static func play() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        do {
            let engine = try prepareEngine()
            let player = try engine.makePlayer(with: fanfare())
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    static func end() {
        let running = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard self.engine === running else { return }
            running?.stop()
            self.engine = nil
        }
    }

    /// A soft, round tap. Faster pieces and nearer pieces land a little harder.
    static func raindrop(impactSpeed: CGFloat, far: Bool, extra: Int) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        let speedScale = min(max(Float(impactSpeed) / 620, 0.75), 1.2)
        var intensity: Float = (far ? 0.34 : 0.5) * speedScale
        intensity *= 1 + 0.1 * Float(min(extra, 3))
        intensity *= Float.random(in: 0.9...1.1)
        intensity = min(max(intensity, 0.28), 0.7)
        let sharpness = Float.random(in: 0.18...0.38)
        do {
            let engine = try prepareEngine()
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0
            )
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil
        }
    }

    private static func prepareEngine() throws -> CHHapticEngine {
        if let engine {
            try engine.start()
            return engine
        }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = false
        engine.playsHapticsOnly = true
        engine.stoppedHandler = { [weak engine] _ in
            DispatchQueue.main.async {
                if self.engine === engine {
                    self.engine = nil
                }
            }
        }
        try engine.start()
        self.engine = engine
        return engine
    }

    private static func fanfare() throws -> CHHapticPattern {
        var events: [CHHapticEvent] = [
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
                ],
                relativeTime: 0.16,
                duration: 0.42
            )
        ]
        let taps: [(time: TimeInterval, intensity: Float, sharpness: Float)] = [
            (0.00, 0.45, 0.9),
            (0.07, 0.62, 0.95),
            (0.14, 0.8, 1),
            (0.24, 1, 0.28),
            (0.42, 0.7, 0.85),
            (0.55, 0.55, 1),
            (0.70, 0.4, 0.7)
        ]
        events += taps.map { tap in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.sharpness)
                ],
                relativeTime: tap.time
            )
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}
