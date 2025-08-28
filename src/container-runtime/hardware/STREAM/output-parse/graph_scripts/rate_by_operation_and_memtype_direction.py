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
        "-c",
        "--csv-file",
        type=file_exists,
        required=True,
        help="CSV file that contains both DRAM and CXL operations",
    )

    parser.add_argument(
        "-o",
        "--output-dir",
        type=str,
        required=True,
        help="Directory to dump all the graphs into",
    )

    parser.add_argument(
        "-t",
        "--title",
        type=str,
        required=True,
        help="There are so many lines, this one needs an extra title",
    )

    args = parser.parse_args()

    directory = args.output_dir

    if not os.path.isdir(directory):
        os.makedirs(directory)

    df = remove_direction_column(pd.read_excel(args.csv_file))

    array_sizes = df["ArraySize"].drop_duplicates()
    functions = df["Function"].drop_duplicates()

    # https://stackoverflow.com/a/67148732 (filtering via index)
    dram_to_cxl_df, cxl_to_dram_df = (
        df.copy()[df.index.map(lambda i: i % 8 in range(0, 4))],
        df.copy()[df.index.map(lambda i: i % 8 in range(4, 8))],
    )

    dram_to_cxl_df["MemoryType"] = "DRAM to CXL"
    cxl_to_dram_df["MemoryType"] = "CXL to DRAM"

    df = pd.concat([dram_to_cxl_df, cxl_to_dram_df])

    memory_types = df["MemoryType"].drop_duplicates()

    colors = ["green", "orange", "blue", "red"]

    for array_size in array_sizes:
        filtered = df[df["ArraySize"] == array_size]

        fig = plt.figure(figsize=(10, 10))
        ax = plt.subplot(111)

        for i, memory in enumerate(memory_types):
            for j, func in enumerate(functions):
                inner_filtered = filtered[filtered["Function"] == func]

                tmp_df: pd.DataFrame = (
                    inner_filtered[inner_filtered["MemoryType"].str.contains(memory)]
                    .drop(columns=["MemoryType"])
                    .groupby(["Threads"])["BestRateMBs"]
                    .mean()
                )

                x, y = smooth_line(tmp_df.index, tmp_df.values)

                ax.plot(
                    x,
                    y,
                    label=f"{func}: {memory}",
                    color=colors[j],
                    linestyle="solid" if i % 2 == 0 else "dashed",
                )

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
        ax.set_title(f"{args.title}\nArray size: {human_array_size}")

        ax.grid(True, color="white", linewidth=1.2)
        fig.gca().set_facecolor((0.9, 0.9, 0.9))

        f = directory + f"/{human_array_size.replace(' ', '')}.png"
        fig.savefig(f)
        fig.clf()


if __name__ == "__main__":
    main()
