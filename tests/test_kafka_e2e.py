import base64
import json
import os
import time
import uuid

import boto3
import pytest

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
TOPIC_NAME = os.environ.get("KAFKA_TOPIC_NAME", "demo-topic")
COMMAND_TIMEOUT_SECONDS = 120
KAFKA_BIN = "/opt/kafka/bin"
# Installed by user data: writes a temporary SASL/SCRAM client config with the
# credential from Secrets Manager and prints its path.
CLIENT_CONFIG_HELPER = "/usr/local/bin/kafka-client-config"


@pytest.fixture(scope="session")
def instance_id():
    value = os.environ.get("KAFKA_INSTANCE_ID")
    if not value:
        pytest.skip("KAFKA_INSTANCE_ID not set - deploy the environment first")
    return value


@pytest.fixture(scope="session")
def secret_arn():
    value = os.environ.get("KAFKA_SECRET_ARN")
    if not value:
        pytest.skip("KAFKA_SECRET_ARN not set - export terraform output phase3_secret_arn")
    return value


@pytest.fixture(scope="session")
def ec2_client():
    return boto3.client("ec2", region_name=AWS_REGION)


@pytest.fixture(scope="session")
def ssm_client():
    return boto3.client("ssm", region_name=AWS_REGION)


@pytest.fixture(scope="session")
def secretsmanager_client():
    return boto3.client("secretsmanager", region_name=AWS_REGION)


def run_remote_command(ssm_client, instance_id, commands, timeout=COMMAND_TIMEOUT_SECONDS):
    response = ssm_client.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": commands},
    )
    command_id = response["Command"]["CommandId"]

    deadline = time.time() + timeout
    invocation = None
    while time.time() < deadline:
        time.sleep(2)
        try:
            invocation = ssm_client.get_command_invocation(
                CommandId=command_id, InstanceId=instance_id
            )
        except ssm_client.exceptions.InvocationDoesNotExist:
            continue
        if invocation["Status"] not in ("Pending", "InProgress", "Delayed"):
            return invocation

    raise TimeoutError(f"SSM command {command_id} did not complete within {timeout}s")


def with_client_config(script: str) -> str:
    """Prefix a broker-side script with an authenticated client config in $CFG,
    removed again when the script exits."""
    return f"""
set -euo pipefail
CFG=$({CLIENT_CONFIG_HELPER})
trap 'rm -f "$CFG"' EXIT
{script}
""".strip()


# ---------------------------------------------------------------------------
# Broker health (authenticated with the credential from Secrets Manager)
# ---------------------------------------------------------------------------


def test_ec2_instance_is_running(ec2_client, instance_id):
    response = ec2_client.describe_instance_status(
        InstanceIds=[instance_id], IncludeAllInstances=True
    )
    state = response["InstanceStatuses"][0]["InstanceState"]["Name"]
    assert state == "running", f"expected instance to be running, got '{state}'"


def test_kafka_service_is_active(ssm_client, instance_id):
    result = run_remote_command(ssm_client, instance_id, ["systemctl is-active kafka"])
    assert result["Status"] == "Success", result["StandardErrorContent"]
    assert result["StandardOutputContent"].strip() == "active"


def test_kafka_is_reachable(ssm_client, instance_id):
    command = with_client_config(
        f'{KAFKA_BIN}/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 --command-config "$CFG"'
    )
    result = run_remote_command(ssm_client, instance_id, [command])
    assert result["Status"] == "Success", result["StandardErrorContent"]


def test_kafka_topic_exists(ssm_client, instance_id):
    command = with_client_config(
        f'{KAFKA_BIN}/kafka-topics.sh --list --bootstrap-server localhost:9092 --command-config "$CFG"'
    )
    result = run_remote_command(ssm_client, instance_id, [command])
    assert result["Status"] == "Success", result["StandardErrorContent"]
    topics = result["StandardOutputContent"].split()
    assert TOPIC_NAME in topics, f"expected topic '{TOPIC_NAME}' in {topics}"


def test_producer_can_publish(ssm_client, instance_id):
    run_id = uuid.uuid4().hex[:8]
    count = 3
    command = with_client_config(
        f'for i in $(seq 1 {count}); do echo "produce-check-{run_id}-$i"; done | '
        f'{KAFKA_BIN}/kafka-console-producer.sh --bootstrap-server localhost:9092 '
        f'--producer.config "$CFG" --topic {TOPIC_NAME}'
    )
    result = run_remote_command(ssm_client, instance_id, [command])
    print(result["StandardOutputContent"])
    assert result["Status"] == "Success", result["StandardErrorContent"]


def test_end_to_end_produce_and_consume(ssm_client, instance_id):
    run_id = uuid.uuid4().hex[:8]
    count = 5
    tag = f"e2e-{run_id}"
    command = with_client_config(f"""
for i in $(seq 1 {count}); do echo "{tag}-$i"; done | {KAFKA_BIN}/kafka-console-producer.sh --bootstrap-server localhost:9092 --producer.config "$CFG" --topic {TOPIC_NAME}
RECEIVED=$({KAFKA_BIN}/kafka-console-consumer.sh --bootstrap-server localhost:9092 --consumer.config "$CFG" --topic {TOPIC_NAME} --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "{tag}-" || true)
echo "EXPECTED={count}"
echo "RECEIVED=$RECEIVED"
if [ "$RECEIVED" -eq "{count}" ]; then
  echo "SUCCESS: received $RECEIVED/{count} messages"
  exit 0
else
  echo "FAILURE: received $RECEIVED/{count} messages"
  exit 1
fi
""".strip())

    result = run_remote_command(ssm_client, instance_id, [command], timeout=90)
    print(result["StandardOutputContent"])
    assert result["Status"] == "Success", result["StandardErrorContent"]
    assert f"received {count}/{count} messages" in result["StandardOutputContent"]


# ---------------------------------------------------------------------------
# Authentication is enforced
# ---------------------------------------------------------------------------


def test_client_without_credentials_is_rejected(ssm_client, instance_id):
    # A plaintext client cannot complete the SASL handshake, so it never gets
    # metadata and gives up; `timeout` bounds the wait.
    command = f"""
OUT=$(timeout 30 {KAFKA_BIN}/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>&1) && RC=0 || RC=$?
echo "EXIT=$RC"
echo "$OUT" | grep -qx "{TOPIC_NAME}" && echo "TOPIC_VISIBLE" || echo "TOPIC_HIDDEN"
""".strip()
    result = run_remote_command(ssm_client, instance_id, [command])
    output = result["StandardOutputContent"]
    print(output)
    assert "EXIT=0" not in output, "unauthenticated client unexpectedly succeeded"
    assert "TOPIC_HIDDEN" in output, "unauthenticated client could list topics"


def test_client_with_wrong_password_is_rejected(ssm_client, instance_id):
    command = with_client_config(f"""
sed -i 's/password="[^"]*"/password="not-the-real-password"/' "$CFG"
OUT=$(timeout 60 {KAFKA_BIN}/kafka-topics.sh --bootstrap-server localhost:9092 --command-config "$CFG" --list 2>&1) && RC=0 || RC=$?
echo "EXIT=$RC"
echo "$OUT" | grep -q "Authentication failed" && echo "AUTH_FAILED" || true
""".strip())
    result = run_remote_command(ssm_client, instance_id, [command])
    output = result["StandardOutputContent"]
    print(output)
    assert "EXIT=0" not in output, "client with a wrong password unexpectedly succeeded"
    assert "AUTH_FAILED" in output, "expected a SASL authentication failure"


# ---------------------------------------------------------------------------
# The credential does not leak
# ---------------------------------------------------------------------------


def test_server_properties_is_readable_only_by_kafka(ssm_client, instance_id):
    result = run_remote_command(
        ssm_client, instance_id, ["stat -c '%a %U' /opt/kafka/config/server.properties"]
    )
    assert result["Status"] == "Success", result["StandardErrorContent"]
    assert result["StandardOutputContent"].strip() == "600 kafka"


def test_secret_not_in_provisioning_logs(ssm_client, instance_id):
    # The password is read and compared on the broker; it never leaves it.
    command = with_client_config("""
PASS=$(sed -n 's/.*password="\\([^"]*\\)".*/\\1/p' "$CFG")
[ -n "$PASS" ] || { echo "NO_PASSWORD"; exit 1; }
for f in /var/log/user-data.log /var/log/cloud-init-output.log; do
  if [ -f "$f" ] && grep -qF -- "$PASS" "$f"; then echo "LEAK:$f"; fi
done
echo "CHECKED"
""".strip())
    result = run_remote_command(ssm_client, instance_id, [command])
    output = result["StandardOutputContent"]
    assert result["Status"] == "Success", result["StandardErrorContent"]
    assert "CHECKED" in output
    assert "LEAK:" not in output, f"credential found in logs: {output}"


def test_secret_not_in_user_data(ec2_client, secretsmanager_client, instance_id, secret_arn):
    password = json.loads(
        secretsmanager_client.get_secret_value(SecretId=secret_arn)["SecretString"]
    )["password"]
    encoded = ec2_client.describe_instance_attribute(
        InstanceId=instance_id, Attribute="userData"
    )["UserData"]["Value"]
    user_data = base64.b64decode(encoded).decode("utf-8")

    assert secret_arn in user_data, "expected user data to reference the secret by ARN"
    assert password not in user_data, "credential value found in EC2 user data"
