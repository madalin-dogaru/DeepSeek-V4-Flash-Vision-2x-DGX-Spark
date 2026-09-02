#!/usr/bin/env python3
"""Live regression for Vision-Exp's position-dependent encoder cache key."""

from __future__ import annotations

import argparse
import base64
import json
import struct
import time
import urllib.request
import zlib


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))


def test_image(width: int = 560, height: int = 266) -> str:
    # This aspect ratio produces the 40x19 ViT grid from issue #172.
    row = bytes((220, 28, 28)) * width
    pixels = b"".join(b"\x00" + row for _ in range(height))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(pixels, 9))
        + png_chunk(b"IEND", b"")
    )
    return base64.b64encode(png).decode()


def request_json(url: str, payload: dict | None = None, timeout: float = 600) -> dict:
    request = urllib.request.Request(
        url,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="GET" if payload is None else "POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response) if response.headers.get_content_type() == "application/json" else {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8888")
    parser.add_argument("--model", default="deepseek-v4-flash-vision-exp")
    args = parser.parse_args()

    image_url = f"data:image/png;base64,{test_image()}"
    chat_url = f"{args.base_url.rstrip('/')}/v1/chat/completions"
    health_url = f"{args.base_url.rstrip('/')}/health"
    timings: list[float] = []

    # Reusing identical bytes at shifted image positions used to return an
    # embedding block with a different compress_pad length and kill EngineCore.
    for shift in range(8):
        prefix = " ".join("padding" for _ in range(shift))
        content = []
        if prefix:
            content.append(
                {
                    "type": "text",
                    "text": f"Ignore these alignment words: {prefix}. Inspect the image next.",
                }
            )
        content.extend(
            [
                {"type": "image_url", "image_url": {"url": image_url}},
                {"type": "text", "text": "Reply with only the dominant color."},
            ]
        )
        payload = {
            "model": args.model,
            "messages": [{"role": "user", "content": content}],
            "max_tokens": 12,
            "temperature": 0,
            "chat_template_kwargs": {"thinking": False},
        }
        started = time.perf_counter()
        result = request_json(chat_url, payload)
        timings.append(time.perf_counter() - started)
        message = ((result.get("choices") or [{}])[0].get("message") or {})
        answer = str(message.get("content") or "").strip()
        if not answer:
            raise RuntimeError(f"shift {shift}: empty model response: {result}")
        normalized = answer.lower().strip()
        compact = "".join(normalized.split())
        recognizes_red = "red" in normalized
        if compact.startswith("#") and len(compact) >= 7:
            try:
                red, green, blue = (int(compact[i : i + 2], 16) for i in (1, 3, 5))
                recognizes_red = recognizes_red or (red > 150 and red > green * 2 and red > blue * 2)
            except ValueError:
                pass
        if not recognizes_red:
            raise RuntimeError(f"shift {shift}: image was not recognized as red: {answer!r}")
        request_json(health_url, timeout=10)
        print(f"shift={shift} ok elapsed={timings[-1]:.2f}s answer={answer[:40]!r}", flush=True)

    print(
        f"PASS: 8 shifted cache reuses; min={min(timings):.2f}s "
        f"max={max(timings):.2f}s total={sum(timings):.2f}s"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
