"""Веб-морда: регистрация, логин, страница аккаунта.

Серверный рендеринг (Jinja2), сессия — тот же токен, что у REST, но в HttpOnly-cookie.
Флаг secure на cookie не ставим: в проде сервер живёт за reverse-proxy с TLS, а локальная
разработка идёт по http.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

import accounts
from api import FEATURES

COOKIE = "vrweb_session"

templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
templates.env.filters["timestamp"] = (
    lambda ts: datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M")
)
router = APIRouter()


def _cookie_user(request: Request) -> sqlite3.Row | None:
    token = request.cookies.get(COOKIE)
    if not token:
        return None
    st = request.app.state
    return accounts.session_user(st.db, token, st.cfg.session_ttl_days)


def _page(request: Request, name: str, **ctx) -> HTMLResponse:
    st = request.app.state
    ctx.setdefault("user", _cookie_user(request))
    ctx.update(cfg=st.cfg, version=st.version, features=FEATURES, request=request)
    return templates.TemplateResponse(request, name, ctx)


def _login_redirect(request: Request, user: sqlite3.Row) -> RedirectResponse:
    st = request.app.state
    token = accounts.create_session(st.db, user["id"], st.cfg.session_ttl_days)
    resp = RedirectResponse("/account", status_code=303)
    resp.set_cookie(
        COOKIE, token, max_age=st.cfg.session_ttl_days * 86400, httponly=True, samesite="lax"
    )
    return resp


@router.get("/", response_class=HTMLResponse)
def index(request: Request):
    return _page(request, "index.html")


@router.get("/register", response_class=HTMLResponse)
def register_form(request: Request):
    return _page(request, "register.html", error=None)


@router.post("/register", response_class=HTMLResponse)
def register_submit(request: Request, nickname: str = Form(...), password: str = Form(...)):
    st = request.app.state
    if not st.cfg.registration_open:
        return _page(request, "register.html", error="Регистрация на этом сервере закрыта.")
    try:
        user = accounts.register(st.db, nickname, password)
    except accounts.AccountError as e:
        return _page(request, "register.html", error=e.message)
    return _login_redirect(request, user)


@router.get("/login", response_class=HTMLResponse)
def login_form(request: Request):
    return _page(request, "login.html", error=None)


@router.post("/login", response_class=HTMLResponse)
def login_submit(request: Request, nickname: str = Form(...), password: str = Form(...)):
    try:
        user = accounts.authenticate(request.app.state.db, nickname, password)
    except accounts.AccountError as e:
        return _page(request, "login.html", error=e.message)
    return _login_redirect(request, user)


@router.get("/account", response_class=HTMLResponse)
def account_page(request: Request):
    user = _cookie_user(request)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    keys = accounts.user_keys(request.app.state.db, user["id"])
    return _page(request, "account.html", user=user, keys=keys)


@router.post("/logout")
def logout(request: Request):
    token = request.cookies.get(COOKIE)
    if token:
        accounts.revoke_session(request.app.state.db, token)
    resp = RedirectResponse("/", status_code=303)
    resp.delete_cookie(COOKIE)
    return resp
