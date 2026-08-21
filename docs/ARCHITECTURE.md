# Arquitetura do ShellOps

O ShellOps mantém separação simples entre apresentação e lógica funcional:

```text
bin/shellops
    ↓
tui/main.sh
    ↓
modules/*.sh
    ↓
discovery/target e integrações consultivas
    ↓
scripts legados explicitamente controlados
```

## Bootstrap

`bin/shellops` resolve a raiz do projeto, carrega `lib/version.sh`, trata
`--help`/`--version`, carrega bibliotecas e módulos e inicia a TUI. Somente
`dialog` é validado como dependência da interface completa.

## TUI

`tui/main.sh` cuida de navegação, coleta de parâmetros, seleção de targets,
confirmações e apresentação. Comandos funcionais permanecem nos módulos.

## Módulos

Cada arquivo em `modules/` representa uma área funcional reutilizável por uma
futura CLI. Dependências FEATURE são verificadas na operação que as utiliza.

## Discovery e target

`modules/discovery.sh` produz registros no formato:

```text
source|type|name|image|state|health|pid|metadata
```

O target selecionado usa uma única representação global `SHELLOPS_TARGET_*`.
O diagnóstico roteia tipos conhecidos para módulos especializados e conserva
fallback genérico para alvos desconhecidos.

## Scripts legados

`install/`, `maintenance/` e `analysis/` contêm rotinas operacionais reais. Um
legado somente é executado por wrapper explícito após classificação de impacto.
Instalações AppManager/TIE e limpezas destrutivas permanecem desabilitadas na
v1.0; suas análises consultivas não fazem `source` nem executam o script.

`install.sh` é exclusivamente o instalador do próprio ShellOps e não executa
scripts operacionais em `install/`.

