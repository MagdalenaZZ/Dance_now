from __future__ import annotations

import argparse
import io
import json
import random
import re
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

import boto3
from PIL import Image

from .manifest import (
    DEFAULT_FRAME_NUM,
    IMAGE_SUFFIXES,
    SUPPORTED_VIDEO_SIZES,
    ManifestItem,
    dumps_manifest,
    frame_num_for_seconds,
    nearest_video_size,
    output_key,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Upload/list images, write a manifest to S3, and submit one cost-efficient GPU job."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input-dir", type=Path, help="Local directory of images to upload")
    source.add_argument("--s3-input-prefix", help="Existing S3 prefix, e.g. s3://bucket/images/")
    parser.add_argument("--bucket", help="S3 bucket (required with --input-dir)")
    parser.add_argument("--prompt", required=True, help="Default motion/camera prompt")
    parser.add_argument(
        "--sidecar-prompts",
        action="store_true",
        help="Use <image-stem>.txt beside local images when present",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        help="Video duration in seconds, rounded to the nearest frame count Wan "
        f"supports (default: {DEFAULT_FRAME_NUM} frames, ~{DEFAULT_FRAME_NUM / 24:.2f}s)",
    )
    parser.add_argument(
        "--video-size",
        choices=["auto", *sorted(SUPPORTED_VIDEO_SIZES)],
        default="auto",
        help="Wan output resolution. 'auto' (default) picks the supported preset closest "
        "to each image's own aspect ratio; pass one explicitly to force it for every image.",
    )
    parser.add_argument("--output-prefix", default="dance-now/outputs")
    parser.add_argument("--job-prefix", default="dance-now/jobs")
    parser.add_argument("--job-queue", required=True)
    parser.add_argument("--job-definition", required=True)
    parser.add_argument("--job-name", help="Defaults to dance-now-<UTC timestamp>")
    parser.add_argument("--seed", type=int, help="Base seed; random when omitted")
    parser.add_argument("--region", help="AWS region; otherwise normal AWS resolution is used")
    parser.add_argument("--dry-run", action="store_true", help="Create/upload manifest but do not submit")
    return parser


def _s3_parts(uri: str) -> tuple[str, str]:
    if not uri.startswith("s3://"):
        raise ValueError("--s3-input-prefix must start with s3://")
    bucket_and_key = uri[5:].split("/", 1)
    return bucket_and_key[0], bucket_and_key[1] if len(bucket_and_key) == 2 else ""


def _video_size_for(args: argparse.Namespace, width: int, height: int) -> str:
    return nearest_video_size(width, height) if args.video_size == "auto" else args.video_size


def _local_inputs(args: argparse.Namespace, s3, job_name: str) -> tuple[str, list[tuple[str, str, str]]]:
    if not args.bucket:
        raise ValueError("--bucket is required with --input-dir")
    root = args.input_dir.resolve()
    paths = sorted(
        path for path in root.rglob("*") if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )
    if not paths:
        raise ValueError(f"No supported images found in {root}")
    upload_prefix = str(PurePosixPath(args.job_prefix) / job_name / "inputs" / root.name)
    result = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        key = str(PurePosixPath(upload_prefix) / relative)
        s3.upload_file(str(path), args.bucket, key)
        prompt = args.prompt
        sidecar = path.with_suffix(".txt")
        if args.sidecar_prompts and sidecar.exists():
            prompt = sidecar.read_text(encoding="utf-8").strip() or prompt
        with Image.open(path) as image:
            video_size = _video_size_for(args, *image.size)
        result.append((key, prompt, video_size))
    return args.bucket, result


def _s3_inputs(args: argparse.Namespace, s3) -> tuple[str, list[tuple[str, str, str]]]:
    bucket, prefix = _s3_parts(args.s3_input_prefix)
    paginator = s3.get_paginator("list_objects_v2")
    keys = sorted(
        obj["Key"]
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix)
        for obj in page.get("Contents", [])
        if Path(obj["Key"]).suffix.lower() in IMAGE_SUFFIXES
    )
    if not keys:
        raise ValueError(f"No supported images found under {args.s3_input_prefix}")
    result = []
    for key in keys:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        with Image.open(io.BytesIO(body)) as image:
            video_size = _video_size_for(args, *image.size)
        result.append((key, args.prompt, video_size))
    return bucket, result


def _job_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "-", value).strip("-_")
    return cleaned[:128] or "dance-now"


def run(args: argparse.Namespace) -> dict:
    session = boto3.Session(region_name=args.region)
    s3 = session.client("s3")
    batch = session.client("batch")
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    job_name = _job_name(args.job_name or f"dance-now-{timestamp}")
    base_seed = args.seed if args.seed is not None else random.SystemRandom().randrange(2**31)
    frame_num = frame_num_for_seconds(args.seconds) if args.seconds is not None else DEFAULT_FRAME_NUM

    if args.input_dir:
        bucket, inputs = _local_inputs(args, s3, job_name)
    else:
        bucket, inputs = _s3_inputs(args, s3)

    output_prefix = str(PurePosixPath(args.output_prefix.strip("/")) / job_name)
    items = [
        ManifestItem(
            input_uri=f"s3://{bucket}/{key}",
            output_uri=f"s3://{bucket}/{output_key(output_prefix, key, index)}",
            prompt=prompt,
            seed=base_seed + index,
            video_size=video_size,
            frame_num=frame_num,
        )
        for index, (key, prompt, video_size) in enumerate(inputs)
    ]
    manifest_key = str(PurePosixPath(args.job_prefix.strip("/")) / job_name / "manifest.json")
    s3.put_object(
        Bucket=bucket,
        Key=manifest_key,
        Body=dumps_manifest(items),
        ContentType="application/json",
    )
    manifest_uri = f"s3://{bucket}/{manifest_key}"
    result = {
        "job_name": job_name,
        "manifest_uri": manifest_uri,
        "images": len(items),
        "duration_seconds": round(frame_num / 24, 2),
        "video_sizes": sorted({item.video_size for item in items}),
    }
    if not args.dry_run:
        response = batch.submit_job(
            jobName=job_name,
            jobQueue=args.job_queue,
            jobDefinition=args.job_definition,
            containerOverrides={
                "environment": [
                    {"name": "MANIFEST_S3_URI", "value": manifest_uri},
                ]
            },
        )
        result["job_id"] = response["jobId"]
    return result


def main() -> None:
    parser = _parser()
    try:
        print(json.dumps(run(parser.parse_args()), indent=2))
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    except Exception as exc:
        print(f"AWS request failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
