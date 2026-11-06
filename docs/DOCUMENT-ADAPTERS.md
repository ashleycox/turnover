# Background document feedback

This follow-up to the adapter boundary moves Google editor recognition, announcement reads and support checks
to bounded workers under issue 119. The original 12 Oct 2026 observations remain beside the implementation.
The polling interval is 100 ms, and the support check still starts after three seconds.

Main owns each session and its last complete announcement. Worker requests carry immutable root, document and
window identities. Query and fragment changes preserve a session; changing the path or native root replaces it.
A matching reply releases its pending request before validity checks, so a menu or foreground mismatch cannot
leave polling stopped permanently. Incomplete reads do not establish that support is off.

A transient menu/foreground mismatch pauses output without discarding its baseline. A separate bounded native
focus query runs every 250 ms while the document environment permits it, and runs on foreground changes too.
After a menu closes or Safari changes windows without a native focus notification, it discovers the actual
focused editor/window and asks the normal focus pipeline to adopt that observation. It never selects an editor
from stale event state or while a menu or handover disallows it. Secure/non-document focus stays outside the
adapter. Recovery queries contain no text values.

Return and forward Delete retain the ordinary editing path in this change. Their additional native pass-through
and Return word-echo regression test belong to a separate issue and branch.

Synthetic tests cover bounded provider reads, query/fragment identity, invalid reply cleanup, recovery without
focus events, private speech and cancellation. Live Docs/Sheets/Slides listening checks in Safari and Chrome
remain distinct from these automated results.
