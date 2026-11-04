<img src="assets/icon.svg" width="64" height="64" alt="">

# luatools-aarch64

Instalador do **LuaTools + SLSsteam + Lumen** para o ambiente de desktop do
[DroidDeck](https://github.com/Droid-Deck/DroidDeck) em ARM64.

O DroidDeck roda o cliente Steam **x86-64** (`steamrt64/steam`) sob FEX quando
o modo x86-64 está ativado. Este projeto usa esse modo: o SLSsteam é o build
x86-64 da branch upstream `AceSLS/SLSsteam@dev-X86_64`, o Lumen é recompilado
para aarch64 (ele só conversa com a Steam por CDP/RPC em loopback) e o plugin
LuaTools é arch-neutral.

## Pré-requisitos

1. DroidDeck com o **cliente Steam x86-64 ativado**.
2. A Steam x86-64 aberta pelo menos uma vez (o DroidDeck baixa `steamrt64`,
   o FEX e o rootfs Ubuntu 24.04 nessa primeira execução).
3. O instalador roda dentro do desktop Linux do DroidDeck (host aarch64, Arch
   Linux ARM).

## Estado verificado (2026-11-04)

Já verificado neste repositório:

- Os **17/17** padrões da branch `dev-X86_64` casam de forma única no
  `steamrt64/steamclient.so` atual (build-id `1a5890ef…`); ver
  `tools/check_patterns.py` e `reference/steam-x86_64-target` na memória.
- O bloco de injeção foi aplicado ao `droiddeck-steam-x64` **real** e o script
  resultante passa em `bash -n`; o patch é idempotente e reversível.
- O instalador passa nos testes offline (`bash tests/test-install.sh`).

Ainda depende de execução real (não há toolchain Linux x86-64 nesta máquina):

- A primeira execução do workflow de build (compila a branch `dev-X86_64`).
- A validação em um dispositivo DroidDeck (injeção no guest FEX e Lumen).

## Publicação única (build do SLSsteam x86-64)

Não existe binário x86-64 pronto: os releases oficiais do SLSsteam são i386.
O workflow `.github/workflows/build-slsteam-x86_64.yml` compila a branch
`dev-X86_64` em `ubuntu-22.04` e publica o asset estável:

```
https://github.com/DaniloSkyrim/luatools-aarch64/releases/download/slsteam-x86_64/slsteam-x86_64.zip
```

Antes de publicar, ajuste `REPO_SLUG` no topo de `install.sh` (ou passe
`LUA_TOOLS_REPO=owner/repo`). Depois, rode o workflow uma vez em **Actions →
build-slsteam-x86_64 → Run workflow**.

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/DaniloSkyrim/luatools-aarch64/main/install.sh | bash
```

Opções:

```bash
bash install.sh --build       # compila o SLSsteam no próprio dispositivo (lento)
bash install.sh --uninstall   # remove SLSsteam, Lumen e o patch
bash install.sh --help
```

## O que é instalado

| Componente | Destino | Arch |
|---|---|---|
| SLSsteam | `~/.droiddeck-x64/.local/share/SLSsteam` | x86-64 (FEX guest) |
| Lumen | `~/.droiddeck-x64/.local/share/Lumen` | aarch64 nativo |
| Plugin LuaTools | `~/.droiddeck-x64/.local/share/Lumen/luatools` | texto |
| 7zz do backend | `.../luatools/backend/bin/7zz` | aarch64 |
| CloudRedirect | `.../.local/share/CloudRedirect` | x86-64 (best-effort) |

O instalador aplica um bloco idempotente em `/usr/local/bin/droiddeck-steam-x64`
que, antes do `exec` final do FEX:

1. inicia o Lumen nativamente (sem `LD_AUDIT`/`LD_PRELOAD` do guest);
2. executa `FEX /usr/bin/env LD_AUDIT=.../SLSsteam.so steamrt64/steam`.

O `LD_AUDIT` lista **apenas** o `SLSsteam.so`: o `library-inject.so` do branch
`dev-X86_64` é um arquivo vazio (helper desativado) e quebraria o loader.

O `LD_AUDIT` é passado como argumento do `env` **do guest**: o processo FEX do
host nunca o vê, então o loader aarch64 não tenta carregar um `.so` x86-64.

## Verificação

```bash
pgrep -af 'SLSsteam|Lumen/lumen'
pid=$(pgrep -f 'steamrt64/steam' | head -n1)
grep -m1 SLSsteam /proc/$pid/maps
```

Log do Lumen: `~/.droiddeck-x64/.lumen.log`.

Para desativar a injeção numa sessão: `SLS_DISABLE=1 steam`.

## Limitações desta versão

- **CloudRedirect é best-effort.** O CI tenta um build x86-64 (o hook resolve
  a vtable por RTTI e a árvore tem branches `__x86_64__`); se o build ou o hook
  não funcionarem, o instalador deixa a aba de cloud saves desativada e o
  restante do LuaTools segue funcionando.
- A branch `dev-X86_64` é o SLSsteam upstream, não o fork `slsteam-moon`:
  o catálogo de assinaturas, o contrato de porta CEF e alguns fixes do fork
  moon não existem nela. O plugin e o Lumen continuam instalados.
- A Steam roda emulada pelo FEX; o cliente ARM64 nativo do DroidDeck não é
  alterado e continua utilizável sem o LuaTools.

## Estrutura

```
install.sh                       instalador único
build/build-slsteam-x86_64.sh    build do SLSsteam x86-64 (usado no CI)
.github/workflows/               build + release do asset x86-64
docs/INSTALL.md                  detalhes operacionais
tools/                           ferramentas de análise usadas no port
```

## Créditos e licenças

- SLSsteam — AceSLS e contribuidores, AGPL-3.0 (baixado e compilado, não
  vendorizado).
- Lumen e LuaTools — swwayps, conforme os repositórios originais.
- DroidDeck — Droid-Deck, GPL-3.0.
- 7-Zip — Igor Pavlov, LGPL-2.1 com restrição unRAR.
