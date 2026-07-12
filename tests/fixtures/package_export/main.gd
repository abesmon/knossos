extends Node3D

const Dep = preload("./dep.gd")

@export var marker := "package-default"


func answer() -> int:
	return Dep.VALUE


func optional_message_resource():
	return load("./message.txt")


func switch_scene():
	return load("./switch_scene.tscn")
