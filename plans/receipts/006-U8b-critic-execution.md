# U8b isolated critic execution/result acceptance

Accepted locally after independent frozen Sol re-review and root's focused
13-test run (session 69788, seed 774323, 5.1 seconds, zero failures).
StageRunner exact-turn execution uses the persisted publication receipt and
stored prompt/schema/allocation in an ephemeral restricted REVIEW session.
Session/turn callbacks persist ownership before result adoption; duplicate active
entry returns pending without another invocation or clobbering the first caller.
Recorded replay validates exact stored receipt and current bindings. BLOCK and
PASS-with-findings remain non-authorizing; uncertain errors retain reconciliation.

The initial review found three result-proof gaps. Public regressions reproduced
all three (13 tests, three failures) before the author repaired them: result before
turn persistence, self-checksummed policy corruption, and task identity drift.
Re-review accepted nonempty exact thread/turn, recomputed full REVIEW policy with
canonical non-source cwd/owner checks, and exact child-task identity comparison.

Author evidence: 67 affected tests passed before final repairs; focused critic
tests 13/0 after repairs; format, specs, owned-file strict Credo and cached Dialyzer
pass. No full suite or live provider calls were run.

Frozen SHA-256:

- Store: `1c0c5f4344feb13f490e8f28f6c5a94d11ac2649de9d60e123eb2dd95527b615`
- amendment: `83b642f734c2a9ba63c87049a47308ddaab9f51567f6c7be499259263acb4203`
- critic: `be5387741ce7bbe0eaf740bca44daf18921b56ea8f562a622e756bb83ccf895f`
- critic tests: `a58d565f0be734bb08f6db3436416746dfe8a2fc2a5eff0350e4a5cd4584d21a`
- migration tests: `d96b9c2bde68c0a093f3fedb65d933ba7f69dd07d2b47ef7113f4bf2da686cfe`

Unedited packet baselines: StageRunner
`f7579e3c0d986984aef375e681ebf49239f693b0680e72278f399a194495be7e`,
AppServer `ac1a7abbf623860f74c4d550a824b6e0cf0a0af21bf9a2d01ed28b349c83ee95`.
Both were already dirty; these are not claims against the original Git baseline.
Native visibility/history, complete skill-context acceptance, Jira authorization,
contract application and full-slice acceptance remain separate.
