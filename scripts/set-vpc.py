#!/usr/bin/env python3
"""Write the current VPC id into the AWS Load Balancer Controller patch.

Why this exists
---------------
The controller needs --aws-vpc-id. Without it, it tries to discover the VPC
from EC2 instance metadata and crash-loops with

    failed to get VPC ID ... context deadline exceeded

So the id has to be explicit. But hardcoding it in the manifest makes the repo
non-reproducible: `make down` + `make up` creates a NEW VPC, and the stale id
means the controller finds zero subnets and every Ingress silently never gets
an ALB. The error it logs points at subnet tagging, which sends you hunting in
completely the wrong place:

    couldn't auto-discover subnets: unable to resolve at least one subnet.
    Evaluated 0 subnets: 0 are tagged for other clusters, ...

("Evaluated 0" is the tell - if tagging were wrong it would evaluate the
subnets and reject them. Evaluating none means it is looking in the wrong VPC.)

    ./scripts/set-vpc.py <vpc-id>
"""
import re
import sys
from pathlib import Path

TARGET = Path(__file__).resolve().parent.parent / "k8s/platform/aws-lbc/patch-deployment.yaml"


def main():
    if len(sys.argv) != 2 or not sys.argv[1].startswith("vpc-"):
        print(__doc__)
        sys.exit(1)
    vpc = sys.argv[1]

    text = TARGET.read_text()
    pat = re.compile(r"(- --aws-vpc-id=)vpc-[0-9a-f]+")
    if not pat.search(text):
        print(f"no --aws-vpc-id line in {TARGET}", file=sys.stderr)
        sys.exit(1)

    old = pat.search(text).group(0).split("=")[1]
    if old == vpc:
        print(f"  vpc id already {vpc}")
        return

    TARGET.write_text(pat.sub(rf"\g<1>{vpc}", text))
    print(f"  aws-lbc vpc id: {old} -> {vpc}")


if __name__ == "__main__":
    main()
