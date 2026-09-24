# Documentação do Modelo de Otimização S&OP - Suzano (Julia / JuMP)

Este documento contém a especificação matemática completa e a documentação do modelo de otimização estocástica/determinística para o planejamento de produção, estoque e logística marítima de exportação de celulose da **Suzano**, conforme implementado em Julia com **JuMP**.

---

## 1. Visão Geral do Problema

A **Suzano** busca maximizar a margem de lucro operacional na exportação de celulose em um horizonte de planejamento discreto de 15 meses ($t \in \{1, 2, \dots, 15\}$). O modelo toma decisões integradas de:
1. **Produção Industrial**: Volume fabricado por fábrica, linha de produto e mês (com utilização obrigatória de 100% da capacidade fabril).
2. **Transferência Terrestre para Portos de Embarque (POL)**: Escoamento das fábricas para seus respectivos POLs de ligação estática.
3. **Logística Marítima Multi-stop**: Alocação de navios em rotas marítimas com carregamento em POLs e descarregamento em PODs no exterior.
4. **Gestão de Frota e Tempo de Retorno (*Return Time*)**: Controle individual da frota de 5 navios por armador e indisponibilidade do navio durante o ciclo completo de viagem ($tempo\_ida\_volta$).
5. **Estoque e Atendimento aos Clientes**: Armazenamento estático em fábricas, POLs e PODs, com chegada de estoque no POD diferida pelo tempo de trânsito de ida ($tempo\_ida$) e limite de atendimento pela demanda dos clientes.

---

## 2. Formulação Matemática Detalhada

### 2.1. Conjuntos e Índices

* $T = \{1, 2, \dots, 15\}$: Conjunto de instantes discretos de tempo (meses), indexado por $t$.
* $C$: Conjunto dos clientes ativos, indexado por $c$.
* $L$: Conjunto de todos os locais da malha logística ($L = F \cup POL \cup POD$), indexado por $loc$.
  * $F \subset L$: Conjunto de fábricas de celulose ($f \in F$).
  * $POL \subset L$: Conjunto de portos de embarque no Brasil ($pol \in POL$).
  * $POD \subset L$: Conjunto de portos de desembarque no exterior ($pod \in POD$).
* $A$: Conjunto dos armadores marítimos, indexado por $a$.
* $R$: Conjunto de rotas marítimas, indexado por $r = (a, o, d) \in R$, onde $o \in POL$ (ou lista de origens) e $d \in POD$ (ou lista de destinos).
* $N = \{(a, i) \mid a \in A, i \in \{1, 2, 3, 4, 5\}\}$: Conjunto de navios físicos (5 navios idênticos por armador).
* $P = \{(fa, l)\}$: Conjunto de produtos ativos, combinando família ($fa$) e linha de produto ($l$).

#### Relações e Subconjuntos de Compatibilidade (*Sparsity Sets*)
* $FabricaLinhas \subseteq F \times L_{linha}$: Mapeamento das linhas de produto $l$ que a fábrica $f$ está capacitada a produzir.
* $ClientePODs \subseteq C \times POD$: Mapeamento dos portos de desembarque $pod$ elegíveis para atender o cliente $c$ com frete terrestre (*in-land*).
* $FabricaPOL(f) \in POL$: Mapeamento estático da fábrica $f$ ao seu porto de embarque associado.

---

### 2.2. Parâmetros do Modelo

* $preco\_venda_{c, p, t}$: Preço unitário de venda do produto $p$ para o cliente $c$ no instante $t$ [USD/ton].
* $frete\_mar_{a, o, d}$: Tarifa de frete marítimo contratada na rota $(a, o, d)$ [USD/ton].
* $custo\_inland_{c, pod}$: Custo de frete terrestre/última milha do $pod$ até o cliente $c$ [USD/ton].
* $volume\_producao_{f, t}$: Capacidade líquida obrigatória de produção da fábrica $f$ no instante $t$ [ton].
* $demanda_{c, p, t}$: Demanda prevista do cliente $c$ pelo produto $p$ no instante $t$ [ton].
* $min\_intake_{a, o, d}$: Carregamento mínimo obrigatório por navio contratado na rota [ton].
* $max\_intake_{a, o, d}$: Capacidade máxima de carga do navio na rota [ton].
* $caladoDWT_{loc}$: Limite operacional de calado/DWT permitido no porto $loc$ [ton].
* $max\_estoque_{loc}$: Capacidade estática máxima de armazenamento no local $loc$ [ton].
* $estoque\_inicial_{loc, p}$: Nível de estoque do produto $p$ no local $loc$ no início do horizonte ($t=0$) [ton].
* $tempo\_ida_{a, o, d}$: Tempo de trânsito de ida da viagem [meses].
* $tempo\_ida\_volta_{a, o, d}$: Tempo total de ciclo e retorno do navio [meses].

---

### 2.3. Variáveis de Decisão

* $prod_{f, p, t} \ge 0$: Volume do produto $p = (fa, l)$ produzido na fábrica $f$ no instante $t$ [ton] (para $(f, l) \in FabricaLinhas$).
* $fab\_pol_{f, p, t} \ge 0$: Volume do produto $p$ transferido da fábrica $f$ para seu POL no instante $t$ [ton].
* $load_{pol, p, t} \ge 0$: Volume do produto $p$ embarcado no porto $pol$ no instante $t$ [ton].
* $unload_{pod, p, t} \ge 0$: Volume do produto $p$ desembarcado no porto $pod$ no instante $t$ [ton].
* $w\_ship_{r, p, t} \ge 0$: Carga total do produto $p$ transportada na rota $r = (a, o, d)$ no instante $t$ [ton].
* $navios_{r, t} \in \mathbb{Z}_+$: Número de viagens/navios contratados para a rota $r$ no instante $t$.
* $estoque\_produto_{loc, p, t} \ge 0$: Nível de estoque acumulado do produto $p$ no local $loc$ no final do instante $t$ [ton].
* $vendas\_produto_{c, pod, p, t} \ge 0$: Volume do produto $p$ entregue e vendido ao cliente $c$ via $pod$ no instante $t$ [ton].
* $navio\_partida_{(a, i), r, t} \in \{0, 1\}$: Variável binária de partida do navio $(a, i)$ na rota $r$ no instante $t$.
* $navio\_estado_{(a, i), t} \in \{0, 1\}$: Variável binária que indica se o navio $(a, i)$ está ocupado/em viagem no instante $t$.

---

### 2.4. Função Objetivo

Maximização do lucro líquido total (Receita de Vendas deduzida dos custos de Frete Marítimo e Frete *In-land*):

$$\max Z = \sum_{c \in C} \sum_{pod \in POD} \sum_{p \in P} \sum_{t \in T} \left( preco\_venda_{c, p, t} \cdot vendas\_produto_{c, pod, p, t} \right) - \sum_{r=(a,o,d) \in R} \sum_{p \in P} \sum_{t \in T} \left( frete\_mar_{a, o, d} \cdot w\_ship_{r, p, t} \right) - \sum_{c \in C} \sum_{pod \in POD} \sum_{p \in P} \sum_{t \in T} \left( custo\_inland_{c, pod} \cdot vendas\_produto_{c, pod, p, t} \right)$$

---

### 2.5. Equações de Restrição

#### 1. Utilização Integral da Capacidade Fabril (100% de uso de máquina)
$$\sum_{p=(fa, l) : (f, l) \in FabricaLinhas} prod_{f, p, t} = volume\_producao_{f, t} \quad \forall f \in F, \forall t \in T$$

#### 2. Balanço de Estoque nas Fábricas
$$estoque\_produto_{f, p, t} = \begin{cases} estoque\_inicial_{f, p} + prod_{f, p, t} - fab\_pol_{f, p, t}, & \text{se } t = 1 \\ estoque\_produto_{f, p, t-1} + prod_{f, p, t} - fab\_pol_{f, p, t}, & \text{se } t > 1 \end{cases} \quad \forall f \in F, \forall p \in P, \forall t \in T$$

#### 3. Limite de Transferência para o POL pelo Estoque da Fábrica
$$fab\_pol_{f, p, t} \le \begin{cases} estoque\_inicial_{f, p}, & \text{se } t = 1 \\ estoque\_produto_{f, p, t-1}, & \text{se } t > 1 \end{cases} \quad \forall f \in F, \forall p \in P, \forall t \in T$$

#### 4. Conservação de Carga da Rota Marítima
$$load_{o, p, t} = w\_ship_{(a, o, d), p, t} \quad \forall (a, o, d) \in R, \forall p \in P, \forall t \in T$$
$$unload_{d_{end}, p, t} = w\_ship_{(a, o, d), p, t} \quad \forall (a, o, d) \in R, \forall p \in P, \forall t \in T$$

#### 5. Limites Contratuais por Navio (*Min Intake* e *Max Intake*)
$$\sum_{p \in P} w\_ship_{r, p, t} \ge min\_intake_{r} \cdot navios_{r, t} \quad \forall r \in R, \forall t \in T$$
$$\sum_{p \in P} w\_ship_{r, p, t} \le max\_intake_{r} \cdot navios_{r, t} \quad \forall r \in R, \forall t \in T$$

#### 6. Restrição de Calado / DWT nos Portos de Embarque
$$\sum_{p \in P} load_{o, p, t} \le caladoDWT_{o} \cdot navios_{(a, o, d), t} \quad \forall (a, o, d) \in R, \forall t \in T$$

#### 7. Balanço de Estoque nos Portos de Embarque (POL)
$$estoque\_produto_{pol, p, t} = \begin{cases} estoque\_inicial_{pol, p} + \sum_{f : FabricaPOL(f)=pol} fab\_pol_{f, p, t} - load_{pol, p, t}, & \text{se } t = 1 \\ estoque\_produto_{pol, p, t-1} + \sum_{f : FabricaPOL(f)=pol} fab\_pol_{f, p, t} - load_{pol, p, t}, & \text{se } t > 1 \end{cases} \quad \forall pol \in POL, \forall p \in P, \forall t \in T$$

#### 8. Limite de Carregamento Marítimo pelo Estoque do POL
$$w\_ship_{(a, o, d), p, t} \le \begin{cases} estoque\_inicial_{o, p}, & \text{se } t = 1 \\ estoque\_produto_{o, p, t-1}, & \text{se } t > 1 \end{cases} \quad \forall (a, o, d) \in R, \forall p \in P, \forall t \in T$$

#### 9. Balanço de Estoque nos Portos de Desembarque (POD) com *Transit Time*
$$estoque\_produto_{pod, p, t} = \begin{cases} estoque\_inicial_{pod, p} + \sum_{r : d_{end}=pod, t > tempo\_ida_r} unload_{pod, p, t - tempo\_ida_r} - \sum_{c : (c, pod) \in ClientePODs} vendas\_produto_{c, pod, p, t}, & \text{se } t = 1 \\ estoque\_produto_{pod, p, t-1} + \sum_{r : d_{end}=pod, t > tempo\_ida_r} unload_{pod, p, t - tempo\_ida_r} - \sum_{c : (c, pod) \in ClientePODs} vendas\_produto_{c, pod, p, t}, & \text{se } t > 1 \end{cases}$$

#### 10. Teto de Vendas pela Demanda
$$\sum_{pod : (c, pod) \in ClientePODs} vendas\_produto_{c, pod, p, t} \le demanda_{c, p, t} \quad \forall c \in C, \forall p \in P, \forall t \in T$$

#### 11. Capacidade Máxima de Armazenamento Estático por Local
$$\sum_{p \in P} estoque\_produto_{loc, p, t} \le max\_estoque_{loc} \quad \forall loc \in L, \forall t \in T$$

#### 12. Disponibilidade da Frota e Tempo de Retorno (*Return Time*)
$$navio\_estado_{(a, i), t} = \sum_{r \in R_a} \sum_{t_0 = \max(1, t - tempo\_ida\_volta_r + 1)}^{t} navio\_partida_{(a, i), r, t_0} \quad \forall (a, i) \in N, \forall t \in T$$

---

## 3. Resumo da Estrutura do Código Julia

O código em `código_julia.txt` executa a montagem dos conjuntos a partir das tabelas CSV/PDF e constrói o modelo com o **JuMP** e solver **Gurobi**:

```julia
using JuMP
using DataFrames
using CSV
using Gurobi

# Leitura e parsing dos dados
df_clientes      = CSV.read("MDClientes.csv", DataFrame)
df_locais        = CSV.read("MDLocais.csv", DataFrame)
df_produtos      = CSV.read("MDProdutos.csv", DataFrame)
df_cap_fabricas  = CSV.read("RDCapFabricas.csv", DataFrame)
df_local_produto = CSV.read("RDLocalProduto.csv", DataFrame)
df_demanda       = CSV.read("RDDemanda.csv", DataFrame)
df_custo_inland  = CSV.read("RDCustoInland.csv", DataFrame)
df_estoque_init  = CSV.read("RDEstoqueInicial.csv", DataFrame)
df_armador_rotas = CSV.read("MDArmadorRotas.csv", DataFrame)

# Instanciação do modelo e otimização
model = Model(Gurobi.Optimizer)
optimize!(model)
```
