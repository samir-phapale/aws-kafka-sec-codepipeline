#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

KAFKA_VERSION="${kafka_version}"
SCALA_VERSION="${scala_version}"
TOPIC_NAME="${topic_name}"
TOPIC_PARTITIONS="${topic_partitions}"
TOPIC_REPLICATION_FACTOR="${topic_replication_factor}"

# Only the secret's ARN is passed in user data, never its value: user data is
# readable by anyone who can describe the instance.
# Secret version ${secret_version_id} - a new credential replaces this broker,
# so it is always formatted with the current one.
SECRET_ARN="${kafka_secret_arn}"
SECRET_REGION="${secret_region}"

echo "=== Installing Java and prerequisites ==="
dnf install -y java-17-amazon-corretto-headless wget tar nc jq

echo "=== Creating kafka service account ==="
id -u kafka &>/dev/null || useradd -m -s /sbin/nologin kafka

echo "=== Downloading Kafka $${KAFKA_VERSION} (Scala $${SCALA_VERSION}) ==="
KAFKA_DIST="kafka_$${SCALA_VERSION}-$${KAFKA_VERSION}"
cd /opt
wget -q "https://dlcdn.apache.org/kafka/$${KAFKA_VERSION}/$${KAFKA_DIST}.tgz" -O /opt/kafka.tgz
tar -xzf /opt/kafka.tgz -C /opt
rm -f /opt/kafka.tgz
ln -sfn "/opt/$${KAFKA_DIST}" /opt/kafka

mkdir -p /var/lib/kafka/data
chown -R kafka:kafka "/opt/$${KAFKA_DIST}" /var/lib/kafka

echo "=== Installing kafka-client-config helper ==="
# Clients get the credential the same way the broker does: from Secrets
# Manager via the instance role, at the moment they need it.
cat > /usr/local/bin/kafka-client-config <<'HELPER'
#!/bin/bash
# Writes a temporary Kafka client config (mode 600) carrying the SASL/SCRAM
# credential from Secrets Manager and prints its path. Delete it when done:
#   CFG=$(kafka-client-config)
#   /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --command-config "$CFG" --list
#   rm -f "$CFG"
set -euo pipefail
SECRET_JSON=$(aws secretsmanager get-secret-value --region "${secret_region}" --secret-id "${kafka_secret_arn}" --query SecretString --output text)
CFG=$(mktemp /tmp/kafka-client-XXXXXX)
cat > "$CFG" <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$(jq -r .username <<<"$SECRET_JSON")" password="$(jq -r .password <<<"$SECRET_JSON")";
EOF
echo "$CFG"
HELPER
chmod 755 /usr/local/bin/kafka-client-config

echo "=== Reading the Kafka credential from Secrets Manager ==="
# Command tracing stays off while the credential is in use so it never
# reaches /var/log/user-data.log or the EC2 console output.
set +x
SECRET_JSON=""
for i in $(seq 1 30); do
  if SECRET_JSON=$(aws secretsmanager get-secret-value --region "$SECRET_REGION" --secret-id "$SECRET_ARN" --query SecretString --output text 2>/dev/null); then
    break
  fi
  echo "Secret not readable yet (attempt $i/30) - waiting for IAM permissions to propagate"
  sleep 10
done
if [ -z "$SECRET_JSON" ]; then
  echo "ERROR: could not read the Kafka secret from Secrets Manager"
  exit 1
fi
KAFKA_USER=$(jq -r .username <<<"$SECRET_JSON")
KAFKA_PASS=$(jq -r .password <<<"$SECRET_JSON")
unset SECRET_JSON
echo "Credential for user '$KAFKA_USER' read from Secrets Manager"

echo "=== Configuring Kafka (KRaft mode, single node, SASL/SCRAM) ==="
# IMDSv2 is enforced (http_tokens = "required"), so fetch a session token first.
IMDS_TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4)
# Run as kafka so the /opt/kafka/logs dir that kafka-run-class.sh creates is owned by kafka, not root.
CLUSTER_ID=$(sudo -u kafka /opt/kafka/bin/kafka-storage.sh random-uuid)

# server.properties holds the broker's own login (needed for inter-broker
# authentication), so only the kafka user may read it.
install -m 600 -o kafka -g kafka /dev/null /opt/kafka/config/server.properties
cat > /opt/kafka/config/server.properties <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.bootstrap.servers=$${PRIVATE_IP}:9093
listeners=SASL_PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
inter.broker.listener.name=SASL_PLAINTEXT
advertised.listeners=SASL_PLAINTEXT://$${PRIVATE_IP}:9092
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
listener.name.sasl_plaintext.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$${KAFKA_USER}" password="$${KAFKA_PASS}";
log.dirs=/var/lib/kafka/data
num.partitions=$${TOPIC_PARTITIONS}
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1
group.initial.rebalance.delay.ms=0
EOF

# --add-scram stores the SCRAM credential (salted hash) in the cluster
# metadata at format time, so the user exists before the broker first starts.
sudo -u kafka /opt/kafka/bin/kafka-storage.sh format --standalone -t "$${CLUSTER_ID}" \
  -c /opt/kafka/config/server.properties \
  --add-scram "SCRAM-SHA-512=[name=$${KAFKA_USER},password=$${KAFKA_PASS}]"
unset KAFKA_USER KAFKA_PASS
set -x

echo "=== Installing systemd unit ==="
cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka (KRaft mode)
After=network.target

[Service]
Type=simple
User=kafka
Environment=JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka
systemctl start kafka

echo "=== Waiting for Kafka to become ready ==="
# Every client call below authenticates with the credential from Secrets Manager.
CLIENT_CONFIG=$(/usr/local/bin/kafka-client-config)
trap 'rm -f "$${CLIENT_CONFIG}"' EXIT
chown kafka:kafka "$${CLIENT_CONFIG}"

READY=0
for i in $(seq 1 30); do
  if /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 --command-config "$${CLIENT_CONFIG}" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [ "$${READY}" -ne 1 ]; then
  echo "ERROR: Kafka did not become ready in time"
  exit 1
fi

echo "=== Creating topic '$${TOPIC_NAME}' ==="
sudo -u kafka /opt/kafka/bin/kafka-topics.sh --create --if-not-exists \
  --topic "$${TOPIC_NAME}" \
  --bootstrap-server localhost:9092 \
  --command-config "$${CLIENT_CONFIG}" \
  --partitions "$${TOPIC_PARTITIONS}" \
  --replication-factor "$${TOPIC_REPLICATION_FACTOR}"

echo "USER_DATA_COMPLETE" > /opt/kafka-ready
echo "=== Provisioning complete ==="
