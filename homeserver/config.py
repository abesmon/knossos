"""Конфигурация домашнего сервера.

Источники (по возрастанию приоритета): дефолты → INI-файл `homeserver.cfg`
(секция [homeserver], путь можно сменить через VRWEB_CONFIG) → переменные окружения.
Обязателен только `domain` — он входит в адреса пользователей (nick@domain),
менять его на живом сервере нельзя.
"""

from __future__ import annotations

import configparser
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Config:
    domain: str = "localhost"
    name: str = "VRWeb Home"
    homepage: str = ""
    # "" -> производный wss://{domain}/signal (сигналинг-модуль этого же монолита).
    signaling_url: str = ""
    data_dir: Path = Path(__file__).resolve().parent / "data"
    registration_open: bool = True
    session_ttl_days: int = 30
    cert_ttl_days: int = 30
    host: str = "0.0.0.0"
    port: int = 8080

    def effective_signaling_url(self) -> str:
        return self.signaling_url or f"wss://{self.domain}/signal"

    def effective_homepage(self) -> str:
        return self.homepage or f"https://{self.domain}/"


def load_config(path: str | None = None) -> Config:
    cfg = Config()
    ini_path = Path(path or os.environ.get("VRWEB_CONFIG", Path(__file__).with_name("homeserver.cfg")))
    if ini_path.is_file():
        ini = configparser.ConfigParser()
        ini.read(ini_path, encoding="utf-8")
        s = ini["homeserver"] if ini.has_section("homeserver") else ini["DEFAULT"]
        cfg.domain = s.get("domain", cfg.domain)
        cfg.name = s.get("name", cfg.name)
        cfg.homepage = s.get("homepage", cfg.homepage)
        cfg.signaling_url = s.get("signaling_url", cfg.signaling_url)
        cfg.data_dir = Path(s.get("data_dir", str(cfg.data_dir)))
        cfg.registration_open = s.getboolean("registration_open", cfg.registration_open)
        cfg.session_ttl_days = s.getint("session_ttl_days", cfg.session_ttl_days)
        cfg.cert_ttl_days = s.getint("cert_ttl_days", cfg.cert_ttl_days)
        cfg.host = s.get("host", cfg.host)
        cfg.port = s.getint("port", cfg.port)

    env = os.environ
    cfg.domain = env.get("VRWEB_DOMAIN", cfg.domain)
    cfg.name = env.get("VRWEB_NAME", cfg.name)
    cfg.homepage = env.get("VRWEB_HOMEPAGE", cfg.homepage)
    cfg.signaling_url = env.get("VRWEB_SIGNALING_URL", cfg.signaling_url)
    if "VRWEB_DATA_DIR" in env:
        cfg.data_dir = Path(env["VRWEB_DATA_DIR"])
    if "VRWEB_REGISTRATION_OPEN" in env:
        cfg.registration_open = env["VRWEB_REGISTRATION_OPEN"].lower() in ("1", "true", "yes", "on")
    cfg.host = env.get("HOST", cfg.host)
    cfg.port = int(env.get("PORT", cfg.port))
    return cfg
