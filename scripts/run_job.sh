#!/usr/bin/env bash
# Self-contained run: build the image if needed, deploy the Batch stack,
# submit one job, wait for it to finish, then tear the stack (and image)
# back down. Nothing is left running in AWS once this exits, unless
# --keep-stack or --keep-image is passed.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: run_job.sh --stack NAME --bucket BUCKET --vpc VPC_ID --subnets SUBNET_ID[,SUBNET_ID...] \
                   (--input-dir DIR | --s3-input-prefix s3://...) --prompt "TEXT" [options]

Required:
  --stack NAME                CloudFormation stack name (created and deleted by this run)
  --bucket BUCKET             S3 bucket for manifests, inputs, and outputs
  --vpc VPC_ID                VPC with outbound internet access
  --subnets SUBNET_ID,...     Comma-separated subnet IDs in that VPC
  --prompt "TEXT"             Default motion/camera prompt
  --input-dir DIR             Local image directory (mutually exclusive with --s3-input-prefix)
  --s3-input-prefix s3://...  Existing S3 prefix of images (mutually exclusive with --input-dir)

Options:
  --codebuild-project NAME    Build inside AWS via this CodeBuild project (see
                               scripts/deploy_codebuild.sh) and push to Docker Hub instead of
                               building/pushing locally through ECR. No local bandwidth used
                               for the image; the resulting image is left on Docker Hub
                               permanently (not deleted on exit) since that's the point.
  --ecr-repo NAME             ECR repository to build into locally (default: dance-now-worker;
                               ignored when --codebuild-project is set)
  --image-tag TAG             Image tag to build/push (default: latest)
  --image-uri URI             Reuse an already-built image; skips the build/push step
  --region REGION             AWS region (default: aws configure get region)
  --sidecar-prompts           Use <image-stem>.txt beside local images when present
  --seed N                    Base seed; random when omitted
  --seconds N                 Video duration in seconds (default: ~5.04s / 121 frames)
  --video-size SIZE           Force one Wan resolution preset for every image
                               (default: auto-picked from each image's own aspect ratio)
  --job-name NAME             Defaults to dance-now-<UTC timestamp>
  --poll-seconds N            Job status poll interval (default: 30)
  --keep-stack                Do not delete the CloudFormation stack afterward
  --keep-image                Do not delete the ECR repository afterward
  --delete-outputs            After the video/metadata are downloaded locally, delete this
                               job's objects from S3 (its manifest, uploaded inputs, and
                               outputs). Off by default; the bucket itself is never deleted.
  -h, --help                  Show this help
EOF
  exit 2
}

stack_name="" bucket="" vpc_id="" subnet_ids="" prompt="" input_dir="" s3_input_prefix=""
ecr_repo="dance-now-worker" image_tag="latest" image_uri="" region="${AWS_REGION:-}"
sidecar_prompts=false seed="" job_name="" poll_seconds=30 keep_stack=false keep_image=false
seconds="" video_size="" delete_outputs=false codebuild_project=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) stack_name="$2"; shift 2 ;;
    --bucket) bucket="$2"; shift 2 ;;
    --vpc) vpc_id="$2"; shift 2 ;;
    --subnets) subnet_ids="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --input-dir) input_dir="$2"; shift 2 ;;
    --s3-input-prefix) s3_input_prefix="$2"; shift 2 ;;
    --ecr-repo) ecr_repo="$2"; shift 2 ;;
    --image-tag) image_tag="$2"; shift 2 ;;
    --image-uri) image_uri="$2"; shift 2 ;;
    --region) region="$2"; shift 2 ;;
    --sidecar-prompts) sidecar_prompts=true; shift ;;
    --seed) seed="$2"; shift 2 ;;
    --seconds) seconds="$2"; shift 2 ;;
    --video-size) video_size="$2"; shift 2 ;;
    --job-name) job_name="$2"; shift 2 ;;
    --poll-seconds) poll_seconds="$2"; shift 2 ;;
    --keep-stack) keep_stack=true; shift ;;
    --keep-image) keep_image=true; shift ;;
    --delete-outputs) delete_outputs=true; shift ;;
    --codebuild-project) codebuild_project="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for required in stack_name bucket vpc_id subnet_ids prompt; do
  if [[ -z "${!required}" ]]; then
    echo "Missing --${required//_/-}" >&2
    usage
  fi
done
if [[ -z "$input_dir" && -z "$s3_input_prefix" ]]; then
  echo "One of --input-dir or --s3-input-prefix is required" >&2
  usage
fi
if [[ -n "$input_dir" && -n "$s3_input_prefix" ]]; then
  echo "--input-dir and --s3-input-prefix are mutually exclusive" >&2
  usage
fi

region="${region:-$(aws configure get region)}"
export AWS_REGION="$region"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  local exit_code="${1:-$?}"
  # Disarm first: whether we got here via the trap or an explicit call,
  # a later `exit` in this function must not re-enter cleanup and double-run
  # every deletion.
  trap - EXIT INT TERM
  # Cleanup must never abort partway through: a failed AWS call here (a
  # timeout, a transient error, describe-stacks on a stack that doesn't
  # exist) must not skip the steps after it. Disable -e for the duration.
  set +e
  echo
  if [[ "$keep_stack" == false ]]; then
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" >/dev/null 2>&1; then
      echo "==> Deleting stack ${stack_name}"
      aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"
      if ! aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region"; then
        echo "==> WARNING: stack delete-complete wait failed/timed out; check the CloudFormation console for ${stack_name}" >&2
      else
        echo "==> Stack deleted"
      fi
    fi
  else
    echo "==> --keep-stack set; leaving ${stack_name} in place"
  fi
  if [[ "$keep_image" == false && -z "$image_uri_arg_supplied" && -z "$codebuild_project" ]]; then
    if aws ecr describe-repositories --repository-names "$ecr_repo" --region "$region" >/dev/null 2>&1; then
      echo "==> Deleting ECR repository ${ecr_repo}"
      if ! aws ecr delete-repository --repository-name "$ecr_repo" --region "$region" --force >/dev/null; then
        echo "==> WARNING: failed to delete ECR repository ${ecr_repo}; check the ECR console" >&2
      fi
    fi
  elif [[ -n "$codebuild_project" ]]; then
    echo "==> Image built via CodeBuild lives on Docker Hub permanently (not deleted)"
  else
    echo "==> Leaving image/ECR repository in place"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

image_uri_arg_supplied=""
if [[ -n "$image_uri" ]]; then
  image_uri_arg_supplied=1
elif [[ -n "$codebuild_project" ]]; then
  echo "==> Building via CodeBuild project ${codebuild_project} (pushes to Docker Hub; no local upload)"
  build_log="$(mktemp)"
  if "$repo_root/scripts/build_via_codebuild.sh" "$codebuild_project" "$bucket" "$image_tag" | tee "$build_log"; then
    image_uri="$(tail -n1 "$build_log")"
    rm -f "$build_log"
  else
    echo "==> CodeBuild build failed" >&2
    rm -f "$build_log"
    cleanup 1
  fi
else
  echo "==> Building and pushing ${ecr_repo}:${image_tag}"
  build_log="$(mktemp)"
  # Explicit success check rather than `var=$(cmd | tail -1)`: piping into a
  # command substitution that feeds an assignment is a known bash rough edge
  # where a mid-pipeline failure doesn't reliably trip `set -e` (confirmed by
  # two real runs where it silently skipped cleanup). `tee` inside an `if`
  # condition avoids that ambiguity entirely while still streaming output.
  if "$repo_root/scripts/build_and_push.sh" "$ecr_repo" "$image_tag" | tee "$build_log"; then
    image_uri="$(tail -n1 "$build_log")"
    rm -f "$build_log"
  else
    echo "==> Build/push failed" >&2
    rm -f "$build_log"
    cleanup 1
  fi
fi
echo "==> Image: ${image_uri}"

echo "==> Deploying stack ${stack_name}"
aws cloudformation deploy \
  --stack-name "$stack_name" \
  --template-file "$repo_root/infra/batch.yaml" \
  --capabilities CAPABILITY_IAM \
  --region "$region" \
  --parameter-overrides \
    "BucketName=${bucket}" \
    "ContainerImage=${image_uri}" \
    "VpcId=${vpc_id}" \
    "SubnetIds=${subnet_ids}"

job_queue="$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='JobQueue'].OutputValue" --output text)"
job_definition="$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" \
  --query "Stacks[0].Outputs[?OutputKey=='JobDefinition'].OutputValue" --output text)"
echo "==> JobQueue=${job_queue} JobDefinition=${job_definition}"

submit_args=(--bucket "$bucket" --prompt "$prompt" --job-queue "$job_queue" --job-definition "$job_definition" --region "$region")
[[ -n "$input_dir" ]] && submit_args+=(--input-dir "$input_dir")
[[ -n "$s3_input_prefix" ]] && submit_args+=(--s3-input-prefix "$s3_input_prefix")
[[ "$sidecar_prompts" == true ]] && submit_args+=(--sidecar-prompts)
[[ -n "$seed" ]] && submit_args+=(--seed "$seed")
[[ -n "$job_name" ]] && submit_args+=(--job-name "$job_name")
[[ -n "$seconds" ]] && submit_args+=(--seconds "$seconds")
[[ -n "$video_size" ]] && submit_args+=(--video-size "$video_size")

echo "==> Submitting job"
submission="$(dance-now-submit "${submit_args[@]}")"
echo "$submission"
job_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <<<"$submission")"
submitted_job_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_name"])' <<<"$submission")"

echo "==> Waiting on job ${job_id} (polling every ${poll_seconds}s)"
status=""
while true; do
  status="$(aws batch describe-jobs --jobs "$job_id" --region "$region" --query 'jobs[0].status' --output text)"
  echo "    status=${status}"
  case "$status" in
    SUCCEEDED|FAILED) break ;;
  esac
  sleep "$poll_seconds"
done

if [[ "$status" == "FAILED" ]]; then
  reason="$(aws batch describe-jobs --jobs "$job_id" --region "$region" --query 'jobs[0].statusReason' --output text)"
  log_stream="$(aws batch describe-jobs --jobs "$job_id" --region "$region" --query 'jobs[0].container.logStreamName' --output text)"
  echo "==> Job FAILED: ${reason}" >&2
  if [[ -n "$log_stream" && "$log_stream" != "None" ]]; then
    echo "==> Last log lines (/aws/batch/job/${log_stream})" >&2
    aws logs get-log-events --log-group-name /aws/batch/job --log-stream-name "$log_stream" \
      --region "$region" --limit 100 --query 'events[].message' --output text >&2 || true
  fi
  exit 1
fi

echo "==> Job SUCCEEDED"
output_prefix="dance-now/outputs/${submitted_job_name}/"
echo "==> Outputs at s3://${bucket}/${output_prefix}"
aws s3api list-objects-v2 --bucket "$bucket" --prefix "$output_prefix" --region "$region" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' | sed "s|^|    s3://${bucket}/|"

local_dir="${repo_root}/videos/${submitted_job_name}"
mkdir -p "$local_dir"
echo "==> Downloading to ${local_dir}"
aws s3 cp --recursive --region "$region" "s3://${bucket}/${output_prefix}" "$local_dir/"

if [[ "$delete_outputs" == true ]]; then
  echo "==> Local copy confirmed; deleting this job's S3 objects (bucket itself is kept)"
  aws s3 rm --recursive --region "$region" "s3://${bucket}/${output_prefix}"
  aws s3 rm --recursive --region "$region" "s3://${bucket}/dance-now/jobs/${submitted_job_name}/"
else
  echo "==> S3 copies left in place (pass --delete-outputs to remove them after download)"
fi
