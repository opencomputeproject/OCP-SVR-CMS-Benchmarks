import pandas as pd

# TODO: Have this eventually be a function that only filters out columns passed by arg
def remove_direction_column(df: pd.DataFrame) -> pd.DataFrame:
    if "Direction" in df.columns:
        df = df.iloc[:, 0:5].drop(["Direction"], axis=1)
    else:
        df = df.iloc[:, 0:4]

    return df
