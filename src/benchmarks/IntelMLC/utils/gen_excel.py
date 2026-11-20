#!/usr/bin/python3 

import pandas as pd
import os
import argparse
import re
import hashlib

EXCEL_MAX_SHEET_NAME_LEN = 31

def sanitize_tab_name(tab_name):
    illegal_chars_pattern = r'[\\/*?:[\]]'
    sanitized_name = re.sub(illegal_chars_pattern, '_', tab_name)
    return sanitized_name

def build_tab_name(filename, seen):
    match = re.search('node.*(?=.csv)', filename)
    raw = match.group() if match else filename[:-len('.csv')]
    tab_name = sanitize_tab_name(raw)
    if len(tab_name) > EXCEL_MAX_SHEET_NAME_LEN or tab_name in seen:
        suffix = f'_{hashlib.md5(raw.encode()).hexdigest()[:6]}'
        tab_name = tab_name[:EXCEL_MAX_SHEET_NAME_LEN - len(suffix)] + suffix
    seen.add(tab_name)
    return tab_name

def csv_to_excel(directory, excel_filename):
    seen = set()
    with pd.ExcelWriter(excel_filename) as writer:
        for filename in os.listdir(directory):
            if filename.endswith('.csv'):
                tab_name = build_tab_name(filename, seen)
                df = pd.read_csv(os.path.join(directory, filename))
                df.to_excel(writer, sheet_name=tab_name, index=False)

def main():
    parser = argparse.ArgumentParser(description="Convert CSV files in a directory to an Excel file")
    parser.add_argument('Directory', metavar='Directory', type=str, help='the directory to process')
    parser.add_argument('ExcelFile', metavar='ExcelFile', type=str, help='the output Excel file name')
    args = parser.parse_args()

    csv_to_excel(args.Directory, args.ExcelFile)

if __name__ == "__main__":
    main()

