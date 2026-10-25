#!/usr/bin/env bash
# EWB VPC Peering lab - run in AWS CloudShell (same Region as your lab).
# Usage:
#   export STUDENT="YourName" MYIP="x.x.x.x"   # MYIP = your LAPTOP's public IPv4 (search "what is my ip")
#   bash ewb-vpc-peering.sh build     # pages 5-7: VPCs, subnets, IGW, routes, SGs, 3 instances
#   (SSH from laptop, capture baseline ping failure from App-A)
#   bash ewb-vpc-peering.sh peer      # pages 9-10: peering + all three peer routes
#   (capture forward/reverse ping, ssh ewb-app-b, isolation check)
#   bash ewb-vpc-peering.sh fail      # remove ICMP rule on ewb-sg-app-b (controlled failure)
#   bash ewb-vpc-peering.sh restore   # put the exact rule back
#   bash ewb-vpc-peering.sh show      # print IDs and SSH config for your report
#   bash ewb-vpc-peering.sh cleanup   # page 14 - ONLY after all evidence is saved
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_REGION:-ap-south-1}"
STUDENT="${STUDENT:-YourName}"
STATE="$HOME/ewb-state.env"
touch "$STATE"; source "$STATE"

save() { echo "$1=$2" >> "$STATE"; eval "$1=$2"; }
tag()  { aws ec2 create-tags --resources "$1" --tags "Key=Name,Value=$2" \
           "Key=Project,Value=EWB-VPC-Peering" "Key=Student,Value=$STUDENT"; }
q()    { aws ec2 "$@" --output text; }

build() {
  : "${MYIP:?Set MYIP to your laptop public IPv4 first}"
  AZ=$(q describe-availability-zones --query 'AvailabilityZones[0].ZoneName')

  # --- VPC A (page 5)
  save VPC_A $(q create-vpc --cidr-block 10.10.0.0/16 --query Vpc.VpcId); tag $VPC_A ewb-vpc-a
  save SN_APUB  $(q create-subnet --vpc-id $VPC_A --cidr-block 10.10.1.0/24 --availability-zone $AZ --query Subnet.SubnetId); tag $SN_APUB ewb-a-public
  save SN_APRIV $(q create-subnet --vpc-id $VPC_A --cidr-block 10.10.2.0/24 --availability-zone $AZ --query Subnet.SubnetId); tag $SN_APRIV ewb-a-private
  save IGW $(q create-internet-gateway --query InternetGateway.InternetGatewayId); tag $IGW ewb-igw-a
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_A
  save RT_APUB $(q create-route-table --vpc-id $VPC_A --query RouteTable.RouteTableId); tag $RT_APUB ewb-rt-a-public
  save ASSOC_APUB $(q associate-route-table --route-table-id $RT_APUB --subnet-id $SN_APUB --query AssociationId)
  aws ec2 create-route --route-table-id $RT_APUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
  save RT_APRIV $(q create-route-table --vpc-id $VPC_A --query RouteTable.RouteTableId); tag $RT_APRIV ewb-rt-a-private
  save ASSOC_APRIV $(q associate-route-table --route-table-id $RT_APRIV --subnet-id $SN_APRIV --query AssociationId)

  # --- VPC B (page 6)
  save VPC_B $(q create-vpc --cidr-block 10.20.0.0/16 --query Vpc.VpcId); tag $VPC_B ewb-vpc-b
  save SN_BPRIV $(q create-subnet --vpc-id $VPC_B --cidr-block 10.20.1.0/24 --availability-zone $AZ --query Subnet.SubnetId); tag $SN_BPRIV ewb-b-private
  save RT_BPRIV $(q create-route-table --vpc-id $VPC_B --query RouteTable.RouteTableId); tag $RT_BPRIV ewb-rt-b-private
  save ASSOC_BPRIV $(q associate-route-table --route-table-id $RT_BPRIV --subnet-id $SN_BPRIV --query AssociationId)

  # --- Security groups and inbound rules
  save SG_BASTION $(q create-security-group --group-name ewb-sg-bastion --description "EWB bastion" --vpc-id $VPC_A --query GroupId); tag $SG_BASTION ewb-sg-bastion
  save SG_APPA    $(q create-security-group --group-name ewb-sg-app-a  --description "EWB App-A"  --vpc-id $VPC_A --query GroupId); tag $SG_APPA ewb-sg-app-a
  save SG_APPB    $(q create-security-group --group-name ewb-sg-app-b  --description "EWB App-B"  --vpc-id $VPC_B --query GroupId); tag $SG_APPB ewb-sg-app-b
  ssh_rule()  { aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$2}]" >/dev/null; }
  icmp_rule() { aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=$2}]" >/dev/null; }
  ssh_rule  $SG_BASTION "$MYIP/32"
  ssh_rule  $SG_APPA 10.10.1.10/32
  icmp_rule $SG_APPA 10.20.1.10/32
  ssh_rule  $SG_APPB 10.10.1.10/32
  icmp_rule $SG_APPB 10.10.2.10/32

  # --- Key pair (private key stays out of the instances)
  if [ ! -f "$HOME/ewb-lab.pem" ]; then
    aws ec2 create-key-pair --key-name ewb-lab --query KeyMaterial --output text > "$HOME/ewb-lab.pem"
    chmod 400 "$HOME/ewb-lab.pem"
  fi

  # --- Instances (page 7)
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  launch() { # name subnet ip sg publicflag
    q run-instances --image-id $AMI --instance-type t3.micro --key-name ewb-lab \
      --network-interfaces "DeviceIndex=0,SubnetId=$2,PrivateIpAddress=$3,Groups=$4,AssociatePublicIpAddress=$5" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$1},{Key=Project,Value=EWB-VPC-Peering},{Key=Student,Value=$STUDENT}]" \
      --query 'Instances[0].InstanceId'
  }
  save I_BASTION $(launch ewb-bastion $SN_APUB  10.10.1.10 $SG_BASTION true)
  save I_APPA    $(launch ewb-app-a   $SN_APRIV 10.10.2.10 $SG_APPA false)
  save I_APPB    $(launch ewb-app-b   $SN_BPRIV 10.20.1.10 $SG_APPB false)
  echo "Waiting for status checks..."
  aws ec2 wait instance-status-ok --instance-ids $I_BASTION $I_APPA $I_APPB
  echo "Build done."; show
}

peer() {
  save PCX $(q create-vpc-peering-connection --vpc-id $VPC_A --peer-vpc-id $VPC_B --query VpcPeeringConnection.VpcPeeringConnectionId)
  tag $PCX ewb-a-b-peer
  aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids $PCX
  aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null
  sleep 10
  aws ec2 create-route --route-table-id $RT_APRIV --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 create-route --route-table-id $RT_BPRIV --destination-cidr-block 10.10.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  aws ec2 create-route --route-table-id $RT_APUB  --destination-cidr-block 10.20.0.0/16 --vpc-peering-connection-id $PCX >/dev/null
  echo "Peering active status:"; q describe-vpc-peering-connections --vpc-peering-connection-ids $PCX --query 'VpcPeeringConnections[0].Status.Code'
}

fail()    { aws ec2 revoke-security-group-ingress --group-id $SG_APPB --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]" >/dev/null; echo "ICMP rule removed from ewb-sg-app-b. Ping from App-A now."; }
restore() { aws ec2 authorize-security-group-ingress --group-id $SG_APPB --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=10.10.2.10/32}]" >/dev/null; echo "ICMP rule restored. Ping from App-A again."; }

show() {
  BIP=$(q describe-instances --instance-ids $I_BASTION --query 'Reservations[0].Instances[0].PublicIpAddress')
  echo; echo "== IDs for your report =="; cat "$STATE"
  echo; echo "== Bastion public IPv4: $BIP =="
  echo "App-A / App-B public IPs (should be None):"
  q describe-instances --instance-ids $I_APPA $I_APPB --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]'
  echo; echo "== ~/.ssh/config on your laptop =="
  for h in "ewb-bastion $BIP" "ewb-app-a 10.10.2.10" "ewb-app-b 10.20.1.10"; do
    set -- $h
    printf 'Host %s\n    HostName %s\n    User ec2-user\n    IdentityFile ~/.ssh/ewb-lab.pem\n    IdentitiesOnly yes\n' "$1" "$2"
    [ "$1" != ewb-bastion ] && printf '    ProxyJump ewb-bastion\n'
    echo
  done
  echo "Download ~/ewb-lab.pem from CloudShell (Actions > Download file) and keep it on your laptop only."
}

cleanup() {
  read -p "Have you saved ALL evidence? Type yes to delete everything: " ans; [ "$ans" = yes ] || exit 1
  aws ec2 terminate-instances --instance-ids $I_BASTION $I_APPA $I_APPB >/dev/null
  aws ec2 wait instance-terminated --instance-ids $I_BASTION $I_APPA $I_APPB
  [ -n "${PCX:-}" ] && aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null
  for a in $ASSOC_APUB $ASSOC_APRIV $ASSOC_BPRIV; do aws ec2 disassociate-route-table --association-id $a; done
  for r in $RT_APUB $RT_APRIV $RT_BPRIV; do aws ec2 delete-route-table --route-table-id $r; done
  for g in $SG_BASTION $SG_APPA $SG_APPB; do aws ec2 delete-security-group --group-id $g; done
  for s in $SN_APUB $SN_APRIV $SN_BPRIV; do aws ec2 delete-subnet --subnet-id $s; done
  aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_A
  aws ec2 delete-internet-gateway --internet-gateway-id $IGW
  aws ec2 delete-vpc --vpc-id $VPC_A; aws ec2 delete-vpc --vpc-id $VPC_B
  aws ec2 delete-key-pair --key-name ewb-lab; rm -f "$HOME/ewb-lab.pem"
  echo "Cleanup done. Verify by Project tag in EC2/VPC consoles and capture screenshots."
}

cmd="${1:?usage: build|peer|fail|restore|show|cleanup}"
case "$cmd" in
  build|peer|fail|restore|show|cleanup) "$cmd" ;;
  *) echo "usage: build|peer|fail|restore|show|cleanup"; exit 1 ;;
esac
