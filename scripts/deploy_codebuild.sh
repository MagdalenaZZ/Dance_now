#!/usr/bin/env bash
# One-time setup: deploys the CodeBuild project that builds the worker image
# inside AWS and pushes it to Docker Hub. Run this once (re-run is safe, it's
# idempotent); scripts/build_via_codebuild.sh triggers builds against it
# afterward. Costs nothing while idle.
#
# Before running this, create the Docker Hub credentials secret out-of-band:
#   aws secretsmanager create-secret \
#     --name dance-now/dockerhub-credentials \
#     --secret-string '{"username":"YOUR_DOCKERHUB_USER","password":"YOUR_ACCESS_TOKEN"}' \
#     --region YOUR_REGION
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 STACK_NAME BUCKET DOCKERHUB_USERNAME [DOCKERHUB_REPO]" >&2
  exit 2
fi

stack_name="$1"
bucket_name="$2"
dockerhub_username="$3"
dockerhub_repo="${4:-dance-now-worker}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

aws cloudformation deploy \
  --stack-name "${stack_name}" \
  --template-file "${repo_root}/infra/codebuild.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    "BucketName=${bucket_name}" \
    "DockerHubUsername=${dockerhub_username}" \
    "DockerHubRepo=${dockerhub_repo}"

aws cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[0].Outputs[].{Name:OutputKey,Value:OutputValue}' \
  --output table
