#!/usr/bin/env python3

import argparse

import humanize
import pandas as pd

from graph_scripts.utils import file_exists, remove_direction_column


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Get the best bandwidths from a CSV file"
    )

    parser.add_argument(
        "-c", "--csv-file", type=file_exists, required=True, help="CSV file to process"
    )

    args = parser.parse_args()

    df = remove_direction_column(pd.read_excel(args.csv_file))

    # Group by Array size, threads, then function,
    # and average the best rate of the grouping due to pure memory types
    # having 2 results for the same group of attributes previously mentioned
    df = (
        df.groupby(["ArraySize", "Threads", "Function"])["BestRateMBs"]
        .mean()
        .reset_index()
    )

    # Sometimes, file columns will be out of order, so this flips the two
    # columns "ArraySize" and "Threads", with with their headers
    if df.columns[0] != "ArraySize":
        df["ArraySize"], df["Threads"] = df["Threads"], df["ArraySize"]
        df.columns = ["Threads", "ArraySize", "Function", "BestRateMBs"]

    # Get the max bandwidth for each array size group
    idx = df.groupby(["ArraySize"])["BestRateMBs"].idxmax()
    df = df.loc[idx]

    # Make the numbers readable by humans
    df["ArraySize"] = df["ArraySize"].apply(
        lambda x: humanize.intword(x, format="%.1f")
    )

    print(df.to_string(index=False))


if __name__ == "__main__":
    main()
