#!/usr/bin/env bash
# Remote-region datastore for MaaS: one EC2 VM (own VPC) in another AWS region
# running Redis 7 (TLS, password, AOF, io-threads) for Limitador and
# PostgreSQL 16 (TLS, password) for maas-api. Ports 6379/5432 are open only to
# the MaaS cluster's NAT gateway IPs; SSH only to the caller's public IP.
# Runs locally with the AWS CLI (no oc needed).
#
#   bash local/remote-datastore-ec2.sh                       # up
#   DS_ACTION=status bash local/remote-datastore-ec2.sh
#   DS_INSTANCE_TYPE=m5.4xlarge REDIS_CPUS=8 PG_CPUS=8 bash local/remote-datastore-ec2.sh   # resize + pin cores
#   DS_ACTION=down   bash local/remote-datastore-ec2.sh      # delete VM + VPC
#
# Writes REDIS_URL / PG_URL to harness/state/remote-datastore.env (also
# REDIS_URL to remote-redis.env, read by remote/scenario31-limitador-redis-switch.sh).
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-ocp-sandbox15}"
DS_ACTION="${DS_ACTION:-up}"
DS_REGION="${DS_REGION:-us-east-2}"
MAAS_REGION="${MAAS_REGION:-us-east-1}"
DS_NAME="${DS_NAME:-maas-remote-datastore}"
DS_INSTANCE_TYPE="${DS_INSTANCE_TYPE:-m5.xlarge}"     # 4 vCPU: Redis io-threads 4 (scenario 31-B conclusion 7)
DS_VPC_CIDR="${DS_VPC_CIDR:-10.200.0.0/16}"
DS_SUBNET_CIDR="${DS_SUBNET_CIDR:-10.200.1.0/24}"
DS_DISK_GB="${DS_DISK_GB:-30}"
REDIS_IMAGE="${REDIS_IMAGE:-docker.io/library/redis:7.2}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:16}"
REDIS_IO_THREADS="${REDIS_IO_THREADS:-4}"
REDIS_CPUS="${REDIS_CPUS:-}"   # dedicated cores (cpuset 0..N-1); empty = shared
PG_CPUS="${PG_CPUS:-}"         # dedicated cores after Redis's
PG_DB="${PG_DB:-maas}"
PG_USER="${PG_USER:-maas}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/myocp-bastion}"
STATE_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state}"
STATE_FILE="${STATE_DIR}/remote-datastore.env"

ec2() { aws ec2 --region "$DS_REGION" "$@"; }
tagged() { ec2 "$1" --filters "Name=tag:Name,Values=${DS_NAME}" --query "$2" --output text; }
none() { [ -z "$1" ] || [ "$1" = None ]; }

instance_id() { ec2 describe-instances --filters "Name=tag:Name,Values=${DS_NAME}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text; }

if [ "$DS_ACTION" = status ]; then
  ec2 describe-instances --filters "Name=tag:Name,Values=${DS_NAME}" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress]' --output table
  exit 0
fi

if [ "$DS_ACTION" = down ]; then
  iid=$(instance_id)
  if ! none "$iid"; then ec2 terminate-instances --instance-ids $iid >/dev/null; ec2 wait instance-terminated --instance-ids $iid; echo "terminated $iid"; fi
  vpc=$(tagged describe-vpcs 'Vpcs[0].VpcId')
  if ! none "$vpc"; then
    for sg in $(ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do ec2 delete-security-group --group-id "$sg"; done
    for sn in $(ec2 describe-subnets --filters Name=vpc-id,Values="$vpc" --query 'Subnets[].SubnetId' --output text); do ec2 delete-subnet --subnet-id "$sn"; done
    for rt in $(ec2 describe-route-tables --filters Name=vpc-id,Values="$vpc" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do ec2 delete-route-table --route-table-id "$rt"; done
    for igw in $(ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
      ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"; ec2 delete-internet-gateway --internet-gateway-id "$igw"; done
    ec2 delete-vpc --vpc-id "$vpc"; echo "deleted $vpc"
  fi
  eip=$(tagged describe-addresses 'Addresses[0].AllocationId')
  if ! none "$eip"; then ec2 release-address --allocation-id "$eip"; echo "released $eip"; fi
  ec2 delete-key-pair --key-name "$DS_NAME" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
  exit 0
fi

# ---- up -------------------------------------------------------------------
ALLOWED_CIDRS="${ALLOWED_CIDRS:-$(aws ec2 --region "$MAAS_REGION" describe-nat-gateways --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp' --output text | tr '\t' '\n' | sed 's#$#/32#' | paste -sd, -)}"
[ -n "$ALLOWED_CIDRS" ] || { echo "no NAT gateway IPs in ${MAAS_REGION}; set ALLOWED_CIDRS"; exit 1; }
SSH_CIDR="${SSH_CIDR:-$(curl -s https://checkip.amazonaws.com)/32}"
echo "== region ${DS_REGION}, allowed (6379/5432): ${ALLOWED_CIDRS}, ssh: ${SSH_CIDR}"

echo "== 1) VPC / subnet / internet gateway"
vpc=$(tagged describe-vpcs 'Vpcs[0].VpcId')
if none "$vpc"; then
  vpc=$(ec2 create-vpc --cidr-block "$DS_VPC_CIDR" --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${DS_NAME}}]" --query Vpc.VpcId --output text)
  ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames
  igw=$(ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${DS_NAME}}]" --query InternetGateway.InternetGatewayId --output text)
  ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
  az=$(ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
  subnet=$(ec2 create-subnet --vpc-id "$vpc" --cidr-block "$DS_SUBNET_CIDR" --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${DS_NAME}}]" --query Subnet.SubnetId --output text)
  ec2 modify-subnet-attribute --subnet-id "$subnet" --map-public-ip-on-launch
  rt=$(ec2 create-route-table --vpc-id "$vpc" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${DS_NAME}}]" --query RouteTable.RouteTableId --output text)
  ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
  ec2 associate-route-table --route-table-id "$rt" --subnet-id "$subnet" >/dev/null
fi
subnet=$(tagged describe-subnets 'Subnets[0].SubnetId')
echo "vpc ${vpc}, subnet ${subnet}"

echo "== 2) security group"
sg=$(ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" Name=group-name,Values="$DS_NAME" --query 'SecurityGroups[0].GroupId' --output text)
if none "$sg"; then
  sg=$(ec2 create-security-group --vpc-id "$vpc" --group-name "$DS_NAME" --description "MaaS remote datastore" --query GroupId --output text)
fi
perms="[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"${SSH_CIDR}\"}]}"
for port in 6379 5432; do
  ranges=$(echo "$ALLOWED_CIDRS" | tr ',' '\n' | sed 's#.*#{"CidrIp":"&"}#' | paste -sd, -)
  perms="${perms},{\"IpProtocol\":\"tcp\",\"FromPort\":${port},\"ToPort\":${port},\"IpRanges\":[${ranges}]}"
done
ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions "${perms}]" >/dev/null 2>&1 || true   # duplicates ignored

echo "== 3) key pair / passwords"
ec2 describe-key-pairs --key-names "$DS_NAME" >/dev/null 2>&1 || \
  ec2 import-key-pair --key-name "$DS_NAME" --public-key-material "fileb://$(cygpath -m "${SSH_KEY_PATH}.pub" 2>/dev/null || echo "${SSH_KEY_PATH}.pub")" >/dev/null
mkdir -p "$STATE_DIR"
REDIS_PASSWORD=$(grep -s '^REDIS_PASSWORD=' "$STATE_FILE" | cut -d= -f2- || true); REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -hex 24)}"
PG_PASSWORD=$(grep -s '^PG_PASSWORD=' "$STATE_FILE" | cut -d= -f2- || true); PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 24)}"

echo "== 4) instance (${DS_INSTANCE_TYPE})"
iid=$(instance_id)
if none "$iid"; then
  ami=$(MSYS_NO_PATHCONV=1 aws ssm get-parameter --region "$DS_REGION" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  userdata=$(cat <<EOF
#!/bin/bash
set -eux
dnf install -y docker openssl
systemctl enable --now docker
mkdir -p /opt/ds/tls /opt/ds/redis /opt/ds/pg
cd /opt/ds/tls
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=${DS_NAME}" -keyout tls.key -out tls.crt
chown 999:999 tls.key tls.crt /opt/ds/redis; chmod 600 tls.key
docker run -d --name redis --restart always --network host -v /opt/ds/tls:/tls:ro -v /opt/ds/redis:/data ${REDIS_IMAGE} \
  redis-server --port 0 --tls-port 6379 --tls-cert-file /tls/tls.crt --tls-key-file /tls/tls.key --tls-auth-clients no \
  --requirepass ${REDIS_PASSWORD} --appendonly yes --appendfsync everysec --maxmemory-policy noeviction \
  --io-threads ${REDIS_IO_THREADS} --io-threads-do-reads yes
docker run -d --name postgres --restart always --network host -v /opt/ds/tls:/tls:ro -v /opt/ds/pg:/var/lib/postgresql/data \
  -e POSTGRES_DB=${PG_DB} -e POSTGRES_USER=${PG_USER} -e POSTGRES_PASSWORD=${PG_PASSWORD} ${PG_IMAGE} \
  -c ssl=on -c ssl_cert_file=/tls/tls.crt -c ssl_key_file=/tls/tls.key
EOF
)
  iid=$(ec2 run-instances --image-id "$ami" --instance-type "$DS_INSTANCE_TYPE" --key-name "$DS_NAME" \
    --subnet-id "$subnet" --security-group-ids "$sg" --user-data "$userdata" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${DS_DISK_GB},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${DS_NAME}}]" --query 'Instances[0].InstanceId' --output text)
else
  cur=$(ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].InstanceType' --output text)
  if [ "$cur" != "$DS_INSTANCE_TYPE" ]; then
    echo "resize ${cur} -> ${DS_INSTANCE_TYPE} (stop/start; containers restart automatically)"
    ec2 stop-instances --instance-ids "$iid" >/dev/null; ec2 wait instance-stopped --instance-ids "$iid"
    ec2 modify-instance-attribute --instance-id "$iid" --instance-type "{\"Value\":\"${DS_INSTANCE_TYPE}\"}"
    ec2 start-instances --instance-ids "$iid" >/dev/null
  fi
fi
ec2 wait instance-running --instance-ids "$iid"

# Elastic IP: the address survives stop/start (resize), so the URLs in MaaS stay valid
eip=$(tagged describe-addresses 'Addresses[0].AllocationId')
if none "$eip"; then
  eip=$(ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${DS_NAME}}]" --query AllocationId --output text)
fi
ec2 associate-address --allocation-id "$eip" --instance-id "$iid" --allow-reassociation >/dev/null
ip=$(ec2 describe-addresses --allocation-ids "$eip" --query 'Addresses[0].PublicIp' --output text)
echo "instance ${iid}, Elastic IP ${ip}"

echo "== 5) wait for containers"
for _ in $(seq 1 60); do
  out=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "ec2-user@${ip}" \
    "sudo docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null" 2>/dev/null || true)
  echo "$out" | grep -q '^redis Up' && echo "$out" | grep -q '^postgres Up' && break
  sleep 10
done
echo "$out"
if [ -n "$REDIS_CPUS" ] || [ -n "$PG_CPUS" ]; then
  r=${REDIS_CPUS:-0}; p=${PG_CPUS:-0}
  cmd=""
  [ "$r" -gt 0 ] && cmd+="sudo docker update --cpuset-cpus 0-$((r - 1)) redis >/dev/null; "
  [ "$p" -gt 0 ] && cmd+="sudo docker update --cpuset-cpus ${r}-$((r + p - 1)) postgres >/dev/null; "
  echo "== cpu: redis ${r} cores, postgres ${p} cores (nproc $(ssh -i "$SSH_KEY_PATH" "ec2-user@${ip}" nproc))"
  ssh -i "$SSH_KEY_PATH" "ec2-user@${ip}" "${cmd} sudo docker inspect -f '{{.Name}} cpuset={{.HostConfig.CpusetCpus}}' redis postgres"
fi
ssh -i "$SSH_KEY_PATH" "ec2-user@${ip}" "sudo docker exec redis redis-cli --tls --insecure -a '${REDIS_PASSWORD}' --no-auth-warning PING; \
  sudo docker exec postgres pg_isready -U ${PG_USER} -d ${PG_DB}"

cat > "$STATE_FILE" <<EOF
DS_REGION=${DS_REGION}
DS_INSTANCE_ID=${iid}
DS_HOST=${ip}
REDIS_PASSWORD=${REDIS_PASSWORD}
PG_PASSWORD=${PG_PASSWORD}
REDIS_URL=rediss://default:${REDIS_PASSWORD}@${ip}:6379#insecure
PG_URL=postgresql://${PG_USER}:${PG_PASSWORD}@${ip}:5432/${PG_DB}?sslmode=require
EOF
printf 'REDIS_HOST=%s\nREDIS_PASSWORD=%s\nREDIS_URL=rediss://default:%s@%s:6379#insecure\n' "$ip" "$REDIS_PASSWORD" "$REDIS_PASSWORD" "$ip" \
  > "${STATE_DIR}/remote-redis.env"
echo "written ${STATE_FILE}"
