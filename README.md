# Grafana (iOS)

Нативный клиент SwiftUI для Grafana с источником данных Zabbix: обзор, проблемы, системы, панели в стиле Grafana, карта филиалов.

- iOS 16+, сборка через XcodeGen (`project.yml`) и GitHub Actions (артефакт `Grafana-ipa`, без подписи, ставится через Sideloadly).
- Адрес Grafana вводится при первом запуске. Логин и пароль хранятся в Keychain.
- Демо-режим для проверки без сервера: аргумент запуска `--demo`.
