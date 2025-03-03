#!/usr/bin/env python3

import os
import argparse
import re
import pandas as pd


def dir_path(path: str) -> str:
    if os.path.isdir(path):
        return path
    else:
        raise argparse.ArgumentTypeError(f"readable_dir:{path} is not a valid path")

def sanitize_name(in_name: str) -> str:
    illegal_chars_pattern = r'[\\/*?:[\]]'
    name = re.sub(illegal_chars_pattern, '_', in_name)
    return name


def process_memtier_results(filename: str) -> pd.DataFrame:
    result = {}
    file = open(filename, "r")
    Lines = file.readlines()

    result["Data size (bytes)"] = os.path.basename(filename).split("_")[0]

    for line in Lines:
        # print(line)
        line = line.strip(" ").strip("\n")
        if line.startswith("Totals "):
            line1 = re.sub(" +", ",", line)
            res_array = line1.split(",")
            result["ops/sec"] = float(res_array[1])
            result["hits/sec"] = float(res_array[2])
            result["miss/sec"] = float(res_array[3])
            result["avg_latency"] = float(res_array[4])
            result["p50_latency"] = float(res_array[5])
            result["p95_latency"] = float(res_array[6])
            result["p99_latency"] = float(res_array[7])
            result["p99.9_latency"] = float(res_array[8])
            result["kb/s"] = float(res_array[9])

    # print(result)
    return result


def sort_dataframe_column_with_kmg(df: pd.DataFrame, column_name: str) -> pd.DataFrame:
    """Sorts a DataFrame column with strings ending with K/k, M/m, G/g in ascending order."""

    def key_function(s: str) -> float:
        """Key function for sorting."""
        if isinstance(s, str):
            if s.endswith('k') or s.endswith('K'):
                return float(s[:-1]) * 1000
            elif s.endswith('m') or s.endswith('M'):
                return float(s[:-1]) * 1000000
            elif s.endswith('g') or s.endswith('G'):
                return float(s[:-1]) * 1000000000
            else:
                try:
                    # Handles cases where the string is just a number
                    return float(s)
                except ValueError:
                    # pushes non-numeric or oddly formatted strings to the end.
                    return float('inf')
        else:
            # handles cases where the cell is not a string
            try:
                return float(s)
            except (TypeError, ValueError):
                # pushes non-numeric or oddly formatted cells to the end.
                return float('inf')

    df_sorted = df.sort_values(by=column_name, key=lambda col: col.apply(key_function))
    return df_sorted


def process_directory(directory: str, df: pd.DataFrame) -> pd.DataFrame:
    result_df = df.copy()
    # Parse only files with pattern *_bench.log
    for filename in os.listdir(directory):
        filepath = os.path.join(directory, filename)
        # Process only the files
        if not os.path.isfile(filepath):
            continue
        # Process only those files that end with _bench.log
        if filename.endswith("_bench.log"):
            print(f"    Processing: {filepath}")
            result_df.loc[len(result_df)] = process_memtier_results(filepath)
        result_df = sort_dataframe_column_with_kmg(result_df, 'Data size (bytes)')
    return result_df


def plot_the_df(output_name: str, title: str, df: pd.DataFrame) -> None:
    ax = df.plot.bar(rot=0)
    ax.set_title(title)
    ax.legend(loc='lower center', bbox_to_anchor=(0.5, -0.2), ncol=2)
    fig = ax.get_figure()
    fig.savefig(output_name+'.png', bbox_inches='tight')


def get_experiment_prefix(input_string: str) -> str:
    try:
        index = input_string.index("run")
        return input_string[:index-1]
    except ValueError:
        return input_string


def plot_charts(left_df: pd.DataFrame, right_df: pd.DataFrame, args: argparse.Namespace) -> None:
    left_name = get_experiment_prefix(os.path.basename(os.path.normpath(args.left)))
    right_name = get_experiment_prefix(os.path.basename(os.path.normpath(args.right)))

    # Consider the case when the same output prefix is used for different experiments
    if left_name == right_name:
        left_name += "_left"
        right_name += "_right"
    


    merged_df = left_df.merge(right_df,
                              on=['Data size (bytes)'],
                              how='left',
                              suffixes=('_'+left_name, '_'+right_name))
    merged_df.to_excel(args.output + ".xlsx", index=False)
   
    # Metrics and their readable names
    plots_to_generate = { "ops/sec" : "Operations/s (Relative)",
                          "hits/sec": "Hits/s (Relative)",
                          "miss/sec": "Miss/s (Relative)",
                          "avg_latency": "Average Latency (Relative)",
                          "p50_latency": "P50 Latency (Relative)",
                          "p95_latency": "P95 Latency (Relative)",
                          "p99_latency": "P99 Latency (Relative)",
                          "p99.9_latency": "P99.9 Latency (Relative)",
                          "kb/s": "Throughput kb/s (Relative)"
                        }


    for plot, title in plots_to_generate.items():
        o_left_name = plot+'_'+left_name
        o_right_name = plot+'_'+right_name

        columns_to_extract = [ 'Data size (bytes)', o_left_name, o_right_name ]
        extracted_df = merged_df[columns_to_extract]
        extracted_df = extracted_df.rename(columns={o_left_name: left_name, o_right_name: right_name})
        # Normalize Results to left values, i.e. Generate relative performance numbers
        extracted_df[right_name] = extracted_df[right_name] / extracted_df[left_name]
        extracted_df[left_name] = extracted_df[left_name] / extracted_df[left_name]

        output_name = args.output + "_" + sanitize_name(plot)
        extracted_df.set_index(['Data size (bytes)'], inplace=True)
        plot_the_df(output_name, title, extracted_df)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('-l',
                        '--left',
                        required=True,
                        type=dir_path,
                        help="directory path of the base results")
    parser.add_argument('-r',
                        '--right',
                        required=True,
                        type=dir_path,
                        help="directory path of the experiment results")
    parser.add_argument('-o',
                        '--output',
                        required=False,
                        help='The prefix for generating the charts')
    args = parser.parse_args()

    df = pd.DataFrame(
        columns=[
            "Data size (bytes)",
            "ops/sec",
            "hits/sec",
            "miss/sec",
            "avg_latency",
            "p50_latency",
            "p95_latency",
            "p99_latency",
            "p99.9_latency",
            "kb/s",
        ]
    )
    print(f"Processing the results in {args.left}")
    left_df = process_directory(args.left, df)
    print(f"Processing the results in {args.right}")
    right_df = process_directory(args.right, df)

    plot_charts(left_df, right_df, args)


if __name__ == "__main__":
    main()
