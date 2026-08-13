#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ECR_REPOSITORY_NAME [IMAGE_TAG]" >&2
  exit 2
fi

repository_name="$1"
image_tag="${2:-latest}"
aws_region="${AWS_REGION:-$(aws configure get region)}"
aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
registry="${aws_account_id}.dkr.ecr.${aws_region}.amazonaws.com"
image_uri="${registry}/${repository_name}:${image_tag}"

aws ecr describe-repositories --repository-names "${repository_name}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${repository_name}" >/dev/null
aws ecr get-login-password --region "${aws_region}" \
  | docker login --username AWS --password-stdin "${registry}"
docker buildx build --platform linux/amd64 --tag "${image_uri}" --push .

echo "${image_uri}"

