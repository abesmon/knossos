"""Сигналинг как модуль монолита.

Протокол и семантика — в точности как у standalone-сервера ../signaling/server.py
(join / offer / answer / candidate; см. ../signaling/README.md). Хаб независим от
транспорта: пиру нужен только async-колбэк `send(dict)`, поэтому модуль не знает ни
о FastAPI, ни об аккаунтах — граница «сигналинг ≠ домашний сервер» проходит здесь.
"""

from __future__ import annotations

import logging
from itertools import count
from typing import Awaitable, Callable

log = logging.getLogger("homeserver.signaling")

SIGNAL_TYPES = ("offer", "answer", "candidate")


class SignalPeer:
    def __init__(self, peer_id: int, send: Callable[[dict], Awaitable[None]]):
        self.id = peer_id
        self._send = send
        self.room: str | None = None
        self.nick: str = ""
        # Порядковый номер ВХОДА В КОМНАТУ (штампуется при каждом join). Старшинство
        # авторитета считается по нему, а не по id подключения: id выдаётся при коннекте
        # к серверу, и давно запущенный клиент имел бы преимущество в любой комнате.
        self.seq: int = 0
        # Аутентифицированный федеративный адрес (nick@domain) из access_token в join;
        # "" — аноним. Нужен presence-гейту пространств (docs/personal-spaces.md).
        self.address: str = ""

    async def send(self, msg: dict) -> None:
        # Сокет мог закрыться между нашим event'ом и отправкой — пир умрёт сам,
        # его вычистит собственный disconnect.
        try:
            await self._send(msg)
        except Exception:
            pass


class SignalingHub:
    """auth/join_check — опциональные хуки монолита (standalone-режим их не задаёт):
    auth(token) -> федеративный адрес ("" — невалидный токен); join_check(room, address)
    -> пускать ли в комнату (гейт комнат персональных пространств). Хаб по-прежнему не
    знает об аккаунтах — только зовёт колбэки."""

    def __init__(self, auth: Callable[[str], str] | None = None,
                 join_check: Callable[[str, str], bool] | None = None):
        self._rooms: dict[str, dict[int, SignalPeer]] = {}
        self._ids = count(1)
        # Монотонный счётчик входов в комнаты (общий на сервер): меньший seq = вошёл раньше.
        self._join_seqs = count(1)
        self._auth = auth
        self._join_check = join_check

    async def connect(self, send: Callable[[dict], Awaitable[None]]) -> SignalPeer:
        peer = SignalPeer(next(self._ids), send)
        await peer.send({"type": "welcome", "id": peer.id})
        log.info("peer %d connected", peer.id)
        return peer

    async def handle(self, peer: SignalPeer, msg: dict) -> None:
        mtype = msg.get("type")
        if mtype == "join":
            await self._join(peer, str(msg.get("room", "")), str(msg.get("nick", "")),
                             str(msg.get("access_token", "")))
        elif mtype in SIGNAL_TYPES:
            await self._relay(peer, msg)

    def room_has_address(self, room: str, address: str) -> bool:
        """Есть ли в комнате аутентифицированный участник с этим адресом (presence
        для «дверь открыта, пока хозяин дома»)."""
        if address == "":
            return False
        return any(p.address == address for p in self._rooms.get(room, {}).values())

    async def disconnect(self, peer: SignalPeer) -> None:
        await self._leave(peer)
        log.info("peer %d disconnected", peer.id)

    async def _join(self, peer: SignalPeer, room: str, nick: str, access_token: str = "") -> None:
        # Повторный join (клиент сменил страницу) — сперва выходим из старой комнаты.
        await self._leave(peer)
        # Токен привязывает WS-сессию к аккаунту (владелец входит в свой закрытый дом);
        # невалидный токен не рвёт соединение — пир просто аноним.
        peer.address = self._auth(access_token) if self._auth and access_token else ""
        if self._join_check is not None and not self._join_check(room, peer.address):
            # Комната закрыта политикой пространства (см. spaces.room_allowed): без страницы
            # гость и так ничего не увидит, гейт закрывает подслушивание голоса по URL.
            log.info("peer %d denied to room %r (space closed)", peer.id, room)
            await peer.send({"type": "join_denied", "room": room, "reason": "space_closed"})
            return
        peer.room = room
        peer.nick = nick or f"Guest-{peer.id}"
        # Свежий seq на КАЖДЫЙ вход: ушёл из комнаты — потерял старшинство.
        peer.seq = next(self._join_seqs)
        members = self._rooms.setdefault(room, {})

        # Новичку — его seq и список тех, кто уже в комнате; старожилам — что появился новичок.
        await peer.send({
            "type": "peers",
            "seq": peer.seq,
            "peers": [{"id": p.id, "nick": p.nick, "seq": p.seq} for p in members.values()],
        })
        for other in members.values():
            await other.send({"type": "peer_join", "id": peer.id, "nick": peer.nick, "seq": peer.seq})

        members[peer.id] = peer
        log.info("peer %d (%s, seq=%d) joined room %r (%d total)", peer.id, peer.nick, peer.seq, room, len(members))

    async def _leave(self, peer: SignalPeer) -> None:
        if peer.room is None:
            return
        members = self._rooms.get(peer.room)
        room = peer.room
        peer.room = None
        if members is None:
            return
        members.pop(peer.id, None)
        for other in members.values():
            await other.send({"type": "peer_leave", "id": peer.id})
        log.info("peer %d left room (%d remain)", peer.id, len(members))
        if not members:
            self._rooms.pop(room, None)

    async def _relay(self, peer: SignalPeer, msg: dict) -> None:
        if peer.room is None:
            return
        target = self._rooms.get(peer.room, {}).get(msg.get("to"))
        if target is None:
            return
        await target.send({"type": msg["type"], "from": peer.id, "data": msg.get("data")})
