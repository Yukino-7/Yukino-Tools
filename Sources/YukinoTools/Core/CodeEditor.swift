import SwiftUI
import AppKit

/// Native NSTextView with JSON coloring, undo, selection, and a scrolling line-number ruler.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    var highlightJSON = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.backgroundColor = .controlBackgroundColor
        view.drawsBackground = false
        view.delegate = context.coordinator
        scroll.documentView = view
        let ruler = LineRuler(textView: view, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.ruler = ruler
        view.string = text
        context.coordinator.color(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            context.coordinator.ruler?.needsDisplay = true
        }
        view.isEditable = editable
        context.coordinator.color(view)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var ruler: LineRuler?
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            color(view)
            ruler?.needsDisplay = true
        }
        func color(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let selection = view.selectedRanges
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor], range: range)
            if parent.highlightJSON && storage.length < 300_000 {
                let patterns: [(String, NSColor)] = [
                    (#"\b(true|false|null)\b"#, .systemPurple),
                    (#"(?<![\w\"])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#, .systemOrange),
                    (#"\"(?:[^\"\\]|\\.)*\""#, .systemGreen),
                    (#"\"(?:[^\"\\]|\\.)*\"(?=\s*:)"#, .systemBlue)
                ]
                for (pattern, color) in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    for match in regex.matches(in: view.string, range: range) {
                        storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
            }
            storage.endEditing()
            view.selectedRanges = selection
            view.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]
        }
    }
}

final class LineRuler: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
        wantsLayer = true
        layer?.masksToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init(coder: NSCoder) { fatalError("Not used") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refresh() { needsDisplay = true }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).fill()
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let visible = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let prefix = text.substring(to: min(characterRange.location, text.length))
        var line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var index = text.lineRange(for: NSRange(location: min(characterRange.location, text.length), length: 0)).location
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        while index < text.length {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = lineRect.minY + view.textContainerOrigin.y - visible.minY
            if y > rect.maxY { break }
            let label = "\(line)" as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 9, y: y + 1), withAttributes: attributes)
            let next = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            if next <= index { break }
            index = next
            line += 1
        }
        if text.length == 0 {
            ("1" as NSString).draw(at: NSPoint(x: 26, y: view.textContainerOrigin.y), withAttributes: attributes)
        }
    }
}

struct EditorPanel: View {
    let title: String
    @Binding var text: String
    var editable = true
    var json = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Text("\(text.utf8.count.formatted()) bytes").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).frame(height: 44).background(.quaternary.opacity(0.35))
            Divider()
            CodeEditor(text: $text, editable: editable, highlightJSON: json)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline, lineWidth: 0.5))
    }
}
