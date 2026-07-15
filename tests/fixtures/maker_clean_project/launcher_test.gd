extends Node


func _ready() -> void:
	var ok := true
	var unix_url := VrwebLauncher.local_url("/tmp/My VR World/index.html", "Linux")
	ok = ok and unix_url == "vrweblocal:///tmp/My VR World/index.html"
	var windows_url := VrwebLauncher.local_url("C:\\VR Worlds\\demo.html", "Windows")
	ok = ok and windows_url == "vrweblocal:///C:/VR Worlds/demo.html"
	var linux_plan := VrwebLauncher.launch_plan(unix_url, "/opt/Knossos/knossos",
			VrwebLauncher.MODE_EXECUTABLE, "Linux")
	ok = ok and bool(linux_plan.get("ok", false)) \
			and linux_plan.get("command", "") == "/opt/Knossos/knossos" \
			and linux_plan.get("args", []) == [unix_url]
	var mac_plan := VrwebLauncher.launch_plan(unix_url, "/Applications/Knossos Preview.app",
			VrwebLauncher.MODE_EXECUTABLE, "macOS")
	ok = ok and bool(mac_plan.get("ok", false)) \
			and mac_plan.get("command", "") == "/usr/bin/open" \
			and mac_plan.get("args", [])[1] == "/Applications/Knossos Preview.app"
	var deeplink_plan := VrwebLauncher.launch_plan(unix_url, "",
			VrwebLauncher.MODE_DEEPLINK, "Windows")
	ok = ok and bool(deeplink_plan.get("ok", false)) \
			and deeplink_plan.get("action", "") == "shell_open"
	var missing := VrwebLauncher.launch("/tmp/My VR World/index.html",
			"/definitely/missing/knossos", VrwebLauncher.MODE_EXECUTABLE)
	ok = ok and not bool(missing.get("ok", true)) \
			and str(missing.get("error", "")).contains("не найден")
	print("CLEAN MAKER LAUNCHER ", "PASSED" if ok else "FAILED")
	get_tree().quit(0 if ok else 1)

