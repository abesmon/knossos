"""Presence — «где люди»: сводка занятых страниц (docs/presence.md).

Контракт presence.v1 отдаёт список «страница → сколько людей» (+ теги). ОТКУДА сервер
знает про комнаты, контракт не предписывает: в монолите источник — собственный
SignalingHub, у другой реализации это может быть внешний сигналинг или федерация.

Фильтрация приватного — тоже НЕ требование контракта, а добросовестность конкретной
реализации. Наша reference implementation скрывает из выдачи:
  - не-веб/локальные страницы (vrweblocal/vrwebresource, см. docs/multiplayer.md): чужой
    домашний сервер вообще не должен знать про чью-то локальную ФС — а seed_key такой
    страницы утёк бы путями/именем пользователя;
  - приватные инстансы (query-параметр `vrweb-instance`, см. docs/multiplayer.md):
    такая ссылка — ключ к комнате, анонсировать её = слить ключ;
  - персональные пространства этого сервера (/s/<slug>): slug — секретный адрес,
    его знание = приглашение (docs/personal-spaces.md).
Число людей отдаётся без списка участников — кто именно внутри, выдача не раскрывает.
"""

from __future__ import annotations

import vrweb_scene
from config import Config

# Стандартизируемый query-параметр приватного инстанса (docs/multiplayer.md).
PRIVATE_INSTANCE_PARAM = "vrweb-instance"


def snapshot(cfg: Config, hub, url: str = "") -> list[dict]:
    """Публичная выдача: [{url, count, tags}] по убыванию людности. url в записи —
    канонический ключ страницы (= ключ комнаты, vrweb_scene.seed_key: без схемы/фрагмента,
    host в lowercase); клиент открывает его как обычный адрес (схема по умолчанию https).

    url-аргумент — точечный запрос «сколько людей вот на этой странице?»: выдача только
    по ней (нормализуется тем же seed_key). Фильтрация приватного действует и здесь:
    точечный вопрос о приватном инстансе/пространстве получает пустую выдачу — иначе
    presence позволял бы дистанционно следить за занятостью приватной комнаты."""
    space_prefix = vrweb_scene.seed_key(cfg.effective_base_url()) + "/s/"
    tags = {vrweb_scene.seed_key(u): t for u, t in cfg.presence_tags.items()}
    wanted = vrweb_scene.seed_key(url) if url else ""
    out = []
    for room, count in hub.room_counts().items():
        if not room or not _is_public_web_room(room):
            continue
        if _has_private_param(room) or room.startswith(space_prefix):
            continue
        if wanted and room != wanted:
            continue
        out.append({"url": room, "count": count, "tags": tags.get(room, [])})
    out.sort(key=lambda e: (-e["count"], e["url"]))
    return out


def _is_public_web_room(room: str) -> bool:
    """Публично анонсируем только веб-страницы. Ключ веб-комнаты — host+path без схемы
    (seed_key срезает http/https) и всегда начинается с хоста. Не-веб страницы
    (vrweblocal/vrwebresource) сохраняют схему → в ключе есть "://"; а ключ от СТАРОГО
    клиента, срезавшего vrweblocal, начинается с "/" (путь ФС без хоста) — тоже прячем."""
    return "://" not in room and not room.startswith("/")


def _has_private_param(room: str) -> bool:
    q = room.find("?")
    if q == -1:
        return False
    return any(pair.split("=", 1)[0] == PRIVATE_INSTANCE_PARAM
               for pair in room[q + 1:].split("&"))
