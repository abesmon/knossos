"""Тесты presence «где люди» (docs/presence.md): сводка комнат из сигналинга,
добросовестная фильтрация (vrweb-instance, персональные пространства), теги из
конфига, режимы доступа (public/authenticated) и полное выключение фичи."""

from contextlib import contextmanager

from fastapi.testclient import TestClient

import vrweb_scene
from app import create_app
from config import Config

CREDS = {"nickname": "alice", "password": "secret123"}


@contextmanager
def make_client(tmp_path, **cfg_kw):
    cfg = Config(domain="test.local", data_dir=tmp_path, **cfg_kw)
    with TestClient(create_app(cfg)) as c:
        yield c


@contextmanager
def joined(client, room, nick="A", token=""):
    """Пир в комнате на время блока (welcome и peers вычитываются, чтобы не висели)."""
    with client.websocket_connect("/signal") as ws:
        ws.receive_json()  # welcome
        ws.send_json({"type": "join", "room": room, "nick": nick, "access_token": token})
        ws.receive_json()  # peers
        yield ws


def _presence(client, params=None, headers=None):
    r = client.get("/api/v1/presence", params=params or {}, headers=headers or {})
    assert r.status_code == 200, r.text
    return r.json()


def _rooms(client, params=None, headers=None):
    return _presence(client, params, headers)["rooms"]


# --- Выдача ---

def test_empty_when_nobody_online(client):
    assert _rooms(client) == []


def test_counts_and_order(client):
    with joined(client, "example.com/hub", "A"), joined(client, "example.com/hub", "B"), \
            joined(client, "other.com/page", "C"):
        data = _presence(client)
    # Людные комнаты первыми; в записи — число людей, но не их список.
    assert data["rooms"] == [
        {"url": "example.com/hub", "count": 2, "tags": []},
        {"url": "other.com/page", "count": 1, "tags": []},
    ]
    assert data["total"] == 2


def test_pagination(client):
    with joined(client, "a.com/1", "A"), joined(client, "b.com/2", "B"), \
            joined(client, "c.com/3", "C"):
        page1 = _presence(client, params={"limit": 2})
        page2 = _presence(client, params={"limit": 2, "offset": 2})
    # total — размер выдачи ДО пагинации; страницы не пересекаются и покрывают всё.
    assert page1["total"] == 3 and page2["total"] == 3
    assert len(page1["rooms"]) == 2 and len(page2["rooms"]) == 1
    urls = [r["url"] for r in page1["rooms"] + page2["rooms"]]
    assert sorted(urls) == ["a.com/1", "b.com/2", "c.com/3"]


def test_point_query_normalizes_url(client):
    with joined(client, "example.com/hub", "A"), joined(client, "other.com/page", "B"):
        # Клиент спрашивает «как удобно» (схема, регистр хоста, слеш) — сверка по seed_key.
        data = _presence(client, params={"url": "https://Example.com/hub/"})
    assert data["rooms"] == [{"url": "example.com/hub", "count": 1, "tags": []}]
    assert data["total"] == 1


def test_point_query_private_instance_stays_hidden(client):
    # Точечный вопрос о приватном инстансе — пустота: иначе presence позволял бы
    # дистанционно следить за занятостью приватной комнаты, зная её ключ.
    with joined(client, "example.com/hub?vrweb-instance=sekret"):
        data = _presence(client, params={"url": "example.com/hub?vrweb-instance=sekret"})
    assert data["rooms"] == [] and data["total"] == 0


def test_room_disappears_when_emptied(client):
    with joined(client, "example.com/hub"):
        assert len(_rooms(client)) == 1
    assert _rooms(client) == []


def test_tags_from_config_match_canonical_key(tmp_path):
    # Админ пишет URL как удобно (схема, регистр хоста, слеш) — сверка по seed_key.
    tags = {"https://Example.com/hub/": ["hub", "official"]}
    with make_client(tmp_path, presence_tags=tags) as client:
        with joined(client, "example.com/hub"):
            rooms = _rooms(client)
        assert rooms == [{"url": "example.com/hub", "count": 1, "tags": ["hub", "official"]}]


# --- Добросовестная фильтрация (reference implementation, не требование контракта) ---

def test_private_instance_hidden(client):
    with joined(client, "example.com/hub?vrweb-instance=sekret"), \
            joined(client, "example.com/hub?page=2"):
        rooms = _rooms(client)
    # Ключ приватного инстанса не светится; обычный query — не приватность.
    assert [r["url"] for r in rooms] == ["example.com/hub?page=2"]


def test_personal_space_hidden(client):
    token = client.post("/api/v1/register", json=CREDS).json()["access_token"]
    home = client.get("/api/v1/spaces/home",
                      headers={"Authorization": f"Bearer {token}"}).json()
    with joined(client, vrweb_scene.seed_key(home["url"]), "A", token=token):
        assert _rooms(client) == []


def test_local_pages_hidden(client):
    # Локальные/не-веб страницы не должны утекать в чужую presence-таблицу: ключ
    # vrwebresource сохраняет схему, а старый клиент срезал бы vrweblocal до пути ФС.
    with joined(client, "vrwebresource://demo.html"), \
            joined(client, "/Users/alice/secret.html"), \
            joined(client, "example.com/hub"):
        rooms = _rooms(client)
    assert [r["url"] for r in rooms] == ["example.com/hub"]


def test_point_query_local_stays_hidden(client):
    # Точечный запрос по локальному ключу тоже пуст — presence не подглядывает за ФС.
    with joined(client, "vrwebresource://demo.html"):
        data = _presence(client, params={"url": "vrwebresource://demo.html"})
    assert data["rooms"] == [] and data["total"] == 0


# --- Доступ и discovery ---

def test_feature_announced(client):
    assert "presence.v1" in client.get("/.well-known/vrweb").json()["features"]


def test_disabled_by_config(tmp_path):
    with make_client(tmp_path, presence_enabled=False) as client:
        assert "presence.v1" not in client.get("/.well-known/vrweb").json()["features"]
        r = client.get("/api/v1/presence")
        assert r.status_code == 404
        assert r.json()["error"]["code"] == "presence_disabled"
        # Веб-страница уводит на главную, ссылки в навигации нет.
        assert client.get("/presence", follow_redirects=False).status_code == 303
        assert "/presence" not in client.get("/").text


def test_authenticated_access(tmp_path):
    with make_client(tmp_path, presence_access="authenticated") as client:
        assert client.get("/api/v1/presence").status_code == 401
        token = client.post("/api/v1/register", json=CREDS).json()["access_token"]
        assert _rooms(client, headers={"Authorization": f"Bearer {token}"}) == []
        # Веб-версия без логина — на страницу логина.
        r = client.get("/presence", follow_redirects=False)
        assert r.status_code == 303 and r.headers["location"] == "/login"


def test_web_page_public(client):
    with joined(client, "example.com/hub"):
        page = client.get("/presence")
    assert page.status_code == 200
    assert "example.com/hub" in page.text
