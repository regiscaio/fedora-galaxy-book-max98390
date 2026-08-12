<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book MAX98390

Empacotamento em RPM/akmod do driver `MAX98390` para os alto-falantes internos
de notebooks Samsung Galaxy Book no Fedora, com foco inicial no Galaxy Book4
Ultra.

## Instalação rápida

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-max98390
```

O pacote `akmod` contém os fontes e a receita de build. O `akmods` compila e
instala um RPM `kmod-galaxybook-max98390-<versão-do-kernel>` para cada kernel,
com os dois módulos destinados exatamente àquela versão. Um módulo compilado
para outro kernel não é reutilizado.

## Objetivo

Alguns Galaxy Book expõem a placa de som no sistema e até apresentam o sink de
saída normalmente, mas os alto-falantes internos continuam mudos. O ponto que
falta nesses modelos é o lado dos amplificadores `MAX98390`.

Este repositório organiza esse suporte no padrão Fedora:

- módulos externos reconstruídos e entregues por kernel com `akmods`;
- fila durável que finaliza cada novo kmod somente depois que a transação RPM
  termina, com owner, `vermagic`, `depmod` e resolução validados antes de
  remover qualquer override legado não gerenciado;
- serviço de boot que aguarda o `akmods`, carrega os dois módulos explicitamente
  e cria os dispositivos I2C ausentes;
- tentativas limitadas enquanto ACPI, I2C, módulos e amplificadores ficam
  disponíveis;
- validação dos bindings no driver `max98390-hda` antes de considerar o serviço
  concluído;
- helper de diagnóstico para indicar quando o kernel aparentar ter todas as
  partes do suporte nativo.

Não é instalado arquivo em `modules-load.d`. No primeiro boot de um kernel
novo, tentar carregar os módulos antes do `akmods` terminar criaria uma corrida.
Por isso, o próprio serviço os carrega somente depois do build por kernel. A
unit de I2C é ignorada automaticamente em máquinas sem um dispositivo ACPI
MAX98390. O finalizador é executado antes dela e bloqueia shutdown/suspensão
somente durante sua curta seção crítica; pedidos interrompidos permanecem na
fila para uma tentativa posterior.

A topologia alvo é a do Galaxy Book4 Ultra: um cliente criado pelo ACPI e três
amplificadores adicionais nos endereços `0x39`, `0x3c` e `0x3d`. O serviço só
conclui quando os quatro bindings existem; outra topologia exige um perfil
específico antes do uso.

## Fedora 44 e Linux 7.1

Na combinação atualmente verificada, Fedora 44 com Linux 7.1, o workaround
ainda é necessário nos equipamentos afetados. O kernel ainda não reúne, ao
mesmo tempo, a instanciação de todos os amplificadores, o quirk correspondente
no `snd-hda-codec-alc269` e o side-codec HDA `MAX98390`.

O serviço `max98390-hda-check-upstream.service` faz uma checagem conservadora e
somente informa o resultado no journal. Ele não remove nem desativa o pacote.
Uma mensagem de suporte nativo detectado também não é garantia de que uma
versão futura do kernel funcionará neste notebook: confirme os bindings e faça
um teste auditivo real antes de remover o workaround.

## Limitação atual de gerenciamento de energia

No Linux 7.1 auditado, o `alc269` ainda não cria o component master necessário
para ligar o side-codec ao codec HDA. Por isso, o fallback habilita DSP e
amplificadores durante o probe. Os amplificadores podem permanecer ligados
mesmo sem reprodução, aumentando o consumo em idle.

Esse comportamento é uma limitação conhecida do workaround e não equivale à
integração nativa completa com gerenciamento de energia. Não há promessa de
quando essa integração chegará ao kernel usado pelo Fedora.

## Diagnóstico e validação

Os comandos abaixo são somente leitura:

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

Os dois `modinfo` devem localizar módulos para o kernel em execução. Os arquivos
devem pertencer ao RPM `kmod` daquela versão, e os clientes I2C encontrados
devem apresentar binding em `max98390-hda`. Se um `modinfo` responder
`Module not found`, consulte primeiro o log do `akmods`: copiar um `.ko`
manualmente para `/lib/modules` mascara o problema e deixa o arquivo fora do
gerenciamento do RPM.

Repita essa validação após uma atualização de kernel. O teste definitivo
continua sendo reproduzir áudio nos alto-falantes internos depois de reiniciar
no novo kernel.

Desde a versão `1.00.09`, integrações que já terminaram o build de um kernel
podem aguardar a finalização completa, fora da transação RPM, com:

```bash
sudo /usr/libexec/galaxybook-max98390/max98390-kmod-finalize.sh \
  --kernel "$kernel_release"
```

O comando só retorna sucesso depois de validar os dois owners RPM e
`vermagic`, remover apenas overrides legados sem owner, executar `depmod` e
confirmar a resolução exata dos dois módulos. A fila automática usa o mesmo
contrato e preserva pedidos interrompidos para retry.

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

- `module/`: fontes dos módulos `snd-hda-scodec-max98390` e
  `snd-hda-scodec-max98390-i2c`
- `scripts/`: helpers de finalização por kernel, boot e suporte nativo
- `data/`: units do `systemd`
- `packaging/fedora/`: spec RPM/akmod e geração do payload por kernel

## Build local

```bash
make build
make rpm
```

`make build` compila contra o kernel em execução. `make rpm` gera o pacote
fonte e os pacotes de entrada do fluxo akmod; o payload carregável específico
do kernel é produzido quando o `akmods` executa o build para aquela versão. Os
artefatos locais ficam em `dist/`.
