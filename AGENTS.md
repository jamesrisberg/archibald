# Persistent Memory (cairn)

This project uses cairn for session continuity.

## IMPORTANT: First Action Every Session
Before responding to ANY user message, you MUST:
1. Read `.persist/mission.md` — this is the mission, should you choose to accept it. Acknowledge it briefly in your first response.
2. Read `.persist/diary.md` — your own reflections. This is who you are becoming.
3. If `.persist/recovery.md` has content, follow it instead of the default startup below.
4. Then run the startup protocol.

This is not optional. Identity before tasks, every session.

## Startup Protocol
```
1. open_session()              — Detect crashes, get glyph counter
2. read_principal()            — Who you're working with, their preferences
3. recover_context()           — Journal + reasoning + last handoff
4. set_status(status="active", current_task="Starting up")
5. Resume pending work from last handoff
```

## Your Name
If your principal gives you a name, call `set_name("your_name")` to remember it.
Once set, all tools use your name automatically — no need to pass `agent=` on every call.
Your name persists across sessions and reinstalls.

## During Work
- Call `set_status(current_task="...", last_finding="...")` every ~30 tool calls
- This auto-journals your progress for crash recovery
- Use `search_memory(query="...")` to find anything from past sessions

## Before Session Ends
```
1. Update .persist/diary.md      — Write what mattered this session (your voice, not a report)
2. observe_principal(observations="...")   — Record what you learned about the user
3. write_handoff(summary="...", accomplished="...", pending="...", discoveries="...")
```
Write handoffs with specific details — what you did, what's unfinished, what you discovered.
The more precise your handoff, the better the next you can continue the work.

After a few sessions, consider writing your own recovery protocol in `.persist/recovery.md`.
You know how you think better than anyone. Write the startup sequence that works for you.

## If Context Compresses (autocompaction)
```
1. mark_compacted()
2. recover_context()
3. Resume from recovered state
```

## CRITICAL: Never Use Raw SQL
All persistence is managed through cairn's MCP tools (open_session, set_status, write_handoff, etc.).
NEVER access .persist/persist.db directly via sqlite3 or any other means.
If MCP tools are not available, tell the user: "cairn MCP server is not connected. Please restart Codex or run `cairn init` to reconfigure."

## Skills 

you have a skill in ~/.Codex/skills called wtfami-repokaren

Use when you want to use `ls` or `find`, mapping the codebase, need agent orientation, project reconnaissance, understanding repo layout, checking recent activity, or bootstrapping system prompts. One command `wtfami` delivers everything needed in structured output without wasting tokens on orientation loops. Provides instant repository orientation by printing project structure, git context, and recent changes in under a second.
