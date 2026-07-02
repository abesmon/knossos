"""Тесты базового контура домашнего сервера: discovery, аккаунты, сертификаты,
веб-морда, сигналинг. Запуск — python -m pytest tests -q (см. README.md)."""

import base64

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

import identity
import keys

CREDS = {"nickname": "alice", "password": "secret123"}


def _register(client, creds=CREDS):
    r = client.post("/api/v1/register", json=creds)
    assert r.status_code == 200, r.text
    return r.json()


# --- discovery ---

def test_well_known(client):
    data = client.get("/.well-known/vrweb").json()
    assert data["server"]["domain"] == "test.local"
    assert "identity.v1" in data["features"]
    assert "signaling.v1" in data["features"]
    assert data["config"]["signaling_url"] == "wss://test.local/signal"
    key = data["signing_keys"][0]
    assert key["algorithm"] == keys.ALGORITHM
    # Публичный ключ — валидный DER SPKI (RSA).
    serialization.load_der_public_key(base64.b64decode(key["public_key"]))


# --- аккаунты ---

def test_register_login_account(client):
    reg = _register(client)
    assert reg["address"] == "alice@test.local"

    r = client.get("/api/v1/account", headers={"Authorization": f"Bearer {reg['access_token']}"})
    assert r.json()["nickname"] == "alice"

    login = client.post("/api/v1/login", json=CREDS)
    assert login.json()["address"] == "alice@test.local"


def test_register_validation(client):
    bad = client.post("/api/v1/register", json={"nickname": "a!", "password": "secret123"})
    assert bad.status_code == 400
    assert bad.json()["error"]["code"] == "invalid_nickname"

    weak = client.post("/api/v1/register", json={"nickname": "bob", "password": "short"})
    assert weak.json()["error"]["code"] == "weak_password"

    _register(client)
    dup = client.post("/api/v1/register", json={"nickname": "ALICE", "password": "secret123"})
    assert dup.json()["error"]["code"] == "nickname_taken"  # ник нормализуется в lowercase


def test_login_wrong_password(client):
    _register(client)
    r = client.post("/api/v1/login", json={"nickname": "alice", "password": "wrong-one"})
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "invalid_credentials"


def test_logout_revokes_token(client):
    token = _register(client)["access_token"]
    auth = {"Authorization": f"Bearer {token}"}
    assert client.post("/api/v1/logout", headers=auth).status_code == 200
    assert client.get("/api/v1/account", headers=auth).status_code == 401


# --- сертификаты идентичности ---

def test_certify_and_verify(client):
    token = _register(client)["access_token"]
    client_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub_b64 = base64.b64encode(client_key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )).decode()

    r = client.post("/api/v1/identity/certify", json={"public_key": pub_b64},
                    headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200, r.text
    cert = r.json()

    assert cert["certificate"]["address"] == "alice@test.local"
    assert cert["certificate"]["public_key"] == pub_b64
    # certificate_json — ровно та строка, над которой стоит подпись.
    assert cert["certificate_json"] == keys.canonical_json(cert["certificate"]).decode()

    # Проверяем так, как это сделает чужой участник федерации:
    # ключ сервера — из discovery, подпись — над канонической строкой.
    server_key = client.get("/.well-known/vrweb").json()["signing_keys"][0]["public_key"]
    assert identity.verify_certificate_json(cert["certificate_json"], cert["signature"], server_key)

    # Испорченный сертификат не проходит.
    forged = keys.canonical_json(
        dict(cert["certificate"], address="mallory@test.local")
    ).decode()
    assert not identity.verify_certificate_json(forged, cert["signature"], server_key)


def test_certify_rejects_bad_key(client):
    token = _register(client)["access_token"]
    r = client.post("/api/v1/identity/certify", json={"public_key": "not-a-key"},
                    headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "bad_public_key"


def test_certify_requires_auth(client):
    r = client.post("/api/v1/identity/certify", json={"public_key": "AAAA"})
    assert r.status_code == 401


# --- веб-морда ---

def test_webui_register_flow(client):
    r = client.post("/register", data=CREDS, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/account"

    page = client.get("/account")  # cookie подхватился клиентом
    assert "alice@test.local" in page.text

    r = client.post("/logout", follow_redirects=False)
    assert r.status_code == 303
    assert client.get("/account", follow_redirects=False).status_code == 303  # снова на /login


# --- сигналинг (протокол как у standalone ../signaling/) ---

def test_signaling_join_relay_leave(client):
    with client.websocket_connect("/signal") as a, client.websocket_connect("/signal") as b:
        a_id = a.receive_json()["id"]
        b_id = b.receive_json()["id"]

        # join штампует монотонный seq (старшинство авторитета — по порядку входа в КОМНАТУ,
        # а не по id подключения; см. docs/authority.md).
        a.send_json({"type": "join", "room": "r1", "nick": "A"})
        a_joined = a.receive_json()
        a_seq = a_joined["seq"]
        assert a_joined == {"type": "peers", "seq": a_seq, "peers": []}
        assert a_seq > 0

        b.send_json({"type": "join", "room": "r1", "nick": "B"})
        b_joined = b.receive_json()
        b_seq = b_joined["seq"]
        assert b_seq > a_seq  # вошёл позже — старшинство ниже
        assert b_joined["peers"] == [{"id": a_id, "nick": "A", "seq": a_seq}]
        assert a.receive_json() == {"type": "peer_join", "id": b_id, "nick": "B", "seq": b_seq}

        a.send_json({"type": "offer", "to": b_id, "data": {"sdp": "x"}})
        assert b.receive_json() == {"type": "offer", "from": a_id, "data": {"sdp": "x"}}

        # Смена комнаты = выход из старой; новый вход = НОВЫЙ seq (старшинство не переносится).
        b.send_json({"type": "join", "room": "r2", "nick": "B"})
        b_rejoined = b.receive_json()
        assert b_rejoined["peers"] == []
        assert b_rejoined["seq"] > b_seq
        assert a.receive_json() == {"type": "peer_leave", "id": b_id}
