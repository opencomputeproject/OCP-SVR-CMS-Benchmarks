#!/usr/bin/env python3

from io import StringIO
import re
from pathlib import Path
import sys

import pandas as pd

ARRAY_SIZES: list[int] = [
    430_080_000,
]


WHITESPACE_REPLACE = re.compile(r"\s+")


def format_stream_output(
    s: str, thread_count: int, array_size: int
) -> list[list[int | str]]:
    lines = [x.strip() for x in s.strip().splitlines()]

    start, end = 0, len(lines)

    for i, line in enumerate(lines):
        if "Function" in line and "BestRateMBs" in line:
            start = i
            break

    for i, line in enumerate(lines[start + 1 :]):
        if line.startswith("-"):
            end = i
            break

    selected_output = lines[start : start + end + 1]

    lst: list[list[str]] = [WHITESPACE_REPLACE.split(x) for x in selected_output]

    lst[0].insert(0, "ArraySize")
    lst[0].insert(0, "Threads")

    for i in range(1, len(lst)):
        lst[i][0] = lst[i][0].removesuffix(":")
        lst[i].insert(0, array_size)
        lst[i].insert(0, thread_count)

    return lst


def main() -> None:
    lst = []

    directory = Path(sys.argv[1])

    files = [f.name for f in directory.iterdir() if f.is_file()]

    for file in files:
        file_path = directory / file
        threads = file.split("_")[-1].replace(".txt", "")
        with open(file_path) as f:
            formatted = format_stream_output(f.read(), threads, 430_080_000)
            lst.extend(formatted)

    header = lst[0]
    filtered = list(filter(lambda x: x != header, lst))
    filtered.insert(0, header)

    out = "\n".join(",".join(str(y) for y in x) for x in filtered)

    df = pd.read_csv(StringIO(out))

    # df.to_excel("genoa3_1.xlsx", index=False)
    df.to_csv("out.csv", index=False)


if __name__ == "__main__":
    main()
