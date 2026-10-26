# Undeployed agent-log states

Owner Decision 3 supports main 45312a9 (schema 9) and fresh/current state. No branch build was deployed.

The archived fixtures are copied from 8038586, before consolidation phase 3. They describe schema 10/11, partial schema-12 capabilities and a missing lookahead field after an intermediate scanner. They are historical examples, not supported upgrade inputs. Their runtime privacy/provenance regressions remain active using main/current origins.

Checkpoint metadata versions 1–4 and scanner versions before 6 were also branch-only. Existing recovery matrices now start from main's unversioned metadata (0); resumable current scanner version 6 and cross-tool recovery remain active. Malformed or obsolete current checkpoints fail closed rather than being silently repaired. Main's old queue formats remain supported because 45312a9 decoded and wrote them.

`checkpoint-fixtures.json` also archives the version-2/version-4 metadata fixtures and the malformed scanner-token shape formerly swallowed by recovery. Active tests retain masking checks using a valid current scanner and test rejection of obsolete versions. `schema-fixtures.swift.txt` preserves the original schema 10/11, partial schema-12 and absent-lookahead upgrade examples; main adoption, indexed cleanup, provenance preservation, rollback and deletion-preview assertions stay active.
