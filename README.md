# Dance Now

Generate five-second videos from batches of images using the open Wan 2.2 TI2V-5B
model and a single cost-conscious AWS Batch Spot GPU job.

The default design deliberately processes a whole manifest sequentially on one
`g5.2xlarge`. Wan is downloaded and loaded once, then reused for every image in
the batch. The Batch compute environment has zero minimum vCPUs and at most one
GPU instance, so it scales back down when the work is finished.

## What gets created

- An ECR image containing the worker and Wan inference code (not the model weights).
- An AWS Batch Spot compute environment restricted to one `g5.2xlarge`.
- A job queue and job definition.
- IAM roles scoped to the S3 bucket supplied during deployment.
- A temporary 150 GB encrypted root disk, deleted with the Spot instance.

Model weights are downloaded from Hugging Face at the beginning of each cold
job. This avoids paying every month for persistent model storage. Input images,
the generated MP4 files, and JSON metadata live in your existing S3 bucket.

## Prerequisites

- AWS CLI credentials with permission to use CloudFormation, IAM, ECR, Batch,
  EC2, and the chosen S3 bucket.
- Docker with `buildx` available.
- A VPC and subnet with outbound internet access. A default VPC works.
- An EC2 Spot quota of at least 8 vCPUs for G/VT instances. New accounts often
  need a quota request before the first GPU job can start.
- Python 3.10 or newer for the local submission command.

The scripts use the normal AWS CLI region resolution. On this machine that is
currently `eu-west-2`. Set `AWS_REGION` if the bucket and GPU resources should
be somewhere else.

## 1. Build and push the worker

From the repository root:

```bash
chmod +x scripts/*.sh
./scripts/build_and_push.sh dance-now-worker v1
```

The last output line is the ECR image URI. The first build is large and may take
a while because it contains CUDA, PyTorch, and Wan's dependencies.

## 2. Deploy the Batch stack

Find a VPC and suitable subnet IDs, then deploy:

```bash
./scripts/deploy_stack.sh \
  dance-now \
  YOUR_BUCKET \
  ACCOUNT.dkr.ecr.REGION.amazonaws.com/dance-now-worker:v1 \
  vpc-0123456789abcdef0 \
  subnet-0123456789abcdef0,subnet-0123456789abcdef1
```

The script prints the resulting `JobQueue` and `JobDefinition` values. The stack
uses Spot price/capacity optimization and will bid up to 70% of On-Demand. Change
the `SpotBidPercentage` parameter if jobs remain `RUNNABLE` for too long.

## 3. Install the local submitter

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
```

### Submit a local image directory

```bash
dance-now-submit \
  --input-dir ./images \
  --bucket YOUR_BUCKET \
  --prompt "The dancer moves naturally while the camera slowly pushes in" \
  --job-queue DANCE_NOW_JOB_QUEUE_ARN \
  --job-definition DANCE_NOW_JOB_DEFINITION_ARN
```

Supported image formats are JPEG, PNG, and WebP. Add `--sidecar-prompts` to use
a prompt from `photo.txt` beside `photo.jpg`; images without a sidecar retain the
default `--prompt`.

### Submit images already in S3

```bash
dance-now-submit \
  --s3-input-prefix s3://YOUR_BUCKET/dance-now/source-images/ \
  --prompt "Subtle body movement and fabric motion, locked camera" \
  --job-queue DANCE_NOW_JOB_QUEUE_ARN \
  --job-definition DANCE_NOW_JOB_DEFINITION_ARN
```

The command prints the AWS job ID and manifest URI. Outputs default to:

```text
s3://YOUR_BUCKET/dance-now/outputs/<job-name>/0000-<image-name>.mp4
s3://YOUR_BUCKET/dance-now/outputs/<job-name>/0000-<image-name>.json
```

Use `--dry-run` to upload inputs and create the manifest without submitting GPU
work. Run `dance-now-submit --help` for output-prefix, job-name, seed, and region
options.

## What you can and can't configure

Wan 2.2 TI2V-5B's pipeline only takes a start image, a text prompt, a fixed
set of resolution presets, and a frame count — so that's what's exposed:

| Setting | Configurable? | How |
| --- | --- | --- |
| Prompt (motion/camera direction) | Yes, per image | `--prompt`, or per-image via `--sidecar-prompts` (`photo.txt` beside `photo.jpg`) |
| Duration | Yes | `--seconds`. Rounded to the nearest frame count Wan supports (frames must be `4n+1`); default is 121 frames ≈ 5.04s |
| Resolution / aspect ratio | Yes, auto by default | Picked per image from Wan's 8 supported presets (`1280*704`, `704*1280`, `1280*720`, `720*1280`, `1024*704`, `704*1024`, `832*480`, `480*832`) using whichever preset's aspect ratio is closest to that image's own. Pass `--video-size` to force one preset for every image in the batch instead |
| Seed | Yes | `--seed` (base seed; each image in a batch gets `seed + index`) |
| Output format | No | Always MP4 |
| End frame / last-frame conditioning | No | Wan's TI2V-5B pipeline takes a single start image only — no last-frame argument exists in this model. Wan does have a separate first-last-frame model (FLF2V-14B), but it isn't wired into this repo (larger weights, more VRAM, different pipeline) |
| Sampling steps, guidance scale, shift, fps | No | Fixed to Wan's own TI2V-5B defaults (50 steps, 5.0 guidance, 5.0 shift, 24 fps) — not currently exposed as flags |

## Fully automated run (build → deploy → submit → wait → teardown)

Steps 1–3 above are still useful for iterating, but for a normal batch you can
run everything in one shot with `scripts/run_job.sh`. It builds/pushes the
image if needed, deploys the CloudFormation stack, submits the job, polls
until it finishes, prints the outputs (or the failure logs), and then
**deletes the stack it created** — so nothing is left running or sitting in
your account when it exits, including on Ctrl-C or a failed build.

```bash
./scripts/run_job.sh \
  --stack dance-now \
  --bucket YOUR_BUCKET \
  --vpc vpc-0123456789abcdef0 \
  --subnets subnet-0123456789abcdef0,subnet-0123456789abcdef1 \
  --input-dir ./images \
  --prompt "The dancer moves naturally while the camera slowly pushes in"
```

Requires the venv from step 3 to be active (`dance-now-submit` on `PATH`).
Run `./scripts/run_job.sh --help` for the full option list, including
`--s3-input-prefix`, `--seed`, `--seconds`, `--video-size`, `--job-name`, and
`--poll-seconds`.

On success it also downloads the resulting `.mp4`/`.json` pair from S3 into
`videos/<job-name>/` (a sibling of `images/`) so you don't have to go fetch
them yourself. By default the S3 copies (manifest, uploaded inputs, outputs)
are left in the bucket; pass `--delete-outputs` to delete just this job's
objects once the local download is confirmed — the bucket itself is never
deleted, so `--bucket` can safely point at a fixed bucket you keep around
permanently rather than a throwaway one.

By default it also deletes the ECR repository/image on exit, so a rerun
rebuilds the multi-GB CUDA image from scratch — safe, but slow. If you'll run
more jobs within the ECR image's monthly storage cost (a few cents to ~$1),
pass `--keep-image` to skip the rebuild next time; pass `--image-uri` on a
later run to reuse it without rebuilding. `--keep-stack` similarly skips
deleting the CloudFormation stack (Batch scales it to zero vCPUs between
jobs, so leaving it costs nothing but the IAM/queue bookkeeping).

## Monitor a job

```bash
aws batch describe-jobs --jobs JOB_ID
```

The AWS Batch console links each running child to its CloudWatch log stream. A
Spot interruption is retried once. On retry, the worker checks S3 and skips MP4
files that were already completed, avoiding duplicate inference.

## Cost controls

- `MinvCpus: 0` prevents an always-on GPU.
- `MaxvCpus: 8` permits only one `g5.2xlarge` at a time.
- One job handles all images sequentially and loads the model once.
- The model disk is deleted when the instance terminates.
- Existing output files are skipped during retries.

AWS Batch can take several minutes to scale an idle compute environment back to
zero. Check the EC2 console after the first test and set an AWS Budget alert. For
an initial smoke test, submit exactly one image before starting a larger batch.

## Alternatives

This project self-hosts the open Wan 2.2 TI2V-5B model on your own AWS Batch
GPU job, which keeps costs low but means you manage the infrastructure. If you
would rather use a hosted, pay-as-you-go generation service instead, some
alternatives include:

- **MiniMax H3 (768P)** — ~$0.047/sec, ~2250s video generation
- **Hailuo 2.0 / 2.3** — unlimited plans, ~3857s video generation
- **Nano Banana Pro** — 4K, unlimited
- **Nano Banana 2** — 4K, unlimited
- **Seedream 5.0 Lite** — 3K, unlimited
- **Seedream 4.5** — 4K, unlimited
- **GPT Image 1.5** — unlimited
- **Light Studio** — unlimited
- **AnyAngle** — unlimited
- **Veo 3.1** — via unlimited-plan access
- **Sora 2** — via unlimited-plan access

These are commercial, hosted offerings and pricing/limits change frequently;
check each provider's current terms before relying on them.

## Tests

The lightweight tests do not require CUDA or AWS access:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

