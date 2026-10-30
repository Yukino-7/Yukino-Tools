# Local Codex token totals

The Codex view reads metadata and usage counters from `.jsonl` and `.jsonl.zst`
files in the configured Codex folder's `sessions` and `archived_sessions`
directories. Compressed logs use the bundled Zstandard decoder; no additional
command-line tool is required, and decompressed logs are never written to disk.

Total tokens are input plus output. Cached input is already included in input,
and reasoning is already included in output. Response IDs deduplicate modern
records across pages, archive copies, and compressed/uncompressed copies.
Older cumulative counters contribute deltas rather than repeated snapshots.

The Token activity chart offers Today, 7 days, 30 days, and All time. All time
shows daily totals from the earliest recorded usage date through today, including
compressed logs and zero-usage days, with the covered dates shown below the total.

Unchanged compressed logs are cached. Changed compressed files are decoded from
the beginning and accepted only after frame validation. Empty, truncated, or
damaged archives contribute to the existing unreadable-file warning; a failed
read does not commit partial counters. If a previously readable archive becomes
unreadable, its last successful in-memory snapshot remains until a successful
rescan or application restart, with the warning visible meanwhile.

These are totals for locally available logs, not a permanent account ledger.
Deleting logs or switching the configured data folder can still reduce totals.
