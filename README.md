# AWS Secrets Manager: Credenciais de Banco sem Senha no Código, com Rotação e Auditoria

*Como tirar a senha do banco de dentro do código e da máquina, deixá-la cifrada, auditável e rotacionável — e provar que funciona, com uma aplicação real rodando na AWS.*

![Capa](imagens/imagem%20(19).png)
---

## O problema que todo mundo já viu

Abra qualquer projeto antigo e procure por `password =`. É quase certo que você vai encontrar uma senha de banco escrita em texto puro: no código-fonte, num arquivo `.env`, num `application.properties` ou numa variável de ambiente do container.

Funciona? Funciona. O problema é o que vem depois:

- a senha **vaza no repositório** — e fica no histórico do Git para sempre, mesmo que você a apague depois;
- vaza em **backups e imagens de máquina**, que ninguém lembra de limpar;
- aparece em **logs e telas de diagnóstico**, porque variável de ambiente é fácil de imprimir por acidente;
- e, quando a senha precisa mudar, exige **um novo deploy** — então, na prática, ninguém troca.

A pergunta central deste artigo é simples: **onde guardar a senha?** A resposta que vou demonstrar é o **AWS Secrets Manager** — um cofre gerenciado onde a credencial fica cifrada, com acesso controlado por identidade, auditada e passível de rotação, e de onde a aplicação a lê em tempo de execução **sem nunca ter uma chave gravada em lugar nenhum**.

Para não ficar na teoria, construí uma aplicação de verdade — o **Cofre de Pedidos** — e implantei tudo na AWS. As imagens ao longo do texto são da execução real.

> Este é um projeto de estudo, feito 100% pelo Console AWS. Todo o passo a passo reproduzível está em [`IMPLANTACAO.md`](IMPLANTACAO.md), a arquitetura detalhada em [`ARQUITETURA.md`](ARQUITETURA.md) e os testes de validação em [`TESTES.md`](TESTES.md).

## Diagrama da arquitetura de referência
![Capa](imagens/imagem%20(18).png)

---

## A ideia em uma frase

> A aplicação se identifica com a **identidade da própria máquina** (um IAM Role), pede a senha ao **Secrets Manager** no momento em que precisa, e o cofre só entrega depois de o **KMS** decifrar o valor — registrando tudo no **CloudTrail**.

Nenhuma senha no código. Nenhuma chave de acesso na instância. E, quando a senha muda, a aplicação pega a nova sozinha.

![Aplicação Cofre de Pedidos rodando: três cartões em OK — identidade da instância, leitura do segredo e conexão com o banco](imagens/imagem%20(1).png)

Essa é a tela da aplicação funcionando. Os três cartões contam a história inteira:

- **Identidade da instância** — a aplicação está autenticada como um IAM Role, com credenciais temporárias.
- **AWS Secrets Manager** — ela leu o segredo `prod/app/db`; repare que a senha aparece como `••••••••`, **nunca** em texto.
- **Banco de dados** — ela usou usuário e senha do segredo para conectar ao MariaDB e listar os pedidos.

O resto do artigo mostra como cada peça foi montada e por quê.

---

## A aplicação: Cofre de Pedidos

É uma aplicação web mínima, em Python, que simula o caso mais comum do mundo real: **um sistema que precisa de usuário e senha para falar com um banco de dados.**

Em vez de carregar a senha no código, ela faz o seguinte a cada carregamento de página:

1. descobre quem é (o IAM Role da instância);
2. pede a credencial ao Secrets Manager;
3. conecta ao MariaDB com o que recebeu;
4. mostra o resultado — e qualquer erro — na tela.

Essa transparência é proposital. Cada cartão vira **OK** ou **ERRO** conforme o que acontece de verdade, então a página funciona como um painel de testes ao vivo. A senha, no entanto, **jamais** aparece: é exibida como `••••••••`, e nem no código-fonte da página nem nos logs do servidor ela existe em texto.

A aplicação inteira é instalada sozinha, no primeiro boot da máquina, por um script de inicialização ([`app/user-data.sh`](app/user-data.sh)) — e esse script **também não contém a senha**. Ele a busca no cofre na hora de criar o banco.

---

## Como foi montado, peça por peça

### 1. O cofre: um segredo cifrado

Tudo começa criando o segredo `prod/app/db` no Secrets Manager, no formato JSON, com os dados de conexão do banco (motor, host, porta, nome do banco, usuário e senha).

![Segredo prod/app/db no Secrets Manager, cifrado com a chave gerenciada aws/secretsmanager](imagens/imagem%20(2).png)

O valor fica guardado em pares chave/valor — exatamente o formato que a AWS usa para segredos de banco de dados.

![Valor do segredo: engine, host, port, dbname, username e password](imagens/imagem%20(5).png)

E aqui está a primeira camada de proteção: **o valor é cifrado em repouso pelo AWS KMS**. Ele só existe em texto claro por um instante, dentro da memória, no momento em que alguém autorizado o lê.

### 2. A identidade: um IAM Role com o mínimo necessário

Como a aplicação prova que tem direito de ler o segredo, sem carregar uma chave de acesso? Com um **IAM Role** associado à máquina.

Criei uma política que permite **uma única ação** — ler o valor **daquele** segredo específico — e nada mais.

![Política POLITICA_APP: serviço Secrets Manager, nível de acesso somente leitura](imagens/imagem%20(7).png)

Essa política foi anexada a um Role, junto com a permissão que habilita o acesso ao terminal da máquina sem abrir porta SSH.

![Role ROLE_APP com a política de leitura do segredo e a de acesso via Session Manager](imagens/imagem%20(6).png)

Esse é o princípio do **menor privilégio** na prática: o Role lê um segredo, e só. Ele nem sequer consegue **listar** os segredos da conta — vamos ver isso acontecer mais adiante.

### 3. A máquina e a rede

A aplicação roda em uma EC2 Amazon Linux, numa rede com acesso controlado: o firewall (Security Group) só aceita tráfego web **vindo do meu próprio IP**. Sem SSH aberto, sem o banco exposto.

![Security Group permitindo apenas HTTP na porta 80, com origem restrita ao meu IP](imagens/imagem%20(8).png)

A instância sobe com o IAM Role já associado e com o metadados em modo seguro (IMDSv2). O banco MariaDB roda na própria máquina, acessível só localmente.

![Instância EC2 em execução: Amazon Linux 2023, IMDSv2 obrigatório, com o IAM Role associado](imagens/imagem%20(10).png)

No primeiro boot, o script de inicialização instala o banco, instala a aplicação e — o ponto-chave — **lê o segredo pelo Role da máquina** para criar o usuário do banco com a senha certa. A senha existe apenas no cofre e no banco. Nunca no script.

### 4. A prova de que não há senha vazando

Com tudo no ar, abri o terminal da máquina (pelo Session Manager, sem SSH) e fiz as verificações de segurança:

![Terminal: instalação concluída, serviços ativos, nenhuma credencial estática, e o ListSecrets negado](imagens/imagem%20(12).png)

Três coisas ficam provadas nessa tela:

- **Não há credencial estática na máquina** — nenhum arquivo `~/.aws` com chaves.
- **A identidade é o Role** — `assumed-role/ROLE_APP/...`, credenciais temporárias.
- **O menor privilégio é real** — ao tentar `list-secrets`, a resposta é `AccessDeniedException`. O Role lê o segredo da aplicação e **nada além disso**.

E a senha? Procurei por ela no HTML da página, no log da aplicação e no log de instalação. As três buscas retornaram **zero**. A credencial simplesmente não está escrita em lugar nenhum fora do cofre.

---

## Uma camada a mais: política no próprio segredo

A política de identidade diz "este Role **pode** ler". Dá para reforçar pelo outro lado, com uma política **anexada ao segredo**, dizendo "este segredo só aceita ser lido por estas identidades — qualquer outra é **negada**".

![Política de recurso do segredo: um Deny para qualquer identidade fora da lista permitida](imagens/imagem%20(13).png)

A regra é um `Deny` explícito para todos, com exceção da aplicação e do administrador. Depois de salvá-la, recarreguei a aplicação: continua lendo normalmente, porque o Role está na lista.

![Aplicação OK com a política de recurso ativa: o Role autorizado segue lendo o segredo](imagens/imagem%20(14).png)

Por que isso importa? Porque na AWS, quando políticas se combinam, **um `Deny` explícito sempre vence qualquer `Allow`**. Mesmo que alguém, por engano, dê a um usuário uma permissão ampla de "ler qualquer segredo", este segredo específico continuaria protegido. São duas fechaduras, cada uma com a sua chave.

---

## A parte favorita: trocar a senha sem mexer na aplicação

Esta é a razão de existir do Secrets Manager. Vamos trocar a senha do banco e ver o que acontece.

**Passo 1 — mudo a senha no cofre.** Edito o valor do segredo no Console. O Secrets Manager guarda a nova versão como "atual" (`AWSCURRENT`) e a antiga vira "anterior" (`AWSPREVIOUS`).

**Passo 2 — a aplicação percebe na hora.** Ao recarregar, o cartão do Secrets Manager já mostra a versão nova. Mas o banco dá erro:

![Cartão do banco em ERRO 1045: o segredo já tem a senha nova, mas o banco ainda tem a antiga](imagens/imagem%20(3).png)

Esse erro `1045 — Access denied` é **a lição mais importante do laboratório**: mudar a senha no cofre **não muda a senha no banco**. São dois sistemas. O cofre guarda a credencial; o banco é o "sistema de destino", onde a senha de fato precisa ser aplicada.

**Passo 3 — sincronizo o banco.** Rodo o utilitário que aplica a senha nova (o mesmo papel que uma automação faria). Recarrego a página:

![Depois de sincronizar: os três cartões voltam a OK, já com a nova versão do segredo](imagens/imagem%20(4).png)

Tudo verde de novo — **sem alterar uma linha de código e sem reiniciar a aplicação**. Ela simplesmente pede sempre a versão "atual" e recebe o valor novo.

É aqui que entra a **rotação automática**: uma função Lambda faz exatamente esses passos em ciclo (gera a senha, aplica no banco, testa, e só então promove a versão nova), eliminando aquela janela de erro. Para Amazon RDS e Aurora, a AWS já entrega essa automação pronta. Neste projeto, fiz a rotação **manual** justamente para enxergar, passo a passo, o que a automação esconde.

---

## Quem leu o segredo, e quando? O CloudTrail conta

Guardar a senha bem é metade do trabalho. A outra metade é **saber quem a acessou**. Todo acesso ao Secrets Manager e toda decifragem no KMS ficam registrados no CloudTrail.

![CloudTrail: leituras GetSecretValue feitas pela instância, e ações administrativas feitas pelo usuário do Console](imagens/imagem%20(15).png)

Dá para ver os eventos `GetSecretValue` — cada vez que a aplicação leu o segredo — identificados pela máquina. E, acompanhando cada leitura, um evento `Decrypt` no KMS:

![CloudTrail filtrado por Decrypt: o KMS decifrando o segredo a cada leitura](imagens/imagem%20(16).png)

Abrindo um desses eventos, o detalhe é revelador:

![Detalhe do evento Decrypt: a decifragem foi feita pelo próprio Secrets Manager, sobre o segredo e a versão corretos](imagens/imagem%20(17).png)

O campo `invokedBy` mostra `secretsmanager.amazonaws.com`: foi **o serviço** que pediu a decifragem, nos bastidores — a aplicação nunca fala diretamente com o KMS. O registro aponta exatamente qual segredo, qual versão e qual chave. Tudo isso **sem jamais gravar o valor da senha**. É auditoria completa, de graça, nos últimos 90 dias.

---

## Os conceitos por trás, de forma direta

### Credenciais temporárias em vez de chaves fixas

O IAM Role entrega à máquina credenciais que **expiram e se renovam sozinhas**. O SDK as encontra automaticamente. Resultado: nunca existe uma `access key` parada na instância para alguém roubar.

### O segredo é um JSON

```json
{ "engine": "mariadb", "host": "127.0.0.1", "port": "3306", "dbname": "lab02db", "username": "app_user", "password": "••••••••" }
```

Uma única leitura traz tudo que a aplicação precisa para conectar. É o mesmo formato dos segredos de banco gerenciados pela AWS.

### Versões: AWSCURRENT, AWSPREVIOUS, AWSPENDING

| Estágio | O que é |
|---------|---------|
| `AWSCURRENT` | A versão atual, entregue por padrão |
| `AWSPREVIOUS` | A anterior, guardada para rollback |
| `AWSPENDING` | A que está sendo preparada durante uma rotação |

Como a aplicação sempre pede a `AWSCURRENT`, ela adota valores novos **sem mudança de código**.

### Cache: não martele a API

A aplicação guarda o segredo em memória por 60 segundos. Evita custo e latência de ler a cada requisição. Se o login no banco falhar, ela relê uma vez antes de desistir — o padrão recomendado para conviver com rotações.

### Duas políticas, uma decisão

| | Política de identidade | Política de recurso |
|--|------------------------|---------------------|
| Fica em | no IAM Role (quem acessa) | no segredo (o que é acessado) |
| Faz | libera o Role a ler só este segredo | nega qualquer identidade fora da lista |

Na mesma conta, basta um `Allow` para permitir. Mas um `Deny` explícito em qualquer uma das duas **sempre prevalece**.

### Chave da AWS × chave do cliente (CMK)

| | `aws/secretsmanager` (padrão) | CMK (do cliente) |
|--|-------------------------------|------------------|
| Controle | da AWS | seu (política, rotação, auditoria da chave) |
| Custo | sem custo de chave | custo mensal por chave |
| Quando usar | maioria dos casos | compliance, controle próprio, acesso entre contas |

### Secrets Manager × Parameter Store

| | Secrets Manager | Parameter Store (SecureString) |
|--|-----------------|--------------------------------|
| Rotação automática | **sim**, nativa | não |
| Custo | por segredo/mês + chamadas | parâmetro padrão sem custo de armazenamento |
| Política no próprio recurso | sim | não |
| Melhor para | credenciais que **rotacionam** | configuração e segredos simples |

Em uma frase: **senha de banco que precisa rotacionar → Secrets Manager; configuração estável e simples → Parameter Store.**

---

## O que fica de aprendizado

Montar esse fluxo deixa claro o que significa, na prática, tratar uma credencial com cuidado:

- **A senha sai do código e da máquina.** Fica em um cofre cifrado, em um único lugar.
- **A aplicação não carrega chave nenhuma.** Ela se identifica pela máquina (IAM Role) e recebe credenciais temporárias.
- **O acesso é mínimo e tem dupla trava.** A aplicação lê um segredo, e só; o próprio segredo recusa qualquer outro.
- **Trocar a senha não quebra nada** — e expõe por que a rotação automática existe.
- **Todo acesso é auditável**, sem nunca registrar o valor.

É um padrão que escala do laboratório para produção: troque o MariaDB local por um Amazon RDS e ative a rotação gerenciada, que o resto da arquitetura continua igual.

---

## Quer reproduzir?

Todo o material para refazer este projeto do zero está aqui:

| Documento | Conteúdo |
|-----------|----------|
| [`ARQUITETURA.md`](ARQUITETURA.md) | Diagramas, componentes, o fluxo completo e o ciclo de vida do segredo |
| [`IMPLANTACAO.md`](IMPLANTACAO.md) | O passo a passo no Console, em sete cenários, com custos e limpeza |
| [`TESTES.md`](TESTES.md) | Os testes de validação (positivos, negativos e de segurança) com evidências |
| [`app/user-data.sh`](app/user-data.sh) | O script que instala banco e aplicação, lendo o segredo no primeiro boot |

> **Nota sobre as imagens:** as capturas acima são de uma execução real e podem conter identificadores da conta (ID, ARNs, IP). Ao reutilizar este material, oculte esses dados.

---

*Projeto de estudo de segurança na AWS, implantado e validado de ponta a ponta pelo Console. Dúvidas e sugestões são bem-vindas.*
