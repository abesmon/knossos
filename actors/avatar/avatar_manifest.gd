class_name AvatarManifest
extends RefCounted

## Манифест прав на аватар (схема в духе apple-app-site-association): декларация, КОМУ
## разрешено носить аватар. Лежит рядом с файлом аватара по адресу, который клиент ВЫВОДИТ из
## его URL (см. AvatarResolver._manifest_uri) — адрес манифеста никогда не берётся от пира,
## иначе носитель подсунет свой permissive-манифест и обойдёт проверку. Подписи нет: доверие
## даёт origin отдачи файла + контроль записи по этому пути (host == trust).
## См. docs/avatars.md → «Защита владения аватаром».

enum Verdict {
	ALLOWED,      ## allow содержит "*" ИЛИ личность верифицирована и совпала — показываем без предупреждения
	UNCONFIRMED,  ## манифеста нет/не достать ИЛИ личность пира пока невозможно верифицировать — жёлтый «⚠»
	DENIED,       ## манифест есть, личность верифицирована, но носителя в allow нет — (цель) скрыть аватар
}

const WILDCARD := "*"

## Паттерны прав: "*" (всем), "*@host" (любой с host), "user@host" (конкретный).
var allow: PackedStringArray = PackedStringArray()


## Парсит JSON-текст манифеста. null — если текст не валиден или это не объект.
static func parse(text: String) -> AvatarManifest:
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var m := AvatarManifest.new()
	var raw: Variant = (data as Dictionary).get("allow", [])
	if typeof(raw) == TYPE_ARRAY:
		for e: Variant in raw as Array:
			if typeof(e) == TYPE_STRING and (e as String).strip_edges() != "":
				m.allow.append((e as String).strip_edges())
	return m


## Вердикт для носителя с заявленной личностью `identity` ("user@host"; "" — неизвестна) и
## флагом `identity_verified` (подтвердил ли слой идентичности, что пир — это и правда он).
## Пока слоя идентичности нет, его зовут с verified=false → всё кроме "*" даёт UNCONFIRMED.
func evaluate(identity: String, identity_verified: bool) -> Verdict:
	if allow.has(WILDCARD):
		return Verdict.ALLOWED
	if not identity_verified or identity.strip_edges() == "":
		return Verdict.UNCONFIRMED
	for pat in allow:
		if _matches(pat, identity):
			return Verdict.ALLOWED
	return Verdict.DENIED


static func _matches(pattern: String, identity: String) -> bool:
	if pattern == identity:
		return true
	if pattern.begins_with("*@"):
		return identity.ends_with("@" + pattern.substr(2))
	return false
