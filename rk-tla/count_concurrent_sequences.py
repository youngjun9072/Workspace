#!/usr/bin/env python3
"""Count fully applied four-action traces from a TLC state dump."""

import re
import sys


def count(path):
    pairs = set()
    mixed = set()
    rejected = set()
    block = []

    def consume(lines):
        state = "".join(lines)
        if "/\\ step = 4\n" not in state or "/\\ queue = <<>>\n" not in state:
            return
        history = re.search(r"/\\ history = <<(.*?)>>", state, re.S)
        initial = re.search(r"/\\ initialSchema = (\[pk \|-> .*?\])", state)
        if history is None or initial is None:
            raise ValueError("terminal state is missing history or initial schema")
        operations = tuple(re.findall(r'"([^"]+)"', history.group(1)))
        pair = (initial.group(1), operations)
        pairs.add(pair)
        if any(op.startswith(("Update", "Delete")) for op in operations) and any(
            not op.startswith(("Update", "Delete")) for op in operations
        ):
            mixed.add(pair)
        if "/\\ rejected = TRUE\n" in state:
            rejected.add(pair)

    with open(path, encoding="utf-8") as source:
        for line in source:
            if line.startswith("State "):
                if block:
                    consume(block)
                block = [line]
            else:
                block.append(line)
        if block:
            consume(block)

    print(f"initial schema + four statement attempts: {len(pairs)}")
    print(f"including both DDL and DML: {len(mixed)}")
    print(f"including rejected DDL: {len(rejected)}")


if __name__ == "__main__":
    count(sys.argv[1])
