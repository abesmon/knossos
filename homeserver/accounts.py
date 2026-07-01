"""Аккаунты и сессии: регистрация, логин, токены.

Никнейм нормализуется в lowercase и валидируется под адрес nick@domain.
Сессии — общий механизм для REST (Bearer) и веб-морды (cookie): в БД лежит
только SHA-256 токена.
"""

from __future__ import annotations

import re
import sqlite3
import time

import security
from db import Database

NICK_RE = re.compile(r"^[a-z0-9._-]{3,32}$")


class AccountError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def normalize_nickname(nickname: str) -> str:
    nick = nickname.strip().lower()
    if not NICK_RE.match(nick):
        raise AccountError(
            "invalid_nickname",
            "Никнейм: 3–32 символа, только a-z, 0-9, точка, дефис, подчёркивание.",
        )
    return nick


def register(db: Database, nickname: str, password: str) -> sqlite3.Row:
    nick = normalize_nickname(nickname)
    if len(password) < 8:
        raise AccountError("weak_password", "Пароль — минимум 8 символов.")
    now = int(time.time())
    try:
        with db.conn() as c:
            c.execute(
                "INSERT INTO users (nickname, password_hash, created_at) VALUES (?, ?, ?)",
                (nick, security.hash_password(password), now),
            )
    except sqlite3.IntegrityError:
        raise AccountError("nickname_taken", "Такой никнейм уже занят.") from None
    return get_user_by_nickname(db, nick)


def get_user_by_nickname(db: Database, nickname: str) -> sqlite3.Row | None:
    with db.conn() as c:
        return c.execute("SELECT * FROM users WHERE nickname = ?", (nickname,)).fetchone()


def authenticate(db: Database, nickname: str, password: str) -> sqlite3.Row:
    try:
        nick = normalize_nickname(nickname)
    except AccountError:
        raise AccountError("invalid_credentials", "Неверный никнейм или пароль.") from None
    user = get_user_by_nickname(db, nick)
    if user is None or not security.verify_password(password, user["password_hash"]):
        raise AccountError("invalid_credentials", "Неверный никнейм или пароль.")
    return user


def create_session(db: Database, user_id: int, ttl_days: int) -> str:
    token = security.new_token()
    now = int(time.time())
    with db.conn() as c:
        c.execute(
            "INSERT INTO sessions (user_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?)",
            (user_id, security.token_hash(token), now, now + ttl_days * 86400),
        )
    return token


def session_user(db: Database, token: str, ttl_days: int) -> sqlite3.Row | None:
    """Пользователь по токену; сессия скользящая — использование продлевает срок."""
    now = int(time.time())
    with db.conn() as c:
        row = c.execute(
            "SELECT u.*, s.id AS session_id FROM sessions s JOIN users u ON u.id = s.user_id "
            "WHERE s.token_hash = ? AND s.expires_at > ?",
            (security.token_hash(token), now),
        ).fetchone()
        if row is not None:
            c.execute(
                "UPDATE sessions SET expires_at = ? WHERE id = ?",
                (now + ttl_days * 86400, row["session_id"]),
            )
    return row


def revoke_session(db: Database, token: str) -> None:
    with db.conn() as c:
        c.execute("DELETE FROM sessions WHERE token_hash = ?", (security.token_hash(token),))


def record_user_key(db: Database, user_id: int, public_key_b64: str) -> None:
    """Журнал сертифицированных ключей (аудит; в будущем — отзыв)."""
    with db.conn() as c:
        c.execute(
            "INSERT OR IGNORE INTO user_keys (user_id, public_key, created_at) VALUES (?, ?, ?)",
            (user_id, public_key_b64, int(time.time())),
        )


def user_keys(db: Database, user_id: int) -> list[sqlite3.Row]:
    with db.conn() as c:
        return c.execute(
            "SELECT public_key, created_at FROM user_keys WHERE user_id = ? ORDER BY created_at",
            (user_id,),
        ).fetchall()
