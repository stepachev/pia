Проверка модуля Sources/PiaChat/Context (основной Package.swift не трогает).
  ./build.sh [6|5]                     — собрать (Swift 6 по умолчанию)
  ./context-check                      — захват frontmost-приложения
  ./context-check --delay=3            — подождать 3 с (успеть переключиться) и захватить
  ./context-check --app=dev.serafim.fast — захват конкретного приложения (Yab)
  ./context-check --shift              — тест жеста «двойной правый Shift» на синтетических событиях
  ./context-check --text-test          — тесты очистки/обрезки текста окна
  ./context-check --trim-test          — тесты обрезки однотонных полей снимка на синтетических картинках
  ./context-check --shot=путь.png      — прогнать готовую картинку через обрезку + 800 px (PIA_TRIM_DEBUG=1 — края)
