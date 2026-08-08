# summary-filter.jq — проекция `docker inspect` в безопасный набор полей (schema 1).
#
# Единственный источник правды для containers-summary.json: его применяет
# dump-snapshot.sh и он же проверяется в tests/test-inventory-scan.sh — чтобы
# проверяемое и работающее не разъезжались.
#
# ПРИНЦИП: белый список. В снимок попадают только перечисленные поля. Всё, куда
# пользователь кладёт произвольные строки и команды — Args, Cmd, Entrypoint, Labels,
# Healthcheck, LogConfig — не переносится ВООБЩЕ. Значения переменных окружения не
# сохраняются никогда, только имена.
#
# Грабля, ради которой это сделано (2026-08-08): сырой inspect унёс в снимок ключ
# `sb_secret_` из многострочного значения env и приватный TLS-ключ из Entrypoint.
# Маскировка — растущий чёрный список и последней линией обороны быть не может.

[ .[] | {
    Name: (.Name // "" | sub("^/"; "")),
    Image: (.Config.Image // null),
    ImageDigest: (.Image // null),
    Created: (.Created // null),
    State: {
        Status:    (.State.Status // null),
        Health:    (.State.Health.Status // null),
        ExitCode:  (.State.ExitCode // null),
        StartedAt: (.State.StartedAt // null)
    },
    RestartPolicy: (.HostConfig.RestartPolicy.Name // null),
    Networks: [ (.NetworkSettings.Networks // {}) | to_entries[]
                | {network: .key, ip: .value.IPAddress} ],
    Ports: (.NetworkSettings.Ports // {}),
    Mounts: [ (.Mounts // [])[] | {Type, Source, Destination, RW} ],
    EnvNames: [ (.Config.Env // [])[] | split("=")[0] ]
} ]
