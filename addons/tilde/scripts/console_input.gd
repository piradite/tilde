extends LineEdit

func _gui_input(event):
    if event is InputEventKey and event.pressed:
        if event.keycode == KEY_P:
            var char = "P" if event.shift_pressed else "p"
            insert_text_at_caret(char)
            accept_event()
