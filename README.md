<img src="assets/icon.svg" width="64" height="64" alt="">

# luatools-aarch64

Instalador do **LuaTools + SLSsteam + Lumen** para o cliente Steam **aarch64
nativo** do [DroidDeck](https://github.com/Droid-Deck/DroidDeck).

O DroidDeck traz um cliente Steam ARM64 próprio em
`~/.local/share/Steam/steamrtarm64/`. É esse cliente que este projeto usa —
tanto no desktop quanto ao apertar *play* direto no DroidDeck (Gamescope). O
cliente x86-64 emulado por FEX **não** é usado nem alterado.

## Pré-requisitos

1. DroidDeck com o cliente ARM64 já baixado: abra a Steam uma vez pelo ícone
   normal e deixe `~/.local/share/Steam/steamrtarm64/steamclient.so` aparecer.
2. Terminal dentro do desktop Linux do DroidDeck (host aarch64).

O instalador escreve tudo dentro de `$HOME` (DroidDeck LinuxFS). A única exceção
é `/usr/local/bin/droiddeck-steam-install`, que recebe o bloco de hook marcado
(editado de forma idempotente; ver abaixo).

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/DaniloSkyrim/luatools-aarch64/main/install.sh | bash
```

Depois disso, abra a Steam pelo ícone normal do DroidDeck. Nada mais é
necessário: o wrapper injeta o SLSsteam, inicia o Lumen e mantém tudo isso
depois de atualizações do cliente Steam.

```bash
bash install.sh --uninstall   # restaura o launcher e remove SLSsteam/Lumen
bash install.sh --help
```

Reinstalar é seguro e idempotente: `backend/data` (configurações, APIs, lista de
appids) e `backend/api.json` são preservados.

## Como funciona

O instalador troca o launcher do cliente por um wrapper:

```
steamrtarm64/steam        -> script (wrapper do SLSsteam)
steamrtarm64/steam.real   -> cliente aarch64 original, intacto
```

O wrapper, a cada abertura da Steam:

1. limpa qualquer `LD_AUDIT` herdado e exporta `LD_AUDIT=<SLSsteam.so>`;
2. garante o flag `.cef-enable-remote-debugging` na raiz da Steam (é o caminho
   que o `droiddeck-session` checa antes de mexer no port do DevTools);
3. inicia o Lumen com o ambiente limpo de injeção;
4. publica o contrato `cef_port` (porta + `owner <pid> <starttime>`) que o
   Lumen lê para anexar ao CEF do cliente;
5. adiciona `-noverifyfiles` e executa `steam.real`.

Como o wrapper é um script, o self-check do cliente tentaria baixar a Steam de
novo e sairia com código 42 — daí o `-noverifyfiles` sempre presente.

Um **hook idempotente** em `/usr/local/bin/droiddeck-steam-install` reaplica o
wrapper depois de cada atualização do cliente (o DroidDeck roda esse script no
início da sessão e após updates). Não há systemd no guest; o hook é o
mecanismo de persistência.

## O que é instalado

| Componente | Destino | Arch |
|---|---|---|
| SLSsteam | `~/.local/share/SLSsteam` | aarch64 |
| Lumen | `~/.local/share/Lumen` | aarch64 |
| Plugin LuaTools | `~/.local/share/Lumen/luatools` | texto |
| 7zz do backend | `.../luatools/backend/bin/7zz` | aarch64 |
| Wrapper | `.../steamrtarm64/steam` | script |
| Hook de update | `/usr/local/bin/droiddeck-steam-install` | bloco idempotente |

Configuração do SLSsteam: `~/.config/SLSsteam/config.yaml` (migrada da árvore
antiga `~/.droiddeck-x64` quando existir).

## Por que um port aarch64

O SLSsteam upstream não tem suporte a aarch64: o `Makefile` força `-m32`, a
tabela de assinaturas descreve o cliente i386 e `lib/` só traz arquivos i386.
Este repositório carrega o port em `patches/slsteam-aarch64.patch`, aplicado
sobre `AceSLS/SLSsteam@7f59509` (commit pinado), e produz o binário no CI.

O ponto crítico do port é a assinatura `CUser::UpdateAppOwnershipTicket`: o
cliente arm64 mudou os últimos bytes, e como `Patterns::init()` zera **todas**
as addresses quando uma pattern obrigatória falha, uma única assinatura errada
desliga o plugin inteiro. A correção troca o final `F9 6B 04 A9` por wildcards
(mesmo comprimento, aplicável in-place).

## Assinaturas verificadas

O CI valida cada pattern contra o `steamclient.so` aarch64 vivo, baixado do CDN
da Valve por `tools/fetch_steam_aarch64.py`:

```
unique=14 ambiguous=0 missing=0
```

## Release

O workflow `.github/workflows/build-slsteam-arm64.yml` roda em
`ubuntu-24.04-arm` e publica em `releases/tag/slsteam-arm64`:

| Asset | Conteúdo |
|---|---|
| `slsteam-arm64.zip` | `SLSsteam.so` (aarch64), `config.yaml`, `version.txt`, `LICENSE` |
| `lumen-arm64.zip` | `lumen` (aarch64) + `lua/` |
| `*.sha256` | checksums verificados pelo instalador |

As quatro bibliotecas estáticas (`libmem`, `capstone`+`keystone`+`LLVM`,
`yaml-cpp`, `protobuf`, `LuaJIT`) são compiladas do zero em runner ARM nativo e
cacheadas entre execuções — elas **precisam** ser `EM_AARCH64`, e os `.a` i386
que acompanham o upstream não servem.

## Verificação

```bash
pid=$(pgrep -x steam.real | head -n1)
grep -m1 SLSsteam /proc/$pid/maps
tail -n 20 ~/.SLSsteam.log

pgrep -af 'Lumen/lumen'
tail -n 50 ~/.local/share/Lumen/lumen.log
```

O log do SLSsteam deve conter `SLSsteam (arm64 -> arm64) loading in steam` e
`Loaded successfully`.

Para desativar a injeção numa sessão: `SLS_DISABLE=1 steam`.

## Limitações

- Só o cliente ARM64 nativo é suportado. O modo x86-64 sob FEX continua
  funcionando sem o LuaTools; se uma instalação antiga tiver deixado o launcher
  `droiddeck-steam-x64` patchado, o instalador restaura o original (backup em
  `.luatools-orig`) para não haver dois Lumens competindo.
- O hash do `steamclient.so` do DroidDeck não está na lista de hashes
  homologados do SLSsteam, então o log emite um aviso. As 14 assinaturas casam
  de forma única, então o aviso é inofensivo.
- `la_activity`/`la_symbind64`/`la_objclose` ausentes no binário: não são
  fatais (glibc 2.43).

## Estrutura

```
install.sh                        instalador único
patches/slsteam-aarch64.patch     port aarch64 do SLSsteam
patches/lumen-aarch64.patch       ajustes do Lumen para steam.real
build/build-slsteam-arm64.sh      build + validação + empacotamento
build/build-lumen-arm64.sh        build + empacotamento do Lumen
.github/workflows/                CI no runner ARM64 que publica a release;
                                  tests.yml roda a suíte offline em Linux
tools/check_patterns.py           validador de assinaturas (--arch aarch64|x86)
tools/fetch_steam_aarch64.py      baixa o steamclient.so arm64 do CDN
tests/test-install.sh             testes offline do instalador
docs/INSTALL.md                   detalhes operacionais
```

## Créditos e licenças

- SLSsteam — AceSLS e contribuidores, AGPL-3.0 (compilado, não vendorizado).
- Lumen e LuaTools — swwayps, conforme os repositórios originais.
- DroidDeck — Droid-Deck, GPL-3.0.
- 7-Zip — Igor Pavlov, LGPL-2.1 com restrição unRAR.
