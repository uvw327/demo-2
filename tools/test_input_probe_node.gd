# 诊断探针节点：记录 _unhandled_input / _input 收到的事件，供链路测试打印。
extends Node3D


func _input(event: InputEvent) -> void:
	print("[probe/_input] ", event.get_class(), " pressed=", event.is_pressed())


func _unhandled_input(event: InputEvent) -> void:
	print("[probe/unhandled] ", event.get_class(), " pressed=", event.is_pressed(), " device=", event.device)
