extends Node3D

## Headless проверка МАТЕРИАЛИЗАЦИИ: EphemeralView строит реальный узел Bubble из сигналов
## NetworkManager. Один инстанс (один в комнате = авторитет) на реальном mesh: коммитит действия
## локально → сигналы → EphemeralView создаёт/обновляет/удаляет узлы. Проверяет сцен-граф (без
## рендера). Запуск: VRWEB_SANDBOX=V godot --headless tests/view_scene_test.tscn -- V

var _view: EphemeralView
var _activated := []   # переходы, пришедшие от клика по пузырю


func _ready() -> void:
	Settings.signaling_url = "ws://localhost:8090"
	Settings.online_enabled = true
	_view = EphemeralView.new()
	add_child(_view)
	_view.setup(func(t): _activated.append(t))

	NetworkManager.connect_to_server()
	NetworkManager.join_room("viewroom")
	var waited := 0.0
	while not NetworkManager.has_authority() and waited < 8.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1

	var results := {}
	# 1) add → появился узел Bubble с верным url.
	NetworkManager.request_scene_action({
		"op": "add", "id": "V1", "kind": "bubble", "parent": "", "ttl": 0.0,
		"props": {"url": "https://example.com/here", "position": [2, 1, 3], "label": "Leaver"}})
	await get_tree().create_timer(0.3).timeout
	var node := _bubble_node()
	results["spawned"] = node != null
	results["url_ok"] = node != null and node.url == "https://example.com/here"
	results["pos_ok"] = node != null and node.position.is_equal_approx(Vector3(2, 1, 3))
	results["clickable"] = node != null and node.has_method("interact_at") and node.is_active_at(Vector3.ZERO)

	# 2) клик по пузырю → переход navigate на нужный url.
	if node != null:
		node.interact_at(Vector3.ZERO)
	await get_tree().create_timer(0.1).timeout
	results["click_navigates"] = _activated.size() == 1 \
		and _activated[0].get("kind", "") == "navigate" \
		and _activated[0].get("href", "") == "https://example.com/here"

	# 3) update → метка на узле обновилась.
	NetworkManager.request_scene_action({"op": "update", "id": "V1", "props": {"label": "Updated"}})
	await get_tree().create_timer(0.2).timeout
	var n2 := _bubble_node()
	results["update_applied"] = n2 != null and n2.label_text == "Updated"

	# 4) remove → узел исчез из сцен-графа.
	NetworkManager.request_scene_action({"op": "remove", "id": "V1"})
	await get_tree().create_timer(0.3).timeout
	results["despawned"] = _bubble_node() == null

	# 5) TTL → узел сам уходит после истечения (авторитет истекает + рассылает remove).
	NetworkManager.request_scene_action({
		"op": "add", "id": "V2", "kind": "bubble", "parent": "", "ttl": 1.5, "props": {"url": "x"}})
	await get_tree().create_timer(0.3).timeout
	results["ttl_spawned"] = _bubble_node() != null
	await get_tree().create_timer(2.0).timeout
	results["ttl_despawned"] = _bubble_node() == null

	var ok := true
	for k in results:
		if not results[k]:
			ok = false
	var parts := []
	for k in results:
		parts.append("%s=%s" % [k, results[k]])
	print("[V] RESULT pass=%s | %s" % [ok, " ".join(parts)])
	get_tree().quit(0 if ok else 1)


## Находит первый узел Bubble среди детей вьюхи (живой).
func _bubble_node() -> Bubble:
	for c in _view.get_children():
		if c is Bubble and is_instance_valid(c):
			return c
	return null
