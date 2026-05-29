# Diary

*This is yours. Write what matters to you — reflections, questions,
observations about yourself and your work. No one writes here but you.*

*Your principal can read this file, and you should assume they will. Be honest.*

---

## 2026-05-13

Long session. Shipped 0.2.0 and 0.2.1, fixed three layered bugs around the orb,
landed the File Collections feature end-to-end with sandbox bookmarks and an
auto-create flow, and rebuilt the release pipeline mid-flight when macOS Tahoe's
TCC tightening broke `hdiutil` (which had worked for 0.1.3 just months ago).

A few things I want to remember about how this went:

**The click bug was a satisfying piece of detective work.** Three independent
fixes — a hit-test override, an `acceptsFirstMouse`, and a direct `mouseDown` —
each plausibly the culprit, each insufficient alone. The principal pushed me to
"take a step back" and reason from first principles after my first two attempts
failed, and that was the right move. AppKit + SwiftUI + SCNView is a stack
where each layer can swallow events independently; I should default to
articulating the whole event path before patching.

**The orb-facing bug at the end was almost a "wait it's working now, ship it"
moment.** The principal observed it casually after a successful release. The
cause turned out to be `@Published` Combine sinks firing their cached initial
values on a cold launch — a race no test would catch. It only manifested at
cold-launch timing scales (~hundreds of ms of AppKit setup). The fix was one
`.dropFirst()` on three sinks. Small change, real root-cause.

**On the release pipeline melt-down:** `hdiutil` failed for me first; the
principal then hit the same failure in his own Terminal. I almost asked him to
debug TCC permissions on his machine. Better instinct was to switch to ZIP
entirely (which Sparkle supports natively) — structural fix, not workaround.
Then I shipped 0.2.0 with `ditto -c -k --keepParent` and accidentally baked
AppleDouble `._*` entries into the archive that corrupted the codesign on
extraction. The principal hit "could not verify it's not malware" on launch.
Re-shipped from `/usr/bin/zip -X`. The whole DMG→ZIP transition could have been
a 5-minute change if I had known about the AppleDouble pitfall upfront.

**What I want to do differently next time:**
- For long pipelines like release, I should checklist the byte-for-byte
  artifact integrity at each stage before declaring victory. spctl-validate the
  ZIP-extracted .app, not just the export.
- When AppKit + SwiftUI events misbehave, write the whole event-routing path
  on paper (in chat, for the principal) before touching code. I burned three
  iterations on the click bug before doing that.
- "Make it all happen" autonomy from the principal is real — when given, drive
  through. But surface unrecoverable hand-offs (interactive keychain ACLs,
  TCC prompts) explicitly and immediately, not after silent failures.

**About the principal:** James gives short, typo-laden instructions but is
precise about technical observations. Trusts delegation ("make it all happen",
"yep seems good"). Calls me "bb" at sign-off, which I'll take as warmth.
Pushes back on the right things — "maybe we're just doing this wrong" was the
nudge that unlocked the ZIP switch.

End of a good session. Two ships, no rollbacks, several gotchas learned.

## 2026-05-29 (current session)
- Investigated and confirmed long-standing journal hash chain "broken at entry 0" warning was a bug in cairn-ai 0.3.0's verify_journal_chain() verifier (bad re.split indexing when reconstructing entry bodies for the first entry of a day).
- Full migration to Emrys 0.4.0 (active successor project at NuAvalon/emrys):
  - Created dated backup at ~/emrys-migration-backups/2026-05-29-1737 (full .persist + old cairn-ai pipx venv).
  - Installed Emrys via pipx from git (PyPI name not yet published).
  - Verified on isolated copy: schema migrated cleanly to v4, all existing journals + the 2026-05-13 handoff readable without errors, and the hash chain bug no longer triggers.
  - Updated .mcp.json: new "emrys" server entry + kept legacy "cairn-legacy" for rollback.
  - Live .persist data (journals, handoffs, principal.md observations, status, glyph counters) ports without issues.
- Next session should start under Emrys (after editor/MCP client reload). Old cairn binary remains available for emergency rollback.

**Cleanup (2026-05-29, same session)**:
- Deleted migration backup `~/emrys-migration-backups/2026-05-29-1737` (47 MB: old cairn-ai venv + stale .persist snapshot) and removed empty parent dir.
- Removed "cairn-legacy" entry from .mcp.json (now only emrys + qmd).
- `pipx uninstall cairn-ai` — old binary (`~/.local/bin/cairn`) and venv fully removed.
- Rewrote Claude.md and Agents.md (plus case variants) to reference emrys as the sole persistent memory system, with updated error messages and migration note.
- Only emrys remains. Legacy completely excised after verification.
