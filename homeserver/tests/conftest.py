import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import create_app  # noqa: E402
from config import Config  # noqa: E402


@pytest.fixture()
def client(tmp_path):
    cfg = Config(domain="test.local", data_dir=tmp_path)
    with TestClient(create_app(cfg)) as c:
        yield c
