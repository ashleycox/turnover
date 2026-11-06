// SPDX-License-Identifier: GPL-3.0-or-later
// Google Docs, Sheets and Slides draw their documents as pictures; only with their own "screen reader support" on
// (Command Option Z, remembered by the Google account) is the text there for any screen reader, NVDA's, JAWS's and
// VoiceOver's alike. With it off, TurnOver's browse mode saw only the menus and the arrows said nothing (// 12 Oct 2026, in Safari: no Docs announcements at all in the log). With it on, Docs adds an "Accessibility" menu to
// its menu bar: that is how TurnOver tells. When it is off, TurnOver says how to turn it on, once per document.
import Foundation

package enum GoogleDocs {
    nonisolated package static func isGoogleEditor(_ url: String) -> Bool {
        guard let u = URL(string: url), u.host == "docs.google.com" else { return false }
        return ["/document/", "/spreadsheets/", "/presentation/"].contains { u.path.contains($0) }
    }
}
