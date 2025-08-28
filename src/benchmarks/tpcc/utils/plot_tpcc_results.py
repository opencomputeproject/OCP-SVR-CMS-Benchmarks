#!/usr/bin/env python3

import sys
import pandas as pd
import matplotlib.pyplot as plt

'''
This script plots the 'tpcc_results.csv' file created by running 'plot_tpcc_results.py' first
'''

if len(sys.argv) < 2:
    print("Please provide the CSV file as a command-line argument.")
    sys.exit(1)

csv_file = sys.argv[1]

try:
    # Read the CSV file
    data = pd.read_csv(csv_file)

    # Extract the required columns
    threads = data['Threads']
    tps = data['TPS']
    qps = data['QPS']
    p95th_percentile = data['P95th_percentile']

    # Create the plots
    plt.figure(figsize=(10, 6))

    # Threads vs TPS
    plt.plot(threads, tps, marker='o', linestyle='-', color='blue')
    plt.xlabel('Number of Sysbench Clients')
    plt.ylabel('Transactions per Second (TPS)')
    plt.title('Transactions per Second')
    plt.savefig('threads_vs_tps.png')
    plt.close()

    # Threads vs QPS
    plt.figure(figsize=(10, 6))
    plt.plot(threads, qps, marker='o', linestyle='-', color='green')
    plt.xlabel('Number of Sysbench Clients')
    plt.ylabel('Queries per Second (QPS)')
    plt.title('Queries per Second (QPS)')
    plt.savefig('threads_vs_qps.png')
    plt.close()

    # Threads vs P95th_percentile
    plt.figure(figsize=(10, 6))
    plt.plot(threads, p95th_percentile, marker='o', linestyle='-', color='red')
    plt.xlabel('Number of Sysbench Clients')
    plt.ylabel('P95 Latency (milliseconds)')
    plt.title('P95 Latency (milliseconds)')
    plt.savefig('threads_vs_p95th_percentile.png')
    plt.close()

    print("Plots saved successfully.")
except FileNotFoundError:
    print(f"CSV file '{csv_file}' not found.")
except Exception as e:
    print("An error occurred:", e)
