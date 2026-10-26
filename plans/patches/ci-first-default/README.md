# CI-first default: accepted local candidate

The source and canonical-policy patches are independently reviewed local work.
They are NOT applied to executable framework source or installed into canonical
shared configuration/rules/skills. This patch-only handoff prevents a broker or
later Mix invocation from accidentally activating the default during the
unresolved PPL-9881 push. No commit, push or deployment is authorized here.

Supported ordinary-ticket CI-first policies: Grail, Polaris, Augusta and
Blackburn. Repository omission inherits `draft_mr`; explicit
`verification_first` retains the old order. Invalid policies and unsupported
collection deny before remote mutation. PrePost remains explicitly
verification-first until its conditional selector evidence is supported.
Legacy non-ticket CI-first and manual-required ticket contracts are unsupported,
not silently waived. Optional allow-failure jobs are not certified by this CI
gate; independent verification and contracted manual validation still own any
additional required evidence.

[source.patch](source.patch) contains only named source/test changes.
[shared-policy.patch](shared-policy.patch) targets canonical shared paths, not
provider-specific copies. Both patches must be revalidated against their recorded
base hashes and current routing/ownership before any separately approved
installation. Do not apply them blindly to a changed checkout.

Validation: 63 focused tests, touched-file formatting, specs and isolated
Dialyzer passed. Dialyzer reused the copied dependency PLT without a freshness
claim. No full suite or live CI integration ran. See
[validation](VALIDATION.md) and the historically frozen
[candidate manifest](CANDIDATE.md); its earlier Dialyzer-deferred line is superseded
by the supplemental validation receipt.

Reviewed patch SHA256:

- source: `620e5f9258d90857dce62719eb020d3110aceed824ceca6d41e40422575edae9`
- shared policy: `a2f05fe54006185599f9a674252408608c3ba9e03de06710f3907fda0c7b1b32`

The separately implemented push-lifecycle repair remains in the framework
checkout, with a frozen blocker-only build and independent acceptance. It remains
undeployed: the actual activation guard found five Desktop source-cwd helpers,
and historical push uncertainty still lacks a genuine original outcome receipt.
