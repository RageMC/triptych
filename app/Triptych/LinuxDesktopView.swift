// SPDX-License-Identifier: GPL-3.0-or-later
//
// Triptych's graphical Linux desktop (design: engines/linux-desktop/DESIGN.md).
// Maps Xvfb's shared-memory XWD framebuffer directly into Metal on the host and
// forwards touch, pointer, and hardware/software keyboard input to the guest
// XTest agent over loopback. LinuxDesktop.swift starts Xfce in the guest.

import Combine
import Foundation
import Metal
import MetalKit
import Network
import SwiftUI
import UIKit

// MARK: - Guest SHM Framebuffer Reader (XWD v7 -> BGRX8888)

/// Parsed geometry and mapped bytes of `<rootfs>/data/dev/shm/Xvfb_screen0`.
struct XWDFramebufferLayout {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelOffset: Int
    let byteCount: Int
}

final class LinuxSHMFrameSource {
    private var fd: Int32 = -1
    private var mapping: UnsafeMutableRawPointer?
    private var mappedLength: Int = 0
    private var mappedInode: UInt64 = 0
    /// Files created before this are ignored (a previous session's frame left in the rootfs).
    var notBefore = Date.distantPast
    private var previousSnapshot = Data()
    private(set) var layout: XWDFramebufferLayout?

    deinit {
        closeMapping()
    }

    func openIfNeeded(shmURL: URL) -> Bool {
        if mapping != nil {
            // Xvfb restarted: the guest removed and recreated the file, so the mapping shows a dead inode.
            var cur = stat()
            if layout != nil, stat(shmURL.path, &cur) == 0, UInt64(cur.st_ino) == mappedInode, Int(cur.st_size) == mappedLength { return true }
            closeMapping()
        }
        let newFd = Darwin.open(shmURL.path, O_RDONLY)
        guard newFd >= 0 else { return false }
        var st = stat()
        guard fstat(newFd, &st) == 0, st.st_size >= 100,
              Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec) + 1) >= notBefore else {
            Darwin.close(newFd)
            return false
        }
        let size = Int(st.st_size)
        guard let ptr = mmap(nil, size, PROT_READ, MAP_SHARED, newFd, 0), ptr != MAP_FAILED else {
            Darwin.close(newFd)
            return false
        }
        fd = newFd
        mapping = ptr
        mappedLength = size
        mappedInode = UInt64(st.st_ino)
        guard let parsed = parseHeader(ptr: ptr, length: size) else {
            closeMapping()
            return false
        }
        layout = parsed
        return true
    }

    func closeMapping() {
        if let mapping {
            munmap(mapping, mappedLength)
            self.mapping = nil
        }
        mappedLength = 0
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        layout = nil
        previousSnapshot.removeAll(keepingCapacity: false)
    }

    /// Returns updated contiguous pixel buffer and dirty row bounds if the guest changed any scanline.
    func pollChangedRegion() -> (bytes: UnsafeRawPointer, layout: XWDFramebufferLayout, dirtyY: Range<Int>)? {
        guard let mapping, let layout else { return nil }
        let base = UnsafeRawPointer(mapping).advanced(by: layout.pixelOffset)
        let byteLen = layout.byteCount
        if previousSnapshot.count != byteLen {
            previousSnapshot = Data(bytes: base, count: byteLen)
            return (base, layout, 0..<layout.height)
        }
        var minY = layout.height
        var maxY = -1
        let stride = layout.bytesPerRow
        previousSnapshot.withUnsafeMutableBytes { prevRaw in
            guard let prevBase = prevRaw.baseAddress else { return }
            for y in 0..<layout.height {
                let off = y * stride
                if memcmp(base.advanced(by: off), prevBase.advanced(by: off), stride) != 0 {
                    memcpy(prevBase.advanced(by: off), base.advanced(by: off), stride)
                    if y < minY { minY = y }
                    maxY = y
                }
            }
        }
        guard maxY >= minY else { return nil }
        return (base, layout, minY..<(maxY + 1))
    }

    private func parseHeader(ptr: UnsafeMutableRawPointer, length: Int) -> XWDFramebufferLayout? {
        guard length >= 100 else { return nil }
        func readUInt32BE(_ index: Int) -> Int {
            let v = ptr.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
            return Int(UInt32(bigEndian: v))
        }
        let headerSize = readUInt32BE(0)
        let version = readUInt32BE(1)
        let format = readUInt32BE(2)
        let width = readUInt32BE(4)
        let height = readUInt32BE(5)
        let byteOrder = readUInt32BE(7)
        let bpp = readUInt32BE(11)
        let bytesPerRow = readUInt32BE(12)
        let ncolors = readUInt32BE(19)
        let (minStride, strideOverflow) = width.multipliedReportingOverflow(by: 4)
        guard version == 7, format == 2, byteOrder == 0, bpp == 32,
              width > 0, height > 0, !strideOverflow, bytesPerRow >= minStride else { return nil }
        let (colorBytes, colorOverflow) = ncolors.multipliedReportingOverflow(by: 12)
        let (pixelOffset, offsetOverflow) = headerSize.addingReportingOverflow(colorBytes)
        let (byteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        let (totalBytes, totalOverflow) = pixelOffset.addingReportingOverflow(byteCount)
        guard !colorOverflow, !offsetOverflow, !countOverflow, !totalOverflow,
              pixelOffset >= 100, totalBytes <= length else { return nil }
        return XWDFramebufferLayout(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelOffset: pixelOffset,
            byteCount: byteCount
        )
    }
}

// MARK: - Loopback Input Client (XTest JSON Protocol)

@MainActor
final class LinuxInputClient: ObservableObject {
    @Published private(set) var isConnected = false
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "triptych.linux.input")
    private var wanted: UInt16?

    /// Connects, and keeps retrying every second until disconnect(): the guest agent starts after Xfce.
    func connect(port: UInt16 = 5950) {
        disconnect()
        wanted = port
        open(port)
    }

    private func open(_ port: UInt16) {
        guard wanted == port, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                case .waiting, .failed, .cancelled:
                    self.isConnected = false
                    conn.cancel()
                    self.connection = nil
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if self.connection == nil { self.open(port) }
                default: break
                }
            }
        }
        conn.start(queue: queue)
        connection = conn
        drain(conn)
    }

    /// The agent answers every command; read and drop the replies so its sendall() never blocks.
    private nonisolated func drain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, done, error in
            if done || error != nil {
                Task { @MainActor in if self?.connection === conn { conn.cancel() } }
                return
            }
            self?.drain(conn)
        }
    }

    func disconnect() {
        wanted = nil
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    func sendMove(x: Int, y: Int) {
        sendJSON(["type": "move", "x": x, "y": y])
    }

    func sendButton(_ button: Int, down: Bool, x: Int? = nil, y: Int? = nil) {
        var payload: [String: Any] = ["type": "button", "button": button, "down": down]
        if let x, let y {
            payload["x"] = x
            payload["y"] = y
        }
        sendJSON(payload)
    }

    func sendClick(_ button: Int, x: Int? = nil, y: Int? = nil) {
        var payload: [String: Any] = ["type": "click", "button": button]
        if let x, let y {
            payload["x"] = x
            payload["y"] = y
        }
        sendJSON(payload)
    }

    func sendKey(keysym: String, down: Bool) {
        sendJSON(["type": "key", "keysym": keysym, "down": down])
    }

    func sendKeyCombo(mods: [String], keysym: String) {
        sendJSON(["type": "key_combo", "mods": mods, "keysym": keysym])
    }

    func sendText(_ text: String) {
        sendJSON(["type": "text", "text": text])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let connection,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .idempotent)
    }
}

// MARK: - Metal Framebuffer + Input UIView

/// What the canvas has shown so far (also the canvas's accessibility value, for the UI tests).
@MainActor
final class LinuxDesktopStatus: ObservableObject {
    @Published var width = 0
    @Published var height = 0
    @Published var frames = 0
    /// Distinct colours on a 32x18 sample grid of the last frame: about 1 for a bare X root, many for a desktop.
    @Published var colors = 0
    var summary: String { frames == 0 ? "no frame" : "\(width)x\(height) frames \(frames) colors \(colors)" }
}

final class LinuxDesktopCanvasUIView: MTKView, MTKViewDelegate, UIKeyInput {
    private let shmSource = LinuxSHMFrameSource()
    private let shmURL: URL
    private let input: LinuxInputClient
    private let status: LinuxDesktopStatus

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textures: [MTLTexture?] = [nil, nil, nil]
    private var dirtyYBySlot: [Range<Int>?] = [nil, nil, nil]
    private var activeSlot = 0
    private var currentLayout: XWDFramebufferLayout?
    private var pollTimer: DispatchSourceTimer?

    private var scrollAccumulatorY: CGFloat = 0
    private var isDraggingLeft = false
    var allowSoftKeyboard = false

    init(shmURL: URL, input: LinuxInputClient, status: LinuxDesktopStatus, notBefore: Date) {
        self.shmURL = shmURL
        shmSource.notBefore = notBefore
        self.input = input
        self.status = status
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        self.delegate = self
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1.0)
        self.framebufferOnly = true
        self.isMultipleTouchEnabled = true
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "linux-desktop"
        self.accessibilityLabel = "Linux desktop"
        self.accessibilityValue = "no frame"
        setupMetal()
        setupGestures()
        startPolling()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        pollTimer?.cancel()
        shmSource.closeMapping()
    }

    private func setupMetal() {
        guard let device else { return }
        commandQueue = device.makeCommandQueue()
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut desktop_vertex(uint i [[vertex_id]]) {
            const float2 p[4] = { float2(-1, 1), float2(-1, -1), float2(1, 1), float2(1, -1) };
            const float2 t[4] = { float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1) };
            return VOut{ float4(p[i], 0, 1), t[i] };
        }
        fragment float4 desktop_fragment(VOut v [[stage_in]], texture2d<float> img [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return float4(img.sample(s, v.uv).rgb, 1.0);
        }
        """
        guard let lib = try? device.makeLibrary(source: shader, options: nil) else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "desktop_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "desktop_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.tickFramebuffer()
        }
        timer.resume()
        pollTimer = timer
    }

    private func tickFramebuffer() {
        guard shmSource.openIfNeeded(shmURL: shmURL),
              let update = shmSource.pollChangedRegion() else { return }
        ensureTextures(layout: update.layout)
        currentLayout = update.layout
        // Accumulate dirty row bounds into all three triple-buffered slots so reused
        // older textures catch up cleanly without stale regions.
        for i in 0..<dirtyYBySlot.count {
            if let existing = dirtyYBySlot[i] {
                dirtyYBySlot[i] = min(existing.lowerBound, update.dirtyY.lowerBound)..<max(existing.upperBound, update.dirtyY.upperBound)
            } else {
                dirtyYBySlot[i] = update.dirtyY
            }
        }
        let nextSlot = (activeSlot + 1) % textures.count
        if let tex = textures[nextSlot], let dirty = dirtyYBySlot[nextSlot] {
            let y0 = dirty.lowerBound
            let h = dirty.count
            let region = MTLRegionMake2D(0, y0, update.layout.width, h)
            let ptr = update.bytes.advanced(by: y0 * update.layout.bytesPerRow)
            tex.replace(region: region, mipmapLevel: 0, withBytes: ptr, bytesPerRow: update.layout.bytesPerRow)
            dirtyYBySlot[nextSlot] = nil
            activeSlot = nextSlot
            setNeedsDisplay()
        }
        report(update.bytes, update.layout)
    }

    private func report(_ bytes: UnsafeRawPointer, _ layout: XWDFramebufferLayout) {
        var seen = Set<UInt32>()
        for gy in 0..<18 {
            let row = bytes.advanced(by: (gy * (layout.height - 1) / 17) * layout.bytesPerRow)
            for gx in 0..<32 {
                seen.insert(row.loadUnaligned(fromByteOffset: (gx * (layout.width - 1) / 31) * 4, as: UInt32.self) & 0x00ff_ffff)
            }
        }
        MainActor.assumeIsolated {
            status.width = layout.width
            status.height = layout.height
            status.frames += 1
            status.colors = seen.count
            accessibilityValue = status.summary
        }
    }

    private func ensureTextures(layout: XWDFramebufferLayout) {
        guard let device else { return }
        if let existing = textures[0], existing.width == layout.width, existing.height == layout.height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: layout.width,
            height: layout.height,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = .shaderRead
        for i in 0..<textures.count {
            textures[i] = device.makeTexture(descriptor: desc)
            dirtyYBySlot[i] = 0..<layout.height
        }
    }

    /// Maps normalized aspect-fit viewport rectangle in points inside `bounds`.
    func aspectFitRect(in bounds: CGRect) -> CGRect {
        guard let layout = currentLayout, bounds.width > 0, bounds.height > 0 else { return bounds }
        let texAspect = CGFloat(layout.width) / CGFloat(layout.height)
        let viewAspect = bounds.width / bounds.height
        if viewAspect > texAspect {
            let w = bounds.height * texAspect
            return CGRect(x: (bounds.width - w) * 0.5, y: 0, width: w, height: bounds.height)
        } else {
            let h = bounds.width / texAspect
            return CGRect(x: 0, y: (bounds.height - h) * 0.5, width: bounds.width, height: h)
        }
    }

    private func guestPoint(from viewPoint: CGPoint) -> (Int, Int)? {
        guard let layout = currentLayout else { return nil }
        let fit = aspectFitRect(in: bounds)
        guard fit.width > 0, fit.height > 0 else { return nil }
        let nx = max(0, min(1, (viewPoint.x - fit.minX) / fit.width))
        let ny = max(0, min(1, (viewPoint.y - fit.minY) / fit.height))
        let gx = min(layout.width - 1, max(0, Int((nx * CGFloat(layout.width)).rounded(.down))))
        let gy = min(layout.height - 1, max(0, Int((ny * CGFloat(layout.height)).rounded(.down))))
        return (gx, gy)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if currentLayout != nil { setNeedsDisplay() }
    }

    func draw(in view: MTKView) {
        guard let commandQueue,
              let pipeline,
              let texture = textures[activeSlot],
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }

        let fitPts = aspectFitRect(in: bounds)
        let scaleX = bounds.width > 0 ? drawableSize.width / bounds.width : 1
        let scaleY = bounds.height > 0 ? drawableSize.height / bounds.height : 1
        enc.setViewport(MTLViewport(
            originX: Double(fitPts.origin.x * scaleX),
            originY: Double(fitPts.origin.y * scaleY),
            width: Double(fitPts.width * scaleX),
            height: Double(fitPts.height * scaleY),
            znear: 0,
            zfar: 1
        ))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Touch, Trackpad & Keyboard Forwarding

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)

        let twoFingerScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        twoFingerScroll.minimumNumberOfTouches = 2
        twoFingerScroll.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerScroll)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        if allowSoftKeyboard { _ = becomeFirstResponder() }
        guard let (x, y) = guestPoint(from: gr.location(in: self)) else { return }
        Task { @MainActor in input.sendClick(1, x: x, y: y) }
    }

    @objc private func handleRightClick(_ gr: UITapGestureRecognizer) {
        guard let (x, y) = guestPoint(from: gr.location(in: self)) else { return }
        Task { @MainActor in input.sendClick(3, x: x, y: y) }
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let (x, y) = guestPoint(from: gr.location(in: self)) else { return }
        Task { @MainActor in input.sendClick(3, x: x, y: y) }
    }

    @objc private func handleDrag(_ gr: UIPanGestureRecognizer) {
        guard let (x, y) = guestPoint(from: gr.location(in: self)) else { return }
        Task { @MainActor in
            switch gr.state {
            case .began:
                isDraggingLeft = true
                input.sendButton(1, down: true, x: x, y: y)
            case .changed:
                input.sendMove(x: x, y: y)
            case .ended, .cancelled, .failed:
                if isDraggingLeft {
                    isDraggingLeft = false
                    input.sendButton(1, down: false, x: x, y: y)
                }
            default: break
            }
        }
    }

    @objc private func handleScroll(_ gr: UIPanGestureRecognizer) {
        let delta = gr.translation(in: self)
        gr.setTranslation(.zero, in: self)
        scrollAccumulatorY += delta.y
        let step: CGFloat = 24
        guard let (x, y) = guestPoint(from: gr.location(in: self)) else { return }
        Task { @MainActor in
            while scrollAccumulatorY >= step {
                input.sendClick(4, x: x, y: y)
                scrollAccumulatorY -= step
            }
            while scrollAccumulatorY <= -step {
                input.sendClick(5, x: x, y: y)
                scrollAccumulatorY += step
            }
        }
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        guard let (x, y) = guestPoint(from: gr.location(in: self)) else { return }
        Task { @MainActor in input.sendMove(x: x, y: y) }
    }

    // Hardware keyboard (`pressesBegan` / `pressesEnded`)
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        Task { @MainActor in input.sendText(text) }
    }

    func deleteBackward() {
        Task { @MainActor in
            input.sendKey(keysym: "BackSpace", down: true)
            input.sendKey(keysym: "BackSpace", down: false)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let sym = Self.x11Keysym(for: key) {
                handled = true
                Task { @MainActor in input.sendKey(keysym: sym, down: true) }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let sym = Self.x11Keysym(for: key) {
                handled = true
                Task { @MainActor in input.sendKey(keysym: sym, down: false) }
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    private static func x11Keysym(for key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardReturnOrEnter: return "Return"
        case .keyboardEscape: return "Escape"
        case .keyboardDeleteOrBackspace: return "BackSpace"
        case .keyboardTab: return "Tab"
        case .keyboardSpacebar: return "space"
        case .keyboardUpArrow: return "Up"
        case .keyboardDownArrow: return "Down"
        case .keyboardLeftArrow: return "Left"
        case .keyboardRightArrow: return "Right"
        case .keyboardLeftControl, .keyboardRightControl: return "Control_L"
        case .keyboardLeftAlt, .keyboardRightAlt: return "Alt_L"
        case .keyboardLeftShift, .keyboardRightShift: return "Shift_L"
        case .keyboardLeftGUI, .keyboardRightGUI: return "Super_L"
        case .keyboardF1: return "F1"
        case .keyboardF2: return "F2"
        default:
            let ch = key.charactersIgnoringModifiers
            return ch.count == 1 ? ch : nil
        }
    }
}

struct LinuxMetalDesktopCanvas: UIViewRepresentable {
    let shmURL: URL
    @ObservedObject var input: LinuxInputClient
    let status: LinuxDesktopStatus
    let notBefore: Date
    @Binding var softKeyboardEnabled: Bool

    func makeUIView(context: Context) -> LinuxDesktopCanvasUIView {
        let view = LinuxDesktopCanvasUIView(shmURL: shmURL, input: input, status: status, notBefore: notBefore)
        view.allowSoftKeyboard = softKeyboardEnabled
        return view
    }

    func updateUIView(_ uiView: LinuxDesktopCanvasUIView, context: Context) {
        uiView.allowSoftKeyboard = softKeyboardEnabled
        if softKeyboardEnabled {
            _ = uiView.becomeFirstResponder()
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

// MARK: - SwiftUI Desktop Container

struct LinuxDesktopView: View {
    let rootfsURL: URL
    var notBefore = Date.distantPast
    @StateObject private var input = LinuxInputClient()
    @StateObject private var status = LinuxDesktopStatus()
    @State private var softKeyboard = false

    private var shmURL: URL {
        rootfsURL.appendingPathComponent("data/dev/shm/Xvfb_screen0")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinuxMetalDesktopCanvas(shmURL: shmURL, input: input, status: status, notBefore: notBefore, softKeyboardEnabled: $softKeyboard)
                .ignoresSafeArea(.container, edges: .bottom)
            if status.frames == 0 {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for the desktop. Xfce takes a minute to start on the interpreter.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }

            HStack(spacing: 10) {
                Button("Alt+F2") {
                    input.sendKeyCombo(mods: ["Alt_L"], keysym: "F2")
                }
                Button("Ctrl+C") {
                    input.sendKeyCombo(mods: ["Control_L"], keysym: "c")
                }
                Button {
                    softKeyboard.toggle()
                } label: {
                    Image(systemName: softKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                }
                Circle()
                    .fill(input.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityElement()
                    .accessibilityIdentifier("linux-desktop-input")
                    .accessibilityValue(input.isConnected ? "connected" : "waiting")
            }
            .font(.caption.monospaced())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(14)
        }
        .onAppear { input.connect(port: 5950) }
        .onDisappear { input.disconnect() }
    }
}
