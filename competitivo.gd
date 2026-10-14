extends Node2D

# --- Configuração do Grid e Mapa ---
@export var tamanho_celula: int = 32
@export var colunas: int = 30
@export var linhas: int = 20
@onready var label_painel: Label = $Label 

@export var velocidade_veiculo: float = 300.0

var pontos_grid: Array[Vector2i] = []
var obstaculos: Array[Vector2i] = []
var celulas_com_lama: Array[Vector2i] = [] 

var posicoes_grid_veiculos: Array[Vector2i] = []
var posicoes_suavizadas: Array[Vector2] = []
var alvos_atuais_veiculos: Array[int] = [] 
var clientes_coletados: Dictionary = {} 

var tempo_penalidade_lama: Array[float] = [0.0, 0.0]
var cores_veiculos = [Color.RED, Color.PURPLE]
var pontuacoes: Array[int] = [0, 0]

var ja_spawnou_extras: bool = false
var rng = RandomNumberGenerator.new()

func _ready() -> void:
	randomize()
	rng.randomize()
	iniciar_nova_iteracao_completa()

func _process(delta: float) -> void:
	atualizar_movimento_veiculos(delta)
	verificar_coleta_clientes()
	atualizar_texto_ui()
	queue_redraw()

func iniciar_nova_iteracao_completa() -> void:
	ja_spawnou_extras = false
	gerar_obstaculos_e_lama_aleatorios()
	inicializar_jogo()

func gerar_obstaculos_e_lama_aleatorios() -> void:
	obstaculos.clear()
	pontos_grid.clear()
	celulas_com_lama.clear()
	
	pontos_grid.append(Vector2i(2, 2))     # [0] Base V1 (Vermelho - Expectiminimax)
	pontos_grid.append(Vector2i(27, 17))   # [1] Base V2 (Roxo - Minimax Puro)
	
	var tipo_layout = rng.randi_range(1, 3)
	if tipo_layout == 1:
		for y in range(3, 17):
			obstaculos.append(Vector2i(9, y))
			obstaculos.append(Vector2i(21, y))
		for x in range(12, 19):
			obstaculos.append(Vector2i(x, 10))
	elif tipo_layout == 2:
		for x in range(5, 25):
			obstaculos.append(Vector2i(x, 6))
			obstaculos.append(Vector2i(x, 13))
	else:
		for i in range(15):
			var ox = rng.randi_range(5, colunas - 6)
			var oy = rng.randi_range(4, linhas - 5)
			obstaculos.append(Vector2i(ox, oy))
			obstaculos.append(Vector2i(ox + 1, oy))

	var num_clientes_iniciais = 15
	var total_alvos = 2 + num_clientes_iniciais

	while pontos_grid.size() < total_alvos:
		var rx = rng.randi_range(2, colunas - 3)
		var ry = rng.randi_range(3, linhas - 3)
		var pos_candidata = Vector2i(rx, ry)
		
		var valido = true
		if pos_candidata in obstaculos:
			valido = false
		for p in pontos_grid:
			if p == pos_candidata or abs(p.x - rx) + abs(p.y - ry) < 3:
				valido = false
				break
				
		if valido:
			pontos_grid.append(pos_candidata)

	# Proporção densa de lama (~28% do mapa livre)
	for x in range(colunas):
		for y in range(linhas):
			var cel = Vector2i(x, y)
			if not (cel in obstaculos) and not (cel in pontos_grid):
				if rng.randf() < 0.28:
					celulas_com_lama.append(cel)

func inicializar_jogo() -> void:
	clientes_coletados.clear()
	tempo_penalidade_lama = [0.0, 0.0]
	
	posicoes_grid_veiculos = [pontos_grid[0], pontos_grid[1]] 
	posicoes_suavizadas.clear()
	alvos_atuais_veiculos.clear()
	
	for v in range(2):
		posicoes_suavizadas.append(Vector2(posicoes_grid_veiculos[v]) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2))
		alvos_atuais_veiculos.append(escolher_proximo_cliente(v))
		
	if not has_node("TimerSpawnExtra"):
		var t_spawn = Timer.new()
		t_spawn.name = "TimerSpawnExtra"
		t_spawn.wait_time = 5.0
		t_spawn.one_shot = true
		t_spawn.timeout.connect(_spawnar_clientes_extras_em_jogo)
		add_child(t_spawn)
		t_spawn.start()

func _spawnar_clientes_extras_em_jogo() -> void:
	if ja_spawnou_extras:
		return
	ja_spawnou_extras = true
	
	var quantidade_extras = rng.randi_range(5, 10)
	var adicionados = 0
	while adicionados < quantidade_extras:
		var rx = rng.randi_range(2, colunas - 3)
		var ry = rng.randi_range(3, linhas - 3)
		var pos_candidata = Vector2i(rx, ry)
		
		var valido = true
		if pos_candidata in obstaculos:
			valido = false
		for p in pontos_grid:
			if p == pos_candidata:
				valido = false
				break
				
		if valido:
			pontos_grid.append(pos_candidata)
			adicionados += 1
			
	for j in range(2):
		alvos_atuais_veiculos[j] = escolher_proximo_cliente(j)


func escolher_proximo_cliente(id_veiculo: int) -> int:
	var clientes_disponiveis = []
	for i in range(2, pontos_grid.size()):
		if not clientes_coletados.has(i):
			clientes_disponiveis.append(i)
			
	if clientes_disponiveis.is_empty():
		return id_veiculo 
		

	if id_veiculo == 0:
		var pos_vermelho = posicoes_grid_veiculos[0]
		var pos_roxo = posicoes_grid_veiculos[1]
		
		var lista_ordenada_roxo = []
		for c_idx in clientes_disponiveis:
			var cam = encontrar_caminho_grid(pos_roxo, pontos_grid[c_idx])
			var dist = calcular_custo_com_expectativa_clima(cam)
			lista_ordenada_roxo.append({"id": c_idx, "dist": dist})
		
		lista_ordenada_roxo.sort_custom(func(a, b): return a.dist < b.dist)
		var primeiro_mais_perto_roxo = lista_ordenada_roxo[0]["id"] if lista_ordenada_roxo.size() > 0 else -1
		var segundo_mais_perto_roxo = lista_ordenada_roxo[1]["id"] if lista_ordenada_roxo.size() > 1 else primeiro_mais_perto_roxo
		var menor_dist_roxo = lista_ordenada_roxo[0]["dist"] if lista_ordenada_roxo.size() > 0 else INF

		var melhor_cliente = clientes_disponiveis[0]
		var melhor_valor_max = -INF
		
		for c_vermelho in clientes_disponiveis:
			var cam_v = encontrar_caminho_grid(pos_vermelho, pontos_grid[c_vermelho])
			var custo_v = calcular_custo_com_expectativa_clima(cam_v)
			var utilidade_estado = -custo_v
			
			if c_vermelho == primeiro_mais_perto_roxo:
				var custo_v_ate_alvo = custo_v
				if menor_dist_roxo < custo_v_ate_alvo:
					var dist_roxo_ao_alvo = menor_dist_roxo
					var cam_alvo_segundo = encontrar_caminho_grid(pontos_grid[primeiro_mais_perto_roxo], pontos_grid[segundo_mais_perto_roxo])
					var dist_alvo_ao_segundo = calcular_custo_com_expectativa_clima(cam_alvo_segundo)
					var cam_v_segundo = encontrar_caminho_grid(pos_vermelho, pontos_grid[segundo_mais_perto_roxo])
					var dist_v_ao_segundo = calcular_custo_com_expectativa_clima(cam_v_segundo)
					
					if (dist_roxo_ao_alvo + dist_alvo_ao_segundo) < dist_v_ao_segundo:
						utilidade_estado -= 8000.0
					else:
						utilidade_estado -= 3000.0
				else:
					utilidade_estado += 500.0

			if utilidade_estado > melhor_valor_max:
				melhor_valor_max = utilidade_estado
				melhor_cliente = c_vermelho
				
		return melhor_cliente
		
	
	else:
		var pos_roxo = posicoes_grid_veiculos[1]
		var melhor_cliente = clientes_disponiveis[0]
		var menor_dist = INF
		for c_idx in clientes_disponiveis:
			var caminho = encontrar_caminho_grid(pos_roxo, pontos_grid[c_idx])
			var dist = float(caminho.size()) 
			if dist < menor_dist and caminho.size() > 0:
				menor_dist = dist
				melhor_cliente = c_idx
		return melhor_cliente


func calcular_custo_com_expectativa_clima(caminho: Array[Vector2i]) -> float:
	if caminho.is_empty():
		return 9999.0
	var custo_base = float(caminho.size())
	var custo_lama_esperado = 0.0
	
	var probabilidade_atolar = 0.4
	var penalidade_atraso = 3.0
	
	for cel in caminho:
		if cel in celulas_com_lama:
			custo_lama_esperado += (probabilidade_atolar * penalidade_atraso)
			
	return custo_base + custo_lama_esperado

func eh_transponivel(celula: Vector2i) -> bool:
	if celula.x < 0 or celula.x >= colunas or celula.y < 0 or celula.y >= linhas:
		return false
	return not (celula in obstaculos)

func encontrar_caminho_grid(inicio: Vector2i, objetivo: Vector2i) -> Array[Vector2i]:
	var abertos: Array[Vector2i] = [inicio]
	var veio_de: Dictionary = {}
	var g_score: Dictionary = {inicio: 0.0}
	var f_score: Dictionary = {inicio: 0.0}
	
	f_score[inicio] = abs(inicio.x - objetivo.x) + abs(inicio.y - objetivo.y)
	var fechados: Array[Vector2i] = []
	var movimentos = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]

	while abertos.size() > 0:
		var atual = abertos[0]
		var menor_f = f_score.get(atual, INF)
		for node in abertos:
			if f_score.get(node, INF) < menor_f:
				menor_f = f_score.get(node, INF)
				atual = node

		if atual == objetivo:
			return reconstruir_caminho(veio_de, atual)

		abertos.erase(atual)
		fechados.append(atual)

		for dir in movimentos:
			var vizinho = atual + dir
			if not eh_transponivel(vizinho) or vizinho in fechados:
				continue
			
			var custo_passo = 1.0 + (0.4 * 3.0) if (vizinho in celulas_com_lama) else 1.0
			var custo_tentativo = g_score.get(atual, INF) + custo_passo
			
			if not vizinho in abertos:
				abertos.append(vizinho)
			elif custo_tentativo >= g_score.get(vizinho, INF):
				continue

			veio_de[vizinho] = atual
			g_score[vizinho] = custo_tentativo
			var h = abs(vizinho.x - objetivo.x) + abs(vizinho.y - objetivo.y)
			f_score[vizinho] = custo_tentativo + h

	return []

func reconstruir_caminho(veio_de: Dictionary, atual: Vector2i) -> Array[Vector2i]:
	var caminho: Array[Vector2i] = [atual]
	while veio_de.has(atual):
		atual = veio_de[atual]
		caminho.push_front(atual)
	return caminho

func atualizar_movimento_veiculos(delta: float) -> void:
	for v in range(2):
		if tempo_penalidade_lama[v] > 0.0:
			tempo_penalidade_lama[v] -= delta
			continue

		var cliente_alvo_idx = alvos_atuais_veiculos[v]
		if cliente_alvo_idx >= pontos_grid.size():
			continue
			
		var destino_cel = pontos_grid[cliente_alvo_idx]
		if posicoes_grid_veiculos[v] == destino_cel:
			continue
			
		var caminho = encontrar_caminho_grid(posicoes_grid_veiculos[v], destino_cel)
		if caminho.size() > 1:
			var proxima_celula = caminho[1]
			var pos_alvo_px = Vector2(proxima_celula) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
			
			posicoes_suavizadas[v] = posicoes_suavizadas[v].move_toward(pos_alvo_px, velocidade_veiculo * delta)
			
			if posicoes_suavizadas[v].distance_to(pos_alvo_px) < 1.0:
				posicoes_grid_veiculos[v] = proxima_celula
				
				# Teste estocástico de atolamento na lama (40% de chance)
				if posicoes_grid_veiculos[v] in celulas_com_lama:
					if rng.randf() < 0.4:
						tempo_penalidade_lama[v] = 1.0 

func verificar_coleta_clientes() -> void:
	for v in range(2):
		for i in range(2, pontos_grid.size()):
			if posicoes_grid_veiculos[v] == pontos_grid[i] and not clientes_coletados.has(i):
				clientes_coletados[i] = v
				pontuacoes[v] += 1
				
				for j in range(2):
					alvos_atuais_veiculos[j] = escolher_proximo_cliente(j)
				
	if clientes_coletados.size() >= pontos_grid.size() - 2:
		if not has_node("TimerReinicio"):
			var t = Timer.new()
			t.name = "TimerReinicio"
			t.wait_time = 1.5
			t.one_shot = true
			t.timeout.connect(func():
				iniciar_nova_iteracao_completa()
				t.queue_free()
			)
			add_child(t)
			t.start()

func atualizar_texto_ui() -> void:
	if not label_painel:
		return
		
	var total_atual = pontos_grid.size() - 2
	var restantes = total_atual - clientes_coletados.size()
	
	var texto = "Expectminimax vs Minimax\n"
	texto += "Clientes Restantes: " + str(restantes) + " / " + str(total_atual) + "\n\n"
	texto += "V1 Vermelho (Expectiminimax): " + str(pontuacoes[0]) + (" [ATOLADO]" if tempo_penalidade_lama[0] > 0.0 else "") + "\n"
	texto += "V2 Roxo (Minimax): " + str(pontuacoes[1]) + (" [ATOLADO]" if tempo_penalidade_lama[1] > 0.0 else "") + "\n"
	
	label_painel.text = texto

func _draw() -> void:
	for x in range(colunas + 1):
		draw_line(Vector2(x * tamanho_celula, 0), Vector2(x * tamanho_celula, linhas * tamanho_celula), Color(0.12, 0.12, 0.12, 0.4))
	for y in range(linhas + 1):
		draw_line(Vector2(0, y * tamanho_celula), Vector2(colunas * tamanho_celula, y * tamanho_celula), Color(0.12, 0.12, 0.12, 0.4))

	for obs in obstaculos:
		draw_rect(Rect2(Vector2(obs) * tamanho_celula, Vector2(tamanho_celula, tamanho_celula)), Color.DARK_SLATE_GRAY, true)

	for lama in celulas_com_lama:
		draw_rect(Rect2(Vector2(lama) * tamanho_celula + Vector2(4,4), Vector2(tamanho_celula-8, tamanho_celula-8)), Color(0.4, 0.25, 0.1, 0.7), true)

	for v in range(2):
		var alvo_idx = alvos_atuais_veiculos[v]
		if alvo_idx < pontos_grid.size():
			var destino_cel = pontos_grid[alvo_idx]
			var caminho_atual = encontrar_caminho_grid(posicoes_grid_veiculos[v], destino_cel)
			var cor_cota = cores_veiculos[v]
			
			for i in range(caminho_atual.size() - 1):
				var p1 = Vector2(caminho_atual[i]) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
				var p2 = Vector2(caminho_atual[i+1]) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
				draw_line(p1, p2, Color(cor_cota.r, cor_cota.g, cor_cota.b, 0.5), 3.5, true)

	for i in range(pontos_grid.size()):
		var p_px = Vector2(pontos_grid[i]) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
		if i == 0:
			draw_circle(p_px, 11.0, Color.RED)
			draw_string(ThemeDB.fallback_font, p_px + Vector2(-22, -14), "Base V1", HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color.WHITE)
		elif i == 1:
			draw_circle(p_px, 11.0, Color.PURPLE)
			draw_string(ThemeDB.fallback_font, p_px + Vector2(-22, -14), "Base V2", HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color.WHITE)
		else:
			var cor = Color.WHITE
			if clientes_coletados.has(i):
				cor = Color.DIM_GRAY
			draw_circle(p_px, 8.0, cor)
			draw_string(ThemeDB.fallback_font, p_px + Vector2(-10, -11), "C" + str(i), HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color.LIGHT_GRAY)

	for v in range(2):
		var pos_v = posicoes_suavizadas[v]
		var cor = cores_veiculos[v]
		draw_rect(Rect2(pos_v - Vector2(8, 8), Vector2(16, 16)), cor, true)
		
		var nome_ia = "Expectiminimax" if v == 0 else "Minimax Puro"
		var texto_tag = "V" + str(v+1) + " (" + nome_ia + ")"
		if tempo_penalidade_lama[v] > 0.0:
			texto_tag += " [ATOLADO]"
		draw_string(ThemeDB.fallback_font, pos_v + Vector2(-35, 24), texto_tag, HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color.WHITE)

func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://menu.tscn")
