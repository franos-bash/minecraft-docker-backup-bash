# FERRAMENTA DE BACKUP PARA MINECRAFT EM DOCKER

## Visão Geral

Este é um script de backup automatizado para servidores Minecraft rodando em containers Docker. Ele para o servidor graciosamente, cria backups marcados por data e hora dos dados do seu mundo, e reinicia o container — tudo de forma automatizada.

## Requerimentos

- Docker (com docker-compose ou docker compose command)
- Bash shell
- rsync para copiar os dados
- RCON habilitado no server.properties
- rcon-cli on the container (for Minecraft Java Edition)

## Instruções

1. Pare o container `docker stop nome-container`
2. Faça uma cópia `cp -r /caminho/container/container-mc /caminho/container/container-mc.bkp`
3. Inicie o container `cd /caminho/container/container-mc && docker-compose up -d`
4. Baixe o arquivo backup.sh `git clone https://github.com/franos-bash/minecraft-docker-backup-bash.git`
6. Coloque o script no mesmo diretório do arquivo docker-compose.yml do servidor minecraft
7. Torne o script executável `sudo chmod +x backup.sh` ou na GUI: clique direito > propriedades > permitir executar como um programa
8. Verifique se o container está rodando saudável `docker ps`
9. Execute o script `./backup.sh.`
10. Observe o retorno no terminal caso ocorra algum erro
11. Se tudo funcionar normalmente, faça um cron job para executar o script com recorrência

!!! Isso vai kickar todos os players, e reiniciar o container !!!

## Como funciona

Este script funciona lendo um arquivo `docker-compose` que está no mesmo diretório que ele. Por exemplo:

```bash
mc-container/
├── backup.sh*
├── data/
└── docker-compose.yml
```

Após o script rodar pela primeira vez, ele criará um diretório para os backups e um arquivo de log:

```bash
mc-container/
├── autobkp/
├── autobkp.log
├── backup.sh*
├── data/
└── docker-compose.yml
```

### Configurando backups automáticos com cron

O script não se executará automaticamente — você precisa configurar um cronjob:

```bash
user@server:~$ crontab -e

# Adicione esta linha:
0 4,16 * * * /path/to/minecraft-container/backup.sh
```

Neste exemplo, o script será executado todos os dias às **4:00 da manhã** e às **4:00 da tarde** (16:00). O formato do cron é `minuto hora dia mês dia_da_semana`.

Visite o site https://crontab.guru/ para ajuda no formato do crontab

## O que ele faz

1. **Lê a configuração** do `docker-compose.yaml`:
   - Extrai o nome do container
   - Encontra o caminho do diretório de dados
   - Localiza dados de jogadores e `server.properties`

2. **Valida conexão RCON**:
   - Lê porta e senha RCON de `server.properties`
   - Testa conectividade antes de prosseguir

3. **Verifica atividade de jogadores**:
   - Consulta quantidade de jogadores online
   - Se jogadores estão online: envia mensagens de aviso de 5 minutos e contagem regressiva no chat
   - Se nenhum jogador: pula contagem regressiva e prossegue imediatamente

4. **Desligamento gracioso do servidor**:
   - Expulsa todos os jogadores
   - Salva todas as alterações
   - Para o servidor graciosamente via RCON

5. **Gerenciamento de backup**:
   - Cria diretório `autobkp` se não existir
   - Verifica número de backups existentes
   - Só faz backup se mudanças forem detectadas (compara dados de jogadores com backup anterior)
   - Copia diretório world com `rsync` usando nome de pasta marcado por data
   - Remove automaticamente backups antigos quando limite é excedido

6. **Reinicialização do servidor**:
   - Inicia o container Docker
   - Verifica inicialização bem-sucedida com tentativas

## Recursos

- **Log**: Mantém logs detalhados em `autobkp.log` no diretório do container
- **Segurança de processo**: Cria arquivo de bloqueio para evitar execuções simultâneas
- **Configurações personalizáveis**: Modifique as variáveis de configuração no início do script:

```bash
# ====== CONFIGURAÇÕES ======
RCON_STOP_TIMEOUT=30      # Tempo limite para parada graciosa do servidor (segundos)
MAX_BACKUP_COPIES=10      # Número máximo de cópias de backup a manter
MIN_DISK_SPACE_MB=1000    # Espaço mínimo em disco necessário antes do backup (MB)
LOG_SIZE_LIMIT=10485760   # 10MB - Limite de rotação de log
CONTAINER_CHECK_RETRIES=3 # Tentativas de iniciar o container
```

- **Backups inteligentes**: Só cria backups se dados de jogadores mudaram desde o último backup
- **Consciente de espaço**: Verifica espaço disponível em disco antes de prosseguir
- **Rotação de log**: Rotaciona automaticamente arquivos de log quando excedem limite de tamanho
- **Amigável com jogadores**: Envia mensagens de aviso aos jogadores conectados antes de reiniciar

## Solução de Problemas

- **"docker-compose.yml não encontrado"**: Certifique-se de que o script está no mesmo diretório que seu arquivo compose
- **"Falha na conexão RCON"**: Verifique se RCON está habilitado e as credenciais estão corretas em `server.properties`
- **"Espaço em disco insuficiente"**: Aumente `MIN_DISK_SPACE_MB` ou libere espaço em disco
- **"Container falhou ao iniciar"**: Verifique logs do Docker com `docker logs <nome_container>`
- Verifique `autobkp.log` para mensagens de erro detalhadas e histórico de operações
