#!/usr/bin/env python3

import argparse
from pathlib import Path
import re
import pandas as pd


WHITESPACE_REPLACE = re.compile(r"\s+")


def validate_dir_path(path_str: str) -> Path:
    path = Path(path_str)

    if not path.is_dir():
        raise argparse.ArgumentTypeError(f"Path '{path_str}' does not exist.")

    return path


# def format_stream_output(s: str, thread_count: int, array_size: int) -> pd.DataFrame:
def format_stream_output(s: str) -> pd.DataFrame:
    """
    Parsing the output of STREAM for all the numbers that are important to us.

    The rest of this docstring is an example of what STREAM outputs:

    ```txt
    -------------------------------------------------------------
    STREAM version $Revision: 5.10 $
    -------------------------------------------------------------
    This system uses 8 bytes per array element.
    -------------------------------------------------------------
    Array size = 4000000 (elements), Offset = 0 (elements)
    Memory per array = 30.5 MiB (= 0.0 GiB).
    Total memory required = 91.6 MiB (= 0.1 GiB).
    Each kernel will be executed 10 times.
    The *best* time for each kernel (excluding the first iteration)
    will be used to compute the reported bandwidth.
    -------------------------------------------------------------
    Number of Threads requested = 64
    Number of Threads counted = 64
    -------------------------------------------------------------
    Your clock granularity/precision appears to be 1 microseconds.
    Each test below will take on the order of 106 microseconds.
    (= 106 clock ticks)
    Increase the size of the arrays if this shows that
    you are not getting at least 20 clock ticks per test.
    -------------------------------------------------------------
    WARNING -- The above is only a rough guideline.
    For best results, please be sure you know the
    precision of your system timer.
    -------------------------------------------------------------
    Function     Direction    BestRateMBs     AvgTime      MinTime      MaxTime
    Copy:        0->1           1597830.1     0.000042     0.000040     0.000048
    Scale:       0->1           1688273.3     0.000040     0.000038     0.000042
    Add:         0->1           2003249.7     0.000051     0.000048     0.000056
    Triad:       0->1           1954627.1     0.000051     0.000049     0.000053
    Copy:        1->0           1688273.3     0.000039     0.000038     0.000040
    Scale:       1->0           1777718.3     0.000038     0.000036     0.000039
    Add:         1->0           2141772.3     0.000047     0.000045     0.000049
    Triad:       1->0           2086285.9     0.000052     0.000046     0.000080
    -------------------------------------------------------------
    Solution Validates: avg error less than 1.000000e-13 on all three arrays
    -------------------------------------------------------------
    ```
    """
    lines = [str(x).strip() for x in s.strip().splitlines()]

    start, end = 0, len(lines)

    for i, line in enumerate(lines):
        if "Array size = " in line:
            lst = WHITESPACE_REPLACE.split(line)
            array_size = lst[3]
        if "Number of Threads requested" in line:
            lst = WHITESPACE_REPLACE.split(line)
            thread_count = lst[5]
        if "Function" in line and "BestRateMBs" in line:
            start = i
            break

    for i, line in enumerate(lines[start + 1 :]):
        if line.startswith("-"):
            end = i
            break

    lst = [WHITESPACE_REPLACE.split(x) for x in lines[start : start + end + 1]]

    df = pd.DataFrame(lst[1:], columns=lst[0])
    df["Function"] = df["Function"].apply(lambda x: x.removesuffix(":"))

    df.insert(0, "ArraySize", [array_size] * len(df))
    df.insert(0, "Threads", [thread_count] * len(df))

    return df


def main() -> None:
    parser = argparse.ArgumentParser(description="STREAM benchmarking tool results parser")

    parser.add_argument(
        "-i",
        "--input",
        type=validate_dir_path,
        help="The directory of where all the results are",
    )

    parser.add_argument(
        "-o",
        "--output",
        type=str,
        required=False,
        help="The prefix of the output files:  The generated files will be <prefix>_<function>.csv"
    )

    args = parser.parse_args()

    input_dir = Path(args.input) #, Path(args.output) if args.output else None
    output_file = args.output

    print(f"Input directory: {input_dir}")
    print(f"Output file: {output_file}")

    df = pd.DataFrame()

    for p in input_dir.rglob("stream_*.log"):
        with open(p) as f:
            raw = f.read()

        tmp_df = format_stream_output(raw)
        df = pd.concat([df, tmp_df], ignore_index=True)

    df = df.astype({'Threads': 'int32'})
    df = df.sort_values(by=['Threads'])

    # Split into constituent functions
    df[df['Function'] == 'Add'].to_csv(output_file+'_add.csv', index=False)
    df[df['Function'] == 'Copy'].to_csv(output_file+'_copy.csv', index=False)
    df[df['Function'] == 'Scale'].to_csv(output_file+'_scale.csv', index=False)
    df[df['Function'] == 'Triad'].to_csv(output_file+'_triad.csv', index=False)
    df.to_csv(output_file+'.csv', index=False)


if __name__ == "__main__":
    main()
