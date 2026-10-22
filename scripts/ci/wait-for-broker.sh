#!/usr/bin/env bash
# Starts the broker if needed and waits until SSM is online and Kafka is installed.
# Usage: wait-for-broker.sh <instance-id>
set -euo pipefail

instance_id="$1"

# Cloud Custodian stops instances nightly.
state=$(aws ec2 describe-instances --instance-ids "$instance_id" \
  --query "Reservations[0].Instances[0].State.Name" --output text)
if [ "$state" = "stopping" ]; then
  aws ec2 wait instance-stopped --instance-ids "$instance_id"
  state=stopped
fi
if [ "$state" = "stopped" ]; then
  aws ec2 start-instances --instance-ids "$instance_id" >/dev/null
fi
aws ec2 wait instance-running --instance-ids "$instance_id"

for i in $(seq 1 30); do
  ping=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query "InstanceInformationList[0].PingStatus" --output text)
  [ "$ping" = "Online" ] && break
  echo "Waiting for SSM agent ($i/30)..."
  sleep 10
done
[ "$ping" = "Online" ] || { echo "SSM agent never came online"; exit 1; }

for i in $(seq 1 30); do
  command_id=$(aws ssm send-command --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters '{"commands":["test -f /opt/kafka-ready"]}' \
    --query "Command.CommandId" --output text)
  sleep 5
  status=$(aws ssm get-command-invocation --command-id "$command_id" \
    --instance-id "$instance_id" --query Status --output text 2>/dev/null || echo Pending)
  [ "$status" = "Success" ] && { echo "Kafka is ready"; exit 0; }
  echo "Waiting for Kafka provisioning ($i/30, $status)..."
  sleep 15
done
echo "Kafka provisioning did not finish"
exit 1
