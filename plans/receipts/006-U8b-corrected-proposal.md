# U8b corrected non-PASS proposals: local controller-API acceptance

## Scope

Explicit native proposals can supersede a stopped nonauthorizing BLOCK/REPAIR
critic attempt, without restarting delivery or changing the installed contract
before authorization. A distinct sealed supersession journal preserves both
inputs, draft baselines and critic/task/owned-stop authority. Revisions advance
from the exact failed draft readback, including repeated corrections.

## Evidence

- Author observed repeated r2 BLOCK → r3 REPAIR → r4 PASS through reservation,
  draft readback, independent critic, authorization, application and replay.
  Historical native/task/result/route/stop/link corruption rejects getters and
  replay; restoration recovers. Private visited ancestry validation avoids public
  getter recursion and live candidate/model/state equality requirements.
- Author observed competing-correction fencing and injected link-insertion
  rollback preserving complete command/amendment/link/effect tables; answer-only,
  uncertain/invoking/reconciliation, nonqualifying PASS and every authorization
  phase remain fenced.
- Populated v34 upgrade/rollback/FK restoration/read-only reopening passed its
  focused case. Independent parallel migration review found no concrete runtime
  defect. Store implementation did not change during later protocol repairs.
- Earlier selected checks: 4/0 (recorded session `59292`, seed not retained here,
  67.8 seconds), then 5/0 (`356308`, 35 excluded). Final normalization/ordinary-
  rejection repairs passed two selected pairs (`755895`, `489844`). Final
  reason-downgrade repair passed 2/0 (`173`, 73 excluded). These are author-
  observed focused results, not a full-suite run or independently rerun aggregate.
- Formatting, specs, warnings-as-errors compilation, scoped Credo and diff checks
  passed. Root read back frozen hashes. Frozen Sol 6.1 medium protocol re-review
  returned bounded PASS, including canonical supersession ownership instead of
  trusting the mutable terminal receipt reason. Ordinary rejection still replays.

Final frozen protocol/test hashes:

- Commands: `543c69bb5dfd33cedfb5fc8f15b44eb6181131012ad21ce0eb665b622d6bae79`
- Amendment: `966f76d510ca133e90a540f57b803b4d52d7aa0fcdac99ad7a96cfc09efd0188`
- Critic test: `1cefa23aef477e458fa1bf029dbcd17d04bbb2744813f5eeb3d909cf520d9108`
- Commands test: `6e07f3e379360cf8c08a30b61925372570bf3d8e49a90bceb105477dc181f90f`
- Store: `75f7c132ac47fc99173e56bf6914968af5ccdcaf7371f66b045ee5405328f1d9`
- Jira operation: `a8c8353ed6b70a44748b177412a56d5d5d50b8d51d7e800a6f32a0a36e868a58`
- HEAD: `52a978818875c59ccf2758ed1b728bb23e33f631`.

## Remaining gates

This accepts controller APIs only. Normal polling still selects the oldest
accepted command and has no amendment consumer; implement that next using the
existing API phase sequence. Mixed commands, whole-Slice-4 integration/native
acceptance and Slice 5 remain. No full suite, commit, push, deployment, native
probe or real-ticket mutation occurred. Historical migration assertions and
separate required-validation/tagged-feedback deferrals remain intact.
