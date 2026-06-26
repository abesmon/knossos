# Приватный конфиг сборки

Адреса сигнального сервера и список ICE/TURN-серверов (вместе с учёткой TURN) — приватные
данные. Мы не держим их в коде/репозитории, а выносим в отдельный конфиг, который
подхватывается на запуске и запекается в билд.

## TL;DR

```bash
cp config/build.example.cfg config/build.private.cfg
# впишите в build.private.cfg свои signaling_url и ice_servers
```

- `config/build.example.cfg` — шаблон, **в гите**.
- `config/build.private.cfg` — реальные значения, **в `.gitignore`**, у каждого свой локально.
- При сборке `build.sh` проверяет наличие `build.private.cfg` и предупреждает, если его нет.

## Как это устроено

| Что | Где |
|-----|-----|
| Загрузчик | [config/build_config.gd](../config/build_config.gd) — autoload `BuildConfig`, зарегистрирован **первым** в `project.godot` |
| Файл значений | `config/build.private.cfg` (формат Godot `ConfigFile`) |
| Шаблон | [config/build.example.cfg](../config/build.example.cfg) |
| Потребители | `Settings.signaling_url` (дефолт), `NetworkManager` → `BuildConfig.ice_servers` |

`BuildConfig` читает файл один раз в `_init` (до остальных автолоадов). Если файла нет —
поля остаются пустыми (`signaling_url=""`, `ice_servers={"iceServers":[]}`) и выводится
`push_warning`: приложение запустится, но онлайн/голос работать не будут.

### Запекание в билд

`config/build.private.cfg` — не ресурс Godot, поэтому он добавлен в `include_filter` обоих
пресетов в [export_presets.cfg](../export_presets.cfg). Так файл попадает внутрь `.pck`
собранного билда, и `ConfigFile.load("res://config/build.private.cfg")` находит его в рантайме.

## Формат

```ini
[net]
signaling_url="https://signaling.example.com"   ; http(s):// нормализуется в ws(s)://

[webrtc]
ice_servers={
"iceServers": [{
"urls": ["stun:stun.l.google.com:19302"]
}, {
"urls": "turn:turn.example.com:3478",
"username": "...",
"credential": "..."
}]
}
```

`ice_servers` — это `Dictionary` ровно той структуры, что ждёт
`WebRTCPeerConnection.initialize()`.

Для нативных клиентов указывайте UDP TURN/STUN. `webrtc-native` работает через libjuice, а
TCP/TLS TURN для него не поддерживается: не добавляйте `turn:...?transport=tcp` и `turns:...`
в продовый `ice_servers`. Если в логах клиента появляются `TURN transports TCP and TLS are not
supported with libjuice`, `Got TURN CreatePermission error response`, `Received unexpected
non-STUN datagram` или `ChannelData has invalid length`, сначала проверьте, что в конфиге
остались только UDP TURN endpoint'ы и что учётка TURN активна для UDP-relay.

## Важно про «секретность»

Значения **попадают внутрь `.pck`** собранного билда и извлекаемы оттуда. Это убирает их
из исходников и репозитория, но не делает секретными для клиента — клиенту они нужны, чтобы
достучаться до серверов. Полностью спрятать TURN-учётку на стороне клиента нельзя. Если
учётка утечёт — ротируйте её в metered.ca (или у своего TURN-провайдера) и обновите
`build.private.cfg`.

См. также [multiplayer.md](multiplayer.md) (STUN/TURN, сигналинг) и [build.md](build.md).
