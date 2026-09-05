# RCA: <short title>

| | |
|---|---|
| **Date** | YYYY-MM-DD |
| **Severity** | SEV1 total outage / SEV2 major degradation / SEV3 minor |
| **Duration** | Xh Ym from first impact to full recovery |
| **Author** | |
| **Status** | Draft / Reviewed |

## Summary

Two or three sentences. What broke, who it affected, how it was fixed. Written
so someone outside the team understands it without reading further.

## Impact

Who was affected and how, in terms a non-engineer would recognise. Requests
failed, users logged out, data delayed. Quantify it: how many, for how long.

## Timeline

All times UTC. Include detection, not just action.

| Time | Event |
|---|---|
| 00:00 | Change deployed / trigger occurred |
| 00:00 | First impact (may be earlier than detection) |
| 00:00 | Detected — by alert, or by a person noticing? |
| 00:00 | Investigation began |
| 00:00 | Root cause identified |
| 00:00 | Mitigation applied |
| 00:00 | Full recovery confirmed |

## Detection

How was this found? If a human noticed before monitoring did, that is itself a
finding, and usually the most valuable one in the document.

## Root cause

The underlying cause, not the symptom. Use five whys and write down the chain:

1. Why did requests fail? →
2. Why? →
3. Why? →
4. Why? →
5. Why? →

Stop at something you can actually change. "Human error" is never a root cause;
ask why the system allowed the error to have that effect.

## Contributing factors

What made this worse, or slower to diagnose, without being the cause. Missing
dashboards, a misleading alert, an undocumented dependency, an unclear runbook.

## What went well

Genuinely — good instincts, fast detection, a runbook that worked. Worth
recording so it survives.

## Corrective actions

| # | Action | Type | Owner | Due |
|---|---|---|---|---|
| 1 | | Prevent / Detect / Mitigate | | |

Classify each one:
- **Prevent** — stops it happening again
- **Detect** — finds it faster next time
- **Mitigate** — reduces the impact when it does happen

An RCA with no *Detect* action usually means the detection gap was not examined.

## Evidence

Queries, dashboard screenshots, log excerpts, command output. Enough that
someone could reconstruct the reasoning without having been there.
