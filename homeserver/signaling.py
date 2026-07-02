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

    async def send(self, msg: dict) -> None:
        # Сокет мог закрыться между нашим event'ом и отправкой — пир умрёт сам,
        # его вычистит собственный disconnect.
        try:
            await self._send(msg)
        except Exception:
            pass


class SignalingHub:
    def __init__(self):
        self._rooms: dict[str, dict[int, SignalPeer]] = {}
        self._ids = count(1)
        # Монотонный счётчик входов в комнаты (общий на сервер): меньший seq = вошёл раньше.
        self._join_seqs = count(1)

    async def connect(self, send: Callable[[dict], Awaitable[None]]) -> SignalPeer:
        peer = SignalPeer(next(self._ids), send)
        await peer.send({"type": "welcome", "id": peer.id})
        log.info("peer %d connected", peer.id)
        return peer

    async def handle(self, peer: SignalPeer, msg: dict) -> None:
        mtype = msg.get("type")
        if mtype == "join":
            await self._join(peer, str(msg.get("room", "")), str(msg.get("nick", "")))
        elif mtype in SIGNAL_TYPES:
            await self._relay(peer, msg)

    async def disconnect(self, peer: SignalPeer) -> None:
        await self._leave(peer)
        log.info("peer %d disconnected", peer.id)

    async def _join(self, peer: SignalPeer, room: str, nick: str) -> None:
        # Повторный join (клиент сменил страницу) — сперва выходим из старой комнаты.
        await self._leave(peer)
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
