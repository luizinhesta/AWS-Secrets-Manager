# AWS Secrets Manager — Credenciais de Banco sem Senha no Código: Implantação

> Guia completo, do zero até a limpeza. Este laboratório é **independente**: não reutiliza nenhum recurso de outro laboratório.
>
> Execução manual pelo **Console AWS em português (Brasil)**. A instalação da aplicação na EC2 é feita pelo script de user data [`app/user-data.sh`](app/user-data.sh). Comandos de terminal aparecem apenas para validação e para a rotação manual. Região de referência: `<REGIAO_AWS>` (ex.: `us-east-1`).
>
> 📸 **Capturas desta execução.** Ao final de cada cenário há imagens reais da implantação (pasta [`imagens/`](imagens/)). Elas exibem **dados reais da conta** (ID, ARNs, IP público e ID da instância). **Oculte/borre esses dados antes de publicar** o repositório.

## Nomes dos recursos

Os passos abaixo já usam os **nomes de recurso definitivos** deste laboratório:

- Segredo: `prod/app/db` · banco: `lab02db` · usuário do banco: `app_user` · tabela: `pedidos`
- Política IAM: `POLITICA_APP`
- IAM Role (instance profile) da EC2: `ROLE_APP`
- Security Group da EC2: `SG_APP`
- Nome da instância: `EC2_APP`

Apenas os valores **criados pela AWS** ou **específicos da sua conta** aparecem como marcadores — substitua cada um pelo seu valor real ao executar:

- `<REGIAO_AWS>` — a Região onde você cria todos os recursos (ex.: `us-east-1`).
- `<ID_CONTA>` — o ID de 12 dígitos da sua conta.
- `<SUFIXO_SEGREDO>` — os 6 caracteres que o Secrets Manager acrescenta ao ARN do segredo (ex.: em `prod/app/db-AbC123`, o sufixo é `AbC123`).
- `<ARN_SEGREDO>` — o ARN completo, no formato `arn:aws:secretsmanager:<REGIAO_AWS>:<ID_CONTA>:secret:prod/app/db-<SUFIXO_SEGREDO>`.
- `<MEU_IP>` — seu IP público (use a opção **Meu IP** no Console).
- `<IP_PUBLICO_EC2>` — o IP público atribuído à EC2.
- `<ARN_ADMIN>` — o ARN da identidade que você usa no Console (ver passo 16).
- `<SENHA_FICTICIA>` / `<NOVA_SENHA_FICTICIA>` — senhas fictícias do banco (inicial e a usada na rotação).

> ⚠️ **Nunca** versione identificadores reais da sua conta (ID, ARNs, IP, nome do ambiente ou da permission set de SSO).

## Custos estimados (sem Free Tier)

| Recurso | Cobrança | Referência aproximada |
|---------|----------|-----------------------|
| Segredo no Secrets Manager | por segredo/mês, proporcional às horas | 0,40 USD/mês |
| Chamadas de API do Secrets Manager | por 10.000 chamadas | 0,05 USD (o cache de 60 s da aplicação mantém o volume baixo) |
| EC2 `t3.micro` | por hora em `running` | ~0,02 USD/h (varia por Região) |
| IPv4 público | por hora | 0,005 USD/h |
| EBS gp3 8 GiB (volume raiz) | por GB-mês, proporcional | poucos centavos por dia |
| KMS `aws/secretsmanager`, IAM, Session Manager, histórico do CloudTrail | — | sem custo adicional |

Uma sessão de cerca de 3 horas fica na ordem de **alguns centavos de dólar**. Os preços mudam e variam por Região: confira as páginas oficiais de preços antes de começar. Execute o **Procedimento de Limpeza** ao final.

---

## Cenário 1 — Criar o segredo `prod/app/db`

> ⚠️ **Custo:** a partir daqui o segredo é cobrado enquanto existir.
>
> 🧪 **Testes habilitados por este cenário:** nenhum ainda (o segredo é pré-requisito dos demais). Ver [`TESTES.md`](TESTES.md).

1. **Console AWS > seletor de Região** (canto superior direito). Selecione `<REGIAO_AWS>`. Todos os recursos do laboratório ficam nessa Região.
2. **Secrets Manager > Armazenar um novo segredo.** Tipo: **Outro tipo de segredo**.
3. Na aba **Pares de chave/valor**, adicione:

   | Chave | Valor |
   |-------|-------|
   | `engine` | `mariadb` |
   | `host` | `127.0.0.1` |
   | `port` | `3306` |
   | `dbname` | `lab02db` |
   | `username` | `app_user` |
   | `password` | `<SENHA_FICTICIA>` |

   JSON equivalente (aba **Texto simples**):

   ```json
   {
     "engine": "mariadb",
     "host": "127.0.0.1",
     "port": "3306",
     "dbname": "lab02db",
     "username": "app_user",
     "password": "<SENHA_FICTICIA>"
   }
   ```
   `dbname` e `username` aceitam apenas letras, números e `_`. A senha pode ter caracteres especiais.

4. **Chave de criptografia:** mantenha `aws/secretsmanager`, a chave gerenciada pela AWS, que não tem custo. **Próximo.**
5. **Nome do segredo:** `prod/app/db`. **Descrição:** `Credenciais do banco do Cofre de Pedidos (laboratório)`. Não altere as **Permissões de recurso** agora (isso é feito no Cenário 4). **Próximo.**
6. **Configurar rotação:** mantenha **desativada**. **Próximo > Armazenar.**
7. **Secrets Manager > Segredos > `prod/app/db`.** Na **Visão geral**, copie o **ARN do segredo** e anote-o como `<ARN_SEGREDO>`. O ARN termina em `-<SUFIXO_SEGREDO>`.
8. Na seção **Valor do segredo**, clique em **Recuperar valor do segredo**. Os seis pares aparecem. Na aba **Versões**, há **uma** versão com o rótulo `AWSCURRENT`.

**Evidências — Cenário 1**

![Segredo prod/app/db criado no Secrets Manager, cifrado com aws/secretsmanager](imagens/imagem%20(2).png)

![Valor do segredo em pares chave/valor: engine, host, port, dbname, username e password](imagens/imagem%20(5).png)

---

## Cenário 2 — Identidade da aplicação (IAM)

> 🧪 **Testes habilitados por este cenário:** a política `POLITICA_APP` é a base do **T05** (menor privilégio) e do **T07** (remover a política de identidade e ver a leitura ser negada). Ver [`TESTES.md`](TESTES.md).

9. **IAM > Políticas > Criar política > aba JSON.** Cole a política abaixo, substituindo `<ARN_SEGREDO>` pelo ARN do passo 7:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "LerSomenteOSegredoDaAplicacao",
         "Effect": "Allow",
         "Action": "secretsmanager:GetSecretValue",
         "Resource": "<ARN_SEGREDO>"
       }
     ]
   }
   ```
   **Próximo.** Nome: `POLITICA_APP`. **Criar política.**

   > **Por que não há `kms:Decrypt`?** Com a chave gerenciada `aws/secretsmanager`, a política da própria chave autoriza o uso via Secrets Manager para identidades da conta. Com uma CMK, seria necessário conceder `kms:Decrypt` nessa chave.

10. **IAM > Funções > Criar função.**
    - **Tipo de entidade confiável:** Serviço da AWS. **Caso de uso:** EC2. **Próximo.**
    - **Permissões:** marque `POLITICA_APP` e `AmazonSSMManagedInstanceCore`. **Próximo.**
    - **Nome da função:** `ROLE_APP`. **Criar função.**

    O Console cria junto um **instance profile** com o mesmo nome. A segunda política permite abrir o terminal pelo Session Manager, sem par de chaves e sem a porta 22.

**Evidências — Cenário 2**

![Política POLITICA_APP: Secrets Manager, nível de acesso Leitura](imagens/imagem%20(7).png)

![Função ROLE_APP com as políticas POLITICA_APP e AmazonSSMManagedInstanceCore anexadas](imagens/imagem%20(6).png)

---

## Cenário 3 — Rede, EC2 e aplicação

> ⚠️ **Custo:** a EC2, o volume EBS e o IPv4 público são cobrados por hora.
>
> 🧪 **Testes habilitados por este cenário:** ao fim deste cenário já é possível executar **T01** (aplicação responde na porta 80), **T02** (lê o segredo via IAM Role), **T03** (conecta ao banco), **T04** (a senha não vaza), **T05** (menor privilégio no terminal) e **T11** (superfície de rede mínima). Ver [`TESTES.md`](TESTES.md).

11. **EC2 > Security Groups > Criar grupo de segurança.**
    - **Nome:** `SG_APP`. **Descrição:** `Cofre de Pedidos - HTTP somente do meu IP`. **VPC:** a VPC padrão.
    - **Regras de entrada > Adicionar regra:** Tipo **HTTP**, porta 80, Origem **Meu IP** (gera `<MEU_IP>/32`).
    - **Regras de saída:** mantenha o padrão. **Criar grupo de segurança.**

    Não crie regras para SSH (22) nem para MariaDB (3306).

12. **EC2 > Instâncias > Executar instâncias.**
    - **Nome:** `EC2_APP`.
    - **AMI:** Amazon Linux 2023 (64 bits x86). **Tipo:** `t3.micro`.
    - **Par de chaves:** **Prosseguir sem um par de chaves**. O acesso é pelo Session Manager.
    - **Configurações de rede > Editar:** VPC padrão; uma sub-rede pública; **Atribuir IP público automaticamente: Habilitar**; **Selecionar grupo de segurança existente:** `SG_APP`.
    - **Armazenamento:** 8 GiB gp3 (padrão).
    - **Detalhes avançados:**
      - **Perfil de instância do IAM:** `ROLE_APP`. Ele precisa estar associado já na criação, porque o user data lê o segredo no primeiro boot.
      - **Metadados acessíveis:** Habilitado. **Versão dos metadados:** **Somente V2 (token obrigatório)**.
      - **Dados do usuário:** cole o conteúdo **inteiro** de [`app/user-data.sh`](app/user-data.sh).
    - **Executar instância.**

13. **EC2 > Instâncias > `EC2_APP`.** Aguarde o estado **Executando** e as **verificações de status 3/3**. A instalação costuma levar de 3 a 5 minutos; no primeiro boot, o script espera a rede/DNS ficar pronta antes de instalar os pacotes, então pode demorar um pouco mais. Anote o **Endereço IPv4 público** como `<IP_PUBLICO_EC2>`.

14. **Navegador:** acesse `http://<IP_PUBLICO_EC2>/`. A página **Cofre de Pedidos** mostra três cartões com **OK**:
    - **Identidade da instância:** `arn:aws:sts::<ID_CONTA>:assumed-role/`ROLE_APP`/i-...`, com credenciais temporárias.
    - **AWS Secrets Manager:** o segredo, a versão, o estágio `AWSCURRENT` e o usuário `app_user`. A senha aparece como `••••••••`.
    - **Banco de dados:** conexão realizada e a tabela com 3 pedidos fictícios.

    > A página usa **HTTP** porque o foco aqui é a gestão do segredo e o acesso está restrito ao seu IP. Em produção, publique a aplicação atrás de um ALB com certificado TLS do ACM.

    > 🧪 Este passo é a evidência de **T01, T02 e T03** em [`TESTES.md`](TESTES.md). O **T04** (senha não exposta) também pode ser verificado agora.

15. **Terminal pelo Session Manager:** **EC2 > Instâncias > `EC2_APP` > Conectar > aba Session Manager > Conectar.** Se o botão estiver desabilitado, aguarde 2 a 3 minutos depois do boot. Valide o ambiente:

    ```bash
    export AWS_DEFAULT_REGION=<REGIAO_AWS>
    sudo tail -n 5 /var/log/lab02-user-data.log      # deve terminar com "LAB-02: instalação concluída."
    systemctl is-active lab02-app mariadb            # active / active
    sudo ls -d /root/.aws /home/*/.aws 2>/dev/null || echo "Nenhuma credencial estática na instância"
    aws sts get-caller-identity --query Arn --output text   # assumed-role/`ROLE_APP`/i-...
    aws secretsmanager list-secrets 2>&1 | head -n 2        # AccessDeniedException esperado
    ```

    O `list-secrets` negado comprova o menor privilégio: o Role só consegue ler **um** segredo.

    > 🧪 Este passo é a evidência de **T05** em [`TESTES.md`](TESTES.md).

> **Diagnóstico.** Se algum cartão aparecer com **ERRO** ou a página não abrir:
> - Leia `/var/log/lab02-user-data.log` (fim do arquivo). Se terminar em `LAB-02: instalação concluída.`, a instalação foi bem-sucedida.
> - Se o log mostrar `No match for argument: mariadb105-server` ou `Could not resolve host: ...amazonlinux...`, o `dnf` rodou antes da rede/DNS subir. A versão atual do script aguarda a rede e repete o `dnf`; se ainda assim falhar, rode manualmente pelo Session Manager: `sudo dnf -y install mariadb105-server python3 python3-pip`, seguido de `sudo bash /var/lib/cloud/instance/scripts/part-001` para reexecutar o restante.
> - Se o Role foi associado **depois** da criação da instância, rode `sudo lab02-sync-db` e `sudo systemctl restart lab02-app`.
> - Confira se a origem da regra HTTP 80 do `SG_APP` ainda corresponde ao seu IP atual (IPs residenciais mudam).

**Evidências — Cenário 3**

![VPC com sub-redes públicas usada pelo laboratório](imagens/imagem%20(9).png)

![Security Group SG_APP com regra de entrada HTTP 80 somente do meu IP](imagens/imagem%20(8).png)

![Instância EC2_APP em execução: Amazon Linux 2023, t3.micro, IMDSv2 obrigatório, função do IAM ROLE_APP](imagens/imagem%20(10).png)

![Página Cofre de Pedidos com os três cartões OK: identidade, Secrets Manager e banco de dados](imagens/imagem%20(1).png)

---

## Cenário 4 — Política de recurso no segredo

> 🧪 **Testes habilitados por este cenário:** **T08** (remover o Role da lista `aws:PrincipalArn` e ver o `Deny` explícito prevalecer sobre o `Allow` da identidade). Ver [`TESTES.md`](TESTES.md).

16. **Descubra `<ARN_ADMIN>`.** Abra o **CloudShell** (ícone `>_` no topo do Console) e execute `aws sts get-caller-identity --query Arn --output text`. Converta o resultado:
    - **Usuário IAM:** use o ARN como veio, por exemplo `arn:aws:iam::<ID_CONTA>:user/<NOME>`.
    - **Usuário raiz:** `arn:aws:iam::<ID_CONTA>:root`.
    - **Função assumida ou IAM Identity Center** (`arn:aws:sts::<ID_CONTA>:assumed-role/<NOME_FUNCAO>/<SESSAO>`): use `arn:aws:iam::<ID_CONTA>:role/*<NOME_FUNCAO>`. O `*` cobre o caminho `aws-reserved/...` das funções do Identity Center.

17. **Secrets Manager > `prod/app/db` > Visão geral > Permissões de recurso > Editar permissões.** Cole e **Salve**:

    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "NegarLeituraForaDasIdentidadesEsperadas",
          "Effect": "Deny",
          "Principal": "*",
          "Action": "secretsmanager:GetSecretValue",
          "Resource": "*",
          "Condition": {
            "StringNotLike": {
              "aws:PrincipalArn": [
                "arn:aws:iam::<ID_CONTA>:role/`ROLE_APP`",
                "<ARN_ADMIN>"
              ]
            }
          }
        }
      ]
    }
    ```

    Em uma política de recurso, `"Resource": "*"` se refere ao **próprio segredo**. O `Deny` atinge apenas a leitura do valor. Se você errar o `<ARN_ADMIN>`, ainda consegue editar ou excluir esta política.

18. **Validação:** recarregue `http://<IP_PUBLICO_EC2>/?refresh=1` e veja o cartão do Secrets Manager **OK** (com origem `Secrets Manager (GetSecretValue)`, confirmando a releitura pela API já com o `Deny` ativo). Depois clique em **Recuperar valor do segredo** no Console, que também deve funcionar. As duas identidades estão na lista. O teste negativo dessa política está em [`TESTES.md`](TESTES.md) (T08).

**Evidências — Cenário 4**

![CloudShell: aws sts get-caller-identity retornando o ARN de SSO usado como identidade de admin](imagens/imagem%20(11).png)

![Política de recurso do segredo: Deny com StringNotLike aws:PrincipalArn para ROLE_APP e o admin](imagens/imagem%20(13).png)

![Aplicação OK após salvar a política de recurso: o Role continua lendo o segredo (releitura via GetSecretValue)](imagens/imagem%20(14).png)

---

## Cenário 5 — Rotação manual e versionamento

> 🧪 **Testes habilitados por este cenário:** **T09** (editar a senha cria `AWSCURRENT`/`AWSPREVIOUS`; a aplicação adota o novo valor após o `lab02-sync-db`, sem mudar código). Ver [`TESTES.md`](TESTES.md).

19. **Secrets Manager > `prod/app/db` > Recuperar valor do segredo > Editar.** Altere `password` para `<NOVA_SENHA_FICTICIA>` e clique em **Salvar**. Na aba **Versões**, a nova versão fica com `AWSCURRENT` e a anterior com `AWSPREVIOUS`.
20. **Navegador:** abra `http://<IP_PUBLICO_EC2>/?refresh=1`.
    - O cartão do Secrets Manager mostra a **nova versão**.
    - O cartão do banco mostra **ERRO** `(1045, "Access denied for user 'app_user'@'localhost' ...")`.

    O segredo mudou, mas o banco ainda tem a senha antiga. **Alterar o segredo não altera a senha no sistema de destino.**
21. **Session Manager:** execute `sudo lab02-sync-db`. A saída é `Usuário 'app_user' sincronizado com a versão ... (AWSCURRENT).`
22. **Navegador:** recarregue a página. Os três cartões voltam a **OK**, sem reiniciar a aplicação nem alterar código.

> **Rotação automática (conceitual, não provisionada).** Uma função Lambda de rotação executa as etapas `createSecret`, `setSecret`, `testSecret` e `finishSecret` em um intervalo configurado. A nova senha fica como `AWSPENDING` até ser aplicada e testada no banco, e só então é promovida a `AWSCURRENT`. Isso elimina a janela de falha vista no passo 20. Para Amazon RDS e Aurora, a rotação é gerenciada pela AWS.

**Evidências — Cenário 5**

![Após editar o segredo e antes de sincronizar: cartão do banco em ERRO 1045 (senha antiga no MariaDB)](imagens/imagem%20(3).png)

![Terminal do Session Manager: sudo lab02-sync-db aplicando a nova senha (versão AWSCURRENT) no banco](imagens/imagem%20(12).png)

![Após sincronizar: os três cartões voltam a OK, com o Secrets Manager já na nova versão](imagens/imagem%20(4).png)

---

## Cenário 6 — Auditoria no CloudTrail

> 🧪 **Testes habilitados por este cenário:** **T06** (o segredo é cifrado em repouso e a decifragem é auditada: eventos `GetSecretValue` e `Decrypt` com `invokedBy`). Ver [`TESTES.md`](TESTES.md).

23. **CloudTrail > Histórico de eventos.** Os eventos podem levar alguns minutos para aparecer.
    - **Filtro "Origem do evento" = `secretsmanager.amazonaws.com`:** aparecem `GetSecretValue`, com o usuário `ROLE_APP/i-...`, e `PutSecretValue`, que é a sua edição do passo 19.
    - **Filtro "Nome do evento" = `Decrypt`:** são eventos do KMS em que o registro mostra `"invokedBy": "secretsmanager.amazonaws.com"`. Eles comprovam a decifragem feita pelo serviço no momento da leitura.

    O histórico registra **quem** leu o segredo e **quando**, mas nunca o valor.

**Evidências — Cenário 6**

![CloudTrail filtrado por secretsmanager.amazonaws.com: GetSecretValue pela instância e DescribeSecret/GetResourcePolicy pelo admin](imagens/imagem%20(15).png)

![CloudTrail filtrado por Decrypt: eventos do KMS acompanhando cada leitura, com usuário igual ao ID da instância](imagens/imagem%20(16).png)

![Detalhe de um evento Decrypt: invokedBy secretsmanager.amazonaws.com, SecretARN e versão, chave KMS e readOnly true](imagens/imagem%20(17).png)

---

## Cenário 7 — Exclusão agendada e restauração

> 🧪 **Testes habilitados por este cenário:** **T10** (o segredo agendado para exclusão não pode ser lido — `InvalidRequestException` — e pode ser restaurado). Ver [`TESTES.md`](TESTES.md).

24. **Secrets Manager > `prod/app/db` > Ações > Excluir segredo.** Período de espera: `7` dias. **Agendar exclusão.** O segredo passa a mostrar a data de exclusão.
25. **Navegador:** abra `/?refresh=1`. O cartão do Secrets Manager mostra **ERRO** `InvalidRequestException`, informando que o segredo está marcado para exclusão.
26. **Secrets Manager > Segredos.** Se o segredo não aparecer na lista, ative a opção de exibir os segredos agendados para exclusão. Abra `prod/app/db` e clique em **Cancelar exclusão**. Recarregue a aplicação: tudo volta a **OK**. O valor e as versões são preservados.

> **Exclusão imediata** (sem janela) não está disponível no Console. Ela exige CLI ou SDK, e é **irreversível**:
> `aws secretsmanager delete-secret --secret-id prod/app/db --force-delete-without-recovery --region <REGIAO_AWS>`

---

## Procedimento de Limpeza (ordem por dependência)

- **L1. EC2 > Instâncias > `EC2_APP` > Estado da instância > Encerrar.** O volume raiz é excluído junto, porque "Excluir no encerramento" vem marcado por padrão. O IPv4 público é liberado.
- **L2. EC2 > Security Groups.** Exclua `SG_APP`, depois que a instância estiver **Encerrada**.
- **L3. IAM > Funções.** Exclua `ROLE_APP`. O instance profile de mesmo nome é removido junto.
- **L4. IAM > Políticas.** Exclua `POLITICA_APP`.
- **L5. Secrets Manager > `prod/app/db` > Ações > Excluir segredo.** Use uma janela de 7 dias, ou a exclusão imediata via CloudShell (comando acima) se quiser recriar `prod/app/db` em seguida. Um segredo agendado para exclusão **bloqueia a criação de outro com o mesmo nome**.
- **L6. Verificação final:**
  - nenhuma instância `EC2_APP` em execução;
  - `SG_APP`, `ROLE_APP` e `POLITICA_APP` ausentes;
  - o segredo excluído ou agendado para exclusão.

---

## Checklist de validação rápida

- [ ] Página `http://<IP_PUBLICO_EC2>/` com os três cartões **OK** e a senha mascarada.
- [ ] `list-secrets` negado na EC2 e nenhuma credencial em `~/.aws`.
- [ ] Política de recurso com `Deny` ativa, com a aplicação e o Console ainda lendo o segredo.
- [ ] Rotação manual: erro 1045 antes do `lab02-sync-db` e **OK** depois; versões `AWSCURRENT`/`AWSPREVIOUS`.
- [ ] `GetSecretValue` e `Decrypt` visíveis no CloudTrail.
- [ ] Exclusão agendada bloqueia a leitura, e o cancelamento restaura.
- [ ] Limpeza concluída.
