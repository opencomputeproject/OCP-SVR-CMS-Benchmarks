#!/usr/bin/python3 

import os
import pandas as pd
import re
import matplotlib.pyplot as plt
from scipy.interpolate import make_interp_spline
import numpy as np
import argparse


file_patterns = {
    'w21_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W21.seq.(?:10|25|50).csv|bw_ramp.results.node_\d+.R.seq.100:0|bw_ramp.results.node_\d+.R.seq.0:100',
    'w23_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W23.seq.(?:10|25|50).csv',
    'w27_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W27.seq.(?:10|25|50).csv',
    'w21_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W21.rand.(?:10|25|50).csv|bw_ramp.results.node_\d+.R.rand.100:0|bw_ramp.results.node_\d+.R.rand.0:100',
    'w23_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W23.rand.(?:10|25|50).csv',
    'w27_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W27.rand.(?:10|25|50).csv',
}

# We need to make sure not to include 100:0/0:100 files here as they only have one node.
# and this regex is just used to pull the nodes from the filename.
node_file_patterns = {
    'w21_seq': r'bw_ramp_interleave.results.node_\d+.node_\d+.W21.seq.(?:10|25|50).csv',
    'w23_seq': file_patterns['w23_seq'],
    'w27_seq': file_patterns['w27_seq'],
    'w21_rand': r'bw_ramp_interleave.results.node_\d+.node_\d+.W21.rand.(?:10|25|50).csv',
    'w23_rand': file_patterns['w23_rand'],
    'w27_rand': file_patterns['w27_rand']
}

def read_csv_files(search_dir, regex_pattern=r'(.+)\.csv'):
    csv_files = [file for file in os.listdir(search_dir) if re.match(regex_pattern, file)]
    print(f'files: {csv_files}')
    data_dict = {}

    for file in csv_files:
        df = pd.read_csv(file)
        data_dict[file] = df

    return data_dict


def generate_stacked_line_chart(data_dict, x_column, y_column, image_name, title='Stacked Line Chart'):
    plt.figure(figsize=(10, 6))

    for filename, dataframe in data_dict.items():
        x = dataframe[x_column]
        y = dataframe[y_column]

        # Perform cubic spline interpolation
        x_new = np.linspace(x.min(), x.max(), 300)
        spline = make_interp_spline(x, y)
        y_smooth = spline(x_new)
        
        node = dataframe['Node'].iloc[0]
        cxl_ratio = dataframe['DRAM:CXL Ratio'].iloc[0]
        label = f"{node} {cxl_ratio}"
        plt.plot(x_new, y_smooth, label=label)

    plt.xlabel(x_column)
    plt.ylabel(y_column)
    plt.title(title)
    plt.legend()
    plt.savefig(f'{image_name}.png')
    plt.show()
    
    
def extract_nodes_from_filenames(directory, regex_pattern):
    pattern = re.compile(regex_pattern)
    for filename in os.listdir(directory):
        match = re.search(pattern, filename)
        if match:
            node_values = re.findall(r'node_(\d+)', filename)
            if len(node_values) == 2:
                A = int(node_values[0])
                B = int(node_values[1])
                return A, B
    return None, None


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Process command line arguments.")
    parser.add_argument('-d', '--directory', help='Name of the directory', required=True)
    parser.add_argument('-r', '--ratio', choices=['w21', 'w23', 'w27'], help='Ratio', required=True)
    parser.add_argument('-t', '--type', choices=['seq', 'rand'], help='Option: seq or rand', required=True)
    
    args = parser.parse_args()

    directory = args.directory
    if not os.path.isdir(directory):
        print(f"Error: '{directory}' is not a valid directory.")
        exit(1)

    ratio = args.ratio.lower()
    data_type = args.type.lower()
    
    df_dict = read_csv_files(directory, file_patterns[f'{ratio}_{data_type}'])
    nodes = extract_nodes_from_filenames(directory, node_file_patterns[f'{ratio}_{data_type}'])
    generate_stacked_line_chart(df_dict, 
                                'Num of Cores', 
                                'Bandwidth(MB/s)',
                                f'bw_{data_type}_node{nodes[0]}:node{nodes[1]}_{data_type}_{ratio}',
                                title=f'{ratio} {data_type} Bandwidth node{nodes[0]}:node{nodes[1]}')
    generate_stacked_line_chart(df_dict, 
                            'Num of Cores', 
                            'Latency(ns)',
                            f'lt_{data_type}_node{nodes[0]}:node{nodes[1]}_{data_type}_{ratio}',
                            title=f'{ratio} {data_type} Latency node{nodes[0]}:node{nodes[1]}')

