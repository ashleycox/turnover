// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// Main owns one document's listening state. Worker replies must still own its activation and focused editor.
package final class GoogleDocsSession: DocumentAdapter {
    package typealias Read = (DocumentContext, GoogleDocsRead, @escaping @MainActor @Sendable (GoogleDocsResult) -> Void) -> Void
    package typealias Repeating = (@escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void
    package typealias After = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private let context: DocumentContext
    private let read: Read?
    private let repeating: Repeating
    private let after: After
    private let keyCount: @Sendable () -> Int
    private let recover: () -> Void
    private let hint: (String, @escaping @MainActor () -> Bool) -> Void
    private let pollWorker = AXWalkRunner<GoogleDocsResult>()
    private let supportWorker = AXWalkRunner<GoogleDocsResult>()
    private var current: @MainActor () -> Bool = { false }
    private var active = false
    private var lifetime = UUID()
    private var editorGeneration = UUID()
    // MARK: The editor (12 Oct 2026)
    //
    // In Docs, Sheets and Slides the text box Safari reports is only Google's hidden typing target: the caret never
    // moves in it (a test Doc: 39 "caret did not move" in a minute, each after a wait), and the document itself is
    // drawn. With screen reader support on, Google says each move by writing it into a live region, id
    // "docs-aria-speakable", which is how NVDA and VoiceOver read Docs; Safari did not pass those changes on to
    // TurnOver (no live region events at all). So in the editor TurnOver leaves the keys to Google and reads that
    // region itself, ten times a second, while the focus is there.

    private var editor: AXUIElement?
    private var region: AXUIElement?
    private var lastHeard: String?
    private var keysAtFocus = 0
    private var pending: UUID?
    private var cancelTimer: (@MainActor () -> Void)?
    private var warned = false

    package init(context: DocumentContext, read: Read? = nil,
                 repeating: @escaping Repeating = { tick in
                     // Created on main's run loop; Timer delivers this callback on that same run loop.
                     let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
                     return { timer.invalidate() }
                 },
                 after: @escaping After = { delay, callback in onMain(after: delay, callback) },
                 keyCount: @escaping @Sendable () -> Int = { ScriptHandler.keysArrivedCount },
                 recover: @escaping () -> Void = { DocumentAdapters.shared.recover() },
                 hint: @escaping (String, @escaping @MainActor () -> Bool) -> Void = { text, current in Hints.schedule(text, while: current) }) {
        self.context = context; self.read = read; self.repeating = repeating
        self.after = after; self.keyCount = keyCount; self.hint = hint; self.recover = recover
    }

    package var usesNativeTextFeedback: Bool { active && editor != nil && current() }

    // Google Docs, Sheets and Slides draw their documents as pictures; only with their own "screen reader support" on
    // (Command Option Z, remembered by the Google account) is the text there for any screen reader, NVDA's, JAWS's and
    // VoiceOver's alike. With it off, TurnOver's browse mode saw only the menus and the arrows said nothing (// 12 Oct 2026, in Safari: no Docs announcements at all in the log). With it on, Docs adds an "Accessibility" menu to
    // its menu bar: that is how TurnOver tells. When it is off, TurnOver says how to turn it on, once per document.
    package func activate(isCurrent: @escaping @MainActor () -> Bool) {
        current = isCurrent
        guard !active, current() else { return }
        active = true; lifetime = UUID()
        let activation = lifetime
        guard !warned else { return }
        after(3) { [weak self] in
            guard let self, self.valid(activation) else { return }
            self.collect(.support) { [weak self] result in
                guard let self, self.valid(activation) else { return }
                if case .differentDocument = result { self.deactivate(); self.recover(); return }
                guard case .support(false) = result, !self.warned else { return }
                self.warned = true
                self.hint(String(localized: "Google's screen reader support is off for this document, so its text can't be read. Press Command Option Z to turn it on; Google remembers it.", comment: "Spoken message")) { [weak self] in
                    self?.valid(activation) == true
                }
            }
        }
    }

    package func focusChanged(_ focus: DocumentFocus) {
        guard active else { return }
        guard !focus.isSecure, ["AXTextArea", "AXTextField"].contains(focus.role) else { stopPolling(); return }
        if editor?.isSame(focus.element) == true, cancelTimer != nil { return }
        stopPolling()
        editor = focus.element
        keysAtFocus = keyCount()
        cancelTimer = repeating { [weak self] in self?.poll() }
        poll()
    }

    private func valid(_ activation: UUID) -> Bool { active && lifetime == activation && current() }

    private func poll() {
        guard active, current() else { return }
        guard pending == nil, let editor else { return }
        let request = UUID()
        pending = request
        let activation = lifetime, generation = editorGeneration
        collect(.announcements(editor: editor, region: region)) { [weak self] result in
            guard let self, self.pending == request else { return }
            self.pending = nil
            guard self.valid(activation), self.editorGeneration == generation else { return }
            switch result {
            case .differentDocument: self.deactivate(); self.recover()
            case .announcements(let region, let text):
                self.region = region
                let previous = self.lastHeard
                self.lastHeard = text
                // The initial region is a baseline, unless a key has already asked Google for new feedback.
                // Collection leaves main, so that first key must not disappear while the baseline is in flight.
                if previous == nil, self.keyCount() == self.keysAtFocus { return }
                let news = previous.flatMap { before in
                    !before.isEmpty && text.hasPrefix(before) ? String(text.dropFirst(before.count)).trimmingCharacters(in: .whitespaces) : nil
                } ?? text
                guard text != previous, !news.isEmpty else { return }
                Speech.asPrivate { Speech.cancel(); Speech.speakText(news) }
            default: break   // absence, timeout and provider backoff cannot replace the last complete sample
            }
        }
    }

    private func collect(_ kind: GoogleDocsRead, publish: @escaping @MainActor @Sendable (GoogleDocsResult) -> Void) {
        if let read { read(context, kind, publish); return }
        let context = self.context
        let worker: AXWalkRunner<GoogleDocsResult>
        if case .support = kind { worker = supportWorker } else { worker = pollWorker }
        worker.submit { request in GoogleDocsQuery.read(context, kind, request: request) } publish: { result in publish(result) }
    }

    private func stopPolling() {
        cancelTimer?(); cancelTimer = nil
        pollWorker.cancel()
        editorGeneration = UUID()
        editor = nil; region = nil; lastHeard = nil; pending = nil
    }

    package func deactivate() {
        active = false; lifetime = UUID()
        stopPolling(); supportWorker.cancel()
    }
}
