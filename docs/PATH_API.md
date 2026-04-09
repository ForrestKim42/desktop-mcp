# Path API — Unified Single-Call Interface

> Status: **design draft (2026-04-09)**
> Scope: A unifying evolution of `desktop_do` that collapses read / focus / act / find / inspect into a single path grammar. Backwards-compatible: existing action strings remain valid leaves of the new grammar.

---

## Motivation

The current `desktop_do` exposes two modes implicitly:

1. **Read** — call without `actions`, get a summary + refs list.
2. **Act** — call with `actions`, execute and get the post-state.

Between them, a set of gaps has accumulated:

- Summary groups list items (e.g. `message_container (3):`) but the individual `@N` refs never appear in the output, so tapping a specific child is impossible when the label collides.
- No `find` / `inspect` / `verbose` — LLM must guess exact labels.
- Multi-step flows require N calls, each carrying a full snapshot dump, even when the transitions are known in advance (documented in an `app-memory` layer).
- `page` / `pageSize` paginate the AX ref list but are no-ops for CDP-backed apps (Slack, Discord, VS Code) because those go through `CDPElementHolder` which never emits the `=== Refs ===` section.

The underlying reason is that **reading and acting speak different vocabularies**, and the pre-computed knowledge in `app-memory` has no channel to flow back into a single call.

## Core insight

> UI is a tree. Reading is a focus operation. Every ref is a valid focus point. **Every node is a sub-UI with the same interface as the root.**

Three axioms collapse the entire surface:

1. **Every node is a ref** — groups, leaves, regions, windows, applications. One ref space.
2. **A path is a `/`-joined sequence of refs** — mirrors a filesystem or URL.
3. **`desktop_do(paths[])` evaluates each path and returns a view per path** — input and output are symmetrical arrays.

From these three axioms, `read`, `focus`, `act`, `find`, `inspect`, `list`, `verbose`, and `page` all fall out as path-syntax variations or terminal verbs. **Nothing in the old API is gained by being a separate parameter.**

## The grammar

```
path       := segment ('/' segment)*  ('?' | '!' | ':silent')?
segment    := ref | verb
ref        := [APP/] TYPE ':' label [@index] [ '[' selector ']' ]
verb       := 'tap' | 'doubletap' | 'type' ':' text | 'press' ':' key
            | 'scroll' ':' direction [':' count]
            | 'find' ':' query | 'expect' ':' screen
            | 'wait' ':' ms
terminal   := verb | (empty) // empty = "just read whatever you focused on"
```

Trailing markers on a path:

- `?` — force a read-dump of the view at the end of this path (verbose, the whole view).
- `!` — assertion mode: return only `{ok: true/false}`. No dump, no matter what.
- (nothing) — silent success; return `{ok: true}` or `{ok: false, where: "..."}`.

### Examples

```text
// Read the Slack root (summary).
Slack

// Zoom into the thread dialog region.
Slack/Dialog

// Zoom into one specific message container; get its full child refs.
Slack/message_container@2

// Zoom into that message AND act inside it.
Slack/message_container@2/LINK:스레드 보기/tap

// Fuzzy find followed by act.
Slack/find:닫기/tap

// Disambiguate when find returns multiple hits.
Slack/find:닫기/[2]/tap

// Multi-step flow — one call.
Slack/channel-sidebar-channel:alpha-room/tap
Slack/Input:message_input/type:hello
Slack/press:RETURN?

// Cross-app in a single batch (each row is one path).
Slack/find:최근 링크/tap
Arc/Input:URL/type:{clipboard}/press:RETURN?
```

## `desktop_do(paths[])`

```ts
desktop_do(paths: string[]): View[]
```

- Each path is evaluated independently against its app context.
- The return array is 1:1 with the input array.
- Each `View` is either:
  - `{ok: true}` — silent success.
  - `{ok: false, where: "Slack/find:닫기", reason: "no match"}` — failed step.
  - `{summary, refs, dialogs, changes}` — when the path ended with `?`.

### Why array-in, array-out matters

Reading is expensive (1000+ elements, ~20ms AX or a CDP round-trip). Acting is cheap (one event). In the current 1-path-per-call world, an N-step flow implies N dumps. Once paths are batched:

- Silent steps cost only the action.
- `?` steps cost one dump each — LLM explicitly marks when it wants to see the result.
- `expect:` steps cost nothing unless the assertion fails — the dump is produced only at divergence.

An N-step flow with known transitions collapses to **0 intermediate dumps**. The only dump is the one the LLM explicitly asks for at the end. This is the maximal compression of read-cost.

## Assertions via `expect:`

`app-memory` (the project's ROUTES/TRANSITIONS layer) already stores "after action X, expected screen Y". That knowledge becomes a first-class path segment:

```text
Slack/channel-sidebar-channel:alpha-room/tap/expect:channel_view
Slack/Input:message_input/type:hello/press:RETURN/expect:channel_view
```

- On success: silent, no dump.
- On failure: the path halts at the failing assertion, and the returned `View` for that path contains the actual (unexpected) view so the LLM can recover.

Costs become:
- **Happy path**: 0 intermediate dumps.
- **Divergence**: 1 dump, precisely at the point where expected != actual.

This is the ideal. Dumps happen *if and only if* the LLM's mental model was wrong.

## `app-memory` as compiled macros

With this API, `app-memory` stops being "documentation the LLM reads" and becomes **compiled execution plans**:

- `ROUTES.md` screen names → values for `expect:`.
- `TRANSITIONS.md` parameterized flows → arrays passed directly to `desktop_do`.

A parameterized flow like:

```yaml
# TRANSITIONS.md
send_channel_message:
  params: [channel, message]
  path:
    - "Slack/channel-sidebar-channel:{channel}/tap/expect:channel_view"
    - "Slack/Input:message_input/type:{message}"
    - "Slack/press:RETURN/expect:channel_view"
```

becomes a literal `desktop_do([...])` call. Exploration cost paid once during crawl → every subsequent invocation is a single call. **Knowledge becomes action.**

## Backwards compatibility

Every existing action string is already a valid path:

- `tap Slack/BUTTON:Save` → `Slack/BUTTON:Save/tap`
- `type hello` → `(current focus)/type:hello`
- `press RETURN` → `press:RETURN`
- Omitting `actions` entirely → `{app}` (read-only path).

The server can accept both shapes during a transition period. New clients use paths; old clients keep working.

## Implementation roadmap

### Phase 0 — design lock (this document)

Lock the grammar, commit this doc. No code changes. Allows parallel iteration on the spec without destabilizing the existing tool.

### Phase 1 — `find` as a first-class action (minimum viable win)

The immediate pain is "I can't tap this element because its ref is hidden in the summary." `find` alone fixes 80% of that, with near-zero refactor cost:

- Add `find <query>` to `ActionParser`.
- In `Tools.swift`, resolve `find` against `CDPElementHolder` + `ElementStore`:
  - Match `query` against label (substring, case-insensitive).
  - Return a result block listing matched refs with context (region, parent).
- No path-grammar changes yet — `find` is just a new action verb that prints candidates. Existing `tap` remains the way to act on the result.

After Phase 1, the flow becomes:

```
desktop_do(actions=["find 닫기"])            // lists candidates
desktop_do(actions=["tap Slack/BUTTON:닫기@1"])  // acts on chosen one
```

Two calls instead of zero, but it's achievable without breaking anything.

### Phase 2 — `inspect` / group drilldown

- Add `inspect <group-name>` and `inspect <ref>` actions.
- Extend `CDPSnapshot.swift` to preserve group signatures in `CDPElementHolder` (a `groupIndex: [String: [Int]]`).
- `inspect` returns the drilled-down refs for a named group or the children of a ref.

### Phase 3 — path grammar parser

- Introduce `PathParser.swift` that turns a `/`-joined path into a sequence of `Segment` enums.
- `desktop_do` accepts `paths: [String]` alongside the legacy `actions:`. Each path becomes a pipeline that the existing action layer executes.
- Silent vs. `?` vs. `!` are parser flags, not separate modes.

### Phase 4 — `expect:` and app-memory binding

- Add `expect:<screen>` as a terminal verb.
- Define a small "screen signature" — e.g. "has a ref matching X, is in region Y" — that the server can evaluate against the current view.
- Wire `app-memory` YAML flows to produce `desktop_do` call arrays directly.

### Phase 5 — deprecate `page`/`pageSize`

Once `inspect` + `find` are in place, `page`/`pageSize` become dead weight. Remove from the tool schema (or keep as no-ops with a deprecation note).

## Minimum axioms (reference)

The whole API reduces to these four lines:

1. Every node is a ref.
2. `/`-joined refs are paths.
3. `desktop_do(paths[])` evaluates each path and returns one view per path.
4. Each path declares whether to dump (`?`), assert (`expect:`/`!`), or stay silent.

## Why this is the end state, not a milestone

Most API refactors trade one set of parameters for another. This one removes the need for `verbose`, `page`, `pageSize`, `find` (as a separate tool), `inspect` (as a separate tool), and `actions`-vs-no-`actions` mode switching all at once — by noticing that they were already the same operation with different markers.

Subsequent evolution (mobile-mcp parity, richer assertions, streaming responses) can happen inside this grammar without another breaking change. The grammar is the ceiling, not the floor.

---

## Open questions

- **Selector syntax inside refs**: `BUTTON:닫기[data-qa=close_flexpane]` vs `BUTTON[data-qa=close_flexpane]`? Probably the latter — selectors replace the label when explicit.
- **Path composition across apps**: Today cross-app is expressed as separate paths. Should a single path span apps (`Slack/.../copy > Arc/.../paste`)? Probably not — keep paths single-app, batch at the array level.
- **Concurrency**: Can paths in a single array run in parallel? Only if they don't touch overlapping apps. Start serial, add a `parallel:` marker later if needed.
- **Return-on-first-failure vs. continue**: Default should be halt-the-failing-path, continue others. Configurable via an envelope option `{paths, mode: 'halt' | 'continue'}`.

These do not block Phase 1.
