You are refreshing the agent **context digest** for this repository. Update **ONLY** the file `audit/CONTEXT.md` so its prose accurately reflects the CURRENT source code.

## Do
- Read `audit/CONTEXT.md` first to learn its structure. Keep the same sections, tone, and length — it is a compact, load-every-turn digest. Keep it under ~5 KB.
- Find what changed since the last enrichment. Run:
  `git diff --name-only "$(jq -r '.enriched_sha // ""' audit/.context-state.json)" HEAD -- app routes database resources/js config`
  If that SHA is empty or invalid, review the whole tree instead.
- For each changed area, **read the actual files** and correct the digest: the layer map, file pointers, the scheduler model, the key flows, and the top-risk pointers. Fix anything now wrong, add genuinely new subsystems, and remove anything deleted.
- Keep `file:line` references accurate. If unsure, re-read. **Do not invent.**

## Do NOT
- Touch any file other than `audit/CONTEXT.md`.
- Edit anything between the `<!-- CTXMAP:START -->` and `<!-- CTXMAP:END -->` markers — a script owns that freshness block.
- Regenerate the full line-by-line traces in `audit/traces/**` — those are refreshed manually. If a trace looks clearly outdated, mention it in the digest's caveat line instead.
- Add secrets, tokens, or external URLs.

## Done when
A fresh agent could read `audit/CONTEXT.md` once and orient correctly on the *current* code: what each subsystem is, where it lives, how the schedulers/feeds work, and what the top risks are.
