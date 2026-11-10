import UIKit

// The layouts, drawn with plain UIKit. Sizes and spacing are the dashboard
// preview's (web/src/lib/components/dak/InAppPreview.svelte), which are the
// Flutter SDK's: points here are its dp.

/// The window a message shows in, one per scene, above the app's windows.
/// A banner's window lets touches outside the banner through to the app.
final class InAppWindow: UIWindow {
    var passThrough = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if passThrough && (hit === self || hit === rootViewController?.view) { return nil }
        return hit
    }
}

/// The root view: Escape for VoiceOver (the two-finger scrub) closes the
/// message.
final class InAppRootView: UIView {
    var onEscape: (() -> Void)?

    override func accessibilityPerformEscape() -> Bool {
        guard let onEscape else { return false }
        onEscape()
        return true
    }
}

/// Strings the system already has in the user's language.
@MainActor
enum InAppStrings {
    /// The system close button's label ("Close", localized).
    static let close: String = {
        if let label = UIButton(type: .close).accessibilityLabel, !label.isEmpty { return label }
        return "Close"
    }()
}

/// A label that VoiceOver can activate: a tappable message's text.
final class InAppLabel: UILabel {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

/// A message's scroll view: buttons get their touches at once (a quick tap
/// is never lost to the scroll view's wait), and a drag that starts on a
/// button still scrolls.
final class InAppScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl ? true : super.touchesShouldCancel(in: view)
    }
}

// MARK: - Colours and type

/// Colours as the Flutter SDK picks them: the message's own, else the
/// theme's; text on a background the message sets is black or white,
/// whichever reads.
struct InAppColors {
    let background: UIColor
    let title: UIColor
    let body: UIColor
    /// The X of a modal, card or full-screen message without an image.
    let close: UIColor
    let bannerClose: UIColor
    let buttons: [(background: UIColor?, foreground: UIColor)]

    init(_ m: InAppMessage, theme: DakInAppTheme, tint: UIColor) {
        let c = m.content
        let surface = theme.surface ?? (m.layout == .fullscreen ? UIColor.systemBackground : Self.elevatedBackground)
        background = c.backgroundColor.map(Self.color) ?? surface
        let onBackground = c.backgroundColor.map { Self.readable(on: Self.color($0)) } ?? theme.onSurface ?? .label
        let onVariant =
            c.backgroundColor == nil ? (theme.onSurfaceVariant ?? .secondaryLabel) : onBackground.withAlphaComponent(0.75)
        title = c.titleColor.map(Self.color) ?? onBackground
        body = c.bodyColor.map(Self.color) ?? onVariant
        close = c.titleColor.map(Self.color) ?? onBackground
        bannerClose = c.titleColor.map(Self.color) ?? onVariant
        let primary = theme.primary ?? tint
        let onPrimary = theme.onPrimary ?? Self.readable(onDynamic: primary)
        buttons = c.buttons.enumerated().map { i, b in
            let bg = b.backgroundColor.map(Self.color) ?? (i == 0 ? primary : nil)
            let fg =
                b.textColor.map(Self.color)
                ?? (b.backgroundColor != nil
                    ? Self.readable(on: Self.color(b.backgroundColor!))
                    : i == 0 ? onPrimary : (c.backgroundColor == nil ? primary : onBackground))
            return (bg, fg)
        }
    }

    /// The system background as iOS draws raised things (sheets, alerts):
    /// a lighter grey in dark mode.
    static let elevatedBackground = UIColor { traits in
        UIColor.systemBackground.resolvedColor(
            with: UITraitCollection(traitsFrom: [traits, UITraitCollection(userInterfaceLevel: .elevated)]))
    }

    static func color(_ argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    /// White on a dark colour, black (87 %) on a light one: Flutter's
    /// estimateBrightnessForColor.
    static func readable(on color: UIColor) -> UIColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return (l + 0.05) * (l + 0.05) > 0.15 ? UIColor(white: 0, alpha: 0xDE / 255.0) : .white
    }

    /// [readable(on:)] for a colour that changes with dark mode.
    static func readable(onDynamic color: UIColor) -> UIColor {
        UIColor { traits in readable(on: color.resolvedColor(with: traits)) }
    }

    /// Whether text on [color] should be light (for the status bar).
    static func isDark(_ color: UIColor, _ traits: UITraitCollection) -> Bool {
        readable(on: color.resolvedColor(with: traits)) == .white
    }
}

/// The type sizes of the preview (Material's), scaled with Dynamic Type.
enum InAppType {
    case title, headline, titleSmall, body, button

    var size: CGFloat {
        switch self {
        case .title: return 22
        case .headline: return 24
        case .titleSmall, .body, .button: return 14
        }
    }

    var lineHeight: CGFloat {
        switch self {
        case .title: return 28
        case .headline: return 32
        case .titleSmall, .body, .button: return 20
        }
    }

    var weight: UIFont.Weight {
        switch self {
        case .title, .headline, .titleSmall: return .semibold
        case .body: return .regular
        case .button: return .medium
        }
    }

    /// The Dynamic Type curve it scales by.
    var style: UIFont.TextStyle {
        switch self {
        case .title: return .title2
        case .headline: return .title1
        case .titleSmall: return .subheadline
        case .body, .button: return .body
        }
    }

    func font(_ traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: size, weight: weight), compatibleWith: traits)
    }

    /// [text] in this type: the line height grows with the font and is a
    /// minimum, so tall scripts (Bangla) are never clipped.
    func text(_ text: String, color: UIColor, alignment: NSTextAlignment, traits: UITraitCollection)
        -> NSAttributedString
    {
        let font = font(traits)
        let line = lineHeight * font.pointSize / size
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = line
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                .baselineOffset: max(0, (line - font.lineHeight) / 4),
            ])
    }
}

// MARK: - Pieces

/// A button: filled (40 high, round ends) when it has a background, else a
/// text button.
final class InAppButtonView: UIControl {
    let button: InAppButton
    private let label = UILabel()
    private let filled: Bool

    init(_ button: InAppButton, background: UIColor?, foreground: UIColor, traits: UITraitCollection, wraps: Bool) {
        self.button = button
        filled = background != nil
        super.init(frame: .zero)
        backgroundColor = background
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        label.attributedText = InAppType.button.text(button.text, color: foreground, alignment: .center, traits: traits)
        label.numberOfLines = wraps ? 0 : 1
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let side: CGFloat = filled ? 24 : 12
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        isAccessibilityElement = true
        accessibilityLabel = button.text
        accessibilityTraits = .button
        accessibilityIdentifier = "dak-in-app-button-\(button.id)"
        addInteraction(UIPointerInteraction(delegate: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

// MARK: - The view controller

/// Draws one message in its layout. [onClick] gets a button, or nil for a
/// tap on the message itself; [onDismiss] the user closing it (the X, a tap
/// outside, a swipe, Escape, or the banner's timer).
final class InAppViewController: UIViewController, UIGestureRecognizerDelegate {
    let message: InAppMessage
    private let image: UIImage?
    private let theme: DakInAppTheme
    /// The app's view controller whose orientations and status bar this one
    /// keeps.
    private weak var appTop: UIViewController?
    var onClick: ((InAppButton?) -> Void)?
    var onDismiss: (() -> Void)?

    /// The keyboard, in screen coordinates, if one is up.
    var keyboardFrame: CGRect? {
        didSet { if isViewLoaded { updateKeyboard() } }
    }

    private var root: InAppRootView { view as! InAppRootView }
    private var backdrop = UIControl()
    /// What moves in and out (with the shadow).
    private var panel = UIView()
    /// The message's own surface (clips the image to the corners).
    private var sheet = UIView()
    private(set) var closeButton: UIButton?
    private(set) var buttonViews: [InAppButtonView] = []
    private(set) var titleLabel: UILabel?
    private(set) var bodyLabel: UILabel?
    private(set) var imageView: UIImageView?
    /// The region above the keyboard and inside the safe area.
    private let area = UILayoutGuide()
    private var areaConstraints: [NSLayoutConstraint] = []
    private var areaBottom: NSLayoutConstraint?
    private var keyboardBottom: NSLayoutConstraint?
    /// The type size and language direction the views were made for.
    private var builtFor: (UIContentSizeCategory, UITraitEnvironmentLayoutDirection)?
    private var autoDismiss: DispatchWorkItem?
    private var leaving = false
    private var swipedAway = false

    init(message: InAppMessage, image: UIImage?, theme: DakInAppTheme, appTop: UIViewController?) {
        self.message = message
        self.image = message.content.hasImage ? image : nil
        self.theme = theme
        self.appTop = appTop
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var layout: InAppLayout { message.layout }
    var blocking: Bool { !layout.isBanner }

    override func loadView() {
        let v = InAppRootView()
        v.onEscape = { [weak self] in self?.dismissByUser() }
        v.accessibilityIdentifier = "dak-in-app-\(layout.rawValue)"
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addLayoutGuide(area)
        build()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Dynamic Type or the language direction changed: the type and the
        // button rows are made anew.
        if let built = builtFor, built != (traitCollection.preferredContentSizeCategory, direction) {
            build()
            if !leaving { setIn() }
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateKeyboard()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.updateKeyboard() })
    }

    // MARK: Orientation and status bar: the app's

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        appTop?.supportedInterfaceOrientations ?? .all
    }

    override var shouldAutorotate: Bool { true }

    override var prefersStatusBarHidden: Bool { appTop?.prefersStatusBarHidden ?? false }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if layout == .fullscreen {
            return InAppColors.isDark(colors.background, traitCollection) ? .lightContent : .darkContent
        }
        return appTop?.preferredStatusBarStyle ?? .default
    }

    // MARK: Keyboard (hardware): Escape closes

    override var canBecomeFirstResponder: Bool { blocking }

    override var keyCommands: [UIKeyCommand]? {
        guard blocking else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escapePressed() {
        dismissByUser()
    }

    // MARK: Building

    private lazy var colors = InAppColors(message, theme: theme, tint: view.tintColor ?? .systemBlue)

    private var c: InAppContent { message.content }

    /// The language direction: the traits', else the app's.
    private var direction: UITraitEnvironmentLayoutDirection {
        switch traitCollection.layoutDirection {
        case .leftToRight, .rightToLeft: return traitCollection.layoutDirection
        default:
            return UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }
    }

    private func build() {
        builtFor = (traitCollection.preferredContentSizeCategory, direction)
        for v in view.subviews { v.removeFromSuperview() }
        NSLayoutConstraint.deactivate(areaConstraints)
        view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
        backdrop = UIControl()
        panel = UIView()
        sheet = UIView()
        closeButton = nil
        buttonViews = []
        titleLabel = nil
        bodyLabel = nil
        imageView = nil
        areaBottom = nil
        keyboardBottom = nil

        let safe = view.safeAreaLayoutGuide
        let bottom = area.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        areaBottom = bottom
        areaConstraints = [
            area.topAnchor.constraint(equalTo: safe.topAnchor),
            area.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            bottom,
        ]
        NSLayoutConstraint.activate(areaConstraints)

        switch layout {
        case .modal: buildModal()
        case .card: buildCard()
        case .fullscreen: buildFullscreen()
        case .bannerTop, .bannerBottom: buildBanner(top: layout == .bannerTop)
        }
        updateKeyboard()
        setUpAccessibility()
    }

    private func pin(_ v: UIView, in parent: UIView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// Dims the app behind a modal or card; a tap on it closes the message.
    private func addBackdrop() {
        backdrop.backgroundColor = UIColor(white: 0, alpha: 0x8A / 255.0)
        backdrop.addTarget(self, action: #selector(backdropTapped), for: .touchUpInside)
        backdrop.accessibilityIdentifier = "dak-in-app-backdrop"
        // Screen readers get the backdrop as a way out only when there is no X.
        backdrop.isAccessibilityElement = !message.showsClose
        backdrop.accessibilityLabel = InAppStrings.close
        backdrop.accessibilityTraits = .button
        pin(backdrop, in: view)
    }

    @objc private func backdropTapped() {
        dismissByUser()
    }

    private func shadow(_ v: UIView, radius: CGFloat, y: CGFloat, opacity: Float) {
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = opacity
        v.layer.shadowRadius = radius
        v.layer.shadowOffset = CGSize(width: 0, height: y)
    }

    private func label(_ text: String, _ type: InAppType, color: UIColor, alignment: NSTextAlignment, lines: Int)
        -> UILabel
    {
        // Start-aligned text follows the app's language direction (right to
        // left too), not the text's.
        let resolved = alignment == .natural ? (direction == .rightToLeft ? NSTextAlignment.right : .left) : alignment
        let l = InAppLabel()
        l.attributedText = type.text(text, color: color, alignment: resolved, traits: traitCollection)
        l.textAlignment = resolved
        l.numberOfLines = lines
        l.lineBreakMode = lines == 0 ? .byWordWrapping : .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        return l
    }

    private func titleView(_ type: InAppType, alignment: NSTextAlignment, lines: Int = 0) -> UILabel? {
        guard c.hasTitle, let text = c.title else { return nil }
        let l = label(text, type, color: colors.title, alignment: alignment, lines: lines)
        l.accessibilityTraits = .header
        l.accessibilityIdentifier = "dak-in-app-title"
        titleLabel = l
        return l
    }

    private func bodyView(alignment: NSTextAlignment, lines: Int = 0) -> UILabel? {
        guard c.hasBody, let text = c.body else { return nil }
        let l = label(text, .body, color: colors.body, alignment: alignment, lines: lines)
        l.accessibilityIdentifier = "dak-in-app-body"
        bodyLabel = l
        return l
    }

    private func makeImageView() -> UIImageView? {
        guard let image else { return nil }
        let v = UIImageView(image: image)
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.isAccessibilityElement = false
        v.accessibilityIdentifier = "dak-in-app-image"
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView = v
        return v
    }

    /// One or two buttons side by side, three stacked; stacked too at the
    /// accessibility type sizes, where labels wrap instead of being cut.
    private func buttonsView() -> UIView? {
        guard !c.buttons.isEmpty else { return nil }
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttonViews = c.buttons.enumerated().map { i, b in
            let colors = self.colors.buttons[i]
            let v = InAppButtonView(
                b, background: colors.background, foreground: colors.foreground, traits: traitCollection, wraps: large)
            v.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            return v
        }
        let stack = UIStackView(arrangedSubviews: buttonViews)
        stack.spacing = 8
        if buttonViews.count <= 2 && !large {
            stack.axis = .horizontal
            stack.distribution = .fillEqually
        } else {
            stack.axis = .vertical
            stack.distribution = .fill
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func buttonTapped(_ sender: InAppButtonView) {
        guard !leaving else { return }
        onClick?(sender.button)
    }

    private func makeClose(size: CGFloat, color: UIColor, onImage: Bool) -> UIButton {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        b.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        b.tintColor = onImage ? .white : color
        if onImage {
            b.backgroundColor = UIColor(white: 0, alpha: 0x42 / 255.0)
            b.layer.cornerRadius = 20
        }
        b.accessibilityLabel = InAppStrings.close
        b.accessibilityIdentifier = "dak-in-app-close"
        b.isPointerInteractionEnabled = true
        b.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 40), b.heightAnchor.constraint(equalToConstant: 40),
        ])
        closeButton = b
        return b
    }

    @objc private func closeTapped() {
        dismissByUser()
    }

    /// Title, body and buttons, centred, with the preview's padding.
    private func texts(top: CGFloat, bottom: CGFloat = 16) -> UIView {
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = titleView(.title, alignment: .center)
        let body = bodyView(alignment: .center)
        if let title { stack.addArrangedSubview(title) }
        if let body {
            if let title { stack.setCustomSpacing(8, after: title) }
            stack.addArrangedSubview(body)
        }
        if let buttons = buttonsView() {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(20, after: last) }
            stack.addArrangedSubview(buttons)
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
        ])
        return box
    }

    /// A scroll view whose frame is as tall as its content, down to what the
    /// constraints around it allow.
    private func scroll(_ inner: UIView) -> UIScrollView {
        let s = InAppScrollView()
        s.contentInsetAdjustmentBehavior = .never
        s.alwaysBounceVertical = false
        s.showsHorizontalScrollIndicator = false
        s.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        s.addSubview(inner)
        let fit = s.frameLayoutGuide.heightAnchor.constraint(equalTo: s.contentLayoutGuide.heightAnchor)
        fit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: s.contentLayoutGuide.topAnchor),
            inner.bottomAnchor.constraint(equalTo: s.contentLayoutGuide.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: s.contentLayoutGuide.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: s.contentLayoutGuide.trailingAnchor),
            inner.widthAnchor.constraint(equalTo: s.frameLayoutGuide.widthAnchor),
            fit,
        ])
        return s
    }

    /// Taps on the message itself run its click action (not on its buttons
    /// or X, which have their own).
    private func addTap(to v: UIView) {
        guard c.clickAction != nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(messageTapped))
        tap.delegate = self
        v.addGestureRecognizer(tap)
    }

    @objc private func messageTapped() {
        guard !leaving else { return }
        onClick?(nil)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v {
            if current is UIControl { return g is UIPanGestureRecognizer }
            v = current.superview
        }
        return true
    }

    // MARK: Layouts

    private func buildModal() {
        view.backgroundColor = .clear
        addBackdrop()
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        shadow(panel, radius: 16, y: 8, opacity: 0.22)
        sheet.backgroundColor = colors.background
        sheet.layer.cornerRadius = 20
        sheet.layer.cornerCurve = .continuous
        sheet.clipsToBounds = true
        sheet.accessibilityIdentifier = "dak-in-app-sheet"
        pin(sheet, in: panel)

        let column = UIStackView()
        column.axis = .vertical
        if let img = makeImageView() {
            column.addArrangedSubview(img)
            let ratio = img.heightAnchor.constraint(
                equalTo: img.widthAnchor, multiplier: (image?.size.height ?? 1) / max(image?.size.width ?? 1, 1))
            ratio.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([ratio, img.heightAnchor.constraint(lessThanOrEqualToConstant: 240)])
        }
        column.addArrangedSubview(texts(top: imageView == nil ? 36 : 20))
        let s = scroll(column)
        pin(s, in: sheet)
        addTap(to: column)
        if message.showsClose {
            let x = makeClose(size: 20, color: colors.close, onImage: imageView != nil)
            sheet.addSubview(x)
            NSLayoutConstraint.activate([
                x.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 4),
                x.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -4),
            ])
        }
        let fill = panel.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -48)
        fill.priority = UILayoutPriority(999)
        let center = panel.centerYAnchor.constraint(equalTo: area.centerYAnchor)
        center.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            center,
            fill,
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 24),
            panel.topAnchor.constraint(greaterThanOrEqualTo: area.topAnchor, constant: 24),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: area.bottomAnchor, constant: -24),
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.85),
        ])
    }

    private func buildCard() {
        view.backgroundColor = .clear
        addBackdrop()
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        shadow(panel, radius: 16, y: -2, opacity: 0.2)
        sheet.backgroundColor = colors.background
        sheet.layer.cornerRadius = 24
        sheet.layer.cornerCurve = .continuous
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.clipsToBounds = true
        sheet.accessibilityIdentifier = "dak-in-app-sheet"
        pin(sheet, in: panel)

        let column = UIStackView()
        column.axis = .vertical
        if let img = makeImageView() {
            column.addArrangedSubview(img)
            img.heightAnchor.constraint(equalToConstant: 200).isActive = true
        } else {
            let gap = UIView()
            gap.heightAnchor.constraint(equalToConstant: 16).isActive = true
            column.addArrangedSubview(gap)
        }
        column.addArrangedSubview(texts(top: 20))
        let s = scroll(column)
        sheet.addSubview(s)
        // The sheet runs under the home indicator; its content stays above it.
        let inner = sheet.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: sheet.topAnchor),
            s.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            s.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
        ])
        addTap(to: column)
        if message.showsClose {
            let x = makeClose(size: 20, color: colors.close, onImage: imageView != nil)
            sheet.addSubview(x)
            NSLayoutConstraint.activate([
                x.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 8),
                x.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -4),
            ])
        }
        let full = panel.widthAnchor.constraint(equalTo: view.widthAnchor)
        full.priority = UILayoutPriority(999)
        let kb = panel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        keyboardBottom = kb
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            full,
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            kb,
            panel.topAnchor.constraint(greaterThanOrEqualTo: area.topAnchor),
            panel.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.9),
        ])
    }

    private func buildFullscreen() {
        view.backgroundColor = colors.background
        let safe = view.safeAreaLayoutGuide
        let textBox = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        if let title = titleView(.headline, alignment: .center) { stack.addArrangedSubview(title) }
        if let body = bodyView(alignment: .center) {
            if let title = titleLabel { stack.setCustomSpacing(12, after: title) }
            stack.addArrangedSubview(body)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        textBox.addSubview(stack)
        let s = scroll(textBox)
        view.addSubview(s)
        // Short text sits in the middle of its part of the page.
        let low = stack.centerYAnchor.constraint(equalTo: textBox.centerYAnchor)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: textBox.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: textBox.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(greaterThanOrEqualTo: textBox.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: textBox.bottomAnchor, constant: -24),
            low,
            textBox.heightAnchor.constraint(greaterThanOrEqualTo: s.frameLayoutGuide.heightAnchor),
        ])
        let textTop: NSLayoutYAxisAnchor
        if let img = makeImageView() {
            view.addSubview(img)
            NSLayoutConstraint.activate([
                img.topAnchor.constraint(equalTo: safe.topAnchor),
                img.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                img.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                // The preview's flex 5 : 4.
                img.heightAnchor.constraint(equalTo: s.heightAnchor, multiplier: 5.0 / 4.0),
            ])
            textTop = img.bottomAnchor
        } else {
            textTop = safe.topAnchor
        }
        let textBottom: NSLayoutYAxisAnchor
        if let buttons = buttonsView() {
            view.addSubview(buttons)
            NSLayoutConstraint.activate([
                buttons.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
                buttons.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
                buttons.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -20),
            ])
            textBottom = buttons.topAnchor
        } else {
            textBottom = safe.bottomAnchor
        }
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: textTop),
            s.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            s.bottomAnchor.constraint(equalTo: textBottom),
        ])
        addTap(to: view)
        if message.showsClose {
            let x = makeClose(size: 20, color: colors.close, onImage: imageView != nil)
            view.addSubview(x)
            NSLayoutConstraint.activate([
                x.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
                x.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
            ])
        }
        panel.removeFromSuperview()
    }

    private func buildBanner(top: Bool) {
        view.backgroundColor = .clear
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        shadow(panel, radius: 12, y: 4, opacity: 0.2)
        sheet.backgroundColor = colors.background
        sheet.layer.cornerRadius = 16
        sheet.layer.cornerCurve = .continuous
        sheet.clipsToBounds = true
        sheet.accessibilityIdentifier = "dak-in-app-sheet"
        pin(sheet, in: panel)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        if let img = makeImageView() {
            img.layer.cornerRadius = 10
            img.layer.cornerCurve = .continuous
            NSLayoutConstraint.activate([
                img.widthAnchor.constraint(equalToConstant: 48), img.heightAnchor.constraint(equalToConstant: 48),
            ])
            row.addArrangedSubview(img)
            row.setCustomSpacing(12, after: img)
        }
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .fill
        if let title = titleView(.titleSmall, alignment: .natural, lines: 2) { column.addArrangedSubview(title) }
        if let body = bodyView(alignment: .natural, lines: 3) {
            if let title = titleLabel { column.setCustomSpacing(2, after: title) }
            column.addArrangedSubview(body)
        }
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(column)
        if message.showsClose {
            let x = makeClose(size: 18, color: colors.bannerClose, onImage: false)
            row.addArrangedSubview(x)
        } else {
            let gap = UIView()
            gap.widthAnchor.constraint(equalToConstant: 8).isActive = true
            row.addArrangedSubview(gap)
        }
        sheet.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -10),
        ])
        addTap(to: sheet)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        panel.addGestureRecognizer(pan)

        let fill = panel.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -24)
        fill.priority = UILayoutPriority(999)
        var list = [
            panel.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            fill,
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 12),
        ]
        if top {
            list.append(panel.topAnchor.constraint(equalTo: area.topAnchor, constant: 12))
            list.append(panel.bottomAnchor.constraint(lessThanOrEqualTo: area.bottomAnchor, constant: -12))
        } else {
            list.append(panel.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -12))
            list.append(panel.topAnchor.constraint(greaterThanOrEqualTo: area.topAnchor, constant: 12))
        }
        NSLayoutConstraint.activate(list)
        scheduleAutoDismiss()
    }

    // MARK: Keyboard

    /// How much of the view the keyboard covers from the bottom.
    var keyboardOverlap: CGFloat {
        guard let frame = keyboardFrame, let window = view.window, frame.height > 0 else { return 0 }
        let kb = view.convert(frame, from: window.screen.coordinateSpace)
        // A floating or undocked keyboard covers nothing below it.
        guard kb.maxY >= view.bounds.maxY - 1 else { return 0 }
        return max(0, view.bounds.maxY - kb.minY)
    }

    private func updateKeyboard() {
        let overlap = keyboardOverlap
        areaBottom?.constant = -max(view.safeAreaInsets.bottom, overlap)
        keyboardBottom?.constant = -overlap
    }

    /// The keyboard moves; the message moves with it.
    func keyboardChanged(_ frame: CGRect?, duration: TimeInterval) {
        keyboardFrame = frame
        guard isViewLoaded, view.window != nil else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: Accessibility

    private func setUpAccessibility() {
        // Modal layouts read as a dialog: nothing behind them.
        root.accessibilityViewIsModal = blocking
        // A tappable message reads its title and text as one button.
        if c.clickAction != nil, let first = (titleLabel ?? bodyLabel) as? InAppLabel {
            let texts = [titleLabel, bodyLabel].compactMap { $0?.attributedText?.string }
            first.accessibilityLabel = texts.joined(separator: ", ")
            first.accessibilityTraits = layout.isBanner ? .button : [.header, .button]
            first.onActivate = { [weak self] in self?.messageTapped() }
            if first !== bodyLabel { bodyLabel?.isAccessibilityElement = false }
        }
        // A banner's text can close it from the actions rotor too.
        if layout.isBanner {
            for l in [titleLabel, bodyLabel].compactMap({ $0 }) {
                l.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: InAppStrings.close) { [weak self] _ in
                        self?.dismissByUser()
                        return true
                    }
                ]
            }
        }
    }

    /// What VoiceOver should read first.
    var firstElement: Any? { titleLabel ?? bodyLabel ?? buttonViews.first ?? closeButton }

    /// What VoiceOver says when a banner appears.
    var announcement: String {
        [c.hasTitle ? c.title : nil, c.hasBody ? c.body : nil].compactMap { $0 }.joined(separator: ". ")
    }

    // MARK: Banner gestures and timer

    /// Screen reader users need the time it takes to find the banner: no
    /// timer for them.
    private func scheduleAutoDismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        guard layout.isBanner, let after = c.autoDismiss else { return }
        if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning { return }
        let item = DispatchWorkItem { [weak self] in self?.dismissByUser() }
        autoDismiss = item
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let top = layout == .bannerTop
        let dy = g.translation(in: view).y
        // Towards the edge it came from it follows the finger; the other way
        // it resists.
        let away = top ? -dy : dy
        switch g.state {
        case .began:
            autoDismiss?.cancel()
        case .changed:
            panel.transform = CGAffineTransform(translationX: 0, y: away > 0 ? dy : dy / 4)
        case .ended, .cancelled, .failed:
            let speed = top ? -g.velocity(in: view).y : g.velocity(in: view).y
            if g.state == .ended && (away > panel.bounds.height * 0.4 || speed > 600) {
                swipedAway = true
                let off = top ? -(panel.frame.maxY + 20) : view.bounds.height - panel.frame.minY + 20
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn]) {
                    self.panel.transform = CGAffineTransform(translationX: 0, y: off)
                } completion: { _ in
                    self.dismissByUser()
                }
            } else {
                UIView.animate(
                    withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                    options: [.allowUserInteraction]
                ) {
                    self.panel.transform = .identity
                }
                scheduleAutoDismiss()
            }
        default:
            break
        }
    }

    private func dismissByUser() {
        guard !leaving else { return }
        onDismiss?()
    }

    // MARK: In and out

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// What the message looks like before it comes in (and after it goes).
    private func setOut() {
        let reduce = reduceMotion
        switch layout {
        case .modal:
            backdrop.alpha = 0
            panel.alpha = 0
            if !reduce { panel.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }
        case .card:
            backdrop.alpha = 0
            panel.alpha = 0
            if !reduce { panel.transform = CGAffineTransform(translationX: 0, y: panel.bounds.height) }
        case .fullscreen:
            view.alpha = 0
        case .bannerTop:
            panel.alpha = 0
            if !reduce { panel.transform = CGAffineTransform(translationX: 0, y: -panel.frame.maxY) }
        case .bannerBottom:
            panel.alpha = 0
            if !reduce { panel.transform = CGAffineTransform(translationX: 0, y: view.bounds.height - panel.frame.minY) }
        }
    }

    private func setIn() {
        backdrop.alpha = 1
        panel.alpha = 1
        panel.transform = .identity
        view.alpha = 1
    }

    /// Slides, scales or fades in (a fade only with Reduce Motion).
    func animateIn() {
        view.layoutIfNeeded()
        setOut()
        let animator = UIViewPropertyAnimator(
            duration: reduceMotion ? 0.15 : 0.22, controlPoint1: CGPoint(x: 0.215, y: 0.61),
            controlPoint2: CGPoint(x: 0.355, y: 1))
        animator.addAnimations { self.setIn() }
        animator.startAnimation()
    }

    /// The reverse, then [completion].
    func animateOut(_ completion: @escaping () -> Void) {
        leaving = true
        autoDismiss?.cancel()
        view.isUserInteractionEnabled = false
        if swipedAway {
            UIView.animate(withDuration: 0.1, animations: { self.panel.alpha = 0 }, completion: { _ in completion() })
            return
        }
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? 0.12 : 0.18, curve: .easeIn)
        animator.addAnimations { self.setOut() }
        animator.addCompletion { _ in completion() }
        animator.startAnimation()
    }
}
