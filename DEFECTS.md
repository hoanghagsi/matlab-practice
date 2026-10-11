# Known defects — `drm2d_nonlocality_tool.m`

Found by Agent C (verification pass) on **2026-10-01**, against `PLAN.md`.
Both are **open**. Neither blocks use: the tool passes all five acceptance criteria and
matches the Python reference to 1.3–1.8e-15 against a 1e-6 tolerance.

File under test: `matlab/drm2d_nonlocality_tool.m` (77212 bytes, mtime 2026-10-01 10:10).
Line numbers below refer to that version. **If the file has been edited since, re-locate by
the quoted code, not by line number.**

---

## DEFECT-1 (moderate) — the "single-x slice" check is vacuous

**Status:** open. Costs confidence, not accuracy.

### What is wrong

`drm2d_nonlocality_tool.m:2125-2126`:

```matlab
% The comparison deliberately uses the SINGLE-x slice (Python analysis.fig_dose_maps),
% not the x-averaged slice the GUI displays, so the display choice cannot affect it.
chk('dose RaShi single-x slice', sliceSingleX(dR, grid.xe_mm), ...
    sliceSingleX(R.dose_rashi_Gy, R.x_edges_mm(:)), 1e-6);
```

`sliceSingleX` is applied to **both** operands. Any error in `sliceSingleX` cancels, so the
check cannot detect that the slice function is wrong. It tests that the MATLAB and Python
*dose arrays* agree — which three other checks already do — not that the slice is correct.

### Why it matters

This check exists to enforce a specific requirement: when the display was changed to the
**x-averaged** slice (approved deviation, `PLAN.md` §8 / §12 Q5), the Python comparison had to
stay on the **single-x** path so the display choice could not loosen the 1e-6 validation
tolerance. Agent B reported this as *"enforced by a test, not just a comment"*. **It is not
enforced.** The comment at line 2123-2124 states a guarantee the code does not provide.

### How it was found (reproducer)

Mutation test M4: rewire `sliceSingleX` (line 1807) to call `sliceXAveraged` (line 1795).

- Expected: suite goes red.
- Actual: **46/46 still PASS.**
- Proof the mutant path really ran: the reported relmax shifted 1.28e-15 -> 8.24e-16.

Three other mutations in the same pass *were* caught (reverting the D2 fix; scaling dose by
1+1e-5; corrupting one element of `rashi_Gy`), so the suite is sound apart from this check.

### Mitigating factor

The substance of the requirement is still met. The `dose RaShi` and `dose 2DRM` checks compare
**full 3D arrays** and were mutation-proven real (M2: a 1e-5 scaling produced 3 failures). So
the Python comparison is genuinely independent of the display path — it just is not *guarded*
against someone changing it later.

### Proposed fix (not applied)

Pick either:

1. **Preferred** — export a Python-side single-x slice from `export_reference.py` and compare
   MATLAB's `sliceSingleX` against that. Makes the check a real cross-language test.
2. Cheaper — assert that `sliceSingleX` and `sliceXAveraged` give *different* results on a
   known x-asymmetric array, so swapping one for the other is caught.

Fix the **test**, not the code: `sliceSingleX` itself is correct.

---

## DEFECT-2 (low, but user-facing) — a negative size silently deletes a region

**Status:** open. No crash, no NaN, no wrong physics — but silent data loss on a typo.

### What is wrong

`snapHeight`, `drm2d_nonlocality_tool.m:295-303`:

```matlab
function [h, msg] = snapHeight(h, step_mm, label)
msg = '';
h0  = h;
if ~isfinite(h) || h < 0
    h = 0;                                      % <-- clamps to 0
    msg = sprintf('%s must be >= 0 mm WEPL; reset to 0.', label);
    return;
end
```

Typing `-5` into Region A height sets it to **0**, i.e. Region A disappears from the device.

`PLAN.md` T28 specifies: *"Rejected, previous value restored."* The code clamps to a floor
instead. It is also **internally inconsistent**: non-numeric input (T29) *does* restore the
previous value (verified: reverts to 40), so two kinds of bad input behave differently.

### Wider than Agent C reported

Agent C tested only `heightA`. `snapWidth` (line 277-285) has the **same pattern**:

```matlab
if ~isfinite(w) || w <= 0
    w = D_mm;                                   % <-- clamps to one pin cell
```

So the defect affects **five fields**, via the call sites in `validateParams`:

| line | field | bad-input result |
|---|---|---|
| 249 | Region A width  | reset to `D` (one pin cell) |
| 251 | Region B width  | reset to `D` |
| 253 | Field x-extent  | reset to `D` |
| 257 | Region A height | reset to 0 — **region deleted** |
| 259 | Region B height | reset to 0 — **region deleted** |

The two height fields are the damaging ones; the width fields collapse the region to a single
cell, which is at least visible in the geometry plot.

### Reproducer

```matlab
f = drm2d_nonlocality_tool();                     % defaults: heightA = 60 mm WEPL
drm2d_nonlocality_tool('set', f, 'heightA_mm', -5);
% heightA_mm is now 0, not 60. Region A is gone from the geometry plot.
```

### Why the existing test missed it

Agent B's T28 check asserts only `widthA > 0`. The clamp satisfies that, so it passed. The
check was too weak to express the requirement it was named for.

### Proposed fix (not applied)

In `snapHeight` and `snapWidth`, restore the prior field value instead of a floor on
`~isfinite` or out-of-range input, matching the non-numeric path.

**Implementation note:** neither function currently receives the previous value — they take only
`(h, step_mm, label)` / `(w, D_mm, label)`. So the fix needs either an extra `prev` argument
threaded from `validateParams` (lines 249-259), or the restore handled at the call site with
the snap functions signalling rejection rather than silently substituting. The call-site option
is probably cleaner, since `validateParams` already holds the previous parameter struct.

Add a test that asserts the value is **unchanged** after bad input, not merely positive.

---

## Context for picking this up later

- Verification report: Agent C's full 35-test table, mutation results and the two false alarms
  it self-corrected (T24, T35) are in the session transcript, not on disk.
- Test harnesses: `matlab/tests/agentC_gaps.m`, `agentC_probe.m`, `agentC_final.m`.
- Built-in suite: `drm2d_nonlocality_tool('selftest')` (31 checks) and `('selftest','full')`
  (46 checks, needs `matlab/reference/*.mat`).
- MATLAB: R2026b at `C:\Program Files\MATLAB\R2026b\bin\matlab`; headless via `matlab -batch`.
  Legacy `figure`/`uicontrol` with `'Visible','off'` works under `-batch` — no `'nogui'`
  fallback is needed.
- `matlab/reference/*.mat` is **244 MB** and regenerable with `python matlab/export_reference.py`.
  Safe to delete if space is needed; `selftest('full')` will then fail until it is re-run.
- Unrelated and also open: the three `analytic_model/nonlocality.py` defects from the earlier
  adversarial pass (see `CLAUDE.md` Current Status). The MATLAB tool already implements the
  **corrected** D2 spectral weight, so it is not affected by those.

Checking with MATLAB codes
