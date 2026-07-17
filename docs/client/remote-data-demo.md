# Демо remote data и runtime-ресурсов

Страница [test_pages/remote_data_demo.html](../../test_pages/remote_data_demo.html) показывает
динамическую карусель из пяти элементов. Открыть её можно с локальной стартовой страницы или
напрямую:

```text
vrwebresource://remote_data_demo.html
```

Для каждого слайда Luau параллельно загружает JSON-текст и изображение. Первые четыре изображения
используют сокращённый блок `document.assets.load(..., "image", callback)`. Пятый намеренно
разворачивает ту же операцию:

```lua
document.assets.fetch(url, "bytes", function(event)
  local image = event.ok and document.assets.decode(event.data, "image") or nil
  if image then
    image.apply(material, "albedo_texture")
  end
end)
```

Так автор может перед декодированием проверить, выбрать или преобразовать сырые данные. Та же
модель используется для `audio-mp3`/`audio-ogg`/`audio-wav` и `mesh-gltf`: меняются только тип
декодера и целевое свойство. Opaque resource не выходит из capability и применяется через
проверяемый host path.

Защищённый ресурс запрашивается через `fetch_with`/`load_with` и явный
`{credentials = "include"}`. Страница самого Home Server может получить свой origin-scoped
Bearer, а внешний HTTPS origin — только сертификат пользователя и подписанный proof конкретного
GET URL. Обычные слайды демо
оставлены анонимными: публичная картинка не должна узнавать глобальную identity без необходимости.
Формат заголовков и серверная проверка описаны в
[home-server.md](../network/home-server.md#подписанный-get-защищённых-ресурсов).

Кнопка `LOCAL NEXT` меняет слайд только на текущем клиенте. `AUTHORITY SYNC` отправляет следующий
индекс всем участникам через существующий `document.remote.call`. Локальный endpoint принимает
намерение только если transport-подтверждённый `event.caller.is_authority`, после чего каждый
клиент самостоятельно загружает ресурс. Байты изображения не рассылаются через remote call.

Демо использует generation counter: если пользователь быстро нажал кнопку, поздний ответ старого
запроса не перезапишет новый слайд. Это обязательный прикладной паттерн, потому что completion
асинхронных запросов не упорядочен.

Автотест `tests/test_remote_data.tscn` работает без внешней сети: получает bundle-текст и SVG как
bytes, передаёт bytes в `decode("image")`, применяет opaque resource к материалу, а также создаёт
тестовый RSA identity и проверяет URL-bound proof тем же публичным ключом, который видит владелец
ресурса.
