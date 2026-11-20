#!/usr/bin/env python3

import os
import pandas as pd
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.interpolate import make_interp_spline
import numpy as np
import argparse


RATIOS = ['w21', 'w23', 'w27']
TYPES = ['seq', 'rand']

file_patterns = {
    'w21_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W21.seq.(?:10|25|50)(?:.socket_\d+)?.csv|bw_ramp.results.node_\d+.R.seq.100:0|bw_ramp.results.node_\d+.R.seq.0:100',
    'w23_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W23.seq.(?:10|25|50)(?:.socket_\d+)?.csv',
    'w27_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W27.seq.(?:10|25|50)(?:.socket_\d+)?.csv',
    'w21_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W21.rand.(?:10|25|50)(?:.socket_\d+)?.csv|bw_ramp.results.node_\d+.R.rand.100:0|bw_ramp.results.node_\d+.R.rand.0:100',
    'w23_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W23.rand.(?:10|25|50)(?:.socket_\d+)?.csv',
    'w27_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W27.rand.(?:10|25|50)(?:.socket_\d+)?.csv',
}

def read_csv_files(search_dir, regex_pattern=r'(.+)\.csv'):
    csv_files = [file for file in os.listdir(search_dir) if re.match(regex_pattern, file)]
    print(f'files: {csv_files}')
    data_dict = {}

    for file in csv_files:
        df = pd.read_csv(os.path.join(search_dir, file))
        data_dict[file] = df

    return data_dict


def generate_stacked_line_chart(data_dict, x_column, y_column, output_dir, image_name, title='Stacked Line Chart'):
    plt.figure(figsize=(10, 6))

    plotted = False
    for filename, dataframe in data_dict.items():
        x = dataframe[x_column]
        y = dataframe[y_column]

        finite = np.isfinite(x) & np.isfinite(y)
        if not finite.any():
            print(f"Skipping '{filename}': no finite {y_column} data (all NaN/inf).")
            continue
        x, y = x[finite], y[finite]

        if len(x) >= 4 and x.is_monotonic_increasing and x.is_unique:
            # Perform cubic spline interpolation
            x_new = np.linspace(x.min(), x.max(), 300)
            spline = make_interp_spline(x, y)
            y_smooth = spline(x_new)
        else:
            x_new, y_smooth = x, y

        cxl_ratio = dataframe['DRAM:CXL Ratio'].iloc[0]
        label = f"{node_label_from_filenames([filename])} {cxl_ratio}"
        plt.plot(x_new, y_smooth, label=label)
        plotted = True

    if not plotted:
        print(f"Skipping chart '{image_name}': no series had finite {y_column} data.")
        plt.close()
        return

    plt.xlabel(x_column)
    plt.ylabel(y_column)
    plt.title(title)
    plt.legend()
    plt.savefig(os.path.join(output_dir, f'{image_name}.png'))
    plt.close()


def node_label_from_filenames(filenames):
    sockets, nodes = [], []
    for filename in filenames:
        for socket in re.findall(r'socket_(\d+)', filename):
            if socket not in sockets:
                sockets.append(socket)
        for node in re.findall(r'node_(\d+)', filename):
            if node not in nodes:
                nodes.append(node)

    parts = []
    if sockets:
        parts.append('-'.join(f'socket{s}' for s in sockets))
    if nodes:
        parts.append('-'.join(f'node{n}' for n in nodes))
    if not parts:
        return None
    return '_'.join(parts)


def process_directory(directory, ratio, data_type):
    df_dict = read_csv_files(directory, file_patterns[f'{ratio}_{data_type}'])
    if not df_dict:
        print(f"No CSV data found in '{directory}' for ratio '{ratio}' type '{data_type}'. "
              "Note: w23/w27 interleave data is only produced when mlc.sh is run with both -c and -d "
              "(and only for the 'seq' access pattern); single-node runs only populate w21.")
        return

    node_label = node_label_from_filenames(df_dict.keys())
    generate_stacked_line_chart(df_dict,
                                'Num of Cores',
                                'Bandwidth(MB/s)',
                                directory,
                                f'bw_{data_type}_{node_label}_{ratio}',
                                title=f'{ratio} {data_type} Bandwidth {node_label}')
    generate_stacked_line_chart(df_dict,
                            'Num of Cores',
                            'Latency(ns)',
                            directory,
                            f'lt_{data_type}_{node_label}_{ratio}',
                            title=f'{ratio} {data_type} Latency {node_label}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Process command line arguments.")
    parser.add_argument('-d', '--directory', help='Name of the directory', required=True)
    parser.add_argument('-r', '--ratio', choices=RATIOS, help='Ratio. If omitted, all ratios are processed.')
    parser.add_argument('-t', '--type', choices=TYPES, help='Option: seq or rand. If omitted, both are processed.')

    args = parser.parse_args()

    directory = args.directory
    if not os.path.isdir(directory):
        print(f"Error: '{directory}' is not a valid directory.")
        exit(1)

    ratios = [args.ratio] if args.ratio else RATIOS
    types = [args.type] if args.type else TYPES
    multi = len(ratios) > 1 or len(types) > 1

    for ratio in ratios:
        for data_type in types:
            if multi:
                print(f"\n=== ratio={ratio} type={data_type} ===")
            process_directory(directory, ratio, data_type)

