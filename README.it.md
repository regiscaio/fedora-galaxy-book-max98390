<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

## Installazione rapida

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

Pacchettizzazione RPM/akmod del percorso driver `MAX98390` per gli
altoparlanti interni dei notebook Samsung Galaxy Book su Fedora, con focus
iniziale sul Galaxy Book4 Ultra.

## Obiettivo

Alcuni Galaxy Book espongono normalmente la scheda audio e mostrano persino il
sink di uscita nel sistema, ma gli altoparlanti interni restano muti. In quei
modelli, la parte mancante è il lato degli amplificatori `MAX98390`.

Questo repository organizza quel supporto nel modo tipico di Fedora:

- moduli esterni ricostruiti con `akmods`;
- caricamento automatico dei moduli all'avvio;
- servizio di boot per creare i dispositivi I2C mancanti degli amplificatori;
- helper per rilevare quando il kernel possiede già supporto nativo sufficiente.

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

- `module/`: sorgenti di `snd-hda-scodec-max98390` e `snd-hda-scodec-max98390-i2c`
- `scripts/`: helper di boot e controlli sul supporto nativo
- `data/`: file `modules-load.d` e unit di `systemd`
- `packaging/fedora/`: spec RPM

## Build locale

```bash
make build
make rpm
```

Gli RPM generati vengono salvati in `dist/`.

## Stato attuale

L'obiettivo di questa prima linea è fornire un pacchetto Fedora testabile e
riproducibile per il percorso `MAX98390`. La validazione della build fa parte
di questo repository; la validazione sonora su hardware reale deve essere
trattata come fase di integrazione sul notebook di destinazione.
