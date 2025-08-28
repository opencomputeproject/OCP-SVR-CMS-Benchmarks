#!/usr/bin/env python3

import argparse
import pandas as pd
import sys
import re
import io


def process_TPCC_results_v1(filename):
    result = {}
    file = open(filename, 'r')
    Lines = file.readlines()

    # fp_regex = re.compile(r'\d+(\.\d*)?')
    for line in Lines:
        # print(line)
        line = line.strip(' ').strip('\n')
        if line.startswith('Number of threads:'):
            result['Threads'] = int(line.split(':')[1].strip(' '))
        elif line.startswith('transactions:'):
            result['TPS'] = float(line.split('(')[1].split(' ')[0])
        elif line.startswith('queries:'):
            result['QPS'] = float(line.split('(')[1].split(' ')[0])
        elif line.startswith('ignored errors:'):
            result['Ignored_Errors'] = float(line.split('(')[1].split(' ')[0])
        elif line.startswith('95th percentile'):
            result['P95th_percentile'] = float(line.split(':')[1].strip(' '))
    return result


def print_header():
    print("Threads", end=',')
    print("TPS", end=',')
    print("QPS", end=',')
    print("Ignored_Errors", end=',')
    print("P95th percentile", end=',')
    print()


def main():
    parser = argparse.ArgumentParser()      
    parser.add_argument('file', nargs='+', type=argparse.FileType('r'))
    args = parser.parse_args()

    # print(args.file)
    printheaders = False
    if (len(args.file) > 1):
        printheaders = True

    df = pd.DataFrame(columns=['Threads', 'TPS', 'QPS', 'Ignored_Errors', 'P95th_percentile'])
    for f in args.file:
        df.loc[len(df)] = process_TPCC_results_v1(f.name)
    df = df.sort_values(by=['Threads'])
    df.to_csv("tpcc_results.csv", index=False, header=printheaders)


if __name__ == '__main__':
    main()
