#!/usr/bin/env python3

import argparse

import pandas as pd

from graph_scripts.utils import file_exists


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Get the best bandwidths from a CSV file"
    )

    parser.add_argument(
        "-c", "--csv-file", type=file_exists, required=True, help="CSV file to process"
    )

    parser.add_argument(
        "-o", "--output", type=str, required=True, help="Where to put the Excel file"
    )

    args = parser.parse_args()

    # Read CSV file, write to new Excel file
    df = pd.read_csv(args.csv_file)
    df.to_excel(args.output, index=False)


if __name__ == "__main__":
    main()
