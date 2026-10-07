extends AcceptDialog

func _ready():
	Manager.ui_aviso = self      # o Manager chama  Manager.aviso("texto")  ->  mostrar()

func mostrar(msg: String):
	self.dialog_text = msg
	self.popup_centered()
