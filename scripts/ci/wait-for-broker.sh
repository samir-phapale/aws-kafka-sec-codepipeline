#!/usr/bin/env bash
# Makes sure the Kafka broker is running, reachable over SSM and finished
# provisioning before the end-to-end tests run.
#   wait-for-broker.sh <instance-id>
set -euo pipefail

INSTANCE_ID="${1:?usage: wait-for-broker.sh <instance-id>}"

# Cloud Custodian stops instances nightly, so the broker may be stopped.
STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].State.Name" --output text)
echo "Broker state: $STATE"
if [ "$STATE" = "stopping" ]; then
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
  STATE=stopped
fi
if [ "$STATE" = "stopped" ]; then
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

STATUS=""
for i in $(seq 1 30); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query "InstanceInformationList[0].PingStatus" --output text)
  if [ "$STATUS" = "Online" ]; then
    echo "SSM agent online"
    break
  fi
  echo "Waiting for SSM agent (attempt $i/30)..."
  sleep 10
done
if [ "$STATUS" != "Online" ]; then
  echo "SSM agent never came online"
  exit 1
fi

STATUS=""
for i in $(seq 1 30); do
  COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters '{"commands":["test -f /opt/kafka-ready"]}' \
    --query "Command.CommandId" --output text)
  sleep 5
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  if [ "$STATUS" = "Success" ]; then
    echo "Kafka provisioning complete (/opt/kafka-ready found)"
    exit 0
  fi
  echo "Waiting for Kafka provisioning to finish (attempt $i/30, status=$STATUS)..."
  sleep 15
done
echo "Kafka provisioning did not finish (/opt/kafka-ready not found)"
exit 1
