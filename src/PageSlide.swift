import AppKit

// One desktop's list sliding over to the next. It behaves like the macOS desktop swipe: the list stays under your fingers
// and the next desktop comes in beside it, while the panel's size and the page dots move with them. Letting go carries
// the movement on: it lands on the next desktop or springs back, and fingers put down again catch it on the way.
// Keys slide the same way. With Reduce Motion on there is no slide: the page changes at once, as macOS does.
final class PageSlide: NSObject {
    static var allowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private unowned let panel: SwitcherPanel
    private let view: SwitcherView
    private let home: NSRect                               // the panel at rest on this page
    private let pageWidth: CGFloat
    private let neighbour: (Int) -> SwitcherView?          // the page one to the right (1) or left (-1); nil at the ends
    private var built: [Int: SwitcherView?] = [:]
    private var side = 0                                   // the neighbour in the panel now
    private(set) var offset: CGFloat = 0                   // how far the list has moved; left is negative
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var landed: (() -> Void)?
    private var lastTick: CFTimeInterval = 0
    private var link: AnyObject?
    private var timer: Timer?
    private var settling = 0
    private(set) var ticks = 0                             // read by the self-test: frames drawn while settling

    var isSettling: Bool { landed != nil }
    var width: CGFloat { pageWidth }

    init(panel: SwitcherPanel, view: SwitcherView, neighbour: @escaping (Int) -> SwitcherView?) {
        self.panel = panel; self.view = view; self.neighbour = neighbour
        home = panel.frame
        pageWidth = panel.frame.width
        super.init()
        view.sliding = true
    }

    private func page(on side: Int) -> SwitcherView? {
        guard side != 0 else { return nil }
        if let known = built[side] { return known }
        let made = neighbour(side)
        built[side] = .some(made)
        return made
    }

    // The fingers moved: `travel` is the distance from where the list rests. With nothing on that side it stretches a
    // little and resists, so an end of the list feels like an end.
    func track(_ travel: CGFloat) {
        stopTicking()
        landed = nil
        let wanted = travel < 0 ? 1 : travel > 0 ? -1 : side
        if page(on: wanted) == nil {
            let stretch = Tokens.Motion.pageEdgeStretch
            offset = travel.sign == .minus ? -PageSlide.resisted(-travel, limit: stretch) : PageSlide.resisted(travel, limit: stretch)
        } else {
            offset = max(-pageWidth, min(pageWidth, travel))
        }
        draw()
    }

    static func resisted(_ travel: CGFloat, limit: CGFloat) -> CGFloat { limit * (1 - 1 / (travel / limit * 0.55 + 1)) }

    // Let go: on to the page in `delta` (or back, with 0), carrying the speed the fingers had.
    func settle(to delta: Int, speed: CGFloat, landed: @escaping () -> Void) {
        target = -CGFloat(delta) * pageWidth
        velocity = max(-Tokens.Motion.pageMaxSpeed, min(Tokens.Motion.pageMaxSpeed, speed))
        self.landed = landed
        lastTick = CACurrentMediaTime()
        ticks = 0
        startTicking()
        // A safety net, not the animation: a display that stops ticking must not leave the list half way.
        settling += 1
        let turn = settling
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isSettling, self.settling == turn else { return }
            self.land()
        }
    }

    // A key was pressed, or the list is closing: straight to the end of the movement.
    func land() {
        stopTicking()
        let done = landed
        landed = nil
        done?()
    }

    // Stops where it is, for fingers catching it on the way.
    func hold() {
        stopTicking()
        landed = nil
        settling += 1
    }

    func stop() { stopTicking(); landed = nil; settling += 1 }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(CGFloat(now - lastTick), 0.05)
        lastTick = now
        ticks += 1
        // A critically damped spring, the shape of the system's own: quick away, soft arrival, no bounce past the end.
        let omega = 2 * .pi / CGFloat(Tokens.Motion.pageSpring)
        let x = offset - target
        let c = velocity + omega * x
        let e = exp(-omega * dt)
        let nextX = (x + c * dt) * e
        velocity = (c - omega * (x + c * dt)) * e
        let crossed = (x < 0) != (nextX < 0) && x != 0
        offset = crossed ? target : target + nextX
        draw()
        if crossed || (abs(nextX) < 0.5 && abs(velocity) < 20) { land() }
    }

    private func draw() {
        let wanted = offset < 0 ? 1 : offset > 0 ? -1 : side
        if wanted != side {
            if let old = page(on: side) { old.rows.removeFromSuperview() }
            side = wanted
        }
        let other = page(on: side)
        let amount = other == nil ? 0 : min(1, abs(offset) / pageWidth)
        var f = home
        if let other {
            f.size.width = round(home.width + (other.frame.width - home.width) * amount)
            f.size.height = round(home.height + (other.frame.height - home.height) * amount)
            f.origin.x = floor(home.midX - f.width / 2)
            f.origin.y = floor(home.midY - f.height / 2)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if f != panel.frame {
            panel.setFrame(f, display: true)
            panel.invalidateShadow()
        }
        view.place(offset: offset, pageWidth: pageWidth, incoming: other?.rows, side: side)
        CATransaction.commit()
        view.header?.peek = other?.header.map { (title: $0.title, index: $0.index, amount: amount) }
    }

    private func startTicking() {
        stopTicking()
        if #available(macOS 14, *) {
            let l = view.displayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stopTicking() {
        if #available(macOS 14, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        timer?.invalidate()
        timer = nil
    }
}
