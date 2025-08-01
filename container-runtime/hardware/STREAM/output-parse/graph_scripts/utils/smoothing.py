import numpy as np
import pandas as pd
from scipy.interpolate import make_interp_spline


def smooth_line(x: pd.Index, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    x_new = np.linspace(x.min(), x.max(), 300)
    spline = make_interp_spline(x, y)
    y_smooth = spline(x_new)

    return x_new, y_smooth
