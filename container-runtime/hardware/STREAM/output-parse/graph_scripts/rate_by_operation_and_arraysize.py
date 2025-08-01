#!/usr/bin/env python3

import argparse
import os

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import pandas as pd

from utils import file_exists, smooth_line, int_to_human, remove_direction_column

# Supressing a warning that appears when more than 20 figures are opened
plt.rcParams["figure.max_open_warning"] = 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create graphs from previously generated CSV files"
    )

    parser.add_argument(
        "-c", "--csv-file", type=file_exists, required=True, help="CSV file to process"
    )

    parser.add_argument(
        "-o",
        "--output-dir",
        type=str,
        required=True,
        help="Directory to dump all the graphs into",
    )

    parser.add_argument(
        "-a",
        "--array-sizes",
        type=int,
        nargs="+",
        required=False,
        help="The array sizes to be graphed",
    )

    parser.add_argument(
        "-f",
        "--functions",
        type=str,
        nargs="+",
        required=False,
        help="The functions to be graphed",
    )

    parser.add_argument(
        "-v",
        "--vendor-type",
        type=str,
        required=False,
        help="The vendor type to be displayed in the title",
    )

    parser.add_argument(
        "-t",
        "--title",
        type=str,
        required=False,
        help="The main title of the graph",
    )

    args = parser.parse_args()

    directory = args.output_dir

    if not os.path.isdir(directory):
        os.makedirs(directory)

    df = remove_direction_column(pd.read_excel(args.csv_file))

    array_sizes, functions = (
        args.array_sizes if args.array_sizes else df["ArraySize"].drop_duplicates(),
        args.functions if args.functions else df["Function"].drop_duplicates(),
    )

    for func in functions:
        filtered = df[df["Function"] == func]

        fig = plt.figure(figsize=(10, 10))
        ax = plt.subplot(111)

        for array_size in array_sizes:
            tmp_df: pd.DataFrame = (
                filtered[filtered["ArraySize"] == array_size]
                .drop(columns=["ArraySize"])
                .groupby(["Threads"])["BestRateMBs"]
                .mean()
            )

            x, y = smooth_line(tmp_df.index, tmp_df.values)

            ax.plot(x, y, label=int_to_human(array_size))

        box = ax.get_position()
        ax.set_position(
            [box.x0, box.y0 + box.height * 0.1, box.width, box.height * 0.9]
        )
        ax.legend(
            loc="upper center",
            bbox_to_anchor=(0.5, -0.125),
            fancybox=True,
            shadow=True,
            ncol=5,
            fontsize=10,
        )

        ax.yaxis.set_major_formatter(
            FuncFormatter(
                lambda x, _: int_to_human(x)
                if x < 1_000_000
                else int_to_human(x, fmt="%.1f")
            )
        )

        ax.set_xlabel("Threads")
        ax.set_ylabel("Best Rate (MB/s)")

        original_title = (
            f"Vendor Type: {args.vendor_type}, Operation: {func}"
            if args.vendor_type
            else f"Operation: {func}"
        )

        if title := args.title:
            ax.set_title(f"{title}\n{original_title}")
        else:
            ax.set_title(original_title)

        ax.grid(True, color="white", linewidth=1.2)
        fig.gca().set_facecolor((0.9, 0.9, 0.9))

        f = directory + f"/{func}.png"
        fig.savefig(f)
        fig.clf()


if __name__ == "__main__":
    main()
