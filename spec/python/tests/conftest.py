import os

import pytest


def pytest_collection_modifyitems(config, items) -> None:
    shard = os.environ.get("ZEN_UI_PYTEST_SHARD")
    if shard is None:
        return
    try:
        index, count = map(int, shard.split("/"))
        if not 1 <= index <= count:
            raise ValueError
    except ValueError:
        raise pytest.UsageError("ZEN_UI_PYTEST_SHARD must be INDEX/COUNT with 1 <= INDEX <= COUNT")

    deselected = [item for position, item in enumerate(items) if position % count != index - 1]
    items[:] = items[index - 1::count]
    config.hook.pytest_deselected(items=deselected)
