#!/usr/bin/env python3
"""Render jupyter.yaml for a given per-pod GPU count.

Reads the manifest on stdin, writes it on stdout with the Jupyter pod's GPU
request set to --gpus. The manifest on disk stays the single source of truth for
everything else, so the CPU, single-GPU and multi-GPU paths cannot drift apart.

  --gpus 0   no accelerator: drop the nvidia.com/gpu resource and the GPU node
             toleration, and lower the memory limit to fit a small CPU machine
  --gpus N   request and limit N GPUs (they must match; GPUs are not oversubscribable)
"""
import argparse
import sys

import yaml

parser = argparse.ArgumentParser()
parser.add_argument("--gpus", type=int, required=True)
parser.add_argument("--memory-limit", default=None,
                    help="override the container memory limit, e.g. 48Gi")
args = parser.parse_args()

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]

for doc in docs:
    if doc.get("kind") != "Deployment":
        continue
    spec = doc["spec"]["template"]["spec"]

    if args.gpus == 0:
        # Nothing schedules onto a GPU node, so the toleration is noise.
        spec.pop("tolerations", None)

    for container in spec["containers"]:
        res = container.setdefault("resources", {})
        for side in ("requests", "limits"):
            side_res = res.setdefault(side, {})
            if args.gpus == 0:
                side_res.pop("nvidia.com/gpu", None)
            else:
                side_res["nvidia.com/gpu"] = args.gpus

        if args.memory_limit:
            res["limits"]["memory"] = args.memory_limit
        elif args.gpus == 0:
            res["limits"]["memory"] = "10Gi"

yaml.safe_dump_all(docs, sys.stdout, default_flow_style=False, sort_keys=False)
