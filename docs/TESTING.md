# Piano di test di backqup

## Cosa testiamo e perché

| Area | Perché |
|------|--------|
| **Cifratura con sola chiave pubblica (age)** | Il server che esegue i backup conosce solo i *recipient* (`age1...`). Se viene compromesso, i backup già prodotti restano illeggibili. Verifichiamo che l'oggetto caricato abbia l'header age, non sia leggibile come tar e non si apra con una chiave sbagliata. |
| **Validazione del dump Postgres** | Un dump corrotto non deve mai essere caricato come se fosse buono. Dopo un dump `custom` (`compress` o `-Fc`/`--format=custom` in `args`) gira `pg_restore --list`; se fallisce, il backup fallisce. I dump SQL piani e `pg_dumpall` non sono validati. |
| **Round-trip di restore** | Un backup vale solo se si ripristina. L'e2e scarica l'oggetto, lo decifra, lo scompatta, lo ripristina in un database nuovo e confronta conteggio righe e hash del contenuto con il seed. |
| **Per database** | Ogni tipo di database ha il suo comando di dump e il suo formato: la copertura e2e è per database (vedi tabella sotto). |

## Livelli

### a) Unit test (`go test`)

Go può non essere installato sull'host: si usa Docker. Il package `web` incorpora `web/dist` (go:embed), quindi serve un placeholder.

Linux / Git Bash:

```sh
mkdir -p web/dist && touch web/dist/index.html
docker run --rm -v "$PWD:/src" -v backqup-gomod:/go/pkg/mod -w /src golang:1.23-alpine \
  sh -c "apk add -q git age && go vet ./... && GO_ENV=test go test ./..."
```

PowerShell:

```powershell
New-Item -ItemType Directory -Force web/dist | Out-Null; New-Item -ItemType File -Force web/dist/index.html | Out-Null
docker run --rm -v "${PWD}:/src" -v backqup-gomod:/go/pkg/mod -w /src golang:1.23-alpine `
  sh -c "apk add -q git age && go vet ./... && GO_ENV=test go test ./..."
```

(In Git Bash su Windows esporta prima `MSYS_NO_PATHCONV=1`.) Il test di round-trip age (`encryptor/age_test.go`) usa `age`/`age-keygen` reali e viene saltato se non sono nel PATH.

Falsi negativi noti in ambiente alpine/busybox o con checkout CRLF (Windows, `core.autocrlf=true`): `helper` (`TestUtils_init`, test su `tar` GNU e su fine riga) e `config` (`TestWatchConfigToReload`, file watcher su mount Docker). Sono test upstream, non toccati dal fork; su Ubuntu (CI) passano.

### b) E2E locale: `tests/e2e/run.sh`

Prerequisiti: solo Docker (con il plugin `docker compose`). Se l'immagine `backqup:dev` non esiste la costruisce da sé (`docker build -t backqup:dev .`).

```sh
sh tests/e2e/run.sh
```

Cosa fa, in ordine:

1. Avvia lo stack (`tests/e2e/docker-compose.yml`): Postgres 16 e MariaDB 11 con una tabella `items` di 200 righe, due server vuoti come target di restore (Postgres 18 e MariaDB 11), un S3 locale (SeaweedFS, perché MinIO non pubblica più immagini) e un container `backqup` con l'immagine da testare. Nessuna porta è pubblicata.
2. Genera due chiavi age usa e getta in `tests/e2e/.work` (quella buona e una "sbagliata"). A `gobackup` viene passata solo la chiave pubblica.
3. Esegue `gobackup perform` per il modello `pg` (`compress: gzip`, quindi dump custom + validazione) e per `maria`, con `encrypt_with: type: age` e storage S3 (`tests/e2e/gobackup.yml`, variabili `$ENV`).
4. Scarica gli oggetti `*.tar.age` da S3 e verifica: header `age-encryption.org/v1`, non leggibile come tar, non decifrabile con la chiave sbagliata.
5. Decifra con la chiave privata, estrae il tar (`<modello>/postgresql/appdb/appdb.sql.gz`, `<modello>/mysql/appdb/appdb.sql`), ripristina in database freschi (`pg_restore`, `mariadb`).
6. Confronta `count(*)` e md5 del contenuto tra sorgente e ripristino.
7. In uscita (`trap`, anche in caso di errore) svuota `.work` e fa `docker compose down -v`.

Esito: ultima riga `E2E PASSED` (exit 0) oppure `FAIL: <motivo>` seguito da `E2E FAILED` (exit != 0). Lo step in corso è l'ultimo `== ...` stampato; sopra ci sono i log di `gobackup`. Per ispezionare lo stack dopo un errore commenta il `trap` in `run.sh`. Tempo atteso: circa 40 secondi a immagini già scaricate (alcuni minuti al primo avvio per pull e build).

Nota: l'immagine ha `pg_dump`/`pg_restore` 18. Il dump si ripristina anche su server più vecchi (provato su Postgres 16: dati, RLS e GRANT identici), ma `pg_restore` 18 manda `SET transaction_timeout`, che i server < 17 non conoscono: **un errore innocuo e exit code 1** (`errors ignored on restore: 1`). L'e2e usa un target 18 per avere exit 0. Su server < 17:

- non usare `--single-transaction` (quell'errore annullerebbe tutto il restore);
- negli script, non fermarsi sull'exit code ma controllare che l'unico errore sia quello, oppure filtrarlo: `pg_restore -f - dump | grep -v '^SET transaction_timeout' | psql -d <db>`;
- `pg_restore` 16 non legge i dump di `pg_dump` 18: il restore va fatto con il client dell'immagine (o uno >= 18).

### c) CI

Su ogni pull request e push su `main` (`.github/workflows/backqup-test.yml`): unit test (`go vet` + `go test ./...` con `age` installato) ed e2e (build immagine + `tests/e2e/run.sh`). I workflow di release upstream (`release-*.yml`) non sono toccati: pubblicano sul registry upstream e vanno rivisti quando decideremo dove pubblicare l'immagine.

Sui tag (release): build dell'immagine dal Dockerfile e rerun dell'e2e su quell'immagine (`BACKQUP_IMAGE=<tag> sh tests/e2e/run.sh`) prima del push sul registry. Non ancora implementato: il registry non è deciso.

### d) Drill di restore manuale (periodico, es. mensile)

Da fare su un backup **reale**, con la chiave privata custodita offline.

- [ ] Scarica l'ultimo oggetto `*.tar.age` dallo storage di produzione e annota data e dimensione (sono coerenti con la schedulazione?).
- [ ] Decifra su una macchina fidata: `age -d -i key.txt -o backup.tar backup.tar.age`.
- [ ] Estrai: `tar -xf backup.tar` e individua il dump.
- [ ] Crea un database usa e getta (container Postgres della stessa major del server di produzione o più recente).
- [ ] Ripristina con il `pg_restore` dell'immagine (18): `pg_restore --no-owner -d <db> appdb.sql.gz` (dump custom) oppure `psql -d <db> -f dump.sql`. Su server < 17 è atteso un solo errore `transaction_timeout` (vedi nota in b).
- [ ] Ricrea i ruoli applicativi (il dump è senza ruoli/privilegi: `--no-owner`/provision-roles) e riassegna i grant.
- [ ] Smoke check: conteggi delle tabelle principali vs. produzione, ultimo record presente, l'app si avvia contro il DB ripristinato e il login funziona.
- [ ] Registra l'esito (data, backup usato, tempo di restore) e distruggi database e file decifrati.

## Copertura per database

| Database | E2E (`tests/e2e`) | Solo unit test upstream |
|----------|:-----------------:|:-----------------------:|
| PostgreSQL | si (custom + validazione) | si |
| MariaDB / MySQL | si | si |
| MongoDB, Redis, SQLite, MSSQL, InfluxDB, etcd, PostgreSQL `all_databases` e altri | no | si |

I database non coperti dall'e2e hanno solo i test di costruzione del comando (upstream): prima di usarli in produzione aggiungi un servizio a `tests/e2e/docker-compose.yml` e un modello a `gobackup.yml`.
