extends Node
## Cliente HTTP assincrono com limite de concorrencia.
## Uso:   var r: Dictionary = await http.request_bytes(url)
##        r.ok (bool), r.code (int), r.body (PackedByteArray), r.error (String)

const USER_AGENT := "SAARIS-Simulator/1.0 (pesquisa academica UFRJ/GTA)"

var max_concurrent: int = 3
var _active: int = 0


func request_bytes(url: String, method: int = HTTPClient.METHOD_GET, extra_headers: PackedStringArray = PackedStringArray(), body: String = "", timeout_s: float = 60.0) -> Dictionary:
	while _active >= max_concurrent:
		await get_tree().process_frame
	_active += 1

	var req: HTTPRequest = HTTPRequest.new()
	req.timeout = timeout_s
	req.use_threads = true
	add_child(req)

	var headers: PackedStringArray = PackedStringArray(["User-Agent: " + USER_AGENT])
	headers.append_array(extra_headers)

	var err: int = req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		_active -= 1
		return {"ok": false, "code": 0, "error": "request() falhou (erro %d)" % err, "body": PackedByteArray()}

	var res: Array = await req.request_completed   # [result, response_code, headers, body]
	req.queue_free()
	_active -= 1

	var result: int = res[0]
	var code: int = res[1]
	var ok: bool = (result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300)
	var msg: String = ""
	if not ok:
		msg = "HTTP %d (resultado %d)" % [code, result]
	return {"ok": ok, "code": code, "error": msg, "body": res[3]}
