# Changelog

## 2026-09-04

- Advanced the serving layer to vLLM `1356635`, where native DeepSeek V4
  Vision support is merged.
- Added the checksum-pinned PR #54631 patch for one-pass Vision weight loading
  and correct trained DSpark block width.
- Added behavior-based image verification for both post-merge fixes.
- Enabled the validated breakable CUDA graph path and persistent, versioned
  Triton, TileLang, and TorchInductor caches.
- Kept MTP3 after measured comparisons showed it outperforming MTP5 by about
  12% on controlled and natural single-session decode.
- Made image replication use the cluster interface, optional zstd streaming,
  and exact image-ID verification.

## 2026-09-03

- Fixed clean offline startup by propagating the immutable model revision to
  both the primary model loader and the independent MTP draft loader.
- Added profile regressions that verify both revision paths and reject an
  unpinned Compose configuration.
- Corrected the default worker checkout directory in the environment template.

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
- Enabled both logical RoCE paths exposed by one DGX Spark QSFP connection,
  with merged-NIC NCCL scheduling and persistent MTU 9000 configuration.
- Added a read-only dual-path fabric check and documented measured raw RDMA,
  NCCL collective, long-context, and production traffic-distribution evidence.
