"""Сборка монолита: домашний сервер (веб-морда + REST + discovery) + сигналинг.

Сущности остаются раздельными модулями (api/webui/accounts против signaling) и
встречаются только здесь — см. docs/home-server.md, раздел «разные сущности,
один процесс».
"""

from __future__ import annotations

import json
import logging

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

import api
import webui
from config import Config
from db import Database
from keys import ServerKeys
from signaling import SignalingHub

VERSION = "0.1.0"


def create_app(cfg: Config) -> FastAPI:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    app = FastAPI(title="knossos-homeserver", version=VERSION)
    app.state.cfg = cfg
    app.state.version = VERSION
    app.state.db = Database(cfg.data_dir / "homeserver.db")
    app.state.keys = ServerKeys(cfg.data_dir)
    app.state.hub = SignalingHub()

    @app.exception_handler(HTTPException)
    async def http_error(request: Request, exc: HTTPException):
        detail = exc.detail if isinstance(exc.detail, dict) else {"code": "error", "message": str(exc.detail)}
        return JSONResponse(status_code=exc.status_code, content={"error": detail})

    app.include_router(api.router)
    app.include_router(webui.router)

    @app.websocket("/signal")
    async def signal(ws: WebSocket):
        await ws.accept()
        hub: SignalingHub = ws.app.state.hub
        peer = await hub.connect(ws.send_json)
        try:
            while True:
                raw = await ws.receive_text()
                try:
                    msg = json.loads(raw)
                except (ValueError, TypeError):
                    continue
                if isinstance(msg, dict):
                    await hub.handle(peer, msg)
        except WebSocketDisconnect:
            pass
        finally:
            await hub.disconnect(peer)

    return app
