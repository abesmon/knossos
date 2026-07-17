extends Node

var _failed := false


func _ready() -> void:
	_test_identity_headers()
	_test_demo_activation()
	await get_tree().process_frame
	var page := Node3D.new()
	add_child(page)
	var label := Label3D.new()
	var material := StandardMaterial3D.new()
	var loaded_material := StandardMaterial3D.new()
	page.add_child(label)
	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	var source := """
local label = document.query("#label")
local material = document.query("#material")
local loaded_material = document.query("#loaded-material")
assert(document.features.has("vrweb/assets/2"))
assert(document.assets.fetch_with("remote_data/message.txt", "text", {
  credentials = "omit",
}, function(event)
  assert(event.ok)
  assert(event.credentials == "omit")
  label.set("text", event.data)
end))
assert(document.assets.fetch_with("http://external.example/private", "text", {
  credentials = "include",
}, function(_event) end) == false)
assert(document.assets.fetch("logo.svg", "bytes", function(event)
  assert(event.ok)
  local image = document.assets.decode(event.data, "image")
  assert(image ~= nil)
  assert(image.apply(label, "text") == false)
  assert(image.apply(material, "albedo_texture"))
end))
assert(document.assets.load("logo.svg", "image", function(event)
  assert(event.ok and event.resource ~= nil)
  assert(event.resource.apply(loaded_material, "albedo_texture"))
end))
"""
	runtime.setup(page, {"label": label, "material": material,
			"loaded-material": loaded_material},
			"vrwebresource://remote_data_demo.html", null,
			VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL))
	var errors := []
	runtime.script_failed.connect(func(id, phase, message):
		errors.append({"id": id, "phase": phase, "message": message}))
	var activated := runtime.activate([{"id": "test.remote-data", "profile": "vrweb-luau/1",
		"kind": "inline", "source": source, "hash": source.sha256_text()}])
	_eq(activated.ok, true, "remote-data realm activates")
	for _frame in 30:
		if not label.text.is_empty() and material.albedo_texture != null \
				and loaded_material.albedo_texture != null:
			break
		await get_tree().process_frame
	_eq(label.text.contains("Текст загружен"), true, "text fetch updates a scene element")
	_eq(material.albedo_texture != null, true, "raw bytes decode and apply as an image resource")
	_eq(loaded_material.albedo_texture != null, true, "load composes fetch and image decode")
	_eq(errors.is_empty(), true, "asset callbacks stay inside the controlled realm (%s)" % str(errors))
	runtime.close()
	runtime.queue_free()
	page.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if _failed else 0)


func _test_identity_headers() -> void:
	_eq(VrwebScriptAssets._same_web_origin("https://home.example/world.html",
			"https://home.example/private.json"), true,
			"same-origin pages may use their scoped Home Server bearer")
	_eq(VrwebScriptAssets._same_web_origin("https://evil.example/world.html",
			"https://home.example/private.json"), false,
			"a third-party page cannot trigger ambient Home Server bearer auth")
	var old_key = HomeServer._key
	var old_cert_json: String = HomeServer.cert_json
	var old_cert_signature: String = HomeServer.cert_signature
	var old_cert: Dictionary = HomeServer._cert
	HomeServer._key = Crypto.new().generate_rsa(2048)
	var public_key: String = HomeServer._public_key_b64()
	HomeServer._cert = {"v": 1, "address": "asset-test@example.test",
		"public_key": public_key, "key_id": "test",
		"expires_at": int(Time.get_unix_time_from_system()) + 600}
	HomeServer.cert_json = JSON.stringify(HomeServer._cert)
	HomeServer.cert_signature = "test-home-server-signature"
	var url := "https://assets.example.test/private/image.png"
	var headers := HomeServer.data_identity_headers_for(url)
	var values := {}
	for header in headers:
		var separator := header.find(":")
		values[header.substr(0, separator)] = header.substr(separator + 1).strip_edges()
	var timestamp := int(values.get("X-VRWeb-Identity-Timestamp", "0"))
	var nonce := str(values.get("X-VRWeb-Identity-Nonce", ""))
	var payload := HomeServer.data_request_proof_payload("GET", url, timestamp, nonce)
	var proof := Marshalls.base64_to_raw(str(values.get("X-VRWeb-Identity-Proof", "")))
	_eq(headers.size(), 5, "identity request carries certificate and possession proof")
	_eq(Marshalls.base64_to_raw(str(values.get(
			"X-VRWeb-Identity-Certificate", ""))).get_string_from_utf8(),
			HomeServer.cert_json, "certificate JSON survives header encoding")
	_eq(HomeServer.verify_signature(public_key, payload.to_utf8_buffer(), proof), true,
			"resource owner can verify the URL-bound request proof")
	_eq(HomeServer.data_identity_headers_for("http://assets.example.test/private").is_empty(),
			true, "identity is never disclosed over plaintext HTTP")
	HomeServer._key = old_key
	HomeServer.cert_json = old_cert_json
	HomeServer.cert_signature = old_cert_signature
	HomeServer._cert = old_cert


func _test_demo_activation() -> void:
	var html := FileAccess.get_file_as_string("res://test_pages/remote_data_demo.html")
	var doc := HtmlParser.parse(html)
	var declarations := VrwebScriptDeclaration.collect(doc,
			"vrwebresource://remote_data_demo.html")
	_eq(declarations.errors.is_empty(), true, "remote-data demo declaration is valid")
	var policy := VrwebContentPolicy.new(VrwebContentPolicy.Mode.ALLOW_ALL)
	var built := VrwebBuilder.build(doc, "vrwebresource://remote_data_demo.html", policy)
	var page_root := built.get("root") as Node
	add_child(page_root)
	var targets := {}
	var index := SceneHtml.build_page_index(doc)
	for node_id in index.get("nodes", {}):
		var record: Dictionary = index.nodes[node_id]
		var node = (built.nodes as Dictionary).get(record.elem)
		if node != null:
			targets[node_id] = node
	for resource_id in built.get("resources", {}):
		targets[resource_id] = built.resources[resource_id]
	var runtime := VrwebLuauRuntime.new()
	add_child(runtime)
	runtime.setup(page_root, targets, "vrwebresource://remote_data_demo.html", null, policy)
	var activated := runtime.activate(declarations.scripts)
	_eq(activated.ok, true, "remote-data demo Luau and scene ids activate")
	runtime.close()
	runtime.queue_free()
	page_root.queue_free()


func _eq(actual, expected, label_text: String) -> void:
	if actual == expected:
		print("  [ok]  ", label_text)
	else:
		_failed = true
		push_error("FAIL: %s — expected %s, got %s" % [label_text, str(expected), str(actual)])
