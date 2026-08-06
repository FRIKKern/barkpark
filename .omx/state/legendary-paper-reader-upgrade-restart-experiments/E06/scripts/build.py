#!/usr/bin/env python3
import argparse
from pathlib import Path
from candidate import HERE, build

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=HERE / "generated")
args = parser.parse_args()
build(args.output)
print(args.output)
