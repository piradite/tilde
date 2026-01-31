extends CanvasLayer

enum BoolDisplay { TRUE_FALSE, ON_OFF, ONE_ZERO, YES_NO }

const CONFIG_PATH = "user://tilde.cfg"
const DEFAULT_SIZE = Vector2(700, 500)
const MIN_SIZE = Vector2(300, 200)

@onready var window: Panel = $ConsoleWindow
@onready var margin: MarginContainer = $ConsoleWindow/WindowMargin
@onready var blocker: ColorRect = $BackgroundBlocker
@onready var header: Panel = $ConsoleWindow/WindowMargin/MainVBox/TitleBar
@onready var close_btn: Button = $ConsoleWindow/WindowMargin/MainVBox/TitleBar/HBox/CloseBtn

@onready var tabs = {
    "term": $ConsoleWindow/WindowMargin/MainVBox/Tabs/BtnTerminal,
    "act": $ConsoleWindow/WindowMargin/MainVBox/Tabs/BtnActions,
    "insp": $ConsoleWindow/WindowMargin/MainVBox/Tabs/BtnInspector,
    "sett": $ConsoleWindow/WindowMargin/MainVBox/Tabs/BtnSettings
}
@onready var views = {
    "term": $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/TerminalView,
    "act": $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/ActionsView,
    "insp": $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView,
    "sett": $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/SettingsView
}

@onready var term_input: LineEdit = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/TerminalView/Input
@onready var term_log: RichTextLabel = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/TerminalView/History
@onready var term_list: ItemList = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/TerminalView/Suggestions
@onready var term_search: LineEdit = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/TerminalView/HistorySearch

@onready var act_list: VBoxContainer = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/ActionsView/Scroll/ActionList
@onready var act_search: LineEdit = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/ActionsView/ActionSearch

@onready var insp_tree: Tree = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView/Tree
@onready var insp_search: LineEdit = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView/Search
@onready var insp_info: Label = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView/Details/DetailsVBox/NodeInfo

@onready var sett_list: VBoxContainer = $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/SettingsView/SettingsList

@onready var monitor: Label = $PerfOverlay

var is_open: bool = false
var history: Array[String] = []
var history_idx: int = -1
var cmds: Dictionary = {}
var aliases: Dictionary = {}
var config: ConfigFile = ConfigFile.new()
var _renames: Dictionary = {}
var _reset_pending: bool = false
var _reset_timer: float = 0.0

var theme_res: Theme = Theme.new()
var style_win: StyleBoxFlat = StyleBoxFlat.new()
var style_head: StyleBoxFlat = StyleBoxFlat.new()
var font_size: int = 16
var bg_color: Color = Color(0.1, 0.1, 0.1, 0.95)
var border_color: Color = Color(0.3, 0.3, 0.3, 1.0)
var border_width: int = 1
var radius: int = 4
var color_logs: bool = true

var pause_mode: bool = true
var bool_fmt: int = BoolDisplay.TRUE_FALSE
var persist: bool = true
var mouse_prev: int = Input.MOUSE_MODE_VISIBLE
var pause_prev: bool = false

var toggle_keys: Array = [KEY_QUOTELEFT]
var _bind_idx: int = -1

var metrics = {
    "fps": true,
    "ram": true,
    "vram": false,
    "nodes": false,
    "draws": false
}

var dragging: bool = false
var drag_off: Vector2 = Vector2.ZERO
var resize_dir: int = 0
var resize_start: Vector2 = Vector2.ZERO
var resize_rect: Rect2 = Rect2()
var mon_drag: bool = false
var mon_off: Vector2 = Vector2.ZERO
var mon_start: Vector2 = Vector2.ZERO

var sel_node: Node = null
var insp_timer: float = 0.0

var _watches: Array[Dictionary] = []
var _watch_box: VBoxContainer = null

var _full_log: Array[Dictionary] = [] 

var tpl_scene: PackedScene = preload("res://addons/tilde/scenes/action.tscn")
var _tpls: Node = null
var _overrides: Dictionary = {}

func _ready():
    visible = true
    window.visible = false
    blocker.visible = false
    layer = 128
    process_mode = Node.PROCESS_MODE_ALWAYS
    
    _tpls = tpl_scene.instantiate()
    
    _watch_box = VBoxContainer.new()
    _watch_box.name = "WatchList"
    act_list.add_child(_watch_box)
    act_list.move_child(_watch_box, 0)
    
    move_child(monitor, 1) 
    
    window.theme = theme_res
    monitor.theme = theme_res
    window.add_theme_stylebox_override("panel", style_win)
    header.add_theme_stylebox_override("panel", style_head)
    
    _load_cfg()
    _style_win()
    _bind_signals()
    _update_fonts()
    _init_cmds()
    _build_settings()
    _init_scripts()

func _process(delta):
    if monitor.visible: _update_monitor()
    if is_open:
        var focus = get_viewport().gui_get_focus_owner()
        if focus == null or not is_ancestor_of(focus):
            term_input.grab_focus()
        elif tabs["term"].button_pressed and focus != term_input and focus != term_search:
            term_input.grab_focus()
        if views["insp"].visible:
            insp_timer += delta
            if insp_timer >= 0.5:
                insp_timer = 0; _update_details()
        if views["act"].visible: _update_watches()
    if _reset_pending:
        _reset_timer -= delta
        if _reset_timer <= 0: _reset_pending = false

func _init_scripts():
    var files = _find_scripts("res://")
    for path in files:
        if path.begins_with("res://addons"): continue
        var f = FileAccess.open(path, FileAccess.READ)
        if f and f.get_as_text().findn("tilde") != -1:
            _load_script(path)

func _find_scripts(path: String) -> Array[String]:
    var list: Array[String] = []
    var dir = DirAccess.open(path)
    if dir:
        dir.list_dir_begin()
        var name = dir.get_next()
        while name != "":
            if dir.current_is_dir():
                if name != "." and name != "..":
                    list.append_array(_find_scripts(path.path_join(name)))
            elif name.get_extension() == "gd":
                list.append(path.path_join(name))
            name = dir.get_next()
    return list

func _load_script(path: String):
    var sc = load(path)
    if not sc: return
    if sc.get_instance_base_type() not in ["Node", "Object", "RefCounted"]: return
    var inst = sc.new()
    if inst is Node:
        inst.name = path.get_file().get_basename() + "_AutoTilde"
        add_child(inst)

func _input(event):
    if _bind_idx != -1:
        if event is InputEventKey and event.pressed:
            get_viewport().set_input_as_handled()
            if event.keycode == KEY_ESCAPE:
                _bind_idx = -1
            else:
                _set_keybind_slot(_bind_idx, event.keycode)
                _bind_idx = -1
            _refresh_settings_ui()
        return

    if event.is_pressed() and _is_activation(event):
        toggle(); get_viewport().set_input_as_handled()
    if is_open and event is InputEventKey and event.pressed and event.ctrl_pressed:
        if event.keycode in [KEY_EQUAL, KEY_PLUS]:
            font_size += 2; _update_fonts(); _save_cfg(); get_viewport().set_input_as_handled()
        elif event.keycode == KEY_MINUS:
            font_size = max(8, font_size - 2); _update_fonts(); _save_cfg(); get_viewport().set_input_as_handled()
    if dragging and event is InputEventMouseMotion: _handle_drag(); get_viewport().set_input_as_handled()
    if resize_dir != 0 and event is InputEventMouseMotion: _handle_resize(); get_viewport().set_input_as_handled()
func _is_activation(event) -> bool:
    for b in toggle_keys:
        if b is int and event is InputEventKey and event.keycode == b: return true
        if b is String and event.is_action_pressed(b): return true
        if b is InputEvent:
            if b is InputEventKey and event is InputEventKey and b.keycode == event.keycode: return true
            if b.is_match(event): return true
    return false

func keybind(bind_var):
    add_keybind(bind_var)

func add_keybind(bind_var):
    if bind_var not in toggle_keys:
        toggle_keys.append(bind_var)
        _save_cfg()

func set_keybinds(list: Array):
    toggle_keys = list
    _save_cfg()

func set_template_override(type: String, node: Node):
    _overrides[type] = node

func add_custom_control(ctrl: Control, filter: String = ""):
    act_list.add_child(ctrl)
    ctrl.set_meta("filter", filter if filter != "" else ctrl.name)
    _apply_style(ctrl)

func add_category(txt: String):
    var btn = _get_template("Category")
    btn.text = txt
    act_list.add_child(btn)
    btn.set_meta("filter", txt)
    _apply_style(btn)

func add_button(txt: String, cb: Callable, desc: String = "", req: bool = false):
    _make_btn(txt, cb, req)
    var slug = txt.to_lower().replace(" ", "_")
    register_command(slug, func(_a): _safe_call(cb, req).call(), desc)

func add_toggle(txt: String, init: bool, cb: Callable, desc: String = "", key: String = ""):
    _make_toggle(txt, init, cb, key)
    var slug = txt.to_lower().replace(" ", "_")
    register_command(slug, func(args):
        if args.size() > 0:
            var val = _parse_bool(args[0])
            if val != null: 
                if persist and key != "":
                    config.set_value("persistence", key, val)
                    _save_cfg()
                cb.call(val)
        else:
            log_message(txt + " (Toggle logic not directly togglable via command yet)") 
    , desc, _bool_opts)

func add_input(txt: String, cb: Callable, desc: String = "", req: bool = false):
    _make_input(txt, "Set", cb, req)
    var slug = txt.to_lower().replace(" ", "_")
    register_command(slug, func(args):
        if args.size() > 0: _safe_call(cb, req).call(args[0])
    , desc)

func add_dropdown(txt: String, getter: Callable, cb: Callable, desc: String = "", req: bool = false):
    var items = getter.call()
    _make_menu(txt, items, cb, "Go", req)
    var slug = txt.to_lower().replace(" ", "_")
    register_command(slug, func(args):
        if args.size() > 0: _safe_call(cb, req).call(args[0])
    , desc, func(args): return [] if args.size() > 0 else getter.call())

func add_slider(label: String, min_v: float, max_v: float, cb: Callable, init: float = 0.0):
    _make_slider(label, min_v, max_v, cb, init)

func add_color(label: String, init: Color, cb: Callable):
    _make_color(label, init, cb)

func add_watch(label: String, getter: Callable):
    var row = HBoxContainer.new()
    var lbl = Label.new()
    lbl.text = label + ":"
    var val = Label.new()
    val.text = "..."
    val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(lbl)
    row.add_child(val)
    _watch_box.add_child(row)
    _watches.append({"label": label, "node": val, "getter": getter})
    _apply_style(row)

func add_vec2(label: String, cb: Callable, init: Vector2 = Vector2.ZERO, req: bool = false):
    var row = _get_template("Input")
    row.get_node("Label").text = label + ":"
    var input = row.get_node("LineEdit")
    var btn = row.get_node("Button")
    input.text = str(init)
    btn.text = "Set"
    var logic = func(s):
        var v = str_to_var("Vector2" + s if not s.begins_with("(") else s)
        if v is Vector2: _safe_call(cb, req).call(v)
        else: log_message("Invalid Vector2! Use (x, y)", Color.RED)
    btn.pressed.connect(func(): logic.call(input.text))
    act_list.add_child(row)
    var slug = label.to_lower().replace(" ", "_")
    register_command(slug, func(args):
        if args.size()>0: logic.call(" ".join(args))
    , "Set " + label + " (Vector2)")
    row.set_meta("filter", label)
    _apply_style(row)

func add_separator():
    act_list.add_child(HSeparator.new())

func add_spacer(h: int = 10):
    var s = Control.new()
    s.custom_minimum_size.y = h
    act_list.add_child(s)

func register_command(cmd: String, call: Callable, desc: String = "", comp: Callable = Callable()):
    var name = cmd
    if _renames.has(cmd):
        name = _renames[cmd]
        _renames.erase(cmd)
    cmds[name] = {"func": call, "desc": desc, "comp": comp}

func rename_command(old: String, new: String):
    if cmds.has(old):
        cmds[new] = cmds[old]
        cmds.erase(old)
    else:
        _renames[old] = new

func log_message(txt: String, col: Color = Color.WHITE):
    _full_log.append({"text": txt, "color": col})
    _log_append(txt, col)

func _log_append(txt: String, col: Color):
    var lines = txt.split("\n")
    for line in lines:
        var f = line
        if color_logs:
            if "error" in line.to_lower(): f = "[color=red]" + line + "[/color]"
            elif "warn" in line.to_lower(): f = "[color=yellow]" + line + "[/color]"
        term_log.push_color(col)
        term_log.append_text(f + "\n")
        term_log.pop()
    
    term_log.call_deferred("scroll_to_line", term_log.get_line_count())

func toggle():
    is_open = !is_open
    window.visible = is_open
    blocker.visible = is_open
    monitor.mouse_filter = Control.MOUSE_FILTER_STOP if is_open else Control.MOUSE_FILTER_IGNORE
    if is_open:
        mouse_prev = Input.mouse_mode
        pause_prev = get_tree().paused
        if pause_mode: get_tree().paused = true
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
        term_input.grab_focus()
        term_input.clear()
    else:
        Input.mouse_mode = mouse_prev
        get_tree().paused = pause_prev
        term_input.release_focus()
        term_list.visible = false
        dragging = false
        resize_dir = 0
        _save_cfg()

func process_command(txt: String):
    var p = txt.strip_edges().split(" ", false)
    if p.is_empty(): return
    var name = p[0]
    if cmds.has(name):
        cmds[name]["func"].call(p.slice(1))
    else:
        log_message("Unknown command: " + name, Color.RED)

func _get_template(type: String) -> Control:
    if _overrides.has(type):
        var node = _overrides[type]
        return node.instantiate() if node is PackedScene else node.duplicate()
    return _tpls.get_node(type).duplicate()

func _make_btn(txt: String, cb: Callable, req: bool, parent = act_list):
    var btn = _get_template("Button")
    btn.text = txt
    btn.pressed.connect(_safe_call(cb, req))
    parent.add_child(btn)
    btn.set_meta("filter", txt)
    _apply_style(btn)

func _make_toggle(txt: String, init: bool, cb: Callable, key: String, parent = act_list):
    var btn = _get_template("Toggle")
    btn.text = txt
    var s = init
    if persist and key != "":
        s = config.get_value("persistence", key, init)
    btn.button_pressed = s
    btn.toggled.connect(func(t):
        if persist and key != "":
            config.set_value("persistence", key, t)
            _save_cfg()
        cb.call(t)
    )
    parent.add_child(btn)
    btn.set_meta("filter", txt)
    _apply_style(btn)

func _make_input(lbl: String, b_txt: String, cb: Callable, req: bool, parent = act_list):
    var row = _get_template("Input")
    row.get_node("Label").text = lbl + ":"
    var fld = row.get_node("LineEdit")
    var btn = row.get_node("Button")
    btn.text = b_txt
    btn.pressed.connect(func(): _safe_call(cb, req).call(fld.text))
    parent.add_child(row)
    row.set_meta("filter", lbl)
    _apply_style(row)
    return row

func _make_menu(lbl: String, items: Array, cb: Callable, b_txt: String, req: bool, parent = act_list):
    var row = _get_template("Dropdown")
    row.get_node("Label").text = lbl + ":"
    var opt = row.get_node("OptionButton")
    var btn = row.get_node("Button")
    btn.text = b_txt
    for i in items: opt.add_item(str(i))
    btn.pressed.connect(func(): _safe_call(cb, req).call(opt.selected))
    parent.add_child(row)
    row.set_meta("filter", lbl)
    _apply_style(row)
    return row

func _make_slider(lbl: String, min_v: float, max_v: float, cb: Callable, init: float, parent = act_list):
    var row = _get_template("Slider")
    row.get_node("Label").text = lbl + ":"
    var s = row.get_node("HSlider")
    s.min_value = min_v
    s.max_value = max_v
    s.step = 0.01 
    s.value = init
    s.value_changed.connect(cb)
    parent.add_child(row)
    row.set_meta("filter", lbl)
    _apply_style(row)
    return row

func _make_color(lbl: String, init: Color, cb: Callable, parent = act_list):
    var row = _get_template("Color")
    row.get_node("Label").text = lbl + ":"
    var btn = row.get_node("ColorPickerButton")
    btn.color = init
    btn.color_changed.connect(cb)
    parent.add_child(row)
    row.set_meta("filter", lbl)
    _apply_style(row)
    return row

func _update_watches():
    for w in _watches:
        w.node.text = str(w.getter.call())

func _safe_call(cb: Callable, req: bool) -> Callable:
    return func(arg = null):
        if req:
            var g = get_node_or_null("/root/Global")
            if not g or not is_instance_valid(g.game):
                log_message("Error: Game required.", Color.RED)
                return
        if cb.get_argument_count() > 0 and arg != null:
            cb.call(arg)
        else:
            cb.call()

func _bind_signals():
    term_input.text_submitted.connect(_on_term_submit)
    term_input.text_changed.connect(_on_term_change)
    term_input.gui_input.connect(_on_term_gui)
    term_list.item_selected.connect(_on_sugg_select)
    term_search.text_changed.connect(_on_hist_search)
    act_search.text_changed.connect(_on_act_search)
    insp_search.text_changed.connect(_on_insp_search)
    $ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView/InspectorControls/RefreshBtn.pressed.connect(_update_tree)
    insp_tree.item_activated.connect(_toggle_vis)
    insp_tree.item_selected.connect(_on_insp_select)
    var tog = get_node_or_null("ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView/Details/DetailsVBox/InspectorActions/ToggleVisible")
    if tog: tog.pressed.connect(_toggle_vis)
    var free = get_node_or_null("ConsoleWindow/WindowMargin/MainVBox/ContentContainer/InspectorView/Details/DetailsVBox/InspectorActions/FreeNode")
    if free: free.pressed.connect(_free_node)
    header.gui_input.connect(_on_head_input)
    if close_btn: close_btn.pressed.connect(toggle)
    monitor.gui_input.connect(_on_mon_input)
    tabs["term"].pressed.connect(_tab.bind("term"))
    tabs["act"].pressed.connect(_tab.bind("act"))
    tabs["insp"].pressed.connect(_tab.bind("insp"))
    tabs["sett"].pressed.connect(_tab.bind("sett"))
    for n in $ConsoleWindow/ResizeHandles.get_children():
        var d = _resize_dir(n.name)
        n.gui_input.connect(_on_resize_input.bind(d))

func _tab(name: String):
    for k in views: views[k].visible = (k == name)
    for k in tabs: tabs[k].button_pressed = (k == name)
    if name == "term": term_input.grab_focus()
    if name == "insp": _update_tree()

func _load_cfg():
    if config.load(CONFIG_PATH) == OK:
        if config.has_section("aliases"):
            for k in config.get_section_keys("aliases"): aliases[k] = config.get_value("aliases", k)
        font_size = config.get_value("settings", "font_size", 16)
        pause_mode = config.get_value("settings", "pause_on_open", true)
        bool_fmt = config.get_value("settings", "bool_preference", BoolDisplay.TRUE_FALSE)
        bg_color = config.get_value("visuals", "bg_color", bg_color)
        border_color = config.get_value("visuals", "border_color", border_color)
        border_width = config.get_value("visuals", "border_width", border_width)
        radius = config.get_value("visuals", "corner_radius", radius)
        toggle_keys = config.get_value("settings", "toggle_keys", [KEY_QUOTELEFT])
        for k in metrics: metrics[k] = config.get_value("perf_metrics", k, metrics[k])
        window.size = config.get_value("settings", "window_size", DEFAULT_SIZE)
        window.position = config.get_value("settings", "window_position", Vector2(50, 50))
        window.modulate.a = config.get_value("settings", "alpha", 1.0)
        monitor.visible = config.get_value("perf", "visible", false)
        monitor.position = config.get_value("perf", "position", Vector2(10, 10))
        monitor.horizontal_alignment = config.get_value("perf", "alignment", 0)

func _save_cfg():
    config.set_value("settings", "font_size", font_size)
    config.set_value("settings", "pause_on_open", pause_mode)
    config.set_value("settings", "bool_preference", bool_fmt)
    config.set_value("settings", "window_size", window.size)
    config.set_value("settings", "window_position", window.position)
    config.set_value("settings", "alpha", window.modulate.a)
    config.set_value("settings", "toggle_keys", toggle_keys)
    config.set_value("visuals", "bg_color", bg_color)
    config.set_value("visuals", "border_color", border_color)
    config.set_value("visuals", "border_width", border_width)
    config.set_value("visuals", "corner_radius", radius)
    for k in metrics: config.set_value("perf_metrics", k, metrics[k])
    config.set_value("perf", "visible", monitor.visible)
    config.set_value("perf", "position", monitor.position)
    config.set_value("perf", "alignment", monitor.horizontal_alignment)
    config.save(CONFIG_PATH)

func _style_win():
    style_win.bg_color = bg_color
    style_win.border_color = border_color
    for i in 4: style_win.set_border_width(i, border_width); style_win.set_corner_radius(i, radius)
    style_head.bg_color = bg_color.lightened(0.1)
    style_head.set_corner_radius(CORNER_TOP_LEFT, radius)
    style_head.set_corner_radius(CORNER_TOP_RIGHT, radius)
    margin.add_theme_constant_override("margin_left", border_width)
    margin.add_theme_constant_override("margin_right", border_width)
    margin.add_theme_constant_override("margin_top", border_width)
    margin.add_theme_constant_override("margin_bottom", border_width)

func _update_fonts():
    theme_res.default_font_size = font_size
    for p in ["normal_font_size", "bold_font_size", "italics_font_size", "mono_font_size"]: term_log.add_theme_font_size_override(p, font_size)
    insp_tree.add_theme_font_size_override("font_size", font_size)
    insp_tree.add_theme_font_size_override("title_button_font_size", font_size)
    _apply_style(act_list); _apply_style(sett_list); _apply_style(views["insp"])

func _apply_style(n: Node):
    if n is Control:
        n.add_theme_font_size_override("font_size", font_size)
        if n is Tree: n.add_theme_font_size_override("title_button_font_size", font_size)
        if not (n is LineEdit or n is ItemList or n is Tree):
            n.focus_mode = Control.FOCUS_NONE
    for c in n.get_children(): _apply_style(c)

func _init_cmds():
    register_command("clear", func(_a): term_log.clear(); _full_log.clear(), "Clears history.")
    register_command("help", _cmd_help, "Shows help.")
    register_command("quit", func(_a): get_tree().quit(), "Quits game.")
    register_command("alias", _cmd_alias, "Manage aliases.", _alias_opts)
    register_command("tilde_pause", func(a): _cmd_bool(a, "pause_mode"), "Toggle pause.", _bool_opts)
    register_command("tilde_perf", func(a): _cmd_bool(a, "monitor", "visible"), "Toggle perf.", _bool_opts)
    register_command("tilde_alpha", _cmd_alpha, "Set alpha.")
    register_command("tilde_timescale", func(a):
        if a.size() > 0: Engine.time_scale = str(a[0]).to_float()
        log_message("Time Scale: %.2f" % Engine.time_scale)
    , "Set speed.")
    register_command("tilde_reset_config", _cmd_reset, "Factory reset.")

func _cmd_alpha(a):
    if a.size() > 0:
        var v = str(a[0]).to_float()
        window.modulate.a = clamp(v, 0.1, 1.0)
        _save_cfg()
    log_message("Alpha: %.2f" % window.modulate.a)

func _cmd_help(_a):
    var txt = "[color=green]--- Commands ---[/color]\n"
    var keys = cmds.keys()
    keys.sort()
    for k in keys: txt += "[b]%s[/b]: %s\n" % [k, cmds[k]["desc"]]
    log_message(txt.strip_edges())

func _cmd_alias(args):
    if args.size() == 0: return
    var sub = args[0].to_lower()
    if sub == "list":
        for k in aliases: log_message("%s: %s" % [k, aliases[k]])
    elif sub in ["rm", "remove", "delete"]:
        if args.size() > 1:
            var t = args[1]; aliases.erase(t)
            if config.has_section("aliases"): config.erase_section_section_key("aliases", t)
            _save_cfg(); log_message("Removed: " + t)
    elif args.size() > 1:
        aliases[sub] = " ".join(args.slice(1))
        config.set_value("aliases", sub, aliases[sub])
        _save_cfg(); log_message("Alias '%s' created." % sub)

func _alias_opts(args):
    if args.size() == 0: return ["list", "rm"]
    if args[0] in ["rm", "remove"]: return aliases.keys()
    return []

func _cmd_reset(_args):
    if not _reset_pending:
        _reset_pending = true; _reset_timer = 5.0
        log_message("WARNING: Type again to confirm factory reset.", Color.YELLOW)
    else: _do_reset()

func _do_reset():
    var dir = DirAccess.open("user://")
    if dir.file_exists("tilde.cfg"): dir.remove("tilde.cfg")
    font_size = 16; pause_mode = true; bool_fmt = BoolDisplay.TRUE_FALSE
    window.size = DEFAULT_SIZE; window.position = Vector2(50, 50)
    window.modulate.a = 1.0; monitor.visible = false; aliases.clear()
    toggle_keys = [KEY_QUOTELEFT]
    _reset_pending = false; config = ConfigFile.new()
    _style_win(); _update_fonts()
    for c in sett_list.get_children(): c.queue_free()
    _build_settings(); log_message("Reset Complete.", Color.GREEN)

func _cmd_bool(args, obj_name, prop = ""):
    var var_name = obj_name
    if args.size() > 0:
        var v = _parse_bool(args[0])
        if v != null: 
            if prop != "": get(obj_name).set(prop, v)
            else: set(var_name, v)
            _save_cfg()
    
    var cur = get(obj_name).get(prop) if prop != "" else get(var_name)
    var stat = ""
    match bool_fmt:
        BoolDisplay.ON_OFF: stat = "ON" if cur else "OFF"
        BoolDisplay.YES_NO: stat = "YES" if cur else "NO"
        BoolDisplay.ONE_ZERO: stat = "1" if cur else "0"
        _: stat = "TRUE" if cur else "FALSE"
        
    var lbl = var_name if prop == "" else prop
    log_message("%s: %s" % [lbl.capitalize().replace(" ", " "), stat])

func _refresh_settings_ui():
    var scroll = views["sett"].scroll_vertical
    for c in sett_list.get_children(): c.queue_free()
    _build_settings()
    await get_tree().process_frame
    views["sett"].scroll_vertical = scroll

func _build_settings():
    var _head = func(t):
        var l = Label.new(); l.text = "--- " + t + " ---"
        l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        sett_list.add_child(l); _apply_style(l)
    
    _head.call("General")
    _make_slider("Transparency", 0.1, 1.0, func(v): 
        window.modulate.a = v; _save_cfg()
    , window.modulate.a, sett_list)
    
    _make_slider("Font Size", 8, 48, func(v): 
        font_size = int(v); _update_fonts(); _save_cfg()
    , font_size, sett_list)
    
    var r_spd = _make_input("Game Speed", "Set", func(v): 
        Engine.time_scale = str(v).to_float()
    , false, sett_list)
    r_spd.get_node("LineEdit").text = str(Engine.time_scale)
    
    var r_bool = _make_menu("Bool Style", ["true/false", "on/off", "1/0", "yes/no"], func(idx): 
        bool_fmt = idx; _save_cfg()
    , "Set", false, sett_list)
    r_bool.get_node("OptionButton").selected = bool_fmt
    
    _make_toggle("Pause on Open", pause_mode, func(t): 
        pause_mode = t; _save_cfg()
    , "", sett_list)
    
    _make_toggle("Show Monitor", monitor.visible, func(t): 
        monitor.visible = t; _save_cfg()
    , "", sett_list)
    
    _head.call("Activation Keys")
    for i in range(3):
        var txt = "Empty"
        if i < toggle_keys.size():
            var k = toggle_keys[i]
            if k is int: txt = OS.get_keycode_string(k)
            elif k is String: txt = k
            elif k is InputEventKey: txt = OS.get_keycode_string(k.keycode)
        
        var msg = "Press any key..." if _bind_idx == i else txt
        
        var row = HBoxContainer.new()
        var lbl = Label.new()
        lbl.text = "Keybind " + str(i+1) + ":"
        lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        var btn = Button.new()
        btn.text = msg
        btn.toggle_mode = true
        btn.button_pressed = (_bind_idx == i)
        btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        btn.pressed.connect(func(): 
            _bind_idx = i
            _refresh_settings_ui()
        )
        var clr = Button.new()
        clr.text = "X"
        clr.pressed.connect(func():
            _remove_keybind_slot(i)
            _refresh_settings_ui()
        )
        
        row.add_child(lbl)
        row.add_child(btn)
        row.add_child(clr)
        sett_list.add_child(row)
        _apply_style(row)

    _head.call("Performance Monitor")
    for k in metrics:
        _make_toggle("Show " + k.capitalize(), metrics[k], func(t): 
            metrics[k] = t; _save_cfg()
        , "", sett_list)
        
    _head.call("Visual Styling")
    _make_color("Background", bg_color, func(c): 
        bg_color = c; _style_win(); _save_cfg()
    , sett_list)
    
    _make_color("Border", border_color, func(c): 
        border_color = c; _style_win(); _save_cfg()
    , sett_list)
    
    _make_slider("Corner Radius", 0, 50, func(v): 
        radius = int(v); _style_win(); _save_cfg()
    , radius, sett_list)

func _set_keybind_slot(idx: int, k):
    while toggle_keys.size() <= idx:
        toggle_keys.append(null)
        
    toggle_keys[idx] = k
    toggle_keys = toggle_keys.filter(func(x): return x != null)
    _save_cfg()

func _remove_keybind_slot(idx: int):
    if idx < toggle_keys.size():
        toggle_keys.remove_at(idx)
        _save_cfg()

func _on_insp_search(text): _update_tree()

func _on_hist_search(text):
    term_log.clear()
    var q = text.to_lower()
    for e in _full_log:
        if q.is_empty() or q in e.text.to_lower(): _log_append(e.text, e.color)

func _on_act_search(text):
    for c in act_list.get_children():
        if c == _watch_box: continue
        if c is Control:
            var content = ""
            if c.get("text"): content += c.text
            if c.has_meta("filter"): content += c.get_meta("filter")
            for child in c.get_children(): if child is Label: content += child.text
            c.visible = text.is_empty() or text.to_lower() in content.to_lower()

func _update_tree():
    insp_tree.clear(); var root = insp_tree.create_item()
    _build_tree(get_tree().root, root, insp_search.text.to_lower())

func _build_tree(n: Node, item: TreeItem, filter: String):
    var matches = filter == "" or filter in n.name.to_lower() or filter in n.get_class().to_lower()
    if matches:
        item.set_text(0, n.name + " (" + n.get_class() + ")")
        item.set_metadata(0, n)
        if "visible" in n: item.set_custom_color(0, Color.WHITE if n.visible else Color.GRAY)
    for c in n.get_children():
        if c == self: continue 
        _build_tree(c, item.create_child(), filter)
        if filter != "" and matches: item.set_collapsed(false)

func _on_insp_select():
    var item = insp_tree.get_selected()
    if item: sel_node = item.get_metadata(0); _update_details()

func _update_details():
    if not is_instance_valid(sel_node): insp_info.text = "Select a node"; return
    var t = "Name: %s\nClass: %s\nID: %s" % [sel_node.name, sel_node.get_class(), sel_node.get_instance_id()]
    if "position" in sel_node: t += "\nPos: " + str(sel_node.position)
    if "global_position" in sel_node: t += "\nGlobal: " + str(sel_node.global_position)
    insp_info.text = t

func _toggle_vis():
    if is_instance_valid(sel_node) and "visible" in sel_node: sel_node.visible = !sel_node.visible; _update_tree()

func _free_node():
    if is_instance_valid(sel_node): sel_node.queue_free(); sel_node = null; await get_tree().process_frame; _update_tree()

func _update_monitor():
    var t = ""
    if metrics["fps"]: t += "FPS: %d\n" % Performance.get_monitor(Performance.TIME_FPS)
    if metrics["ram"]: t += "RAM: %.1f MB\n" % (Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
    if metrics["vram"]: t += "VRAM: %.1f MB\n" % (Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)
    if metrics["nodes"]: t += "Nodes: %d\n" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
    if metrics["draws"]: t += "Draws: %d\n" % Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
    monitor.text = t.strip_edges(); monitor.size = Vector2.ZERO 

func _on_head_input(ev):
    if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
        dragging = ev.pressed; drag_off = window.global_position - get_viewport().get_mouse_position()

func _handle_drag():
    var m = get_viewport().get_mouse_position(); var v = get_viewport().get_visible_rect().size; var t = m + drag_off
    window.global_position = Vector2(clamp(t.x, 0, v.x - window.size.x), clamp(t.y, 0, v.y - window.size.y))

func _on_resize_input(ev, dir):
    if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
        resize_dir = dir if ev.pressed else 0; resize_start = get_viewport().get_mouse_position(); resize_rect = Rect2(window.global_position, window.size)

func _handle_resize():
    var m = get_viewport().get_mouse_position(); var d = m - resize_start; var r = resize_rect
    var nr = r
    if resize_dir in [3, 5, 7]: var diff = min(d.x, r.size.x - MIN_SIZE.x); nr.position.x += diff; nr.size.x -= diff
    elif resize_dir in [4, 6, 8]: nr.size.x = max(r.size.x + d.x, MIN_SIZE.x)
    if resize_dir in [1, 5, 6]: var diff = min(d.y, r.size.y - MIN_SIZE.y); nr.position.y += diff; nr.size.y -= diff
    elif resize_dir in [2, 7, 8]: nr.size.y = max(r.size.y + d.y, MIN_SIZE.y)
    window.global_position = nr.position; window.size = nr.size

func _resize_dir(n: String) -> int:
    if "TL" in n: return 5; if "TR" in n: return 6; if "BL" in n: return 7; if "BR" in n: return 8
    if "Top" in n: return 1; if "Bottom" in n: return 2; if "Left" in n: return 3; if "Right" in n: return 4
    return 0

func _on_mon_input(ev):
    if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
        if ev.pressed:
            if is_open: 
                mon_drag = false 
                mon_start = get_viewport().get_mouse_position()
                mon_off = monitor.position - mon_start
        else:
            if is_open:
                var end = get_viewport().get_mouse_position()
                if not mon_drag or end.distance_to(mon_start) < 5:
                    _next_perf_align()
                mon_drag = false
                _save_cfg()
    
    if ev is InputEventMouseMotion and is_open:
        if ev.button_mask & MOUSE_BUTTON_MASK_LEFT:
            var m = get_viewport().get_mouse_position()
            if not mon_drag and m.distance_to(mon_start) > 5:
                mon_drag = true
            
            if mon_drag:
                var t = m + mon_off
                var v = get_viewport().get_visible_rect().size
                var p = monitor.size
                t.x = clamp(t.x, 0, v.x - p.x)
                t.y = clamp(t.y, 0, v.y - p.y)
                monitor.position = t

func _next_perf_align():
    monitor.horizontal_alignment = (monitor.horizontal_alignment + 1) % 3

func _on_term_change(text):
    if text.is_empty():
        term_list.visible = false
        return
        
    var suggs = []
    var p = text.split(" ", false)
    
    if not " " in text:
        var q = text.to_lower()
        for c in cmds.keys():
            if c.to_lower().begins_with(q): suggs.append(c)
        for a in aliases:
            if a.to_lower().begins_with(q): suggs.append(a)
    else:
        var cmd = p[0]
        var q = ""
        var args = p.slice(1)
        if text.ends_with(" "): q = ""
        elif not args.is_empty():
            q = args[-1].to_lower()
            args = args.slice(0, -1)
            
        var t_cmd = cmd
        if aliases.has(cmd): t_cmd = aliases[cmd].split(" ", false)[0]
            
        if cmds.has(t_cmd) and cmds[t_cmd]["comp"]:
            var opts = cmds[t_cmd]["comp"].call(args)
            if opts:
                for o in opts:
                    if str(o).to_lower().begins_with(q): suggs.append(str(o))

    _show_suggestions(suggs)

func _show_suggestions(list):
    term_list.clear()
    if list.is_empty():
        term_list.visible = false
    else:
        term_list.visible = true
        for s in list:
            term_list.add_item(s)
        term_list.select(0)
        var h = min(list.size() * (font_size + 8) * 2, 200)
        term_list.custom_minimum_size.y = h

func _on_term_submit(text):
    term_list.visible = false
    var clean = text.strip_edges()
    
    term_input.clear() 
    
    if clean == "":
        term_input.call_deferred("grab_focus")
        return
        
    log_message("> " + clean, Color.LIGHT_GRAY)
    history.append(clean)
    history_idx = history.size()
    
    process_command(clean)
    term_input.call_deferred("grab_focus")

func _on_sugg_select(idx):
    var s = term_list.get_item_text(idx)
    var t = term_input.text
    
    if not " " in t:
        term_input.text = s + " "
    else:
        if t.ends_with(" "):
            term_input.text += s + " "
        else:
            var last = t.rfind(" ")
            term_input.text = t.left(last + 1) + s + " "
            
    term_input.caret_column = term_input.text.length()
    term_input.grab_focus()
    term_list.visible = false
    _on_term_change(term_input.text)

func _on_term_gui(event):
    if term_list.visible and event is InputEventKey and event.pressed:
        if event.keycode == KEY_DOWN:
            var idx = (term_list.get_selected_items()[0] + 1) % term_list.item_count
            term_list.select(idx); term_list.ensure_current_is_visible(); get_viewport().set_input_as_handled()
        elif event.keycode == KEY_UP:
            var idx = max(0, term_list.get_selected_items()[0] - 1)
            term_list.select(idx); term_list.ensure_current_is_visible(); get_viewport().set_input_as_handled()
        elif event.keycode == KEY_TAB:
            _on_sugg_select(term_list.get_selected_items()[0]); get_viewport().set_input_as_handled()
    elif event is InputEventKey and event.pressed:
        if event.keycode == KEY_UP:
            if history_idx > 0: history_idx -= 1; term_input.text = history[history_idx]; term_input.caret_column = term_input.text.length()
            get_viewport().set_input_as_handled()
        elif event.keycode == KEY_DOWN:
            if history_idx < history.size() - 1: history_idx += 1; term_input.text = history[history_idx]; term_input.caret_column = term_input.text.length()
            else: history_idx = history.size(); term_input.clear()
            get_viewport().set_input_as_handled()

func _parse_bool(s: String):
    var l = s.to_lower()
    if l in ["true", "1", "yes", "on", "t"]: return true
    if l in ["false", "0", "no", "off", "f"]: return false
    return null

func _bool_opts(args):
    if args.size() > 0: return []
    match bool_fmt:
        BoolDisplay.ON_OFF: return ["on", "off"]
        BoolDisplay.YES_NO: return ["yes", "no"]
        BoolDisplay.ONE_ZERO: return ["1", "0"]
        _: return ["true", "false"]
