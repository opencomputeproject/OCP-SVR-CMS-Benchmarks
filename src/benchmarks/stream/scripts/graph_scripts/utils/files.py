import argparse
import platform
from datetime import datetime
from pathlib import Path


def file_exists(file: str) -> Path:
    path = Path(file)

    if not path.is_file():
        raise argparse.ArgumentTypeError(f"File '{file}' does not exist.")

    return path


# {uname}_stream_{NUMA}_{yyyymmdd}.csv
# {uname}_stream_{yyyymmdd}.csv
def dump_file_name(numa_nodes: str | None = None) -> str:
    platform_name = platform.system()
    now = datetime.now().strftime(r"%Y%m%d")

    return (
        f"{platform_name}_stream_{numa_nodes}_{now}.csv"
        if numa_nodes
        else f"{platform_name}_stream_{now}.csv"
    )
