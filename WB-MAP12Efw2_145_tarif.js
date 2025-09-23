// WB-rules: Multi-tariff energy aggregation + единицы измерения + кнопка Refresh
// Версия 3.1 (Исправлено отображение единиц)

// ----- Основные настройки -----
var meterDevice = "wb-map12e_145"; // MQTT ID вашего счетчика MAP12E
var channels = 4; // Количество каналов счетчика для обработки
var updateIntervalSec = 30; // Интервал опроса в секундах (не менее 5)
var maxDeltaKwh = 100.0; // Максимальный скачок потребления для фильтрации ошибок

// ----- Виртуальное устройство для настройки тарифов -----
defineVirtualDevice("map12e_tariffs", {
  title: "MAP12E Tariff Configuration",
  cells: {
    tariff_count: {
      title: "Количество тарифов",
      type: "value",
      value: 2,
      readonly: false
    },
    t1_start: {
      title: "Начало Т1 (ЧЧ:ММ)",
      type: "text",
      value: "07:00",
      readonly: false
    },
    t2_start: {
      title: "Начало Т2 (ЧЧ:ММ)",
      type: "text",
      value: "23:00",
      readonly: false
    },
    t3_start: {
      title: "Начало Т3 (ЧЧ:ММ)",
      type: "text",
      value: "00:00",
      readonly: false
    },
    t4_start: {
      title: "Начало Т4 (ЧЧ:ММ)",
      type: "text",
      value: "00:00",
      readonly: false
    }
  }
});

// ----- Виртуальное устройство для отображения данных -----
var dataCells = {};
dataCells["tariffs_summary"] = {
  title: "Тарифы",
  type: "text",
  value: "инициализация...",
  readonly: true,
  meta: { "order": 1 }
};

for (var i = 1; i <= channels; i++) {
  var id = ("0" + i).slice(-2); // Форматируем номер канала (1 -> 01, 2 -> 02)
  for (var t = 1; t <= 4; t++) {
    dataCells["ch" + id + "_T" + t] = {
      title: "Ch " + i + " T" + t + " Energy",
      // ❗️ИСПРАВЛЕНО ЗДЕСЬ: 'type' должен быть "power_consumption"
      type: "power_consumption", 
      value: 0,
      readonly: true,
      // 'type' убран из meta, здесь ему не место
      meta: { "order": i * 10 + t, "unit": "кВт·ч" } 
    };
  }
  dataCells["ch" + id + "_status"] = {
    title: "Ch " + i + " Status",
    type: "text",
    value: "",
    readonly: true,
    meta: { "order": 101 + i * 10 }
  };
   dataCells["ch" + id + "_last_total"] = {
    title: "Ch " + i + " Total (internal)",
    // ❗️ИСПРАВЛЕНО ЗДЕСЬ: 'type' должен быть "power_consumption"
    type: "power_consumption",
    value: 0,
    readonly: true,
    // 'type' убран из meta
    meta: { "order": 100 + i*10, "unit": "кВт·ч" }
  };
}
// Кнопка для ручного обновления информации о тарифах
dataCells["refresh_tariffs"] = {
  title: "Обновить тарифы",
  type: "pushbutton",
  value: false,
  readonly: false,
  meta: { "order": 4 }
};

defineVirtualDevice("map12e_data", {
  title: "MAP12E Aggregated Data " + meterDevice,
  cells: dataCells
});


// ----- Вспомогательные функции (без изменений) -----

function parseTimeHHMM(str) {
  var parts = str.split(":");
  if (parts.length != 2) return null;
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
  var tc = parseInt(dev["map12e_tariffs"]["tariff_count"], 10) || 1;
  tc = Math.max(1, Math.min(tc, 4));
  var starts = [
    dev["map12e_tariffs"]["t1_start"],
    dev["map12e_tariffs"]["t2_start"],
    dev["map12e_tariffs"]["t3_start"],
    dev["map12e_tariffs"]["t4_start"]
  ];
  var arr = starts.slice(0, tc);
  var arrNum = arr.map(function(s) {
    var v = parseTimeHHMM(s);
    return (v === null ? 0 : v);
  });
  return { count: tc, startStrings: arr, startNums: arrNum };
}

function getTariffIndex() {
  var now = hhmmNow();
  var cfg = getTariffConfig();
  if (cfg.count === 1) return 1;

  var tariffs = [];
  for (var i = 0; i < cfg.count; i++) {
    tariffs.push({ index: i + 1, start: cfg.startNums[i] });
  }
  tariffs.sort(function(a, b) { return a.start - b.start; });

  for (var i = tariffs.length - 1; i >= 0; i--) {
    if (now >= tariffs[i].start) {
      return tariffs[i].index;
    }
  }
  return tariffs[tariffs.length - 1].index;
}

function getTariffsSummaryString(currentTariffIndex) {
  var cfg = getTariffConfig();
  if (cfg.count === 1) {
    return "Т1 (круглосуточно) <-- активен";
  }

  var tariffs = [];
  for (var i = 0; i < cfg.count; i++) {
    tariffs.push({
      index: i + 1,
      startStr: cfg.startStrings[i]
    });
  }
  tariffs.sort(function(a, b) { return a.index - b.index; });

  var summaryParts = [];
  for (var i = 0; i < tariffs.length; i++) {
    var part = "Т" + tariffs[i].index + " (с " + tariffs[i].startStr + ")";
    if (tariffs[i].index === currentTariffIndex) {
      part += " <-- активен";
    }
    summaryParts.push(part);
  }
  return summaryParts.join("; ");
}

function readChTotalAP(ch) {
  var ctrlName = "Ch " + ch + " Total AP energy";
  if (dev[meterDevice] && dev[meterDevice][ctrlName] !== undefined) {
    var v = parseFloat(dev[meterDevice][ctrlName]);
    return isNaN(v) ? null : v;
  }
  return null;
}

// ----- Функция обновления информации о тарифах (без изменений) -----
function updateTariffInfo() {
  log("Обновление информации о тарифах...");
  var tariffIndex = getTariffIndex();
  var summary = getTariffsSummaryString(tariffIndex);
  dev["map12e_data"]["tariffs_summary"] = summary;
  
  var cfg = getTariffConfig();
  for (var i = 1; i <= channels; i++) {
    var id = ("0" + i).slice(-2);
    for (var t = 1; t <= 4; t++) {
      var cellName = "ch" + id + "_T" + t;
      if (t > cfg.count && dev["map12e_data"][cellName] != 0) {
        dev["map12e_data"][cellName] = 0;
      }
    }
  }
  log("Информация о тарифах обновлена. " + summary);
}

// ----- Инициализация (без изменений) -----
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
  updateTariffInfo();
}, 5000);

// ----- Основной цикл обработки данных (без изменений) -----
defineRule("map12e_data_aggregator", {
  when: cron("*/" + Math.max(5, updateIntervalSec) + " * * * * *"),
  then: function() {
    var tariffIndex = getTariffIndex();
    if (!dev["map12e_data"]["tariffs_summary"].includes("Т" + tariffIndex + " <--")) {
        updateTariffInfo();
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
      var delta = total - last;

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
        var tariffControl = "ch" + id + "_T" + tariffIndex;
        var prev = parseFloat(dev["map12e_data"][tariffControl]) || 0;
        dev["map12e_data"][tariffControl] = parseFloat((prev + delta).toFixed(6));
      }
      dev["map12e_data"]["ch" + id + "_last_total"] = total;
      dev["map12e_data"]["ch" + id + "_status"] = "ok";
    }
  }
});

// ----- Обработчик кнопки обновления тарифов (без изменений) -----
defineRule("map12e_tariff_refresher", {
  whenChanged: "map12e_data/refresh_tariffs",
  then: function(newValue, devName, cellName) {
    if (newValue) {
      updateTariffInfo();
    }
  }
});
