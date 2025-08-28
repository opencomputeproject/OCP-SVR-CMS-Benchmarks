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


def process_numastat_results(filename) -> pd.DataFrame:
    result = {}
    df = pd.read_csv(filename)

    node_columns_count = sum(1 for col in df.columns if col.startswith("Node"))
    result["Data size (bytes)"] = os.path.basename(filename).split("_")[0]

    for i in range(node_columns_count):
        columnname = 'Node'+str(i)
        result[columnname+'_Memory_avg'] = round(df[columnname].div(1024).mean(), 2)
        result[columnname+'_Memory_P95'] = round(df[columnname].div(1024*1024).quantile(0.95), 2)
    return result


def process_directory_numastat(directory: str, df: pd.DataFrame) -> pd.DataFrame:
    result_df = df.copy()
    for filename in os.listdir(directory):
        filepath = os.path.join(directory, filename)
        # Process only the files
        if not os.path.isfile(filepath):
            continue
        # Process only those files that end with _bench.log
        if filename.endswith("_numastat.csv"):
            print(f"    Processing: {filepath}")
            rdict = process_numastat_results(filepath)
            result_df.loc[len(result_df)] = rdict
        result_df = sort_dataframe_column_with_kmg(result_df, 'Data size (bytes)')
    return result_df


def process_dstat_results(filename) -> pd.DataFrame:
    result = {}
    df = pd.read_csv(filename, skiprows=4)
    # The columns are actually loaded in directly as the first data row, so set them in the dataframe
    df.columns = df.iloc[0]
    # Ignore the first data row, as it may be incomplete.  This is a known problem wiht dstat reported data
    data = df[2:]
    data = data.apply(pd.to_numeric)

    # Check the headers to identify the actual name generared by dstat
    # dstat generated different headers for different versions of the tool and OS combinations
    if 'idl' in df.columns:
        cpu_idle = 'idl'
        cpu_wait = 'wai'
        mem_used = 'used'
    elif 'total usage:idl' in df.columns:
        cpu_idle = 'total usage:idl'
        cpu_wait = 'total usage:wai'
        mem_used = 'used'
    else:
        return result

    result['CPU_Utilization'] = round((100.0 - data[cpu_idle].mean()), 2)
    result['CPU_Wait'] = round(data[cpu_wait].mean(), 2)
    result['Memory_Utilization_avg'] = round(data[mem_used].div(1024*1024).mean(), 2)
    result['Memory_Utilization_p95'] = round(data[mem_used].div(1024*1024).quantile(0.95), 2)
    result["Data size (bytes)"] = os.path.basename(filename).split("_")[0]

    return result


def plot_the_df(output_name: str, title: str, df: pd.DataFrame) -> None:
    ax = df.plot.bar(rot=0)
    ax.set_title(title)
    if  df.shape[1] == 2:
        ax.legend(loc='lower center', bbox_to_anchor=(0.5, -0.2), ncol=2)
    else:
        ax.legend(loc='right', bbox_to_anchor=(0.5, -0.2), ncol=2)
    fig = ax.get_figure()
    #fig.savefig(output_name+'.png', bbox_inches='tight')
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
                              suffixes=('_'+left_name, '_'+right_name)).set_index('Data size (bytes)')
    merged_df.to_excel(args.output + ".xlsx", index=False)
   
    # Metrics and their readable names
    # The first element is the title of the chart, 
    # the second element tells us if the plot should be absolute or relative
    plots_to_generate = { "ops/sec" : ( "Redis-Memtier Operations/s (Relative)", False),
                          "hits/sec": ("Redis-Memtier Hits/s (Relative)", False),
                          "miss/sec": ("Redis-Memtier Miss/s (Relative)", False),
                          "avg_latency": ("Redis-Memtier Average Latency (Relative)", False),
                          "p50_latency": ("Redis-Memtier P50 Latency (Relative)", False),
                          "p95_latency": ("Redis-Memtier P95 Latency (Relative)", False),
                          "p99_latency": ("Redis-Memtier P99 Latency (Relative)", False),
                          "p99.9_latency": ("Redis-Memtier P99.9 Latency (Relative)", False),
                          "kb/s": ("Redis-Memtier Throughput kb/s (Relative)", False),
                          "CPU_Utilization": ( "Redis-Memtier Average System CPU Utilization (Cores)", True),
                          "Memory_Utilization_avg": ("Redis-Memtier Average System Memory Utilization (GB)", True),
                          "Memory_Utilization_p95": ("Redis-Memtier P95 System Memory Utilization (GB)", True)
                        }


    for plot, title in plots_to_generate.items():
        o_left_name = plot+'_'+left_name
        o_right_name = plot+'_'+right_name

        columns_to_extract = [ o_left_name, o_right_name ]
        extracted_df = merged_df[columns_to_extract]
        extracted_df = extracted_df.rename(columns={o_left_name: left_name, o_right_name: right_name})
        # Normalize Results to left values, i.e. Generate relative performance numbers
        if title[1] == False:
            extracted_df[right_name] = extracted_df[right_name] / extracted_df[left_name]
            extracted_df[left_name] = extracted_df[left_name] / extracted_df[left_name]

        output_name = args.output + "_" + sanitize_name(plot)
        plot_the_df(output_name, title[0], extracted_df)

    numastat_df = merged_df[[col for col in merged_df.columns if col.startswith('Node')]]
    plot_the_df(args.output + "_numa_utilization", "NUMA Node Memory Utilization (GB)", numastat_df)


def process_directory_app(directory: str, df: pd.DataFrame) -> pd.DataFrame:
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


def collate_app_stats(directory: str) -> pd.DataFrame:
    app_df = pd.DataFrame(
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
    return process_directory_app(directory, app_df)


def process_directory_dstat(directory: str, df: pd.DataFrame) -> pd.DataFrame:
    result_df = df.copy()
    # Parse only files with pattern *_dstat.csv
    valid_dstat = True
    for filename in os.listdir(directory):
        filepath = os.path.join(directory, filename)
        # Process only the files
        if not os.path.isfile(filepath):
            continue
        # Process only those files that end with _bench.log
        if filename.endswith("_dstat.csv"):
            print(f"    Processing: {filepath}")
            rdict = process_dstat_results(filepath)
            if not rdict:
                valid_dstat = False
                return pd.DataFrame()
            result_df.loc[len(result_df)] = rdict
        result_df = sort_dataframe_column_with_kmg(result_df, 'Data size (bytes)')
    return result_df


def collate_dstat_stats(directory: str) -> pd.DataFrame:
    dstat_df = pd.DataFrame(
        columns=[
            'Data size (bytes)',
            'CPU_Utilization',
            'CPU_Wait',
            'Memory_Utilization_avg',
            'Memory_Utilization_p95'
        ]
    )
    return process_directory_dstat(directory, dstat_df)


def process_directory_numastat(directory: str, df: pd.DataFrame) -> pd.DataFrame:
    result_df = df.copy()
    for filename in os.listdir(directory):
        filepath = os.path.join(directory, filename)
        # Process only the files
        if not os.path.isfile(filepath):
            continue
        # Process only those files that end with _bench.log
        if filename.endswith("_numastat.csv"):
            print(f"    Processing: {filepath}")
            rdict = process_numastat_results(filepath)
            result_df.loc[len(result_df)] = rdict
        result_df = sort_dataframe_column_with_kmg(result_df, 'Data size (bytes)')
    return result_df


def collate_numastat_stats(directory: str) -> pd.DataFrame:
    # The numastat collection is dynamic and based on the number
    # of NUMA nodes on the system.
    # Create the base dataframe to account for the numebr of nodes.
    numastat_df = pd.DataFrame(columns=['Data size (bytes)'])
    
    # Find the number of NUMA nodes in the system under test
    filepath = os.path.join(directory, 'lscpu.log')
    file = open(filepath, "r")
    Lines = file.readlines()
    for line in Lines:
        # print(line)
        line = line.strip(" ").strip("\n")
        if line.startswith("NUMA node(s):"):
            line1 = re.sub(" +", "", line)
            res_array = line1.split(":")
            num_numa_nodes = int(res_array[1])
            break

    # Populate the base dataframe
    for i in range(num_numa_nodes):
        columnname = 'Node'+str(i)
        numastat_df[columnname+'_Memory_avg'] = None 
        numastat_df[columnname+'_Memory_P95'] = None 

    return process_directory_numastat(directory, numastat_df)


# Collect all the possible stats into a single dataframe
def generate_combined_stats(directory: str) -> pd.DataFrame:
    print(f"Processing the results in {directory}")
    app_df = collate_app_stats(directory)
    dstat_df = collate_dstat_stats(directory)
    if not dstat_df.empty:
        app_df = app_df.merge(dstat_df, 
                              on=['Data size (bytes)'],
                              how='inner')
    numastat_df = collate_numastat_stats(directory)
    if not numastat_df.empty:
        app_df = app_df.merge(numastat_df, 
                              on=['Data size (bytes)'],
                              how='inner')
    return app_df


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

    left_df = generate_combined_stats(args.left)
    right_df = generate_combined_stats(args.right)
    plot_charts(left_df, right_df, args)


if __name__ == "__main__":
    main()
