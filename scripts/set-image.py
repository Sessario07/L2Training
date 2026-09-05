#!/usr/bin/env python3
"""Set an image in a kustomization.yaml without needing the standalone
`kustomize` binary.

`kustomize edit set image` requires the separate kustomize CLI, which is not
bundled with kubectl (kubectl only embeds the *build* half as
`kubectl kustomize`). Depending on it makes the build fail on any machine that
has kubectl but not kustomize — which is most of them.

    ./scripts/set-image.py k8s/app l2lab-app=<registry>/api:<tag>
"""
import re
import sys
from pathlib import Path

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    kdir = Path(sys.argv[1])
    kfile = kdir / "kustomization.yaml"
    text = kfile.read_text()

    for pair in sys.argv[2:]:
        name, ref = pair.split("=", 1)
        new_name, _, new_tag = ref.rpartition(":")
        # Rewrite the newName/newTag under the matching `- name:` entry.
        pat = re.compile(
            rf"(- name: {re.escape(name)}\n)(\s+)newName: \S+\n\s+newTag: \S+",
            re.M,
        )
        if not pat.search(text):
            print(f"no image entry named '{name}' in {kfile}", file=sys.stderr)
            sys.exit(1)
        text = pat.sub(
            lambda m: f"{m.group(1)}{m.group(2)}newName: {new_name}\n"
                      f"{m.group(2)}newTag: {new_tag}",
            text,
        )
        print(f"  {name} -> {new_name}:{new_tag}")

    kfile.write_text(text)

if __name__ == "__main__":
    main()
