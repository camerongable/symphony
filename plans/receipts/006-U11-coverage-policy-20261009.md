# U11 coverage policy approval

On October 9, 2026, the user explicitly approved 98.5% coverage: “I'm fine with
98.5%”. The previously active 99% threshold is replaced with 98.5% in
`elixir/mix.exs`. No tests, exclusions, production safety gates or other quality
requirements change.

Named-file formatting and `git diff --check` pass. The prior full gate's 98.67%
coverage remains historical evidence, not acceptance of the corrected candidate.
Run the final frozen full quality gate to establish current acceptance.

This approval does not authorize the separately proposed native model-turn
budget, deployment, a real-ticket trial or external mutations.
