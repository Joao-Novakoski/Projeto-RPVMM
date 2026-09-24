using JuMP
using DataFrames
using CSV
using Gurobi


const FROTA_MAX_POR_ARMADOR = 5


df_clientes = CSV.read("MDClientes.csv", DataFrame)
df_locais = CSV.read("MDLocais.csv", DataFrame)
df_produtos = CSV.read("MDP.csv", DataFrame)
df_cap_fabricas = CSV.read("RDCapFabricas.csv", DataFrame)
df_local_produto = CSV.read("RDLocalProduto.csv", DataFrame)
df_demanda = CSV.read("RDDemanda.csv", DataFrame)
df_custo_inland = CSV.read("RDCustoInland.csv", DataFrame)
df_estoque_init = CSV.read("RDEstoqueInicial.csv", DataFrame)

df_armador_rotas = CSV.read("MDArmadorRotas.csv", DataFrame)
df_armador_rotas.COD_LOCAL_DESTINOS = split.(df_armador_rotas.COD_LOCAL_DESTINOS, ";")

L = unique(df_locais.COD_LOCAL)
T = sort(unique(df_cap_fabricas.INSTANTE))
C = filter(row -> row.ATIVO == true, df_clientes).COD_CLIENTE
F = filter(row -> row.TIPO == "Fabrica", df_locais).COD_LOCAL
POL = filter(row -> row.TIPO == "POL", df_locais).COD_LOCAL
POD = filter(row -> row.TIPO == "POD", df_locais).COD_LOCAL
A = unique(df_armador_rotas.COD_ARMADOR)
R = [(row.COD_ARMADOR, row.COD_LOCAL_ORIGENS, row.COD_LOCAL_DESTINOS) for row in eachrow(df_armador_rotas)]
N = [(a, i) for a in A for i in 1:5]

df_prod_ativos  = filter(row -> row.ATIVO == true, df_produtos)
P = [(row.FAMILIA_PRODUTO, row.LINHA_PRODUTO) for row in eachrow(df_prod_ativos)]


FabricaLinhas = [(row.COD_LOCAL, row.LINHA_PRODUTO) for row in eachrow(df_local_produto) if row.PRODUZ == true]
ClientePODs = [(row.COD_CLIENTE, row.COD_LOCAL) for row in eachrow(df_custo_inland)]
FabricaPOL = Dict(
    "Suzano" => "Santos", "TresLagoas" => "Santos", "Ribas" => "Santos",
    "Limeira" => "Santos", "Jacarei" => "Santos",
    "Mucuri" => "Portocel", "Aracruz" => "Portocel", "Veracel" => "Portocel",
    "Imperatriz" => "Itaqui"
)

preco_venda = Dict(
    (
        row.COD_CLIENTE,
        (row.FAMILIA_PRODUTO, row.LINHA_PRODUTO),
        row.INSTANTE
    ) => row.PRECO_VENDA
    for row in eachrow(df_demanda)
)

frete_mar = Dict(
    (
        row.COD_ARMADOR,
        row.COD_LOCAL_ORIGENS,
        row.COD_LOCAL_DESTINOS
    ) => row.FRETE_POR_TON
    for row in eachrow(df_armador_rotas)
)

custo_inland = Dict(
    (
        row.COD_CLIENTE,
        row.COD_LOCAL
    ) => row.CUSTO_INLAND_POR_TON
    for row in eachrow(df_custo_inland)
)

min_intake = Dict(
    (
        row.COD_ARMADOR,
        row.COD_LOCAL_ORIGENS,
        row.COD_LOCAL_DESTINOS
    ) => row.MIN_INTAKE
    for row in eachrow(df_armador_rotas)
)

max_intake = Dict(
    (
        row.COD_ARMADOR,
        row.COD_LOCAL_ORIGENS,
        row.COD_LOCAL_DESTINOS
    ) => row.MAX_INTAKE
    for row in eachrow(df_armador_rotas)
)

caladoDWT = Dict(
    (
        row.COD_LOCAL
    ) => row.CALADO_DWT
    for row in eachrow(df_locais)
)

estoque_inicial = Dict(
    (
        row.COD_LOCAL,
        (row.FAMILIA_PRODUTO, row.LINHA_PRODUTO)
    ) => row.QTD_DISPONIVEL
    for row in eachrow(df_estoque_init)
)

tempo_ida = Dict(
    (
        row.COD_ARMADOR,
        row.COD_LOCAL_ORIGENS,
        row.COD_LOCAL_DESTINOS
    ) => row.TEMPO_IDA
    for row in eachrow(df_armador_rotas)
)

volume_producao = Dict(
    (
        row.COD_LOCAL,
        row.INSTANTE
    ) => row.VOLUME_PRODUCAO
    for row in eachrow(df_cap_fabricas)
)

demanda = Dict(
    (
        row.COD_CLIENTE,
        (row.FAMILIA_PRODUTO, row.LINHA_PRODUTO),
        row.INSTANTE
    ) => row.DEMANDA
    for row in eachrow(df_demanda)
)

max_estoque = Dict(
    (
        row.COD_LOCAL
    ) => row.MAX_ESTOQUE
    for row in eachrow(df_locais)
)


model = Model()


# Produção nas Fábricas
@variable(model, prod[f in F, (fa,l) in P, t in T; (f, l) in FabricaLinhas] >= 0)

# Envio Fábrica -> POL
@variable(model, fab_pol[f in F, (fa,l) in P, t in T; (f, l) in FabricaLinhas] >= 0)

# Embarque em cada POL
@variable(model, load[pol in POL, (fa,l) in P, t in T] >= 0)

# Desembarque em cada POD
@variable(model, unload[pod in POD, (fa,l) in P, t in T] >= 0)

# Carga Total Transportada na Rota
@variable(model, w_ship[r in R, (fa,l) in P, t in T] >= 0)

# Número de Navios Contratados
@variable(model, navios[r in R, t in T] >= 0, Int)

# Estoques e Vendas
@variable(model, estoque_produto[l in L, (fa,l) in P, t in T] >= 0)
@variable(model, vendas_produto[c in C, pod in POD, (fa,l) in P, t in T; (c, pod) in ClientePODs] >= 0)

@variable(model, navio_partida[(a, i) in N, r in R,t in T], Bin)
@variable(model, navio_estado[(a, i) in N, t in T], Bin)




@objective(model, Max,
    # Receita de Vendas
    sum(preco_venda[c, (fa,l), t] * vendas_produto[c, pod, (fa,l), t] 
        for c in C, pod in POD, (fa,l) in P, t in T 
        if (c, pod) in ClientePODs && haskey(preco_venda, (c, (fa,l), t))) -
    
    # Custo de Frete Marítimo
    sum(frete_mar[a, o, d] * w_ship[r, (fa,l), t] 
        for (a, o, d) in R, (fa,l) in P, t in T 
        if haskey(FreteMaritimo, (a, o, d))) -
    
    # Custo Inland
    sum(custo_inland[c, pod] * s_vendas[c, pod, (fa,l), t] 
        for c in C, pod in POD, (fa,l) in P, t in T 
        if (c, pod) in ClientePODs && haskey(custo_inland, (c, pod)))
)




# Embarque Total nos POLs = Carga da Viagem
@constraint(model, embarque_total[(a, o, d) in R, (fa,l) in P, t in T],
    load[o, (fa,l), t] == w_ship[(a, o, d), (fa,l), t]
)

# Desembarque Total nos PODs = Carga da Viagem
@constraint(model, desembarque_total[(a, o, d) in R, (fa,l) in P, t in T],
    unload[d[end], (fa,l), t] == w_ship[(a, o, d), (fa,l), t]
)

# Min intake
@constraint(model, Min_intake[(a, o, d) in R, t in T],
    sum(w_ship[(a, o, d), (fa,l), t] for (fa,l) in P) >= min_intake[a, o, d] * navios[(a, o, d), t]
)

# Max intake
@constraint(model, Max_intake[(a, o, d) in R, t in T],
    sum(w_ship[(a, o, d), (fa,l), t] for (fa,l) in P) <= max_intake[a, o, d] * navios[(a, o, d), t]
)

# Restrição de Calado por Porto visitado
@constraint(model, calado_pol[(a, o, d) in R, t in T],
    sum(load[o, (fa,l), t] for (fa,l) in P) <= CaladoDWT[o] * navios[(a, o, d), t]
)

# Balanço de Estoque no POL
@constraint(model, estoque_pol[pol in POL, (fa,l) in P, t in T],
    estoque_produto[pol, (fa,l), t] == (t == 1 ? estoque_inicial[pol, (fa,l)] : estoque_produto[pol, (f,l), t-1]) +
    sum(fab_pol[f, (fa,l), t] for f in F if FabricaPOL[f] == pol && (f, l) in FabricaLinhas) -
    sum(load[pol, (fa,l), t])
)

# Balanço de Estoque no POD
@constraint(model, estoque_pod[pod in POD, (fa,l) in P, t in T],
    estoque_produto[pod, (fa,l), t] == (t == 1 ? estoque_inicial[pod, (fa,l)] : estoque_produto[pod, (fa,l), t-1]) +
    sum(unload[d[end], (fa,l), t - tempo_ida[a, o, d]] for (a, o, d) in R if pod == d[end] && t > tempo_ida[a, o, d]) -
    sum(vendas_produto[c, pod, (fa,l), t] for c in C if (c, pod) in ClientePODs)
)

# Balanço de estoque na fábrica
@constraint(model, estoque_fabrica[f in F, (fa,l) in P, t in T],
    estoque_produto[f, (fa,l), t] == (t == 1 ? estoque_inicial[f, (fa,l)] : estoque_produto[f, (fa, l), t-1]) +
    sum(prod[f, (fa, l), t]) - fab_pol[f, (fa, l), t]
)

# a quantidade transportada na rota é menor do que a armazenada
@constraint(model, limite_transporte_rota[(a, o, d) in R, (fa, l) in P, t in T],
    w_ship[(a, o, d), (fa, l), t] <= (t == 1 ? estoque_inicial[o, (fa, l)] : estoque_produto[o, (fa, l), t-1])
)

# a quantidade transportada da fabrica é menor do que a armazenada
@constraint(model, limite_transporte_fabrica[f in F, (fa, l) in P, t in T],
    fab_pol[f, (fa, l), t] <= (t == 1 ? estoque_inicial[f, (fa, l)] : estoque_produto[f, (fa, l), t-1])
)

# até 100% da capacidade da fábrica
@constraint(model, capacidade_fabrica[f in F, t in T],
    sum(prod[f, (fa,l), t] for (fa,l) in P if (f, l) in FabricaLinhas) == volume_producao[f, t]
)

# Venda limitada à demanda
@constraint(model, demanda[c in C, (fa,l) in P, t in T],
    sum(vendas_produto[c, pod, (fa,l), t] for pod in POD if (c, pod) in ClientePODs) == haskeu(demanda, (c, (f,l), t)) ? demanda[c, (f,l), t] : 0
)

# Capacidade Máxima de estoque por lugar
@constraint(model, Max_estoque[l in L, t in T],
    sum(estoque_produto[l, (fa,l), t] for (fa,l) in P) <= max_estoque[l]
)

# Navio só é usado quando está disponível (navio_estado = 0)
@constraint(model, rest_estado_navio[(a, i) in N, t in T],
    navio_estado[(a, i), t] == sum(
        navio_partida[(a, i), (a, o, d), t0]
        for (a, o, d) in R, t0 in T
        if t0 <= t && t0 >= t - TempoIdaVolta[r] + 1
    )
)