# Credits and upstreams

This repository packages and documents work from several upstream projects:

- DeepSeek: `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp` model and reference code.
- vLLM: official multimodal implementation in pull request #54566 and the
  `deepseekv4-flash-vision` prerelease image.
- FlashInfer: SM120/SM121 sparse-MLA implementation in pull request #4802.
- MiaAI-Lab: two-node DGX Spark launch and operational groundwork.
- Tony Deangelo: DGX Spark DeepSeek V4 NVFP4 recipe lineage.
- NVIDIA: DGX Spark, ConnectX-7, CUDA, NCCL, and container runtime.

The repository scripts and documentation are MIT licensed. vLLM-derived code,
FlashInfer, model weights, base images, CUDA, and NCCL retain their respective
upstream licenses and terms.

Primary references:

- https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-Vision-Exp
- https://github.com/vllm-project/vllm/pull/54566
- https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash-Vision-Exp
- https://github.com/flashinfer-ai/flashinfer/pull/4802
- https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
- https://github.com/tonyd2wild/DeepSeek-v4-Flash-Vision-Exp-DSpark-1M-NVFP4-KV-2x-DGX-Spark
- https://docs.nvidia.com/dgx/dgx-spark/spark-clustering.html
