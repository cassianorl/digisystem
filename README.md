# ShellOps

ShellOps é uma TUI em Bash para suporte, troubleshooting, coleta de evidências e
operações controladas em ambientes TASY sobre Linux RHEL-based.

Versão: **1.0.0**  
Release status: **RC1** — testes obrigatórios em Linux real ainda estão pendentes.

## Plataformas alvo

- Oracle Linux 8/9
- AlmaLinux 8/9
- RHEL 8/9
- Rocky Linux 8/9 quando compatível

## Instalação

Em um checkout confiável do projeto, execute como root:

```bash
./install.sh --check
./install.sh install
```

O instalador do ShellOps cria ou atualiza `/opt/shellops`, preserva o repositório
Git e cria `/usr/local/bin/shellops`. Atualizações usam somente
`git pull --ff-only` e são recusadas quando existem alterações locais.

Os scripts em `install/` têm finalidades operacionais diferentes e não são
executados pelo instalador do ShellOps.

## Execução

```bash
shellops
shellops --help
shellops --version
```

## Menu principal

1. Diagnóstico
2. TASY / AppManager
3. Docker / Containers
4. Java / Tomcat
5. TIE / Integrações
6. Oracle / Conectividade
7. Logs e Coletas
8. Certificados
9. Ferramentas Linux
0. Sair

## Classes de operação

- **CONSULTA:** somente leitura.
- **ALTERAÇÃO:** modifica configuração ou gera artefato local conhecido.
- **MANUTENÇÃO:** pode remover dados, reiniciar componentes ou causar impacto.
- **DRY-RUN:** análise consultiva; o legado não é executado.
- **PREPARAR:** avalia pré-requisitos sem executar a ação final.

Alterações e manutenções devem mostrar alvo e impacto antes da confirmação.
Operações destrutivas nunca são implícitas.

## Dependências

CORE para iniciar a TUI:

- Bash
- dialog
- utilitários básicos do sistema

Dependências FEATURE habilitam áreas específicas, sem bloquear o ShellOps:

- Docker: Docker, TIE e aplicações TASY em containers
- OpenSSL: certificados e TLS
- keytool: JKS
- sqlplus/tnsping/lsnrctl: Oracle
- jcmd/jstack: Java avançado
- chronyc: detalhes NTP
- Samba: provisionamento Samba

Sysstat, xmllint, tracepath/traceroute, dig, nc e ethtool são opcionais. O
inventário do host está em `Ferramentas Linux > Dependências`.

## Áreas funcionais

- **TASY/AppManager:** descoberta, status, configuração segura, datasource,
  HAProxy/Keepalived, JMX, logs e checklist. Instalação permanece DRY-RUN.
- **TIE:** componentes, conectividade, RabbitMQ, MongoDB, Elastic Stack,
  evidências de eventos e checklist. Instalação permanece DRY-RUN.
- **Docker:** inventário, diagnóstico, logs, stats, mounts, rede, healthcheck e
  análise de limpeza. O legado destrutivo não é executado.
- **Java/Tomcat:** JVMs, heap, threads, JMX, portas, GC/OOM, logs e thread dump.
  Heap dump permanece apenas PREPARAR.
- **Oracle:** client, TNS/listener, conectividade e templates SQL read-only.
- **Certificados:** PEM, DER, PKCS#12/PFX/P12, JKS, cadeia, chave e TLS remoto.
- **Logs/Coletas:** consultas seguras, TasyReports e Support Bundle restrito.
- **Ferramentas Linux:** sistema, performance, serviços, rede, storage/LVM,
  locale/time/NTP e provisionamento Samba explicitamente classificado.

## Segurança

O ShellOps não deve exibir ou persistir senhas, tokens ou private keys. Não usa
`eval`, não executa comandos construídos a partir de texto do usuário e não
coleta Docker `Config.Env` integralmente.

O Support Bundle não inclui automaticamente:

- logs arbitrários de aplicação;
- credenciais, secrets ou `Config.Env`;
- certificados e chaves;
- thread dumps ou heap dumps;
- SQL text ou payload BIFROST.

A inspeção por padrões é somente uma barreira adicional e não prova que um
artefato está livre de secrets.

## Limitações e validação antes do release final

Antes da tag `v1.0.0`, validar em Oracle Linux 9, AlmaLinux 9 ou equivalente:

- instalação e atualização em `/opt/shellops`;
- Docker daemon e permissões de acesso;
- systemd e journalctl;
- sysstat;
- jcmd/jstack e JVM em container;
- keytool e conversões JKS;
- sqlplus, tnsping e lsnrctl;
- permissões POSIX de artefatos sensíveis;
- HAProxy/Keepalived;
- Samba em host descartável.

## Backlog pós-v1.0

- execução segura dos instaladores AppManager e TIE;
- execução integrada das limpezas Docker e MongoDB;
- heap dump executável;
- SQL Oracle avançado;
- Elasticsearch autenticado;
- transferência SCP/SFTP;
- Support Bundle avançado;
- automação de CI e release.

Consulte [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) para a estrutura interna.

