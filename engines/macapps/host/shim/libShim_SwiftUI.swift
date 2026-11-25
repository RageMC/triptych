import Foundation
import UIKit
import SwiftUI

// MARK: - Color & Image bridges

@_silgen_name("$s7SwiftUI5ColorVyACSo7NSColorCcfC")
public func _shim_Color_init_nsColor(_ nsColor: NSColor) -> Color {
    Color(uiColor: nsColor.uiColor)
}

@_silgen_name("$s7SwiftUI5ImageV02nsC0ACSo7NSImageC_tcfC")
public func _shim_Image_init_nsImage(_ nsImage: NSImage) -> Image {
    Image(uiImage: nsImage.uiImage ?? UIImage())
}

// MARK: - NSHostingSizingOptions

public struct NSHostingSizingOptions: OptionSet, SetAlgebra, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let minSize = NSHostingSizingOptions(rawValue: 1 << 0)
    public static let intrinsicContentSize = NSHostingSizingOptions(rawValue: 1 << 1)
    public static let maxSize = NSHostingSizingOptions(rawValue: 1 << 2)
    public static let standardBounds: NSHostingSizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
}

// MARK: - NSHostingView & NSHostingController

private func attachHostingControllerView(_ uiView: UIView, to nsView: NSView) {
    uiView.backgroundColor = .clear
    uiView.frame = nsView.hostView.bounds
    uiView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    nsView.hostView.addSubview(uiView)
}

open class NSHostingView<Content: View>: NSView {
    private let hostingController: UIHostingController<Content>

    open var rootView: Content {
        didSet { hostingController.rootView = rootView }
    }

    open var sizingOptions: NSHostingSizingOptions = [.intrinsicContentSize]

    required public init(rootView: Content) {
        self.rootView = rootView
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        attachHostingControllerView(hostingController.view, to: self)
    }

    required public init?(coder: NSCoder, rootView: Content) {
        self.rootView = rootView
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        attachHostingControllerView(hostingController.view, to: self)
    }
}

open class NSHostingController<Content: View>: NSViewController {
    private let hostingController: UIHostingController<Content>

    open var rootView: Content {
        didSet { hostingController.rootView = rootView }
    }

    public init(rootView: Content) {
        self.rootView = rootView
        self.hostingController = UIHostingController(rootView: rootView)
        super.init()
    }

    open override func loadView() {
        let container = NSView(frame: .zero)
        attachHostingControllerView(hostingController.view, to: container)
        self.view = container
    }
}

// MARK: - NSViewRepresentable

@MainActor @preconcurrency
public struct NSViewRepresentableContext<Representable: NSViewRepresentable> {
    public let coordinator: Representable.Coordinator
    public let transaction: Transaction
    public let environment: EnvironmentValues

    internal init(coordinator: Representable.Coordinator, transaction: Transaction, environment: EnvironmentValues) {
        self.coordinator = coordinator
        self.transaction = transaction
        self.environment = environment
    }
}

@MainActor @preconcurrency
public protocol NSViewRepresentable: View where Body == Never {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void

    @MainActor @preconcurrency func makeNSView(context: Context) -> NSViewType
    @MainActor @preconcurrency func updateNSView(_ nsView: NSViewType, context: Context)
    @MainActor @preconcurrency static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
    @MainActor @preconcurrency func makeCoordinator() -> Coordinator
    @MainActor @preconcurrency func _identifiedViewTree(in nsView: NSViewType) -> _IdentifiedViewTree
    @MainActor @preconcurrency func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize?
    @MainActor @preconcurrency func _overrideSizeThatFits(_ size: inout CGSize, in proposedSize: _ProposedSize, nsView: NSViewType)
    @MainActor @preconcurrency func _overrideLayoutTraits(_ layoutTraits: inout _LayoutTraits, for nsView: NSViewType)
    @MainActor @preconcurrency static func _modifyBridgedViewInputs(_ inputs: inout _ViewInputs)
    @MainActor @preconcurrency static func _layoutOptions(_ provider: NSViewType) -> LayoutOptions
    @MainActor @preconcurrency static var _invalidatesSizeOnConstraintChanges: Bool { get }

    typealias Context = NSViewRepresentableContext<Self>
    typealias LayoutOptions = _PlatformViewRepresentableLayoutOptions
}

extension NSViewRepresentable where Coordinator == Void {
    @MainActor @preconcurrency public func makeCoordinator() -> Coordinator { () }
}

extension NSViewRepresentable {
    @MainActor @preconcurrency public static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {}
    @MainActor @preconcurrency public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? { nil }
    @MainActor @preconcurrency public func _overrideSizeThatFits(_ size: inout CGSize, in proposedSize: _ProposedSize, nsView: NSViewType) {}
    @MainActor @preconcurrency public func _overrideLayoutTraits(_ layoutTraits: inout _LayoutTraits, for nsView: NSViewType) {}
    @MainActor @preconcurrency public static func _modifyBridgedViewInputs(_ inputs: inout _ViewInputs) {}
    @MainActor @preconcurrency public static var _invalidatesSizeOnConstraintChanges: Bool { false }

    @MainActor @preconcurrency public func _identifiedViewTree(in nsView: NSViewType) -> _IdentifiedViewTree {
        .empty
    }

    @MainActor @preconcurrency public static func _layoutOptions(_ provider: NSViewType) -> LayoutOptions {
        LayoutOptions(rawValue: 0)
    }

    @MainActor @preconcurrency public var body: Never {
        fatalError("NSViewRepresentable.body should never be called")
    }

    nonisolated private var _bridgedToUIKit: BridgedNSView<Self> {
        BridgedNSView(representable: self)
    }

    nonisolated public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        BridgedNSView<Self>._makeView(view: view[\._bridgedToUIKit], inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        BridgedNSView<Self>._makeViewList(view: view[\._bridgedToUIKit], inputs: inputs)
    }
}

private final class BridgedNSViewHost<V: NSView>: UIView {
    let nsView: V
    init(nsView: V) {
        self.nsView = nsView
        super.init(frame: nsView.frame)
        let inner = nsView.hostView
        inner.frame = bounds
        inner.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(inner)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private struct BridgedNSView<R: NSViewRepresentable>: UIViewRepresentable {
    let representable: R

    func makeCoordinator() -> R.Coordinator {
        representable.makeCoordinator()
    }

    func makeUIView(context: UIViewRepresentableContext<BridgedNSView<R>>) -> BridgedNSViewHost<R.NSViewType> {
        let nsCtx = NSViewRepresentableContext<R>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        let v = representable.makeNSView(context: nsCtx)
        return BridgedNSViewHost(nsView: v)
    }

    func updateUIView(_ uiView: BridgedNSViewHost<R.NSViewType>, context: UIViewRepresentableContext<BridgedNSView<R>>) {
        let nsCtx = NSViewRepresentableContext<R>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        representable.updateNSView(uiView.nsView, context: nsCtx)
    }

    static func dismantleUIView(_ uiView: BridgedNSViewHost<R.NSViewType>, coordinator: R.Coordinator) {
        R.dismantleNSView(uiView.nsView, coordinator: coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BridgedNSViewHost<R.NSViewType>, context: UIViewRepresentableContext<BridgedNSView<R>>) -> CGSize? {
        let nsCtx = NSViewRepresentableContext<R>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        return representable.sizeThatFits(proposal, nsView: uiView.nsView, context: nsCtx)
    }

    func _identifiedViewTree(in uiView: BridgedNSViewHost<R.NSViewType>) -> _IdentifiedViewTree {
        representable._identifiedViewTree(in: uiView.nsView)
    }

    func _overrideSizeThatFits(_ size: inout CGSize, in proposedSize: _ProposedSize, uiView: BridgedNSViewHost<R.NSViewType>) {
        representable._overrideSizeThatFits(&size, in: proposedSize, nsView: uiView.nsView)
    }

    func _overrideLayoutTraits(_ layoutTraits: inout _LayoutTraits, for uiView: BridgedNSViewHost<R.NSViewType>) {
        representable._overrideLayoutTraits(&layoutTraits, for: uiView.nsView)
    }

    static func _modifyBridgedViewInputs(_ inputs: inout _ViewInputs) {
        R._modifyBridgedViewInputs(&inputs)
    }
}

// MARK: - NSViewControllerRepresentable

@MainActor @preconcurrency
public struct NSViewControllerRepresentableContext<Representable: NSViewControllerRepresentable> {
    public let coordinator: Representable.Coordinator
    public let transaction: Transaction
    public let environment: EnvironmentValues

    internal init(coordinator: Representable.Coordinator, transaction: Transaction, environment: EnvironmentValues) {
        self.coordinator = coordinator
        self.transaction = transaction
        self.environment = environment
    }
}

@MainActor @preconcurrency
public protocol NSViewControllerRepresentable: View where Body == Never {
    associatedtype NSViewControllerType: NSViewController
    associatedtype Coordinator = Void

    @MainActor @preconcurrency func makeNSViewController(context: Context) -> NSViewControllerType
    @MainActor @preconcurrency func updateNSViewController(_ nsViewController: NSViewControllerType, context: Context)
    @MainActor @preconcurrency static func dismantleNSViewController(_ nsViewController: NSViewControllerType, coordinator: Coordinator)
    @MainActor @preconcurrency func makeCoordinator() -> Coordinator
    @MainActor @preconcurrency func _identifiedViewTree(in nsViewController: NSViewControllerType) -> _IdentifiedViewTree
    @MainActor @preconcurrency func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSViewControllerType, context: Context) -> CGSize?
    @MainActor @preconcurrency static func _layoutOptions(_ provider: NSViewControllerType) -> LayoutOptions
    @MainActor @preconcurrency static var _invalidatesSizeOnConstraintChanges: Bool { get }

    typealias Context = NSViewControllerRepresentableContext<Self>
    typealias LayoutOptions = _PlatformViewRepresentableLayoutOptions
}

extension NSViewControllerRepresentable where Coordinator == Void {
    @MainActor @preconcurrency public func makeCoordinator() -> Coordinator { () }
}

extension NSViewControllerRepresentable {
    @MainActor @preconcurrency public static func dismantleNSViewController(_ nsViewController: NSViewControllerType, coordinator: Coordinator) {}
    @MainActor @preconcurrency public func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSViewControllerType, context: Context) -> CGSize? { nil }
    @MainActor @preconcurrency public static var _invalidatesSizeOnConstraintChanges: Bool { false }

    @MainActor @preconcurrency public func _identifiedViewTree(in nsViewController: NSViewControllerType) -> _IdentifiedViewTree {
        .empty
    }

    @MainActor @preconcurrency public static func _layoutOptions(_ provider: NSViewControllerType) -> LayoutOptions {
        LayoutOptions(rawValue: 0)
    }

    @MainActor @preconcurrency public var body: Never {
        fatalError("NSViewControllerRepresentable.body should never be called")
    }

    nonisolated private var _bridgedToUIKit: BridgedNSViewController<Self> {
        BridgedNSViewController(representable: self)
    }

    nonisolated public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        BridgedNSViewController<Self>._makeView(view: view[\._bridgedToUIKit], inputs: inputs)
    }

    nonisolated public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        BridgedNSViewController<Self>._makeViewList(view: view[\._bridgedToUIKit], inputs: inputs)
    }
}

private final class BridgedNSViewControllerHost<VC: NSViewController>: UIViewController {
    let nsViewController: VC
    init(nsViewController: VC) {
        self.nsViewController = nsViewController
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = UIView()
        let inner = nsViewController.view.hostView
        inner.frame = root.bounds
        inner.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(inner)
        self.view = root
    }
}

private struct BridgedNSViewController<R: NSViewControllerRepresentable>: UIViewControllerRepresentable {
    let representable: R

    func makeCoordinator() -> R.Coordinator {
        representable.makeCoordinator()
    }

    func makeUIViewController(context: UIViewControllerRepresentableContext<BridgedNSViewController<R>>) -> BridgedNSViewControllerHost<R.NSViewControllerType> {
        let nsCtx = NSViewControllerRepresentableContext<R>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        let vc = representable.makeNSViewController(context: nsCtx)
        return BridgedNSViewControllerHost(nsViewController: vc)
    }

    func updateUIViewController(_ uiViewController: BridgedNSViewControllerHost<R.NSViewControllerType>, context: UIViewControllerRepresentableContext<BridgedNSViewController<R>>) {
        let nsCtx = NSViewControllerRepresentableContext<R>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        representable.updateNSViewController(uiViewController.nsViewController, context: nsCtx)
    }

    static func dismantleUIViewController(_ uiViewController: BridgedNSViewControllerHost<R.NSViewControllerType>, coordinator: R.Coordinator) {
        R.dismantleNSViewController(uiViewController.nsViewController, coordinator: coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: BridgedNSViewControllerHost<R.NSViewControllerType>, context: UIViewControllerRepresentableContext<BridgedNSViewController<R>>) -> CGSize? {
        let nsCtx = NSViewControllerRepresentableContext<R>(
            coordinator: context.coordinator,
            transaction: context.transaction,
            environment: context.environment
        )
        return representable.sizeThatFits(proposal, nsViewController: uiViewController.nsViewController, context: nsCtx)
    }

    func _identifiedViewTree(in uiViewController: BridgedNSViewControllerHost<R.NSViewControllerType>) -> _IdentifiedViewTree {
        representable._identifiedViewTree(in: uiViewController.nsViewController)
    }
}

// macOS-only non-optional List(selection:content:) bridges to iOS List(selection: Binding<SelectionValue?>, content:).
@_silgen_name("$s7SwiftUI4ListV9selection7contentACyxq_GAA7BindingVyxG_q_yXEtcfC")
public func _shim_List_init_selection<SelectionValue: Hashable, Content: View>(
    selection: Binding<SelectionValue>,
    content: () -> Content
) -> List<SelectionValue, Content> {
    let opt = Binding<SelectionValue?>(
        get: { selection.wrappedValue },
        set: { if let v = $0 { selection.wrappedValue = v } }
    )
    return List<SelectionValue, Content>(selection: opt, content: content)
}

// macOS-only LinkButtonStyle (iOS SwiftUI's traps when used): a borderless button in the accent colour, like a
// link on macOS. gen_swiftui_aliases.py binds SwiftUI.LinkButtonStyle's symbols to this type.
public struct LinkButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.borderless).foregroundStyle(Color.accentColor)
    }
}
