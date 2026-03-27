extends AcceptDialog

func _ready():
	Manager.show_user_warning.connect(_on_show_warning)

func _on_show_warning(msg: String):
	self.dialog_text = msg
	self.popup_centered()
