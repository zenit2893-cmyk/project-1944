# Call of Duty 3: physics and gameplay invariance harness

The offline harness in `scripts/physics-invariance/physics_invariance.py` compares a 60-Hz capture with a 120-Hz capture. It keeps the authoritative simulation timeline separate from renderer Presents, so a faster counter or repeated framebuffer cannot masquerade as a preserved game simulation. The harness does not modify guest clocks, cvars, generated code, or the PC port.

The harness is ready, and its ten synthetic contract tests pass. There are currently no `cod3-physics-invariance-v1` captures in the workspace. The files under `analysis/timing/captures` use `cod3-candidate-observation-v1`: they observe two candidate functions and do not contain authoritative input, state, gameplay events, or scene frames. They are therefore rejected by this harness. Real COD3 gameplay and 120 FPS remain **NOT VERIFIED**.

## Capture contract

Captures are UTF-8 NDJSON. The contract retains the time units and ordering rules from [timing-trace-format.md](timing-trace-format.md), with two explicit record extensions:

| Record | Required content | Meaning |
| --- | --- | --- |
| `metadata` | `schema="cod3-physics-invariance-v1"`, `timing_schema="cod3-timing-v1"`, build/XEX/input/checkpoint hashes, scenario, seed, clock contract, target Hz, cvars, state/input modes, six expected categories, static anchors | Identity and capture policy. `executable_sha256` is retained for audit and may differ between an original and a recompiled run. |
| `sim` | `host_ns`, contiguous `tick`, `sim_ns`, positive `dt_ns`, nonempty `values` | One completed authoritative simulation step. `sim_ns` is never derived from Present or host FPS. |
| `input` | `host_ns`, `tick`, `sim_ns`, increasing `sequence`, `device`, `action`, nonempty `values` | Exact replay sample. Host timestamps are diagnostics; logical sequence, tick, action and values are compared exactly. |
| `state` | `host_ns`, `tick`, `sim_ns`, `entity_id`, `domain`, nonempty `values` | Post-step authoritative state for one stable entity and domain. Domains are `movement`, `fire`, `ai`, `animation`, `script`, `cutscene` or `world`. |
| `event` | `host_ns`, `tick`, `sim_ns`, category, name, optional entity, nonempty `values` | An event emitted by game logic. A render flash, duplicated Present, or polling callback is not a gameplay event. |
| `frame` | `host_ns`, increasing `present_id`, nondecreasing `render_id`, committed `sim_tick`, render mode | A host Present and the scene build that produced it. A repeated Present keeps the same `render_id`. |
| `end` | `capture_complete=true`, final `host_ns`, `tick`, `sim_ns`, zero dropped/QPC failures when present | Completeness footer. A partial capture cannot pass. |

`metadata.input_log_mode` is `embedded_exact` when `input` records are present, or `digest_only` when only `input_sha256` is available. `metadata.state_log_mode` is `embedded_exact` when per-entity records are present, or `sim_values_only` when only the timing trace's `sim.values` are available. Digest-only input and simulation-only state are useful diagnostics but make the comparison `INCOMPLETE_COVERAGE`; they cannot silently become a pass.

All four controls below are captured as live values for each run:

```json
"cvars": {
  "com_maxfps": 60,
  "pmove_msec": 8,
  "timescale": 1.0,
  "fixedtime": 0
}
```

The 60-Hz capture must declare `render_target_hz=60` and `com_maxfps=60`; the 120-Hz capture must declare `render_target_hz=120` and `com_maxfps=120`. `pmove_msec`, `timescale` and `fixedtime` must match. These are captured values, not instructions to change the game. The checker does not write them back to guest memory.

The metadata must include all six event categories: `movement`, `fire`, `ai`, `animation`, `script` and `cutscene`. A run that does not exercise a category is reported as incomplete. A useful test matrix can use the same schema for several scenarios, but a final acceptance bundle must include the required category coverage and the movement/weapon/AI/script/animation/cutscene probes listed below.

## Comparison policy

The comparator performs these checks in this order:

1. It checks the shared scenario identity: title/media ID, source XEX hash, scenario, exact input digest, checkpoint digest, RNG seed, guest frequency/scalar, timing schema and state schema. The two executable hashes are shown in the report but are not required to match when the comparison crosses original and recompiled builds.
2. It checks that the only required cvar difference is `com_maxfps`. A change in `pmove_msec`, `timescale`, `fixedtime` or another declared control is an invariance failure.
3. It compares embedded input logs by sequence, tick, simulation time, device, action and values. `host_ns` is excluded because the two processes do not run at the same wall time.
4. It compares every simulation tick, its exact `sim_ns`/`dt_ns`, and its recorded values. A missing step, doubled simulation speed, changed quantisation or state value is an invariance failure. Numeric tolerances are absolute and must be supplied explicitly by field path.
5. It compares per-entity state snapshots by `(tick, entity_id, domain)` and then compares values. Stable entity IDs and units must be defined by the capture producer; memory addresses and pointer counts are not sufficient state evidence.
6. It compares gameplay events at exact simulation ticks and times. With complete category coverage, global event order, identity and values are exact. If a category is missing, shared categories are checked independently and the result remains `INCOMPLETE_COVERAGE` because global ordering cannot be certified.
7. It measures rendering separately. Only a new `render_id` counts as a new scene image. Repeated Presents are reported but excluded from the scene-render rate. The report includes the mean rate and p50/p95/p99/max scene intervals; it does not claim display scanout or visual correctness.

The result is one of:

| Result | Interpretation |
| --- | --- |
| `SYNTHETIC_CHECK_ONLY` | The fields matched in a synthetic fixture. This is an analyzer test, never gameplay evidence. |
| `OBSERVED_FIELDS_MATCH_120FPS_UNCERTIFIED` | Game captures matched all recorded invariants and reached the declared scene rates. Full game coverage, visual correctness and physical display refresh still require separate evidence; `gameplay_120fps_verified` stays `false`. |
| `INCOMPLETE_COVERAGE` | No recorded mismatch was found, but exact input/state records, category coverage or the static evidence manifest is missing. |
| `INVARIANCE_FAILED` | At least one identity, cvar, input, simulation, state, event or render-target check failed. |
| `INVALID_CAPTURE_OR_POLICY` | The NDJSON, metadata, static evidence or tolerance policy is invalid. |

## Game logic probes

The values in these records should be captured after the authoritative step or event, using stable IDs and documented units:

| Category | Minimum evidence for a pair |
| --- | --- |
| Movement | Position/velocity, grounded state, jump/fall transition, slope/ladder/collision result, crouch/prone state, grenade or vehicle trajectory where present. |
| Fire | Shot sequence and simulation time, weapon state, ammo, reload markers, recoil, hit/impact and damage result. A muzzle-flash render is not a shot event. |
| AI | Decision/target/route event, reaction timing, target identity and RNG/state digest. AI updates must not multiply with scene Presents. |
| Animation | Clip identity and phase, duration, root motion and foot/reload markers. Intermediate rendering must not repeat or advance authoritative animation events. |
| Script | Objective/checkpoint/QTE state, trigger order and timers. Script callbacks must be tied to simulation ticks. |
| Cutscene | Scene markers, duration, video/audio sync and transition state. Media-only frames without a game step need their own capture schema. |

## Static timing anchors

The harness requires the four relevant string anchors from [analysis/timing-native-evidence.json](../../analysis/timing-native-evidence.json):

| Name | Address | Evidence boundary |
| --- | --- | --- |
| `pmove_msec` | `0x82065B68` | Verified NUL-terminated string bytes only; live cvar value is captured separately. |
| `timescale` | `0x82066288` | Verified NUL-terminated string bytes only; live cvar value is captured separately. |
| `com_maxfps` | `0x82068764` | Verified NUL-terminated string bytes only; live cvar value is captured separately. |
| `fixedtime` | `0x82068798` | Verified NUL-terminated string bytes only; live cvar value is captured separately. |

Pass `--anchor-manifest` to verify that the metadata points to this current evidence file. The checker never treats an address or string anchor as a write target, and static evidence alone cannot establish a simulation frequency.

## Running it

Once the game logger produces a baseline and candidate capture:

```powershell
$py = 'python'
& $py '<workspace>\scripts\physics-invariance\physics_invariance.py' `
  '<workspace>\analysis\timing\captures\cod3-60.ndjson' `
  '<workspace>\analysis\timing\captures\cod3-120.ndjson' `
  --anchor-manifest '<workspace>\analysis\timing-native-evidence.json' `
  --output '<workspace>\analysis\timing\physics-invariance-report.json'
```

For a measured, documented numeric tolerance file:

```json
{
  "state.movement.position_x": 0.0001,
  "event.animation.reload_marker.phase": 0.001
}
```

Do not add a tolerance to make a failing run pass. Record the field unit, measurement error and reason in the run notes. Simulation time, input sequence, event order and event simulation time are always exact.

Self-tests:

```powershell
& $py -m unittest discover `
  -s '<workspace>\tests\physics-invariance' -p 'test_*.py' -v
```

The tests cover matching 60/120 synthetic runs, exact input mismatch, state mismatch and scoped tolerance, repeated Presents, cvar drift, missing event coverage, static-anchor rejection, and incorrect render pairing. They do not launch the game and do not certify Call of Duty 3.
