import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    var convs: [Conversation] {
        model.s.conversations.values
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                $0.messages.contains { $0.content.localizedCaseInsensitiveContains(search) } }
            .sorted { $0.lastTs > $1.lastTs }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { SyncBadge() }
                ForEach(convs) { c in
                    NavigationLink(value: c.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.title.isEmpty ? "Conversation" : c.title).font(.headline).lineLimit(1)
                            Text(c.messages.last?.content ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text(Date(timeIntervalSince1970: c.lastTs), style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("B.E.T.E.R.")
            .navigationDestination(for: String.self) { ChatView(convId: $0) }
            .toolbar {
                NavigationLink(value: "new-" + UUID().uuidString.prefix(8).lowercased()) {
                    Image(systemName: "square.and.pencil")
                }
            }
            .refreshable { model.retryNow() }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let convId: String
    @State private var realId: String?
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var attachments: [(id: String, name: String)] = []
    @State private var uploading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var cid: String? { realId ?? (convId.hasPrefix("new-") ? nil : convId) }
    var conv: Conversation? { cid.flatMap { model.s.conversations[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let conv, !conv.complete {
                            Button("Load earlier messages") { Task { await model.loadOlder(conv.id) } }
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(conv?.messages ?? []) { m in
                            MessageBubble(m: m).id(m.id)
                        }
                        if let cid, model.isWaitingForReply(cid) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(model.status == .upToDate || model.status == .synchronizing ? "B.E.T.E.R. is thinking…" : "Waiting to reach your PC…")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }.id("waiting")
                        }
                    }
                    .padding()
                }
                .onChange(of: conv?.messages.count ?? 0) { _, _ in
                    withAnimation { proxy.scrollTo(conv?.messages.last?.id, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(conv?.messages.last?.id, anchor: .bottom) }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments, id: \.id) { a in
                            Label(a.name, systemImage: "paperclip").font(.caption)
                                .padding(6).background(.thinMaterial, in: Capsule())
                                .onTapGesture { attachments.removeAll { $0.id == a.id } }
                        }
                    }.padding(.horizontal)
                }
            }
            composer
        }
        .navigationTitle(conv?.title.isEmpty == false ? conv!.title : "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await uploadFile(url) } }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await uploadData(data, name: "photo.jpg") }
                photo = nil
            }
        }
    }

    var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                Button { importing = true } label: { Label("File", systemImage: "doc") }
            } label: {
                Image(systemName: uploading ? "hourglass" : "plus.circle.fill").font(.title2)
            }
            .disabled(uploading || !model.can("attachments"))
            TextField("Message B.E.T.E.R.", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            Button {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                realId = model.send(text: t, convId: cid, attachments: attachments.map(\.id))
                text = ""
                attachments = []
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func uploadFile(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = "Could not read that file"; return }
        await uploadData(data, name: url.lastPathComponent)
    }

    private func uploadData(_ data: Data, name: String) async {
        guard data.count <= 20_000_000 else { error = "Files up to 20 MB"; return }
        uploading = true
        error = nil
        do {
            let id = try await model.upload(name: name, data: data)
            attachments.append((id: id, name: name))
        } catch {
            self.error = "Attachments need a connection to your PC: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        uploading = false
    }
}

struct MessageBubble: View {
    let m: ChatMessage
    var mine: Bool { m.role == "user" }

    var body: some View {
        HStack(alignment: .top) {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                RichText(text: m.content)
                if m.pending {
                    Label("waiting to send", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(mine ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .contextMenu {
                Button { UIPasteboard.general.string = m.content } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: m.content)
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// Markdown text with fenced code blocks shown as monospaced, lightly highlighted, copyable blocks.
struct RichText: View {
    let text: String

    enum Part: Identifiable {
        case prose(Int, String)
        case code(Int, String, String)
        var id: Int { switch self { case .prose(let i, _), .code(let i, _, _): return i } }
    }

    var parts: [Part] {
        var out: [Part] = []
        let chunks = text.components(separatedBy: "```")
        for (i, c) in chunks.enumerated() {
            if i % 2 == 0 {
                if !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.prose(i, c.trimmingCharacters(in: .newlines))) }
            } else {
                var lines = c.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                out.append(.code(i, lang, lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parts) { p in
                switch p {
                case .prose(_, let s):
                    Text(markdown(s)).textSelection(.enabled)
                case .code(_, let lang, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(Highlighter.highlight(code)).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

enum Highlighter {
    static let keywords: Set<String> = ["def", "class", "return", "if", "else", "elif", "for", "while", "in", "import", "from", "as", "with",
        "try", "except", "finally", "raise", "lambda", "None", "True", "False", "and", "or", "not", "func", "let", "var", "struct",
        "enum", "guard", "switch", "case", "const", "function", "async", "await", "public", "private", "static", "void", "int",
        "float", "bool", "string", "new", "this", "self", "nil", "null", "true", "false", "break", "continue", "do", "using", "namespace"]

    static func highlight(_ code: String) -> AttributedString {
        var out = AttributedString()
        var token = ""
        var inString: Character?
        var inComment = false
        func flush(_ color: Color? = nil) {
            guard !token.isEmpty else { return }
            var a = AttributedString(token)
            if let color { a.foregroundColor = color }
            else if keywords.contains(token) { a.foregroundColor = .purple }
            else if Double(token) != nil { a.foregroundColor = .orange }
            out += a
            token = ""
        }
        for ch in code {
            if inComment {
                token.append(ch)
                if ch == "\n" { flush(.gray); inComment = false }
                continue
            }
            if let q = inString {
                token.append(ch)
                if ch == q { flush(.red); inString = nil }
                continue
            }
            if ch == "#" {
                flush(); token = String(ch); inComment = true; continue
            }
            if ch == "\"" || ch == "'" { flush(); token = String(ch); inString = ch; continue }
            if ch.isLetter || ch.isNumber || ch == "_" { token.append(ch) } else { flush(); out += AttributedString(String(ch)) }
        }
        flush(inComment ? .gray : (inString != nil ? .red : nil))
        return out
    }
}
