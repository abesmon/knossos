extends SceneTree

## Хедлесс-проверка кластерной топологии (docs/clustering.md). Без 3D — печатает дерево
## кластеров-комнат, объекты, метки. Запуск:
##   godot --headless --path . --script res://tests/test_clustering.gd

const AUTHOR := """
<html><body>
  <section id="sec">
    <nav><a href="/a">a</a><a href="/b">b</a><a href="/c">c</a></nav>
    <h1>title1</h1>
    <p>para one</p>
    <p>para two</p>
    <h2>subtitle</h2>
    <p>subtitle text</p>
    <h1>title2</h1>
    <img src="cat.png" alt="кот">
    <table><tr><td>x</td></tr></table>
  </section>
</body></html>
"""

const TORN := """
<html><body>
  <div class="wrap" id="wrap" style="background-color:#102030">
    <h1 id="h">Заголовок</h1>
    <p>before image</p>
    <img src="mid.png" alt="mid">
    <p>after image</p>
  </div>
</body></html>
"""

const BLOCKS := """
<html><body>
  <article>
    <h1>Код и цитаты</h1>
    <p>интро</p>
    <pre>line1
  line2</pre>
    <blockquote>цитата с <a href="/src">источником</a></blockquote>
    <figure><img src="f.png" alt="рис"><figcaption>подпись</figcaption></figure>
    <p>аутро</p>
  </article>
</body></html>
"""

const HEADLESS := "<html><body><div><p>только текст</p><p>и ещё</p></div></body></html>"

# Проходная комната (вики-структура Поликуб): <section id> с единственным ребёнком и без
# своего наполнения схлопывается в ребёнка; якорь секции и semanticTag переносятся.
const PASSTHROUGH := """
<html><body>
  <section id="outer"><section id="inner"><h2>Заголовок</h2><p>текст</p></section></section>
</body></html>
"""

# Переносы строк внутри абзаца: <br> и кривой </br> (abesmon.syrupmg.ru). Текст не должен
# склеиваться, </br></br> -> пустая строка, ссылки сохраняют кликабельность.
const LINEBREAKS := """
<html><body>
  <p>Я веду блог</br></br>Я курирую <a href="/smg">SMG</a></br>А про друзей <a href="/friends">ТУТ</a></p>
</body></html>
"""

# Две ссылки-кнопки на отдельных строках (abesmon .buttons-table): схлопнутый перенос между
# inline-<a> -> ОДИН пробел, не склейка вплотную.
const SPACING := """
<html><body>
  <div class="buttons-table">
    <a href="/one">ONE WAY UP</a>
    <a href="/tg">Телеграм Открытия</a>
  </div>
</body></html>
"""

# Навбар (abesmon.syrupmg.ru): inline-div с классом "body-header" и span+3 ссылки.
# Должен стать группой-меню (кликабельной), НЕ заголовком.
const NAVBAR := """
<html><body>
  <div class="body-header">
    <span class="body-header-current" aria-current="page">Главная</span>
    <a href="/blog">Блог</a>
    <a href="/projects">Проекты</a>
    <a href="/friends">Мои друзья</a>
  </div>
  <h1>Контент</h1>
  <p>тело страницы</p>
</body></html>
"""


# RichText только из картинок (без связного текста) распаковывается в отдельные объекты-image.
# Галерея из inline-картинок-ссылок сливается в ОДИН RichText-сегмент (light-кластер меню),
# который целиком состоит из картинок -> раскрываем в отдельные image→navigate.
# Картинка-ссылка сохраняет кликабельность (function переезжает на объект). Смешанный абзац
# (текст + картинка) панелью остаётся.
const IMAGES_ONLY := """
<html><body>
  <div class="gallery">
    <a href="/x"><img src="a.png" alt="a"></a>
    <a href="/y"><img src="b.png" alt="b"></a>
    <a href="/z"><img src="c.png" alt="c"></a>
  </div>
  <p>подпись с <img src="d.png" alt="d"> внутри текста</p>
</body></html>
"""


var _holder: Node3D
var _gen


func _initialize() -> void:
	_dump_case("AUTHOR (section>nav>h1>...>h2>...>h1>img>table)", AUTHOR)
	_dump_case("TORN (h1 разорван картинкой; div с id+bg)", TORN)
	_dump_case("BLOCKS (pre/blockquote/figure — дробители)", BLOCKS)
	_dump_case("HEADLESS (нет заголовков -> одна комната)", HEADLESS)
	_dump_case("PASSTHROUGH (пустые section-обёртки схлопнуты, якоря перенесены)", PASSTHROUGH)
	# Шум: пустой <ul> и чекбокс без подписи выкидываются; чекбокс с aria-label остаётся.
	# Ожидаем в комнате только [input(Инструменты), text(контент)].
	_dump_case("NOISE (пустой ul + немой input выкинуты)",
		"<html><body><ul class=\"m\"></ul>" +
		"<input type=\"checkbox\" aria-label=\"Инструменты\">" +
		"<input type=\"checkbox\"><p>контент</p></body></html>")
	_dump_case("NAVBAR (div.body-header span+3a -> меню, НЕ заголовок)", NAVBAR)
	# Пустой ВИЗУАЛЬНЫЙ заголовок-ссылка (ries «ENTER →») -> разбирается в кликабельный text,
	# а не висит пустой комнатой-заголовком. Явный <h1> в <header> остаётся заголовком.
	_dump_case("BARE-VISUAL (styled <a> -> text+link, не heading)",
		"<html><body><header><h1>Титул</h1></header>" +
		"<p><a href=\"/home\" style=\"font-size:22px;font-weight:bold\"><span>ENTER →</span></a></p>" +
		"</body></html>")
	# Панель из одних картинок распакована: ждём objs=[image→navigate ×3, text(смешанный)].
	_dump_case("IMAGES-ONLY (RichText из картинок -> отдельные image)", IMAGES_ONLY)
	_dump_linebreaks()

	# Geometry smoke: BLOCKS содержит code/quote/figure — проверяем, что рендер не падает.
	var space := TopologyBuilder.build(HtmlParser.parse(BLOCKS))
	_holder = Node3D.new()
	get_root().add_child(_holder)
	var noop := func(_t): pass
	_gen = WorldGenerator.generate(space, _holder, int(hash("blocks")), noop)


func _process(_delta: float) -> bool:
	if _gen == null or not _gen.build_complete:
		return false
	print("\n========== GEOMETRY SMOKE (BLOCKS) ==========")
	print("build_complete=%s child_nodes=%d" % [str(_gen.build_complete), _holder.get_child_count()])
	_holder.queue_free()
	quit()
	return true


func _dump_linebreaks() -> void:
	print("\n========== LINEBREAKS / SPACING (<br>, </br>, пробел между inline-<a>) ==========")
	for pair in [["LINEBREAKS", LINEBREAKS], ["SPACING", SPACING]]:
		var space := TopologyBuilder.build(HtmlParser.parse(pair[1]))
		for o in space["rooms"][space["root"]]["objects"]:
			if o["type"] == "text":
				print(pair[0], " plain=", JSON.stringify(o["content"]["text"]))


func _dump_case(name: String, html: String) -> void:
	print("\n========== ", name, " ==========")
	var doc := HtmlParser.parse(html)
	var space := TopologyBuilder.build(doc)
	print("root=%d rooms=%d labels=%s" % [space["root"], space["rooms"].size(), str(space["labels"])])
	_dump_room(space, space["root"], 0)


func _dump_room(space: Dictionary, id: int, depth: int) -> void:
	var r: Dictionary = space["rooms"][id]
	var types: Array = []
	for o in r["objects"]:
		var fn = o.get("function", null)
		types.append(str(o["type"]) + ("→" + str(fn.get("kind")) if fn else ""))
	var h: Dictionary = r["hints"]
	var hint_str := "w=%s" % str(h.get("weight", 0))
	if h.has("semanticTag"):
		hint_str += " sem=%s" % h["semanticTag"]
	if h.has("css"):
		hint_str += " css=%s" % str(h["css"])
	print("%s#%d [%s] %s objs=%s" % ["  ".repeat(depth), id, r["kind"], hint_str, str(types)])
	for cid in r["children"]:
		_dump_room(space, cid, depth + 1)
