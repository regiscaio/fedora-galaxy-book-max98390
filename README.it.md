<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

Pacchettizzazione RPM/akmod del percorso driver `MAX98390` per gli
altoparlanti interni dei notebook Samsung Galaxy Book su Fedora, con focus
iniziale sul Galaxy Book4 Ultra.

## Installazione rapida

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

Il pacchetto `akmod` contiene i sorgenti e la ricetta di compilazione. `akmods`
compila e installa un RPM `kmod-galaxybook-max98390-<versione-del-kernel>` per
ogni kernel, con i due moduli destinati specificamente a quella versione. Un
modulo compilato per un altro kernel non viene mai riutilizzato.

## Obiettivo

Alcuni Galaxy Book espongono normalmente la scheda audio e mostrano persino il
sink di uscita nel sistema, ma gli altoparlanti interni restano muti. In quei
modelli, la parte mancante è il lato degli amplificatori `MAX98390`.

Questo repository organizza quel supporto nel modo tipico di Fedora:

- moduli esterni ricostruiti e distribuiti per ogni kernel con `akmods`;
- una coda persistente che finalizza ogni nuovo kmod dopo la transazione RPM,
  con proprietario, `vermagic`, `depmod` e risoluzione validati senza rimuovere
  né adottare alcun override legacy non gestito;
- un mutex globale autenticato che serializza la manutenzione degli indici dei
  moduli con gli altri driver Galaxy Book, anche durante un `dracut` parallelo;
- un servizio di boot che attende `akmods`, carica esplicitamente entrambi i
  moduli e crea i dispositivi I2C mancanti;
- tentativi limitati mentre ACPI, I2C, i moduli e gli amplificatori diventano
  disponibili;
- verifica che i dispositivi siano associati a `max98390-hda` prima che il
  servizio segnali il successo;
- un helper diagnostico che indica quando il kernel sembra includere tutte le
  parti dell'implementazione nativa.

Non viene installato alcun file in `modules-load.d`. Al primo avvio con un nuovo
kernel, tentare di caricare i moduli prima che `akmods` termini creerebbe una
race condition. Per questo il servizio li carica soltanto dopo la compilazione
per quel kernel. L'unit I2C viene ignorata automaticamente sui sistemi privi di
un dispositivo ACPI MAX98390. Il finalizzatore viene eseguito prima e inibisce
spegnimento/sospensione solo durante la breve sezione critica; le richieste
interrotte restano in coda per un tentativo successivo.

La topologia di destinazione è quella del Galaxy Book4 Ultra: un client creato
da ACPI e tre amplificatori aggiuntivi agli indirizzi `0x39`, `0x3c` e `0x3d`.
Il servizio termina solo quando esistono tutti e quattro i binding; una
topologia diversa richiede un profilo esplicito prima dell'uso.

## Fedora 44 e Linux 7.1

Nella combinazione attualmente verificata, Fedora 44 con Linux 7.1, il
workaround è ancora necessario sui sistemi interessati. Il kernel non riunisce
ancora, contemporaneamente, l'istanzazione di tutti gli amplificatori, il quirk
corrispondente in `snd-hda-codec-alc269` e il side-codec HDA `MAX98390`.

`max98390-hda-check-upstream.service` esegue un controllo conservativo e si
limita a riportare il risultato nel journal. Non rimuove né disattiva il
pacchetto. Anche un messaggio che rileva il supporto nativo non garantisce che
un kernel futuro funzioni su questo notebook: verificare i binding ed eseguire
una vera prova di ascolto prima di rimuovere il workaround.

## Limite attuale della gestione energetica

Nel Linux 7.1 verificato, `alc269` non crea ancora il component master necessario
per collegare il side-codec al codec HDA. Di conseguenza, il fallback abilita
il DSP e gli amplificatori durante il probe. Gli amplificatori possono restare
accesi anche senza riproduzione, aumentando il consumo in idle.

Questo comportamento è un limite noto del workaround e non equivale a
un'integrazione nativa completa con gestione energetica. Non vi è alcuna
promessa su quando tale integrazione arriverà nel kernel distribuito da Fedora.

## Diagnostica e convalida

I seguenti comandi sono di sola lettura:

```bash
kernel_release="$(uname -r)"

modinfo -k "$kernel_release" snd-hda-scodec-max98390
modinfo -k "$kernel_release" snd-hda-scodec-max98390-i2c

systemctl is-enabled max98390-hda-i2c-setup.service
systemctl is-active max98390-hda-i2c-setup.service
journalctl -b -u akmods.service -u max98390-hda-i2c-setup.service \
  -u max98390-kmod-finalize.service \
  -u max98390-hda-check-upstream.service --no-pager

find /sys/bus/i2c/devices -maxdepth 2 -type l -name driver \
  -lname '*max98390-hda*' -print

for module_name in snd-hda-scodec-max98390 snd-hda-scodec-max98390-i2c; do
  module_path="$(modinfo -k "$kernel_release" -n "$module_name")" || continue
  printf '%s -> ' "$module_path"
  rpm -qf "$module_path"
done
```

Entrambi i comandi `modinfo` devono trovare i moduli per il kernel in
esecuzione. I file devono appartenere al relativo RPM `kmod` e i client I2C
rilevati devono mostrare il binding a `max98390-hda`. Se `modinfo` restituisce
`Module not found`, consultare prima il log di `akmods`: copiare manualmente un
`.ko` in `/lib/modules` nasconde il problema e lascia il file fuori dalla
gestione RPM.

Ripetere questa convalida dopo ogni aggiornamento del kernel. La prova definitiva
rimane la riproduzione di audio tramite gli altoparlanti interni dopo l'avvio
con il nuovo kernel.

Dalla versione `1.00.12`, le integrazioni che hanno completato la build di un
kernel possono attendere la finalizzazione completa fuori dalla transazione RPM:

```bash
sudo /usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh \
  --kernel "$kernel_release"
```

Il comando restituisce successo solo dopo aver validato proprietari ed EVR RPM
esatti dei due payload, i relativi `vermagic`, eseguito `depmod` e confermato la
risoluzione esatta. Un override legacy senza proprietario viene conservato. La
regola `depmod.d` del pacchetto dà priorità soltanto ai due moduli validati in
`extra/galaxybook-max98390`; se quel payload non è presente, la copia in
`updates` rimane disponibile come fallback. La coda automatica usa lo stesso
contratto e conserva le richieste interrotte.

Prima del lock privato MAX98390 e del lock condiviso di RPM, il finalizzatore
acquisisce il mutex BSD esclusivo
`/run/lock/galaxybook-kmod-lifecycle.lock`. Un'integrazione coordinatrice può
ereditare il descrittore autenticato, che resta valido fino alla conferma del
marcatore. Vengono riconvalidati antenati, proprietario, modo `0600`, numero di
hardlink e identità `device:inode` tra path e FD. L'attesa è limitata a dieci
minuti; un errore di acquisizione conserva la coda e impedisce l'avvio di
`depmod` o dell'ispezione degli override legacy.

Gli scriptlet `%post` e `%postun` degli RPM specifici per kernel sono
intenzionalmente no-op: acquisire il mutex dentro la transazione invertirebbe
l'ordine RPM → globale e potrebbe causare un deadlock. L'installazione viene
accodata dal trigger del pacchetto comune e finalizzata dopo la transazione.
La rimozione automatica e sicura dei moduli non è supportata in questa release:
anche `%postun` è no-op e una futura API del pacchetto dovrà coordinare la
rimozione fuori dalla transazione. Mantenere il pacchetto comune durante ogni
rimozione pianificata e non eseguire un `depmod` isolato in parallelo agli
aggiornamenti dei driver.

Durante gli upgrade del pacchetto comune, `%pretrans` incorpora un coordinatore
che registra uno snapshot autenticato, arma un recovery persistente e
maschera/drena watcher, servizio I2C dipendente e worker prima della
sostituzione. Dopo l'uscita del writer RPM, il recovery apre solo un grafo
`all-new` coerente. Un'installazione legacy pubblica senza worker può
ripristinare quell'assenza originale; un vecchio worker non sicuro o uno stato
misto resta mascherato per l'adozione da parte di un upgrade compatibile. Tutti
gli start sono asincroni per evitare un'inversione RPM → mutex globale. Se già
installati, i peer devono essere `galaxybook-ov02c10-kmod-common >= 1.00.25` e
`galaxybook-setup >= 1.00.48`; queste dipendenze condizionali non installano i
peer assenti.

Questo bootstrap di migrazione richiede un manager `systemd` attivo. In un
chroot o in una root offline, gli scriptlet non contattano il manager, quindi
non armano il recovery e non verificano il preset e l'attivazione delle unit
introdotte dall'upgrade. Non considerare completa la migrazione iniziale in
questa modalità: ripetere la transazione del pacchetto comune in una sessione
live e verificare il watcher. Dopo un recovery live riuscito, il watcher
persistente copre i riavvii successivi; non viene creato alcun servizio
permanente aggiuntivo.

Un downgrade esplicito non rientra in questo contratto di recovery. Il solver
normale rifiuta un MAX98390 precedente a `1.00.12` quando sono presenti i peer
coordinati. Non forzare un downgrade coordinato, rimuovere tali peer o
installare una build precedente con `--nodeps`: quelle build non includono il
coordinatore attuale e il WIP locale `1.00.11` conteneva un worker che rimuoveva
gli override legacy. Il percorso `all-old` ripristina soltanto uno snapshot
preesistente; non autorizza un downgrade del pacchetto.

## Ambito

Questo pacchetto si occupa solo del percorso degli altoparlanti `MAX98390`.

Non sostituisce:

- il driver della fotocamera `OV02C10`;
- l'app `Galaxy Book Camera`;
- `Galaxy Book Setup`.

## Origine tecnica

La base tecnica di questo driver deriva dal lavoro pubblicato in:

- <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes>

La differenza qui è il packaging orientato a Fedora, con focus su `RPM`,
`akmods`, `systemd` e una manutenzione prevedibile allineata con gli altri
repository di questa linea.

## Struttura

- `module/`: sorgenti di `snd-hda-scodec-max98390` e
  `snd-hda-scodec-max98390-i2c`
- `scripts/`: helper di finalizzazione per kernel, filtro fail-closed di
  `kmodtool`, boot e supporto nativo
- `data/`: unit `systemd`
- `packaging/fedora/`: spec RPM/akmod e generazione del payload per kernel

## Build locale

```bash
make build
make rpm
```

`make build` compila per il kernel in esecuzione. `make rpm` genera il pacchetto
sorgente e i pacchetti di ingresso del flusso akmod; il payload caricabile e
specifico del kernel viene prodotto quando `akmods` compila per quella versione.
Gli artefatti locali vengono salvati in `dist/`.

Il target `install` di `module/Makefile` esiste solo per lo sviluppo e non
partecipa al mutex di lifecycle. In produzione si devono usare esclusivamente
gli RPM/akmods e il finalizzatore pacchettizzato.
