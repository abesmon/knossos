"""Чистая работа с vrweb-разметкой пространства: парсинг, индекс узлов, применение
дельты эфемерного слоя (server-authoritative merge), сериализация, rev.

Python-порт клиентского SceneHtml (scripts/ephemeral/scene_html.gd) в объёме,
нужном серверу персистенции (docs/page-persistence.md):

- детерминированные id узлов обязаны совпадать с клиентскими бит-в-бит: авторский
  атрибут `id`, иначе структурный "n<путь индексов элементов>" (текстовые узлы не
  считаются) — см. SceneHtml.build_page_index;
- дельта — плоские объекты слоя (kind vrweb-patch / vrweb-node), сервер применяет их
  к СВОЕЙ копии разметки, присланному слитому документу не доверяет;
- при первом изменении структурные id «пришпиливаются» (пишутся атрибутами), чтобы
  удаление/вставка узлов не сдвигала адреса соседей в будущих правках.

Модуль не знает ни о БД, ни о HTTP — только разметка и плоские данные.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field

KIND_NODE = "vrweb-node"
KIND_PATCH = "vrweb-patch"
PATCH_PREFIX = "vpatch:"
PAGE_PREFIX = "page:"
ACCEPTED_KINDS = (KIND_PATCH, KIND_NODE)

# Лимиты запроса флаша (анонсируются capability-ответом).
MAX_OBJECTS = 256
MAX_BYTES = 256 * 1024

_TAG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*$")
_ATTR_RE = re.compile(r"^[a-z_][a-z0-9_.:-]*$")


@dataclass
class Element:
    tag: str                       # исходный регистр (PascalCase для классов Godot)
    attrs: dict = field(default_factory=dict)   # имена lowercase, значения — сырые строки
    children: list = field(default_factory=list)


# ============================================================================
#  Парсер фрагмента разметки (содержимое блока <vrweb>)
# ============================================================================

_TOKEN_RE = re.compile(r"<!--.*?-->|<[^>]*>", re.DOTALL)
_ATTR_TOKEN_RE = re.compile(
    r"""([^\s=/]+)\s*(?:=\s*("[^"]*"|'[^']*'|[^\s>]*))?""")


def _decode_entities(s: str) -> str:
    s = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), s)
    return (s.replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", '"').replace("&apos;", "'").replace("&#39;", "'")
            .replace("&amp;", "&"))


def escape_attr(s: str) -> str:
    """Как HtmlNode.escape_attr на клиенте: & < > и двойная кавычка."""
    return (s.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def parse_fragment(markup: str) -> list[Element]:
    """Разбирает фрагмент в список элементов верхнего уровня. Текст и комментарии
    пропускаются (внутри <vrweb> текста не бывает — см. SceneHtml.parse_scene)."""
    top: list[Element] = []
    stack: list[Element] = []
    for m in _TOKEN_RE.finditer(markup):
        token = m.group(0)
        if token.startswith("<!--") or token.startswith("<!"):
            continue
        inner = token[1:-1].strip()
        if inner.startswith("/"):
            name = inner[1:].strip()
            # Закрываем ближайший совпадающий тег (мягко, как лояльный клиентский парсер).
            for i in range(len(stack) - 1, -1, -1):
                if stack[i].tag.lower() == name.lower():
                    del stack[i:]
                    break
            continue
        self_closing = inner.endswith("/")
        if self_closing:
            inner = inner[:-1].strip()
        if not inner:
            continue
        parts = inner.split(None, 1)
        tag = parts[0]
        attrs: dict = {}
        if len(parts) > 1:
            for am in _ATTR_TOKEN_RE.finditer(parts[1]):
                name = am.group(1).lower()
                raw = am.group(2) or ""
                if raw[:1] in "\"'":
                    raw = raw[1:-1]
                attrs[name] = _decode_entities(raw)
        elem = Element(tag=tag, attrs=attrs)
        (stack[-1].children if stack else top).append(elem)
        if not self_closing:
            stack.append(elem)
    return top


def serialize_fragment(elements: list[Element], indent: int = 1) -> str:
    """Каноническая сериализация фрагмента (2 пробела на уровень, как у клиента)."""
    lines: list[str] = []
    for e in elements:
        _emit(e, indent, lines)
    return "\n".join(lines)


def _emit(e: Element, indent: int, lines: list[str]) -> None:
    pad = "  " * indent
    attr_str = "".join(' %s="%s"' % (k, escape_attr(str(v))) for k, v in e.attrs.items())
    if not e.children:
        lines.append("%s<%s%s />" % (pad, e.tag, attr_str))
        return
    lines.append("%s<%s%s>" % (pad, e.tag, attr_str))
    for c in e.children:
        _emit(c, indent + 1, lines)
    lines.append("%s</%s>" % (pad, e.tag))


# ============================================================================
#  Индекс узлов: детерминированные id (паритет с SceneHtml.build_page_index)
# ============================================================================

def build_index(elements: list[Element]) -> dict:
    """id -> {elem, parent_elem, parent_id}. Авторский id, иначе структурный
    "n<путь>"; коллизия авторского id — структурный fallback (как на клиенте)."""
    index: dict = {}
    _index_children(elements, None, "", [], index)
    return index


def _index_children(children: list[Element], parent_elem, parent_id: str,
                    path: list, index: dict) -> None:
    for i, c in enumerate(children):
        child_path = path + [i]
        node_id = str(c.attrs.get("id", "")).strip()
        if node_id == "" or node_id in index:
            node_id = "n" + "-".join(str(p) for p in child_path)
        index[node_id] = {"elem": c, "parent_elem": parent_elem, "parent_id": parent_id}
        _index_children(c.children, c, node_id, child_path, index)


def pin_ids(elements: list[Element]) -> None:
    """Пришпилить структурные id атрибутами: после мутаций (удаление/вставка) адреса
    соседей не должны сдвигаться. Идемпотентно: авторские id не трогаются."""
    for node_id, rec in build_index(elements).items():
        elem: Element = rec["elem"]
        if str(elem.attrs.get("id", "")).strip() == "":
            # id — первым атрибутом, как в слитом документе клиента.
            elem.attrs = {"id": node_id, **elem.attrs}


# ============================================================================
#  Применение дельты (server-authoritative merge)
# ============================================================================

def apply_objects(markup: str, objects: list) -> dict:
    """Применяет объекты дельты к разметке. Возвращает
    { results: {id: {outcome, reason?}}, markup: str, changed: bool }.
    Гранулярность — объект: внутри объекта атомарно, между объектами — нет."""
    elements = parse_fragment(markup)
    results: dict = {}
    applied = 0
    inserted: dict = {}   # id объекта -> Element, вставленный в ЭТОМ флаше

    def reject(oid: str, reason: str) -> None:
        results[oid] = {"outcome": "rejected", "reason": reason}

    # Пришпиливаем структурные id до мутаций: и адреса не поедут, и вставленные узлы
    # получат стабильных соседей. Если ни один объект не применится — не сохраняем.
    pin_ids(elements)

    for obj in objects if isinstance(objects, list) else []:
        if not isinstance(obj, dict):
            continue
        oid = str(obj.get("id", ""))
        kind = str(obj.get("kind", ""))
        props = obj.get("props", {})
        if oid == "" or not isinstance(props, dict):
            reject(oid or "?", "bad object")
            continue
        if kind not in ACCEPTED_KINDS:
            reject(oid, "kind not accepted")
            continue
        index = build_index(elements)   # после каждой мутации адреса актуальны
        if kind == KIND_PATCH:
            outcome = _apply_patch(elements, index, oid, props)
        else:
            outcome = _apply_node(elements, index, inserted, oid, str(obj.get("parent", "")), props)
        results[oid] = outcome
        if outcome["outcome"] == "applied":
            applied += 1

    if applied == 0:
        return {"results": results, "markup": markup, "changed": False}
    return {"results": results, "markup": serialize_fragment(elements), "changed": True}


def _apply_patch(elements: list[Element], index: dict, oid: str, props: dict) -> dict:
    if not oid.startswith(PATCH_PREFIX):
        return {"outcome": "rejected", "reason": "patch id must be vpatch:<node>"}
    node_id = oid[len(PATCH_PREFIX):]
    rec = index.get(node_id)
    if rec is None:
        return {"outcome": "rejected", "reason": "node not found"}
    elem: Element = rec["elem"]
    if props.get("removed", False):
        siblings = rec["parent_elem"].children if rec["parent_elem"] is not None else elements
        siblings.remove(elem)
        return {"outcome": "applied"}
    set_map = props.get("set", {})
    if not isinstance(set_map, dict) or not set_map:
        return {"outcome": "rejected", "reason": "empty patch"}
    for k, v in set_map.items():
        name = str(k).lower()
        if name == "id" or not _ATTR_RE.match(name):
            return {"outcome": "rejected", "reason": "bad attribute %r" % k}
    for k, v in set_map.items():
        elem.attrs[str(k).lower()] = str(v)
    return {"outcome": "applied"}


def _apply_node(elements: list[Element], index: dict, inserted: dict,
                oid: str, parent: str, props: dict) -> dict:
    if oid in index:
        # Анти-дубль: узел с этим id уже в базе (повторный флаш) — не вставляем второй.
        return {"outcome": "rejected", "reason": "already persisted"}
    tag = str(props.get("tag", ""))
    attrs = props.get("attrs", {})
    if not _TAG_RE.match(tag):
        return {"outcome": "rejected", "reason": "bad tag"}
    if not isinstance(attrs, dict):
        return {"outcome": "rejected", "reason": "bad attrs"}
    for k in attrs:
        name = str(k).lower()
        if name == "id" or not _ATTR_RE.match(name):
            return {"outcome": "rejected", "reason": "bad attribute %r" % k}
    # id объекта становится HTML-id элемента — опора дедупликации на клиентах.
    elem = Element(tag=tag, attrs={"id": oid})
    for k in sorted(attrs, key=str):
        elem.attrs[str(k).lower()] = str(attrs[k])
    if parent == "":
        elements.append(elem)
    elif parent.startswith(PAGE_PREFIX):
        rec = index.get(parent[len(PAGE_PREFIX):])
        if rec is None:
            return {"outcome": "rejected", "reason": "parent node not found"}
        rec["elem"].children.append(elem)
    else:
        # Родитель — другой эфемерный объект: вставлен этим же флашем или уже в базе.
        parent_elem = inserted.get(parent)
        if parent_elem is None:
            rec = index.get(parent)
            parent_elem = rec["elem"] if rec is not None else None
        if parent_elem is None:
            return {"outcome": "rejected", "reason": "parent missing"}
        parent_elem.children.append(elem)
    inserted[oid] = elem
    return {"outcome": "applied"}


# ============================================================================
#  Версия базы и канонический ключ комнаты
# ============================================================================

def rev_of(markup: str) -> str:
    """Идентификатор версии базы — контент-хэш разметки блока."""
    return hashlib.sha256(markup.encode("utf-8")).hexdigest()[:16]


def seed_key(url: str) -> str:
    """Порт PageFetcher.seed_key (клиент): канонический ключ страницы = ключ комнаты.
    Не влияют: схема, регистр хоста, хвостовые слеши, фрагмент. Влияют: хост, путь, query."""
    url = url.strip()
    hash_pos = url.find("#")
    if hash_pos != -1:
        url = url[:hash_pos]
    query = ""
    q_pos = url.find("?")
    if q_pos != -1:
        query = url[q_pos:]
        url = url[:q_pos]
    scheme_end = url.find("://")
    if scheme_end != -1:
        url = url[scheme_end + 3:]
    slash = url.find("/")
    if slash == -1:
        url = url.lower()
    else:
        url = url[:slash].lower() + url[slash:]
    while url.endswith("/"):
        url = url[:-1]
    return url + query
