extends SceneTree

## Хедлесс-проверка мини-каскада CSS: CssParser + StyleResolver (docs/css-cascade.md).
## Запуск: godot --headless --path . --script res://tests/test_css.gd

var _ok := true


func _initialize() -> void:
	_parser_suite()
	_resolver_suite()
	_topology_suite()
	_demo_page_suite()
	_fetcher_suite()
	print("\n=== ", ("ALL PASSED" if _ok else "FAILURES ABOVE"), " ===")
	quit(0 if _ok else 1)


# --- CssParser ---

func _parser_suite() -> void:
	print("\n-- CssParser --")

	var rules := CssParser.parse("h1 { color: red; margin: 0 }")
	_check(rules.size() == 1, "правило распарсено, margin отброшен вайтлистом")
	if rules.size() == 1:
		_check(rules[0]["decls"].size() == 1 and rules[0]["decls"].has("color"), "остался только color")

	_check(CssParser.parse("p { margin: 0; padding: 1px }").is_empty(),
			"правило без вайтлист-свойств выброшено целиком")

	rules = CssParser.parse("/* c1 */ p { /* c2 */ color: blue }")
	_check(rules.size() == 1, "комментарии вычищены")

	# Специфичность: a=id, b=class/attr, c=tag.
	rules = CssParser.parse("#i .a.b span[href] { color: red }")
	if _check(rules.size() == 1, "compound-цепочка распарсена"):
		_check(rules[0]["spec"] == 1_000_000 + 3 * 1_000 + 1, "специфичность (1,3,1)")
		_check((rules[0]["parts"] as Array).size() == 3, "3 compound-части")
		_check((rules[0]["combinators"] as Array) == [" ", " "], "комбинаторы-потомки")

	rules = CssParser.parse("ul > li { color: red }")
	if _check(rules.size() == 1, "child-комбинатор распарсен"):
		_check((rules[0]["combinators"] as Array) == [">"], "комбинатор >")

	rules = CssParser.parse("a:hover, .keep { color: red }")
	if _check(rules.size() == 1, "a:hover выброшен, .keep остался"):
		_check((rules[0]["parts"] as Array)[0]["classes"] == ["keep"], "выжил именно .keep")

	rules = CssParser.parse(":root { --x: 1 } h1 + p { color: red } h1 ~ p { color: blue }")
	_check(rules.size() == 1, "+/~ не поддержаны и выброшены, :root остался")
	if rules.size() == 1:
		_check((rules[0]["parts"] as Array)[0]["tag"] == "html", ":root нормализован в html")

	# Вложенность в значениях: ; внутри url(data:...) не рвёт декларации.
	var decls := CssParser.parse_declarations(
			"background-image:url(\"data:image/svg+xml;base64,AA;BB\");color:red")
	_check(decls.has("background-image") and decls.has("color"), "url(data:...;...) не ломает сплит")

	decls = CssParser.parse_declarations("color: red !important; color: blue")
	_check(decls["color"]["v"] == "red" and decls["color"]["imp"], "!important не сдаётся поздней обычной")

	decls = CssParser.parse_declarations("background: #fff url(x.png) no-repeat")
	_check(decls.has("background-color") and decls.has("background-image")
			and decls["background-color"]["short"], "шортхенд background развёрнут")
	_check(CssParser.color_token("#fff url(x.png) no-repeat") == "#fff", "цветовой токен шортхенда")
	_check(CssParser.extract_url("#fff url(x.png) no-repeat") == "x.png", "url-токен шортхенда")

	# @media
	_check(CssParser.media_matches("screen"), "@media screen проходит")
	_check(CssParser.media_matches("(min-width: 600px)"), "min-width 600 при viewport 1280")
	_check(not CssParser.media_matches("(min-width: 2000px)"), "min-width 2000 не проходит")
	_check(not CssParser.media_matches("print"), "print не проходит")
	_check(CssParser.media_matches("not print"), "not print проходит")
	_check(CssParser.media_matches("screen, print"), "список: хоть один совпал")
	rules = CssParser.parse("@media (min-width: 600px) { p { color: red } } @media print { p { color: blue } }")
	_check(rules.size() == 1 and rules[0]["decls"]["color"]["v"] == "red", "@media фильтрует блоки")
	rules = CssParser.parse("@supports (display: grid) { p { color: red } }")
	_check(rules.size() == 1, "@supports — спускаемся внутрь")
	rules = CssParser.parse("@font-face { font-family: x; src: url(a.woff) } p { color: red }")
	_check(rules.size() == 1, "@font-face пропущен блоком, парсинг продолжился")

	# @import
	var imports := CssParser.extract_imports("@import url(\"a.css\") screen; @import 'b.css'; p{}")
	_check(imports.size() == 2 and imports[0]["href"] == "a.css" and imports[0]["media"] == "screen"
			and imports[1]["href"] == "b.css", "@import: url() и строка")

	# Цвета
	_check(CssParser.parse_color("#ff0000") == Color.RED, "#hex")
	_check(CssParser.parse_color("rgb(255, 0, 0)") == Color.RED, "rgb()")
	_check(CssParser.parse_color("rgb(100% 0% 0% / 1)") == Color.RED, "современный rgb с %")
	_check(CssParser.parse_color("rgba(0,0,0,0)") == null, "альфа 0 -> null")
	_check(CssParser.parse_color("teal") is Color, "именованный цвет")
	_check(CssParser.parse_color("transparent") == null, "transparent -> null")
	var hsl: Variant = CssParser.parse_color("hsl(0, 100%, 50%)")
	_check(hsl is Color and (hsl as Color).is_equal_approx(Color.RED), "hsl() -> rgb")


# --- StyleResolver ---

func _resolver_suite() -> void:
	print("\n-- StyleResolver --")

	# Специфичность и порядок источника.
	var doc := _resolve("<div id='i' class='c'>x</div>",
			["div { color: red } .c { color: green } #i { color: blue }"])
	_check(_color_of(doc, "div") == Color.BLUE, "#id бьёт .class и tag")
	doc = _resolve("<p class='c'>x</p>", ["p { color: red } p { color: blue }"])
	_check(_color_of(doc, "p") == Color.BLUE, "при равной специфичности поздний побеждает")
	doc = _resolve("<p>x</p>", ["p { color: red !important } p { color: blue }"])
	_check(_color_of(doc, "p") == Color.RED, "!important бьёт поздний обычный")
	doc = _resolve("<p style='color: blue'>x</p>", ["p { color: red }"])
	_check(_color_of(doc, "p") == Color.BLUE, "инлайн бьёт author")
	doc = _resolve("<p style='color: blue'>x</p>", ["p { color: red !important }"])
	_check(_color_of(doc, "p") == Color.RED, "author !important бьёт инлайн")

	# Наследование цвета + own-флаг + currentColor.
	doc = _resolve("<div class='outer'><p>x</p></div>", [".outer { color: teal }"])
	var p := doc.find_descendant("p")
	_check(p.computed.get("color") == CssParser.parse_color("teal"), "color наследуется")
	_check(not p.computed.get("color-own", false), "унаследованный цвет не own")
	_check(doc.find_descendant("div").computed.get("color-own", false), "своя декларация own")
	doc = _resolve("<div><p>x</p></div>",
			["div { color: teal } p { background-color: currentcolor }"])
	_check(doc.find_descendant("p").computed.get("background-color") == CssParser.parse_color("teal"),
			"currentColor -> вычисленный color")

	# font-size: цепочка em/%/rem.
	doc = _resolve("<div class='a'><span class='b'><i class='c'>x</i></span></div>",
			[".a { font-size: 20px } .b { font-size: 1.5em } .c { font-size: 50% }"])
	_check(is_equal_approx(_fs(doc, "i"), 15.0), "em и % против родителя (20 -> 30 -> 15)")
	doc = _resolve("<html><body><p class='r'>x</p></body></html>",
			["html { font-size: 20px } .r { font-size: 2rem }"])
	_check(is_equal_approx(_fs(doc, "p"), 40.0), "rem против недефолтного корня")
	doc = _resolve("<p style='font: italic bold 24px/1.5 Arial'>x</p>", [])
	_check(is_equal_approx(_fs(doc, "p"), 24.0), "шортхенд font -> кегль")

	# font-weight
	doc = _resolve("<div class='b'><span class='br'>x</span></div>",
			[".b { font-weight: bold } .br { font-weight: bolder }"])
	_check(doc.find_descendant("span").computed["font-weight"] == 900, "bolder от родителя 700")
	doc = _resolve("<p style='font-weight: 550'>x</p>", [])
	_check(doc.find_descendant("p").computed["font-weight"] == 550, "числовой вес")

	# Скрытие через класс (.sr-only-паттерн) и display:none.
	doc = _resolve("<span class='sr-only'>x</span>",
			[".sr-only { position: absolute; width: 1px; height: 1px; clip: rect(0, 0, 0, 0) }"])
	_check(doc.find_descendant("span").computed.get("hidden", false), ".sr-only (clip) -> hidden")
	doc = _resolve("<nav class='menu'>x</nav>", [".menu { display: none }"])
	_check(doc.find_descendant("nav").computed.get("hidden", false), "display:none через класс")
	doc = _resolve("<div class='off'>x</div>",
			[".off { position: fixed; left: -9999px }"])
	_check(doc.find_descendant("div").computed.get("hidden", false), "унос за экран через класс")
	# visibility наследуется, visible у ребёнка перекрывает.
	doc = _resolve("<div class='h'><p class='v'>x</p><span>y</span></div>",
			[".h { visibility: hidden } .v { visibility: visible }"])
	_check(doc.find_descendant("span").computed.get("hidden", false), "visibility:hidden наследуется")
	_check(not doc.find_descendant("p").computed.get("hidden", false), "visible у ребёнка перекрывает")

	# Комбинаторы: бэктрекинг потомка при child-цепочке.
	doc = _resolve("<div class='a'><div class='b'><section><p>x</p></section></div></div>",
			[".a > .b p { color: red }"])
	_check(_color_of(doc, "p") == Color.RED, "смешанная цепочка > + потомок")
	doc = _resolve("<ul><li><ol><li class='x'>a</li></ol></li></ul>",
			["ul > li.x { color: red }"])
	_check(_color_of(doc, "li.x") == null, "child не срабатывает через уровень")

	# [attr]
	doc = _resolve("<a href='x'>a</a><a>b</a>", ["a[href] { color: red }"])
	var links := _all(doc, "a")
	_check(links[0].computed.get("color") == Color.RED and links[1].computed.get("color") == null,
			"[attr] по наличию")

	# CSS-переменные.
	doc = _resolve("<body><p>x</p></body>",
			[":root { --main: teal } p { color: var(--main) }"])
	_check(_color_of(doc, "p") == CssParser.parse_color("teal"), "var() от :root")
	doc = _resolve("<p>x</p>", ["p { color: var(--nope, blue) }"])
	_check(_color_of(doc, "p") == Color.BLUE, "var() fallback")
	doc = _resolve("<body><div>x</div></body>",
			[":root { --bg: #102030 } div { background: var(--bg) url(x.png) }"])
	var div := doc.find_descendant("div")
	_check(div.computed.get("background-color") == Color.html("#102030"),
			"var() внутри шортхенда background")
	_check(div.computed.get("background-image", "") == "x.png", "картинка шортхенда с var()")

	# Презентационные атрибуты — слабейший тир.
	doc = _resolve("<body bgcolor='#ff0000'>x</body>", [])
	_check(doc.find_descendant("body").computed.get("background-color") == Color.RED,
			"bgcolor без CSS работает")
	doc = _resolve("<body bgcolor='#ff0000'>x</body>", ["body { background-color: blue }"])
	_check(doc.find_descendant("body").computed.get("background-color") == Color.BLUE,
			"CSS-правило бьёт bgcolor")
	doc = _resolve("<font size='6'>x</font>", [])
	_check(is_equal_approx(_fs(doc, "font"), 32.0), "<font size=6> -> 32px")

	# border: none не считается рамкой.
	doc = _resolve("<div class='b'>x</div><div class='n'>y</div>",
			[".b { border: 1px solid red } .n { border: none }"])
	var divs := _all(doc, "div")
	_check(divs[0].computed.get("border", false), "border: 1px solid -> хинт")
	_check(not divs[1].computed.get("border", false), "border: none -> нет хинта")


# --- Интеграция с топологией ---

func _topology_suite() -> void:
	print("\n-- Топология --")
	var visible := """
	<html><body>
	<section><h2>Первая</h2><p>Текст текст текст</p></section>
	<section class='gone'><h2>Вторая</h2><p>Ещё текст</p></section>
	</body></html>
	"""
	var doc := HtmlParser.parse(visible)
	StyleResolver.resolve(doc, [])
	var space_all := TopologyBuilder.build(doc)
	doc = HtmlParser.parse(visible)
	StyleResolver.resolve(doc, [".gone { display: none }"])
	var space_hidden := TopologyBuilder.build(doc)
	_check((space_hidden["rooms"] as Dictionary).size() < (space_all["rooms"] as Dictionary).size(),
			"секция, скрытая классом, не попадает в мир")

	# Паспорт документа из каскада (то, что раньше давал только инлайн/простой экстрактор).
	doc = HtmlParser.parse("<html><head><style>body { background: #102030; color: #aabbcc }</style></head><body><p>x</p></body></html>")
	var refs := StyleResolver.collect_sheet_refs(doc)
	_check(refs.size() == 1 and refs[0]["kind"] == "inline", "collect_sheet_refs видит <style>")
	StyleResolver.resolve(doc, [refs[0]["text"]])
	var space := TopologyBuilder.build(doc)
	var passport: Dictionary = space.get("document", {})
	_check(passport.get("bg", "").begins_with("#102030"), "паспорт: фон body из каскада")
	_check(passport.get("fg", "").begins_with("#aabbcc"), "паспорт: цвет текста из каскада")


# --- Демо-страница (e2e без сети: файлы читаются напрямую) ---

func _demo_page_suite() -> void:
	print("\n-- css_demo (e2e) --")
	var html := _read("res://addons/vrweb_tools/examples/css_demo.html")
	var css := _read("res://addons/vrweb_tools/examples/css_demo.css")
	if not _check(html != "" and css != "", "examples/css_demo.{html,css} читаются"):
		return
	var doc := HtmlParser.parse(html)
	var refs := StyleResolver.collect_sheet_refs(doc)
	var has_link := false
	for r in refs:
		if r["kind"] == "link" and r["href"] == "css_demo.css":
			has_link = true
	_check(has_link, "<link rel=stylesheet> найден")
	var texts: Array = []
	for r in refs:
		texts.append(r["text"] if r["kind"] == "inline" else css)
	StyleResolver.resolve(doc, texts)
	var space := TopologyBuilder.build(doc)
	_check((space["document"] as Dictionary).has("bg"), "паспорт документа из внешней таблицы")
	var hidden_probe := _find_class(doc, "sr-only")
	_check(hidden_probe != null and hidden_probe.computed.get("hidden", false),
			".sr-only из внешней таблицы скрыт")


# --- CssFetcher (локальные схемы: без сети, синхронно) ---

func _fetcher_suite() -> void:
	print("\n-- CssFetcher --")
	var fetcher := CssFetcher.new()
	get_root().add_child(fetcher)

	# Лямбда захватывает по значению — наружу отдаём через мутацию общего словаря.
	var got := {}
	fetcher.fetch_all(["vrwebresource://examples/css_demo.css"], 2.0,
			func(res: Dictionary): got.merge(res))
	var demo_text := String(got.get("vrwebresource://examples/css_demo.css", ""))
	_check(demo_text.contains(".card"), "локальная таблица прочитана (vrwebresource)")

	got.clear()
	fetcher.fetch_all(["vrwebresource://examples/css_import_a.css"], 2.0,
			func(res: Dictionary): got.merge(res))
	var flat := String(got.get("vrwebresource://examples/css_import_a.css", ""))
	_check(flat.contains(".a") and flat.contains(".b"), "@import развёрнут в плоский текст")
	_check(not flat.contains("@import"), "@import-стейтменты вырезаны")
	_check(flat.count(".b") == 1, "print-@import заменён пустым, не текстом")

	got.clear()
	fetcher.fetch_all(["vrwebresource://no_such_file.css"], 2.0,
			func(res: Dictionary): got.merge(res))
	_check(got.has("vrwebresource://no_such_file.css")
			and String(got["vrwebresource://no_such_file.css"]) == "",
			"недоступная таблица -> пустой текст, колбэк всё равно зовётся")

	fetcher.queue_free()


# --- Хелперы ---

func _resolve(body_html: String, sheets: Array) -> HtmlNode:
	var doc := HtmlParser.parse(body_html)
	StyleResolver.resolve(doc, sheets)
	return doc


func _color_of(doc: HtmlNode, what: String) -> Variant:
	var node: HtmlNode
	if what.contains("."):
		node = _find_class(doc, what.get_slice(".", 1))
	else:
		node = doc.find_descendant(what)
	return node.computed.get("color") if node != null else null


func _fs(doc: HtmlNode, tag: String) -> float:
	var node := doc.find_descendant(tag)
	return node.computed.get("font-size", -1.0) if node != null else -1.0


func _all(doc: HtmlNode, tag: String) -> Array:
	var out: Array = []
	_collect_tag(doc, tag, out)
	return out


func _collect_tag(n: HtmlNode, tag: String, out: Array) -> void:
	if n.tag == tag:
		out.append(n)
	for c in n.children:
		_collect_tag(c, tag, out)


func _find_class(n: HtmlNode, cl: String) -> HtmlNode:
	if n.get_attr("class").split(" ", false).has(cl):
		return n
	for c in n.children:
		var f := _find_class(c, cl)
		if f != null:
			return f
	return null


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _check(cond: bool, label: String) -> bool:
	print(("  [ok]  " if cond else "  [FAIL] "), label)
	if not cond:
		_ok = false
	return cond
