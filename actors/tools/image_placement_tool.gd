class_name ImagePlacementTool
extends PlayerTool

## Инструмент размещения картинок: тумблер (запрос активации включает прицеливание, повторный —
## отмена). Прицеливание ведёт полупрозрачное превью по лучу из камеры; ЛКМ фиксирует трансформ и
## запрашивает файл у main (пикер — UI, остаётся там; спавн — здесь). Артефакт — ОБЫЧНЫЙ vrweb-node
## с тегом <VRWebImage> (материализация, консоль пространства и персистенция работают готовыми
## путями), файл импортируется в realtime-ресурс (BlobStore, компактный блоб + ссылка по хэшу).
## См. docs/network/realtime-resources.md и docs/client/tools.md.

## Нужен файл картинки: ToolManager ретранслирует в main (image_pick_requested), main открывает
## диалог и возвращает результат через provide_file.
signal pick_requested(filters: PackedStringArray)

enum State { IDLE, AIMING, AWAITING_FILE }

const PLACE_REACH := 1.8         # макс. дальность луча размещения, м
const PLACE_MASK := 1            # слой геометрии мира (стены/полы) — на что «прилипает» картинка
const PLACE_SURFACE_GAP := 0.02  # отступ от поверхности вдоль нормали (антизазор/z-fighting), м
const PLACE_PREVIEW_SIZE := 0.3  # сторона превью-квадрата места размещения, м
const FILE_FILTERS: PackedStringArray = ["*.png,*.jpg,*.jpeg,*.webp,*.gif;Изображения"]

var _state: int = State.IDLE
var _preview: MeshInstance3D              # полупрозрачный квадрат «здесь будет картинка»
var _last_xform := Transform3D.IDENTITY   # трансформ превью с прошлого физ-кадра (луч — только там)
var _confirmed_xform := Transform3D.IDENTITY  # зафиксированный ЛКМ трансформ будущей картинки
## База для относительных URL офлайн-билда (у main: _base_url) — инжектится main'ом после
## создания игрока; инструмент сам знания о навигации не держит.
var base_url_provider: Callable = Callable()


func setup(camera: Camera3D, world_root: Node3D, player: Player) -> void:
	super(camera, world_root, player)
	_setup_preview()


func tool_id() -> StringName:
	return &"image"


## Тумблер: из покоя — включить прицеливание (только в браузинге мира), иначе — отмена.
func activation_request() -> bool:
	match _state:
		State.IDLE:
			if not _player.is_mouse_captured():
				return false
			_begin_aiming()
			return true
		_:
			_cancel()
			return false


func _on_unequip() -> void:
	_state = State.IDLE
	if _preview != null:
		_preview.visible = false


## ЛКМ в прицеливании: фиксируем трансформ и просим файл (main откроет диалог и вернёт
## результат через provide_file).
func primary_pressed() -> void:
	if _state != State.AIMING:
		return
	_confirmed_xform = _last_xform
	_state = State.AWAITING_FILE
	_preview.visible = false
	hint_changed.emit("")
	pick_requested.emit(FILE_FILTERS)


## ПКМ в прицеливании — отмена (то же, что повторное нажатие хоткея).
func secondary_pressed() -> bool:
	if _state != State.AIMING:
		return false
	_cancel()
	finished.emit()
	return true


## Мышь отпущена не подтверждением (Esc, потеря фокуса) — выходим из прицеливания. В ожидании
## файла НЕ отменяем: мышь отпустил сам файловый диалог.
func on_mouse_capture_changed(captured: bool) -> void:
	if not captured and _state == State.AIMING:
		_cancel()
		finished.emit()


## main зовёт после файлового диалога (через ToolManager.get_tool(&"image")): ok=false — отмена.
## Импорт синхронный: декод+пережим крупной картинки — доли секунды, для инструмента приемлемо.
func provide_file(ok: bool, path: String) -> void:
	if _state != State.AWAITING_FILE:
		return
	_state = State.IDLE
	if ok and path != "":
		_spawn_image(path)
	finished.emit()


func descriptor() -> Dictionary:
	return {"kind": "tool-image-placer", "props": {}}


# --- Прицеливание ---

func _begin_aiming() -> void:
	_state = State.AIMING
	# Стартовый трансформ без луча (луч зовём только в физ-кадре) — на конце луча лицом к игроку.
	var fwd := -_cam.global_transform.basis.z
	_last_xform = Transform3D(_face_basis(-fwd, fwd), _cam.global_position + fwd * PLACE_REACH)
	hint_changed.emit("Наведите точку · ЛКМ — выбрать картинку · ПКМ или 3 — отмена")


func _cancel() -> void:
	_state = State.IDLE
	if _preview != null:
		_preview.visible = false
	hint_changed.emit("")


## Физ-кадр (только при активном инструменте): пересчитать трансформ по лучу и подвинуть превью.
func _physics_process(_delta: float) -> void:
	if _state != State.AIMING:
		return
	# Луч размещения — только в физ-кадре (direct_space_state безопасен только там).
	_last_xform = _compute_placement()
	_preview.global_transform = _last_xform
	_preview.visible = true


## Трансформ будущей картинки по лучу из камеры (макс PLACE_REACH). Попали в поверхность —
## прижимаем к ней и разворачиваем по её нормали; мимо — вешаем на конце луча лицом к игроку.
func _compute_placement() -> Transform3D:
	var origin := _cam.global_position
	var fwd := -_cam.global_transform.basis.z
	var to := origin + fwd * PLACE_REACH
	var query := PhysicsRayQueryParameters3D.create(origin, to, PLACE_MASK, [_player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return Transform3D(_face_basis(-fwd, fwd), to)
	var normal: Vector3 = (hit["normal"] as Vector3).normalized()
	return Transform3D(_face_basis(normal, fwd), (hit["position"] as Vector3) + normal * PLACE_SURFACE_GAP)


## Ортонормальный правый базис, у которого +Z (лицевая грань квада) смотрит вдоль front.
## Верх — мировой; для почти вертикального front (пол/потолок) в роли «верха» берём взгляд,
## иначе базис вырождается. up_hint — направление взгляда для этого случая.
static func _face_basis(front: Vector3, up_hint: Vector3) -> Basis:
	var z := front.normalized()
	var up := Vector3.UP
	if absf(z.dot(up)) > 0.99:
		up = Vector3(up_hint.x, 0.0, up_hint.z)
		up = up.normalized() if up.length() > 0.001 else Vector3.FORWARD
	var x := up.cross(z).normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


## Полупрозрачный квадрат «здесь будет картинка». top_level: живёт в мировых координатах
## (позицию задаём global_transform каждый физ-кадр), двусторонний и unlit, чтобы читался
## под любым углом. По умолчанию скрыт — показывается только в режиме прицеливания.
func _setup_preview() -> void:
	_preview = MeshInstance3D.new()
	_preview.name = "ImagePlacePreview"
	_preview.top_level = true
	var quad := QuadMesh.new()
	quad.size = Vector2(PLACE_PREVIEW_SIZE, PLACE_PREVIEW_SIZE)
	_preview.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.4, 0.85, 1.0, 0.35)
	_preview.material_override = mat
	_preview.visible = false
	add_child(_preview)


# --- Спавн артефакта ---

func _spawn_image(path: String) -> void:
	var url: String = BlobStore.import_image(FileAccess.get_file_as_bytes(path))
	if url == "":
		hint_changed.emit("Не удалось разместить: формат не распознан или файл не ужимается в лимит")
		return
	# Полный трансформ прицеливания (позиция + разворот по нормали/лицом к игроку) — одним
	# атрибутом transform; var_to_str даёт литерал Transform3D(...), парсимый обратно билдером.
	var attrs := {
		"src": url,
		"alt": path.get_file(),
		"transform": var_to_str(_confirmed_xform),
	}
	if NetworkManager.in_room():
		NetworkManager.request_scene_action({
			"op": "add", "id": NetworkManager.new_object_id(), "kind": SceneHtml.KIND_NODE,
			"parent": "", "ttl": 0.0,
			"props": {"tag": VrwebBuilder.IMAGE_TAG, "attrs": attrs},
		})
	else:
		# Офлайн (вне комнаты) — локальный узел напрямую в мир, как офлайн-штрихи карандаша.
		var base_url: String = base_url_provider.call() if base_url_provider.is_valid() else ""
		var node := VrwebBuilder.build_element(VrwebBuilder.IMAGE_TAG, attrs, {}, base_url)
		if node != null:
			_world.add_child(node)
	hint_changed.emit("Изображение размещено: %s" % path.get_file())
