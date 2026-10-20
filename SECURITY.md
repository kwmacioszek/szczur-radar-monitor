# Bezpieczeństwo

Repo jest publiczne. Nie zawiera żadnych sekretów: sekrety żyją wyłącznie w Cloudflare
(Worker) i w środowisku GitHub `monitor`.

## Sekrety i minimalne uprawnienia

| Sekret | Gdzie | Uprawnienia | Skutek wycieku |
| --- | --- | --- | --- |
| `WEBHOOK_SECRET` | sekret Workera; nagłówek `X-Monitor-Secret` webhooka Railway | brak, tylko uwierzytelnienie webhooka | ktoś może wysłać fałszywe zdarzenie; Worker i tak przyjmie tylko projekt szczur-radar i poprawne pola, a run tylko czyta stan z Railway |
| `GITHUB_DISPATCH_TOKEN` | sekret Workera | fine-grained PAT: tylko repo `szczur-radar-monitor`, **Actions: write**, nic więcej, z datą wygaśnięcia | uruchamianie i anulowanie runów monitora |
| `RAILWAY_API_TOKEN` | sekret środowiska GitHub `monitor` (dostępny tylko z `main`) | dedykowany token workspace Railway (Railway nie ma tokenów tylko do odczytu; token projektu obejmuje jedno środowisko) | dostęp do workspace Railway; dlatego tylko w chronionym środowisku |
| `GITHUB_TOKEN` | automatyczny token runu | `contents: read`, `issues: write`, jawnie w workflow | wygasa z końcem runu |

`RAILWAY_PROJECT_ID` i `GITHUB_REPO` (`worker/wrangler.toml`) to wartości publiczne.

Zasady:

- Worker porównuje sekret w stałym czasie (`crypto.subtle.timingSafeEqual` na skrótach SHA-256)
  i nigdy nie loguje sekretów ani treści żądania.
- Worker przekazuje do GitHub tylko pięć zwalidowanych pól (UUID dla id, `[a-z0-9-]{1,64}` dla
  nazw); skrypt weryfikacji waliduje je ponownie i dostaje je wyłącznie przez `env:`.
- Lokalne sekrety (`worker/.dev.vars`, `.env`) są w `.gitignore`.

## Ochrona publicznego repo

- `verify.yml` (jedyny workflow z sekretami) ma wyłącznie wyzwalacz `workflow_dispatch` i używa
  środowiska `monitor`, ograniczonego do gałęzi `main`.
- `ci.yml` (`pull_request`, `push`) nie używa środowiska ani sekretów. Nigdy
  `pull_request_target`.
- `main` chroniony rulesetem: bez force-push, zmiany tylko przez PR.
- Runy workflow z forków wymagają zatwierdzenia.
- Akcje przypięte po SHA; `permissions` jawne na górze każdego workflow.

## Rotacja

- `GITHUB_DISPATCH_TOKEN`: PAT zawsze z datą wygaśnięcia. Przed wygaśnięciem utwórz nowy z tymi
  samymi uprawnieniami, `npx wrangler secret put GITHUB_DISPATCH_TOKEN`, potem unieważnij stary.
- `RAILWAY_API_TOKEN`: rotowany razem z PAT. Nowy token workspace, podmiana sekretu w środowisku
  `monitor`, unieważnienie starego w Railway.
- `WEBHOOK_SECRET`: nowy losowy ciąg (np. `openssl rand -hex 32`), `npx wrangler secret put
  WEBHOOK_SECRET`, zaraz potem ta sama wartość w nagłówku webhooka Railway. Między tymi krokami
  webhooki dostają 401 i Railway je ponawia.
- Po podejrzeniu wycieku: natychmiast unieważnij dany sekret u źródła (GitHub, Railway), potem
  rotuj jak wyżej.

## Zgłaszanie podatności

Nie otwieraj publicznego issue. Użyj prywatnego zgłoszenia (GitHub → Security → Report a
vulnerability) w tym repo.
