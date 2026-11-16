// The search row: sits between the header and the first item. It is a plain drawing until it is used, so an
// ordinary Option+Tab costs some text. Idle it is a quiet line that says how to get in, with no field look and nothing
// to click into: letters on the list are shortcuts, so it must not invite typing. Selected, the next letter starts the
// search. The text field exists only while typing. The same line shows a key's refusal for a moment.
import AppKit

final class SearchRowView: NSView {
    enum State { case idle, selected, typing }

    let theme: Theme
    var state: State = .idle { didSet { needsDisplay = true } }
    var hint: String = Tokens.Copy.searchHint { didSet { needsDisplay = true; layoutField() } }
    var onClick: (() -> Void)?
    private(set) var field: SearchField?
    private var note: String?
    private var noteTimer: Timer?

    // A word about the key just pressed; it fades back to the hint.
    func show(note text: String) {
        note = text
        needsDisplay = true
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in self?.note = nil; self?.needsDisplay = true }
    }
    deinit { noteTimer?.invalidate() }

    init(frame: NSRect, theme: Theme) {
        self.theme = theme
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    func startTyping(delegate: NSTextFieldDelegate) -> SearchField {
        let f = SearchField(frame: .zero)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = theme.titleFont
        f.textColor = theme.color(Tokens.Color.label)
        f.lineBreakMode = .byClipping
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.setAccessibilityLabel(Tokens.Copy.searchPlaceholder)
        f.placeholderAttributedString = NSAttributedString(string: Tokens.Copy.searchPlaceholder, attributes: [
            .font: theme.titleFont, .foregroundColor: theme.color(Tokens.Color.secondary)])
        f.delegate = delegate
        addSubview(f)
        field = f
        state = .typing
        hint = Tokens.Copy.searchFilesHint
        layoutField()
        return f
    }

    private func hintWidth() -> CGFloat { (hint as NSString).size(withAttributes: [.font: Tokens.Font.hint]).width }

    private func layoutField() {
        guard let field else { return }
        let x = theme.textStart - 2   // a text field insets its text by 2 pt; this lines it up with the row titles
        let right = bounds.width - theme.rowTrailing - (hint.isEmpty ? 0 : hintWidth() + 12)
        let h = ceil(theme.titleFont.boundingRectForFont.height)
        field.frame = NSRect(x: x, y: floor((bounds.height - h) / 2), width: max(40, right - x), height: h)
    }

    override func draw(_ dirty: NSRect) {
        let t = theme
        let row = bounds
        let selected = state == .selected
        if selected { t.drawSelection(in: row, tail: false) }   // no stripe tail here: the hint sits at the right end
        let s = Tokens.Size.searchGlyph
        if let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: s, weight: .regular)) {
            // Tinted solid, then drawn faint: a see-through tint over a black symbol comes out dark grey on a dark panel.
            let tinted = glass.tinted(selected ? t.color(Tokens.Color.selectionText) : t.color(Tokens.Color.label).withAlphaComponent(1))
            let size = tinted.size
            tinted.draw(in: NSRect(x: Tokens.Size.iconInset + (t.icon - size.width) / 2, y: row.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: selected ? 1 : (state == .idle ? 0.4 : 0.6))
        }
        if state != .typing {
            let idle = state == .idle
            let attrs: [NSAttributedString.Key: Any] = [.font: idle ? Tokens.Font.hint : (selected ? t.titleSelectedFont : t.titleFont), .paragraphStyle: searchPara,
                                                        .foregroundColor: selected ? t.color(Tokens.Color.selectionText) : t.color(Tokens.Color.tertiary)]
            ((idle ? SearchRowView.idleText : Tokens.Copy.searchPlaceholder) as NSString)
                .draw(with: NSRect(x: t.textStart, y: row.midY - (idle ? 7 : 9), width: row.width - t.textStart - 150, height: 18),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        let line = note ?? hint
        if !line.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.hint, .foregroundColor: selected ? t.color(Tokens.Color.selectionSub) : t.color(note == nil ? Tokens.Color.tertiary : Tokens.Color.label)]
            let width = (line as NSString).size(withAttributes: attrs).width
            (line as NSString).draw(at: NSPoint(x: row.maxX - t.rowTrailing - width, y: row.midY - 7), withAttributes: attrs)
        }
    }

    static let idleText = "Search"

    private var searchPara: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    override func isAccessibilityElement() -> Bool { field == nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { Tokens.Copy.searchPlaceholder }
}

// Swap has no Edit menu, so the usual Command keys are wired here. Command+Return shows a file in Finder.
final class SearchField: NSTextField {
    var onReveal: (() -> Void)?
    var onCommand: ((UInt16) -> Bool)?   // Command+a key the list knows: true when it was used

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return super.performKeyEquivalent(with: e) }
        if e.keyCode == 36 { onReveal?(); return true }
        if flags == .command, onCommand?(e.keyCode) == true { return true }
        let action: Selector?
        switch (e.charactersIgnoringModifiers ?? "").lowercased() {
        case "a": action = #selector(NSText.selectAll(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "z": action = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: e)
    }
}
