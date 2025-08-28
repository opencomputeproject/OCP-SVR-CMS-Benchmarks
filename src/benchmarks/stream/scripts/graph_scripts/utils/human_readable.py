import math

import humanize

SHORTER_NUMBERS: dict[str, str] = {"billion": "bil", "million": "mil", "thousand": "k"}


def int_to_human(x: int, fmt: str = "%.0f", replace_long: bool = True) -> str:
    word = humanize.intword(x, fmt)

    if replace_long:
        for long, short in SHORTER_NUMBERS.items():
            word = word.replace(long, short)

    return word


# https://stackoverflow.com/a/65399616
def scientific_notation(x: int) -> str:
    n = math.floor(math.log10(x))

    return f"{x / 10 ** n:.1f}e{n:01d}"
