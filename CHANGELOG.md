# Changelog

## 2026-09-02

- Added the pinned official vLLM Vision runtime for two DGX Spark systems.
- Overlaid FlashInfer pull request #4802 at commit `26fabfe` for GB10/SM121.
- Configured native vision, 1M context, FP8 KV, expert parallelism, and MTP3.
- Disabled the FlashInfer crossover autotuner after a verified GB10 failure.
- Added coordinated two-rank supervision and bounded incident capture.
- Added image-content, image-cache-alignment, profile, and shutdown checks.
- Documented the exact deployed stack, acceptance evidence, and failure modes.
- Changed model staging to one pinned download followed by verified ConnectX
  replication to the worker's local NVMe cache.
- Added optional, non-owning Spark Studio endpoint registration with duplicate
  detection and an integration regression test.
