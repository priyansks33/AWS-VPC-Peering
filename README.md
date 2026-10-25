# AWS VPC Peering Project

Hands-on project demonstrating private connectivity between two Amazon VPCs using **VPC Peering**, built and documented by **Priyan** as part of the EWB program.

## Overview

VPC peering lets resources in two separate VPCs communicate using private IP addresses, as if they were on the same network, without going over the public internet, a VPN, or a gateway. This project sets up two VPCs, peers them, configures routing and security, and verifies connectivity between instances in each VPC.

## Architecture

```
   VPC-A (10.0.0.0/16)                    VPC-B (10.1.0.0/16)
 ┌─────────────────────┐                ┌─────────────────────┐
 │  Public subnet      │                │  Public subnet      │
 │  EC2 instance A     │◄──────────────►│  EC2 instance B     │
 │  (10.0.x.x)         │  VPC Peering   │  (10.1.x.x)         │
 └─────────────────────┘   Connection   └─────────────────────┘
```

## What Was Built

- Two VPCs with non-overlapping CIDR blocks
- A subnet in each VPC
- An Internet Gateway and route for SSH access to test instances
- An EC2 instance in each VPC
- A VPC peering connection (requested and accepted)
- Route table entries in both VPCs pointing the other VPC's CIDR at the peering connection
- Security group rules allowing traffic (ICMP/SSH) from the peer VPC's CIDR

## Repository Contents

| File | Description |
|------|-------------|
| `Priyan_EWB_VPC_Peering.pdf` | Full project report: steps, screenshots, results, and learnings |
| `ewb-vpc-peering.sh` | Shell script (AWS CLI) that builds the environment |
| `README.md` | This file |

## Prerequisites

- An AWS account with permissions for EC2 and VPC
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed and configured (`aws configure`)
- A bash-compatible shell (Linux, macOS, WSL, or AWS CloudShell)
- An existing EC2 key pair if the script launches instances you will SSH into

## Usage

```bash
# 1. Clone the repository
git clone https://github.com/<your-username>/AWS-VPC-Peering.git
cd AWS-VPC-Peering

# 2. Review the variables at the top of the script (region, CIDRs, key pair name)
nano ewb-vpc-peering.sh

# 3. Make it executable and run
chmod +x ewb-vpc-peering.sh
./ewb-vpc-peering.sh
```

## Verifying the Peering

1. SSH into the instance in VPC-A.
2. Ping the **private IP** of the instance in VPC-B:
   ```bash
   ping <private-ip-of-instance-B>
   ```
3. Successful replies confirm that traffic is flowing over the peering connection.
4. Repeat in the opposite direction (B to A).

## Key Concepts Learned

- Peering is **non-transitive**: if A peers with B and B peers with C, A cannot reach C through B.
- CIDR blocks of peered VPCs **cannot overlap**.
- Peering alone is not enough: **route tables** and **security groups** on both sides must allow the traffic.
- Peering requires a request from one VPC and an acceptance from the other.

## Cleanup

To avoid ongoing charges, delete the resources when finished:

1. Terminate the EC2 instances
2. Delete the peering connection
3. Delete route table entries, subnets, route tables, and Internet Gateways
4. Delete the VPCs

## Author

**Priyan**
EWB Program: AWS VPC Peering Project

## License

This project is for educational purposes.
