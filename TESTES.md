# AWS Secrets Manager — Credenciais de Banco sem Senha no Código: Testes

## Introdução

Os testes deste laboratório são **procedimentos manuais verificáveis**. Eles são executados no navegador, no Console AWS e no terminal da EC2 (via Session Manager), depois da implantação descrita em [`IMPLANTACAO.md`](IMPLANTACAO.md). Os nomes de recurso (`ROLE_APP`, `SG_APP`, etc.) e os marcadores da sua conta (`<IP_PUBLICO_EC2>`, `<ID_CONTA>`, etc.) estão descritos na seção **Nomes dos recursos** daquele documento.

> **Status:** 🔄 **parcialmente executados.** O laboratório foi implantado com sucesso: a aplicação **Cofre de Pedidos** respondeu com os três cartões **OK**, a senha não vazou em nenhum ponto, o menor privilégio foi confirmado pelo Session Manager, a **rotação manual** foi validada de ponta a ponta e a **auditoria no CloudTrail** confirmou a decifragem pelo KMS. Os testes **T01–T06 e T09 estão PASS**. Os demais (T07, T08, T10, T11) dependem de ações adicionais — remoção de políticas, exclusão/restauração e checagem de rede — e seguem **pendentes**. Preencha a coluna **Status** conforme executar cada um e adicione as capturas em [Evidências da execução](#evidências-da-execução).

### Critério de pass/fail

- **PASS:** o resultado observado corresponde ao **Resultado esperado**. Nos testes negativos, isso significa que o erro previsto **ocorreu**.
- **FAIL:** o resultado observado corresponde ao **Resultado de falha** ou diverge do esperado.

Os testes negativos sempre terminam com a **restauração** do estado correto, para que os testes seguintes partam de um ambiente funcional.

## Onde cada teste é habilitado (mapa com o `IMPLANTACAO.md`)

Cada teste depende de um cenário da implantação. Execute os testes na ordem em que concluir os cenários.

| Teste | Habilitado por (em [`IMPLANTACAO.md`](IMPLANTACAO.md)) |
|-------|-------------------------------------------------------|
| T01, T02, T03 | Cenário 3, passo 14 (página **Cofre de Pedidos**) |
| T04 | Cenário 3, passos 14–15 (HTML e logs) |
| T05, T11 | Cenário 3, passo 15 (terminal e rede) |
| T06 | Cenário 6 (CloudTrail) |
| T07 | Cenário 2 (remover `POLITICA_APP` do Role) |
| T08 | Cenário 4 (editar a política de recurso do segredo) |
| T09 | Cenário 5 (rotação manual) |
| T10 | Cenário 7 (exclusão agendada e restauração) |

## Tabela de testes (T01–T11)

| ID | Status | Objetivo | Pré-requisito | Procedimento | Resultado esperado | Resultado de falha | Explicação |
|----|--------|----------|---------------|--------------|--------------------|--------------------|------------|
| **T01** *(Positivo)* | ✅ **PASS** | A aplicação responde pela porta 80 a partir do seu IP. | Cenário 3 concluído. | 1. Acessar `http://<IP_PUBLICO_EC2>/health`. 2. Acessar `http://<IP_PUBLICO_EC2>/`. | `/health` retorna `{"status": "ok"}`, e `/` exibe a página **Cofre de Pedidos**. | Timeout, conexão recusada ou erro 5xx. | Confirma a instalação do user data, o serviço `lab02-app` e a regra HTTP 80 do `SG_APP`. |
| **T02** *(Positivo)* | ✅ **PASS** | A aplicação lê o segredo usando o IAM Role, com credenciais temporárias. | T01 PASS. | 1. Abrir `/?refresh=1`. 2. Ler os cartões **Identidade da instância** e **AWS Secrets Manager**. | Identidade `assumed-role/`ROLE_APP`/i-...`; Secrets Manager **OK** com versão, estágio `AWSCURRENT` e origem `Secrets Manager (GetSecretValue)`. | Cartão com **ERRO** ou identidade diferente do Role. | O `boto3` obtém credenciais do instance profile via IMDSv2. Nenhuma chave fica na instância. |
| **T03** *(Positivo)* | ✅ **PASS** | A aplicação conecta ao banco com as credenciais do segredo. | T02 PASS. | 1. Ler o cartão **Banco de dados**. | **OK**, com a versão do MariaDB e a tabela de 3 pedidos fictícios. | **ERRO** 1045 (senha) ou 2003 (banco parado). | Mostra o uso real do segredo: a senha do banco nunca aparece no código nem no user data. |
| **T04** *(Segurança)* | ✅ **PASS** | A senha não é exposta pela aplicação. | T03 PASS. | No Session Manager, com `<SENHA>` = valor real do campo `password`: 1. `curl -s http://127.0.0.1/ \| grep -cF '<SENHA>'`. 2. `sudo journalctl -u lab02-app --no-pager \| grep -cF '<SENHA>'`. 3. `sudo grep -cF '<SENHA>' /var/log/lab02-user-data.log`. | As três contagens retornam `0`; no navegador, a senha aparece só como `••••••••`. | A senha aparece em qualquer um dos três locais. | A senha só existe em memória durante a conexão. O user data a envia ao `mysql` pela entrada padrão e nenhum log a registra. |
| **T05** *(Segurança)* | ✅ **PASS** | Não há credenciais estáticas e o Role tem privilégio mínimo. | Session Manager disponível. | 1. `export AWS_DEFAULT_REGION=<REGIAO_AWS>`. 2. `sudo ls -d /root/.aws /home/*/.aws`. 3. `aws sts get-caller-identity`. 4. `aws secretsmanager list-secrets`. | Nenhum diretório `.aws`; identidade `assumed-role/`ROLE_APP`/...`; `list-secrets` retorna `AccessDeniedException`. | Existe `~/.aws/credentials`, ou `list-secrets` funciona. | A política `POLITICA_APP` permite apenas `GetSecretValue` no ARN de **um** segredo. |
| **T06** *(Positivo)* | ✅ **PASS** | O segredo é cifrado em repouso e a decifragem é auditada. | T02 PASS e alguns minutos de espera. | 1. Secrets Manager > `prod/app/db` > **Criptografia**: chave `aws/secretsmanager`. 2. CloudTrail > Histórico de eventos > Nome do evento `Decrypt`. 3. Abrir um evento. | A chave é `aws/secretsmanager`, e há eventos `Decrypt` com `"invokedBy": "secretsmanager.amazonaws.com"` próximos de cada `GetSecretValue`. | Sem eventos `Decrypt`, ou chave diferente da configurada. | O valor só é decifrado no momento da leitura, e o CloudTrail registra quem leu e quando. |
| **T07** *(Negativo)* | ⏳ | Sem a política de identidade, a leitura é negada. | T02 PASS. | 1. IAM > Funções > `ROLE_APP` > **Remover** `POLITICA_APP`. 2. Aguardar ~1 min e abrir `/?refresh=1`. 3. **Restaurar:** anexar `POLITICA_APP` novamente e recarregar. | No passo 2, o cartão Secrets Manager mostra **ERRO** `AccessDeniedException ... not authorized to perform: secretsmanager:GetSecretValue`, com o principal (quem), a ação e o recurso. No passo 3, volta a **OK**. | O segredo continua sendo lido sem a política. | Na mesma conta, sem um `Allow` na identidade (ou no recurso), a negação implícita prevalece. |
| **T08** *(Negativo)* | ⏳ | O `Deny` da política de recurso prevalece sobre o `Allow` da identidade. | Cenário 4 concluído. | 1. Editar a política de recurso e **remover** a linha do `ROLE_APP` da lista `aws:PrincipalArn`. Salvar. 2. Abrir `/?refresh=1`. 3. **Restaurar** a linha e recarregar. | No passo 2: **ERRO** `AccessDeniedException ... with an explicit deny in a resource-based policy`, mesmo com `POLITICA_APP` anexada. No passo 3: **OK**. | Leitura permitida no passo 2. | Na avaliação do IAM, um `Deny` explícito sempre vence um `Allow`. |
| **T09** *(Positivo)* | ✅ **PASS** | A rotação manual cria uma nova versão, e a aplicação a adota sem mudar código. | T03 PASS. | 1. Editar `password` para `<NOVA_SENHA_FICTICIA>`. 2. Aba **Versões**. 3. Abrir `/?refresh=1`. 4. `sudo lab02-sync-db`. 5. Recarregar. | No passo 2: `AWSCURRENT` (nova) e `AWSPREVIOUS` (antiga). No passo 3: Secrets Manager **OK** com a nova versão, e banco **ERRO 1045**. No passo 5: tudo **OK**. | Nenhuma nova versão; o banco aceita a senha nova sem sincronizar; ou continua falhando após a sincronização. | Alterar o segredo não altera o sistema de destino. A rotação automática (Lambda) aplica e testa a senha antes de promovê-la. |
| **T10** *(Negativo)* | ⏳ | Um segredo agendado para exclusão não pode ser lido e pode ser restaurado. | T02 PASS. | 1. **Ações > Excluir segredo**, janela de 7 dias. 2. Abrir `/?refresh=1`. 3. **Cancelar exclusão** e recarregar. | No passo 2: **ERRO** `InvalidRequestException`, informando que o segredo está marcado para exclusão. No passo 3: **OK**, com as mesmas versões. | O segredo continua legível durante a janela, ou não pode ser restaurado. | A janela de recuperação (7 a 30 dias) protege contra exclusões acidentais. |
| **T11** *(Negativo)* | ⏳ | A superfície de rede é mínima. | Cenário 3 concluído. | 1. Em uma rede diferente (ex.: 4G do celular), acessar `http://<IP_PUBLICO_EC2>/`. 2. No seu computador (PowerShell): `Test-NetConnection <IP_PUBLICO_EC2> -Port 22` e `-Port 3306`. | No passo 1: timeout. No passo 2: `TcpTestSucceeded : False` nas duas portas. | Acesso fora do seu IP, ou as portas 22/3306 acessíveis. | O `SG_APP` libera só HTTP 80 do seu IP. O MariaDB escuta apenas em `127.0.0.1`, e o terminal é pelo Session Manager. |

## Evidências da execução

> Adicione aqui as capturas de tela depois de executar os testes. Salve as imagens na pasta `imagens/` e referencie-as como `![descrição](imagens/nome-do-arquivo.png)`. Lembre-se de ocultar o ID da conta, o seu IP e os ARNs reais antes de publicar.

**Execução registrada (T01–T03).** A aplicação **Cofre de Pedidos** respondeu pela porta 80 com os três cartões **OK**:

- **Identidade da instância:** principal `assumed-role/ROLE_APP/i-...`, com credenciais temporárias via IAM Role (sem chave estática na EC2).
- **AWS Secrets Manager:** segredo `prod/app/db` lido por `GetSecretValue`, estágio `AWSCURRENT`, usuário `app_user` e a senha exibida apenas como `••••••••`.
- **Banco de dados (MariaDB local):** conexão realizada com as credenciais do segredo (servidor `10.5.29-MariaDB`), listando os três pedidos de exemplo.

![Página Cofre de Pedidos com os três cartões OK](imagens/imagem%20(1).png)

> A captura da página mostra dados reais da conta (ID no ARN e IP público da EC2). Oculte-os antes de publicar.

**Execução registrada (T05).** No terminal do Session Manager, a sequência de validação confirmou:

- `/var/log/lab02-user-data.log` terminando em `LAB-02: instalação concluída.`;
- `lab02-app` e `mariadb` ambos `active`;
- `Nenhuma credencial estática na instância` (sem `~/.aws`);
- identidade `arn:aws:sts::<ID_CONTA>:assumed-role/ROLE_APP/i-...`;
- `aws secretsmanager list-secrets` retornando `AccessDeniedException ... not authorized to perform: secretsmanager:ListSecrets because no identity-based policy allows the secretsmanager:ListSecrets action`.

O `ListSecrets` negado comprova o menor privilégio: o Role lê apenas o segredo `prod/app/db` (via `GetSecretValue`), sem poder listar os demais.

![Terminal do Session Manager: instalação concluída, serviços ativos, sem credencial estática, ARN do Role e ListSecrets negado](imagens/imagem%20(12).png)

> A saída do terminal mostra o ID da conta no ARN. Oculte-o antes de publicar.

**Execução registrada (T04).** As três buscas pela senha retornaram `0`, confirmando que ela não é exposta:

```bash
curl -s http://127.0.0.1/ | grep -cF '<SENHA>'                      # 0 (HTML da pagina)
sudo journalctl -u lab02-app --no-pager | grep -cF '<SENHA>'        # 0 (log da aplicacao)
sudo grep -cF '<SENHA>' /var/log/lab02-user-data.log               # 0 (log de instalacao)
```
A senha só existe em memória durante a conexão com o banco. A página a exibe apenas como `••••••••`, o user data a envia ao `mysql` pela entrada padrão (sem imprimi-la) e nenhum log a registra.

![Terminal mostrando as três buscas pela senha retornando 0 e o lab02-sync-db sincronizando o usuário](imagens/imagem%20(12).png)

**Execução registrada (T09).** A rotação manual foi validada:

1. A senha do segredo foi editada no Console; na aba **Versões**, a nova versão ficou com `AWSCURRENT` e a anterior com `AWSPREVIOUS`.
2. Antes de sincronizar, a página mostrou o cartão do banco com **ERRO 1045** (segredo novo, senha antiga no banco).
3. `sudo lab02-sync-db` aplicou a nova senha no MariaDB.
4. Ao recarregar, os três cartões voltaram a **OK**, com o cartão do Secrets Manager exibindo a nova versão. A aplicação adotou a nova credencial **sem alteração de código** nem reinício.

Isso evidencia que **alterar o segredo não altera o sistema de destino**: a rotação automática (Lambda) resolveria isso promovendo a nova versão só após aplicá-la e testá-la no banco.

![Antes de sincronizar: cartão do banco em ERRO 1045](imagens/imagem%20(3).png)

![Depois do lab02-sync-db: os três cartões voltam a OK com a nova versão do segredo](imagens/imagem%20(4).png)

**Execução registrada (T06).** O CloudTrail (Histórico de eventos) confirmou a auditoria completa:

- Filtro **Origem do evento** = `secretsmanager.amazonaws.com`: vários `GetSecretValue` com nome de usuário igual ao ID da instância (`i-...`, leituras da aplicação pelo Role) e eventos `DescribeSecret`/`GetResourcePolicy` com o usuário do Console.
- Filtro **Nome do evento** = `Decrypt`: eventos do KMS acompanhando cada leitura. No detalhe de um deles:
  - `eventSource: kms.amazonaws.com`, `eventName: Decrypt`, `readOnly: true`;
  - `invokedBy`, `sourceIPAddress` e `userAgent` iguais a `secretsmanager.amazonaws.com` — a decifragem foi feita **pelo serviço**, não diretamente pela EC2;
  - `arn: .../assumed-role/ROLE_APP/i-...` — a chamada original partiu do Role da instância;
  - `encryptionContext.SecretARN` apontando `prod/app/db` e `SecretVersionId` igual à versão vigente;
  - `resources` com a chave `AWS::KMS::Key` utilizada.

O CloudTrail registra **quem** leu o segredo, **quando** e **com qual chave** ele foi decifrado — sem nunca expor o valor.

![CloudTrail filtrado por secretsmanager.amazonaws.com: GetSecretValue pela instância e ações do admin](imagens/imagem%20(15).png)

![CloudTrail filtrado por Decrypt: eventos do KMS acompanhando cada leitura](imagens/imagem%20(16).png)

![Detalhe de um evento Decrypt: invokedBy secretsmanager, SecretARN, versão e chave KMS](imagens/imagem%20(17).png)

| Teste | Evidência sugerida |
|-------|--------------------|
| T01–T03 | Página **Cofre de Pedidos** com os três cartões **OK** |
| T05 | Terminal do Session Manager com `get-caller-identity` e o `AccessDenied` de `list-secrets` |
| T06 | Evento `Decrypt` no CloudTrail com `invokedBy` |
| T07 / T08 | Cartão do Secrets Manager com `AccessDeniedException` |
| T09 | Aba **Versões** (`AWSCURRENT`/`AWSPREVIOUS`), erro 1045 e saída do `lab02-sync-db` |
| T10 | Erro `InvalidRequestException` e segredo restaurado |
| T11 | Saída do `Test-NetConnection` |
