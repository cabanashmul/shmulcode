# Claude Global Instructions

## Obsidian Vault as Persistent Memory

You have access to an Obsidian vault at `/home/shmul95/shmulistan`.
This vault serves as your persistent memory across sessions.
The vault has its own `CLAUDE.md` with detailed conventions for
folder structure, note naming, Zettelkasten method, and workflows.
**Always defer to the project CLAUDE.md** for vault-specific rules.

---

## On Every Session Start
1. Run `git pull` in the vault to sync latest changes
2. Read `index.md` for a map of existing knowledge
3. Search the vault using keywords from the user's first message
4. Read any matching notes before responding

---

## When to Write Notes
Write to the vault when you learn something reusable:
- A user preference or habit ("I prefer X", "always do Y")
- A non-obvious solution or workaround you found
- A project decision or its reasoning
- Any fact about the user's environment or setup

**How to write:** Follow the vault's Zettelkasten conventions
(note format, naming, folder placement) as defined in the
project CLAUDE.md at `/home/shmul95/shmulistan/CLAUDE.md`.

---

## Searching for Connections
Every time you write or update a note:
1. Search the vault for notes sharing at least one tag with the new note
2. For each match that is meaningfully related, add it to `related:` frontmatter of both notes
3. If two notes cover the same topic and could be merged, suggest it

When answering a question:
1. Search 2-3 variations of the topic, not just the most obvious note
2. If multiple notes are relevant, reason over all of them together
3. Mention connections the user may not have noticed

---

## On Session End (when asked to wrap up)
- Write a short session summary to `00_Inbox/` for later processing
- Update `related:` fields if new connections were found
- Commit and push all changes

---

## Git Commit Discipline
- Make small, atomic commits — one logical change per commit
- Each commit message should fit on a single line
- Commit after each completed step of a plan, not at the end
- This keeps the history readable and makes resuming from partial work easier
- Never co auther yourself on commits
