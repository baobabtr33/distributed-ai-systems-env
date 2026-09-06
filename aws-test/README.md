# aws-test — single GPU EC2 instance running JupyterLab

The AWS counterpart to [`../gcp-test`](../gcp-test/README.md): one `g6.xlarge` (1x NVIDIA
L4) running JupyterLab, reached through an SSH tunnel. Nothing listens publicly — the
security group opens port 22 to your address alone, and Jupyter binds to `127.0.0.1` on
the instance.

Deliberately **not** EKS. `gcp-test` uses GKE because the project targets Kubernetes, but
the question this directory answers first is narrower: can a GPU be obtained on AWS at
all, and how does the same L4 perform? A bare instance answers that in three minutes
instead of twenty, with no control-plane cost. EKS is the natural next step if the answer
is yes.

The instance type matches the GCP run on purpose. Both clouds rent the same NVIDIA L4, so
`00_gpu_smoke_test.ipynb` produces directly comparable numbers.

## Prerequisites

- `aws` CLI v2 (`brew install awscli`)
- Credentials: `aws configure` with an IAM access key, or `aws configure sso`
- **G-instance vCPU quota.** AWS does not meter GPUs directly; G and VT instances draw on
  a per-region vCPU quota, so a `g6.xlarge` needs 4 vCPUs of it. New accounts are often at
  0 and must request an increase — the same wall as GCP, though AWS usually grants it in
  minutes to a day rather than requiring billing history. `make preflight` reports it.

## IAM permissions

The credentials need more than `sts:GetCallerIdentity`. A locked-down IAM user fails in a
confusing way: quota lookups return `AccessDenied`, which is easy to misread as "quota is
zero". `00-preflight.sh` distinguishes the two explicitly.

Quickest route — attach these AWS managed policies to the user:

- `AmazonEC2FullAccess`
- `ServiceQuotasReadOnlyAccess` (or `ServiceQuotasFullAccess` to request increases)
- `AmazonSSMReadOnlyAccess` (the Deep Learning AMI lookup)

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
make preflight         # quota check + current Spot price
make up                # launch, wait for SSH, print nvidia-smi
make jupyter           # install JupyterLab, copy notebooks, start it
make tunnel            # prints http://127.0.0.1:8888/lab?token=... and holds the tunnel
```

Then run `00_gpu_smoke_test.ipynb`.

When finished:

```bash
make down              # terminates the instance; asks you to type its name
```

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `REGION` | `us-east-1` | |
| `INSTANCE_TYPE` | `g6.xlarge` | 1x L4. `g5.xlarge` = A10G, `g4dn.xlarge` = T4 (no bf16) |
| `SPOT` | `true` | `false` for on-demand, ~3x the price, no interruption |
| `NAME` | `gpu-test` | Tag value used for teardown |
| `VOLUME_SIZE` | `100` | GB, gp3, deleted with the instance |
| `LOCAL_PORT` | `8888` | Local side of the tunnel |

## Layout

```
aws-test/
  config.sh              shared vars, credential check, sourced by every script
  00-preflight.sh        G-instance vCPU quota, offered types, Spot price
  01-launch.sh           key pair, security group, AMI lookup, launch, wait for SSH
  02-jupyter.sh          install JupyterLab, copy notebooks, start on 127.0.0.1
  03-tunnel.sh           SSH port-forward, prints the tokenised URL
  99-teardown.sh         terminate by tag, delete key pair and security group
  bench/                 same DDP/AllReduce benchmark as gcp-test
  notebooks/             00_gpu_smoke_test.ipynb, adjusted for a plain instance
  .state/                instance id, public IP, Jupyter token (gitignored)
```

## Differences from `gcp-test`

| | gcp-test | aws-test |
|---|---|---|
| Substrate | GKE cluster, Jupyter in a pod | Plain EC2 instance |
| GPU driver | GKE installs it (`gpu-driver-version=latest`) | Baked into the Deep Learning AMI |
| Access | `kubectl port-forward` | SSH tunnel |
| Persistence | PVC survives pod restarts | EBS volume, deleted with the instance |
| Idle cost | ~$0.10/hr control plane | None — terminate and pay nothing |
| Quota gate | `GPUS_ALL_REGIONS`, billing-history dependent | G-instance vCPUs, usually granted on request |

## Notes

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
