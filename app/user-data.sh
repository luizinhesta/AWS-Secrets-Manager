#!/bin/bash
# User data do laboratório AWS Secrets Manager (Amazon Linux 2023).
# Instala MariaDB local, a aplicação "Cofre de Pedidos" (Python, porta 80) e o
# utilitário lab02-sync-db. Nenhuma senha fica no script: as credenciais são
# lidas do segredo prod/app/db usando o IAM Role da instância.
# Log: /var/log/lab02-user-data.log
set -euxo pipefail
exec > >(tee /var/log/lab02-user-data.log) 2>&1

SECRET_ID="prod/app/db"
APP_DIR="/opt/lab02"

# 0. Esperar rede e DNS (no primeiro boot o dnf pode rodar antes da rede subir)
# Token do IMDSv2 com novas tentativas (o serviço de metadados pode demorar).
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
  [ -n "$TOKEN" ] && break
  sleep 5
done

meta() {
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1"
}

# Região descoberta pelo IMDSv2 (nada fixo no script)
REGIAO=$(meta placement/region)

# Esperar a resolução de DNS do endpoint de pacotes antes de usar o dnf.
for _ in $(seq 1 30); do
  if getent hosts amazonlinux.$REGIAO.amazonaws.com >/dev/null 2>&1 \
     || curl -s -o /dev/null https://amazonlinux.$REGIAO.amazonaws.com; then
    break
  fi
  echo "Aguardando rede/DNS..."
  sleep 5
done

# 1. Pacotes do sistema
# No Amazon Linux 2023: servidor MariaDB = mariadb105-server; o venv vem com
# o python3, e o pip é instalado pelo pacote python3-pip. dnf com retry para
# tolerar o espelho ainda indisponível nos primeiros segundos de boot.
dnf clean all
for tentativa in $(seq 1 10); do
  if dnf -y --setopt=retries=10 --setopt=timeout=30 install \
       mariadb105-server python3 python3-pip; then
    break
  fi
  echo "dnf install falhou (tentativa $tentativa/10). Nova tentativa em 15 s."
  sleep 15
done

# Falha explícita se os pacotes essenciais não foram instalados.
command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1 || {
  echo "ERRO: servidor MariaDB nao foi instalado (verifique rede/DNS e o repositorio)."
  exit 1
}

# MariaDB acessível apenas localmente (nunca exposto na rede)
cat > /etc/my.cnf.d/lab02.cnf <<'EOF'
[mysqld]
bind-address=127.0.0.1
EOF
systemctl enable --now mariadb

# 2. Ambiente Python isolado (versões fixadas)
useradd --system --no-create-home --shell /sbin/nologin lab02app || true
mkdir -p "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet "boto3==1.34.0" "PyMySQL==1.1.1"

# Configuração sem segredos (apenas região e nome do segredo)
cat > "$APP_DIR/lab02.env" <<EOF
AWS_DEFAULT_REGION=$REGIAO
SECRET_ID=$SECRET_ID
CACHE_TTL=60
PORTA=80
EOF

# 3. Sincronizador do banco (simula as etapas setSecret/finishSecret da rotação)
cat > "$APP_DIR/sync_db.py" <<'EOF'
"""Alinha o usuario do MariaDB com a versao AWSCURRENT do segredo.
A senha vai ao cliente mysql pela entrada padrao e nunca e impressa."""
import json, os, re, subprocess, sys
import boto3

SECRET_ID = os.environ.get("SECRET_ID", "prod/app/db")
IDENTIFICADOR = re.compile(r"^[A-Za-z0-9_]{1,32}$")


def literal(valor):
    """Escapa um valor como literal SQL entre aspas simples."""
    return "'" + str(valor).replace("\\", "\\\\").replace("'", "\\'") + "'"


def main():
    resp = boto3.client("secretsmanager").get_secret_value(SecretId=SECRET_ID)
    dados = json.loads(resp["SecretString"])
    banco, usuario, senha = dados["dbname"], dados["username"], dados["password"]
    if not (IDENTIFICADOR.match(banco) and IDENTIFICADOR.match(usuario)):
        sys.exit("dbname e username devem conter apenas letras, números e _ (até 32).")

    sql = [f"CREATE DATABASE IF NOT EXISTS `{banco}`;",
           "DROP USER IF EXISTS ''@'localhost';"]
    for host in ("localhost", "127.0.0.1"):
        conta = f"{literal(usuario)}@'{host}'"
        sql += [f"CREATE USER IF NOT EXISTS {conta} IDENTIFIED BY {literal(senha)};",
                f"ALTER USER {conta} IDENTIFIED BY {literal(senha)};",
                f"GRANT SELECT ON `{banco}`.* TO {conta};"]
    sql += [f"CREATE TABLE IF NOT EXISTS `{banco}`.pedidos ("
            "id INT PRIMARY KEY, cliente VARCHAR(60), produto VARCHAR(60), valor DECIMAL(10,2));",
            f"INSERT IGNORE INTO `{banco}`.pedidos VALUES "
            "(1,'Cliente Exemplo A','Notebook',4599.90),"
            "(2,'Cliente Exemplo B','Monitor',1299.00),"
            "(3,'Cliente Exemplo C','Teclado',249.90);",
            "FLUSH PRIVILEGES;"]
    subprocess.run(["mysql", "-u", "root"], input="\n".join(sql), text=True, check=True)
    print(f"Usuário '{usuario}' sincronizado com a versão {resp['VersionId']} "
          f"({', '.join(resp.get('VersionStages', []))}).")


if __name__ == "__main__":
    main()
EOF

# Atalho: sudo lab02-sync-db
cat > /usr/local/bin/lab02-sync-db <<'EOF'
#!/bin/bash
set -a; . /opt/lab02/lab02.env; set +a
exec /opt/lab02/venv/bin/python /opt/lab02/sync_db.py
EOF
chmod 755 /usr/local/bin/lab02-sync-db

# 4. Aplicação web "Cofre de Pedidos"
cat > "$APP_DIR/app.py" <<'EOF'
"""Cofre de Pedidos (laboratorio AWS Secrets Manager).
Fluxo: IAM Role -> GetSecretValue -> KMS -> MariaDB local -> pagina.
A senha nunca aparece na pagina nem no log."""
import html, json, os, threading, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import boto3, pymysql
from botocore.exceptions import BotoCoreError, ClientError

SECRET_ID = os.environ.get("SECRET_ID", "prod/app/db")
CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
PORTA = int(os.environ.get("PORTA", "80"))

sm = boto3.client("secretsmanager")
sts = boto3.client("sts")
_trava = threading.Lock()
_cache = {"valor": None, "lido_em": 0.0}

CSS = (
    ":root{color-scheme:dark}*{box-sizing:border-box;margin:0;padding:0}"
    'body{font-family:"Segoe UI",system-ui,sans-serif;background:linear-gradient(135deg,#141e30,#243b55);'
    "color:#f5f7fa;min-height:100vh;padding:32px 16px}main{max-width:920px;margin:0 auto}"
    "header{margin-bottom:24px}h1{font-size:28px;margin-bottom:6px}header p{color:#c7d2da}"
    ".grade{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:16px}"
    ".cartao{background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.15);"
    "border-radius:14px;padding:18px 20px;margin-bottom:16px}"
    ".cartao h2{font-size:17px;margin-bottom:10px;display:flex;justify-content:space-between;gap:8px}"
    ".selo{font-size:12px;font-weight:700;padding:3px 10px;border-radius:999px}"
    ".ok .selo{background:#2ecc71;color:#06301a}.erro .selo{background:#ff6b6b;color:#3a0505}"
    "dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 12px;font-size:14px}"
    "dt{color:#9fb3c8}dd{word-break:break-all}"
    "pre{white-space:pre-wrap;word-break:break-word;font-size:13px;color:#ffd4d4}"
    "table{width:100%;border-collapse:collapse;font-size:14px}"
    "th,td{text-align:left;padding:8px;border-bottom:1px solid rgba(255,255,255,.12)}th{color:#9fb3c8}"
    "a.botao{display:inline-block;margin-top:8px;background:#4dabf7;color:#04223a;font-weight:700;"
    "padding:8px 14px;border-radius:8px;text-decoration:none}"
    "a.botao:focus,a.botao:hover{outline:3px solid #fff}"
    "footer{margin-top:12px;font-size:12px;color:#9fb3c8}"
)


def ler_segredo(forcar=False):
    """Retorna (valor, origem). Mantém cache em memória por CACHE_TTL segundos."""
    with _trava:
        agora = time.time()
        if not forcar and _cache["valor"] and agora - _cache["lido_em"] < CACHE_TTL:
            return _cache["valor"], f"cache em memória (lido há {int(agora - _cache['lido_em'])} s)"
        resp = sm.get_secret_value(SecretId=SECRET_ID)
        valor = {
            "dados": json.loads(resp["SecretString"]),
            "arn": resp["ARN"],
            "versao": resp["VersionId"],
            "estagios": resp.get("VersionStages", []),
            "lido_em": datetime.now(timezone.utc).strftime("%d/%m/%Y %H:%M:%S UTC"),
        }
        _cache.update(valor=valor, lido_em=agora)
        return valor, "Secrets Manager (GetSecretValue)"


def consultar_banco(dados):
    conexao = pymysql.connect(host=dados["host"], port=int(dados.get("port", 3306)),
                              user=dados["username"], password=dados["password"],
                              database=dados["dbname"], connect_timeout=5)
    try:
        with conexao.cursor() as cursor:
            cursor.execute("SELECT VERSION()")
            versao = cursor.fetchone()[0]
            cursor.execute("SELECT id, cliente, produto, valor FROM pedidos ORDER BY id")
            return versao, cursor.fetchall()
    finally:
        conexao.close()


def montar_estado(forcar):
    estado = {"identidade": None, "segredo": None, "origem": None, "banco": None, "erros": {}}
    try:
        estado["identidade"] = sts.get_caller_identity()["Arn"]
    except (ClientError, BotoCoreError) as erro:
        estado["erros"]["iam"] = str(erro)
    try:
        segredo, origem = ler_segredo(forcar)
    except (ClientError, BotoCoreError, ValueError) as erro:
        estado["erros"]["segredo"] = str(erro)
        return estado
    estado["segredo"], estado["origem"] = segredo, origem
    try:
        estado["banco"] = consultar_banco(segredo["dados"])
    except pymysql.err.OperationalError as erro:
        # Falha de autenticação com valor em cache: relê o segredo uma vez (padrão após rotação).
        if erro.args and erro.args[0] == 1045 and not forcar:
            return montar_estado(True)
        estado["erros"]["banco"] = str(erro)
    except (pymysql.MySQLError, KeyError, ValueError) as erro:
        estado["erros"]["banco"] = f"{type(erro).__name__}: {erro}"
    return estado


def reais(valor):
    """Formata um número no padrão brasileiro (1.234,56)."""
    return f"{valor:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def cartao(titulo, ok, corpo):
    classe, selo = ("ok", "OK") if ok else ("erro", "ERRO")
    return (f'<section class="cartao {classe}" aria-label="{html.escape(titulo)}: {selo}">'
            f'<h2>{html.escape(titulo)} <span class="selo">{selo}</span></h2>{corpo}</section>')


def pagina(estado):
    e = html.escape
    erros = estado["erros"]
    blocos = []

    if estado["identidade"]:
        blocos.append(cartao("Identidade da instância", True,
                             f"<dl><dt>Principal</dt><dd>{e(estado['identidade'])}</dd>"
                             "<dt>Credenciais</dt><dd>temporárias, via IAM Role (instance profile)</dd></dl>"))
    else:
        blocos.append(cartao("Identidade da instância", False, f"<pre>{e(erros.get('iam', ''))}</pre>"))

    if estado["segredo"]:
        s = estado["segredo"]
        d = s["dados"]
        blocos.append(cartao("AWS Secrets Manager", True,
                             f"<dl><dt>Segredo</dt><dd>{e(SECRET_ID)}</dd>"
                             f"<dt>Versão</dt><dd>{e(s['versao'])}</dd>"
                             f"<dt>Estágios</dt><dd>{e(', '.join(s['estagios']))}</dd>"
                             f"<dt>Usuário</dt><dd>{e(str(d.get('username', '')))}</dd>"
                             "<dt>Senha</dt><dd>•••••••• (nunca exibida)</dd>"
                             f"<dt>Origem</dt><dd>{e(estado['origem'])}</dd>"
                             f"<dt>Lido em</dt><dd>{e(s['lido_em'])}</dd></dl>"))
    else:
        blocos.append(cartao("AWS Secrets Manager", False, f"<pre>{e(erros.get('segredo', ''))}</pre>"))

    if estado["banco"]:
        versao, linhas = estado["banco"]
        corpo_tabela = "".join(
            f"<tr><td>{e(str(i))}</td><td>{e(c)}</td><td>{e(p)}</td><td>R$ {reais(v)}</td></tr>"
            for i, c, p, v in linhas)
        blocos.append(cartao("Banco de dados (MariaDB local)", True,
                             f"<p>Conectado com as credenciais do segredo. Servidor {e(versao)}.</p><br>"
                             "<table><caption class='sr'>Pedidos de exemplo</caption>"
                             "<thead><tr><th scope='col'>ID</th><th scope='col'>Cliente</th>"
                             "<th scope='col'>Produto</th><th scope='col'>Valor</th></tr></thead>"
                             f"<tbody>{corpo_tabela}</tbody></table>"))
    elif "banco" in erros:
        blocos.append(cartao("Banco de dados (MariaDB local)", False, f"<pre>{e(erros['banco'])}</pre>"))

    agora = datetime.now(timezone.utc).strftime("%d/%m/%Y %H:%M:%S UTC")
    return (f"<!doctype html><html lang='pt-br'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            f"<title>Cofre de Pedidos</title><style>{CSS} .sr{{position:absolute;left:-9999px}}</style></head>"
            "<body><main><header><h1>Cofre de Pedidos</h1>"
            "<p>Credenciais do banco lidas no AWS Secrets Manager, sem senha no código ou no servidor.</p>"
            "<a class='botao' href='/?refresh=1'>Forçar nova leitura do segredo</a></header>"
            f"<div class='grade'>{''.join(blocos[:2])}</div>{''.join(blocos[2:])}"
            f"<footer>Cache do segredo: {CACHE_TTL} s · Página gerada em {agora}</footer>"
            "</main></body></html>")


class Handler(BaseHTTPRequestHandler):
    server_version = "CofreDePedidos/1.0"

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/health":
            self._responder(200, "application/json", json.dumps({"status": "ok"}))
        elif url.path == "/":
            forcar = parse_qs(url.query).get("refresh") == ["1"]
            self._responder(200, "text/html; charset=utf-8", pagina(montar_estado(forcar)))
        else:
            self._responder(404, "text/plain; charset=utf-8", "Não encontrado")

    def _responder(self, codigo, tipo, corpo):
        dados = corpo.encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(dados)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(dados)

    def log_message(self, formato, *args):
        # Registra apenas método/caminho/código; nunca dados do segredo.
        print(f"{self.address_string()} {formato % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORTA), Handler).serve_forever()
EOF

# 5. Serviço systemd (usuário sem privilégios, só com permissão de abrir a porta 80)
cat > /etc/systemd/system/lab02-app.service <<'EOF'
[Unit]
Description=Cofre de Pedidos (laboratorio AWS Secrets Manager)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
User=lab02app
EnvironmentFile=/opt/lab02/lab02.env
ExecStart=/opt/lab02/venv/bin/python /opt/lab02/app.py
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 6. Primeira sincronização do banco com o segredo (com novas tentativas)
for tentativa in $(seq 1 12); do
  if /usr/local/bin/lab02-sync-db; then
    break
  fi
  echo "Segredo ainda inacessível (tentativa $tentativa/12). Nova tentativa em 10 s."
  sleep 10
done

systemctl daemon-reload
systemctl enable --now lab02-app
echo "LAB-02: instalação concluída."
