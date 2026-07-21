extends Node

## Главный контроллер VRWeb: адресная строка -> загрузка HTML -> парсинг ->
## топология (артефакт без координат) -> геометрия (3D-пространство) -> навигация.
## Связывает сервисы; сам логику трансляции не содержит.

const PLAYER_SCENE := preload("res://actors/player/player.tscn")
const REMOTE_VIEW_SCRIPT := preload("res://scripts/remote_players_view.gd")
const EPHEMERAL_VIEW_SCRIPT := preload("res://scripts/ephemeral_view.gd")

@onready var _world: Node3D = $world
@onready var _ui: MainUI = $UI
@onready var _loading_hub: LoadingHub = $LoadingHub
@onready var _address: LineEdit = _ui.address
# cancel/refresh — одно место в навбаре: во время загрузки виден cancel (прервать),
# в покое — refresh (перезагрузить). Переключает _set_loading.
@onready var _cancel: Button = _ui.cancel
@onready var _refresh: Button = _ui.refresh
@onready var _back_btn: Button = _ui.back_button
@onready var _fwd_btn: Button = _ui.forward_button
@onready var _settings_btn: Button = _ui.settings_button

var _fetcher: PageFetcher
# Загрузчик внешних CSS (docs/css-cascade.md). Постоянный (не в _world): стили нужны до
# сборки мира, а кэш переживает навигацию — same-site переходы не качают таблицы заново.
var _css_fetcher: CssFetcher
var _script_fetcher: VrwebScriptFetcher
var _script_runtime: VrwebLuauRuntime
var _script_pick_open := false   # OS-диалог document.files.pick уже открыт (один на клиента)
var _address_focus_token := 0
var _settings_focus_token := 0
var _chat_focus_token := 0
var _console_focus_token := 0
# Пока активного мира нет, отдельный lease удерживает свободный курсор для навигационного UI.
# Это также закрывает синхронную ошибку fetch: хвост _on_go не сможет снова захватить мышь.
var _loading_hub_focus_token := 0
# Максимум ожидания внешних таблиц: дальше строим мир с тем, что успело прийти.
const CSS_DEADLINE_SEC := 4.0
# Номер навигации: guard от гонки «продолжение после загрузки CSS против новой навигации».
var _nav_id := 0
var _player: Player
# Активный генератор мира. Держим сильную ссылку, пока он достраивает геометрию порциями
# по кадрам (WorldGenerator — RefCounted; без ссылки его корутина-достройка собралась бы GC
# после _rebuild_world и не возобновилась). Перезапись при следующей навигации освобождает
# старый — его корутина увидит снесённый контейнер и сама прекратится.
var _world_gen: WorldGenerator = null
# Процедурный HTML живёт отдельно от VRWML/overlay/network views, чтобы instance config mode
# мог снять/вернуть только его без навигации и пересборки комнаты.
var _html_layer: Node3D = null
var _page_space: Dictionary = {}
var _page_seed := 0
var _world_image_loader: ImageLoader = null
var _video_manager: VrwebVideoManager = null
var _grab_manager: GrabManager = null
var _item_toolbelt: ItemToolbelt = null
var _base_scene_mode := VrwebBuilder.MODE_COMBINE
var _effective_scene_mode := VrwebBuilder.MODE_COMBINE
@onready var _status: Label = _ui.status
# «Светофор» связи слева от строки статуса: цвет = агрегированное состояние WebRTC-связи
# (NetworkManager.connection_status), тултип — развёрнутый текст. Кружок = Panel с круглым
# StyleBoxFlat, чей bg_color мы перекрашиваем.
@onready var _conn_dot: Panel = _ui.connection_dot
var _conn_dot_style: StyleBoxFlat
@onready var _passive_cursor: TextureRect = _ui.passive_cursor
@onready var _active_cursor: TextureRect = _ui.active_cursor

# Индикаторы голоса (низ экрана): два стека — «звук идёт» (micon) и «заглушено» (micoff, красный),
# в каждом — иконка PTT (видна только в режиме push-to-talk) и иконка микрофона. Активный стек
# выбирается по политике режима, активная иконка «дышит» прозрачностью по силе голоса.
@onready var _indicators: Control = _ui.indicators
@onready var _micon_stack: Control = _ui.mic_on_stack
@onready var _micoff_stack: Control = _ui.mic_off_stack
@onready var _micon_ptt: CanvasItem = _ui.mic_on_ptt
@onready var _micoff_ptt: CanvasItem = _ui.mic_off_ptt

## Индикатор голоса: не прозрачнее этого, пока есть речь; после SILENCE_HIDE тишины — 0 (исчезает).
const VOICE_INDICATOR_MIN_ALPHA := 0.25
const VOICE_INDICATOR_SILENCE_HIDE := 3.0
## Постоянная времени сглаживания прозрачности (с): индикатор «дышит» с запаздыванием/буфером,
## тянется к цели экспоненциально, а не повторяет силу голоса кадр-в-кадр.
const VOICE_INDICATOR_TAU := 0.25
## Сколько времени VAD не видит речи (с). Копится, пока молчим; при речи сбрасывается.
var _voice_silence := VOICE_INDICATOR_SILENCE_HIDE
## Сглаженная (с запаздыванием) прозрачность активной иконки индикатора [0..1].
var _voice_indicator_alpha := 0.0
var _current_url: String = ""
# База для относительных URL (учитывает <base href>); по умолчанию = _current_url.
var _base_url: String = ""
# «Паспорт» текущей страницы из <head> (title/description/thumbnail/metas) — заполняется в
# _on_fetched и отдаётся вкладке «Мир» настроек (см. _extract_page_meta).
var _page_meta: Dictionary = {}
# Фактические hashes executable modules текущей страницы. Пока runtime поддерживает inline
# allow-all; структура уже пригодна для compatibility/trust UI следующих этапов.
var _script_hashes: Dictionary = {}
var _content_policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
# ХРАНИМОЕ дерево HtmlNode текущей страницы — источник HTML-репрезентации пространства для
# консоли (`~`). Из геометрии HTML не восстановим, поэтому документ живёт здесь после парсинга.
var _current_doc: HtmlNode = null
# Индекс узлов vrweb-слоя страницы (детерминированные id, см. SceneHtml.build_page_index):
# по нему консоль сливает страницу с эфемерным оверлеем, а вьюха адресует живые узлы.
var _vrweb_index: Dictionary = {"found": false, "attrs": {}, "top": [], "nodes": {}}
# Консоль пространства (клавиша `~`): HTML-репрезентация + редактирование эфемерного слоя.
@onready var _console: SpaceConsole = _ui.console
# Браузерная история: список записей {url, pose} и индекс текущей. Переход назад/вперёд
# двигает _history_index; новая навигация обрезает «вперёд» и добавляет запись.
var _history: Array[Dictionary] = []
var _history_index: int = -1
# Поза игрока (get_pose), которую нужно восстановить после загрузки при переходе по
# истории, вместо дефолтного спавна страницы. null — обычная навигация.
var _pending_restore_pose: Variant = null
var _label_positions: Dictionary = {}
var _loading: bool = false
# true, пока запись истории под _history_index создана push-навигацией, которая ещё не
# закоммитилась в _on_fetched (страница не загрузилась). Позволяет заменить такой «фантом»
# при повторной навигации, а не копить его (омнибокс браузера: A→C, а не A→B→C).
var _pending_history_push: bool = false

var _ui_pick_finish: Callable = Callable()   # ожидающий fallback-пикер document.files.pick
@onready var _settings_overlay: Control = _ui.settings_overlay
@onready var _debug_panel: PanelContainer = _ui.debug_panel
@onready var _debug_label: Label = _ui.debug_label
var _remote_view: Node3D
@onready var _chat_root: VBoxContainer = _ui.chat_root
@onready var _chat_log: RichTextLabel = _ui.chat_log
@onready var _chat_input: LineEdit = _ui.chat_input
# Чат живёт только в RAM: кольцевой буфер последних CHAT_HISTORY_MAX записей, на диск ничего
# не пишется. Запись = {kind:"user", nick, text} либо {kind:"system", text} (отбивки переходов).
const CHAT_HISTORY_MAX := 50
var _chat_history: Array[Dictionary] = []
# Таймер угасания: в режиме перемещения через 30с после последнего сообщения лог гаснет до 10%.
@onready var _chat_idle_timer: Timer = _ui.chat_idle_timer
var _chat_fade_tween: Tween
# Захвачена ли мышь (режим перемещения) — определяет вид чата: поле ввода и угасание.
var _mouse_captured: bool = true


func _ready() -> void:
	_setup_environment()
	_setup_ui_extras()
	_ui.image_file_chosen.connect(_on_ui_file_chosen)

	_fetcher = PageFetcher.new()
	add_child(_fetcher)
	_fetcher.fetched.connect(_on_fetched)
	_fetcher.failed.connect(_on_failed)

	_css_fetcher = CssFetcher.new()
	add_child(_css_fetcher)
	_script_fetcher = VrwebScriptFetcher.new()
	add_child(_script_fetcher)

	_player = PLAYER_SCENE.instantiate()
	_player.aim_target_changed.connect(_on_aim_target_changed)
	_player.debug_toggled.connect(_on_debug_toggled)
	_player.debug_probed.connect(_on_debug_probed)
	# Браузинг мира и UI взаимоисключающи: пока мышь захвачена, элементы навбара/чата
	# делаем нефокусируемыми, чтобы их нельзя было активировать с клавиатуры (Tab/Space/Enter).
	_player.mouse_capture_changed.connect(_on_mouse_capture_changed)
	# Enter в браузинге открывает строку чата (быстрый ввод сообщения без клика).
	_player.chat_requested.connect(_on_chat_requested)
	# Esc при уже свободной мыши (возимся с UI) открывает настройки.
	_player.settings_requested.connect(_open_settings)
	_world.add_child(_player)
	# Системные инструменты (пузырь, см. docs/client/tools.md) создаются в Player._ready —
	# подключаемся после add_child. Пользовательские инструменты теперь — переносимые предметы
	# (ItemToolbelt в _rebuild_world, docs/space/portable-tools.md).
	_player.tools.status_hint.connect(_set_status)

	_cancel.pressed.connect(_on_cancel)
	_refresh.pressed.connect(_on_refresh)
	_back_btn.pressed.connect(_on_back_pressed)
	_fwd_btn.pressed.connect(_on_fwd_pressed)
	_update_nav_buttons()
	_set_loading(false)
	_address.text_submitted.connect(func(_t): _on_go())
	# При клике в адресную строку отпускаем мышь, чтобы можно было печатать.
	_address.focus_entered.connect(_claim_address_focus)
	_address.focus_exited.connect(_release_address_focus)

	_setup_net()
	# До первой успешно собранной страницы клиент уже находится «между мирами».
	# Хаб остаётся 3D-фоном, а навигационный UI доступен для ввода стартового адреса.
	_remain_in_loading_hub()

	_set_status("Введите адрес и go! — WASD ходьба, двойной пробел — полёт, ЛКМ/E — портал, колесо/тачпад — скролл текста, F3 — отладка, Esc — мышь")

	# При запуске всегда отпускаем мышь (Player._ready захватил её): это снова делает UI
	# фокусируемым — без этого ни grab_focus, ни клики по навбару не сработают. В режим
	# перемещения пользователь войдёт сам кликом по 3D.
	_player.capture_mouse(false)
	# Стартовый адрес: диплинк (приложение открыли по собственной схеме vrwebresource://… —
	# ОС передала URL аргументом, см. Deeplink) имеет приоритет над домашней страницей.
	# Оба грузятся как ввод в омнибоксе: абсолютный URL, без базы. Если ни того, ни другого —
	# ставим фокус в адресную строку, чтобы можно было печатать без лишнего клика.
	var start_url := Deeplink.launch_url()
	if start_url == "":
		start_url = Settings.home_page.strip_edges()
	if start_url != "":
		_address.text = start_url
		_navigate(start_url, "", true)
	else:
		_address.grab_focus()


func _process(delta: float) -> void:
	_update_voice_indicators(delta)


## `~` (клавиша слева от 1) — консоль пространства, как DevTools в браузере. Перехватываем в
## _input (раньше GUI), иначе бэктик напечатался бы в редактор консоли при закрытии. Нюанс
## раскладок: на русской эта физическая клавиша печатает «ё» — если фокус в текстовом поле и
## клавиша даёт НЕ бэктик/тильду, пропускаем событие в поле (набор «ё» в чате/консоли), а
## бэктик переключает консоль из любого места.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if not event.is_action("ui_console_toggle") or event.is_command_or_control_pressed():
		return
	var focus := get_viewport().gui_get_focus_owner()
	var typing := focus is LineEdit or focus is TextEdit
	var is_backtick: bool = event.unicode == 96 or event.unicode == 126 or event.unicode == 0
	if typing and not is_backtick:
		return
	_toggle_console()
	get_viewport().set_input_as_handled()


func _toggle_console() -> void:
	if _console == null:
		return
	if _console.visible:
		_console.close()
		_release_focus_token("_console_focus_token")
	else:
		# Консоль — UI-режим: отпускаем мышь (обратно в браузинг вернёт клик по 3D,
		# который заодно закроет консоль — см. _on_mouse_capture_changed).
		_console_focus_token = _player.claim_mouse_focus("space_console")
		_console.open()
	_sync_chat_with_console()


## Пока консоль открыта — прячем чат (он перекрывался бы её нижней половиной и отвлекал);
## при закрытии возвращаем видимость по обычным правилам (онлайн-состояние).
func _sync_chat_with_console() -> void:
	if _chat_root == null:
		return
	if _console != null and _console.visible:
		_chat_root.visible = false
	else:
		_update_chat_visibility()


## Индикаторы голоса внизу экрана (см. поля выше). Показываем только онлайн (микрофон работает
## лишь тогда). Выбираем стек по политике режима (micon — звук идёт, micoff — заглушено), в PTT
## дополнительно светим иконку PTT. Активную иконку «дышим» прозрачностью по силе голоса: не
## прозрачнее VOICE_INDICATOR_MIN_ALPHA, пока идёт речь; после VOICE_INDICATOR_SILENCE_HIDE секунд
## тишины — полностью прозрачной. micoff подсвечиваем ТОЙ ЖЕ логикой (на мьюте видно, что «звук
## есть, но ты заглушён»).
## Имитация «чуть звука прошло» на взаимодействие с голосом: сбрасываем таймер тишины — индикатор
## всплывает как минимум до VOICE_INDICATOR_MIN_ALPHA (даже без реального сигнала) и, как обычно,
## гаснет через VOICE_INDICATOR_SILENCE_HIDE секунд, если нового сигнала не будет.
func _on_voice_nudge() -> void:
	_voice_silence = 0.0


func _update_voice_indicators(delta: float) -> void:
	if _indicators == null:
		return
	var online := NetworkManager.is_online()
	_indicators.visible = online
	if not online:
		_voice_silence = VOICE_INDICATOR_SILENCE_HIDE
		_voice_indicator_alpha = 0.0
		return

	if VoiceManager.is_speaking():
		_voice_silence = 0.0
	else:
		_voice_silence += delta
	var target := 0.0
	if _voice_silence < VOICE_INDICATOR_SILENCE_HIDE:
		target = clampf(VoiceManager.input_level() * AvatarParams.VOICE_RMS_GAIN,
			VOICE_INDICATOR_MIN_ALPHA, 1.0)
	# «Дышим» с запаздыванием/буфером: тянемся к цели экспоненциально, а не повторяем силу 1:1.
	_voice_indicator_alpha = lerpf(_voice_indicator_alpha, target, 1.0 - exp(-delta / VOICE_INDICATOR_TAU))

	var sound_on := VoiceManager.is_sound_on()
	var ptt := VoiceManager.is_ptt()
	# Активный стек по политике режима; при полной тишине (альфа спала к нулю) скрываем стек
	# ЦЕЛИКОМ, а не гасим отдельную иконку. Прозрачность задаём модуляцией стека — красный
	# micoffstack сохраняет RGB, меняется только alpha; иконка PTT «дышит» вместе со стеком.
	var shown := _voice_indicator_alpha > 0.01
	_micon_stack.visible = sound_on and shown
	_micoff_stack.visible = not sound_on and shown
	_micon_stack.modulate.a = _voice_indicator_alpha
	_micoff_stack.modulate.a = _voice_indicator_alpha
	# Иконка PTT — только в режиме push-to-talk (в активном, видимом стеке).
	_micon_ptt.visible = ptt
	_micoff_ptt.visible = ptt


func _on_go() -> void:
	var url := _address.text.strip_edges()
	if url == "":
		return
	# Новый адрес во время загрузки — как в омнибоксе браузера: отменяем текущую (незавершённую)
	# загрузку и стартуем актуальную. _navigate сам прервёт in-flight запрос и заменит фантомную
	# запись истории вместо накопления (см. _cancel_load и ветку push в _navigate).
	# Ввод в адресной строке — это абсолютный адрес, а не путь относительно текущей страницы.
	# Поэтому base пустой: иначе домен «abesmon.syrupmg.ru» приклеится к текущему пути.
	# Относительный резолв нужен только для внутристраничных ссылок (см. _activate_transition).
	_navigate(url, "", true)
	_release_address_focus()
	_player.capture_mouse(true)


## Cancel в навбаре: прерывает текущую загрузку и снимает флаг (в отличие от навигации, новую
## не начинаем). Остановку запроса и инвалидацию отложенного CSS-колбэка делает _cancel_load.
func _on_cancel() -> void:
	if not _loading:
		return
	_cancel_load()
	_set_loading(false)
	_remain_in_loading_hub()
	_set_status("Загрузка отменена")


## Прерывает текущую загрузку: останавливает HTTP-запрос и инвалидирует возможный отложенный
## CSS-колбэк предыдущей навигации (bump _nav_id, см. _on_fetched). Флаг _loading не трогает —
## его выставит вызывающий (_on_cancel снимает, _navigate тут же поднимает под новую загрузку).
func _cancel_load() -> void:
	_fetcher.cancel()
	if _script_fetcher != null:
		_script_fetcher.cancel()
	_nav_id += 1


## Refresh в навбаре: перезагружает текущую страницу, сохраняя позу игрока (как reload
## в браузере не телепортирует). Без истории — это тот же URL, а не новый переход.
func _on_refresh() -> void:
	if _current_url == "" or _loading:
		return
	_pending_restore_pose = _player.get_pose()
	_navigate(_current_url, "", false)


## Переключает индикацию загрузки в навбаре: во время загрузки виден cancel, в покое — refresh.
func _set_loading(loading: bool) -> void:
	_loading = loading
	if _cancel != null:
		_cancel.visible = loading
	if _refresh != null:
		_refresh.visible = not loading


## При входе в браузинг мира (мышь захвачена) запрещаем фокус UI, чтобы клавиатура их не
## достала; при выходе — снова разрешаем кликать и печатать в навбаре/чате.
func _on_mouse_capture_changed(captured: bool) -> void:
	_set_ui_focusable(not captured)
	_mouse_captured = captured
	# Возврат в браузинг (клик по 3D) закрывает консоль: печатать в ней всё равно нельзя,
	# а нижняя половина экрана мешала бы обзору. Правки при этом не теряются (см. open).
	if captured and _console != null and _console.visible:
		_console.close()
		_sync_chat_with_console()
	# В режиме перемещения поле ввода не нужно (печатать всё равно нельзя — оно открывается
	# по Enter через _on_chat_requested), показываем только лог; в UI-режиме — лог + поле.
	if _chat_input != null:
		_chat_input.visible = not captured
	# Смена режима будит чат: полная видимость и заново заведённый таймер угасания
	# (он стартует лишь в режиме перемещения, см. _chat_wake).
	_chat_wake()


## Enter в браузинге мира — открываем строку чата: освобождаем мышь (делает UI фокусируемым)
## и ставим фокус в поле ввода. Отправка по Enter (или пустой Enter) вернёт в браузинг через
## _on_chat_submitted. Работает только когда чат показан (онлайн).
func _on_chat_requested() -> void:
	if _chat_input == null or _chat_root == null or not _chat_root.visible:
		return
	if _chat_focus_token == 0:
		_chat_focus_token = _player.claim_mouse_focus("chat_input")
	_chat_input.grab_focus()


func _claim_address_focus() -> void:
	if _address_focus_token == 0:
		_address_focus_token = _player.claim_mouse_focus("address_bar")


func _release_address_focus() -> void:
	_player.release_mouse_focus(_address_focus_token)
	_address_focus_token = 0


func _release_focus_token(property: StringName) -> void:
	var token := int(get(property))
	_player.release_mouse_focus(token)
	set(property, 0)


## Разрешает/запрещает фокусировку интерактивных элементов навбара и чата. FOCUS_NONE убирает
## их из обхода по Tab и не даёт активировать с клавиатуры; мышиный клик кнопкам не нужен —
## он всё равно сработает (а при захваченной мыши кликнуть по ним и так нельзя).
func _set_ui_focusable(focusable: bool) -> void:
	var mode := Control.FOCUS_ALL if focusable else Control.FOCUS_NONE
	for c: Control in [_address, _cancel, _refresh, _back_btn, _fwd_btn, _settings_btn, _chat_input]:
		if c != null:
			c.focus_mode = mode
	# Логу чата хватает фокуса по клику (выделение + Ctrl/Cmd+C); в режиме перемещения
	# фокус снимаем, чтобы клавиатура его не доставала (как и прочий UI выше).
	if _chat_log != null:
		_chat_log.focus_mode = Control.FOCUS_CLICK if focusable else Control.FOCUS_NONE


func _navigate(url: String, base: String, push_history: bool) -> void:
	# Пузырь «ушёл сюда» роняем до входа в хаб: после него старый мир и соединение уже сняты.
	# См. _drop_leave_bubble и docs/ephemeral-changes.md.
	# Любая новая навигация отменяет ещё идущую (иначе старый ответ мог бы «доехать» поверх новой).
	if _loading:
		_cancel_load()
	# Переход начинается в нейтральном хабе: покинутая страница больше не видна и не
	# продолжает исполняться, а сетевое соединение с её комнатой гарантированно закрыто.
	# Пузырь роняем до сноса мира; здесь URL ещё до возможного HTTP-редиректа.
	if _current_url != "":
		_drop_leave_bubble(PageFetcher.resolve_url(url, base if base != "" else _current_url))
	_enter_loading_hub("Загрузка %s" % url)
	_set_loading(true)
	_set_status("Загрузка %s …" % url)
	if push_history:
		if _pending_history_push:
			# Предыдущий push-переход ещё не закоммитился (страница не загрузилась) — заменяем
			# его запись, а не копим фантом невыполненного перехода (омнибокс: A→C, не A→B→C).
			_history[_history_index] = {"url": url, "pose": null}
		else:
			# Уходим со страницы по новой ссылке: запоминаем позу в текущей записи, обрезаем
			# ветку «вперёд» (как браузер) и добавляем новую запись. URL запишется финальным
			# (после возможного редиректа) в _on_fetched.
			_capture_current_pose()
			_history.resize(_history_index + 1)
			_history.append({"url": url, "pose": null})
			_history_index = _history.size() - 1
		_pending_history_push = true
	else:
		# reload/назад-вперёд идут по уже существующей (закоммиченной) записи — фантома нет.
		_pending_history_push = false
	_update_nav_buttons()
	_fetcher.fetch(url, base)


## Роняет «пузырь» — временный портал «ушёл сюда» — в покидаемой комнате через системный
## BubbleTool. Зовётся из _on_fetched (переход состоялся), пока _current_url ещё старый.
## Навигационные проверки — здесь (это знание о навигации, не об инструменте): переход только
## если целевая комната (seed_key) отличается от текущей (иначе это reload/переход внутри той же
## страницы — пузырь не нужен). target — финальный адрес назначения (после редиректа).
## См. docs/ephemeral-changes.md и docs/client/tools.md.
func _drop_leave_bubble(target: String) -> void:
	if _current_url == "" or _player == null:
		return
	if target == "" or PageFetcher.seed_key(target) == PageFetcher.seed_key(_current_url):
		return
	var bubble: BubbleTool = _player.tools.get_tool(&"bubble")
	bubble.drop(target)


func _on_fetched(html: String, final_url: String) -> void:
	_current_url = final_url
	_address.text = final_url
	# Переход состоялся — запись истории закоммичена, она больше не «фантом» (см. _navigate).
	_pending_history_push = false
	# Запись истории хранит финальный URL (после редиректа) — по нему пойдёт назад/вперёд.
	if _history_index >= 0 and _history_index < _history.size():
		_history[_history_index]["url"] = final_url

	var t0 := Time.get_ticks_msec()
	var doc := HtmlParser.parse(html)
	# Дерево документа храним: консоль пространства сериализует ЕГО (HTML не восстановим
	# из построенной геометрии). Один источник и для топологии, и для репрезентации.
	_current_doc = doc
	# <base href> (стандарт HTML) переопределяет базу для относительных ссылок/ресурсов;
	# без него база = адрес страницы. seed/история/комната по-прежнему по final_url.
	var base_url := _resolve_base_url(doc, final_url)
	_base_url = base_url
	# «Паспорт» страницы из <head> для вкладки «Мир» в настройках (заголовок/описание/превью).
	_page_meta = _extract_page_meta(doc, base_url, final_url)

	# Мини-каскад CSS (docs/css-cascade.md): собираем ссылки на таблицы; внешние качает
	# CssFetcher с дедлайном — по его истечении едем с тем, что пришло. _loading остаётся
	# true до _finish_page (двойной go! во время загрузки стилей заблокирован), _nav_id
	# отсекает продолжение, если за время загрузки началась новая навигация.
	_nav_id += 1
	var nav := _nav_id
	var sheet_refs := StyleResolver.collect_sheet_refs(doc)
	var hrefs: Array = []
	for ref in sheet_refs:
		if ref["kind"] == "link" and CssParser.media_matches(ref["media"]):
			var abs_url := PageFetcher.resolve_url(ref["href"], base_url)
			if abs_url != "" and not hrefs.has(abs_url):
				hrefs.append(abs_url)
	if hrefs.is_empty():
		# Без внешних таблиц — синхронно (локальные/простые страницы не ждут лишний кадр).
		_finish_page(doc, sheet_refs, {}, final_url, base_url, t0)
	else:
		_set_status("Загрузка стилей (%d)…" % hrefs.size())
		_css_fetcher.fetch_all(hrefs, CSS_DEADLINE_SEC,
			func(css_by_url: Dictionary):
				if nav == _nav_id:
					_finish_page(doc, sheet_refs, css_by_url, final_url, base_url, t0))


## Продолжение сборки страницы после (возможной) загрузки внешних CSS.
func _finish_page(doc: HtmlNode, sheet_refs: Array, css_by_url: Dictionary,
		final_url: String, base_url: String, t0: int) -> void:
	_set_status("Подготовка страницы…")
	# Тексты таблиц в порядке документа (<style> и <link> вперемешку) = порядок каскада.
	var css_texts: Array = []
	for ref in sheet_refs:
		if not CssParser.media_matches(ref["media"]):
			continue
		if ref["kind"] == "inline":
			css_texts.append(ref["text"])
		else:
			css_texts.append(css_by_url.get(PageFetcher.resolve_url(ref["href"], base_url), ""))
	StyleResolver.resolve(doc, css_texts)
	var collection := VrwebScriptDeclaration.collect(doc, base_url)
	for script_error in collection.errors:
		Log.warn("scripts", str(script_error))
	var nav := _nav_id
	_set_status("Загрузка скриптов (%d)…" % collection.scripts.size())
	_script_fetcher.fetch_all(collection.scripts, func(script_result: Dictionary):
		if nav == _nav_id:
			_materialize_page(doc, final_url, base_url, t0, script_result))


func _materialize_page(doc: HtmlNode, final_url: String, base_url: String, t0: int,
		script_result: Dictionary) -> void:
	# Собственный синтаксис VRWeb: блок <vrwml> описывает 3D-сцену напрямую узлами Godot.
	# mode="exclusive" — HTML игнорируется; "combine" — сцена vrweb добавляется поверх HTML.
	# base_url — база для резолва путей внешних ресурсов (<ExtResource>, <img>, <video>).
	for script_error in script_result.errors:
		Log.warn("scripts", "%s: %s" % [str(script_error.get("script_id", "")),
				str(script_error.get("code", ""))])
	_finish_materialize_page(doc, final_url, base_url, t0, script_result.scripts)


func _finish_materialize_page(doc: HtmlNode, final_url: String, base_url: String, t0: int,
		scripts: Array) -> void:
	var navigation := _nav_id
	_set_loading(false)
	_set_status("Сборка пространства…")
	var vrweb := VrwebBuilder.build(doc, base_url, _content_policy)
	# Индекс vrweb-узлов страницы (детерминированные id) — основа слитого документа консоли
	# и адресации эфемерного оверлея (vrweb-patch/vrweb-node). См. docs/space-console.md.
	_vrweb_index = SceneHtml.build_page_index(doc)
	# id узлов базы резервируются в эфемерном слое: add с таким id отклоняется — объект с id
	# из базы может быть только её запечённой копией (дедуп персистенции, docs/page-persistence.md).
	var reserved := {}
	for nid in _vrweb_index.get("nodes", {}):
		reserved[nid] = true
	NetworkManager.set_scene_reserved_ids(reserved)
	# debug=true: топология записывает провенанс (id -> исходный HTML), а WorldGenerator
	# вешает его на узлы — для отладочного инспектора прицела (F3, см. _on_debug_*).
	var space := TopologyBuilder.build(doc, true)
	_rebuild_world(space, final_url, vrweb, base_url)
	# scene-ready: _ready() уже прошёл при add_child, но физические тела и viewport input
	# становятся наблюдаемыми только на границе physics frame. Page scripts по умолчанию
	# стартуют после этой границы, а не в промежуточном состоянии материализации.
	await get_tree().physics_frame
	# Пока ждали lifecycle boundary, пользователь мог начать другую навигацию.
	if navigation != _nav_id:
		return
	_script_runtime = VrwebLuauRuntime.new()
	_script_runtime.name = "VrwebLuauRuntime"
	_script_runtime.file_picker = _script_file_picker()
	_world.add_child(_script_runtime)
	var script_root: Node = vrweb.get("root")
	if script_root == null:
		var generated_root := Node3D.new()
		generated_root.name = "ScriptObjects"
		_world.add_child(generated_root)
		script_root = generated_root
	_script_runtime.setup(script_root, _build_script_targets(vrweb), base_url, _player,
			_content_policy)
	var script_activation := _script_runtime.activate(scripts)
	for script_error in script_activation.errors:
		Log.warn("scripts", "%s/%s: %s" % [str(script_error.script_id),
				str(script_error.phase), str(script_error.message)])
	_script_hashes = _script_runtime.active_hashes()
	# Переход назад/вперёд: возвращаем игрока туда, где он стоял на этой странице, поверх
	# дефолтного спавна из _rebuild_world. Мир детерминирован по URL, поза остаётся валидной.
	if _pending_restore_pose != null:
		_player.restore_pose(_pending_restore_pose)
		_pending_restore_pose = null
	var dt := Time.get_ticks_msec() - t0

	var room_count: int = space.get("rooms", {}).size()
	_set_status("%s — %d пространств, %d мс" % [final_url, room_count, dt])
	_leave_loading_hub()

	# Новая страница — старый документ консоли (и правки к нему) больше не имеют смысла.
	if _console != null:
		_console.on_navigated()

	# Комната мультиплеера = страница. В онлайне переключаемся на комнату нового URL
	# (NetworkManager рвёт старые p2p-соединения и пересоздаёт mesh).
	_join_current_room()

	# Отбивка в чате — граница между мирами в общей (сквозной) истории. Только онлайн:
	# оффлайн чат скрыт, а собеседников нет.
	if Settings.online_enabled:
		_push_system_chat("Присоединились к миру %s" % final_url)


func _on_failed(message: String, url: String) -> void:
	_set_loading(false)
	_remain_in_loading_hub()
	_set_status("Ошибка: %s (%s)" % [message, url])


## <base href> переопределяет базовый адрес для относительных URL (стандарт HTML). Сам href
## может быть относительным/protocol-relative — резолвим его относительно адреса страницы.
func _resolve_base_url(doc: HtmlNode, page_url: String) -> String:
	var base := doc.find_descendant("base")
	if base != null:
		var href := base.get_attr("href").strip_edges()
		if href != "":
			return PageFetcher.resolve_url(href, page_url)
	return page_url


## Человекочитаемые meta-теги для вкладки «Мир» — только осмысленные подписи, без технических
## (viewport, charset, theme-color и т.п.). Ключ (lowercase name/property) → подпись. Заголовок,
## описание и превью показываются отдельно, поэтому их здесь нет.
const MEANINGFUL_META := {
	"author": "Автор",
	"article:author": "Автор",
	"og:site_name": "Сайт",
	"application-name": "Приложение",
	"keywords": "Ключевые слова",
	"og:type": "Тип",
	"article:published_time": "Опубликовано",
	"article:section": "Раздел",
}


## Собирает «паспорт» страницы из <head>: заголовок (<title> или og:title), описание
## (description/og:description), превью (og:image/twitter:image, резолвится относительно базы)
## и осмысленные meta-теги (без технических). Отдаётся настройкам в _open_settings.
func _extract_page_meta(doc: HtmlNode, base_url: String, url: String) -> Dictionary:
	var metas: Array = []
	_collect_meta(doc, metas)
	var description := ""
	var og_title := ""
	var thumb := ""
	# Только человекочитаемые теги из белого списка (с подписью), без дублей по подписи.
	var info: Array = []
	var seen_labels := {}
	for m in metas:
		var key: String = m["key"]
		var value: String = m["value"]
		match key.to_lower():
			"description", "og:description", "twitter:description":
				if description == "":
					description = value
			"og:title", "twitter:title":
				if og_title == "":
					og_title = value
			"og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src":
				if thumb == "":
					thumb = value
		var label: String = MEANINGFUL_META.get(key.to_lower(), "")
		if label != "" and not seen_labels.has(label):
			seen_labels[label] = true
			info.append({"label": label, "value": value})
	var title_node := doc.find_descendant("title")
	var title := title_node.collect_text().strip_edges() if title_node != null else ""
	if title == "":
		title = og_title
	if thumb != "":
		thumb = PageFetcher.resolve_url(thumb, base_url)
	return {
		"url": url,
		"title": title,
		"description": description,
		"thumbnail": thumb,
		"metas": info,
	}


## Рекурсивно собирает meta-теги поддерева в out как [{key, value}]. key — name или property,
## value — content. Пустые ключ/значение пропускаем.
func _collect_meta(node: HtmlNode, out: Array) -> void:
	for c in node.children:
		if c.tag == "meta":
			var key := c.get_attr("name")
			if key == "":
				key = c.get_attr("property")
			var value := c.get_attr("content")
			if key != "" and value != "":
				out.append({"key": key, "value": value})
		_collect_meta(c, out)


## Переводит клиент в нейтральное состояние между страницами. В отличие от прежнего
## in-place swap старый мир прекращает жить сразу, а не после ответа сервера/разрешений.
func _enter_loading_hub(status: String) -> void:
	_release_focus_token(&"_loading_hub_focus_token")
	_ui.visible = false
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	_loading_hub.open(status)
	_clear_world()
	NetworkManager.disconnect_from_server()


## Оставляет клиент в нейтральном пространстве без активного мира. В отличие от перехода,
## навигационный UI доступен: после ошибки/отмены можно ввести другой адрес. Хаб закрывается
## только когда новый мир действительно собран.
func _remain_in_loading_hub() -> void:
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	_loading_hub.open()
	_ui.visible = true
	if _loading_hub_focus_token == 0:
		_loading_hub_focus_token = _player.claim_mouse_focus("loading_hub_navigation")


## Возвращает обычную камеру, HUD и обработку игрока только после успешной сборки мира.
func _leave_loading_hub() -> void:
	_release_focus_token(&"_loading_hub_focus_token")
	_loading_hub.close()
	_player.process_mode = Node.PROCESS_MODE_INHERIT
	_ui.visible = true


## Удаляет всё содержимое страницы, сохраняя локального Player как контроллер следующего мира.
## remove_child нужен сразу: queue_free удаляет из дерева только в конце кадра.
func _clear_world() -> void:
	if is_instance_valid(_script_runtime):
		_script_runtime.close()
	_script_runtime = null
	_script_hashes.clear()
	_world_gen = null
	_html_layer = null
	_page_space = {}
	_world_image_loader = null
	_video_manager = null
	_grab_manager = null
	_item_toolbelt = null
	_base_scene_mode = VrwebBuilder.MODE_COMBINE
	_effective_scene_mode = VrwebBuilder.MODE_COMBINE
	_remote_view = null
	for child in _world.get_children():
		if child == _player:
			continue
		_world.remove_child(child)
		child.queue_free()


## Stable document id -> materialized object map shared by scripting and live overlays.
func _build_script_targets(vrweb: Dictionary) -> Dictionary:
	var targets := {}
	var node_map: Dictionary = vrweb.get("nodes", {})
	for node_id in _vrweb_index.get("nodes", {}):
		var record: Dictionary = _vrweb_index["nodes"][node_id]
		var built = node_map.get(record.get("elem"))
		if built != null:
			targets[node_id] = built
	for resource_id in vrweb.get("resources", {}):
		if not targets.has(resource_id):
			targets[resource_id] = vrweb["resources"][resource_id]
	return targets


func _rebuild_world(space: Dictionary, url: String, vrweb: Dictionary, base_url: String) -> void:
	# Сносим старое пространство, игрока сохраняем. remove_child СРАЗУ (а не только queue_free):
	# queue_free удаляет из дерева лишь в конце кадра, а video_manager.scan(_world) ниже бежит
	# в этом же кадре — иначе он обошёл бы старое (умирающее) поддерево vrweb и привязал бы уже
	# привязанные экраны/мёртвые плееры (двойной connect texture_ready и freed instance в _process).
	_clear_world()

	# Лоадер картинок живёт внутри мира: при следующей навигации мир сносится вместе с ним,
	# незавершённые загрузки старой страницы умирают сами.
	var image_loader := ImageLoader.new()
	image_loader.name = "ImageLoader"
	_world.add_child(image_loader)
	_world_image_loader = image_loader

	# Капсулы других игроков живут в мире: при навигации мир сносится — старые капсулы
	# исчезают (ушёл со страницы = вышел из комнаты), view пересоздаётся для новой.
	_remote_view = REMOTE_VIEW_SCRIPT.new()
	_remote_view.name = "RemotePlayersView"
	_world.add_child(_remote_view)
	_remote_view.setup(_player)

	# Менеджер grabbable-предметов: hold-состояние через Replicated State + attachment-модель
	# (предмет в руке следует за якорем аватара держателя). Живёт в мире и сносится при
	# навигации. Создаётся ДО вьюхи эфемерных изменений: её setup сразу материализует текущее
	# состояние комнаты, и предметы из снимка (при входе в комнату) должны найти менеджера
	# уже готовым. См. docs/client/grabbable.md.
	_grab_manager = GrabManager.new()
	_grab_manager.name = "GrabManager"
	_world.add_child(_grab_manager)
	_grab_manager.setup(_player, _remote_view)

	# Вьюха эфемерных изменений: материализует журнал NetworkManager (пузыри и будущие
	# инструменты) в объекты мира. Тоже живёт в world — при навигации сносится и пересоздаётся
	# для новой комнаты. Клики кликабельных объектов идут в тот же _activate_transition, что и
	# порталы. См. docs/ephemeral-changes.md.
	var ephemeral_view := EPHEMERAL_VIEW_SCRIPT.new()
	ephemeral_view.name = "EphemeralView"
	_world.add_child(ephemeral_view)
	# Реестр «id узла страницы -> живой объект» для эфемерного оверлея (vrweb-patch/vrweb-node):
	# id — из индекса _vrweb_index, объект — из провенанса билдера (элемент -> узел). Суб-ресурсы
	# страницы адресуются своим id напрямую (патч BoxMesh.size меняет все его меши живьём).
	var vrweb_targets := {}
	var node_map: Dictionary = vrweb.get("nodes", {})
	for nid in _vrweb_index.get("nodes", {}):
		var built = node_map.get(_vrweb_index["nodes"][nid]["elem"])
		if built != null:
			vrweb_targets[nid] = built
	var page_resources: Dictionary = vrweb.get("resources", {})
	for rid in page_resources:
		if not vrweb_targets.has(rid):
			vrweb_targets[rid] = page_resources[rid]
	ephemeral_view.setup(_activate_transition,
		{"targets": vrweb_targets, "resources": page_resources, "base_url": base_url,
		"content_policy": _content_policy, "player": _player,
		"file_picker": _script_file_picker()})

	# Менеджер видео-плееров: связывает <VRWebVideoPlayer>/<VRWebVideoScreen> и синхронизирует
	# воспроизведение по сети. Тоже живёт в мире — при навигации сносится (выход из комнаты).
	_video_manager = VrwebVideoManager.new()
	_video_manager.name = "VrwebVideoManager"
	_world.add_child(_video_manager)

	# Тулбелт item-инструментов: хоткеи слотов спавнят переносимые предметы (карандаш/ластик/
	# рамка картинок) вместо вшитых в клиент инструментов. См. docs/space/portable-tools.md.
	_item_toolbelt = ItemToolbelt.new()
	_item_toolbelt.name = "ItemToolbelt"
	_world.add_child(_item_toolbelt)
	_item_toolbelt.setup(_grab_manager)
	_item_toolbelt.status_hint.connect(_set_status)

	# mode="exclusive" — HTML-сцену не строим вовсе, в мире только узлы vrweb.
	var exclusive: bool = vrweb.get("found", false) and vrweb.get("mode", "") == VrwebBuilder.MODE_EXCLUSIVE
	_base_scene_mode = VrwebBuilder.MODE_EXCLUSIVE if exclusive else VrwebBuilder.MODE_COMBINE
	_effective_scene_mode = _base_scene_mode
	_page_space = space
	_page_seed = PageFetcher.space_seed(url, TopologyBuilder.signature(space))
	var gen: WorldGenerator = null
	if exclusive:
		_label_positions = {}
	else:
		gen = _mount_html_layer()

	# Спавн: приоритет у <VRWebSpawner>, затем спавн HTML-топологии «у первого объекта»,
	# затем (exclusive без спавнера) дефолт у начала координат лицом к сцене.
	var spawn: Dictionary = vrweb.get("spawn", {})
	if spawn.has("point"):
		_player.teleport_to(spawn["point"], spawn.get("look_at"))
	elif gen != null:
		@warning_ignore("incompatible_ternary")
		_player.teleport_to(gen.spawn_point, gen.spawn_look_at if gen.has_spawn_look else null)
	else:
		_player.teleport_to(Vector3(0, 1.6, 5), Vector3(0, 1.6, 0))

	# Узлы vrweb добавляются поверх (combine) либо как единственное содержимое (exclusive).
	if vrweb.get("found", false) and vrweb.get("root") != null:
		_world.add_child(vrweb["root"])

	# Регистрируем видео-плееры и привязываем экраны (после добавления всего в дерево).
	# Сканируем весь мир: экраны бывают и из <vrwml>-тегов, и из обычного HTML-тега <video>
	# (WorldGenerator строит из него такой же VrwebVideoScreen). Геометрия HTML теперь
	# достраивается порциями по кадрам (тайм-слайс), поэтому HTML-экраны появляются не сразу —
	# сканируем после сигнала build_finished. Маленькие страницы строятся синхронно (build_complete
	# уже true) — тогда сканируем тут же. В exclusive-режиме (gen == null) геометрии HTML нет.
	# Для streaming callback уже подключён в _mount_html_layer; синхронный/exclusive сканируем сейчас.
	if gen == null or gen.build_complete:
		_video_manager.scan(_world)

	# Внешние ресурсы (<ExtResource path="<url>">) качаются и вставляются асинхронно —
	# прогрессивная подгрузка, как у картинок <img>. Общая логика с дебаг-превью редактора
	# вынесена в VrwebExtInjector; оба лоадера живут в мире и сносятся при навигации.
	VrwebExtInjector.inject(vrweb.get("ext", {}), image_loader, _world)


## Создать только процедурный HTML-слой из сохранённой топологии. Не телепортирует игрока и
## не касается VRWML/overlay/network views. Возвращённый генератор нужен начальному spawn.
func _mount_html_layer() -> WorldGenerator:
	if is_instance_valid(_html_layer) or _page_space.is_empty() or _world_image_loader == null:
		return _world_gen
	_html_layer = Node3D.new()
	_html_layer.name = "HtmlLayer"
	_world.add_child(_html_layer)
	var gen := WorldGenerator.generate(_page_space, _html_layer, _page_seed,
		_activate_transition, _base_url, _world_image_loader)
	_world_gen = gen
	_label_positions = gen.label_positions
	if not gen.build_complete:
		gen.build_finished.connect(_on_html_build_finished.bind(gen), CONNECT_ONE_SHOT)
	return gen


func _on_html_build_finished(gen: WorldGenerator) -> void:
	# Старый генератор мог завершить callback уже после второго переключения режима.
	if gen != _world_gen or not is_instance_valid(_html_layer):
		return
	if is_instance_valid(_video_manager):
		_video_manager.rescan(_world)


func _remove_html_layer() -> void:
	_world_gen = null
	_label_positions = {}
	if is_instance_valid(_html_layer):
		# Сразу исключаем слой из обходов/физики; queue_free завершит освобождение в конце кадра.
		var parent := _html_layer.get_parent()
		if parent != null:
			parent.remove_child(_html_layer)
		_html_layer.queue_free()
	_html_layer = null
	if is_instance_valid(_video_manager):
		_video_manager.rescan(_world)


## Применить effective instance mode без fetch/navigation/join_room и без смены позы.
func _apply_instance_scene_config() -> void:
	if _current_doc == null or _page_space.is_empty():
		return
	var mode := _base_scene_mode
	var attrs := NetworkManager.scene_config_attrs()
	if str(attrs.get("mode", "")).to_lower() == VrwebBuilder.MODE_EXCLUSIVE:
		mode = VrwebBuilder.MODE_EXCLUSIVE
	elif str(attrs.get("mode", "")).to_lower() == VrwebBuilder.MODE_COMBINE:
		mode = VrwebBuilder.MODE_COMBINE
	if mode == _effective_scene_mode:
		return
	_effective_scene_mode = mode
	if mode == VrwebBuilder.MODE_EXCLUSIVE:
		_remove_html_layer()
	else:
		var gen := _mount_html_layer()
		if gen != null and gen.build_complete and is_instance_valid(_video_manager):
			_video_manager.rescan(_world)


## Единый обработчик переходов от порталов и inline-ссылок RichPanel.
func _activate_transition(transition: Dictionary) -> void:
	match transition.get("kind", ""):
		"navigate":
			# Относительные ссылки резолвятся относительно базы страницы (учитывает <base href>).
			_navigate(transition.get("href", ""), _base_url, true)
		"external":
			# Ссылка с нестандартной схемой (mailto:, tel:, magnet:, app-схема) — это не
			# страница для VRWeb, а намерение для ОС. Отдаём системному обработчику; он сам
			# решит, что запускать (почтовик, телефон, торрент-клиент, стороннее приложение).
			var uri: String = transition.get("uri", "")
			var err := OS.shell_open(uri)
			if err == OK:
				_set_status("Открыто во внешнем приложении: %s" % uri)
			else:
				_set_status("Не удалось открыть %s (ошибка %d)" % [uri, err])
		"teleport":
			var target: String = transition.get("target", "")
			if _label_positions.has(target):
				_player.teleport_to(_label_positions[target] + Vector3(0, 0.5, 2))
				_set_status("Переход к #%s" % target)
			else:
				_set_status("Якорь #%s не найден" % target)
		"back":
			_go_back()


## Кнопка «назад» в navbar: идём по истории и уводим мышь обратно в игру (клик по UI её
## отпустил). capture_mouse сам снимет фокус с кнопки.
func _on_back_pressed() -> void:
	_go_back()
	_player.capture_mouse(true)


func _on_fwd_pressed() -> void:
	_go_forward()
	_player.capture_mouse(true)


func _go_back() -> void:
	if _history_index <= 0:
		_set_status("Назад некуда")
		return
	_capture_current_pose()
	_history_index -= 1
	_load_history_entry()


func _go_forward() -> void:
	if _history_index >= _history.size() - 1:
		_set_status("Вперёд некуда")
		return
	_capture_current_pose()
	_history_index += 1
	_load_history_entry()


## Загружает запись истории под текущим _history_index, попросив восстановить сохранённую
## позу игрока. push_history=false — индекс уже выставлен вызывающим.
func _load_history_entry() -> void:
	var entry: Dictionary = _history[_history_index]
	_pending_restore_pose = entry.get("pose")
	_navigate(entry["url"], "", false)


## Сохраняет текущую позу игрока в активной записи истории — чтобы вернуться сюда позже.
func _capture_current_pose() -> void:
	if _history_index >= 0 and _history_index < _history.size():
		_history[_history_index]["pose"] = _player.get_pose()


## Доступность кнопок назад/вперёд по положению в истории.
func _update_nav_buttons() -> void:
	if _back_btn != null:
		_back_btn.disabled = _history_index <= 0
	if _fwd_btn != null:
		_fwd_btn.disabled = _history_index >= _history.size() - 1


# --- Мультиплеер ---

func _setup_net() -> void:
	# Закрытие настроек оставляет мышь свободной (UI-режим) — обратно в перемещение
	# возвращает клик по 3D, а не само закрытие. Поэтому closed здесь ни к чему не цепляем.
	# «Вернуться домой» с вкладки «Мир» — грузим домашний инстанс.
	_settings_overlay.home_requested.connect(_on_home_requested)
	# «Моё пространство» с вкладки «Аккаунт» — персональное пространство домашнего сервера,
	# отдельно от домашней страницы (разные сущности, см. docs/personal-spaces.md).
	_settings_overlay.space_requested.connect(_on_space_requested)
	# Клик по странице в «Кто где сейчас» (presence.v1, docs/presence.md) — обычная навигация.
	_settings_overlay.presence_url_requested.connect(_on_presence_url_requested)
	_settings_overlay.closed.connect(_on_settings_closed)

	_settings_btn.pressed.connect(_open_settings)

	_build_chat_ui()

	Settings.changed.connect(_on_settings_changed)
	# Discovery домашнего сервера завершился (в т.ч. после смены адреса в настройках) —
	# эффективный сигналинг мог смениться (анонс сервера). _sync_online → connect_to_server
	# сравнит адреса и при необходимости честно переподключится. Именно refresh_finished,
	# а не state_changed: тот эмитится и В НАЧАЛЕ refresh (анонс временно сброшен в "") —
	# реагируя на него, мы бы дёргались на конфигный адрес и обратно.
	HomeServer.refresh_finished.connect(_sync_online)
	NetworkManager.connection_changed.connect(_on_connection_changed)
	NetworkManager.chat_received.connect(_on_chat_received)
	# Сигналинг отказал во входе (закрытое персональное пространство): мир построен, но комнаты
	# нет — мы в нём одни. Подсказываем причину. См. docs/personal-spaces.md.
	NetworkManager.room_denied.connect(func(_room: String, _reason: String):
		_set_status("Пространство закрыто — хозяина нет дома (комната недоступна)"))
	# Взаимодействие с голосом (смена режима / нажатие V) — мигаем индикатором даже без сигнала.
	VoiceManager.indicator_nudge.connect(_on_voice_nudge)

	# Применяем сохранённый режим (online_enabled мог остаться с прошлой сессии).
	_sync_online()


func _open_settings() -> void:
	if _settings_focus_token == 0:
		_settings_focus_token = _player.claim_mouse_focus("settings")
	_settings_overlay.open(_current_url, _page_meta)


func _on_settings_closed() -> void:
	_release_focus_token(&"_settings_focus_token")


## «Вернуться домой» из настроек: грузим ДОМАШНЮЮ СТРАНИЦУ (произвольная закладка старта —
## как ввод адреса в омнибоксе, абсолютный URL без базы). Если она не задана — фолбэком идём
## в персональное пространство (пустой старт логично открывать в своём доме).
func _on_home_requested() -> void:
	var home := Settings.home_page.strip_edges()
	if home == "":
		await _go_to_personal_space()
		return
	_address.text = home
	_navigate(home, "", true)
	_player.capture_mouse(true)


## «Моё пространство» из настроек (вкладка «Аккаунт»): идём в ПЕРСОНАЛЬНОЕ ПРОСТРАНСТВО
## домашнего сервера ВНЕ зависимости от домашней страницы — это разные сущности
## (см. docs/personal-spaces.md).
func _on_space_requested() -> void:
	await _go_to_personal_space()


## Страница из presence-списка настроек (presence.v1): переход как по введённому адресу
## (URL из выдачи — канонический ключ без схемы, резолвер подставит https).
func _on_presence_url_requested(url: String) -> void:
	_address.text = url
	_navigate(url, "", true)
	_player.capture_mouse(true)


## Переход в персональное пространство домашнего сервера (personal-spaces.v1). Его адрес НЕ
## хранится — спрашивается у сервера каждый раз, поэтому ротация адреса владельцу незаметна.
func _go_to_personal_space() -> void:
	var res: Dictionary = await HomeServer.fetch_home_space()
	if not res.get("ok", false):
		_set_status("Персональное пространство недоступно: %s" % res.get("error", ""))
		return
	var url := str(res.get("url", ""))
	_address.text = url
	_navigate(url, "", true)
	_player.capture_mouse(true)


func _on_settings_changed() -> void:
	_sync_online()
	# Ник/лицо могли поменяться — разошлём обновлённую карточку уже подключённым пирам.
	NetworkManager.broadcast_identity()


## Приводит сетевое состояние в соответствие настройкам: онлайн — подключаемся и входим
## в комнату текущей страницы; офлайн — рвём соединение.
func _sync_online() -> void:
	if Settings.online_enabled:
		if not NetworkManager.webrtc_available():
			_set_status("WebRTC недоступен: добавьте аддон webrtc-native в addons/webrtc")
		else:
			_join_current_room()
	else:
		NetworkManager.disconnect_from_server()
	_update_chat_visibility()


## Подключиться (если ещё нет) и войти в комнату текущего URL. connect_to_server идемпотентен
## (живое соединение с актуальным адресом не трогает), а при сменившемся эффективном адресе
## сигналинга — переподключается; join_room сам поставит вход в очередь, если соединение ещё
## устанавливается.
func _join_current_room() -> void:
	if not (Settings.online_enabled and NetworkManager.webrtc_available()):
		return
	NetworkManager.connect_to_server()
	if _current_url != "":
		NetworkManager.join_room(PageFetcher.seed_key(_current_url))


func _on_connection_changed(online: bool) -> void:
	_set_status("Онлайн: %s" % Settings.effective_signaling_url() if online else "Офлайн")


# --- Чат ---

func _build_chat_ui() -> void:
	# Текст можно выделять мышью и копировать (Ctrl/Cmd+C). Для этого лог должен принимать
	# события мыши (не IGNORE) — заодно это включает клики по ссылкам ниже.
	# Ссылки в сообщениях ([url]…[/url], см. _linkify) подчёркиваем и делаем кликабельными;
	# meta_clicked отдаёт href в _on_chat_meta_clicked для перехода/внешнего открытия.
	_chat_log.meta_underlined = true
	_chat_log.meta_clicked.connect(_on_chat_meta_clicked)
	_chat_input.max_length = NetworkManager.MAX_CHAT_CHARS   # не ввести больше лимита
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_input.focus_entered.connect(func():
		if _chat_focus_token == 0:
			_chat_focus_token = _player.claim_mouse_focus("chat_input"))
	_chat_input.focus_exited.connect(func(): _release_focus_token(&"_chat_focus_token"))

	# Таймер бездействия: в режиме перемещения через 30с после последнего сообщения лог
	# плавно угасает до 10% непрозрачности, чтобы не мешать обзору (см. _on_chat_idle_timeout).
	_chat_idle_timer.timeout.connect(_on_chat_idle_timeout)


func _on_chat_submitted(text: String) -> void:
	text = text.strip_edges().left(NetworkManager.MAX_CHAT_CHARS)
	_chat_input.clear()
	if text != "":
		NetworkManager.send_chat(text)
		_append_chat(Settings.nick, text)   # локальное эхо
	# Enter всегда возвращает в браузинг — даже на пустом сообщении (round-trip с chat_requested).
	_release_focus_token(&"_chat_focus_token")
	_player.capture_mouse(true)


func _on_chat_received(id: int, text: String) -> void:
	_append_chat(NetworkManager.nick_of(id), text)


func _append_chat(nick: String, text: String) -> void:
	_push_chat({"kind": "user", "nick": nick, "text": text})


## Системная строка чата (серым курсивом) — отбивки переходов между мирами и пр.
func _push_system_chat(text: String) -> void:
	_push_chat({"kind": "system", "text": text})


## Кладёт запись в кольцевой буфер (последние CHAT_HISTORY_MAX, без записи на диск),
## перерисовывает лог и будит чат (видимость + сброс таймера угасания).
func _push_chat(entry: Dictionary) -> void:
	_chat_history.append(entry)
	if _chat_history.size() > CHAT_HISTORY_MAX:
		_chat_history = _chat_history.slice(_chat_history.size() - CHAT_HISTORY_MAX)
	_render_chat()
	_chat_wake()


## Перерисовывает лог из буфера (≤50 строк — дёшево). clear()+append_text заодно обрезает
## старое при переполнении буфера; scroll_following держит прокрутку у низа.
func _render_chat() -> void:
	if _chat_log == null:
		return
	_chat_log.clear()
	for e: Dictionary in _chat_history:
		if e.get("kind", "") == "system":
			_chat_log.append_text("[i][color=#9aa0a6]— %s —[/color][/i]\n" % _esc_bb(e.get("text", "")))
		else:
			_chat_log.append_text("[b]%s[/b]: %s\n" % [_esc_bb(e.get("nick", "")), _linkify(e.get("text", ""))])


## Экранирует "[" в пользовательском тексте, чтобы он не воспринимался как BBCode-тег.
func _esc_bb(s: String) -> String:
	return s.replace("[", "[lb]")


# URL в тексте сообщения: схема (http(s), mailto:, tel:, кастомные app-схемы, deeplink
# scheme://…) либо www.-домен, до первого пробела. Хвостовая пунктуация (.,!? и скобки)
# отрезается отдельно в _linkify, чтобы не утащить её в адрес.
static var _url_re: RegEx = RegEx.create_from_string("(?i)\\b(?:[a-z][a-z0-9+.\\-]*:(?://)?|www\\.)[^\\s]+")


## Оборачивает ссылки в тексте в кликабельный [url=…], остальное экранирует _esc_bb.
## meta каждого [url] — исходный адрес; по нему _on_chat_meta_clicked решает, что делать.
func _linkify(text: String) -> String:
	var out := ""
	var last := 0
	for m: RegExMatch in _url_re.search_all(text):
		out += _esc_bb(text.substr(last, m.get_start() - last))
		var url := m.get_string()
		# Отрезаем хвостовую пунктуацию: "(см. example.com)." не должен включать ")." в адрес.
		var trail := ""
		while url.length() > 0 and url[url.length() - 1] in ".,;:!?)»\"'":
			trail = url[url.length() - 1] + trail
			url = url.substr(0, url.length() - 1)
		if _looks_like_link(url):
			out += "[url=%s][color=#6cb6ff]%s[/color][/url]" % [url, _esc_bb(url)]
			out += _esc_bb(trail)
		else:
			# Ложное срабатывание (напр. "слово:слово") — оставляем как обычный текст.
			out += _esc_bb(m.get_string())
		last = m.get_end()
	out += _esc_bb(text.substr(last))
	return out


## Отсеивает ложные «ссылки» (двоеточие в обычной фразе): настоящий адрес — это www.,
## схема с "//" (deeplink/веб), известная безслэшевая схема (mailto/tel/…) или схема,
## за которой идёт путь/домен с "/" или ".".
func _looks_like_link(s: String) -> bool:
	if s.to_lower().begins_with("www."):
		return true
	var colon := s.find(":")
	if colon <= 0:
		return false
	var rest := s.substr(colon + 1)
	if rest.begins_with("//"):
		return true
	if s.substr(0, colon).to_lower() in ["mailto", "tel", "sms", "magnet", "geo", "maps"]:
		return true
	return rest.contains("/") or rest.contains(".")


## Клик по ссылке в чате: www.→https://, далее общая классификация (навигация VRWeb,
## телепорт к якорю или внешнее намерение для ОС) — та же, что у ссылок страницы.
func _on_chat_meta_clicked(meta: Variant) -> void:
	var url := str(meta).strip_edges()
	if url.to_lower().begins_with("www."):
		url = "https://" + url
	var transition: Variant = TopologyBuilder.classify_href(url)
	if transition == null:
		return
	if transition.get("kind", "") == "navigate":
		# Ссылка из чата — абсолютный адрес (как омнибокс): база пустая, мышь обратно в игру.
		_navigate(transition["href"], "", true)
		_player.capture_mouse(true)
	else:
		_activate_transition(transition)


## Будит чат: полная непрозрачность и (только в режиме перемещения) перезапуск 30-сек таймера,
## по истечении которого лог плавно угаснет до 10% (_on_chat_idle_timeout). В UI-режиме таймер
## не заводится — чат остаётся читаемым, пока мышь свободна.
func _chat_wake() -> void:
	if _chat_fade_tween != null:
		_chat_fade_tween.kill()
		_chat_fade_tween = null
	if _chat_root != null:
		_chat_root.modulate.a = 1.0
	if _chat_idle_timer == null:
		return
	_chat_idle_timer.stop()
	if _mouse_captured and Settings.online_enabled:
		_chat_idle_timer.start()


## 30с без сообщений в режиме перемещения — плавно гасим лог до 10%, чтобы не мешал обзору.
func _on_chat_idle_timeout() -> void:
	if _chat_root == null or not (_mouse_captured and Settings.online_enabled):
		return
	_chat_fade_tween = create_tween()
	_chat_fade_tween.tween_property(_chat_root, "modulate:a", 0.1, 0.6)


func _update_chat_visibility() -> void:
	if _chat_root != null:
		_chat_root.visible = Settings.online_enabled
	# Онлайн-состояние влияет на угасание (оффлайн чат скрыт целиком).
	_chat_wake()


# --- Окружение и UI ---

## Нейтральные небо и свет только для стартового экрана (до загрузки страницы).
## После первой навигации их заменяет процедурная атмосфера из WorldGenerator,
## сгенерированная по данным страницы (см. _rebuild_world).
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	_world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(40), 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	_world.add_child(sun)


func _setup_ui_extras() -> void:
	# Прицел по центру экрана. В сцене лежат две готовые картинки: пассивная и активная.
	_passive_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_active_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_on_aim_target_changed(false, "")

	# «Светофор» связи — маленький кружок слева от строки статуса. MOUSE_FILTER_PASS, чтобы
	# показывался тултип с развёрнутым статусом, но клики уходили сквозь него.
	_conn_dot_style = _conn_dot.get_theme_stylebox("panel").duplicate()
	_conn_dot.add_theme_stylebox_override("panel", _conn_dot_style)

	NetworkManager.net_status_changed.connect(_update_conn_indicator)
	_update_conn_indicator()

	# Консоль пространства (`~`, см. docs/space-console.md): read-only часть — хранимое дерево
	# страницы БЕЗ блока <vrwml>; редактируемая — единый слитый слой сцены, который консоль
	# собирает сама из индекса vrweb и эфемерного состояния NetworkManager.
	_console.setup(_page_html_sans_vrweb, func() -> Dictionary: return _vrweb_index,
		func() -> String: return _current_url)
	NetworkManager.scene_config_changed.connect(func(_config): _apply_instance_scene_config())
	# Snapshot/выход из комнаты заменяет config целиком без granular event.
	NetworkManager.scene_reset.connect(_apply_instance_scene_config)


## Оверлей инспектора провенанса (F3): панель в правом верхнем углу с типом топологии и
## исходным HTML узла под прицелом. Текст приходит от Player.debug_probed.
func _on_debug_toggled(on: bool) -> void:
	if _debug_panel != null:
		_debug_panel.visible = on
	if on:
		_set_status("Отладка ON — наведи прицел на объект (F3 — выкл)")
		if _debug_label != null:
			_debug_label.text = "Наведи прицел на объект…"
	else:
		_set_status("Отладка OFF")


func _on_debug_probed(text: String) -> void:
	if _debug_label != null:
		_debug_label.text = text if text != "" else "Наведи прицел на объект…"


# --- Файловый пикер скриптов (document.files.pick, capability vrweb/files/1) ---
# Пикер — UI, поэтому живёт здесь. Сам выбор файла пользователем — явное согласие (модель
# <input type="file">); скрипт получает только байты выбранного файла, путь ОС не уезжает.

func _script_file_picker() -> Callable:
	return func(kind: String, done: Callable) -> void:
		if _script_pick_open:
			done.call(false, "", PackedByteArray())
			return
		_script_pick_open = true
		var focus_token := _player.claim_mouse_focus("script_file_dialog")
		var finish := func(path: String) -> void:
			_script_pick_open = false
			_player.release_mouse_focus(focus_token)
			_player.capture_mouse(true)
			var bytes := FileAccess.get_file_as_bytes(path) if path != "" else PackedByteArray()
			done.call(path != "" and not bytes.is_empty(), path.get_file(), bytes)
		if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
			DisplayServer.file_dialog_show("Выбрать файл", "", "", false,
				DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, _script_pick_filters(kind),
				func(ok: bool, paths: PackedStringArray, _filter: int) -> void:
					finish.call(paths[0] if ok and not paths.is_empty() else ""))
			return
		# Fallback без нативного диалога ОС — FileDialog в MainUI (результат — _on_ui_file_chosen).
		_ui_pick_finish = finish
		_ui.open_image_dialog(_script_pick_filters(kind))


## Результат fallback-диалога MainUI: завершить ожидающий files.pick.
func _on_ui_file_chosen(ok: bool, path: String) -> void:
	var finish := _ui_pick_finish
	_ui_pick_finish = Callable()
	if finish.is_valid():
		finish.call(path if ok else "")


func _script_pick_filters(kind: String) -> PackedStringArray:
	match kind:
		"image":
			return PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp,*.gif,*.bmp;Изображения"])
		"audio":
			return PackedStringArray(["*.mp3,*.ogg,*.wav;Аудио"])
		"model":
			return PackedStringArray(["*.glb,*.gltf;3D-модели"])
	return PackedStringArray(["*;Все файлы"])


## Подсветка прицела: над кликабельным/портальным объектом включается активная нода курсора,
## иначе — пассивная. hint — «куда ведёт» объект под
## прицелом: пишем его в строку статуса (превью ссылки, как в углу браузера), а как только
## прицел уходит «в никуда» — очищаем поле.
func _on_aim_target_changed(active: bool, hint: String) -> void:
	if _status != null:
		_status.text = hint
	if _passive_cursor != null:
		_passive_cursor.visible = not active
	if _active_cursor != null:
		_active_cursor.visible = active


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
	if _loading_hub != null and _loading_hub.visible:
		_loading_hub.set_status(text)
	Log.info("main", text)


## Перекрашивает «светофор» связи и обновляет его тултип. Зовётся при старте и по
## NetworkManager.net_status_changed (сигнал передаёт готовый словарь статуса).
func _update_conn_indicator(status: Dictionary = {}) -> void:
	if _conn_dot == null:
		return
	if status.is_empty():
		status = NetworkManager.connection_status()
	_conn_dot_style.bg_color = status.get("color", Color.GRAY)
	var detail := str(status.get("detail", ""))
	_conn_dot.tooltip_text = str(status.get("label", "")) \
		+ ("\n" + detail if detail != "" else "")


## Сериализация хранимого документа страницы БЕЗ блока <vrwml> — read-only часть консоли
## (сам vrweb показывается там слитым с эфемерным оверлеем). Блок на время сериализации
## временно вынимается из дерева и возвращается на место (синхронно, дерево общее).
func _page_html_sans_vrweb() -> String:
	if _current_doc == null:
		return ""
	var block := _current_doc.find_descendant(VrwebBuilder.TAG)
	if block == null:
		return _current_doc.to_html()
	var parent := _find_parent(_current_doc, block)
	if parent == null:
		return _current_doc.to_html()
	var idx := parent.children.find(block)
	parent.children.remove_at(idx)
	var html := _current_doc.to_html()
	parent.children.insert(idx, block)
	return html


## Родитель узла в дереве HtmlNode (или null).
func _find_parent(node: HtmlNode, target: HtmlNode) -> HtmlNode:
	for c in node.children:
		if c == target:
			return node
		var found := _find_parent(c, target)
		if found != null:
			return found
	return null
