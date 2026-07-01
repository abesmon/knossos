"""Подписывающий ключ сервера (Ed25519).

Ключ создаётся при первом запуске и живёт в `data/signing_key.pem`. Его публичная
часть анонсируется в /.well-known/vrweb (`signing_keys`) — так чужие участники
федерации проверяют подписи сертификатов этого сервера. Потеря ключа делает ранее
выданные сертификаты непроверяемыми: бэкапить вместе с БД.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


def canonical_json(obj) -> bytes:
    """Каноническая сериализация для подписи: sorted keys, компактно, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


class ServerKeys:
    KEY_ID = "ed25519:1"  # при ротации появятся ed25519:2 и т.д.

    def __init__(self, data_dir: Path):
        pem_path = data_dir / "signing_key.pem"
        data_dir.mkdir(parents=True, exist_ok=True)
        if pem_path.is_file():
            self._private = serialization.load_pem_private_key(pem_path.read_bytes(), password=None)
        else:
            self._private = Ed25519PrivateKey.generate()
            pem = self._private.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
            pem_path.write_bytes(pem)
            pem_path.chmod(0o600)

    @property
    def public_key_b64(self) -> str:
        raw = self._private.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        return base64.b64encode(raw).decode()

    def sign_b64(self, data: bytes) -> str:
        return base64.b64encode(self._private.sign(data)).decode()

    @staticmethod
    def verify_b64(public_key_b64: str, signature_b64: str, data: bytes) -> bool:
        """Проверка подписи по публичному ключу — то, что делает чужой участник федерации."""
        try:
            key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64))
            key.verify(base64.b64decode(signature_b64), data)
            return True
        except Exception:
            return False
