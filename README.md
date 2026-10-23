# szczur-radar-monitor

Zewnętrzny monitor wdrożeń projektu [szczur-radar](https://github.com/kwmacioszek/szczur-radar)
na Railway. Odpowiada na jedno pytanie: czy usługa po deployu wstała i odpowiada.

## Architektura

1. Railway wysyła webhook każdego zdarzenia deployu projektu szczur-radar (także PR envów)
   z nagłówkiem `X-Monitor-Secret` do Cloudflare Workera z katalogu `worker/`.
2. Worker sprawdza sekret, projekt, typ zdarzenia i format pól, a finalne zdarzenia deployu
   (`Deployment.deployed`, `redeployed`, `failed`, `crashed`, `oom_killed`) przekazuje przez
   `workflow_dispatch` do workflow `verify.yml` w tym repo; resztę pomija.
3. Railway dostaje 2xx dopiero, gdy GitHub przyjął dispatch; inaczej 502 i Railway ponawia.
4. `verify.yml` czyta z Railway stan wdrożonej usługi, a dla API i weba sonduje `/api/ready`,
   `/healthz` i `/`; kończy się zielono albo czerwono.
5. Na produkcji czerwony run otwiera lub komentuje jedno issue `deploy-health` na usługę,
   przypisane do operatora, i wysyła alarm do Telegrama; pierwszy zielony run tej usługi zamyka
   issue. W środowiskach PR sygnałem jest tylko wynik runu (bez issue i bez alarmu).

Monitor tylko czyta stan w Railway i sonduje publiczny origin weba. Niczego nie wdraża i niczego
nie zmienia w szczur-radar; nie zastępuje deploy guarda ani reguły no-merge z szczur-radar.

## Jak run ocenia usługę

`verify.yml` (`workflow_dispatch`, wejścia z Workera: `event_type`, `environment_id`,
`environment_name`, `service_name`, `deployment_id`) uruchamia `verifier/verify.sh`. Run ocenia
**usługę, która się wdrożyła**, nie całe środowisko, i zawsze bieżący stan, nie treść webhooka.

1. Stan: `railway deployment list --json -s <usługa>` w danym środowisku (token workspace,
   `RAILWAY_PROJECT_ID` + ID środowiska, nigdy `railway link`). Liczy się najnowszy deploy wg
   `createdAt` poza `SKIPPED`, `REMOVED` i `REMOVING`. Nowszy deploy `WAITING`, `QUEUED` albo
   `NEEDS_APPROVAL` (np. kolejny push czekający na CI) też się nie liczy, chyba że to deploy
   z webhooka: jeszcze nie wystartował, więc ocenia się ten, który działa, a jego własny webhook
   da osobny run.

   | Stan | Wynik |
   | --- | --- |
   | `SUCCESS`, `SLEEPING` | OK |
   | `FAILED`, `CRASHED` | czerwony |
   | `BUILDING`, `DEPLOYING`, `INITIALIZING`, `QUEUED`, `WAITING`, `NEEDS_APPROVAL` | pytanie co 10 s; po 5 min (`SETTLE_TIMEOUT`) czerwony „nieweryfikowalne” |
   | brak deployu, nieznany stan, Railway nie odpowiada do końca okna (wywołanie `railway` albo `gh` dłuższe niż 60 s, `CLI_TIMEOUT`, liczy się jako nieudane) | czerwony |
   | Railway odrzuca token (`Unauthorized`) | od razu czerwony „nieweryfikowalne: token Railway odrzucony”, bez ponowień; wymień token (`SECURITY.md`) |

2. Usługi gotowości (`READINESS_SERVICES`, domyślnie `szczur-radar-api,szczur-radar-web`): po stanie
   OK sondy przez origin weba środowiska (`verifier/web-url.sh`), każda ponawiana w jednym oknie
   3 min (`WAKE_TIMEOUT`, budzenie uśpionego API):
   - `GET /api/ready` → 200 (API sięga bazy),
   - `GET /healthz` → 200 (Caddy żyje),
   - `GET /` → 200, `text/html` z odwołaniem do `/assets/` (SPA naprawdę serwowane).
3. Każda inna usługa (crony `pipeline-trigger`, `db-backup`, baza `postgres`): tylko stan jej
   deployu, bez sond. Run API lub weba nigdy nie czyta stanu innych usług, a run innej usługi nie
   czyta stanu API ani weba.

**Zielony** = stan OK i (dla usługi gotowości) wszystkie sondy przeszły. Inaczej **czerwony**
(`exit 1`). Błędy po starcie (wyjątki w logach, awarie w ruchu) są poza zakresem. Kody wyjścia
`verify.sh`: 0 zielony, 1 czerwony (także nieweryfikowalny, błąd Railway albo `gh`), 2 złe wejście
lub brak zmiennej. Raport (środowisko, usługa, zdarzenie, stan, sondy, link do runu, bez sekretów)
trafia do podsumowania runu i do issue.

Konsekwencja dla cronów: nocne wykonanie crona, które kończy się `CRASHED`, wysyła webhook
`Deployment.crashed`, więc daje czerwony run i issue **tego crona**. Nie wpływa na wynik deployu API
ani weba i nie dotyka ich issue.

## Issue

Tylko produkcja. W środowisku PR run kończy się samym wynikiem (zielony albo czerwony w Actions),
bez issue i bez alarmu. Na produkcji jedno otwarte issue na **usługę** w tym repo: etykieta `deploy-health`, tytuł
`Niezdrowe wdrożenie: <środowisko> / <usługa>`, przypisane do `MONITOR_ASSIGNEE` (push w GitHub
Mobile). Issue jest szukane po `<środowisko> / <usługa>` jako całych słowach, więc
`szczur-radar-pr-8` nigdy nie pasuje do `szczur-radar-pr-81`.

| Wynik runu | Issue tej usługi |
| --- | --- |
| czerwony, brak issue | nowe, z raportem, przypisane do operatora |
| czerwony, issue otwarte | komentarz z raportem (najstarsze otwarte) |
| zielony, issue otwarte | komentarz „zielone po deployu `<id>`” i zamknięcie |
| zielony, brak issue | nic (tylko odczyt listy issue) |

Zielony deploy weba nie zamyka issue API ani crona. Runy jednego środowiska idą w kolejce
(`concurrency` `env-<id środowiska>`, `queue: max`, bez `cancel-in-progress`), więc issue nie ściga
się samo ze sobą; duplikaty webhooków dają po prostu kolejny run z tym samym wynikiem.

## Alarm w Telegramie (tylko produkcja)

Czerwony run środowiska `production` wysyła też zdarzenie do checka healthchecks.io
`production/deploy-health` (kanał alarmowy szczur-radar F-04, checki zakłada `tools/healthchecks/checks.sh`
w szczur-radar): `/fail` z treścią `DEPLOY_UNHEALTHY (<środowisko> / <usługa>): <stan>; run <link>`
(`text/plain`, do 1000 znaków), a po 2xx sukces z `ok`. Telegram pokazuje „down” z tą treścią i zaraz
„up”; stan awarii trzyma issue, nie check. PR envy nie dają ani alarmu, ani issue. Jedna próba na żądanie (połączenie
5 s, żądanie 10 s); błąd healthchecks.io to ostrzeżenie w logu runu i nigdy nie zmienia wyniku. Bez
sekretu `HEALTHCHECK_PING_URL` alarm nie jest wysyłany.

## Ograniczenia

- Railway wysyła webhooki best-effort. Zgubiony webhook albo przepełnienie kolejki środowiska
  (ponad 100 oczekujących runów; nadmiar GitHub anuluje) pomija weryfikację tego deployu. Wtedy
  uruchom `verify.yml` ręcznie (Actions → verify → Run workflow, gałąź `main`) z danymi usługi:
  typ zdarzenia, ID i nazwa środowiska, nazwa usługi, ID deployu. ID i nazwę środowiska kopiuj
  razem z jednego źródła (`railway environment list --json`, tabela w issue albo raport runu):
  stan czytany jest po ID, a sondy i issue idą po nazwie, więc ich pomyłka miesza dwa środowiska.
- Środowisko spoza `production` i `szczur-radar-pr-<N>` nie ma znanego adresu weba, więc deploy
  API lub weba w nim jest czerwony „nieweryfikowalne”.

## Weryfikator lokalnie

```bash
verifier/test.sh                     # stuby railway, gh i weba; bez Dockera i sieci
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.11.0 verifier/*.sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
```

`actionlint` nie zna jeszcze klucza `concurrency.queue` (GitHub dodał go 2026-05-07), więc
`.github/actionlint.yaml` ignoruje tylko ten jeden komunikat w `verify.yml`.

`ci.yml` (`pull_request`, `push` na `main`) uruchamia testy weryfikatora, `shellcheck` oraz testy
i typy Workera, bez środowiska i sekretów.

## Worker

| Żądanie | Odpowiedź |
| --- | --- |
| inna ścieżka lub metoda niż `POST /railway` | 404 |
| brak lub zły `X-Monitor-Secret` | 401 |
| niepoprawny JSON albo pola w złym formacie (UUID id, nazwy `[a-z0-9-]{1,64}`) | 400 |
| inny projekt Railway albo typ zdarzenia spoza listy | 204, bez dispatchu |
| dispatch przyjęty przez GitHub | 202 |
| GitHub odpowiada inaczej niż 2xx, błąd sieci, brak tokena GitHub | 502 |
| brak `WEBHOOK_SECRET` / `RAILWAY_PROJECT_ID` albo zły `GITHUB_REPO` | 500 |

Worker nie loguje sekretów ani treści żądania.

```bash
cd worker
npm ci
npm test            # Vitest, fetch zamockowany
npx tsc --noEmit    # typy
```

Lokalnie (`wrangler dev`): sekrety w `worker/.dev.vars` (ignorowany przez git), np.

```
WEBHOOK_SECRET=lokalny-sekret
```

## Uruchomienie

Jednorazowo, przez operatora (albo agenta na jego wyraźne polecenie). Żaden sekret nie trafia do
repo ani do logów.

1. **Repo**: `kwmacioszek/szczur-radar-monitor`, publiczne. Na `main` ruleset: bez force-push i
   usuwania, zmiany tylko przez PR. Runy z forków wymagają zatwierdzenia (wszyscy zewnętrzni
   kontrybutorzy), domyślne uprawnienia `GITHUB_TOKEN` tylko do odczytu.
2. **Środowisko GitHub `monitor`**: deployment branches tylko `main`, sekret `RAILWAY_API_TOKEN`
   (dedykowany token workspace Railway, osobny od tokena CI szczur-radar):
   `gh secret set RAILWAY_API_TOKEN --env monitor --repo kwmacioszek/szczur-radar-monitor`
   (wartość z promptu, nie z argumentu).
3. **Zmienne repo**: `RAILWAY_PROJECT_ID`, `READINESS_SERVICES`
   (`szczur-radar-api,szczur-radar-web`), `MONITOR_ASSIGNEE` (login operatora).
4. **Worker**: `cd worker && npx wrangler login`, potem `npx wrangler deploy` i sekrety
   `npx wrangler secret put WEBHOOK_SECRET` (losowe, ≥32 bajty) oraz
   `npx wrangler secret put GITHUB_DISPATCH_TOKEN` (fine-grained PAT: tylko to repo,
   Actions: read and write, z datą wygaśnięcia).
5. **Webhook Railway** na projekcie szczur-radar: URL `https://<worker>.workers.dev/railway`,
   nagłówek `X-Monitor-Secret` = `WEBHOOK_SECRET`, PR envy włączone, zdarzenia `Deployment.*`
   przekazywane przez Worker. To jedyna zmiana w projekcie Railway.

Wycofanie: wyłącz lub usuń webhook w Railway; Worker i repo mogą zostać.

## Sekrety i uprawnienia

| Nazwa | Gdzie | Uprawnienia |
| --- | --- | --- |
| `WEBHOOK_SECRET` | sekret Workera (`wrangler secret put`), nagłówek webhooka w Railway | losowy ciąg, tylko do uwierzytelnienia webhooka |
| `GITHUB_DISPATCH_TOKEN` | sekret Workera | fine-grained PAT: tylko to repo, **Actions: write**, z datą wygaśnięcia |
| `RAILWAY_PROJECT_ID`, `GITHUB_REPO` | `[vars]` w `worker/wrangler.toml` | wartości publiczne, nie sekrety |
| `RAILWAY_API_TOKEN` | sekret środowiska GitHub `monitor` (tylko `main`) | dedykowany token workspace Railway, czytany tylko przez `verify.yml` |
| `GITHUB_TOKEN` | automatyczny token runu | `issues: write` tylko w `verify.yml`; `ci.yml` ma `contents: read` |
| `RAILWAY_PROJECT_ID`, `READINESS_SERVICES`, `MONITOR_ASSIGNEE` | zmienne repo (Actions → Variables) | wartości publiczne, nie sekrety |

Szczegóły, rotacja i ochrona publicznego repo: [`SECURITY.md`](SECURITY.md).

## Licencja

MIT, zob. [`LICENSE`](LICENSE).
