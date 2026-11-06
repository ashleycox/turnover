// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated package struct RecoveredDocumentFocus: Sendable {
    package let focus: DocumentFocus
    package let context: DocumentContext?
}

/// Recovery reads native focus, not the last focus event. A menu can close or Safari can change windows
/// without another editor focus notification (review, 6 Nov 2026).
nonisolated package enum DocumentFocusQuery {
    package static func read(pid: pid_t, request: AXWalkRequest) -> RecoveredDocumentFocus? {
        let began = DispatchTime.now().uptimeNanoseconds
        let budget = AXWalkBudget(request: request, duration: 250_000_000, maxVisits: 35, maxAXQueries: 160, startedAt: began)
        return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            let app = AXUIElementCreateApplication(pid)
            guard let element = app.element(kAXFocusedUIElementAttribute), let window = app.element(kAXFocusedWindowAttribute) else { return nil }
            let focus = DocumentFocus(element: element, role: element.role, isSecure: element.string(kAXSubroleAttribute) == "AXSecureTextField")
            var reachedWindow = false
            var node: AXUIElement? = element, root: AXUIElement?, seen: Set<ElementKey> = []
            while let current = node {
                guard budget.visit(), seen.insert(ElementKey(current)).inserted else { return nil }
                if current.role == "AXWebArea" { root = current }
                if current.isSame(window) { reachedWindow = true; break }
                node = current.element(kAXParentAttribute)
            }
            guard reachedWindow, budget.check(), let finalWindow = app.element(kAXFocusedWindowAttribute), finalWindow.isSame(window),
                  let finalFocus = app.element(kAXFocusedUIElementAttribute), finalFocus.isSame(element) else { return nil }
            let context = root.map { root -> DocumentContext in
                let value = root.attr("AXURL")
                let url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
                return DocumentContext(root: root, url: url, ownerPid: pid, window: window)
            }
            return budget.check() ? RecoveredDocumentFocus(focus: focus, context: context) : nil
        }
    }
}
