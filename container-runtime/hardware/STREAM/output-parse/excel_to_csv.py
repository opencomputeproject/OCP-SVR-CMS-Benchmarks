#!/usr/bin/env python3

import argparse

import pandas as pd

from graph_scripts.utils import file_exists


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Get the best bandwidths from a CSV file"
    )

    parser.add_argument(
        "-x",
        "--xlsx-file",
        type=file_exists,
        required=True,
        help="Excel file to process",
    )

    parser.add_argument(
        "-o", "--output", type=str, required=True, help="Where to put the CSV file"
    )

    args = parser.parse_args()

    df = pd.read_excel(args.xlsx_file)

    df.to_csv(args.output, index=False)


if __name__ == "__main__":
    main()
