"""Тесты персональных пространств и флаша персистенции:
vrweb_scene (индекс/слияние/rev/seed_key), API пространств, гейт «дверь открыта,
пока хозяин дома», оба пути авторизации флаша (Bearer и сертификат+proof)."""

import base64
import json
import secrets
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

import vrweb_scene
from spaces_api import PROOF_PREFIX

CREDS = {"nickname": "alice", "password": "secret123"}
GUEST = {"nickname": "bob", "password": "secret123"}


def _register(client, creds=CREDS):
    r = client.post("/api/v1/register", json=creds)
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _home(client, token):
    r = client.get("/api/v1/spaces/home", headers=_auth(token))
    assert r.status_code == 200, r.text
    return r.json()


# --- vrweb_scene: паритет с клиентским SceneHtml ---

def test_index_ids_match_client_scheme():
    elems = vrweb_scene.parse_fragment(
        '<Node3D name="a"><MeshInstance3D /><OmniLight3D id="lamp" /></Node3D><CSGBox3D />')
    index = vrweb_scene.build_index(elems)
    # Структурные id — путь индексов элементов; авторский id побеждает.
    assert set(index) == {"n0", "n0-0", "lamp", "n1"}
    assert index["n0-0"]["parent_id"] == "n0"
    assert index["lamp"]["elem"].tag == "OmniLight3D"


def test_apply_patch_and_remove():
    markup = '<Node3D><OmniLight3D light_energy="1" /></Node3D>'
    out = vrweb_scene.apply_objects(markup, [
        {"id": "vpatch:n0-0", "kind": "vrweb-patch", "parent": "",
         "props": {"set": {"light_energy": "3"}}},
    ])
    assert out["results"]["vpatch:n0-0"]["outcome"] == "applied"
    assert 'light_energy="3"' in out["markup"]
    # id пришпилены — адреса не поедут после будущих структурных правок.
    assert 'id="n0-0"' in out["markup"]

    out2 = vrweb_scene.apply_objects(out["markup"], [
        {"id": "vpatch:n0-0", "kind": "vrweb-patch", "parent": "", "props": {"removed": True}},
    ])
    assert out2["results"]["vpatch:n0-0"]["outcome"] == "applied"
    assert "OmniLight3D" not in out2["markup"]


def test_apply_node_insert_and_dedup():
    markup = '<Node3D id="root" />'
    obj = {"id": "u1.3", "kind": "vrweb-node", "parent": "page:root",
           "props": {"tag": "OmniLight3D", "attrs": {"light_energy": "2"}}}
    out = vrweb_scene.apply_objects(markup, [obj])
    assert out["results"]["u1.3"]["outcome"] == "applied"
    # id объекта стал HTML-id элемента — опора дедупликации у клиентов.
    assert 'id="u1.3"' in out["markup"]
    # Повторный флаш того же объекта — отказ, не дубль.
    out2 = vrweb_scene.apply_objects(out["markup"], [obj])
    assert out2["results"]["u1.3"]["outcome"] == "rejected"
    assert not out2["changed"]


def test_apply_node_nested_in_same_flush():
    out = vrweb_scene.apply_objects("", [
        {"id": "u1.1", "kind": "vrweb-node", "parent": "",
         "props": {"tag": "Node3D", "attrs": {}}},
        {"id": "u1.2", "kind": "vrweb-node", "parent": "u1.1",
         "props": {"tag": "OmniLight3D", "attrs": {}}},
    ])
    assert {r["outcome"] for r in out["results"].values()} == {"applied"}
    index = vrweb_scene.build_index(vrweb_scene.parse_fragment(out["markup"]))
    assert index["u1.2"]["parent_id"] == "u1.1"


def test_seed_key_port():
    # Паритет с PageFetcher.seed_key: веб-схема/регистр хоста/хвостовой слеш/фрагмент не влияют.
    assert vrweb_scene.seed_key("https://Ex.com/Page/") == "ex.com/Page"
    assert vrweb_scene.seed_key("http://ex.com/Page#a") == "ex.com/Page"
    assert vrweb_scene.seed_key("ex.com/p?q=1") == "ex.com/p?q=1"


def test_seed_key_keeps_non_web_scheme():
    # Не-веб схемы СОХРАНЯЮТСЯ в ключе (иначе локальная demo.html столкнулась бы с сайтом
    # demo.html), путь регистрозависим, регистр схемы нормализуется.
    assert vrweb_scene.seed_key("vrwebresource://test_pages/Demo.html") \
        == "vrwebresource://test_pages/Demo.html"
    assert vrweb_scene.seed_key("vrweblocal:///Users/alice/page.html/") \
        == "vrweblocal:///Users/alice/page.html"
    assert vrweb_scene.seed_key("VRWebLocal:///X/") == "vrweblocal:///X"
    # Веб-ключи не изменились этой правкой.
    assert vrweb_scene.seed_key("https://demo.html") == "demo.html"


# --- API пространств: ленивое создание, ротация ---

def test_home_space_lazy_and_rotate(client):
    token = _register(client)["access_token"]
    home = _home(client, token)
    assert home["url"].startswith("https://test.local/s/")
    assert home["name"] == "Дом alice"
    # Повторный запрос — тот же адрес (клиент не хранит URL, спрашивает каждый раз).
    assert _home(client, token)["url"] == home["url"]

    rotated = client.post("/api/v1/spaces/home/rotate", headers=_auth(token)).json()
    assert rotated["url"] != home["url"]
    assert _home(client, token)["url"] == rotated["url"]


def test_home_space_requires_auth(client):
    assert client.get("/api/v1/spaces/home").status_code == 401


# --- Страница и политика доступа ---

def _slug(url):
    return url.rsplit("/", 1)[1]


def test_page_owner_and_guest_when_home(client):
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    path = "/s/" + _slug(url)

    # Дефолтная политика when-home: владельца нет дома — гостю закрыто (403, не 404).
    r = client.get(path)
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "space_closed"

    # Владелец входит всегда (Bearer к своему серверу).
    page = client.get(path, headers=_auth(token))
    assert page.status_code == 200
    assert "persist=" in page.text and "rev=" in page.text and "<vrweb" in page.text

    # Хозяин дома (в комнате пространства через свой сигналинг) — дверь открыта гостям.
    room = vrweb_scene.seed_key(url)
    with client.websocket_connect("/signal") as ws:
        ws.receive_json()  # welcome
        ws.send_json({"type": "join", "room": room, "nick": "A", "access_token": token})
        assert ws.receive_json()["type"] == "peers"
        assert client.get(path).status_code == 200
    # Хозяин ушёл — снова закрыто.
    assert client.get(path).status_code == 403


def _set_policy(client, token, policy):
    # Веб-морда и REST делят один механизм сессий: токен работает и как cookie.
    client.cookies.set("vrweb_session", token)
    r = client.post("/space/settings", data={"name": "Дом", "policy": policy},
                    follow_redirects=False)
    assert r.status_code == 303
    client.cookies.clear()


def test_page_policies(client):
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    path = "/s/" + _slug(url)

    _set_policy(client, token, "public")
    assert client.get(path).status_code == 200          # открыто всем

    _set_policy(client, token, "private")
    assert client.get(path).status_code == 403          # гостю закрыто всегда
    assert client.get(path, headers=_auth(token)).status_code == 200  # владельцу — нет
    # private: даже присутствие владельца не открывает дверь гостям.
    room = vrweb_scene.seed_key(url)
    with client.websocket_connect("/signal") as ws:
        ws.receive_json()
        ws.send_json({"type": "join", "room": room, "nick": "A", "access_token": token})
        assert ws.receive_json()["type"] == "peers"
        assert client.get(path).status_code == 403


def test_room_gate_denies_guest_when_closed(client):
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    room = vrweb_scene.seed_key(url)
    with client.websocket_connect("/signal") as guest:
        guest.receive_json()
        guest.send_json({"type": "join", "room": room, "nick": "B"})
        denied = guest.receive_json()
        assert denied == {"type": "join_denied", "room": room, "reason": "space_closed"}
        # Обычные комнаты не гейтятся.
        guest.send_json({"type": "join", "room": "example.com", "nick": "B"})
        assert guest.receive_json()["type"] == "peers"


def test_room_gate_lets_guest_while_owner_home(client):
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    room = vrweb_scene.seed_key(url)
    with client.websocket_connect("/signal") as owner, client.websocket_connect("/signal") as guest:
        owner.receive_json()
        guest.receive_json()
        owner.send_json({"type": "join", "room": room, "nick": "A", "access_token": token})
        assert owner.receive_json()["type"] == "peers"
        guest.send_json({"type": "join", "room": room, "nick": "B"})
        assert guest.receive_json()["type"] == "peers"


# --- Флаш: capability, Bearer-путь, федеративный путь, 409 ---

def test_flush_capability(client):
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    cap = client.get("/api/v1/spaces/flush", params={"url": url, "address": "alice@test.local"}).json()
    assert cap["policy"] == "allowlist"
    assert cap["writable"] is True
    assert "vrweb-node" in cap["accepts_kinds"]
    cap2 = client.get("/api/v1/spaces/flush", params={"url": url, "address": "mallory@x"}).json()
    assert cap2["writable"] is False


def _page_rev(client, token, url):
    page = client.get("/s/" + _slug(url), headers=_auth(token)).text
    return page.split('rev="', 1)[1].split('"', 1)[0]


def _flush_payload(url, rev, objects):
    return json.dumps({"v": 1, "url": url, "base_rev": rev, "ts": int(time.time()),
                       "nonce": secrets.token_urlsafe(16), "objects": objects})


def test_flush_bearer_applies_and_bumps_rev(client):
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    rev = _page_rev(client, token, url)

    payload = _flush_payload(url, rev, [
        {"id": "u1.9", "kind": "vrweb-node", "parent": "",
         "props": {"tag": "OmniLight3D", "attrs": {"light_energy": "5"}}},
    ])
    r = client.post("/api/v1/spaces/flush", headers=_auth(token),
                    json={"v": 1, "payload": payload})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["status"] == "applied"
    assert out["results"]["u1.9"]["outcome"] == "applied"
    assert out["rev"] != rev
    # Страница переиздана: узел в базе с id объекта, rev сменился.
    page = client.get("/s/" + _slug(url), headers=_auth(token)).text
    assert 'id="u1.9"' in page and out["rev"] in page

    # Повтор с УЖЕ УСТАРЕВШИМ base_rev — version skew.
    r2 = client.post("/api/v1/spaces/flush", headers=_auth(token),
                     json={"v": 1, "payload": payload})
    assert r2.status_code == 409
    assert r2.json()["error"]["current_rev"] == out["rev"]


def test_flush_forbidden_for_stranger(client):
    token = _register(client)["access_token"]
    stranger = _register(client, GUEST)["access_token"]
    url = _home(client, token)["url"]
    rev = _page_rev(client, token, url)
    payload = _flush_payload(url, rev, [])
    r = client.post("/api/v1/spaces/flush", headers=_auth(stranger),
                    json={"v": 1, "payload": payload})
    assert r.status_code == 403


def test_flush_federated_identity(client):
    """Флаш по сертификату + proof (путь редактора с другого устройства/сервера).
    Домен сертификата — наш собственный, так что сеть не нужна."""
    token = _register(client)["access_token"]
    url = _home(client, token)["url"]
    rev = _page_rev(client, token, url)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub_b64 = base64.b64encode(key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
    cert = client.post("/api/v1/identity/certify", json={"public_key": pub_b64},
                       headers=_auth(token)).json()

    payload = _flush_payload(url, rev, [
        {"id": "u2.1", "kind": "vrweb-node", "parent": "",
         "props": {"tag": "Node3D", "attrs": {}}},
    ])
    proof = base64.b64encode(key.sign(PROOF_PREFIX + payload.encode(),
                                      padding.PKCS1v15(), hashes.SHA256())).decode()
    body = {"v": 1, "payload": payload,
            "identity": {"certificate_json": cert["certificate_json"],
                         "signature": cert["signature"]},
            "proof_signature": proof}
    r = client.post("/api/v1/spaces/flush", json=body)
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "applied"

    # Replay того же подписанного payload — отказ (nonce одноразовый).
    r2 = client.post("/api/v1/spaces/flush", json=body)
    assert r2.status_code in (401, 409)   # nonce/replay или rev уже ушёл — оба закрывают повтор
    # Испорченная подпись — отказ.
    bad = dict(body, proof_signature=base64.b64encode(b"nope").decode())
    assert client.post("/api/v1/spaces/flush", json=bad).status_code == 401


def test_editor_allowlist_via_webui(client):
    token = _register(client)["access_token"]
    editor_token = _register(client, GUEST)["access_token"]
    url = _home(client, token)["url"]

    # Владелец добавляет bob в редакторы через веб-морду (cookie = тот же токен-механизм).
    client.cookies.set("vrweb_session", token)
    r = client.post("/space/editors/add", data={"address": "bob@test.local"},
                    follow_redirects=False)
    assert r.status_code == 303
    client.cookies.clear()

    rev = _page_rev(client, token, url)
    payload = _flush_payload(url, rev, [
        {"id": "b1.1", "kind": "vrweb-node", "parent": "",
         "props": {"tag": "Node3D", "attrs": {}}},
    ])
    r = client.post("/api/v1/spaces/flush", headers=_auth(editor_token),
                    json={"v": 1, "payload": payload})
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "applied"
