#!/usr/bin/env python3

import argparse

import pandas as pd
from openpyxl import load_workbook
from openpyxl.worksheet.filters import FilterColumn, Filters

from graph_scripts.utils import file_exists, remove_direction_column


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Get the best bandwidths from a CSV file"
    )

    parser.add_argument(
        "-c", "--csv-file", type=file_exists, required=True, help="CSV file to process"
    )

    parser.add_argument(
        "-o",
        "--output",
        type=str,
        required=True,
        help="Where and what the excel file should be named",
    )

    args = parser.parse_args()

    df = remove_direction_column(pd.read_excel(args.csv_file))

    array_sizes = df["ArraySize"].drop_duplicates()
    functions = df["Function"].drop_duplicates()
    threads = df["Threads"].drop_duplicates()

    dram_to_cxl_df, cxl_to_dram_df = (
        df.copy()[df.index.map(lambda i: i % 8 in range(0, 4))],
        df.copy()[df.index.map(lambda i: i % 8 in range(4, 8))],
    )

    dram_to_cxl_df.rename(columns={"BestRateMBs": "DRAM to CXL"}, inplace=True)
    dram_to_cxl_df["CXL to DRAM"] = cxl_to_dram_df.iloc[:, 3].values
    combined_df = dram_to_cxl_df.copy()

    with pd.ExcelWriter(args.output) as f:
        for array_size in array_sizes:
            filtered = combined_df[combined_df["ArraySize"] == array_size]

            worksheet_name = f"{array_size}"

            filtered.to_excel(
                f,
                sheet_name=worksheet_name,
                index=False,
                engine="openpyxl",
            )

    wb = load_workbook(args.output)

    to_filter = f"C1:C{len(functions) * len(threads) + 1}"

    for array_size in array_sizes:
        ws = wb[str(array_size)]
        filters = ws.auto_filter
        filters.ref = to_filter
        col = FilterColumn(colId=2)
        col.filters = Filters(filter=["Copy", "Scale", "Add", "Triad"])
        filters.filterColumn.append(col)

        ws.auto_filter.add_sort_condition(to_filter)

        wb.save(args.output)


if __name__ == "__main__":
    main()
