#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 STACK_NAME BUCKET IMAGE_URI VPC_ID SUBNET_ID[,SUBNET_ID...]" >&2
  exit 2
fi

stack_name="$1"
bucket_name="$2"
image_uri="$3"
vpc_id="$4"
subnet_ids="$5"

aws cloudformation deploy \
  --stack-name "${stack_name}" \
  --template-file infra/batch.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    "BucketName=${bucket_name}" \
    "ContainerImage=${image_uri}" \
    "VpcId=${vpc_id}" \
    "SubnetIds=${subnet_ids}"

aws cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[0].Outputs[].{Name:OutputKey,Value:OutputValue}' \
  --output table

