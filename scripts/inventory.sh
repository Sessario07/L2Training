#!/usr/bin/env bash
# Every AWS resource this environment created, read back from AWS itself
# rather than from Terraform state — so it also catches things Terraform did
# not create (the ALB, EBS volumes from PVCs) and anything orphaned.
#
#   ./scripts/inventory.sh
set -uo pipefail

REGION="${REGION:-ap-southeast-3}"
PROJECT="${PROJECT:-l2lab-sawibowo}"
ZONE_ID="${ZONE_ID:-Z0646008ZGZY2INOOAOG}"

B=$'\033[1m'; D=$'\033[2m'; O=$'\033[0m'
q() { aws "$@" 2>/dev/null; }
hdr() { printf "\n${B}%s${O}\n" "$1"; }

printf "\n${B}AWS inventory — %s (%s)${O}\n" "$PROJECT" "$REGION"
printf "${D}%s${O}\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

hdr "Networking"
q ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Vpcs[].[VpcId,CidrBlock]' --output text | sed 's/^/  VPC          /'
q ec2 describe-subnets --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' --output text | sed 's/^/  subnet       /'
q ec2 describe-nat-gateways --region "$REGION" --filter "Name=tag:Project,Values=$PROJECT" \
  --query 'NatGateways[?State==`available`].[NatGatewayId,State]' --output text | sed 's/^/  NAT          /'
q ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'InternetGateways[].InternetGatewayId' --output text | sed 's/^/  IGW          /'
q ec2 describe-addresses --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Addresses[].[AllocationId,PublicIp]' --output text | sed 's/^/  EIP          /'

hdr "Compute"
q eks describe-cluster --region "$REGION" --name "$PROJECT" \
  --query 'cluster.[name,version,status,platformVersion]' --output text | sed 's/^/  EKS          /'
q eks describe-nodegroup --region "$REGION" --cluster-name "$PROJECT" \
  --nodegroup-name "$PROJECT-ng" \
  --query 'nodegroup.[nodegroupName,status,capacityType,scalingConfig.desiredSize]' \
  --output text | sed 's/^/  nodegroup    /'
q ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone,InstanceLifecycle]' \
  --output text | sed 's/^/  instance     /'

hdr "Load balancing"
for arn in $(q elbv2 describe-load-balancers --region "$REGION" \
      --query 'LoadBalancers[].LoadBalancerArn' --output text); do
  tags=$(q elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
      --query "TagDescriptions[0].Tags[?Key=='Project'].Value" --output text)
  [ "$tags" = "$PROJECT" ] || continue
  q elbv2 describe-load-balancers --region "$REGION" --load-balancer-arns "$arn" \
    --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code,DNSName]' --output text \
    | sed 's/^/  ALB          /'
done
# Filter to OUR target groups only. This account is shared with ~30 other
# learners, so an unfiltered listing is mostly other people's resources.
for tg in $(q elbv2 describe-target-groups --region "$REGION" \
      --query "TargetGroups[?starts_with(TargetGroupName,'k8s-l2lab') || starts_with(TargetGroupName,'k8s-observab')].TargetGroupArn" \
      --output text); do
  name=$(q elbv2 describe-target-groups --region "$REGION" --target-group-arns "$tg" \
      --query 'TargetGroups[0].[TargetGroupName,Protocol,Port]' --output text)
  health=$(q elbv2 describe-target-health --region "$REGION" --target-group-arn "$tg" \
      --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  printf "  target grp   %s\t%s\n" "$name" "${health:-no targets}"
done

hdr "Storage"
q ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query 'Volumes[].[VolumeId,Size,VolumeType,State]' --output text | sed 's/^/  EBS          /'
# MUST filter by our Project tag as well. Filtering only on the PVC tag lists
# every learner's volumes in this shared account, which is both noise and a
# way to mistake someone else's disk for one of ours.
q ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:kubernetes.io/created-for/pvc/name,Values=*" \
  --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text | sed 's/^/  EBS (PVC)    /'
q s3api list-buckets --query "Buckets[?starts_with(Name,'$PROJECT')].Name" --output text \
  | tr '\t' '\n' | sed 's/^/  S3           /'
q ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName,'$PROJECT')].[repositoryName,imageTagMutability]" \
  --output text | sed 's/^/  ECR          /'

hdr "Security and identity"
q iam list-roles --query "Roles[?starts_with(RoleName,'$PROJECT')].RoleName" --output text \
  | tr '\t' '\n' | sed 's/^/  IAM role     /'
q secretsmanager list-secrets --region "$REGION" \
  --query "SecretList[?starts_with(Name,'$PROJECT')].Name" --output text \
  | tr '\t' '\n' | sed 's/^/  secret       /'
q kms list-aliases --region "$REGION" \
  --query "Aliases[?starts_with(AliasName,'alias/$PROJECT')].AliasName" --output text \
  | tr '\t' '\n' | sed 's/^/  KMS          /'
q acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?contains(DomainName,'sawibowo')].[DomainName,Status]" \
  --output text | sed 's/^/  ACM          /'

hdr "DNS"
q route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?contains(Name,'sawibowo.sandbox')].[Name,Type]" \
  --output text | sed 's/^/  record       /'

hdr "Running cost (billed while up)"
cat <<'COST'
  EKS control plane                    $0.100/hr   fixed, cannot be paused
  2 x t4g.large spot                   $0.054/hr   ~70% off on-demand
  NAT Gateway                          $0.045/hr   one, not one per AZ
  ALB                                  $0.023/hr   one, shared by 3 ingresses
  EBS gp3 (~97 GiB: 2 root + 6 PVC)    $0.013/hr
  KMS key + 2 secrets                  $0.002/hr
  ------------------------------------------------
  TOTAL                                ~$0.237/hr  = $5.69/day
COST
printf "\n  %s\n\n" "$(date -u '+$15 budget is reached after ~63 hours of runtime')"
