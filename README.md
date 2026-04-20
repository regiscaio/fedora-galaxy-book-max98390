# Galaxy Book MAX98390

## Instalação rápida

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

Empacotamento em RPM/akmod do driver `MAX98390` para os alto-falantes internos
de notebooks Samsung Galaxy Book no Fedora, com foco inicial no Galaxy Book4
Ultra.

## Objetivo

Alguns Galaxy Book expõem a placa de som no sistema e até apresentam o sink de
saída normalmente, mas os alto-falantes internos continuam mudos. O ponto que
falta nesses modelos é o lado dos amplificadores `MAX98390`.

Este repositório organiza esse suporte no padrão Fedora:

- módulos externos reconstruídos com `akmods`;
- autoload dos módulos no boot;
- serviço de boot para criar os dispositivos I2C dos amplificadores ausentes;
- helper para detectar quando o kernel já tiver suporte nativo suficiente.

## Escopo

Este pacote cuida apenas do caminho dos alto-falantes `MAX98390`.

Ele não substitui:

- o driver da câmera `OV02C10`;
- o app `Galaxy Book Câmera`;
- o `Galaxy Book Setup`.

## Origem técnica

O código-base deste driver deriva do trabalho publicado em:

- <https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes>

A diferença aqui é o empacotamento orientado a Fedora, com foco em `RPM`,
`akmods`, `systemd` e manutenção previsível no fluxo que já está sendo usado
nos outros repositórios desta linha.

## Estrutura

- `module/`: fontes dos módulos `snd-hda-scodec-max98390` e `snd-hda-scodec-max98390-i2c`
- `scripts/`: helpers de boot e checagem de suporte nativo
- `data/`: arquivos de `modules-load.d` e units do `systemd`
- `packaging/fedora/`: spec RPM

## Build local

```bash
make build
make rpm
```

Os RPMs gerados ficam em `dist/`.

## Estado atual

O objetivo desta primeira linha é entregar um pacote Fedora testável e
reproduzível para a trilha `MAX98390`. A validação de build faz parte deste
repositório; a validação auditiva em hardware deve ser tratada como etapa de
integração no notebook alvo.
