# Changelog

## 1.4.0 — FB2 compatibility and guarded EPUB support

- Добавлены проверенные на Android AlReaderX/KOReader таблицы FB2, изображения, индексы, зачёркивание и вложенные выделения.
- Добавлено декодирование Windows-1251, KOI8-R, CP866, ISO-8859-5, Windows-1252, ISO-8859-1 и UTF-16 без изменения оригинального размера файла Sync.
- Реализован EPUB с AlReaderX Java UTF-16 filename hash + UUID, учётом OPF spine и XPointer DocFragment.
- Подтверждён импорт EPUB KOReader → AlReaderX (координата 114) на AlReaderX 1.33.
- Добавлены независимые эталонные тесты. Непроверенные конструкции EPUB намеренно отклоняются.


## 1.3.1 (source distribution)

- Standard KOReader plugin layout (`alreaderbridge.koplugin/`).
- Removed hard-coded personal WebDAV addresses and login from the public release.
- Separate configurable backup WebDAV endpoint and optional upstream `backup.koplugin` integration.
- Portable, non-copyrighted FB2 fixture and source tests.
- Original v1.3 position mapping logic retained; functionality still requires testing on the target reader.

## 1.3

- FB2 progress sync and guarded reverse exports.
- Optional integration with KOReader Device Backup & Restore.
