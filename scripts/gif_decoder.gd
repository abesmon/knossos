class_name GifDecoder
extends RefCounted

## Декодер GIF87a/GIF89a на чистом GDScript (без нативных зависимостей и аддонов).
## В Godot нет встроенного декодера GIF, а наши картинки приходят из сети/ФС в рантайме
## (их нельзя предподготовить импортом), поэтому декодируем сами. См. docs/gif-support.md.
##
## decode(bytes) -> Array[Dictionary], по кадру на элемент:
##   { "image": Image(RGBA8, размер логического экрана), "delay": float (секунды) }
## Кадры уже скомпонованы на общий холст с учётом прозрачности и disposal-метода,
## так что каждый Image — самодостаточный полный кадр (можно отдать как есть в текстуру).
## Возвращает [] если это не валидный GIF.

const MAX_DICT := 4096   # LZW: словарь не растёт выше 12-битных кодов


## Главная точка входа: байты GIF -> массив кадров (см. шапку файла).
static func decode(data: PackedByteArray) -> Array:
	var n := data.size()
	if n < 13:
		return []
	# Сигнатура "GIF" + версия "87a"/"89a".
	if data[0] != 0x47 or data[1] != 0x49 or data[2] != 0x46:
		return []

	var canvas_w := data[6] | (data[7] << 8)
	var canvas_h := data[8] | (data[9] << 8)
	if canvas_w <= 0 or canvas_h <= 0:
		return []

	var packed := data[10]
	var has_gct := (packed & 0x80) != 0
	var gct_size := 1 << ((packed & 0x07) + 1)

	var pos := 13
	var global_palette: PackedByteArray
	if has_gct:
		global_palette = data.slice(pos, pos + gct_size * 3)
		pos += gct_size * 3

	var frames: Array = []
	# Холст RGBA8 (canvas_w*canvas_h*4), стартует прозрачным. На него композим кадры.
	var canvas := PackedByteArray()
	canvas.resize(canvas_w * canvas_h * 4)
	canvas.fill(0)
	var saved_for_dispose3: PackedByteArray   # снимок до кадра с disposal==3

	# Состояние от последнего Graphic Control Extension (действует на ближайший кадр).
	var gce_delay := 0
	var gce_transparent := -1
	var gce_disposal := 0
	# disposal предыдущего кадра и его прямоугольник — применяем ПЕРЕД отрисовкой текущего.
	var prev_disposal := 0
	var prev_rect := Rect2i()

	while pos < n:
		var block := data[pos]
		pos += 1

		if block == 0x3B:   # трейлер — конец файла
			break

		elif block == 0x21:   # Extension Introducer
			if pos >= n:
				break
			var label := data[pos]
			pos += 1
			if label == 0xF9:   # Graphic Control Extension
				# block_size(1)=4, packed(1), delay u16, transparent_idx(1), terminator(0)
				if pos + 5 >= n:
					break
				var gpacked := data[pos + 1]
				gce_delay = data[pos + 2] | (data[pos + 3] << 8)
				if (gpacked & 0x01) != 0:
					gce_transparent = data[pos + 4]
				else:
					gce_transparent = -1
				gce_disposal = (gpacked >> 2) & 0x07
				pos += 1 + 4   # block_size + 4 байта полей
				pos = _skip_sub_blocks(data, pos)   # терминатор
			else:
				# Application/Comment/PlainText — пропускаем все суб-блоки.
				pos = _skip_sub_blocks(data, pos)

		elif block == 0x2C:   # Image Descriptor — собственно кадр
			if pos + 9 > n:
				break
			var fx := data[pos] | (data[pos + 1] << 8)
			var fy := data[pos + 2] | (data[pos + 3] << 8)
			var fw := data[pos + 4] | (data[pos + 5] << 8)
			var fh := data[pos + 6] | (data[pos + 7] << 8)
			var ipacked := data[pos + 8]
			pos += 9

			var has_lct := (ipacked & 0x80) != 0
			var interlaced := (ipacked & 0x40) != 0
			var palette := global_palette
			if has_lct:
				var lct_size := 1 << ((ipacked & 0x07) + 1)
				palette = data.slice(pos, pos + lct_size * 3)
				pos += lct_size * 3

			if pos >= n:
				break
			var min_code_size := data[pos]
			pos += 1
			# Собираем сжатые данные кадра из суб-блоков.
			var lzw := PackedByteArray()
			while pos < n:
				var bs := data[pos]
				pos += 1
				if bs == 0:
					break
				lzw.append_array(data.slice(pos, pos + bs))
				pos += bs

			var indices := _lzw_decode(lzw, min_code_size, fw * fh)

			# 1. Применяем disposal ПРЕДЫДУЩЕГО кадра к холсту.
			if not frames.is_empty():
				if prev_disposal == 2:
					_clear_rect(canvas, canvas_w, prev_rect)
				elif prev_disposal == 3 and saved_for_dispose3.size() == canvas.size():
					canvas = saved_for_dispose3.duplicate()

			# 2. Если текущий кадр требует restore-to-previous — снимаем холст ДО отрисовки.
			if gce_disposal == 3:
				saved_for_dispose3 = canvas.duplicate()

			# 3. Рисуем индексы кадра на холст (прозрачные пиксели пропускаем).
			_blit(canvas, canvas_w, canvas_h, indices, fx, fy, fw, fh,
					interlaced, palette, gce_transparent)

			# 4. Снимок холста = готовый кадр.
			var img := Image.create_from_data(canvas_w, canvas_h, false, Image.FORMAT_RGBA8, canvas.duplicate())
			var delay_s := float(gce_delay) / 100.0
			if delay_s < 0.02:
				delay_s = 0.1   # как браузеры: 0/слишком быстрый -> разумный дефолт
			frames.append({"image": img, "delay": delay_s})

			prev_disposal = gce_disposal
			prev_rect = Rect2i(fx, fy, fw, fh)
			# Сбрасываем одноразовое состояние GCE.
			gce_delay = 0
			gce_transparent = -1
			gce_disposal = 0

		else:
			# Неизвестный байт — повреждённый поток, выходим с тем, что собрали.
			break

	return frames


## Пропускает цепочку суб-блоков (size-prefixed), возвращает позицию после терминатора 0.
static func _skip_sub_blocks(data: PackedByteArray, pos: int) -> int:
	var n := data.size()
	while pos < n:
		var bs := data[pos]
		pos += 1
		if bs == 0:
			break
		pos += bs
	return pos


## Очищает прямоугольник холста в прозрачный (disposal 2 — restore to background).
static func _clear_rect(canvas: PackedByteArray, cw: int, r: Rect2i) -> void:
	var x0 := maxi(0, r.position.x)
	var y0 := maxi(0, r.position.y)
	var x1 := r.position.x + r.size.x
	var y1 := r.position.y + r.size.y
	for y in range(y0, y1):
		var row := (y * cw + x0) * 4
		for x in range(x0, x1):
			canvas[row] = 0
			canvas[row + 1] = 0
			canvas[row + 2] = 0
			canvas[row + 3] = 0
			row += 4


## Рисует кадр (палитровые индексы) на RGBA-холст, пропуская прозрачный индекс.
## Учитывает чересстрочность (interlace) при маппинге строк.
static func _blit(canvas: PackedByteArray, cw: int, ch: int, indices: PackedByteArray,
		fx: int, fy: int, fw: int, fh: int, interlaced: bool,
		palette: PackedByteArray, transparent: int) -> void:
	@warning_ignore("integer_division")
	var pal_count := palette.size() / 3
	for src_y in range(fh):
		var dst_y := fy + (_interlaced_row(src_y, fh) if interlaced else src_y)
		if dst_y < 0 or dst_y >= ch:
			continue
		var src_base := src_y * fw
		for src_x in range(fw):
			var idx := indices[src_base + src_x] if src_base + src_x < indices.size() else 0
			if idx == transparent or idx >= pal_count:
				continue
			var dst_x := fx + src_x
			if dst_x < 0 or dst_x >= cw:
				continue
			var p := (dst_y * cw + dst_x) * 4
			var c := idx * 3
			canvas[p] = palette[c]
			canvas[p + 1] = palette[c + 1]
			canvas[p + 2] = palette[c + 2]
			canvas[p + 3] = 255


## Переводит номер строки в чересстрочном порядке (4 прохода) в реальный номер строки.
static func _interlaced_row(decoded_row: int, fh: int) -> int:
	# Пройдём проходы, считая строки, пока не доберёмся до decoded_row.
	var passes := [[0, 8], [4, 8], [2, 4], [1, 2]]
	var count := decoded_row
	for p in passes:
		var start: int = p[0]
		var step: int = p[1]
		var rows_in_pass := 0
		var y := start
		while y < fh:
			rows_in_pass += 1
			y += step
		if count < rows_in_pass:
			return start + count * step
		count -= rows_in_pass
	return decoded_row   # не должно случаться


## LZW-распаковка данных кадра в палитровые индексы. expected — ожидаемый размер (fw*fh).
static func _lzw_decode(data: PackedByteArray, min_code_size: int, expected: int) -> PackedByteArray:
	var out := PackedByteArray()
	if min_code_size < 1 or min_code_size > 11:
		return out
	var clear_code := 1 << min_code_size
	var end_code := clear_code + 1

	# Словарь: каждая запись — PackedByteArray последовательности индексов.
	var dict: Array[PackedByteArray] = []
	var code_size := min_code_size + 1
	var next_code := end_code + 1

	var byte_pos := 0
	var bit_pos := 0
	var data_size := data.size()
	var prev := -1

	while true:
		# Читаем code_size бит, LSB-first.
		if byte_pos >= data_size:
			break
		var code := 0
		var got := 0
		while got < code_size:
			if byte_pos >= data_size:
				break
			code |= ((data[byte_pos] >> bit_pos) & 1) << got
			got += 1
			bit_pos += 1
			if bit_pos == 8:
				bit_pos = 0
				byte_pos += 1
		if got < code_size:
			break

		if code == clear_code:
			dict = _init_dict(clear_code)
			code_size = min_code_size + 1
			next_code = end_code + 1
			prev = -1
			continue
		if code == end_code:
			break

		var entry: PackedByteArray
		if prev == -1:
			# Первый код после clear — выводим как есть.
			if code >= dict.size():
				break
			entry = dict[code]
			out.append_array(entry)
			prev = code
			continue

		if code < dict.size():
			entry = dict[code]
		elif code == next_code:
			# Особый случай KwKwK: prev + первый символ prev.
			entry = dict[prev].duplicate()
			entry.append(dict[prev][0])
		else:
			break   # некорректный код

		out.append_array(entry)

		# Новая запись: prev + первый символ entry.
		if next_code < MAX_DICT:
			var new_entry := dict[prev].duplicate()
			new_entry.append(entry[0])
			dict.append(new_entry)
			next_code += 1
			if next_code == (1 << code_size) and code_size < 12:
				code_size += 1
		prev = code

		if out.size() >= expected:
			break

	# Гарантируем нужный размер (повреждённые потоки добиваем нулями).
	if out.size() < expected:
		out.resize(expected)
	elif out.size() > expected:
		out = out.slice(0, expected)
	return out


## Инициализирует LZW-словарь: коды 0..clear-1 — однобайтовые, плюс clear/end заглушки.
static func _init_dict(clear_code: int) -> Array[PackedByteArray]:
	var dict: Array[PackedByteArray] = []
	for i in range(clear_code):
		dict.append(PackedByteArray([i]))
	dict.append(PackedByteArray())   # clear
	dict.append(PackedByteArray())   # end
	return dict
