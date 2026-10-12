# U7 observation and feedback boundary follow-up

The existing MR guard rejection table now includes absent owner observation time
and a non-string native queue observation time. Both reject an otherwise valid
claim before issuance.

The existing feedback receipt test now checks public requeue requests for an unknown
receipt and a pending receipt that is not a change request. The first preserves the
empty ledger; the second preserves the exact recorded rows.

Verification: the two focused files passed 10 tests, zero failures, seed 706116
in 0.6 seconds. Formatting passed. Independent frozen-file review accepted the
assertions as meaningful public-boundary checks with no findings. No production
behavior, timeout, coverage threshold, or route-enable policy changed.

These results do not establish combined Slice 3 acceptance. The previous full gate
failed four file-tool timing cases and measured 98.93% coverage; a fresh full gate
is required after the subsequent reviewed changes.
