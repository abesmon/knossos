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
import api
import presence
import spaces

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
    ctx.update(cfg=st.cfg, version=st.version, features=api.features(st.cfg), request=request)
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


# --- Presence (docs/presence.md): та же выдача, что /api/v1/presence, для удобства
# в браузере. Подчиняется тому же конфигу доступа: authenticated — только под логином. ---

@router.get("/presence", response_class=HTMLResponse)
def presence_page(request: Request):
    st = request.app.state
    if not st.cfg.presence_enabled:
        return RedirectResponse("/", status_code=303)
    if st.cfg.presence_access == "authenticated" and _cookie_user(request) is None:
        return RedirectResponse("/login", status_code=303)
    return _page(request, "presence.html", rooms=presence.snapshot(st.cfg, st.hub))


# --- Персональное пространство (docs/personal-spaces.md): управление — здесь, на
# веб-морде («иное админ-устройство»), клиенту в игре об этом знать не нужно. ---

def _space_page(request: Request, user: sqlite3.Row) -> HTMLResponse:
    st = request.app.state
    space = spaces.get_or_create_home(st.db, st.cfg, user)
    return _page(request, "space.html", user=user, space=space,
                 url=spaces.space_url(st.cfg, space),
                 editors=spaces.editors(st.db, space["id"]))


@router.get("/space", response_class=HTMLResponse)
def space_page(request: Request):
    user = _cookie_user(request)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    return _space_page(request, user)


@router.post("/space/settings")
def space_settings(request: Request, name: str = Form(""), policy: str = Form("")):
    user = _cookie_user(request)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    st = request.app.state
    space = spaces.get_or_create_home(st.db, st.cfg, user)
    spaces.update_settings(st.db, space["id"], name, policy)
    return RedirectResponse("/space", status_code=303)


@router.post("/space/rotate")
def space_rotate(request: Request):
    user = _cookie_user(request)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    st = request.app.state
    space = spaces.get_or_create_home(st.db, st.cfg, user)
    spaces.rotate_slug(st.db, st.cfg, space["id"])
    return RedirectResponse("/space", status_code=303)


@router.post("/space/editors/add")
def space_editor_add(request: Request, address: str = Form("")):
    user = _cookie_user(request)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    st = request.app.state
    space = spaces.get_or_create_home(st.db, st.cfg, user)
    spaces.add_editor(st.db, space["id"], address)
    return RedirectResponse("/space", status_code=303)


@router.post("/space/editors/remove")
def space_editor_remove(request: Request, address: str = Form("")):
    user = _cookie_user(request)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    st = request.app.state
    space = spaces.get_or_create_home(st.db, st.cfg, user)
    spaces.remove_editor(st.db, space["id"], address)
    return RedirectResponse("/space", status_code=303)


@router.post("/logout")
def logout(request: Request):
    token = request.cookies.get(COOKIE)
    if token:
        accounts.revoke_session(request.app.state.db, token)
    resp = RedirectResponse("/", status_code=303)
    resp.delete_cookie(COOKIE)
    return resp
