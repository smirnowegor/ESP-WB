// WB-rules: Multi-tariff energy aggregation + units + Refresh button
// Version 4.11 — fixed: validate before apply, circular time validation, consistent indicator+write

// ----- Основные настройки -----
var meterDevice = "wb-map12e_145";
var channels = 4;
var updateIntervalSec = 30;
var maxDeltaKwh = 100.0;

// ----- Виртуальные устройства -----
defineVirtualDevice("map12e_tariffs", {
  title: "MAP12E Tariff Configuration",
  cells: {
    energy_topic: { title: "Имя топика энергии (без Ch X)", type: "text", value: "Total AP energy", readonly: false },
    tariff_count: { title: "Количество тарифов", type: "value", value: 2, readonly: false },
    t1_start: { title: "Начало Дня", type: "text", value: "07:00", readonly: false },
    t2_start: { title: "Начало Ночи", type: "text", value: "23:00", readonly: false },
    t3_start: { title: "Начало Пик1", type: "text", value: "07:00", readonly: false },
    t4_start: { title: "Начало Полупик1", type: "text", value: "10:00", readonly: false },
    t5_start: { title: "Начало Пик2", type: "text", value: "17:00", readonly: false },
    t6_start: { title: "Начало Полупик2", type: "text", value: "21:00", readonly: false }
  }
});

var dataCells = {};
dataCells["active_tariff_indicator"] = { title: "Текущий тариф", type: "text", value: "инициализация...", readonly: true, meta: { order: 1 } };
dataCells["tariffs_summary"] = { title: "Тарифы", type: "text", value: "инициализация...", readonly: true, meta: { order: 2 } };

for (var i = 1; i <= channels; i++) {
  var id = ("0" + i).slice(-2);
  dataCells["ch" + id + "_T1_day"] = { title: "Ch " + i + " T1 (День)", type: "power_consumption", value: 0, readonly: true, meta: { order: i * 10 + 1, unit: "кВт·ч" } };
  dataCells["ch" + id + "_T2_night"] = { title: "Ch " + i + " T2 (Ночь)", type: "power_consumption", value: 0, readonly: true, meta: { order: i * 10 + 2, unit: "кВт·ч" } };
  dataCells["ch" + id + "_T3_peak"] = { title: "Ch " + i + " T3 (Пик)", type: "power_consumption", value: 0, readonly: true, meta: { order: i * 10 + 3, unit: "кВт·ч" } };
  dataCells["ch" + id + "_T4_halfpeak"] = { title: "Ch " + i + " T4 (Полупик)", type: "power_consumption", value: 0, readonly: true, meta: { order: i * 10 + 4, unit: "кВт·ч" } };

  dataCells["ch" + id + "_T1_day_manual"] = { title: "Ch " + i + " T1 (День) Manual", type: "power_consumption", value: 0, readonly: false, meta: { order: 1000 + i * 10 + 1, unit: "кВт·ч" } };
  dataCells["ch" + id + "_T2_night_manual"] = { title: "Ch " + i + " T2 (Ночь) Manual", type: "power_consumption", value: 0, readonly: false, meta: { order: 1000 + i * 10 + 2, unit: "кВт·ч" } };
  dataCells["ch" + id + "_T3_peak_manual"] = { title: "Ch " + i + " T3 (Пик) Manual", type: "power_consumption", value: 0, readonly: false, meta: { order: 1000 + i * 10 + 3, unit: "кВт·ч" } };
  dataCells["ch" + id + "_T4_halfpeak_manual"] = { title: "Ch " + i + " T4 (Полупик) Manual", type: "power_consumption", value: 0, readonly: false, meta: { order: 1000 + i * 10 + 4, unit: "кВт·ч" } };

  dataCells["ch" + id + "_status"] = { title: "Ch " + i + " Status", type: "text", value: "", readonly: true, meta: { order: 101 + i * 10 } };
  dataCells["ch" + id + "_last_total"] = { title: "Ch " + i + " Total (internal)", type: "power_consumption", value: 0, readonly: true, meta: { order: 100 + i * 10, unit: "кВт·ч" } };
}

dataCells["refresh_tariffs"] = { title: "Обновить тарифы", type: "pushbutton", value: false, readonly: false, meta: { order: 3 } };
defineVirtualDevice("map12e_data", { title: "MAP12E Aggregated Data " + meterDevice, cells: dataCells });

// ----- Вспомогательные функции -----
function parseTimeHHMM(str) {
  if (!str || typeof str !== "string") return null;
  var parts = str.split(":");
  if (parts.length !== 2) return null;
  var h = parseInt(parts[0], 10);
  var m = parseInt(parts[1], 10);
  if (isNaN(h) || isNaN(m)) return null;
  return h * 100 + m;
}

function hhmmNow() {
  var d = new Date();
  return d.getHours() * 100 + d.getMinutes();
}

function getTariffConfig() {
  var raw = dev["map12e_tariffs"]["tariff_count"];
  var tc = parseInt(raw, 10);
  if (isNaN(tc)) tc = 1;
  if (tc < 1) tc = 1;
  if (tc > 3) tc = 3;

  var starts = [];
  starts[0] = dev["map12e_tariffs"]["t1_start"];
  starts[1] = dev["map12e_tariffs"]["t2_start"];
  starts[2] = dev["map12e_tariffs"]["t3_start"];
  starts[3] = dev["map12e_tariffs"]["t4_start"];
  starts[4] = dev["map12e_tariffs"]["t5_start"];
  starts[5] = dev["map12e_tariffs"]["t6_start"];

  var startNums = [];
  for (var i = 0; i < starts.length; i++) {
    var s = starts[i];
    var n = parseTimeHHMM(s);
    if (n === null) n = 0;
    startNums.push(n);
  }
  return { count: tc, startStrings: starts, startNums: startNums };
}

// Проверка порядка времен для круговой последовательности
function mod2400Diff(a, b) {
  // возвращает положительное расстояние от a до b по кругу 0..2400
  var diff = ((b - a) + 2400) % 2400;
  return diff;
}

function validateTimeRanges(cfg) {
  if (!cfg || !cfg.startNums) return false;
  if (cfg.count === 1) return true;

  if (cfg.count === 2) {
    var s0 = cfg.startNums[0];
    var s1 = cfg.startNums[1];
    if (s0 === null || s1 === null) {
      log.error("Некорректный формат времени в настройках (2 тарифа).");
      return false;
    }
    if (s0 === s1) {
      log.error("Начало Дня и Начало Ночи совпадают — некорректно.");
      return false;
    }
    // для 2 тарифов достаточно различать времена (порядок не критичен — допустим любой с переходом через полночь)
    return true;
  }

  if (cfg.count === 3) {
    // Формируем логичную циклическую последовательность: Пик1 -> Полупик1 -> Пик2 -> Полупик2 -> Ночь
    var seq = [
      cfg.startNums[2], // t3_start = Пик1
      cfg.startNums[3], // t4_start = Полупик1
      cfg.startNums[4], // t5_start = Пик2
      cfg.startNums[5], // t6_start = Полупик2
      cfg.startNums[1]  // t2_start = Ночь (в конце круга)
    ];
    var names = ["Пик1","Полупик1","Пик2","Полупик2","Ночь"];
    for (var i = 0; i < seq.length; i++) {
      if (seq[i] === null) {
        log.error("Некорректный формат времени тарифов (3 тарифа). Проверьте: " + names[i]);
        return false;
      }
    }
    // Проверяем, что каждый следующий момент времени действительно идёт вперёд по кругу относительно предыдущего
    for (var j = 0; j < seq.length; j++) {
      var a = seq[j];
      var b = seq[(j + 1) % seq.length];
      var d = mod2400Diff(a, b);
      if (d <= 0) {
        log.error("Временные границы тарифов пересекаются или не в порядке: " + names[j] + " -> " + names[(j + 1) % seq.length]);
        return false;
      }
    }
    return true;
  }

  return false;
}

//РАЗРЕШЕНО: getTariffInfo принимает cfg (если передан), чтобы быть детерминированной
function getTariffInfo(cfgOptional) {
  var cfg = cfgOptional || getTariffConfig();
  var now = hhmmNow();
  var tariffInfo = { tariffIndex: 0, zoneName: "", shortName: "" };

  if (cfg.count === 1) {
    tariffInfo.tariffIndex = 1;
    tariffInfo.zoneName = "День";
    tariffInfo.shortName = "T1_day";
    return tariffInfo;
  }

  if (cfg.count === 2) {
    var dayStart = cfg.startNums[0];
    var nightStart = cfg.startNums[1];

    if (dayStart > nightStart) {
      // переход через полночь
      if (now >= dayStart || now < nightStart) {
        tariffInfo.tariffIndex = 1; tariffInfo.zoneName = "День"; tariffInfo.shortName = "T1_day";
      } else {
        tariffInfo.tariffIndex = 2; tariffInfo.zoneName = "Ночь"; tariffInfo.shortName = "T2_night";
      }
    } else {
      if (now >= dayStart && now < nightStart) {
        tariffInfo.tariffIndex = 1; tariffInfo.zoneName = "День"; tariffInfo.shortName = "T1_day";
      } else {
        tariffInfo.tariffIndex = 2; tariffInfo.zoneName = "Ночь"; tariffInfo.shortName = "T2_night";
      }
    }
    return tariffInfo;
  }

  if (cfg.count === 3) {
    var nightStart = cfg.startNums[1];
    var peak1Start = cfg.startNums[2];
    var halfpeak1Start = cfg.startNums[3];
    var peak2Start = cfg.startNums[4];
    var halfpeak2Start = cfg.startNums[5];

    // защита от null (хотя валидатор должен был пропустить)
    if (nightStart === null) nightStart = 0;
    if (peak1Start === null) peak1Start = 0;
    if (halfpeak1Start === null) halfpeak1Start = 0;
    if (peak2Start === null) peak2Start = 0;
    if (halfpeak2Start === null) halfpeak2Start = 0;

    if (now >= nightStart || now < peak1Start) {
      tariffInfo.tariffIndex = 2; tariffInfo.zoneName = "Ночь"; tariffInfo.shortName = "T2_night";
    } else if (now >= peak1Start && now < halfpeak1Start) {
      tariffInfo.tariffIndex = 3; tariffInfo.zoneName = "Пик1"; tariffInfo.shortName = "T3_peak";
    } else if (now >= halfpeak1Start && now < peak2Start) {
      tariffInfo.tariffIndex = 4; tariffInfo.zoneName = "Полупик1"; tariffInfo.shortName = "T4_halfpeak";
    } else if (now >= peak2Start && now < halfpeak2Start) {
      tariffInfo.tariffIndex = 3; tariffInfo.zoneName = "Пик2"; tariffInfo.shortName = "T3_peak";
    } else if (now >= halfpeak2Start && now < nightStart) {
      tariffInfo.tariffIndex = 4; tariffInfo.zoneName = "Полупик2"; tariffInfo.shortName = "T4_halfpeak";
    }
    return tariffInfo;
  }

  return tariffInfo;
}

function getTariffsSummaryString() {
  var cfg = getTariffConfig();
  if (cfg.count === 1) return "Одноставочный (круглосуточно)";
  var tariffs = [];
  if (cfg.count === 2) {
    tariffs.push({ name: "День", startStr: cfg.startStrings[0] });
    tariffs.push({ name: "Ночь", startStr: cfg.startStrings[1] });
  } else if (cfg.count === 3) {
    tariffs.push({ name: "Ночь", startStr: cfg.startStrings[1] });
    tariffs.push({ name: "Пик1", startStr: cfg.startStrings[2] });
    tariffs.push({ name: "Полупик1", startStr: cfg.startStrings[3] });
    tariffs.push({ name: "Пик2", startStr: cfg.startStrings[4] });
    tariffs.push({ name: "Полупик2", startStr: cfg.startStrings[5] });
  }
  var parts = [];
  for (var i = 0; i < tariffs.length; i++) {
    parts.push(tariffs[i].name + " (с " + tariffs[i].startStr + ")");
  }
  return parts.join("; ");
}

function readChTotalAP(ch) {
  var topicName = dev["map12e_tariffs"]["energy_topic"];
  if (!topicName) {
    log.error("Название топика не задано!");
    return null;
  }
  var ctrlName = "Ch " + ch + " " + topicName;
  if (dev[meterDevice] && dev[meterDevice][ctrlName] !== undefined) {
    var v = parseFloat(dev[meterDevice][ctrlName]);
    return isNaN(v) ? null : v;
  }
  log.error("Контрол '" + ctrlName + "' не найден на устройстве '" + meterDevice + "'.");
  return null;
}

// Обновление индикатора (можно передать tariffInfo чтобы не пересчитывать)
function updateTariffInfo(tariffInfoOptional) {
  var ti = tariffInfoOptional || getTariffInfo();
  var summary = getTariffsSummaryString();
  var indicator = (ti.shortName ? ti.shortName + ": " + ti.zoneName : "Неопределён") +
                  " (обновлено: " + (new Date()).toLocaleTimeString() + ")";
  dev["map12e_data"]["active_tariff_indicator"] = indicator;
  dev["map12e_data"]["tariffs_summary"] = summary;
}

// Инициализация
setTimeout(function() {
  log("Первоначальная инициализация скрипта...");
  for (var i = 1; i <= channels; i++) {
    var id = ("0" + i).slice(-2);
    var tot = readChTotalAP(i);
    if (tot !== null) {
      dev["map12e_data"]["ch" + id + "_last_total"] = tot;
      dev["map12e_data"]["ch" + id + "_status"] = "initialized";
    } else {
      dev["map12e_data"]["ch" + id + "_status"] = "error: no read";
    }
  }
  // валидируем и устанавливаем индикатор корректно
  var cfg_init = getTariffConfig();
  if (!validateTimeRanges(cfg_init)) {
    log.error("Инициализация: неверные временные границы тарифов. Индикатор покажет 'Ночь (fallback)'.");
    updateTariffInfo({ shortName: "T2_night", zoneName: "Ночь" });
  } else {
    updateTariffInfo();
  }
}, 5000);

function findFallbackTariffControl(id) {
  var order = ["T1_day", "T2_night", "T3_peak", "T4_halfpeak"];
  for (var k = 0; k < order.length; k++) {
    var cand = "ch" + id + "_" + order[k];
    if (dev["map12e_data"][cand] !== undefined) return cand;
  }
  return null;
}

// ----- Основной цикл -----
defineRule("map12e_data_aggregator", {
  when: cron("*/" + Math.max(5, updateIntervalSec) + " * * * * *"),
  then: function() {
    var cfg = getTariffConfig();

    // 1) валидируем строго **перед** вычислением/публикацией tariffInfo
    var valid = validateTimeRanges(cfg);
    var tariffInfo;
    if (!valid) {
      log.error("Ошибка в настройках времени — используем fallback: Ночь (T2_night). Проверьте строки t3..t6 и t2.");
      tariffInfo = { shortName: "T2_night", zoneName: "Ночь", tariffIndex: 2 };
      updateTariffInfo(tariffInfo);
    } else {
      tariffInfo = getTariffInfo(cfg);
      updateTariffInfo(tariffInfo);
    }

    for (var i = 1; i <= channels; i++) {
      var id = ("0" + i).slice(-2);
      var total = readChTotalAP(i);
      if (total === null) {
        if (dev["map12e_data"]["ch" + id + "_status"] !== "error: no comm") {
          dev["map12e_data"]["ch" + id + "_status"] = "error: no comm";
        }
        continue;
      }

      var last = parseFloat(dev["map12e_data"]["ch" + id + "_last_total"]) || 0;

      // 1) ручной ввод — перезаписываем целевой тарифный контрол
      var manualControls = [
        "ch" + id + "_T1_day_manual",
        "ch" + id + "_T2_night_manual",
        "ch" + id + "_T3_peak_manual",
        "ch" + id + "_T4_halfpeak_manual"
      ];
      var manualDone = false;
      for (var m = 0; m < manualControls.length; m++) {
        var mc = manualControls[m];
        var raw = dev["map12e_data"][mc];
        var mv = parseFloat(raw);
        if (isNaN(mv)) mv = 0;
        if (mv !== 0) {
          var controlName = mc.replace("_manual", "");
          if (dev["map12e_data"][controlName] === undefined) {
            log("warning: целевой контрол не найден: " + controlName + ". Использую fallback.");
            var fb = findFallbackTariffControl(id);
            if (fb) {
              controlName = fb;
              log("warning: fallback: " + controlName);
            } else {
              log.error("Не найден ни один тарифный контрол для ch" + id + ". Ручной ввод пропущен.");
              dev["map12e_data"][mc] = 0;
              continue;
            }
          }
          // ПЕРЕЗАПИСЫВАЕМ значение (по вашему требованию)
          dev["map12e_data"][controlName] = parseFloat(mv.toFixed(6));
          dev["map12e_data"][mc] = 0;
          dev["map12e_data"][mc.replace("_manual", "_last_update")] = (new Date()).toLocaleString();
          manualDone = true;
          dev["map12e_data"]["ch" + id + "_status"] = "manual overwritten";
          log("Manual overwrite: " + controlName + " = " + mv + " (ch" + id + ")");
        }
      }

      // 2) обработка дельты (используем tariffInfo, который уже был валидно установлен)
      var delta = total - last;
      log("DBG ch" + id + " total=" + total + " last=" + last + " delta=" + delta + " using tariff=" + tariffInfo.shortName);

      if (delta < -0.000001) {
        dev["map12e_data"]["ch" + id + "_status"] = "warning: reset";
        dev["map12e_data"]["ch" + id + "_last_total"] = total;
        continue;
      }
      if (delta > maxDeltaKwh) {
        dev["map12e_data"]["ch" + id + "_status"] = "warning: big jump";
        continue;
      }

      if (delta > 0) {
        var target = null;
        if (tariffInfo && tariffInfo.shortName) {
          target = "ch" + id + "_" + tariffInfo.shortName;
        }
        if (!target || dev["map12e_data"][target] === undefined) {
          log("warning: контрол для дельты не найден: " + target + ". Ищу fallback.");
          var fb2 = findFallbackTariffControl(id);
          if (fb2) {
            target = fb2;
            log("warning: fallback для дельты: " + target);
          } else {
            log.error("Не найден тарифный контрол для дельты ch" + id + ". Пропускаю.");
            dev["map12e_data"]["ch" + id + "_last_total"] = total;
            continue;
          }
        }
        var prevVal = parseFloat(dev["map12e_data"][target]) || 0;
        dev["map12e_data"][target] = parseFloat((prevVal + delta).toFixed(6));
        log("Delta applied: " + target + " += " + delta + " (ch" + id + ")");
      }

      dev["map12e_data"]["ch" + id + "_last_total"] = total;
      if (!manualDone) {
        if (delta > 0) {
          dev["map12e_data"]["ch" + id + "_status"] = "ok";
        } else {
          if (!dev["map12e_data"]["ch" + id + "_status"]) dev["map12e_data"]["ch" + id + "_status"] = "ok";
        }
      }
    }
  }
});

// Остальные правила — не трогаем (автоконфиг/рефреш)
defineRule("map12e_tariff_auto_config", {
  whenChanged: "map12e_tariffs/tariff_count",
  then: function(newValue) {
    var count = parseInt(newValue, 10);
    if (isNaN(count)) count = 1;
    if (count === 1) {
      dev["map12e_tariffs"]["t1_start"] = "00:00";
      dev["map12e_tariffs"]["t2_start"] = "00:00";
      dev["map12e_tariffs"]["t3_start"] = "00:00";
      dev["map12e_tariffs"]["t4_start"] = "00:00";
      dev["map12e_tariffs"]["t5_start"] = "00:00";
      dev["map12e_tariffs"]["t6_start"] = "00:00";
    } else if (count === 2) {
      dev["map12e_tariffs"]["t1_start"] = "07:00";
      dev["map12e_tariffs"]["t2_start"] = "23:00";
      dev["map12e_tariffs"]["t3_start"] = "00:00";
      dev["map12e_tariffs"]["t4_start"] = "00:00";
      dev["map12e_tariffs"]["t5_start"] = "00:00";
      dev["map12e_tariffs"]["t6_start"] = "00:00";
    } else if (count === 3) {
      dev["map12e_tariffs"]["t1_start"] = "00:00";
      dev["map12e_tariffs"]["t2_start"] = "23:00";
      dev["map12e_tariffs"]["t3_start"] = "07:00";
      dev["map12e_tariffs"]["t4_start"] = "10:00";
      dev["map12e_tariffs"]["t5_start"] = "17:00";
      dev["map12e_tariffs"]["t6_start"] = "21:00";
    }
    updateTariffInfo();
  }
});

defineRule("map12e_tariff_refresher", {
  whenChanged: "map12e_data/refresh_tariffs",
  then: function(newValue) {
    if (newValue) {
      var cfg = getTariffConfig();
      if (!validateTimeRanges(cfg)) {
        updateTariffInfo({ shortName: "T2_night", zoneName: "Ночь" });
      } else {
        updateTariffInfo();
      }
    }
  }
});

// initial trick to trigger widgets
setTimeout(function() {
  dev["map12e_tariffs"]["tariff_count"] = dev["map12e_tariffs"]["tariff_count"];
}, 6000);
