"""Точка входа домашнего сервера: python server.py (конфиг — homeserver.cfg / env)."""

import uvicorn

from app import create_app
from config import load_config

cfg = load_config()
app = create_app(cfg)

if __name__ == "__main__":
    uvicorn.run(app, host=cfg.host, port=cfg.port)
