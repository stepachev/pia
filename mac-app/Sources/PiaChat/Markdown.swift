import SwiftUI

// Лёгкий Markdown: блоки (заголовки, списки, цитаты, код, таблицы, линии) разбираем сами,
// строчное (жирный, курсив, `код`, ссылки) — AttributedString(markdown:). Все цвета нейтральные.

enum MDBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case listItem(indent: Int, marker: String, text: String)
    case quote(String)
    case code(lang: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ src: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            // ```код```
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara()
                let fence = String(t.prefix(3))
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                blocks.append(.code(lang: lang, text: code.joined(separator: "\n")))
                continue
            }
            if t.isEmpty { flushPara(); i += 1; continue }
            // заголовок
            if let m = t.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushPara()
                blocks.append(.heading(m.1.count, String(m.2).trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                i += 1; continue
            }
            // линия
            if t.firstMatch(of: /^([-*_])(\s*\1){2,}$/) != nil {
                flushPara(); blocks.append(.rule); i += 1; continue
            }
            // таблица: строка с | и следующая — разделитель |---|
            if t.contains("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).firstMatch(of: /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/) != nil {
                flushPara()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || !r.contains("|") { break }
                    rows.append(cells(r)); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // цитата
            if t.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard r.hasPrefix(">") else { break }
                    q.append(String(r.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(q.joined(separator: "\n")))
                continue
            }
            // пункт списка
            if let m = line.firstMatch(of: /^(\s*)([-*+•]|\d{1,3}[.)])\s+(.*)$/) {
                flushPara()
                let indent = m.1.replacingOccurrences(of: "\t", with: "    ").count / 2
                let raw = String(m.2)
                var text = String(m.3)
                var marker = raw.first.map { "-*+•".contains($0) } == true ? "•" : raw.replacingOccurrences(of: ")", with: ".")
                if let c = text.firstMatch(of: /^\[([ xX])\]\s+(.*)$/) {
                    marker = c.1 == " " ? "☐" : "☑"
                    text = String(c.2)
                }
                // продолжение пункта на следующих строках с отступом
                i += 1
                while i < lines.count {
                    let nx = lines[i]
                    let nt = nx.trimmingCharacters(in: .whitespaces)
                    if nt.isEmpty || nx.firstMatch(of: /^(\s*)([-*+•]|\d{1,3}[.)])\s+/) != nil || !nx.hasPrefix("  ") { break }
                    text += "\n" + nt; i += 1
                }
                blocks.append(.listItem(indent: min(indent, 4), marker: marker, text: text))
                continue
            }
            para.append(line)
            i += 1
        }
        flushPara()
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var r = row.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Строчная разметка → AttributedString с нейтральными ссылками и кодом
    static func inline(_ s: String, size: CGFloat) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
        for run in a.runs {
            if run.link != nil {
                a[run.range].foregroundColor = .primary
                a[run.range].underlineStyle = .single
            }
            if let p = run.inlinePresentationIntent, p.contains(.code) {
                a[run.range].font = .system(size: size - 1, design: .monospaced)
                a[run.range].backgroundColor = Color.primary.opacity(0.08)
            }
        }
        return a
    }
}

struct MarkdownView: View, Equatable {
    let text: String
    var size: CGFloat = 13.5
    var secondary = false
    /// false — текст не выделяется и не перехватывает мышь (свёрнутый отчёт раскрывается щелчком)
    var selectable = true

    static func == (a: MarkdownView, b: MarkdownView) -> Bool {
        a.text == b.text && a.size == b.size && a.secondary == b.secondary && a.selectable == b.selectable
    }

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .tint(.primary)
    }

    private func inline(_ s: String, _ sz: CGFloat? = nil) -> Text {
        Text(MarkdownParser.inline(s, size: sz ?? size))
    }

    private var baseColor: NSColor { secondary ? .secondaryLabelColor : .labelColor }

    /// Абзацы, заголовки, пункты, цитаты — NSTextView (курсор «рука» над ссылками), см. MessageText.swift
    private func textBlock(_ s: String, size sz: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil, lineSpacing: CGFloat = 0) -> MessageText {
        MessageText(text: MDAttr.make(s, size: sz, weight: weight, color: color ?? baseColor, lineSpacing: lineSpacing), selectable: selectable)
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let s):
            textBlock(s, size: level <= 1 ? size + 4 : level == 2 ? size + 2 : size + 0.5, weight: .semibold)
                .padding(.top, 4)
        case .paragraph(let s):
            textBlock(s, size: size, lineSpacing: 2.5)
        case .listItem(let indent, let marker, let s):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(.system(size: marker == "•" ? size : size - 0.5, weight: marker == "•" ? .regular : .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: marker == "•" ? .center : .trailing)
                textBlock(s, size: size, lineSpacing: 2.5)
                    .alignmentGuide(.firstTextBaseline) { _ in MDAttr.baseline(size: size) }
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.25)).frame(width: 2.5)
                textBlock(s, size: size, color: .secondaryLabelColor)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: size - 1.5, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .modifier(SelectableIf(on: selectable))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        case .table(let header, let rows):
            let cols = max(header.count, rows.map(\.count).max() ?? 0)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            inline(c < header.count ? header[c] : "").font(.system(size: size - 0.5, weight: .semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal).opacity(0.6)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                inline(c < r.count ? r[c] : "").font(.system(size: size - 0.5))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: 320, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .modifier(SelectableIf(on: selectable))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

/// Код и таблицы остаются SwiftUI Text — выделяемые, как раньше
struct SelectableIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.textSelection(.enabled) } else { content }
    }
}
