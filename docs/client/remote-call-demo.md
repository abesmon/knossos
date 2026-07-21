# Демо Remote Call, ranks и участников

Страница [test_pages/remote_call.html](../../test_pages/remote_call.html) показывает адресованный
`document.remote.call` как доставку намерения, решение по которому принимает локальный Luau
handler на клиенте адресата. Открыть её можно ссылкой с локальной стартовой страницы или напрямую:

```text
vrwebresource://remote_call.html
```

Три кнопки рассылают запрос всем из `document.players.all()` и ведут на три разные площадки:

1. `move-unchecked` всегда вызывает `document.player.set("position", ...)`;
2. `move-authority` делает это только при `event.caller.is_authority`;
3. `move-rank` требует назначенный `event.caller.rank <= 10`.

Каждый endpoint имеет собственную реакцию: его статус показывает caller, rank и локальный итог
`ПРИНЯТО`/`ОТКЛОНЕНО`. Remote sender не передаёт поля полномочий аргументами — `caller` строится
получателем из фактического peer и локальных таблиц identity/ranks/authority.

Левая панель показывает локальные rank, authority, право управления ranks, verification и
состояние комнаты. Правая — всех известных участников инстанса. Обе подписаны на
`document.players.on_changed`, поэтому обновляются без перезапуска script realm при смене rank,
authority, identity, состава комнаты и состояния связи.

В offline mode список всё равно содержит локального участника с `peer_id = 0`, поэтому открытый
сценарий можно проверить одним клиентом. Для authority/rank сценариев удобно запустить несколько
изолированных клиентов и менять rank через существующий интерфейс инстанса.
