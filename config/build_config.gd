extends Node

## Приватная конфигурация сборки (autoload «BuildConfig»).
##
## Адрес сигнального сервера и список ICE/TURN-серверов (с учётками) — приватные данные,
## которые мы не держим в коде/репозитории. Они лежат в res://config/build.private.cfg
## (этот файл в .gitignore; коммитим только шаблон config/build.example.cfg) и запекаются
## в билд через include_filter в export_presets.cfg. Здесь они читаются один раз на старте.
##
## ВНИМАНИЕ: значения попадают внутрь .pck собранного билда и извлекаемы оттуда. Это убирает
## их из исходников/репозитория, но НЕ делает «секретными» для клиента — клиенту они нужны,
## чтобы достучаться до серверов. Полностью спрятать TURN-учётку нельзя; если она утечёт —
## ротируйте её в metered.ca и обновите build.private.cfg. Подробно — docs/build-config.md.
##
## Этот автолоад зарегистрирован ПЕРВЫМ (до Settings/NetworkManager), чтобы значения были
## готовы к моменту инициализации остальных синглтонов. Загрузка идёт в _init по той же причине.

const PATH := "res://config/build.private.cfg"

## Адрес сигнального сервера (см. NetworkManager). Пусто — онлайн фактически недоступен.
var signaling_url: String = ""
## Дефолтный адрес домашнего сервера (идентичность, см. HomeServer и docs/home-server.md).
## Пользователь может сменить его в настройках; пусто — домашний сервер не преднастроен.
var home_server_url: String = ""
## Конфиг ICE-серверов для WebRTCPeerConnection.initialize(): структура { "iceServers": [...] }.
var ice_servers: Dictionary = {"iceServers": []}


func _init() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		push_warning("BuildConfig: %s не найден — онлайн-функции недоступны. "
			% PATH + "Скопируйте config/build.example.cfg в config/build.private.cfg и впишите адреса.")
		return
	signaling_url = cfg.get_value("net", "signaling_url", signaling_url)
	home_server_url = cfg.get_value("net", "home_server_url", home_server_url)
	ice_servers = cfg.get_value("webrtc", "ice_servers", ice_servers)
