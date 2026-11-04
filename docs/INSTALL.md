# Instalação e operação

## Fluxo

1. O instalador valida o host (`aarch64`), o launcher
   `/usr/local/bin/droiddeck-steam-x64`, o cliente `steamrt64/steamclient.so` e
   o rootfs FEX (`~/.droiddeck-x64/rootfs/usr/bin/env`).
2. Se o cliente x86-64 ainda não existe, chama `droiddeck-steam-x64 --prepare`
   (baixa FEX, rootfs e cliente; pode demorar).
3. Instala dependências de build via `pacman` quando faltam (`base-devel`,
   `lua54`, `curl`, `openssl`, `unzip`, `python`, `file`).
4. Baixa e instala o `slsteam-x86_64.zip` do release; se indisponível e
   `--build` foi passado, compila dentro do rootfs FEX com `apt` + `make`.
5. Baixa o source do Lumen, compila para aarch64 e instala em
   `~/.droiddeck-x64/.local/share/Lumen`.
6. Baixa o plugin `luatools-linux.zip` e o 7zz aarch64.
7. Aplica o bloco `SLSSTEAM-X64-INJECT` em `droiddeck-steam-x64` (backup em
   `.luatools-orig`).
8. Verifica arquiteturas e presença dos arquivos.

## Por que `FEX /usr/bin/env LD_AUDIT=...`

O `LD_AUDIT` é lido pelo `ld.so` **do guest**. Se a variável fosse exportada no
shell aarch64, qualquer processo ARM iniciado depois tentaria carregar um `.so`
x86-64 e falharia; se fosse exportada no processo do FEX, o loader aarch64
falharia antes do FEX iniciar. Passá-la como argumento do `env` do guest
(`FEX /usr/bin/env LD_AUDIT=... steam`) coloca a variável apenas no ambiente do
processo x86-64.

O `library-inject.so` do branch `dev-X86_64` é um arquivo vazio (o helper
`la_objsearch` foi desativado). Por isso o `LD_AUDIT` lista apenas o
`SLSsteam.so`; se um build futuro trouxer um `library-inject.so` ELF64 real, o
instalador o inclui automaticamente.

## Lumen nativo, Steam sob FEX

O bloco do launcher inicia o Lumen **antes** do `exec` do FEX, com o ambiente
limpo de `LD_AUDIT`/`LD_PRELOAD`/`LD_LIBRARY_PATH` e com `HOME=$X64_HOME` (o
próprio `x64_env` do DroidDeck já exporta isso). Isso é o que faz os caminhos
`~/.local/share/...` usados pelo Lumen apontarem para a árvore x86-64:

- `$HOME/.local/share/SLSsteam` (shim de restart e config);
- `$HOME/.local/share/CloudRedirect`;
- `$HOME/.local/share/Steam` (o cliente x86-64, não o ARM).

O instalador ajusta o Lumen para o ambiente emulado:

| Arquivo | Ajuste |
|---|---|
| `lua/proc.lua` | reconhece o cliente pelo cmdline (`/steam` em argv), já que `comm` é `FEXInterpreter`; vale também para `steamwebhelper` |
| `lua/restart_steam.sh` | `sls_steam_alive`/`sls_signal_steam` casam o processo FEX do guest |
| `lua/about.lua` | Update All aponta para este repositório, não para o instalador i386 |

O shim `SLSsteam/path/steam` restaura o `HOME` externo antes de chamar o
launcher (o Lumen roda com `HOME=$X64_HOME`); sem isso o restart criaria um
`~/.droiddeck-x64` aninhado e baixaria um segundo cliente.

## 7zz e CloudRedirect CLI

O plugin traz `backend/bin/7zz` **x86-64**; o backend roda no Lumen aarch64, então
o instalador o substitui pelo 7zz oficial aarch64 (ou por um shim para o
`p7zip`). O `cloud_redirect_cli` também é x86-64: fica em
`cloud_redirect_cli.bin` e o caminho `cloud_redirect_cli` é um wrapper que o
executa pelo FEX com o rootfs do DroidDeck.

Reinstalar o plugin **preserva** `backend/data` (configurações, APIs, lista de
appids) e migra o antigo `backend/api.json` para dentro de `data`.

## Caminhos

| Item | Caminho |
|---|---|
| Home x86-64 | `~/.droiddeck-x64` (ou `BL_X64_HOME`) |
| Cliente | `~/.droiddeck-x64/.local/share/Steam/steamrt64` |
| Rootfs FEX | `~/.droiddeck-x64/rootfs` |
| SLSsteam | `~/.droiddeck-x64/.local/share/SLSsteam` |
| Lumen | `~/.droiddeck-x64/.local/share/Lumen` |
| Config SLS | `~/.droiddeck-x64/.config/SLSsteam/config.yaml` |
| Launcher patchado | `/usr/local/bin/droiddeck-steam-x64` |
| Backup do launcher | `/usr/local/bin/droiddeck-steam-x64.luatools-orig` |

## Diagnóstico

```bash
# O launcher está patchado?
grep -n 'SLSSTEAM-X64-INJECT' /usr/local/bin/droiddeck-steam-x64

# A Steam x86-64 está rodando?
pgrep -af 'steamrt64/steam'

# O SLSsteam entrou no processo?
pid=$(pgrep -f 'steamrt64/steam' | head -n1)
grep -m3 -E 'SLSsteam|library-inject' /proc/$pid/maps

# O Lumen está rodando?
pgrep -af 'Lumen/lumen'
tail -50 ~/.droiddeck-x64/.lumen.log

# Forçar uma sessão sem injeção
SLS_DISABLE=1 steam
```

## Depois de uma atualização do DroidDeck

Uma atualização pode sobrescrever `/usr/local/bin/droiddeck-steam-x64`. Rode o
instalador de novo; ele é idempotente e reaplica o bloco sem duplicar.
