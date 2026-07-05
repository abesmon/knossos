"""HTTP-контур персональных пространств (docs/personal-spaces.md) и флаша
персистенции (docs/page-persistence.md, reference implementation).

Клиент ↔ домашний сервер (минимальный контракт):
  GET  /api/v1/spaces/home         — актуальный адрес СВОЕГО пространства (лениво создаёт)
  POST /api/v1/spaces/home/rotate  — сменить slug (отзыв розданных ссылок)

Страница и персистенция (контракт страничного сервера, для любых клиентов):
  GET  /s/{slug}                   — страница пространства (гейт по политике)
  GET  /api/v1/spaces/flush        — capability-запрос (?url=…&address=…)
  POST /api/v1/spaces/flush        — флаш дельты эфемерного слоя

Auth флаша — два пути: Bearer-токен (локальный пользователь этого сервера; так входит
владелец) или федеративная пара сертификат+proof (редактор с чужого домашнего сервера).
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import time

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

import accounts
import client_identity
import spaces
import vrweb_scene
from api import api_error, bearer_user

PROOF_PREFIX = b"vrweb-flush.v1:"
TS_WINDOW_SEC = 300

# Анти-replay: nonce, виденные в окне свежести (nonce -> deadline). Память процесса —
# при рестарте окно ts всё равно отсечёт старые подписи.
_seen_nonces: dict[str, float] = {}

router = APIRouter()


# --- Клиент ↔ домашний сервер ---

def _home_response(request: Request, space: sqlite3.Row) -> dict:
    return {"url": spaces.space_url(request.app.state.cfg, space), "name": space["name"]}


@router.get("/api/v1/spaces/home")
def home_space(request: Request) -> dict:
    st = request.app.state
    user = bearer_user(request)
    return _home_response(request, spaces.get_or_create_home(st.db, st.cfg, user))


@router.post("/api/v1/spaces/home/rotate")
def rotate_home_space(request: Request) -> dict:
    st = request.app.state
    user = bearer_user(request)
    space = spaces.get_or_create_home(st.db, st.cfg, user)
    spaces.rotate_slug(st.db, st.cfg, space["id"])
    return _home_response(request, spaces.get_or_create_home(st.db, st.cfg, user))


# --- Страница пространства ---

def _requester_address(request: Request) -> str:
    """Локальный предъявитель страницы: Bearer (Godot-клиент) или cookie (браузер)."""
    st = request.app.state
    auth = request.headers.get("authorization", "")
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else \
        request.cookies.get("vrweb_session", "")
    if token == "":
        return ""
    user = accounts.session_user(st.db, token, st.cfg.session_ttl_days)
    return "%s@%s" % (user["nickname"], st.cfg.domain) if user is not None else ""


@router.get("/s/{slug}", response_class=HTMLResponse)
def space_page(request: Request, slug: str) -> HTMLResponse:
    st = request.app.state
    space = spaces.space_by_slug(st.db, slug)
    if space is None:
        raise api_error(404, "not_found", "Пространство не найдено.")
    if not spaces.access_allowed(st.db, st.cfg, st.hub, space, _requester_address(request)):
        # Отличимо от 404 сознательно: гостю понятен UX «хозяина нет дома».
        raise api_error(403, "space_closed", "Хозяина нет дома — пространство закрыто.")
    return HTMLResponse(spaces.page_html(st.cfg, space))


# --- Персистенция: capability + флаш ---

@router.get(spaces.FLUSH_PATH)
def flush_capability(request: Request, url: str = "", address: str = "") -> dict:
    st = request.app.state
    space = spaces.space_by_url(st.db, st.cfg, url)
    if space is None:
        raise api_error(404, "not_found", "Страница не хостится этим сервером.")
    out = {
        "v": 1,
        "rev": vrweb_scene.rev_of(str(space["content"])),
        "identity_required": True,
        "policy": "allowlist",
        "accepts_kinds": list(vrweb_scene.ACCEPTED_KINDS),
        "max_objects": vrweb_scene.MAX_OBJECTS,
        "max_bytes": vrweb_scene.MAX_BYTES,
    }
    if address != "":
        # Необязывающая подсказка для UI (не аутентифицирована) — решение принимает POST.
        out["writable"] = spaces.can_edit(st.db, st.cfg, space, address.strip().lower())
    return out


@router.post(spaces.FLUSH_PATH)
async def flush(request: Request) -> dict:
    st = request.app.state
    raw = await request.body()
    if len(raw) > vrweb_scene.MAX_BYTES:
        raise api_error(413, "too_large", "Запрос больше %d байт." % vrweb_scene.MAX_BYTES)
    try:
        body = json.loads(raw)
    except (ValueError, TypeError):
        raise api_error(400, "bad_request", "Тело — не JSON.") from None
    if not isinstance(body, dict) or body.get("v") != 1:
        raise api_error(415, "bad_version", "Поддерживается только v=1.")
    payload_str = body.get("payload", "")
    if not isinstance(payload_str, str) or payload_str == "":
        raise api_error(400, "bad_request", "Нет payload.")
    try:
        payload = json.loads(payload_str)
    except (ValueError, TypeError):
        raise api_error(400, "bad_request", "payload не парсится.") from None
    if not isinstance(payload, dict) or payload.get("v") != 1:
        raise api_error(415, "bad_version", "payload: поддерживается только v=1.")

    address = _flush_identity(request, body, payload_str)

    space = spaces.space_by_url(st.db, st.cfg, str(payload.get("url", "")))
    if space is None:
        raise api_error(404, "not_found", "Страница не хостится этим сервером.")
    if not spaces.can_edit(st.db, st.cfg, space, address):
        raise api_error(403, "forbidden", "Адресу %s запись в это пространство не разрешена." % (address or "аноним"))

    current_rev = vrweb_scene.rev_of(str(space["content"]))
    if str(payload.get("base_rev", "")) != current_rev:
        # Version skew: клиент перезагружает базу и пересчитывает дельту диффом.
        err = api_error(409, "rev_mismatch", "База изменилась — пересоберите дельту.")
        err.detail["current_rev"] = current_rev
        raise err

    objects = payload.get("objects", [])
    if not isinstance(objects, list) or len(objects) > vrweb_scene.MAX_OBJECTS:
        raise api_error(413, "too_large", "objects: максимум %d." % vrweb_scene.MAX_OBJECTS)

    applied = vrweb_scene.apply_objects(str(space["content"]), objects)
    if applied["changed"]:
        spaces.save_content(st.db, space["id"], applied["markup"])
    results: dict = applied["results"]
    outcomes = {r["outcome"] for r in results.values()} or {"rejected"}
    status = "applied" if outcomes == {"applied"} else \
        ("rejected" if "applied" not in outcomes else "partial")
    return {
        "v": 1,
        "status": status,
        "rev": vrweb_scene.rev_of(applied["markup"]),
        "results": results,
    }


def _flush_identity(request: Request, body: dict, payload_str: str) -> str:
    """Кто подписал флаш. Bearer локального пользователя ИЛИ федеративная пара
    сертификат + proof (подпись над "vrweb-flush.v1:" + payload, свежесть по ts/nonce)."""
    st = request.app.state
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        user = accounts.session_user(st.db, auth[7:].strip(), st.cfg.session_ttl_days)
        if user is None:
            raise api_error(401, "invalid_token", "Токен не найден или истёк.")
        return "%s@%s" % (user["nickname"], st.cfg.domain)

    identity = body.get("identity", {})
    proof_sig = str(body.get("proof_signature", ""))
    if not isinstance(identity, dict) or proof_sig == "":
        raise api_error(401, "identity_required", "Нужен Bearer-токен или identity + proof_signature.")
    try:
        cert = client_identity.verify_presented_certificate(
            str(identity.get("certificate_json", "")), str(identity.get("signature", "")),
            st.cfg.domain, st.keys)
    except client_identity.IdentityError as e:
        raise api_error(401, e.code, e.message) from None
    if not client_identity.verify_proof(cert["public_key"],
                                        PROOF_PREFIX + payload_str.encode("utf-8"), proof_sig):
        raise api_error(401, "bad_proof", "Подпись запроса не сходится с ключом сертификата.")

    # Свежесть и одноразовость подписанного payload (анти-replay).
    payload = json.loads(payload_str)
    now = time.time()
    ts = payload.get("ts", 0)
    if not isinstance(ts, (int, float)) or abs(now - float(ts)) > TS_WINDOW_SEC:
        raise api_error(401, "stale_proof", "ts вне окна ±%d с." % TS_WINDOW_SEC)
    nonce = str(payload.get("nonce", ""))
    if len(nonce) < 8:
        raise api_error(401, "bad_nonce", "Слишком короткий nonce.")
    nonce_key = hashlib.sha256((cert["address"] + ":" + nonce).encode("utf-8")).hexdigest()
    for k in [k for k, dl in _seen_nonces.items() if dl < now]:
        _seen_nonces.pop(k, None)
    if nonce_key in _seen_nonces:
        raise api_error(401, "replay", "Этот nonce уже использован.")
    _seen_nonces[nonce_key] = now + TS_WINDOW_SEC * 2
    return cert["address"]
