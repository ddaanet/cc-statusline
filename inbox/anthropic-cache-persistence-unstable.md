---
name: anthropic-cache-persistence-unstable
description: "Anthropic prompt-cache persistence changed mid-session in June 2026; don't assume a fixed 1h TTL when reasoning about cache cost"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b2fbd920-8c52-492a-b68c-9813cca08711
  modified: 2026-07-29T07:19:55.955Z
---

Prompt-cache lifetime has no reliable fixed TTL — a 2.2h idle gap expired the cache while an 80h gap three days later survived intact (same session, `claude-opus-4-8`, June 2026). Detect cold-cache events **structurally** (`cache_read` dropping below the previous call's `cache_read + cache_creation`), never by elapsed time. Also: raw `input_tokens` collapses to ~2 in steady state because fresh prompt content is billed as `cache_creation` — that's the real "new tokens this turn" signal.

Full UTC timeline and verification data live in the living design doc: `statusline-design.md` in `~/code/cc-statusline` → §4.9 "Cold-cache detection is structural, never time-based". Related: [[statusline-line2-stats]], [[reference_cc_statusline]].
