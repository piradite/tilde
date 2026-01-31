@tool
extends EditorPlugin

func _enter_tree():
    add_autoload_singleton("Tilde", "res://addons/tilde/scenes/Tilde.tscn")

func _exit_tree():
    remove_autoload_singleton("Tilde")
