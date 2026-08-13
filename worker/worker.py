from __future__ import annotations

import json
import os
import sys
import time
import traceback
from pathlib import Path

from dance_now.manifest import ManifestItem, loads_manifest, parse_s3_uri


def env_bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).lower() in {"1", "true", "yes", "on"}


def object_exists(s3, uri: str) -> bool:
    bucket, key = parse_s3_uri(uri)
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except s3.exceptions.ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def download_object(s3, uri: str, destination: Path) -> None:
    bucket, key = parse_s3_uri(uri)
    destination.parent.mkdir(parents=True, exist_ok=True)
    s3.download_file(bucket, key, str(destination))


def upload_file(s3, source: Path, uri: str, content_type: str) -> None:
    bucket, key = parse_s3_uri(uri)
    s3.upload_file(str(source), bucket, key, ExtraArgs={"ContentType": content_type})


def metadata_uri(output_uri: str) -> str:
    return output_uri.removesuffix(".mp4") + ".json"


def load_pipeline(model_dir: Path):
    import torch
    import wan
    from wan.configs import WAN_CONFIGS

    torch.cuda.set_device(0)
    config = WAN_CONFIGS["ti2v-5B"]
    pipeline = wan.WanTI2V(
        config=config,
        checkpoint_dir=str(model_dir),
        device_id=0,
        rank=0,
        t5_fsdp=False,
        dit_fsdp=False,
        use_sp=False,
        t5_cpu=True,
        convert_model_dtype=True,
    )
    return pipeline, config


def generate_one(pipeline, config, item: ManifestItem, input_path: Path, output_path: Path) -> None:
    from PIL import Image
    from wan.configs import MAX_AREA_CONFIGS, SIZE_CONFIGS
    from wan.utils.utils import save_video

    image = Image.open(input_path).convert("RGB")
    video = pipeline.generate(
        item.prompt,
        img=image,
        size=SIZE_CONFIGS[item.video_size],
        max_area=MAX_AREA_CONFIGS[item.video_size],
        frame_num=item.frame_num,
        shift=config.sample_shift,
        sample_solver="unipc",
        sampling_steps=config.sample_steps,
        guide_scale=config.sample_guide_scale,
        seed=item.seed,
        offload_model=True,
    )
    save_video(
        tensor=video[None],
        save_file=str(output_path),
        fps=config.sample_fps,
        nrow=1,
        normalize=True,
        value_range=(-1, 1),
    )
    del video


def main() -> None:
    import boto3
    from huggingface_hub import snapshot_download

    manifest_uri = os.environ["MANIFEST_S3_URI"]
    work_dir = Path(os.getenv("WORK_DIR", "/tmp/dance-now"))
    model_dir = Path(os.getenv("MODEL_DIR", "/models/Wan2.2-TI2V-5B"))
    model_id = os.getenv("MODEL_ID", "Wan-AI/Wan2.2-TI2V-5B")
    skip_existing = env_bool("SKIP_EXISTING", True)
    s3 = boto3.client("s3")

    manifest_path = work_dir / "manifest.json"
    download_object(s3, manifest_uri, manifest_path)
    items = loads_manifest(manifest_path.read_bytes())
    print(f"Loaded {len(items)} image(s) from {manifest_uri}", flush=True)

    model_dir.mkdir(parents=True, exist_ok=True)
    print(f"Ensuring {model_id} is available at {model_dir}", flush=True)
    snapshot_download(repo_id=model_id, local_dir=model_dir)

    pending = [item for item in items if not (skip_existing and object_exists(s3, item.output_uri))]
    if not pending:
        print("Every output already exists; nothing to do.", flush=True)
        return

    print(f"Loading model once for {len(pending)} pending video(s)", flush=True)
    pipeline, config = load_pipeline(model_dir)
    failures: list[str] = []
    for index, item in enumerate(pending):
        started = time.monotonic()
        item_dir = work_dir / f"item-{index:04d}"
        input_path = item_dir / "input" / Path(parse_s3_uri(item.input_uri)[1]).name
        output_path = item_dir / "output.mp4"
        try:
            print(f"Generating {index + 1}/{len(pending)}: {item.input_uri}", flush=True)
            download_object(s3, item.input_uri, input_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            generate_one(pipeline, config, item, input_path, output_path)
            upload_file(s3, output_path, item.output_uri, "video/mp4")
            elapsed = round(time.monotonic() - started, 2)
            metadata = {
                "input_uri": item.input_uri,
                "output_uri": item.output_uri,
                "prompt": item.prompt,
                "seed": item.seed,
                "video_size": item.video_size,
                "frame_num": item.frame_num,
                "duration_seconds": round(item.frame_num / 24, 2),
                "elapsed_seconds": elapsed,
                "model": model_id,
                "batch_job_id": os.getenv("AWS_BATCH_JOB_ID"),
            }
            metadata_path = item_dir / "output.json"
            metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
            upload_file(s3, metadata_path, metadata_uri(item.output_uri), "application/json")
            print(f"Uploaded {item.output_uri} in {elapsed:.1f}s", flush=True)
        except Exception:
            failures.append(item.input_uri)
            traceback.print_exc()

    if failures:
        raise RuntimeError(f"Failed to generate {len(failures)} item(s): {failures}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
