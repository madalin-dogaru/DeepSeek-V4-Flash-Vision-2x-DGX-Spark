#!/usr/bin/env python3
from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PATCH = ROOT / "patches" / "vllm-pr54631.patch"
PATCH_SHA256 = "4fecb840fcd985eeada0538202f920e9293d8ecb7ce9c0cb8337ed7703cff4d4"
VLLM_COMMIT = "1356635d837c4ef002ec98c1a0296e7ff60be3c1"
VLLM_VERSION = "0.28.1rc1.dev317+g1356635d8"
WHEEL_SHA256 = "1928aee68356885d7eb696aa0ed226dfa537e00721c9c5376fafddc04490d198"
IMAGE = "local/deepseek-v4-flash-vision:vllm-1356635-pr54631-fi-26fabfe-gb10"


def require(path: str, values: tuple[str, ...]) -> None:
    text = (ROOT / path).read_text()
    for value in values:
        assert value in text, f"{path} is missing pin: {value}"


assert sha256(PATCH.read_bytes()).hexdigest() == PATCH_SHA256
require(
    "build-official-vision-runtime.sh",
    (VLLM_COMMIT, VLLM_VERSION, WHEEL_SHA256, PATCH_SHA256, IMAGE),
)
require(
    "recipe/official-vision/Dockerfile.current",
    (VLLM_COMMIT, VLLM_VERSION, WHEEL_SHA256, PATCH_SHA256),
)
require("docker-compose.official-vision.yml", (IMAGE,))
require(".env.dspark.example", (IMAGE, VLLM_COMMIT[:7]))
require("scripts/verify-current-vision-image.sh", (VLLM_COMMIT, VLLM_VERSION, PATCH_SHA256))

for path in (
    "build-official-vision-runtime.sh",
    "docker-compose.official-vision.yml",
    "start-official-vision-runtime.sh",
    "recipe/official-vision/Dockerfile.current",
    "scripts/verify-current-vision-image.sh",
):
    text = (ROOT / path).read_text()
    assert "/home/sero" not in text, f"private deployment path leaked into {path}"
    assert "nyx/" not in text, f"private image namespace leaked into {path}"

print("Runtime pins and public recipe boundaries verified.")
