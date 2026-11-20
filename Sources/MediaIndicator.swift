import AppKit
import SwiftUI

final class IndicatorState: ObservableObject {
    @Published var style: IndicatorStyle = .classic
    @Published var control: MediaControl = .volume
    @Published var level = MediaLevel(value: 0)
    @Published var revealed = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchDepth: CGFloat = 0
}

final class MediaIndicator {
    private let state = IndicatorState()
    private let classic = ClassicSystemIndicator()
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var orderOutTimer: Timer?

    static var activeScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    func show(_ control: MediaControl, style: IndicatorStyle, level: MediaLevel, on screen: NSScreen) {
        guard style != .system else { return }
        if style == .classic, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            hidePanel()
            classic.show(control, level: level, display: number.uint32Value) { [weak self] in
                self?.showPanel(control, style: .classic, level: level, on: screen)
            }
            return
        }
        classic.dismiss()
        showPanel(control, style: style, level: level, on: screen)
    }

    private func showPanel(_ control: MediaControl, style: IndicatorStyle, level: MediaLevel, on screen: NSScreen) {
        let panel = panel ?? makePanel()
        if panel.isVisible && state.style != style { hidePanel() }
        hideTimer?.invalidate()
        orderOutTimer?.invalidate()
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let coordinate: CGRect
        if style == .notch {
            let left = screen.auxiliaryTopLeftArea
            let right = screen.auxiliaryTopRightArea
            let screenFrame = screen.frame
            let width = min(max(230, (right?.minX ?? 0) - (left?.maxX ?? 0) + 24), screenFrame.width)
            var center = screenFrame.midX
            state.notchWidth = 0
            state.notchDepth = 0
            if let left, let right, screen.safeAreaInsets.top > 0 {
                let gap = right.minX - left.maxX
                if gap > 0 && gap < width - 20 {
                    state.notchWidth = gap
                    state.notchDepth = screen.safeAreaInsets.top
                    center = left.maxX + gap / 2
                }
            }
            let height = state.notchDepth + 38
            coordinate = CGRect(x: center - width / 2, y: screenFrame.maxY - height, width: width, height: height)
        } else {
            let frame = screen.visibleFrame
            coordinate = CGRect(x: frame.midX - 100, y: frame.midY - 100, width: 200, height: 200)
        }
        state.style = style
        state.control = control
        state.level = level
        if panel.frame != coordinate { panel.setFrame(coordinate, display: false) }
        if !panel.isVisible {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
        }
        if !state.revealed {
            withAnimation(animated ? .spring(response: 0.33, dampingFraction: 0.8) : nil) { state.revealed = true }
        }
        hideTimer = Timer(timeInterval: 1.15, repeats: false) { [weak self] _ in self?.collapse(animated: animated) }
        if let hideTimer { RunLoop.main.add(hideTimer, forMode: .common) }
    }

    func dismiss() {
        classic.dismiss()
        hidePanel()
    }

    private func hidePanel() {
        hideTimer?.invalidate()
        orderOutTimer?.invalidate()
        panel?.orderOut(nil)
        withAnimation(nil) { state.revealed = false }
    }

    private func collapse(animated: Bool) {
        guard animated else { dismiss(); return }
        withAnimation(.easeInOut(duration: 0.22)) { state.revealed = false }
        orderOutTimer = Timer(timeInterval: 0.24, repeats: false) { [weak self] _ in self?.panel?.orderOut(nil) }
        if let orderOutTimer { RunLoop.main.add(orderOutTimer, forMode: .common) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: IndicatorView(state: state))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

struct IndicatorView: View {
    @ObservedObject var state: IndicatorState

    private var fraction: CGFloat { state.level.muted ? 0 : CGFloat(state.level.value) }
    private var symbol: String { state.control.icon(level: state.level.value, muted: state.level.muted) }
    private var readout: String { state.level.muted ? "Без звука" : "\(Int((fraction * 100).rounded()))%" }

    var body: some View {
        Group {
            if state.style == .notch { notch }
            else { classic }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.control.title)
        .accessibilityValue(readout)
    }

    private var classic: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 21).fill(.black.opacity(0.53))
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 105)
                .foregroundStyle(.white)
                .offset(y: -13)
            segmentTrack(spacing: 1.5, emptyOpacity: 0.52, darkEmpty: true)
                .frame(width: 144, height: 8)
                .offset(y: 68)
        }
        .opacity(state.revealed ? 1 : 0)
    }

    private func segmentTrack(spacing: CGFloat, emptyOpacity: Double, darkEmpty: Bool = false) -> some View {
        Canvas { context, size in
            let width = max(0, (size.width - 15 * spacing) / 16)
            for index in 0..<16 {
                var block = CGRect(x: CGFloat(index) * (width + spacing), y: 0, width: width, height: size.height)
                context.fill(Path(block), with: .color((darkEmpty ? Color.black : .white).opacity(emptyOpacity)))
                block.size.width *= min(1, max(0, fraction * 16 - CGFloat(index)))
                context.fill(Path(block), with: .color(.white))
            }
        }
    }

    private var notch: some View {
        GeometryReader { geometry in
            let width = state.revealed ? geometry.size.width : state.notchWidth
            let depth = state.notchDepth + (state.revealed ? 38 : 0)
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 23)
                segmentTrack(spacing: 1, emptyOpacity: 0.29)
                    .frame(height: 3)
            }
            .padding(.horizontal, 20)
            .frame(width: geometry.size.width, height: 38)
            .foregroundStyle(.white)
            .opacity(state.revealed ? 1 : 0)
            .frame(width: width, height: depth, alignment: .bottom)
            .background(NotchIndicatorShape().fill(.black))
            .clipShape(NotchIndicatorShape())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct NotchIndicatorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = min(12, rect.width / 8, rect.height / 3)
        let radius = min(21, rect.width / 4, rect.height / 2)
        let right = rect.maxX
        let bottom = rect.maxY
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addQuadCurve(to: CGPoint(x: right - shoulder, y: shoulder), control: CGPoint(x: right - shoulder, y: 0))
        path.addLine(to: CGPoint(x: right - shoulder, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - shoulder - radius, y: bottom), control: CGPoint(x: right - shoulder, y: bottom))
        path.addLine(to: CGPoint(x: shoulder + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: shoulder, y: bottom - radius), control: CGPoint(x: shoulder, y: bottom))
        path.addLine(to: CGPoint(x: shoulder, y: shoulder))
        path.addQuadCurve(to: .zero, control: CGPoint(x: shoulder, y: 0))
        path.closeSubpath()
        return path
    }
}
