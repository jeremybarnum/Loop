# Glossary — how to read the shorthand in this fork

If you are reading this code as a Loop contributor, start here. The source carries ~800
references of the form `#102`, `R35`, `WS1`, `E4`. They all resolve, but they resolved only if
you already knew which of two dozen documents to open. This page is that index.

## Orientation, in four sentences

This is a fork of Loop that lets an Apple Watch borrow the iPhone's Omnipod DASH and close the
loop from the watch ("Sport Mode"). The phone LENDS the pod; the watch takes over its Bluetooth
session, doses, and hands it back with a record of everything it delivered. Dosing policy on the
watch is a deliberate miniature of the phone's stock `LoopDataManager` — same LoopKit/DoseMath
entry points, cited method by method in `WatchLoopManager`'s header. Everything else — the loan
protocol, the ledger, the glance — is new.

## The reference families

| Form | Means | Resolves in |
|---|---|---|
| `#12`, `#102` | A numbered issue in this project's working list — a bug, a fix, or a verify-and-close item. Cited at the line the fix touches. | `RULINGS.md`, `TEST_COVERAGE_PLAN.md`, `RELEASE_CHECKLIST.md`, `FIELD_OBSERVATIONS.md` — grep the number |
| `R1`…`R35` | A **ruling**: a settled design decision, usually Jeremy's, with the reasoning recorded. Rulings are not re-litigated. | `RULINGS.md` |
| `OBS-1`…`OBS-10` | A dated field observation from a real loan. | `FIELD_OBSERVATIONS.md` |
| `WS1` | Workstream 1 — the two-phase "stay active" hand-back: the watch keeps dosing while its records drain, and releases the pod only after the phone acks. | `RULINGS.md`, `DESIGN_LOAN_ADDPUMPEVENTS.md` |
| `E1`…`E5` | Numbered field **experiments** on radio behaviour. `E4` is the big one: orphan the pod between doses so the pod and G7 radios never contend. Default OFF since R31. | `E4_TIME_SEPARATION.md`, `BENCH_DRILLS_PART_E.md` |
| `C1`…`C12` | Findings from the loan-protocol correctness audit. | `DESIGN_LOAN_PROTOCOL_V2.md`, `DESIGN_LOAN_ADDPUMPEVENTS.md` |
| `DESIGN-6` | A numbered constraint in the protocol design. | `DESIGN_LOAN_PROTOCOL_V2.md` |
| `row 10`, `row 13/14` | A row of the protocol **failure matrix** — enumerated failure scenarios and required behaviour. | `DESIGN_LOAN_PROTOCOL_V2.md`, `BENCH_DRILLS_PART_E.md` |
| "the ladder" | The retry schedule for acquiring the pod's BLE session at takeover — successive read attempts on a backstop timer until the session establishes. | `E4_TIME_SEPARATION.md`, `RULINGS.md` |
| "layer 1 / layer 2" | The two provenance layers on a dose record: layer 1 is the pod's own verdict (confirmed / refuted), layer 2 is what the watch assumed at command time. | `DESIGN_LOAN_PROTOCOL_V2.md` |
| `round-2 fix`, `round-4 fix` | A fix from a numbered review round during the protocol build. Historical; the surrounding comment states the actual invariant. | — (self-contained at the call site) |
| `REAL-2` | **Dangling.** Findings from a verification pass that was never written up. The comments carrying them are self-contained; treat the tag as noise. | nothing — do not go looking |

## The registers worth knowing

- **`RULINGS.md`** — settled decisions. Read before proposing a design change; most questions
  have already been answered here, and re-asking them wastes Jeremy's time.
- **`FIELD_OBSERVATIONS.md`** — what actually happened on the wrist, dated, with log excerpts.
  The source of nearly every non-obvious comment in the code.
- **`KNOWN_RESIDUALS.md`** — known gaps and test debt, deliberately carried.
- **`DEVIATION_AUDIT.md`** — how far the watch port has drifted from stock, measured rather
  than asserted. Start here if you are asking "why is this different from Loop?"

## Comment conventions

A comment earns its place if it would **stop someone reverting the line** — it records a
decision, a defeat, or a measured fact. Narration of what the code plainly does does not.
Where a comment recounts a field incident, the incident belongs in `FIELD_OBSERVATIONS.md`
and the comment should carry the conclusion plus a pointer, not the whole story.
