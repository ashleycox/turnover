// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// A website is selected by its document, independently of the browser's native app module.
nonisolated package struct DocumentContext: Sendable {
    package let root: AXUIElement
    package let url: String
    package let ownerPid: pid_t
    package let window: AXUIElement?
    package init(root: AXUIElement, url: String, ownerPid: pid_t, window: AXUIElement? = nil) {
        self.root = root; self.url = url; self.ownerPid = ownerPid; self.window = window
    }
    /// A fragment or query selects a sheet/tab/heading within the same document, not another session.
    package var identity: String { Self.identity(url) }
    package static func identity(_ url: String) -> String {
        guard var parts = URLComponents(string: url) else { return url }
        parts.query = nil; parts.fragment = nil
        return parts.string ?? url
    }
}

nonisolated package struct DocumentFocus: Sendable {
    package let element: AXUIElement
    package let role: String
    package var isSecure = false
    package init(element: AXUIElement, role: String, isSecure: Bool = false) {
        self.element = element; self.role = role; self.isSecure = isSecure
    }
}

package protocol DocumentAdapter: AnyObject {
    var usesNativeTextFeedback: Bool { get }
    func activate(isCurrent: @escaping @MainActor () -> Bool)
    func focusChanged(_ focus: DocumentFocus)
    func deactivate()
}

/// Owns bounded, in-memory document sessions. API publishes focus snapshots here; no key path walks AX parents.
package final class DocumentAdapters {
    package static var shared = DocumentAdapters()
    package typealias Factory = (DocumentContext) -> any DocumentAdapter
    private struct Registration {
        let id: String
        let matches: (String) -> Bool
        let make: Factory
    }
    private final class Entry {
        let context: DocumentContext
        let adapter: any DocumentAdapter
        init(_ context: DocumentContext, _ adapter: any DocumentAdapter) { self.context = context; self.adapter = adapter }
    }
    private var registrations: [Registration] = []
    private var entries: [Entry] = []
    private var current: Entry?
    private var focus: DocumentFocus?
    private var root: AXUIElement?
    private var ownerPid: pid_t = 0
    private var enabled = true
    private let allowed: () -> Bool
    private let environmentAllowsRecovery: () -> Bool
    private let frontmostPid: () -> pid_t?
    private let publishRecovered: (RecoveredDocumentFocus) -> Void
    private let repeating: RecoveryTimer
    private let recoveryWorker = AXWalkRunner<RecoveredDocumentFocus?>()
    private var cancelRecovery: (() -> Void)?
    private var recoveryPending = false
    private var recoveryGeneration = 0
    package var isRecovering: Bool { recoveryPending }
    private var foregroundBlocked = false
    private var recoveryOwnerPid: pid_t?
    package typealias RecoveryTimer = (@escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void

    package init(allowed: @escaping () -> Bool = {
        guard Core.active, let obj = API.focusObject, obj.role != .passwordEdit, InputManager.directPid != obj.pid,
              !InputManager.isAsleep(obj.pid), !AXHandler.anyMenuOpen.value, !TurnOverMenu.shared.isOpen,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == AXHandler.shared.activePid else { return false }
        if let window = API.focusAncestors.last(where: { $0.axRole == "AXWindow" }),
           let foreground = API.foregroundObject, foreground.axRole == "AXWindow" {
            return window.isSameElement(as: foreground)
        }
        return true
    }, environmentAllowsRecovery: @escaping () -> Bool = {
        Core.active && !AXHandler.anyMenuOpen.value && !TurnOverMenu.shared.isOpen
    }, frontmostPid: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
       publishRecovered: @escaping (RecoveredDocumentFocus) -> Void = { snapshot in
           AXHandler.shared.focusChanged(snapshot.focus.element, pid: snapshot.context?.ownerPid ?? snapshot.focus.element.pid)
       }, repeating: @escaping RecoveryTimer = { callback in
           let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { callback() } }
           return { timer.invalidate() }
       }) {
        self.allowed = allowed; self.environmentAllowsRecovery = environmentAllowsRecovery; self.frontmostPid = frontmostPid
        self.publishRecovered = publishRecovered; self.repeating = repeating
    }

    package func register(_ id: String, matches: @escaping (String) -> Bool, make: @escaping Factory) {
        registrations.removeAll { $0.id == id }
        registrations.append(Registration(id: id, matches: matches, make: make))
        startRecovery()
    }

    package func focusChanged(_ obj: TurnOverObject?, ancestors: [TurnOverObject], document: BrowseModeDocument?) {
        recoveryGeneration += 1
        guard enabled else { leave(); return }
        // Menus and transient foreground mismatches pause the session; recovery probes refresh native focus
        // after they end even if the application emits no replacement focus event.
        guard allowed() else { return }
        guard let obj, let web = ([obj] + ancestors).last(where: { $0.axRole == "AXWebArea" }) else { leave(); return }
        focus = DocumentFocus(element: obj.element, role: obj.axRole, isSecure: obj.role == .passwordEdit)
        root = web.element
        ownerPid = ancestors.last(where: { $0.axRole == "AXWindow" })?.pid ?? obj.pid
        // Browse mode already captured the URL when it built/refreshed this document. Where there is no
        // interceptor, one root attribute supplies the address; recognition never walks a tree on main.
        let url: String
        if let document, document.webArea.isSame(web.element), !document.lastURL.isEmpty { url = document.lastURL }
        else {
            let value = web.element.attr("AXURL")
            url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
        }
        select(DocumentContext(root: web.element, url: url, ownerPid: ownerPid, window: ancestors.last(where: { $0.axRole == "AXWindow" })?.element))
    }

    package func pageChanged(root: AXUIElement, url: String) {
        guard self.root?.isSame(root) == true else { return }
        if let current, current.context.identity == DocumentContext.identity(url) { return }
        recoveryGeneration += 1
        select(DocumentContext(root: root, url: url, ownerPid: ownerPid, window: current?.context.window))
    }

    private func select(_ context: DocumentContext) {
        guard enabled, allowed(), let focus else { leave(); return }
        foregroundBlocked = false
        if let current, current.context.root.isSame(context.root), current.context.identity == context.identity {
            current.adapter.activate(isCurrent: eligibility(for: current))
            current.adapter.focusChanged(focus)
            return
        }
        current?.adapter.deactivate()
        current = nil
        guard let registration = registrations.first(where: { $0.matches(context.url) }) else { return }
        let entry: Entry
        if let known = entries.first(where: { $0.context.root.isSame(context.root) && $0.context.identity == context.identity }) { entry = known }
        else {
            entry = Entry(context, registration.make(context))
            entries.append(entry)
            if entries.count > 40 { entries.removeFirst().adapter.deactivate() }
        }
        current = entry
        recoveryOwnerPid = context.ownerPid
        entry.adapter.activate(isCurrent: eligibility(for: entry))
        entry.adapter.focusChanged(focus)
    }

    private func eligibility(for entry: Entry) -> @MainActor () -> Bool {
        { [weak self, weak entry] in
            guard let self, let entry else { return false }
            return self.enabled && self.current === entry && !self.foregroundBlocked && self.allowed()
        }
    }

    package func observe(_ event: Event) {
        // Google Docs: a focus move starts or stops the reading of Google's announcements; a caret move in the editor
        // starts it too (after a restart the focus is already there, and no focus event comes, 12 Oct 2026).
        // Native recovery also covers returning from menus/windows when neither event arrives.
        guard [.gainFocus, .caret].contains(event.kind), let obj = API.focusObject,
              obj.isSameElement(as: event.obj) else { return }
        focusChanged(obj, ancestors: API.focusAncestors, document: API.focusTreeInterceptor)
    }

    package func usesNativeTextFeedback(for element: AXUIElement) -> Bool {
        guard enabled, let current, focus?.element.isSame(element) == true else { return false }
        return !foregroundBlocked && allowed() && current.adapter.usesNativeTextFeedback
    }

    package func leave() {
        recoveryGeneration += 1
        current?.adapter.deactivate()
        current = nil; root = nil; focus = nil; ownerPid = 0
    }
    package func foregroundChanged() { recoveryGeneration += 1; foregroundBlocked = true; recover() }

    private func startRecovery() {
        guard enabled, cancelRecovery == nil else { return }
        cancelRecovery = repeating { [weak self] in self?.recover() }
    }

    package func recover() {
        guard enabled, environmentAllowsRecovery(), !recoveryPending, let pid = frontmostPid(),
              root != nil || recoveryOwnerPid == pid || API.focusAncestors.contains(where: { $0.axRole == "AXWebArea" }) else { return }
        recoveryPending = true
        let generation = recoveryGeneration
        recoveryWorker.submit(collect: { DocumentFocusQuery.read(pid: pid, request: $0) }, publish: { [weak self] result in
            guard let self else { return }
            recoveryPending = false
            guard enabled, recoveryGeneration == generation, environmentAllowsRecovery(), frontmostPid() == pid, let result else { return }
            if let context = result.context, let current, current.context.root.isSame(context.root),
               current.context.identity == context.identity, focus?.element.isSame(result.focus.element) == true,
               !foregroundBlocked, allowed(), API.focusObject?.isSameElement(as: result.focus.element) == true {
                current.adapter.activate(isCurrent: eligibility(for: current))
                current.adapter.focusChanged(result.focus)
            } else if API.focusObject?.isSameElement(as: result.focus.element) != true || foregroundBlocked {
                publishRecovered(result)
            } else if result.focus.isSecure || result.context == nil {
                leave()
            } else if let context = result.context {
                focus = result.focus; root = context.root; ownerPid = context.ownerPid
                select(context)
            }
        })
    }

    package func suspend() {
        enabled = false; leave(); cancelRecovery?(); cancelRecovery = nil
        recoveryWorker.cancel(); recoveryPending = false
    }
    package func resume() { enabled = true; startRecovery(); recover() }
    package func forget(pid: pid_t) {
        recoveryGeneration += 1
        for entry in entries where entry.context.ownerPid == pid || entry.context.root.pid == pid {
            entry.adapter.deactivate()
            if current === entry { current = nil; root = nil; focus = nil }
        }
        entries.removeAll { $0.context.ownerPid == pid || $0.context.root.pid == pid }
    }
}
