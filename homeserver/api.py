"""REST API (v1) и discovery /.well-known/vrweb.

Контракт — docs/home-server.md. Ошибки всюду {"error": {"code", "message"}}
(хэндлер — в app.py). Auth — Bearer-токен той же сессии, что и cookie веб-морды.
"""

from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

import accounts
import identity

# Версионированные капабилити монолита; клиент сверяет со своими — работает пересечение.
FEATURES = ["identity.v1", "signaling.v1"]


def api_error(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code=status, detail={"code": code, "message": message})


def bearer_user(request: Request) -> sqlite3.Row:
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        raise api_error(401, "missing_token", "Нужен заголовок Authorization: Bearer <token>.")
    st = request.app.state
    user = accounts.session_user(st.db, auth[7:].strip(), st.cfg.session_ttl_days)
    if user is None:
        raise api_error(401, "invalid_token", "Токен не найден или истёк.")
    return user


class Credentials(BaseModel):
    nickname: str
    password: str


class CertifyRequest(BaseModel):
    public_key: str  # raw Ed25519 (32 байта) в base64


router = APIRouter()


@router.get("/.well-known/vrweb")
def well_known(request: Request) -> dict:
    st = request.app.state
    return {
        "server": {
            "software": "knossos-homeserver",
            "version": st.version,
            "domain": st.cfg.domain,
            "name": st.cfg.name,
        },
        "features": FEATURES,
        "config": {
            "signaling_url": st.cfg.effective_signaling_url(),
            "homepage": st.cfg.effective_homepage(),
        },
        "signing_keys": [
            {"key_id": st.keys.KEY_ID, "algorithm": "ed25519", "public_key": st.keys.public_key_b64}
        ],
    }


def _session_response(request: Request, user: sqlite3.Row) -> dict:
    st = request.app.state
    token = accounts.create_session(st.db, user["id"], st.cfg.session_ttl_days)
    return {"address": f"{user['nickname']}@{st.cfg.domain}", "access_token": token}


@router.post("/api/v1/register")
def register(request: Request, creds: Credentials) -> dict:
    st = request.app.state
    if not st.cfg.registration_open:
        raise api_error(403, "registration_closed", "Регистрация на этом сервере закрыта.")
    try:
        user = accounts.register(st.db, creds.nickname, creds.password)
    except accounts.AccountError as e:
        raise api_error(400, e.code, e.message) from None
    return _session_response(request, user)


@router.post("/api/v1/login")
def login(request: Request, creds: Credentials) -> dict:
    try:
        user = accounts.authenticate(request.app.state.db, creds.nickname, creds.password)
    except accounts.AccountError as e:
        raise api_error(401, e.code, e.message) from None
    return _session_response(request, user)


@router.post("/api/v1/logout")
def logout(request: Request, user: sqlite3.Row = Depends(bearer_user)) -> dict:
    auth = request.headers["authorization"]
    accounts.revoke_session(request.app.state.db, auth[7:].strip())
    return {"ok": True}


@router.get("/api/v1/account")
def account(request: Request, user: sqlite3.Row = Depends(bearer_user)) -> dict:
    return {
        "address": f"{user['nickname']}@{request.app.state.cfg.domain}",
        "nickname": user["nickname"],
        "created_at": user["created_at"],
    }


@router.post("/api/v1/identity/certify")
def certify(request: Request, body: CertifyRequest, user: sqlite3.Row = Depends(bearer_user)) -> dict:
    st = request.app.state
    address = f"{user['nickname']}@{st.cfg.domain}"
    try:
        result = identity.issue_certificate(st.keys, address, body.public_key, st.cfg.cert_ttl_days)
    except identity.BadPublicKey as e:
        raise api_error(400, "bad_public_key", str(e)) from None
    accounts.record_user_key(st.db, user["id"], result["certificate"]["public_key"])
    return result
