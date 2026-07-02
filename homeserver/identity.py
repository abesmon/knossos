"""Сертификаты идентичности — ядро роли «центр валидации личности».

Сервер подписывает своим RSA-ключом связку «адрес пользователя ↔ его публичный
ключ». Пир в комнате предъявляет сертификат + доказывает владение ключом (подписывает
челлендж); проверяющий берёт signing_keys домена из /.well-known/vrweb и валидирует
обе подписи. Формат и протокол — docs/home-server.md.

Наружу сертификат ходит в двух видах: `certificate` (объект — для отображения) и
`certificate_json` (каноническая строка — именно над ней стоит подпись). Клиенты
хранят и пересылают строку: проверяющему не нужно воспроизводить каноническую
сериализацию, он верифицирует подпись над сырыми байтами и парсит поля из них же.
"""

from __future__ import annotations

import base64
import json
import time

from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import load_der_public_key

from keys import ServerKeys, canonical_json


class BadPublicKey(Exception):
    pass


MIN_CLIENT_KEY_BITS = 2048


def _validate_client_key(public_key_b64: str) -> str:
    """Ключ клиента — RSA (DER SubjectPublicKeyInfo) в base64; возвращает нормализованный base64."""
    try:
        der = base64.b64decode(public_key_b64, validate=True)
        key = load_der_public_key(der)
        if not isinstance(key, rsa.RSAPublicKey) or key.key_size < MIN_CLIENT_KEY_BITS:
            raise ValueError
    except Exception:
        raise BadPublicKey(
            "public_key должен быть RSA (минимум %d бит) в base64(DER SPKI)" % MIN_CLIENT_KEY_BITS
        ) from None
    return base64.b64encode(der).decode()


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
    cert_json = canonical_json(certificate)
    return {
        "certificate": certificate,
        "certificate_json": cert_json.decode("utf-8"),
        "signature": keys.sign_b64(cert_json),
        "key_id": keys.KEY_ID,
    }


def verify_certificate_json(cert_json: str, signature_b64: str, server_public_key_b64: str) -> bool:
    """Проверка на стороне любого участника федерации (сервер сам её не зовёт).

    Принимает сертификат строкой — той самой, над которой стоит подпись.
    """
    try:
        certificate = json.loads(cert_json)
    except Exception:
        return False
    if not isinstance(certificate, dict) or certificate.get("v") != 1:
        return False
    if certificate.get("expires_at", 0) <= int(time.time()):
        return False
    return ServerKeys.verify_b64(server_public_key_b64, signature_b64, cert_json.encode("utf-8"))
