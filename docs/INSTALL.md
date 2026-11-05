# Instalação e operação

## Fluxo do instalador

1. Valida o host (`aarch64`) e o cliente ARM64 nativo em
   `~/.local/share/Steam/steamrtarm64`. Se ele ainda não existe, chama
   `droiddeck-steam-install` e pede para abrir a Steam uma vez.
2. Baixa `slsteam-arm64.zip` e `lumen-arm64.zip` do release `slsteam-arm64`,
   conferindo o `.sha256` de cada um. Um checksum divergente é fatal; um sidecar
   ausente é aceito.
3. Recusa qualquer coisa que não seja ELF **aarch64** — o instalador lê o
   `e_machine` direto do header, porque as imagens LinuxFS nem sempre têm
   `file(1)`.
4. Instala SLSsteam em `~/.local/share/SLSsteam`, Lumen em
   `~/.local/share/Lumen` e o plugin em `~/.local/share/Lumen/luatools`,
   preservando `backend/data` e `backend/api.json`.
5. Troca o launcher por um wrapper `steam` → `steam.real` e instala o hook em
   `droiddeck-steam-install`.
6. Restaura o `droiddeck-steam-x64` caso uma instalação antiga o tenha patchado.
7. Verifica arquiteturas, wrapper, `-noverifyfiles` e hook.

## A troca do launcher (wrapper)

O cliente ARM64 do DroidDeck também é usado pelo Gamescope, então a injeção
precisa estar no próprio binário do cliente, não num atalho de desktop:

```
steamrtarm64/steam        script (wrapper)
steamrtarm64/steam.real   ELF aarch64 original, intacto
```

O wrapper (`~/.local/share/SLSsteam/steam-wrapper`, copiado para
`steamrtarm64/steam`):

| Passo | Motivo |
|---|---|
| limpa `LD_AUDIT` herdado | o auditor só pode aparecer uma vez; uma cópia herdada carregaria o SLSsteam duas vezes |
| exporta `LD_AUDIT=<SLSsteam.so>` | é assim que o SLSsteam entra em `steamclient.so`/`steamui.so`/`libtier0_s.so` |
| cria `.cef-enable-remote-debugging` na raiz da Steam | `droiddeck-session:108` checa exatamente esse caminho; quando existe, ele não passa `-cef-enable-debugging` próprio e o port fica livre para o Lumen |
| inicia o Lumen | com `env -u LD_AUDIT -u LD_PRELOAD -u LD_LIBRARY_PATH` e `setsid`, para não morrer junto com o cliente |
| escreve `cef_port` | contrato lido por `lua/cefport.lua`: `porta` + `owner <pid> <starttime>` |
| adiciona `-noverifyfiles` | sem isso o self-check vê um script no lugar do binário, rebaixa o cliente e sai com 42 |
| `exec steam.real "$@"` | o `$$` do wrapper vira o pid do cliente, e o registro `owner` continua válido |

O `-shutdown` é repassado sem injeção: parar a Steam não deve iniciar o Lumen
nem reescrever o contrato de porta.

### Contrato `cef_port`

`~/.local/share/Lumen/cef_port` tem duas linhas:

```
8080
owner 12345 9876543
```

A porta vem de `BL_CDP_PORT` (exportada por `droiddeck-session`), com fallback
em 8080 e validação em `1024..65535`. O `starttime` é o campo 22 de
`/proc/<pid>/stat`; comparado com o processo vivo, ele invalida um contrato
deixado por uma sessão anterior. Como `comm` pode conter espaços, o campo é
contado a partir do **último** token terminado em `)`.

## Persistência depois de updates do cliente

Não existe systemd no guest. O DroidDeck roda
`/usr/local/bin/droiddeck-steam-install` no começo da sessão e depois de
atualizar o cliente; esse script restaura o binário da Valve em
`steamrtarm64/steam`. O instalador insere um bloco marcado, logo depois de

```bash
chmod +x "$steam_root/steamrtarm64/steam" 2>/dev/null || true
```

que executa `$HOME/.local/share/SLSsteam/apply-wrap.sh`. O `apply-wrap.sh` é
idempotente:

- `steam` já é o wrapper e `steam.real` existe → só reescreve o wrapper (pega
  versões novas do instalador);
- `steam` é ELF da Valve → move para `steam.real` (sobrescrevendo o antigo) e
  instala o wrapper;
- `steam` não é wrapper nem ELF → recusa e sai sem tocar em nada.

O `--uninstall` remove o bloco do hook e devolve `steam.real` para `steam`.

## Migração da instalação antiga

Uma instalação x86-64 anterior deixou dados em `~/.droiddeck-x64`. O instalador
apenas **copia o que ainda não existe**:

| Origem | Destino |
|---|---|
| `~/.droiddeck-x64/.config/SLSsteam/config.yaml` | `~/.config/SLSsteam/config.yaml` |
| `~/.droiddeck-x64/.local/share/Lumen/luatools/backend/data/` | `~/.local/share/Lumen/luatools/backend/data/` |

Nada é apagado de `~/.droiddeck-x64`.

## Lumen

O asset publicado é construído do `swwayps/lumen@52475c3` e recebe
`patches/lumen-aarch64.patch`, que faz cinco coisas:

| Arquivo | Ajuste |
|---|---|
| `lua/loop.lua` | o cliente roda como `steam.real`; a checagem de liveness testa os dois nomes (`lua/proc.lua` é o scanner genérico e não é editado) |
| `lua/slscheck.lua` | `STEAM_COMMS = {"steam", "steam.real"}` na detecção do SLSsteam |
| `lua/restart_steam.sh` | `pgrep`/`pkill -x '(steam\|steam\.real)'` e reconhece o wrapper como launcher |
| `lua/about.lua` | Update All executa a cópia local em `~/.local/share/Lumen/install.sh` (que o instalador deixa lá), não o instalador i386 upstream |
| `lua/slsconfig.lua` | esconde chaves que o SLSsteam aarch64 não lê |

O instalador reaplica as edições de `about.lua` como fallback idempotente, para
o caso de o usuário rodar um Lumen vanilla.

## Diagnóstico

```bash
# O launcher está com o wrapper?
head -n 3 ~/.local/share/Steam/steamrtarm64/steam

# A Steam está rodando com o cliente nativo?
pid=$(pgrep -x steam.real | head -n1)

# O SLSsteam entrou no processo?
grep -m1 SLSsteam /proc/$pid/maps
tail -n 20 ~/.SLSsteam.log     # espera-se "SLSsteam (arm64 -> arm64) loading in steam"

# O Lumen está rodando?
pgrep -af 'Lumen/lumen'
tail -n 50 ~/.local/share/Lumen/lumen.log

# Contrato do CEF
cat ~/.local/share/Lumen/cef_port

# Forçar uma sessão sem injeção
SLS_DISABLE=1 steam
```

O hash do `steamclient.so` do DroidDeck não está na lista homologada do
SLSsteam: o log emite um aviso de hash desconhecido, mas as 14 assinaturas casam
de forma única e o plugin carrega normalmente.

## Rebuild dos assets

O CI (`.github/workflows/build-slsteam-arm64.yml`, runner `ubuntu-24.04-arm`)
faz tudo:

```bash
build/build-slsteam-arm64.sh      # pin 7f59509 + patch + libs + link + zip
build/build-lumen-arm64.sh        # clone 52475c3 + make + patch lua/ + zip
tools/check_patterns.py <patterns.cpp> <steamclient.so> --arch aarch64
```

Localmente, `LIBS_CACHE=<dir>` reaproveita os `.a` já compilados e
`tools/fetch_steam_aarch64.py <dir>` baixa o cliente ARM64 atual do CDN da Valve
para validar as assinaturas.

## Testes

```bash
bash tests/test-install.sh
```

Testes offline: fixtures de ELF sintético, sem download e sem `pgrep`/`zip`
(o zip dos fixtures é criado por `tests/mkzip.py`). Cobrem instalação de
SLSsteam/Lumen/plugin, wrapper, hook, migração, preservação de dados e
`--uninstall`. Roda tanto em Linux quanto em Git Bash.
