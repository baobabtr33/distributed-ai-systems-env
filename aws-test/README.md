# aws-test — multi-GPU EC2 instance running JupyterLab

The AWS counterpart to [`../gcp-test`](../gcp-test/README.md): one `g4dn.12xlarge`
(4x NVIDIA T4) running JupyterLab, reached through an SSH tunnel. Nothing listens
publicly — the security group opens port 22 to your address alone, and Jupyter binds to
`127.0.0.1` on the instance.

Four GPUs on one node is the cheapest way to get real DDP and NCCL AllReduce numbers:
`g4dn.12xlarge` is $1.63/hr on Spot, against $1.85 for 4x L4 and $1.98 for 4x A10G. The
trade is that the **T4 is sm_75 and has no bf16**, so `bench/` and the notebook fall back
to fp16 — same tensor-core throughput on that generation, different numerics. Set
`INSTANCE_TYPE=g6.12xlarge` for 4x L4 if bf16 matters or you want to compare directly
against the L4 in `gcp-test`.

Deliberately **not** EKS. `gcp-test` uses GKE because the project targets Kubernetes, but
the question this directory answers first is narrower: can GPUs be obtained on AWS at
all, and what does AllReduce cost across four of them? A bare instance answers that in
three minutes instead of twenty, with no control-plane cost. EKS is the natural next step
if the answer is yes.

`00_gpu_smoke_test.ipynb` checks one GPU at a time — driver, PyTorch, matmul throughput.
`make bench` is the multi-GPU part: it runs `bench/ddp_allreduce.py` under `torchrun` at
world size 1 and again across all four GPUs, then prints scaling efficiency. The four T4s
sit on PCIe with no NVLink, so the AllReduce bandwidth is the interconnect ceiling those
numbers run into.

## Prerequisites

- `aws` CLI v2 (`brew install awscli`)
- Credentials: `aws configure` with an IAM access key, or `aws configure sso`
- **G-instance vCPU quota.** AWS does not meter GPUs directly; G and VT instances draw on
  a per-region vCPU quota. This is the thing to get right before anything else: the quota
  counts **vCPUs, not GPUs**, so a 1-GPU `g4dn.xlarge` needs 4 and a 4-GPU
  `g4dn.12xlarge` needs **48**. A request approved for 4 will not launch this scaffold's
  default. New accounts are often at 0 and must request an increase — the same wall as
  GCP, though AWS usually grants it in minutes to a day rather than requiring billing
  history. `make preflight` reports the quota, any pending request, and whether the
  pending value is actually large enough.

## Caveat: the Free Plan cannot launch GPU instances

**Resolved on this account as of 2026-09-07** — a `RunInstances` on `g4dn.xlarge` now
fails with `VcpuLimitExceeded` rather than the Free Tier error below, which means the
plan upgrade went through and quota is the only remaining gate. Kept here because it is
the first wall a new account hits, and the error does not name the plan as the cause.

AWS accounts created under the current free-tier model start on a **Free Plan**, which
restricts EC2 to free-tier-eligible instance types. `RunInstances` on a GPU type fails
before quota is ever consulted:

```
InvalidParameterCombination: The specified instance type is not eligible for Free Tier.
For a list of Free Tier instance types, run 'describe-instance-types' with the filter
'free-tier-eligible=true'.
```

The eligible list contains no GPU at all — `t3.micro`, `t3.small`, `t4g.micro`,
`t4g.small`, `c7i-flex.large`, `m7i-flex.large`. So this is not something a quota increase
fixes; the account must be upgraded to a paid plan first, in
**Billing and Cost Management → Account → upgrade to a paid plan**. Free-tier credits carry
over.

This is the same shape as the GCP blocker recorded in
[`../gcp-test/README.md`](../gcp-test/README.md): a new account cannot reach GPUs until
billing is upgraded. The difference is what comes after. On GCP, upgrading is necessary but
not sufficient — quota then depends on the billing account's payment history, which took a
separate account with prior invoices to satisfy. On AWS the G-instance vCPU quota is a
normal service-quota request, usually granted in minutes to a day.

Check the quota once the account is upgraded:

```bash
make preflight
```

## Caveat: the first quota request is usually denied

A `request-service-quota-increase` submitted from the CLI carries no justification text,
and on an account with no usage history AWS declines it with boilerplate:

```
I am sorry but at this time we are unable to approve your service quota increase request.

Service quotas are put in place to help you gradually ramp up activity and decrease the
likelihood of large bills due to sudden, unexpected spikes.

If you'd like to appeal this decision, please reopen this case and provide as detailed a
use case as possible.
```

This happened here on 2026-09-07 for both G/VT quotas at the minimum value of 4 vCPUs, so
it is not about the size of the ask. Two things change the answer on appeal:

1. **Usage history.** "Gradually ramp up activity" is the literal criterion. An account
   with zero EC2 hours has nothing to ramp up from. Running ordinary CPU instances for a
   few days costs cents and gives the reviewer something to point at — the CPU dry run
   below does double duty here.
2. **A written use case.** Reopen the case and state the instance type, region, count,
   expected hours per month, estimated monthly spend, and what stops it running away (a
   budget alert, scripted teardown). Ask for the minimum, not headroom.

Do not follow a denied 4-vCPU request with a 48-vCPU one. Get 4 approved, run something,
then request 48 with history behind it.

## Running the scaffold without GPU quota

Everything except the GPU works on a CPU instance type, which is worth doing while the
quota case is open — it exercises the zone selection, key pair, security group, AMI
fallback, JupyterLab install, tunnel and teardown, so the GPU run later is one command
rather than a debugging session at $1.63/hr:

```bash
INSTANCE_TYPE=c7i.large SPOT=false NAME=plumbing make up
INSTANCE_TYPE=c7i.large NAME=plumbing make jupyter
INSTANCE_TYPE=c7i.large NAME=plumbing make tunnel
NAME=plumbing make down
```

`c7i.large` draws on the Standard quota (16 vCPU on-demand here), not the G/VT one.
`01-launch.sh` warns that `nvidia-smi` is missing and continues. The notebook's CUDA cells
and `./04-bench.sh` are the only things that will not run.

## IAM permissions

The credentials need more than `sts:GetCallerIdentity`. A locked-down IAM user fails in a
confusing way: quota lookups return `AccessDenied`, which is easy to misread as "quota is
zero". `00-preflight.sh` distinguishes the two explicitly.

Quickest route — attach these AWS managed policies to the user:

- `AmazonEC2FullAccess`
- `ServiceQuotasReadOnlyAccess` (or `ServiceQuotasFullAccess` to request increases)
- `AmazonSSMReadOnlyAccess` (the Deep Learning AMI lookup)

Without the SSM policy the AMI lookup logs `SSM lookup failed, searching for a Deep
Learning AMI by name` and falls back to `describe-images`, which resolves the same image.
It is a warning, not a failure.

Spot additionally needs a **service-linked role**, `AWSServiceRoleForEC2Spot`, which AWS
creates on the account's first Spot request. If the caller cannot create it, `RunInstances`
fails with:

```
AuthFailure.ServiceLinkedRoleCreationNotPermitted: The provided credentials do not have
permission to create the service-linked role for EC2 Spot Instances.
```

Either have an administrator create the role once, or add `iam:CreateServiceLinkedRole`
scoped to that one role — included in the policy below. It is a one-time requirement: the
role persists, and later Spot launches need nothing. Running with `SPOT=false` avoids it
entirely at roughly three times the price.

Least privilege, if you would rather not grant EC2 full access — paste as an inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadEC2",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances", "ec2:DescribeInstanceTypes",
        "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeImages",
        "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
        "ec2:DescribeKeyPairs", "ec2:DescribeVolumes",
        "ec2:DescribeSpotPriceHistory", "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageScratchGpuBox",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateKeyPair", "ec2:DeleteKeyPair",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CreateSpotServiceLinkedRole",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot",
      "Condition": {
        "StringEquals": { "iam:AWSServiceName": "spot.amazonaws.com" }
      }
    },
    {
      "Sid": "AmiLookupAndQuotas",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "servicequotas:GetServiceQuota", "servicequotas:ListServiceQuotas",
        "servicequotas:RequestServiceQuotaIncrease"
      ],
      "Resource": "*"
    }
  ]
}
```

`RunInstances` is unrestricted on `Resource` here for simplicity. On a shared account,
scope it with a condition on `ec2:InstanceType` so these credentials cannot launch
something far more expensive than a `g6.xlarge`.

## Run it

```bash
aws configure          # access key, secret, region (us-east-1), output json

cd aws-test
make preflight         # quota, pending requests, four-GPU types and Spot prices
make up                # launch into the cheapest Spot zone, wait for SSH, nvidia-smi
make jupyter           # install JupyterLab, copy notebooks, start it
make tunnel            # prints http://127.0.0.1:8888/lab?token=... and holds the tunnel
```

Then run `00_gpu_smoke_test.ipynb`. For the multi-GPU numbers, from your laptop:

```bash
make bench             # 1-GPU baseline vs all-GPU DDP, prints scaling efficiency
```

When finished:

```bash
make down              # terminates the instance; asks you to type its name
```

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `REGION` | `us-east-1` | |
| `INSTANCE_TYPE` | `g4dn.12xlarge` | 4x T4, 48 vCPU of quota. `g6.12xlarge` = 4x L4, `g6e.12xlarge` = 4x L40S. Drop to `g4dn.xlarge` / `g6.xlarge` for 1 GPU and 4 vCPU, or `g6f.large` for a fractional L4 and only 2 vCPU |
| `SPOT` | `true` | `false` for on-demand, ~3x the price, no interruption |
| `NAME` | `gpu-test` | Tag value used for teardown |
| `VOLUME_SIZE` | `100` | GB, gp3, deleted with the instance |
| `LOCAL_PORT` | `8888` | Local side of the tunnel |

## Layout

```
aws-test/
  config.sh              shared vars, credential check, sourced by every script
  00-preflight.sh        vCPU quota, pending requests, four-GPU types and Spot prices
  01-launch.sh           key pair, security group, AMI lookup, cheapest-zone launch
  02-jupyter.sh          install JupyterLab, copy notebooks, start on 127.0.0.1
  03-tunnel.sh           SSH port-forward, prints the tokenised URL
  04-bench.sh            torchrun at world size 1 and N, then the scaling summary
  99-teardown.sh         terminate by tag, delete key pair and security group
  bench/                 same DDP/AllReduce benchmark as gcp-test, fp16 on pre-bf16 GPUs
  notebooks/             00_gpu_smoke_test.ipynb, adjusted for a plain instance
  .state/                instance id, public IP, Jupyter token (gitignored)
```

## Differences from `gcp-test`

| | gcp-test | aws-test |
|---|---|---|
| GPUs | 1x L4 | 4x T4 on one node (`g6.12xlarge` for 4x L4) |
| Substrate | GKE cluster, Jupyter in a pod | Plain EC2 instance |
| GPU driver | GKE installs it (`gpu-driver-version=latest`) | Baked into the Deep Learning AMI |
| Access | `kubectl port-forward` | SSH tunnel |
| Persistence | PVC survives pod restarts | EBS volume, deleted with the instance |
| Idle cost | ~$0.10/hr control plane | None — terminate and pay nothing |
| Quota gate | `GPUS_ALL_REGIONS`, billing-history dependent | G-instance vCPUs — 48 for four GPUs, usually granted on request |

## Notes

- **The Spot zone is chosen by price.** Spot rates differ enough between availability
  zones to be worth a lookup — `g6.12xlarge` was $1.85/hr in `us-east-1f` and $4.33/hr in
  `us-east-1d` on the same afternoon. `01-launch.sh` picks the cheapest zone that has a
  default subnet and pins `--subnet-id` to it, rather than letting `RunInstances` choose.
- **No bf16 on the T4.** `bench/ddp_allreduce.py` and the notebook select the autocast
  dtype from `torch.cuda.is_bf16_supported()`. Hardcoding bf16 on sm_75 measures a
  software fallback, not the GPU.
- **No NVLink on a `g4dn.12xlarge`.** `nvidia-smi topo -m` shows PHB/NODE between every
  pair, so AllReduce runs over PCIe. Expect scaling efficiency well under the number a
  NVLink node would give; that gap is the point of measuring it.
- **Spot interruption.** A Spot instance can be reclaimed with 2 minutes' notice, and
  because `SpotInstanceType` is `one-time` it terminates rather than stopping. Everything
  on the instance is lost. Set `SPOT=false` if that matters.
- **The AMI is resolved at launch**, from SSM with a name-based `describe-images` fallback,
  rather than being a hardcoded ID. AMI IDs are region-specific and change with every
  release.
- **The key pair is recreated if the local `.pem` is missing.** AWS returns the private
  half only at creation, so a key that exists in the account without the local file cannot
  be used and is not worth inheriting.
- **`.pem` files and `.state/` are gitignored.** The private key and the Jupyter token both
  live there.
- **Teardown works by tag**, not by a saved instance ID, so it still cleans up if `.state`
  is lost. EBS volumes carry `DeleteOnTermination`, so they go with the instance — verify
  with the `describe-volumes` command teardown prints.
