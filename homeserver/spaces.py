"""Персональные пространства — модуль домашнего сервера (docs/personal-spaces.md).

Пространство — хостимая сервером vrweb-страница пользователя: по умолчанию ей
управляет владелец, права на редактирование он раздаёт через веб-морду. Модуль —
reference implementation протокола персистенции (docs/page-persistence.md).

Здесь: данные (spaces/space_editors), slug и ротация, политика доступа
(public / when-home / private), сборка HTML-страницы, гейт «дверь открыта, пока
хозяин дома» (presence через SignalingHub — сигналинг и хостинг в одном процессе).
HTTP-маршруты — в spaces_api.py; применение дельты к разметке — в vrweb_scene.py.
"""

from __future__ import annotations

import secrets
import sqlite3
import time
import xml.etree.ElementTree as ET

import vrweb_scene
from config import Config
from db import Database

POLICIES = ("public", "when-home", "private")
DEFAULT_POLICY = "when-home"

# Дефолтная сцена нового пространства: свет + пьедестал. mode="combine" — процедурный
# мир из HTML даёт атмосферу/пол, vrweb-узлы добавляются поверх и редактируемы.
DEFAULT_CONTENT = """\
<OmniLight3D transform="Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 3, -4)" omni_range="16" light_energy="2" />
<CSGBox3D size="Vector3(1, 0.5, 1)" use_collision="true" transform="Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.25, -4)" />"""

FLUSH_PATH = "/api/v1/spaces/flush"

# Содержимое редактора вставляется внутрь <vrwml> на HTML-странице. Поэтому принимаем
# только XML-подобные теги сцены, но не настоящие HTML-теги: иначе владелец мог бы случайно
# сохранить <script> и выполнить его в origin домашнего сервера при следующем открытии.
_HTML_TAGS = {
    "a", "abbr", "acronym", "address", "area", "article", "aside", "audio", "b", "base",
    "bdi", "bdo", "big", "blockquote", "body", "br", "button", "canvas", "caption",
    "center", "cite", "code", "col", "colgroup", "data", "datalist", "dd", "del",
    "details", "dfn", "dialog", "dir", "div", "dl", "dt", "em", "embed", "fieldset",
    "figcaption", "figure", "font", "footer", "form", "frame", "frameset", "h1", "h2",
    "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe",
    "image", "img", "input", "ins", "kbd", "label", "legend", "li", "link", "main",
    "map", "mark", "marquee", "math", "menu", "meta", "meter", "nav", "nobr", "noembed",
    "noframes", "noscript", "object", "ol", "optgroup", "option", "output", "p", "param",
    "picture", "plaintext", "portal", "pre", "progress", "q", "rb", "rp", "rt", "rtc",
    "ruby", "s", "samp", "script", "search", "section", "select", "slot", "small",
    "source", "span", "strike", "strong", "style", "sub", "summary", "sup", "svg", "table",
    "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time", "title", "tr",
    "track", "tt", "u", "ul", "var", "video", "vrwml", "wbr", "xmp",
}


class ContentError(ValueError):
    pass


# --- Данные ---

def get_or_create_home(db: Database, cfg: Config, user: sqlite3.Row) -> sqlite3.Row:
    """Пространство пользователя; создаётся лениво при первом обращении."""
    with db.conn() as c:
        row = c.execute("SELECT * FROM spaces WHERE user_id = ?", (user["id"],)).fetchone()
        if row is not None:
            return row
        now = int(time.time())
        slug = _new_slug()
        c.execute(
            "INSERT INTO spaces (user_id, slug, name, policy, content, room_key, created_at, updated_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (user["id"], slug, "Дом %s" % user["nickname"], DEFAULT_POLICY,
             DEFAULT_CONTENT, _room_key(cfg, slug), now, now),
        )
        return c.execute("SELECT * FROM spaces WHERE user_id = ?", (user["id"],)).fetchone()


def rotate_slug(db: Database, cfg: Config, space_id: int) -> None:
    """Сменить slug: все розданные ссылки умирают, «кнопка домой» владельца не
    страдает (клиент не хранит URL — каждый раз спрашивает сервер)."""
    slug = _new_slug()
    with db.conn() as c:
        c.execute("UPDATE spaces SET slug = ?, room_key = ?, updated_at = ? WHERE id = ?",
                  (slug, _room_key(cfg, slug), int(time.time()), space_id))


def space_by_slug(db: Database, slug: str) -> sqlite3.Row | None:
    with db.conn() as c:
        return c.execute("SELECT * FROM spaces WHERE slug = ?", (slug,)).fetchone()


def space_by_url(db: Database, cfg: Config, url: str) -> sqlite3.Row | None:
    """Пространство по URL страницы (сверка по каноническому ключу, а не строке)."""
    key = vrweb_scene.seed_key(url)
    prefix = vrweb_scene.seed_key(cfg.effective_base_url()) + "/s/"
    if not key.startswith(prefix):
        return None
    return space_by_slug(db, key[len(prefix):])


def space_by_room(db: Database, room: str) -> sqlite3.Row | None:
    with db.conn() as c:
        return c.execute("SELECT * FROM spaces WHERE room_key = ?", (room,)).fetchone()


def owner_address(db: Database, cfg: Config, space: sqlite3.Row) -> str:
    with db.conn() as c:
        row = c.execute("SELECT nickname FROM users WHERE id = ?", (space["user_id"],)).fetchone()
    return "%s@%s" % (row["nickname"], cfg.domain) if row else ""


def update_settings(db: Database, space_id: int, name: str, policy: str) -> None:
    if policy not in POLICIES:
        policy = DEFAULT_POLICY
    with db.conn() as c:
        c.execute("UPDATE spaces SET name = ?, policy = ? WHERE id = ?",
                  (name.strip() or "Дом", policy, space_id))


def save_content(db: Database, space_id: int, content: str) -> None:
    with db.conn() as c:
        c.execute("UPDATE spaces SET content = ?, updated_at = ? WHERE id = ?",
                  (content, int(time.time()), space_id))


def validate_content(content: str) -> None:
    """Проверить сырой VRWML-фрагмент из браузерного редактора.

    Форматирование сохраняется как ввёл владелец; XML-парсер используется только для
    проверки сбалансированности и границы фрагмента. Ограничение совпадает с максимальным
    размером persistence flush.
    """
    if len(content.encode("utf-8")) > vrweb_scene.MAX_BYTES:
        raise ContentError("Код превышает допустимый размер (4 МБ).")
    try:
        root = ET.fromstring("<vrweb-fragment>" + content + "</vrweb-fragment>")
    except ET.ParseError as e:
        raise ContentError("Некорректная VRWML-разметка: %s." % e) from None
    for elem in root.iter():
        if elem is root:
            continue
        tag = elem.tag
        if not isinstance(tag, str) or not vrweb_scene._TAG_RE.fullmatch(tag):
            raise ContentError("Недопустимое имя тега.")
        if tag.lower() in _HTML_TAGS:
            raise ContentError("HTML-тег <%s> нельзя помещать в код сцены." % tag)
        for name in elem.attrib:
            if not vrweb_scene._ATTR_RE.fullmatch(name.lower()):
                raise ContentError("Недопустимое имя атрибута %s." % name)


# --- Редакторы (allowlist полных федеративных адресов) ---

def editors(db: Database, space_id: int) -> list[str]:
    with db.conn() as c:
        rows = c.execute("SELECT address FROM space_editors WHERE space_id = ? ORDER BY address",
                         (space_id,)).fetchall()
    return [r["address"] for r in rows]


def add_editor(db: Database, space_id: int, address: str) -> None:
    address = address.strip().lower()
    if "@" not in address or address.startswith("@") or address.endswith("@"):
        return
    with db.conn() as c:
        c.execute("INSERT OR IGNORE INTO space_editors (space_id, address) VALUES (?, ?)",
                  (space_id, address))


def remove_editor(db: Database, space_id: int, address: str) -> None:
    with db.conn() as c:
        c.execute("DELETE FROM space_editors WHERE space_id = ? AND address = ?",
                  (space_id, address.strip().lower()))


def can_edit(db: Database, cfg: Config, space: sqlite3.Row, address: str) -> bool:
    """Право на флаш: владелец или адрес из allowlist. Права ВНУТРИ комнаты (ранги)
    ортогональны — сервер страницы про них не знает."""
    if address == "":
        return False
    return address == owner_address(db, cfg, space) or address in editors(db, space["id"])


# --- Доступ: «дверь открыта, пока хозяин дома» ---

def access_allowed(db: Database, cfg: Config, hub, space: sqlite3.Row, address: str) -> bool:
    """Пускать ли предъявителя address ("" — аноним) на страницу/в комнату.
    Владельца и редакторов пускаем всегда; гостей — по политике: public — всегда,
    when-home — пока владелец в комнате (сервер видит это в СВОЁМ сигналинге),
    private — никогда (федеративный auth фетча — v2)."""
    owner = owner_address(db, cfg, space)
    if address != "" and (address == owner or address in editors(db, space["id"])):
        return True
    policy = str(space["policy"])
    if policy == "public":
        return True
    if policy == "when-home":
        return hub is not None and hub.room_has_address(str(space["room_key"]), owner)
    return False


def room_allowed(db: Database, cfg: Config, hub, room: str, address: str) -> bool:
    """Гейт сигналинга: комната пространства подчиняется той же политике, что и
    страница (иначе знающий URL слушал бы голос без страницы). Обычные комнаты — открыты."""
    space = space_by_room(db, room)
    if space is None:
        return True
    return access_allowed(db, cfg, hub, space, address)


# --- Страница ---

def space_url(cfg: Config, space: sqlite3.Row) -> str:
    return "%s/s/%s" % (cfg.effective_base_url(), space["slug"])


def page_html(cfg: Config, space: sqlite3.Row) -> str:
    """HTML-страница пространства: заголовок + блок <vrwml> с persist/rev.
    Атрибуты блока задаёт сервер (клиентский дифф запрещает их править)."""
    rev = vrweb_scene.rev_of(str(space["content"]))
    name = _esc(str(space["name"]))
    return (
        "<!DOCTYPE html>\n<html lang=\"ru\">\n<head>\n"
        "  <meta charset=\"utf-8\">\n"
        "  <title>%s</title>\n"
        "</head>\n<body>\n"
        "  <header><h1>%s</h1></header>\n"
        "  <main><p>Персональное пространство на %s.</p></main>\n"
        "  <vrwml mode=\"combine\" persist=\"%s%s\" rev=\"%s\">\n"
        "%s\n"
        "  </vrwml>\n"
        "</body>\n</html>\n"
    ) % (name, name, _esc(cfg.domain), cfg.effective_base_url(), FLUSH_PATH, rev,
         str(space["content"]))


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _new_slug() -> str:
    return secrets.token_urlsafe(9)   # 12 символов url-safe — неугадываемый адрес


def _room_key(cfg: Config, slug: str) -> str:
    return vrweb_scene.seed_key("%s/s/%s" % (cfg.effective_base_url(), slug))
