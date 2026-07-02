# VRWeb — домашний сервер

Центр идентичности VRWeb (Слой 3): регистрация/логин, адреса `nickname@domain`,
сертификаты идентичности, анонс функционала и конфигурации через `/.well-known/vrweb`,
веб-морда. В этот же процесс встроен сигнальный сервер (эндпоинт `/signal`, протокол —
как у [../signaling/](../signaling/)).

**Архитектура и контракты — в [docs/home-server.md](../docs/home-server.md).**

## Запуск локально

```bash
cd homeserver
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp homeserver.example.cfg homeserver.cfg   # поправить domain
.venv/bin/python server.py
```

Сервер слушает `http://0.0.0.0:8080`: веб-морда — `/`, API — `/api/v1/...`,
discovery — `/.well-known/vrweb`, сигналинг — `ws://host:8080/signal`.

Конфиг: `homeserver.cfg` (см. [homeserver.example.cfg](homeserver.example.cfg));
любое значение можно переопределить env-переменными `VRWEB_DOMAIN`, `VRWEB_NAME`,
`VRWEB_HOMEPAGE`, `VRWEB_SIGNALING_URL`, `VRWEB_DATA_DIR`, `VRWEB_REGISTRATION_OPEN`,
`HOST`, `PORT`. Данные (SQLite + подписывающий ключ) — в `data/`; бэкапить целиком.

## Запуск в Docker

Самый простой способ — docker compose:

```bash
cd homeserver
cp .env.example .env   # поправить VRWEB_DOMAIN и остальное
docker compose up -d --build
```

Данные (SQLite + подписывающий ключ) живут в именованном volume `data` — переживают
пересборку/перезапуск контейнера.

Вручную, без compose:

```bash
cd homeserver
docker build -t vrweb-homeserver .
docker run -p 8080:8080 -e VRWEB_DOMAIN=example.com -v vrweb-data:/app/data vrweb-homeserver
```

## Тесты

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest tests -q
```

## Быстрая проверка API

```bash
curl -s localhost:8080/.well-known/vrweb | python3 -m json.tool
curl -s -X POST localhost:8080/api/v1/register \
  -H 'Content-Type: application/json' -d '{"nickname":"alice","password":"secret123"}'
```
