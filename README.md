# ESP-WB — Wiren Board + ESPHome integration

ESP-WB содержит готовые конфигурации, контейнерные сервисы и скрипты для интеграции устройств на базе ESP (ESPHome) с контроллерами Wiren Board и Home Assistant. Проект предназначен для быстрого развёртывания среды сборки ESPHome, адаптации счётчиков MAP12E и агрегирования многотарифного учёта энергии в Home Assistant / WB.

Ключевые цели:
- Предоставить готовые конфигурации ESPHome для MAP12E (Modbus).
- Автоматизировать развёртывание контейнеров для ESPHome и Home Assistant на Wiren Board.
- Скрипты для корректной установки Docker и работы с `/mnt/data` на WB.

Полезные ссылки

- Telegram канал: https://t.me/u2smart4home
- Дзен: https://dzen.ru/id/5e32d0969929ba40059b5892
- YouTube: https://www.youtube.com/@udobni_dom
- Статья проекта (подробная инструкция): https://teletype.in/@godisblind/F-3V9VCngZd

Контакты

Автор: Егор (smirnowegor). Для срочной связи: https://t.me/godisblind

Поддержка

- https://dzen.ru/id/5e32d0969929ba40059b5892?donate=true
- https://donate.stream/yoomoney410013774736621

---

## Что внутри (файлы и назначение)

- `espWB_MAP12E.yaml` — основная ESPHome конфигурация для MAP12E (powermeter). Описывает UART/Modbus подключение, набор Modbus-сенсоров, шаблонные сенсоры тарифов, on_boot и логику публикации значений. См. [espWB_MAP12E.yaml](espWB_MAP12E.yaml).
- `espWB_MAP12E_noTariff.yaml` — вариант конфигурации для случая без многотарифного учёта (без шаблонных тарифных сенсоров). См. [espWB_MAP12E_noTariff.yaml](espWB_MAP12E_noTariff.yaml).
- `espHomeWB.yaml` — docker-compose / service snippet для развёртывания контейнера ESPHome с данными и сборкой на `/mnt/data/udobnidom/esphome`. Используется для локального сборочного окружения и OTA. См. [espHomeWB.yaml](espHomeWB.yaml).
- `homeassistantWB.yaml` — docker-compose / service snippet для развёртывания Home Assistant с монтированием конфигурации в `/mnt/data/udobnidom/homeassistant`. См. [homeassistantWB.yaml](homeassistantWB.yaml).
- `MatterWB.yaml` — шаблон / вспомогательная конфигурация для Matter (при наличии устройств). См. [MatterWB.yaml](MatterWB.yaml).
- `WB-MAP12Efw2_145_tarif.js` — сценарий (WB rules) для Wiren Board, агрегирующий многотарифную энергию, распределяющий дельту между тарифами, поддерживающий ручной ввод и кнопку обновления тарифов. См. [WB-MAP12Efw2_145_tarif.js](WB-MAP12Efw2_145_tarif.js).
- `WB-MDM3/` — папка с материалами/прошивками для других устройств/модулей (проверьте содержимое при необходимости). См. [WB-MDM3](WB-MDM3).
- `fastDockerWb.sh` — скрипт установки и настройки Docker на Wiren Board. Включает проверку разделов, перенос данных в `/mnt/data`, конфигурацию `daemon.json` и защиту от переполнения логов. См. [fastDockerWb.sh](fastDockerWb.sh).
- `fastPortainerWB.sh`, `fastZ2MWB.sh`, `duplicatiFastWB.sh` — вспомогательные скрипты быстрого развёртывания Portainer, Zigbee2MQTT, Duplicati на WB.
- `wudWB.yaml` — docker-compose snippet для запуска WUD (Watchdog/Updater Dashboard) с MQTT интеграцией. См. [wudWB.yaml](wudWB.yaml).

Если нужно расширённое описание конкретного файла — могу вставить детальный разбор с ключевыми секциями и примерами (например, разобрать `espWB_MAP12E.yaml` по блокам: Modbus, шаблонные сенсоры, on_boot, фильтры и т.д.).

## Быстрый старт

1) Подготовка окружения на Wiren Board

Если Docker ещё не настроен на WB, используйте `fastDockerWb.sh` (запуск от root):

```bash
sudo bash fastDockerWb.sh
```

2) Развёртывание ESPHome контейнера (локально на WB или на сервере)

Скопируйте `espHomeWB.yaml` в ваш compose-проект или используйте как шаблон. После этого поместите `espWB_MAP12E.yaml` в каталог конфигурации ESPHome и соберите прошивку:

```bash
# пример для esphome cli
esphome run espWB_MAP12E.yaml
```

3) Развёртывание Home Assistant

Используйте `homeassistantWB.yaml` как шаблон для контейнера HA (монтирование в `/mnt/data/udobnidom/homeassistant`).

4) Настройка Wiren Board rules

Скопируйте `WB-MAP12Efw2_145_tarif.js` в правила WB (директория с rules) и создайте виртуальные устройства `map12e_tariffs` и `map12e_data` в панели WB. Проверьте соответствие имён контролов (meterDevice) с реальным идентификатором WB-устройства.

## Рекомендации и примечания

- `espWB_MAP12E.yaml` рассчитан на ESP32 с UART->Modbus и содержит шаблонные сенсоры для многотарифного учёта; внимательно проверьте `address` и `modbus_id` под вашу схему.
- В `WB-MAP12Efw2_145_tarif.js` задаётся `meterDevice` — убедитесь, что имя устройства совпадает с реальным именем в WB.
- Резервируйте `/mnt/data` для контейнеров и сборки ESPHome — на Wiren Board это рекомендуемая практика.
- Перед использованием скриптов установки Docker сделайте резервную копию важных данных.

---

Если хотите, я могу:
- Добавить подробную секцию «Разбор `espWB_MAP12E.yaml` по блокам» с пояснениями и примерами значений;
- Сгенерировать готовый `docker-compose.yml`, объединяющий все `*.yaml` сервисы под одной сетью и volume-монтажом;
- Подготовить PR с коммитом README и изменениями.

Скажите, что делаем дальше?
