#!/usr/bin/python3 

import pandas as pd
import os
import argparse
import re

def sanitize_tab_name(tab_name):
    illegal_chars_pattern = r'[\\/*?:[\]]'
    sanitized_name = re.sub(illegal_chars_pattern, '_', tab_name)
    return sanitized_name

def csv_to_excel(directory, excel_filename):
    with pd.ExcelWriter(excel_filename) as writer:
        for filename in os.listdir(directory):
            if filename.endswith('.csv'):
                tab_name = re.search('node.*(?=.csv)', filename).group()
                sanitized_tab_name = sanitize_tab_name(tab_name)
                df = pd.read_csv(os.path.join(directory, filename))
                df.to_excel(writer, sheet_name=sanitized_tab_name, index=False)

def main():
    parser = argparse.ArgumentParser(description="Convert CSV files in a directory to an Excel file")
    parser.add_argument('Directory', metavar='Directory', type=str, help='the directory to process')
    parser.add_argument('ExcelFile', metavar='ExcelFile', type=str, help='the output Excel file name')
    args = parser.parse_args()

    csv_to_excel(args.Directory, args.ExcelFile)

if __name__ == "__main__":
    main()

