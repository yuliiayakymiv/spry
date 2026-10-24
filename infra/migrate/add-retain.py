"""Add DeletionPolicy/UpdateReplacePolicy: Retain to every resource of a CloudFormation YAML template.

Used by 1-retain-and-collect.sh on the template that is deployed right now (aws cloudformation
get-template), so the stack can be deleted while its resources stay. Reads stdin, writes stdout.
"""

import re
import sys

RESOURCE = re.compile(r"^  [A-Za-z0-9]+:\s*(#.*)?$")
RETAIN = "    DeletionPolicy: Retain\n    UpdateReplacePolicy: Retain\n"

lines = sys.stdin.read().splitlines(keepends=True)
out, in_resources, count = [], False, 0
for i, line in enumerate(lines):
    out.append(line)
    if re.match(r"^\S", line):  # a top-level key: Parameters, Resources, Outputs ...
        in_resources = line.startswith("Resources:")
        continue
    if in_resources and RESOURCE.match(line):
        body = "".join(lines[i + 1 : i + 6])
        if "DeletionPolicy: Retain" not in body:
            out.append(RETAIN)
        count += 1
sys.stdout.write("".join(out))
print(f"   {count} resources marked Retain", file=sys.stderr)
