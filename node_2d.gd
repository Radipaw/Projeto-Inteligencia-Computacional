extends Node2D

# --- Configuração do Grid e Mapa ---
@export var tamanho_celula: int = 32
@export var colunas: int = 30
@export var linhas: int = 20
@onready var label_painel: Label = $Label 
@export var num_veiculos: int = 3
@export var peso_heuristic_w: float = 2.5 # Peso para o Weighted A*
@export var algoritmo_atual: String = "WeightedAStar" # "AStar", "Guloso", "WeightedAStar"
@export var velocidade_veiculo: float = 180.0

# Variável para controlar o mapa ativo (0, 1 ou 2)
var mapa_atual_id: int = 0

# Coordenadas em células do Grid dinâmicas por mapa
var pontos_grid: Array[Vector2i] = []
var obstaculos: Array[Vector2i] = []

var rotas_celulas: Array[Array] = [] 
var cliente_atribuido_a_veiculo: Dictionary = {} 
var clientes_visitados: Dictionary = {} 

# Métricas de eficiência de tamanho de caminho
var custos_rotas_veiculos: Array[int] = []
var custo_total_frota: int = 0

# Controle da Animação dos Caminhões
var posicoes_atuais_veiculos: Array[Vector2] = []
var indices_meta_rota: Array[int] = []
var progresso_trecho: Array[float] = []
var veiculo_aguardando: Array[bool] = [] 

var cores_veiculos = [Color.RED, Color.BLUE, Color.GREEN, Color.ORANGE, Color.PURPLE, Color.CYAN]

func _ready() -> void:
	carregar_mapa(mapa_atual_id)
	calcular_vrp()
	inicializar_animacao_veiculos()
	atualizar_texto_label()

func _process(delta: float) -> void:
	atualizar_movimento_veiculos(delta)
	verificar_sincronia_chegada()
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_A:
			alternar_algoritmo()
			calcular_vrp()
			inicializar_animacao_veiculos()
			atualizar_texto_label()
		elif event.keycode == KEY_S:
			alternar_mapa()
			calcular_vrp()
			inicializar_animacao_veiculos()
			atualizar_texto_label()

func alternar_algoritmo() -> void:
	if algoritmo_atual == "AStar":
		algoritmo_atual = "Guloso"
	elif algoritmo_atual == "Guloso":
		algoritmo_atual = "WeightedAStar"
	else:
		algoritmo_atual = "AStar"
	print("Algoritmo alterado para: ", algoritmo_atual)

func alternar_mapa() -> void:
	mapa_atual_id = (mapa_atual_id + 1) % 3
	carregar_mapa(mapa_atual_id)
	print("Mapa alterado para o ID: ", mapa_atual_id + 1)

# --- Gerenciamento dos 3 Mapas Diferentes ---
func carregar_mapa(id: int) -> void:
	obstaculos.clear()
	pontos_grid.clear()
	
	match id:
		0: # MAPA 1: Duas paredes centrais em cruz/barreiras
			pontos_grid = [
				Vector2i(2, 2),   # 0: Depósito
				Vector2i(27, 2),  # 1: Cliente 1
				Vector2i(27, 17), # 2: Cliente 2
				Vector2i(2, 17),  # 3: Cliente 3
				Vector2i(15, 10), # 4: Cliente 4 (centro)
				Vector2i(15, 2),  # 5: Cliente 5
				Vector2i(15, 17)  # 6: Cliente 6
			]
			for y in range(5, 15):
				obstaculos.append(Vector2i(10, y))
				obstaculos.append(Vector2i(20, y))
			for x in range(10, 21):
				obstaculos.append(Vector2i(x, 7))
				
		1: #MAPA 2: Obstáculos Aleatórios (Gera barreiras randômicas a cada troca/reset)
			pontos_grid = [
				Vector2i(15, 1),  # 0: Depósito
				Vector2i(2, 18),  # 1: Cliente 1
				Vector2i(28, 18), # 2: Cliente 2
				Vector2i(28, 2),  # 3: Cliente 3
				Vector2i(15, 10), # 4: Cliente 4
				Vector2i(5, 10),  # 5: Cliente 5
				Vector2i(25, 10)  # 6: Cliente 6
			]
			
			# Gera blocos/paredes aleatórias garantindo que não bloqueiem os pontos críticos
			var rng = RandomNumberGenerator.new()
			rng.randomize()
			
			# Criando um labirinto randômico de blocos
			for x in range(3, colunas - 3):
				for y in range(2, linhas - 2):
					# Evita colocar paredes em cima exata de depósitos/clientes ou muito perto
					var celula_atual = Vector2i(x, y)
					var muito_perto_de_ponto = false
					for p in pontos_grid:
						if abs(p.x - x) <= 1 and abs(p.y - y) <= 1:
							muito_perto_de_ponto = true
							break
					
					if not muito_perto_de_ponto:
						# Chance de 22% de virar obstáculo, criando aglomerações estilo labirinto
						if rng.randf() < 0.22:
							obstaculos.append(celula_atual)
				
		2: # MAPA 3: Ilhas espalhadas (múltiplos desvios obrigatórios)
			pontos_grid = [
				Vector2i(15, 10), # 0: Depósito (no centro)
				Vector2i(2, 2),   # 1: Cliente 1
				Vector2i(27, 2),  # 2: Cliente 2
				Vector2i(27, 17), # 3: Cliente 3
				Vector2i(2, 17),  # 4: Cliente 4
				Vector2i(15, 2),  # 5: Cliente 5
				Vector2i(15, 17)  # 6: Cliente 6
			]
			# Blocos de pilares (ilhas)
			var blocos = [Vector2i(7,5), Vector2i(7,6), Vector2i(22,5), Vector2i(22,6), 
						  Vector2i(7,13), Vector2i(7,14), Vector2i(22,13), Vector2i(22,14),
						  Vector2i(12,10), Vector2i(17,10)]
			for b in blocos:
				obstaculos.append(b)

func eh_transponivel(celula: Vector2i) -> bool:
	if celula.x < 0 or celula.x >= colunas or celula.y < 0 or celula.y >= linhas:
		return false
	return not (celula in obstaculos)

# --- Heurística de Manhattan ---
func heuristica(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

# --- Implementação do A* / Guloso / Weighted A* em Grid ---
func encontrar_caminho_grid(inicio: Vector2i, objetivo: Vector2i) -> Array[Vector2i]:
	var abertos: Array[Vector2i] = [inicio]
	var veio_de: Dictionary = {}
	
	var g_score: Dictionary = {inicio: 0.0}
	var f_score: Dictionary = {inicio: 0.0}
	
	var h_inicial = heuristica(inicio, objetivo)
	if algoritmo_atual == "Guloso":
		f_score[inicio] = h_inicial
	elif algoritmo_atual == "WeightedAStar":
		f_score[inicio] = peso_heuristic_w * h_inicial
	else:
		f_score[inicio] = h_inicial

	var fechados: Array[Vector2i] = []
	var movimentos = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]

	while abertos.size() > 0:
		var atual = abertos[0]
		var menor_f = f_score.get(atual, INF)
		for node in abertos:
			var f = f_score.get(node, INF)
			if f < menor_f:
				menor_f = f
				atual = node

		if atual == objetivo:
			return reconstruir_caminho(veio_de, atual)

		abertos.erase(atual)
		fechados.append(atual)

		for dir in movimentos:
			var vizinho = atual + dir
			if not eh_transponivel(vizinho) or vizinho in fechados:
				continue
			
			var custo_tentativo = g_score.get(atual, INF) + 1.0
			
			if not vizinho in abertos:
				abertos.append(vizinho)
			elif custo_tentativo >= g_score.get(vizinho, INF):
				continue

			veio_de[vizinho] = atual
			g_score[vizinho] = custo_tentativo
			
			var h = heuristica(vizinho, objetivo)
			if algoritmo_atual == "Guloso":
				f_score[vizinho] = h
			elif algoritmo_atual == "WeightedAStar":
				f_score[vizinho] = g_score[vizinho] + (peso_heuristic_w * h)
			else:
				f_score[vizinho] = g_score[vizinho] + h

	return []

func reconstruir_caminho(veio_de: Dictionary, atual: Vector2i) -> Array[Vector2i]:
	var caminho: Array[Vector2i] = [atual]
	while veio_de.has(atual):
		atual = veio_de[atual]
		caminho.push_front(atual)
	return caminho

# --- Resolução Simplificada do VRP no Grid ---
func calcular_vrp() -> void:
	rotas_celulas.clear()
	cliente_atribuido_a_veiculo.clear()
	clientes_visitados.clear()
	custos_rotas_veiculos.clear()
	custo_total_frota = 0
	
	var clientes_nao_visitados = []
	for i in range(1, pontos_grid.size()):
		clientes_nao_visitados.append(i)
		clientes_visitados[i] = false
	
	for v in range(min(num_veiculos, pontos_grid.size() - 1)):
		rotas_celulas.append([pontos_grid[0]])
	
	if rotas_celulas.is_empty():
		rotas_celulas.append([pontos_grid[0]])

	var veiculo_ativo = 0
	while clientes_nao_visitados.size() > 0:
		var ultimo_ponto = rotas_celulas[veiculo_ativo].back()
		
		var melhor_proximo = clientes_nao_visitados[0]
		var menor_custo = INF
		
		for cliente_idx in clientes_nao_visitados:
			var destino = pontos_grid[cliente_idx]
			var caminho = encontrar_caminho_grid(ultimo_ponto, destino)
			var custo = float(caminho.size())
				
			if custo < menor_custo and caminho.size() > 0:
				menor_custo = custo
				melhor_proximo = cliente_idx
		
		var destino_final = pontos_grid[melhor_proximo]
		var sub_caminho = encontrar_caminho_grid(ultimo_ponto, destino_final)
		if sub_caminho.size() > 0:
			sub_caminho.pop_front()
			for p in sub_caminho:
				rotas_celulas[veiculo_ativo].append(p)
		
		cliente_atribuido_a_veiculo[melhor_proximo] = veiculo_ativo
				
		clientes_nao_visitados.erase(melhor_proximo)
		veiculo_ativo = (veiculo_ativo + 1) % rotas_celulas.size()

	# Retorno ao depósito e cálculo das métricas de tamanho de caminho
	for v in range(rotas_celulas.size()):
		if rotas_celulas[v].back() != pontos_grid[0]:
			var sub_caminho = encontrar_caminho_grid(rotas_celulas[v].back(), pontos_grid[0])
			if sub_caminho.size() > 0:
				sub_caminho.pop_front()
				for p in sub_caminho:
					rotas_celulas[v].append(p)
		
		var tamanho_rota = rotas_celulas[v].size() - 1
		custos_rotas_veiculos.append(max(0, tamanho_rota))
		custo_total_frota += max(0, tamanho_rota)

func inicializar_animacao_veiculos() -> void:
	posicoes_atuais_veiculos.clear()
	indices_meta_rota.clear()
	progresso_trecho.clear()
	veiculo_aguardando.clear()
	
	for v in range(rotas_celulas.size()):
		var celula_inicial = rotas_celulas[v][0]
		posicoes_atuais_veiculos.append(Vector2(celula_inicial) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2))
		indices_meta_rota.append(1)
		progresso_trecho.append(0.0)
		veiculo_aguardando.append(false)

func atualizar_movimento_veiculos(delta: float) -> void:
	for v in range(rotas_celulas.size()):
		if veiculo_aguardando[v]:
			continue 
			
		var rota = rotas_celulas[v]
		if rota.size() <= 1:
			continue
			
		var meta_idx = indices_meta_rota[v]
		var celula_origem = rota[meta_idx - 1]
		var celula_destino = rota[meta_idx]
		
		var pos_origem = Vector2(celula_origem) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
		var pos_destino = Vector2(celula_destino) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
		
		for i in range(1, pontos_grid.size()):
			if pontos_grid[i] == celula_destino and cliente_atribuido_a_veiculo.get(i, -1) == v:
				if progresso_trecho[v] >= 0.5: 
					clientes_visitados[i] = true

		var distancia_total = pos_origem.distance_to(pos_destino)
		if distancia_total > 0:
			var velocidade_ajustada = (velocidade_veiculo * delta) / distancia_total
			progresso_trecho[v] += velocidade_ajustada
			
			if progresso_trecho[v] >= 1.0:
				progresso_trecho[v] = 0.0
				indices_meta_rota[v] += 1
				
				if indices_meta_rota[v] >= rota.size():
					veiculo_aguardando[v] = true
					indices_meta_rota[v] = rota.size() - 1
					posicoes_atuais_veiculos[v] = pos_destino
				else:
					posicoes_atuais_veiculos[v] = pos_destino
			else:
				posicoes_atuais_veiculos[v] = pos_origem.lerp(pos_destino, progresso_trecho[v])

func verificar_sincronia_chegada() -> void:
	if veiculo_aguardando.is_empty():
		return
		
	var todos_terminaram = true
	for aguardando in veiculo_aguardando:
		if not aguardando:
			todos_terminaram = false
			break
			
	if todos_terminaram:
		for i in clientes_visitados.keys():
			clientes_visitados[i] = false
		inicializar_animacao_veiculos()

# --- Atualização do Label UI ---
func atualizar_texto_label() -> void:
	if not label_painel:
		return
		
	var texto = "=== PAINEL DE EFICIÊNCIA (VRP) ===\n"
	texto += "Mapa Ativo: " + str(mapa_atual_id + 1) + "/3 (Pressione 'S' para trocar)\n"
	texto += "Algoritmo: " + algoritmo_atual + " (Pressione 'A' para alternar)\n\n"
	
	for v in range(custos_rotas_veiculos.size()):
		var status_espera = " (Esperando)" if veiculo_aguardando[v] else ""
		texto += "• Veículo V" + str(v+1) + ": " + str(custos_rotas_veiculos[v]) + " passos" + status_espera + "\n"
		
	texto += "\nCUSTO TOTAL DA FROTA: " + str(custo_total_frota) + " passos"
	
	label_painel.text = texto

# --- Desenho Gráfico na Tela ---
func _draw() -> void:
	for x in range(colunas + 1):
		draw_line(Vector2(x * tamanho_celula, 0), Vector2(x * tamanho_celula, linhas * tamanho_celula), Color(0.15, 0.15, 0.15, 0.5))
	for y in range(linhas + 1):
		draw_line(Vector2(0, y * tamanho_celula), Vector2(colunas * tamanho_celula, y * tamanho_celula), Color(0.15, 0.15, 0.15, 0.5))

	for obs in obstaculos:
		var rect = Rect2(Vector2(obs) * tamanho_celula, Vector2(tamanho_celula, tamanho_celula))
		draw_rect(rect, Color.DARK_SLATE_GRAY, true)

	for v in range(rotas_celulas.size()):
		var rota = rotas_celulas[v]
		var cor = cores_veiculos[v % cores_veiculos.size()]
		for i in range(rota.size() - 1):
			var de = Vector2(rota[i]) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
			var para = Vector2(rota[i+1]) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
			draw_line(de, para, Color(cor.r, cor.g, cor.b, 0.5), 3.0, true)

	for i in range(pontos_grid.size()):
		var p_cel = pontos_grid[i]
		var p_px = Vector2(p_cel) * tamanho_celula + Vector2(tamanho_celula/2, tamanho_celula/2)
		if i == 0:
			draw_circle(p_px, 12.0, Color.YELLOW)
			draw_string(ThemeDB.fallback_font, p_px + Vector2(-25, -15), "Depósito", HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color.WHITE)
		else:
			var cor_ponto = Color.WHITE
			if clientes_visitados.get(i, false):
				cor_ponto = Color.DIM_GRAY 
			else:
				var veiculo_id = cliente_atribuido_a_veiculo.get(i, 0)
				cor_ponto = cores_veiculos[veiculo_id % cores_veiculos.size()] 
				
			draw_circle(p_px, 8.0, cor_ponto)
			draw_string(ThemeDB.fallback_font, p_px + Vector2(-10, -12), "C" + str(i), HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color.LIGHT_GRAY)

	for v in range(posicoes_atuais_veiculos.size()):
		var pos_v = posicoes_atuais_veiculos[v]
		var cor = cores_veiculos[v % cores_veiculos.size()]
		draw_rect(Rect2(pos_v - Vector2(7, 7), Vector2(14, 14)), cor, true)
		
		var status_txt = "V" + str(v+1)
		if veiculo_aguardando[v]:
			status_txt += " (Esperando)"
		draw_string(ThemeDB.fallback_font, pos_v + Vector2(-15, 22), status_txt, HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color.WHITE)


func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://menu.tscn")
