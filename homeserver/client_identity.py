"""Проверка идентичности, ПРЕДЪЯВЛЕННОЙ клиентом серверу (флаш персистенции).

Зеркало клиентской проверки пиров (docs/home-server.md, «Проверка в комнате»),
но на стороне сервера страницы:

- шаг 1 — подпись домашнего сервера на сертификате. Для СВОЕГО домена — свои ключи
  без сети; для чужого — signing_keys с канонического https://<домен>/.well-known/vrweb
  (кэш на сутки, как у клиента);
- шаг 2 — доказательство владения ключом: подпись клиента над предъявленным payload
  (у флаша это строка запроса с ts/nonce — свежесть и одноразовость проверяет вызывающий).

Никаких HTTP-фреймворков: сетевой фетч — stdlib urllib (зовётся из sync-эндпоинтов
FastAPI, которые и так крутятся в thread pool).
"""

from __future__ import annotations

import json
import time
import urllib.request

from keys import ALGORITHM, ServerKeys

KEYS_TTL = 86400
FETCH_TIMEOUT = 5.0

# domain -> {"fetched_at": int, "keys": {key_id: public_key_b64}}
_domain_keys: dict = {}


class IdentityError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def verify_presented_certificate(cert_json: str, signature_b64: str,
                                 own_domain: str, own_keys: ServerKeys) -> dict:
    """Шаг 1: сертификат подписан домашним сервером домена из адреса. Возвращает
    {"address": str, "public_key": b64} или бросает IdentityError."""
    if len(cert_json) > 8192 or len(signature_b64) > 4096:
        raise IdentityError("bad_certificate", "Сертификат подозрительно велик.")
    try:
        cert = json.loads(cert_json)
    except (ValueError, TypeError):
        raise IdentityError("bad_certificate", "certificate_json не парсится.") from None
    if not isinstance(cert, dict) or cert.get("v") != 1:
        raise IdentityError("bad_certificate", "Не сертификат (v != 1).")
    if int(cert.get("expires_at", 0)) <= int(time.time()):
        raise IdentityError("certificate_expired", "Сертификат истёк.")
    address = str(cert.get("address", ""))
    nick, _, domain = address.partition("@")
    if not nick or not domain:
        raise IdentityError("bad_certificate", "Некорректный адрес в сертификате.")
    key_id = str(cert.get("key_id", ""))
    if domain == own_domain:
        keys = {own_keys.KEY_ID: own_keys.public_key_b64}
    else:
        keys = _signing_keys_for(domain)
    public_key = keys.get(key_id, "")
    if public_key == "":
        raise IdentityError("unknown_key", "Ключ %s домена %s недоступен." % (key_id, domain))
    if not ServerKeys.verify_b64(public_key, signature_b64, cert_json.encode("utf-8")):
        raise IdentityError("bad_signature", "Подпись домашнего сервера не сходится.")
    return {"address": address, "public_key": str(cert.get("public_key", ""))}


def verify_proof(public_key_b64: str, payload: bytes, signature_b64: str) -> bool:
    """Шаг 2: владение приватным ключом — подпись клиента (rsa-sha256) над payload."""
    return ServerKeys.verify_b64(public_key_b64, signature_b64, payload)


def _signing_keys_for(domain: str) -> dict:
    """signing_keys чужого домена: свежий кэш -> сеть -> протухший кэш. Источник —
    только канонический https://<домен> (строгая проверка, как у клиента)."""
    entry = _domain_keys.get(domain, {})
    now = int(time.time())
    if entry and now - int(entry.get("fetched_at", 0)) < KEYS_TTL:
        return entry.get("keys", {})
    url = "https://%s/.well-known/vrweb" % domain
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        keys = {}
        for k in data.get("signing_keys", []):
            if isinstance(k, dict) and str(k.get("algorithm", "")) == ALGORITHM:
                kid = str(k.get("key_id", ""))
                if kid:
                    keys[kid] = str(k.get("public_key", ""))
        _domain_keys[domain] = {"fetched_at": now, "keys": keys}
        return keys
    except Exception:
        return entry.get("keys", {})   # сеть недоступна — протухший кэш лучше, чем ничего
