# syntax=docker/dockerfile:1.7

ARG VLLM_BASE_IMAGE=vllm/vllm-openai@sha256:8568b4bbc821903d93a0a9c17dd80382fdc0ba78eaa128e3eb5cb71c3bf06b79
FROM ${VLLM_BASE_IMAGE}

ARG FLASHINFER_COMMIT=26fabfe93ab7e866b1a3b581ca6ba2b984d49706
ARG FLASHINFER_ARCHIVE_SHA256=e007f4611041cf4015224044fbe4b53a3074561626362accc542093c4757a5ad

LABEL org.opencontainers.image.source="https://github.com/vllm-project/vllm"
LABEL ai.dgx-spark.runtime="deepseek-v4-flash-vision-gb10"
LABEL ai.dgx-spark.vllm.base.digest="sha256:8568b4bbc821903d93a0a9c17dd80382fdc0ba78eaa128e3eb5cb71c3bf06b79"
LABEL ai.dgx-spark.vllm.base.version="0.28.1rc1.dev137+g5ab628dd1"
LABEL ai.dgx-spark.flashinfer.commit="${FLASHINFER_COMMIT}"
LABEL ai.dgx-spark.flashinfer.archive.sha256="${FLASHINFER_ARCHIVE_SHA256}"

ADD --checksum=sha256:${FLASHINFER_ARCHIVE_SHA256} \
    https://github.com/flashinfer-ai/flashinfer/archive/${FLASHINFER_COMMIT}.tar.gz \
    /tmp/flashinfer.tar.gz

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# PR #4802 must replace the complete Python package surface. Its CUDA sources
# and headers belong under the wheel's data tree, where FlashInfer's JIT loader
# resolves them. The stock AOT module takes precedence over source, so remove it
# explicitly; the corrected SM121 module is compiled once on first model boot.
RUN set -eux; \
    site_root="$(python3 -c 'import inspect, os, flashinfer; print(os.path.dirname(inspect.getfile(flashinfer)))')"; \
    source_root="/tmp/flashinfer-${FLASHINFER_COMMIT}"; \
    tar -xzf /tmp/flashinfer.tar.gz -C /tmp; \
    test -f "${source_root}/flashinfer/mla/_sparse_mla_sm120.py"; \
    test -f "${source_root}/csrc/sparse_mla_sm120.cu"; \
    test -f "${source_root}/include/flashinfer/attention/sparse_mla_sm120/model/model_type.h"; \
    cp -a "${source_root}/flashinfer/." "${site_root}/"; \
    cp -a "${source_root}/csrc/." "${site_root}/data/csrc/"; \
    cp -a "${source_root}/include/flashinfer/." "${site_root}/data/include/flashinfer/"; \
    rm -rf /usr/local/lib/python3.12/dist-packages/flashinfer_jit_cache/jit_cache/sparse_mla_sm120; \
    python3 -m py_compile \
      "${site_root}/mla/_core.py" \
      "${site_root}/mla/_sparse_mla_sm120.py" \
      "${site_root}/mla/_sparse_mla_sm120_cpb.py" \
      "${site_root}/mla/_sparse_mla_sm120_plan.py"; \
    grep -q '_DecodeDispatchEnvelope' "${site_root}/mla/_sparse_mla_sm120_plan.py"; \
    test ! -e /usr/local/lib/python3.12/dist-packages/flashinfer_jit_cache/jit_cache/sparse_mla_sm120/sparse_mla_sm120.so; \
    rm -rf "${source_root}" /tmp/flashinfer.tar.gz
