#!/usr/bin/env python3

import argparse
import os

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import pandas as pd

from utils import file_exists, int_to_human, smooth_line, remove_direction_column

# Supressing a warning that appears when more than 20 figures are opened
plt.rcParams["figure.max_open_warning"] = 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create graphs from previously generated CSV files"
    )

    parser.add_argument(
        "-d",
        "--dram-csv-file",
        type=file_exists,
        required=True,
        help="DRAM CSV file",
    )

    parser.add_argument(
        "-c",
        "--cxl-csv-file",
        type=file_exists,
        required=True,
        help="CXL CSV file",
    )

    parser.add_argument(
        "-x",
        "--dram-cxl-csv-file",
        type=file_exists,
        required=True,
        help="DRAM+CXL CSV file",
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
        help="The array size to use",
    )

    parser.add_argument(
        "-f",
        "--functions",
        type=str,
        nargs="+",
        required=False,
        help="The functions to be plotted",
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

    dram_csv_file, cxl_csv_file, dram_cxl_csv_file = (
        args.dram_csv_file,
        args.cxl_csv_file,
        args.dram_cxl_csv_file,
    )

    dram_df, cxl_df, combined_df = (
        remove_direction_column(pd.read_excel(dram_csv_file)),
        remove_direction_column(pd.read_excel(cxl_csv_file)),
        pd.read_excel(dram_cxl_csv_file),
    )

    direction_column_exists = "Direction" in combined_df.columns

    combined_df = remove_direction_column(combined_df)

    # https://stackoverflow.com/a/67148732 (filtering via index)
    if direction_column_exists:
        dram_cxl_df, cxl_dram_df = (
            combined_df.copy()[combined_df.index.map(lambda i: i % 8 in range(0, 4))],
            combined_df.copy()[combined_df.index.map(lambda i: i % 8 in range(4, 8))],
        )
    else:
        dram_cxl_df, cxl_dram_df = (
            combined_df.copy()[combined_df.index.map(lambda i: i % 8 in (0, 2, 5, 7))],
            combined_df.copy()[combined_df.index.map(lambda i: i % 8 in (1, 3, 4, 6))],
        )

    dram_df["MemoryType"] = "DRAM"
    cxl_df["MemoryType"] = "CXL"
    dram_cxl_df["MemoryType"] = "DRAM to CXL"
    cxl_dram_df["MemoryType"] = "CXL to DRAM"

    df = pd.concat([dram_df, cxl_df, dram_cxl_df, cxl_dram_df])

    memory_types = df["MemoryType"].drop_duplicates()
    functions = args.functions if args.functions else df["Function"].drop_duplicates()
    array_sizes = (
        args.array_sizes if args.array_sizes else df["ArraySize"].drop_duplicates()
    )

    for func in functions:
        for array_size in array_sizes:
            filtered = df[df["ArraySize"] == array_size]
            filtered = filtered[filtered["Function"] == func]

            fig = plt.figure(figsize=(10, 10))
            ax = plt.subplot(111)

            for memory in memory_types:
                tmp_df: pd.DataFrame = (
                    filtered[filtered["MemoryType"].str.contains(memory)]
                    .drop(columns=["MemoryType"])
                    .groupby(["Threads"])["BestRateMBs"]
                    .mean()
                )

                x, y = smooth_line(tmp_df.index, tmp_df.values)

                ax.plot(x, y, label=memory)

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

            human_array_size = int_to_human(array_size, replace_long=False)

            ax.set_xlabel("Threads")
            ax.set_ylabel("Best Rate (MB/s)")

            ax.grid(True, color="white", linewidth=1.2)
            fig.gca().set_facecolor((0.9, 0.9, 0.9))

            if title := args.title:
                ax.set_title(
                    f"{title}\nFunction: {func}, Array size: {human_array_size}"
                )
            else:
                ax.set_title(f"Function: {func}, Array size: {human_array_size}")

            f = directory + f"/{func}-{human_array_size.replace(' ', '')}.png"
            fig.savefig(f)
            fig.clf()


if __name__ == "__main__":
    main()
