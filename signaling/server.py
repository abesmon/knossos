"""VRWeb signaling server.

Минимальный WebSocket-релей для WebRTC-handshake. Сам в обмене данными между
игроками не участвует: после установки p2p-соединения позиции и чат идут напрямую
(mesh). Сервер лишь:
  - присваивает каждому подключению уникальный peer_id,
  - группирует подключения по комнатам (room = PageFetcher.seed_key(url) на клиенте),
  - пересылает offer/answer/ICE-кандидаты между пирами одной комнаты.

Состояние держится в памяти, без БД — комнаты эфемерны и живут, пока в них есть люди.

Протокол (JSON-сообщения):
  клиент -> сервер:
    {"type": "join", "room": <str>, "nick": <str>}
    {"type": "offer"|"answer"|"candidate", "to": <peer_id>, "data": <any>}
  сервер -> клиент:
    {"type": "welcome", "id": <peer_id>}
    {"type": "peers", "peers": [{"id": <peer_id>, "nick": <str>}, ...]}  # уже в комнате
    {"type": "peer_join", "id": <peer_id>, "nick": <str>}
    {"type": "peer_leave", "id": <peer_id>}
    {"type": "offer"|"answer"|"candidate", "from": <peer_id>, "data": <any>}

Антиглар: и новичок (через "peers"), и старожилы (через "peer_join") узнают друг о
друге. offer создаёт пир с меньшим id — так ровно одна сторона инициирует соединение.

Точка расширения (федерация, не реализована): room — произвольная строка, поэтому
сервер можно научить пересылать join/сигналы дружественным серверам, чтобы пиры с
разных сигнальных серверов попадали в одну комнату (аналог Matrix). См. docs/multiplayer.md.
"""

import asyncio
import json
import logging
import os
from itertools import count

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("signaling")

# room_key -> { peer_id: Peer }
rooms: dict[str, dict[int, "Peer"]] = {}
_ids = count(1)


class Peer:
    def __init__(self, ws):
        self.ws = ws
        self.id: int = next(_ids)
        self.room: str | None = None
        self.nick: str = ""

    async def send(self, msg: dict) -> None:
        await self.ws.send(json.dumps(msg))


async def _join(peer: Peer, room: str, nick: str) -> None:
    # Повторный join (клиент сменил страницу) — сперва выходим из старой комнаты.
    await _leave(peer)
    peer.room = room
    peer.nick = nick or f"Guest-{peer.id}"
    members = rooms.setdefault(room, {})

    # Новичку — список тех, кто уже в комнате.
    await peer.send({
        "type": "peers",
        "peers": [{"id": p.id, "nick": p.nick} for p in members.values()],
    })
    # Старожилам — что появился новичок.
    for other in members.values():
        await other.send({"type": "peer_join", "id": peer.id, "nick": peer.nick})

    members[peer.id] = peer
    log.info("peer %d (%s) joined room %r (%d total)", peer.id, peer.nick, room, len(members))


async def _leave(peer: Peer) -> None:
    if peer.room is None:
        return
    room = peer.room
    members = rooms.get(room)
    peer.room = None
    if members is None:
        return
    members.pop(peer.id, None)
    for other in members.values():
        await other.send({"type": "peer_leave", "id": peer.id})
    log.info("peer %d left room (%d remain)", peer.id, len(members))
    if not members:
        rooms.pop(room, None)


async def _relay(peer: Peer, msg: dict) -> None:
    # Пересылаем сигнал конкретному пиру в той же комнате.
    if peer.room is None:
        return
    target_id = msg.get("to")
    members = rooms.get(peer.room, {})
    target = members.get(target_id)
    if target is None:
        return
    await target.send({"type": msg["type"], "from": peer.id, "data": msg.get("data")})


async def handler(ws):
    peer = Peer(ws)
    await peer.send({"type": "welcome", "id": peer.id})
    log.info("peer %d connected", peer.id)
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except (ValueError, TypeError):
                continue
            mtype = msg.get("type")
            if mtype == "join":
                await _join(peer, str(msg.get("room", "")), str(msg.get("nick", "")))
            elif mtype in ("offer", "answer", "candidate"):
                await _relay(peer, msg)
    except websockets.ConnectionClosed:
        pass
    finally:
        await _leave(peer)
        log.info("peer %d disconnected", peer.id)


async def main() -> None:
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))
    log.info("signaling server listening on ws://%s:%d", host, port)
    async with websockets.serve(handler, host, port):
        await asyncio.Future()  # бесконечно


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
