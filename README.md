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
5. Czerwony run otwiera lub komentuje jedno issue `deploy-health` na środowisko i usługę,
   przypisane do operatora; pierwszy zielony run tej usługi je zamyka.

Kroki 4–5 (`verifier/`, `.github/workflows/`) powstają w kolejnej fazie.

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

## Sekrety i uprawnienia

| Nazwa | Gdzie | Uprawnienia |
| --- | --- | --- |
| `WEBHOOK_SECRET` | sekret Workera (`wrangler secret put`), nagłówek webhooka w Railway | losowy ciąg, tylko do uwierzytelnienia webhooka |
| `GITHUB_DISPATCH_TOKEN` | sekret Workera | fine-grained PAT: tylko to repo, **Actions: write**, z datą wygaśnięcia |
| `RAILWAY_PROJECT_ID`, `GITHUB_REPO` | `[vars]` w `worker/wrangler.toml` | wartości publiczne, nie sekrety |

Szczegóły, rotacja i ochrona publicznego repo: [`SECURITY.md`](SECURITY.md).

## Licencja

MIT, zob. [`LICENSE`](LICENSE).
