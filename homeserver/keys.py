"""Подписывающий ключ сервера (RSA-2048, подпись PKCS#1 v1.5 + SHA-256).

Ключ создаётся при первом запуске и живёт в `data/signing_key.pem`. Его публичная
часть анонсируется в /.well-known/vrweb (`signing_keys`) — так чужие участники
федерации проверяют подписи сертификатов этого сервера. Потеря ключа делает ранее
выданные сертификаты непроверяемыми: бэкапить вместе с БД.

Почему RSA, а не Ed25519: проверять подписи должен в том числе Godot-клиент, а его
Crypto/CryptoKey (mbedTLS) умеют только RSA (и SHA-256 максимум — Ed25519 требует
SHA-512). Поле `algorithm` в signing_keys версионирует выбор: появление Ed25519 в
клиенте — это новый `algorithm`/`key_id`, а не слом формата.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


ALGORITHM = "rsa-sha256"  # RSA PKCS#1 v1.5 поверх SHA-256; ключи — base64(DER SPKI)


def canonical_json(obj) -> bytes:
    """Каноническая сериализация для подписи: sorted keys, компактно, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


class ServerKeys:
    KEY_ID = "rsa:1"  # при ротации появятся rsa:2 и т.д.

    def __init__(self, data_dir: Path):
        pem_path = data_dir / "signing_key.pem"
        data_dir.mkdir(parents=True, exist_ok=True)
        if pem_path.is_file():
            self._private = serialization.load_pem_private_key(pem_path.read_bytes(), password=None)
        else:
            self._private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            pem = self._private.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
            pem_path.write_bytes(pem)
            pem_path.chmod(0o600)

    @property
    def public_key_b64(self) -> str:
        der = self._private.public_key().public_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        return base64.b64encode(der).decode()

    def sign_b64(self, data: bytes) -> str:
        sig = self._private.sign(data, padding.PKCS1v15(), hashes.SHA256())
        return base64.b64encode(sig).decode()

    @staticmethod
    def verify_b64(public_key_b64: str, signature_b64: str, data: bytes) -> bool:
        """Проверка подписи по публичному ключу — то, что делает чужой участник федерации."""
        try:
            key = serialization.load_der_public_key(base64.b64decode(public_key_b64))
            key.verify(base64.b64decode(signature_b64), data, padding.PKCS1v15(), hashes.SHA256())
            return True
        except Exception:
            return False
