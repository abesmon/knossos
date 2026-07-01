"""Сертификаты идентичности — ядро роли «центр валидации личности».

Сервер подписывает своим Ed25519-ключом связку «адрес пользователя ↔ его публичный
ключ». Пир в комнате предъявляет сертификат + доказывает владение ключом (подписывает
челлендж); проверяющий берёт signing_keys домена из /.well-known/vrweb и валидирует
обе подписи. Формат и протокол — docs/home-server.md.
"""

from __future__ import annotations

import base64
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from keys import ServerKeys, canonical_json


class BadPublicKey(Exception):
    pass


def _validate_client_key(public_key_b64: str) -> str:
    """Ключ клиента — raw Ed25519 (32 байта) в base64; возвращает нормализованный base64."""
    try:
        raw = base64.b64decode(public_key_b64, validate=True)
        Ed25519PublicKey.from_public_bytes(raw)
    except Exception:
        raise BadPublicKey("public_key должен быть raw Ed25519 (32 байта) в base64") from None
    return base64.b64encode(raw).decode()


def issue_certificate(
    keys: ServerKeys, address: str, public_key_b64: str, ttl_days: int
) -> dict:
    now = int(time.time())
    certificate = {
        "v": 1,
        "address": address,
        "public_key": _validate_client_key(public_key_b64),
        "issued_at": now,
        "expires_at": now + ttl_days * 86400,
        "key_id": keys.KEY_ID,
    }
    return {
        "certificate": certificate,
        "signature": keys.sign_b64(canonical_json(certificate)),
        "key_id": keys.KEY_ID,
    }


def verify_certificate(certificate: dict, signature_b64: str, server_public_key_b64: str) -> bool:
    """Проверка на стороне любого участника федерации (сервер сам её не зовёт)."""
    if certificate.get("v") != 1:
        return False
    if certificate.get("expires_at", 0) <= int(time.time()):
        return False
    return ServerKeys.verify_b64(server_public_key_b64, signature_b64, canonical_json(certificate))
