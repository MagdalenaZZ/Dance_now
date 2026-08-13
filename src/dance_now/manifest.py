from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}

# Wan2.2 TI2V-5B's supported (width, height) presets. Generation is fixed to
# one of these; there is no arbitrary resolution. Source: wan/configs/__init__.py
# in https://github.com/Wan-Video/Wan2.2
SUPPORTED_VIDEO_SIZES: dict[str, tuple[int, int]] = {
    "1280*720": (1280, 720),
    "720*1280": (720, 1280),
    "1280*704": (1280, 704),
    "704*1280": (704, 1280),
    "1024*704": (1024, 704),
    "704*1024": (704, 1024),
    "832*480": (832, 480),
    "480*832": (480, 832),
}

# Model output fps and the frame count that produced the "five-second video"
# in the README (121 frames / 24 fps = 5.04s). Wan requires frame_num of the
# form 4n+1 (see --frame_num help in generate.py upstream).
DEFAULT_FPS = 24
DEFAULT_FRAME_NUM = 121


def nearest_video_size(width: int, height: int) -> str:
    """Pick the supported preset whose aspect ratio is closest to width:height."""
    aspect = width / height
    return min(
        SUPPORTED_VIDEO_SIZES,
        key=lambda name: abs((SUPPORTED_VIDEO_SIZES[name][0] / SUPPORTED_VIDEO_SIZES[name][1]) - aspect),
    )


def frame_num_for_seconds(seconds: float, fps: int = DEFAULT_FPS) -> int:
    """Round a requested duration to the nearest Wan-valid (4n+1) frame count."""
    if seconds < 1:
        raise ValueError("seconds must be at least 1")
    n = max(round((seconds * fps - 1) / 4), 1)
    return 4 * n + 1


@dataclass(frozen=True)
class ManifestItem:
    input_uri: str
    output_uri: str
    prompt: str
    seed: int
    video_size: str = "1280*704"
    frame_num: int = DEFAULT_FRAME_NUM


def parse_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lstrip("/"):
        raise ValueError(f"Expected an S3 object URI, got {uri!r}")
    return parsed.netloc, parsed.path.lstrip("/")


def safe_stem(value: str) -> str:
    stem = Path(value).stem
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip("-._")
    return cleaned or "video"


def output_key(prefix: str, input_key: str, index: int) -> str:
    name = f"{index:04d}-{safe_stem(PurePosixPath(input_key).name)}.mp4"
    return str(PurePosixPath(prefix.strip("/")) / name)


def dumps_manifest(items: list[ManifestItem]) -> bytes:
    payload = {"version": 1, "items": [asdict(item) for item in items]}
    return json.dumps(payload, indent=2, ensure_ascii=False).encode("utf-8")


def loads_manifest(data: bytes | str) -> list[ManifestItem]:
    payload = json.loads(data)
    if payload.get("version") != 1 or not isinstance(payload.get("items"), list):
        raise ValueError("Manifest must have version 1 and an items array")
    items = [ManifestItem(**item) for item in payload["items"]]
    if not items:
        raise ValueError("Manifest contains no images")
    for item in items:
        parse_s3_uri(item.input_uri)
        parse_s3_uri(item.output_uri)
        if not item.prompt.strip():
            raise ValueError(f"Prompt is empty for {item.input_uri}")
        if item.seed < 0:
            raise ValueError(f"Seed must be non-negative for {item.input_uri}")
        if item.video_size not in SUPPORTED_VIDEO_SIZES:
            raise ValueError(f"Unsupported video_size {item.video_size!r} for {item.input_uri}")
        if item.frame_num < 1 or (item.frame_num - 1) % 4 != 0:
            raise ValueError(f"frame_num must be of the form 4n+1 for {item.input_uri}")
    return items

