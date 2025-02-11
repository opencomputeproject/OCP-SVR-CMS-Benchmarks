#!/usr/bin/env python3

import argparse
import os
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.ticker import FuncFormatter

from utils import int_to_human, smooth_line, remove_direction_column

# Suppressing a warning that appears when more than 20 figures are opened
plt.rcParams["figure.max_open_warning"] = 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create graphs from previously generated CSV files"
    )

    parser.add_argument(
        "-c",
        "--csv-files",
        type=str,
        action="append",
        required=True,
        nargs=2,
        help="The first vendor type to process",
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
        help="The function to be graphed",
    )

    parser.add_argument(
        "-t",
        "--title",
        type=str,
        required=False,
        help="The title that the graphs should have",
    )

    args = parser.parse_args()

    csv_files, directory, array_sizes, functions, title = (
        [(Path(x), y) for x, y in args.csv_files],
        args.output_dir,
        args.array_sizes,
        args.functions,
        args.title,
    )

    if not os.path.isdir(directory):
        os.makedirs(directory)

    dfs = [
        (remove_direction_column(pd.read_excel(f)), n)
        for (f, n) in csv_files
    ]

    if not array_sizes:
        array_sizes = dfs[0][0]["ArraySize"].drop_duplicates()
    if not functions:
        functions = dfs[0][0]["Function"].drop_duplicates()

    for array_size in array_sizes:
        for func in functions:
            fig, ax = plt.figure(figsize=(10, 10)), plt.subplot(111)

            for df, n in dfs:
                # https://stackoverflow.com/a/27975230 (Filtering by row value)
                filtered = df[df["ArraySize"] == array_size]
                filtered = (
                    filtered[filtered["Function"] == func]
                    .drop(columns=["Function"])
                    .groupby(["Threads"])["BestRateMBs"]
                    .mean()
                )

                x, y = smooth_line(filtered.index, filtered.values)

                ax.plot(x, y, label=n)

            # https://stackoverflow.com/a/4701285 (setting legend outside plot)
            box = ax.get_position()
            ax.set_position(
                [box.x0, box.y0 + box.height * 0.1, box.width, box.height * 0.9]
            )
            ax.legend(
                loc="upper center",
                bbox_to_anchor=(0.5, -0.125),
                fancybox=True,
                shadow=True,
                ncol=2,
                fontsize=10,
            )

            ax.yaxis.set_major_formatter(
                FuncFormatter(
                    lambda x, _: int_to_human(x)
                    if x < 1_000_000
                    else int_to_human(x, fmt="%.1f")
                )
            )

            human_array_size = int_to_human(array_size, replace_long=False)

            ax.set_xlabel("Threads")
            ax.set_ylabel("Best Rate (MB/s)")

            ax.grid(True, color="white", linewidth=1.2)
            fig.gca().set_facecolor((0.9, 0.9, 0.9))

            default_title = f"Function: {func}, Array size: {human_array_size}"

            if title := args.title:
                ax.set_title(f"{title}\n{default_title}")
            else:
                ax.set_title(default_title)

            f = directory + f"/{func}-{human_array_size.replace(' ', '')}.png"
            fig.savefig(f)
            fig.clf()


if __name__ == "__main__":
    main()
