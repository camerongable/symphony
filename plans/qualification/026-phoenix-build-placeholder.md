# Exact Phoenix placeholder qualification

## Source result

Prepared from accepted `de3d1796bd28e1db49ab19911c751c21dcc4ef86` in the isolated
`phoenix-placeholder-source` checkout, branch `cgable/phoenix-placeholder-20261027`.
This is the separately approved plan026 packaging contract, not a further silent
plan025 retry. Stop for detached review before building a fresh release.

Only four scoped paths change: the READY adapter, its historical qualifier,
their offline tests, and this report. No production/public interface, private
resource, builder, boot guard, public qualifier, configuration, schema, policy,
budget or product source changes. Existing de3 and deployed216 artifacts are
untouched. No live database, service, schedule, native chat or model operation ran.
No external commit publication or deployment is claimed.

## Exact contract

Artifact inventory accepts one keyword-only `artifact_source` context. The three
production callers obtain it only from the already hash-authenticated manifest's
source_root: candidate build, original216 build, and packaged historical proof.
Source inventory never accepts that context, and the no-context inventory remains
strict. There is no environment or CLI bypass.

The only permitted object is the actual symlink
`phoenix-colocated/symphony_elixir/node_modules`, owned by the current user,
gid20, mode0755 and nlink1. Root, source and parents must be canonical directories.
Its raw target must exactly equal the relative path to the authenticated source's
`elixir/assets/node_modules`; canonical resolution must equal that target, which
must be absent even as a dangling alias. Missing/materialized/foreign/redirected
objects fail before regular-file comparison. Every other artifact/helper/source
symlink still fails. The target is neither created nor read.

The validator checks the actual object before enumeration, again at the skip point,
and after enumeration, retaining its device/inode/mtime/ctime identity. A same-byte
replacement or a change to file/directory/missing cannot become a pathname-only
exemption. The returned regular-file dictionary is unchanged. Physical link
metadata is separate evidence, not retroactively attributed to the old manifest:
captured.json records candidate/original placeholder proofs, original_pins returns
its original proof, and historical qualification records its packaged proof.

Existing source/artifact acceptance semantics remain unchanged. Plan026 acceptance
and this report supplement the exact final source/manifest approval; they do not
add an acceptance-protocol category or weaken the existing025 requirements.

## Red and green

The first temporary216-shaped fixture confirms the old no-context inventory
rejects the exact compiler placeholder. Its new explicit-context call initially
failed because that keyword API did not exist:16tests,1error,0.434s. After the
bounded implementation, the narrow positive passed1/0 in0.012s.

The final suite has the original15 checks plus six placeholder tests. Real
filesystem fixtures cover216 and new-release shapes; exact regular dictionary
equality and dangling metadata; missing/file/directory; normalized-but-different
raw target; foreign target; an existing target directory or dangling alias;
redirected root/source/placeholder parents; extra artifact/helper/source links;
skip-point substitutions; and an independently allocated equivalent link swapped
after enumeration. Only privileged uid/gid/mode/nlink negatives simulate the
Path.lstat OS-metadata boundary. Nothing mocks the inventory itself.

Existing artifact fixtures now include a valid physical placeholder and explicit
source context; their artifact/source mutation checks remain intact. Earlier
mailbox-path and semantic limits documented in025 are preserved, not erased.

Commands from this checkout root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s plans/rollout -p test_review_ready_rollout_tools.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s plans/rollout -p test_rollout_tools.py
git diff --check
```

Final logs in ignored `elixir/_build/plan026-evidence/`:

| Gate | Actual result | SHA256 |
| --- | --- | --- |
| ready-tools.log |21tests,0failures,0.389s; exit0|a55b7ab0c6d66dcce0b84b0397f149d775ebbf4910f4e4becd9e4a63f9ef3c12|
| legacy-tools.log |13tests,0failures,0.259s; exit0|b5a34a82ce37e27184c3b6243cb609a5e034b07f2174952c311fc7a487c5ebaf|

The unchanged historical suite retains its known unclosed-fixture ResourceWarnings.
Python compile() syntax validation wrote no pycache. The unchanged public Elixir
qualifier parsed successfully from elixir/:

```sh
ERL_FLAGS='+S 4:4' /opt/homebrew/bin/mise exec -- elixir -e 'Code.string_to_quoted!(File.read!("../plans/rollout/qualify_review_ready_publication.exs")); IO.puts("ELIXIR_SYNTAX_PASS")'
```

All148 private file bytes and executable modes match de3. Builder, boot guard,
public qualifier, historical adapter/tests and all production/configuration/public
interfaces match de3. Diff check passes. No observed live-path fixture fallback or
other new scope deviation occurred in026.

## Limits and next gate

No build or artifact/live qualification ran under this source checkpoint. After
independent source acceptance, a separate authorization must build a fresh clean
release using the unchanged builder, preserve de3/216, authenticate both exact
placeholders, and repeat every025 packaged/read-only/inventory/origin/private/
cold-boot/init-only gate. Artifact and activation reviews remain separate.

Inherited source quality evidence remains Credo650, zero added/three removed
against653. make all stopped at offline uncached file_system setup; coverage,
Dialyzer and full-suite health are not proven. This plans-only change does not
rerun those unrelated source gates or convert them into a PASS.
