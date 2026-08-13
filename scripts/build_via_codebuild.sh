#!/usr/bin/env bash
# Builds and pushes the worker image entirely inside AWS via CodeBuild, then
# to Docker Hub — no local bandwidth involved beyond uploading the source
# code itself (a few hundred KB: Dockerfile, worker/, src/, pyproject.toml).
#
# Prints the pushed image pinned by digest on the last line of stdout, e.g.
#   magza477/dance-now-worker@sha256:abcd...
# Pinning by digest (not the mutable "latest" tag) means the exact,
# already-reviewed content is what gets run later, even if the tag is
# ever overwritten.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 PROJECT_NAME BUCKET [IMAGE_TAG]" >&2
  exit 2
fi

project_name="$1"
bucket_name="$2"
image_tag="${3:-latest}"
region="${AWS_REGION:-$(aws configure get region)}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "==> Packaging build source" >&2
cp "${repo_root}/Dockerfile" "$work_dir/"
cp "${repo_root}/pyproject.toml" "$work_dir/"
cp "${repo_root}/infra/buildspec.yml" "$work_dir/buildspec.yml"
cp -R "${repo_root}/worker" "$work_dir/worker"
cp -R "${repo_root}/src" "$work_dir/src"

zip_path="$work_dir/source.zip"
(cd "$work_dir" && zip -qr "$zip_path" Dockerfile pyproject.toml buildspec.yml worker src)

source_key="dance-now/codebuild-source/source.zip"
echo "==> Uploading source to s3://${bucket_name}/${source_key}" >&2
aws s3 cp "$zip_path" "s3://${bucket_name}/${source_key}" --region "$region" >&2

echo "==> Starting CodeBuild project ${project_name}" >&2
build_id="$(aws codebuild start-build \
  --project-name "$project_name" \
  --region "$region" \
  --environment-variables-override "name=IMAGE_TAG,value=${image_tag},type=PLAINTEXT" \
  --query 'build.id' --output text)"
echo "==> Build ID: ${build_id}" >&2

status=""
while true; do
  status="$(aws codebuild batch-get-builds --ids "$build_id" --region "$region" \
    --query 'builds[0].buildStatus' --output text)"
  echo "    status=${status}" >&2
  case "$status" in
    SUCCEEDED|FAILED|FAULT|TIMED_OUT|STOPPED) break ;;
  esac
  sleep 15
done

log_group="$(aws codebuild batch-get-builds --ids "$build_id" --region "$region" \
  --query 'builds[0].logs.groupName' --output text)"
log_stream="$(aws codebuild batch-get-builds --ids "$build_id" --region "$region" \
  --query 'builds[0].logs.streamName' --output text)"

if [[ "$status" != "SUCCEEDED" ]]; then
  echo "==> Build ${status}; last log lines (${log_group}/${log_stream}):" >&2
  if [[ -n "$log_group" && "$log_group" != "None" ]]; then
    aws logs get-log-events --log-group-name "$log_group" --log-stream-name "$log_stream" \
      --region "$region" --limit 100 --query 'events[].message' --output text >&2 || true
  fi
  exit 1
fi

digest_line="$(aws logs get-log-events --log-group-name "$log_group" --log-stream-name "$log_stream" \
  --region "$region" --limit 500 --query 'events[].message' --output text \
  | grep -o 'DANCE_NOW_IMAGE_DIGEST=.*' | tail -n1)"
if [[ -z "$digest_line" ]]; then
  echo "==> Build succeeded but no digest marker found in logs; check ${log_group}/${log_stream}" >&2
  exit 1
fi

# digest_line looks like: DANCE_NOW_IMAGE_DIGEST=user/repo@sha256:...
echo "${digest_line#DANCE_NOW_IMAGE_DIGEST=}"
