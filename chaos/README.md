# Chaos — RCA practice

```sh
make chaos      # list the scenarios
make break      # inject a RANDOM fault — you are not told which
make hint       # one nudge
make reveal     # the full root cause
make fix        # restore, and record your time to resolution
```

## How to use it properly

**Always `make break` with no argument.** You can inject a specific scenario
with `python3 chaos/chaos.py break <id>`, but if you pick it you already know
the answer and you are rehearsing, not diagnosing.

**Get a baseline first.** Before your first `make break`, spend twenty minutes
with the system healthy: run `make load`, open Grafana, look at what normal
request rate, latency and error ratio actually are. You cannot recognise an
anomaly without knowing the shape of normal. This is the single most skipped
step and the reason people stare at a correct dashboard and see nothing.

**Capture evidence before you investigate.** `make diagnose` takes twenty
seconds and snapshots events, pod state, previous-container logs and ALB target
health. Events expire after an hour and logs roll — by the time you have a
hypothesis, the proof may be gone.

**Work outside in.** DNS → ALB → target group → pod → dependency. Find the first
hop that fails. Guessing which layer is broken wastes more time than checking.

**Write the RCA even when it feels obvious.** Use `docs/rca/TEMPLATE.md`. The
value is not the document, it is being forced to separate *symptom* from *cause*
and to notice how long detection took. `make fix` records your time to
resolution in `history.log` so you can watch it come down.

## The scenarios

| Layer | Scenarios |
|---|---|
| AWS | `alb-routing`, `irsa-broken` |
| Kubernetes | `oomkill`, `cpu-throttle`, `bad-probe`, `dns-down`, `image-pull` |
| Application | `redis-evict`, `worker-lag`, `db-connection-cap` |

Difficulty is about how far the symptom sits from the cause:

- `*` — the symptom points nearly straight at it
- `**` — one layer of indirection
- `***` — the symptom actively misleads you toward the wrong component

The three-star ones are the point of this exercise. `cpu-throttle` presents as
"the application is slow" when the application is fine and we capped it.
`db-connection-cap` presents as "the database is slow" when the database is
idle. `alb-routing` presents as a frontend bug when nothing is wrong with the
frontend. Learning to distrust the obvious reading is most of what separates L2
from L1.

## Safety

Every scenario is reversible and confined to this cluster. `make fix` restores
the exact prior state; for the image-pull scenario the original image reference
is snapshotted before injection.

`chaos/.active` holds the answer while a fault is live — it is gitignored, and
reading it is cheating.
