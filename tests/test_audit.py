"""
Аудит и юнит-тесты Admin_vpn.

Почему именно так: скрипты нельзя «просто запустить» на компьютере разработчика,
потому что они меняют систему (ставят пакеты, трогают файрвол). Поэтому оба
скрипта устроены так, что при подключении через `source` функции загружаются,
но main() не выполняется. Тесты вызывают НАСТОЯЩИЕ функции из скриптов
на временных файлах и проверяют результат, в том числе YAML через PyYAML.

Полная проверка на реальной Ubuntu (установка, туннель, WARP, sniffing)
выполняется в tests/integration.sh в GitHub Actions.

Запуск:  python tests/test_audit.py
Нужно:   Python 3.8+, PyYAML, bash (на Windows — Git Bash), shellcheck.
Переменные окружения (необязательно): BASH_BIN, SHELLCHECK_BIN.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
SETUP = "setup.sh"
ADMIN = "vpn-admin.sh"
INSTALL = "install.sh"
SCRIPTS = [SETUP, ADMIN, INSTALL]
ADMIN_URL = "https://raw.githubusercontent.com/Fulsepredict/Admin_vpn/main/vpn-admin.sh"

# Конфиг в том виде, в каком его создавала ПРОШЛАЯ версия setup.sh, плюс
# реальные «наслоения» с живого сервера: продублированный блок Meta и
# вручную добавленный googleapis.com. Именно такой конфиг должен чинить upgrade.
LEGACY_CONFIG = """listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: OldPassword123

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

outbounds:
  - name: warp_proxy
    type: socks5
    socks5:
      addr: 127.0.0.1:40000

acl:
  inline:
    # --- Instagram & Meta Ecosystem (Zero-Detect для Reels/алгоритмов) ---
    - warp_proxy(suffix:instagram.com)
    - warp_proxy(suffix:cdninstagram.com)
    - warp_proxy(suffix:ig.me)
    - warp_proxy(suffix:facebook.com)
    - warp_proxy(suffix:fbcdn.net)
    - warp_proxy(suffix:fbsbx.com)
    - warp_proxy(suffix:meta.com)
    - warp_proxy(suffix:threads.net)
    # --- Instagram & Meta Ecosystem (Zero-Detect для Reels/алгоритмов) ---
    - warp_proxy(suffix:instagram.com)
    - warp_proxy(suffix:cdninstagram.com)
    - warp_proxy(suffix:ig.me)
    - warp_proxy(suffix:facebook.com)
    - warp_proxy(suffix:fbcdn.net)
    - warp_proxy(suffix:fbsbx.com)
    - warp_proxy(suffix:meta.com)
    - warp_proxy(suffix:threads.net)
    # --- OpenAI / ChatGPT ---
    - warp_proxy(suffix:openai.com)
    - warp_proxy(suffix:chatgpt.com)
    - warp_proxy(suffix:oaistatic.com)
    - warp_proxy(suffix:oaiusercontent.com)
    # --- Anthropic / Claude ---
    - warp_proxy(suffix:anthropic.com)
    - warp_proxy(suffix:claude.ai)
    # --- Google & ReCaptcha (без светофоров и гидрантов) ---
    - warp_proxy(suffix:google.com)
    - warp_proxy(suffix:gstatic.com)
    - warp_proxy(suffix:recaptcha.net)
    # --- Стриминги ---
    - warp_proxy(suffix:netflix.com)
    - warp_proxy(suffix:netflix.net)
    - warp_proxy(suffix:nflxvideo.net)
    - warp_proxy(suffix:spotify.com)
    - warp_proxy(suffix:googleapis.com)
    # --- Весь остальной трафик (YouTube и др.) напрямую ---
    - direct(all)
"""

# Конфиг, где строка "password:" встречается ещё и в outbound (socks5 с авторизацией).
# Старый sed менял бы оба пароля — новая функция должна менять только auth.
CONFIG_WITH_SECOND_PASSWORD = LEGACY_CONFIG.replace(
    "      addr: 127.0.0.1:40000\n",
    "      addr: 127.0.0.1:40000\n      username: proxyuser\n      password: SocksSecret999\n",
)


# ------------------------------------------------------------
# Инфраструктура
# ------------------------------------------------------------

def find_bash():
    env = os.environ.get("BASH_BIN")
    if env:
        return env
    if os.name == "nt":
        # Не используем C:\Windows\System32\bash.exe — это WSL, его может не быть
        for candidate in (r"C:\Program Files\Git\bin\bash.exe",
                          r"C:\Program Files (x86)\Git\bin\bash.exe"):
            if os.path.exists(candidate):
                return candidate
        raise RuntimeError("Не найден Git Bash. Укажи путь в BASH_BIN.")
    found = shutil.which("bash")
    if not found:
        raise RuntimeError("bash не найден")
    return found


def find_shellcheck():
    return os.environ.get("SHELLCHECK_BIN") or shutil.which("shellcheck")


BASH = find_bash()


def to_bash_path(path):
    """Путь, понятный и Linux bash, и Git Bash на Windows."""
    return Path(path).as_posix()


def bash(script, source=ADMIN, env=None, check=True):
    """Выполнить фрагмент bash после `source <скрипт>`. Возвращает CompletedProcess."""
    full_env = dict(os.environ)
    full_env.update({"LC_ALL": "C.UTF-8"} if os.name != "nt" else {})
    if env:
        full_env.update(env)
    prelude = f"source ./{source} >/dev/null 2>&1 || true\n" if source else ""
    proc = subprocess.run(
        [BASH, "-c", prelude + script],
        cwd=REPO, env=full_env, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"bash завершился с кодом {proc.returncode}\n--- stdout ---\n{proc.stdout}"
            f"\n--- stderr ---\n{proc.stderr}"
        )
    return proc


class TempConfig:
    """Временный файл конфига, удаляется после теста."""

    def __init__(self, content):
        fd, self.path = tempfile.mkstemp(suffix=".yaml")
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        os.remove(self.path)

    @property
    def bash_path(self):
        return to_bash_path(self.path)

    def read(self):
        with open(self.path, encoding="utf-8") as handle:
            return handle.read()

    def yaml(self):
        return yaml.safe_load(self.read())


def acl_rules(parsed):
    return parsed["acl"]["inline"]


def warp_domains_from_rules(rules):
    prefix = "warp_proxy(suffix:"
    return [r[len(prefix):-1] for r in rules if r.startswith(prefix)]


def bash_array(name, source):
    out = bash(f'printf "%s\\n" "${{{name}[@]}}"', source=source).stdout
    return [line for line in out.splitlines() if line]


def read_text(name):
    return (REPO / name).read_text(encoding="utf-8")


# ------------------------------------------------------------
# Тесты
# ------------------------------------------------------------

TESTS = []


def test(func):
    TESTS.append(func)
    return func


@test
def files_use_lf_line_endings():
    files = SCRIPTS + ["README.md", "tests/test_audit.py", "tests/integration.sh",
                       ".github/workflows/ci.yml"]
    for name in files:
        data = (REPO / name).read_bytes()
        assert b"\r\n" not in data, f"{name}: Windows-переводы строк (CRLF)"


@test
def scripts_have_bash_shebang_and_valid_syntax():
    for name in SCRIPTS + ["tests/integration.sh"]:
        first_line = read_text(name).splitlines()[0]
        assert first_line == "#!/bin/bash", f"{name}: неверный шебанг {first_line!r}"
        bash(f"bash -n ./{name}", source=None)


@test
def shellcheck_reports_no_findings():
    shellcheck = find_shellcheck()
    assert shellcheck, "shellcheck не найден (укажи SHELLCHECK_BIN)"
    proc = subprocess.run([shellcheck, "-x", "-S", "style", *SCRIPTS, "tests/integration.sh"],
                          cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace")
    assert proc.returncode == 0, f"shellcheck нашёл проблемы:\n{proc.stdout}{proc.stderr}"


@test
def sourcing_scripts_does_not_run_main():
    # Если бы main() запускался при source, тесты начали бы ставить пакеты
    for name in (SETUP, ADMIN):
        proc = bash("echo SOURCED_OK", source=name)
        assert proc.stdout.strip().endswith("SOURCED_OK"), f"{name}: source выполнил лишний код"
        assert "Запусти от root" not in proc.stdout + proc.stderr, f"{name}: main() сработал при source"


@test
def warp_domain_lists_match_between_scripts():
    setup_domains = bash_array("WARP_DOMAINS", SETUP)
    admin_domains = bash_array("RECOMMENDED_WARP_DOMAINS", ADMIN)
    assert setup_domains == admin_domains, "Списки доменов в setup.sh и vpn-admin.sh расходятся"
    assert len(setup_domains) == len(set(setup_domains)), "В списке доменов есть повторы"
    for required in ("instagram.com", "googleapis.com", "googleusercontent.com", "claude.com",
                     "chatgpt.com", "threads.com"):
        assert required in setup_domains, f"Нет обязательного домена {required}"


@test
def rendered_config_with_warp_is_valid_and_complete():
    out = bash('render_config "TestPass_123" true', source=SETUP).stdout
    parsed = yaml.safe_load(out)
    assert parsed["listen"] == ":443"
    assert parsed["auth"] == {"type": "password", "password": "TestPass_123"}
    assert parsed["tls"]["cert"] == "/etc/hysteria/server.crt"
    assert parsed["masquerade"]["proxy"]["url"] == "https://www.bing.com"
    # Sniffing — главное исправление: без него ACL не работает для TUN-клиентов
    assert parsed["sniff"]["enable"] is True
    assert parsed["sniff"]["rewriteDomain"] is False
    assert str(parsed["sniff"]["udpPorts"]) == "443"
    assert parsed["outbounds"][0] == {"name": "warp_proxy", "type": "socks5",
                                      "socks5": {"addr": "127.0.0.1:40000"}}
    rules = acl_rules(parsed)
    assert rules[-1] == "direct(all)", "direct(all) должен быть последним правилом"
    assert len(rules) == len(set(rules)), "В ACL есть дубли"
    assert warp_domains_from_rules(rules) == bash_array("WARP_DOMAINS", SETUP)


@test
def rendered_config_without_warp_has_no_acl():
    parsed = yaml.safe_load(bash('render_config "TestPass_123" false', source=SETUP).stdout)
    assert "acl" not in parsed and "outbounds" not in parsed and "sniff" not in parsed
    assert parsed["auth"]["password"] == "TestPass_123"


@test
def sniff_block_identical_in_both_scripts():
    a = bash("sniff_block", source=SETUP).stdout
    b = bash("sniff_block", source=ADMIN).stdout
    assert a == b and "enable: true" in a


@test
def links_identical_in_both_scripts_and_well_formed():
    call = 'build_links "203.0.113.7" "Pass_word-123" "ab12cd"'
    a = bash(call, source=SETUP).stdout
    b = bash(call, source=ADMIN).stdout
    assert a == b, "build_links в setup.sh и vpn-admin.sh дают разный результат"
    links = dict(line.split("\t", 1) for line in a.strip().splitlines())
    assert set(links) == {"porthop", "standard", "nopin", "official"}
    assert links["porthop"] == ("hy2://Pass_word-123@203.0.113.7:443?insecure=1&alpn=h3"
                                "&pinSHA256=ab12cd&mport=443,20000-50000#Hysteria2-PortHop")
    assert links["standard"] == ("hy2://Pass_word-123@203.0.113.7:443?insecure=1&alpn=h3"
                                 "&pinSHA256=ab12cd#Hysteria2")
    assert "pinSHA256" not in links["nopin"] and "mport=443,20000-50000" in links["nopin"]
    assert links["official"].startswith("hysteria2://Pass_word-123@203.0.113.7:443,20000-50000/?")


@test
def links_without_pin_have_no_empty_parameter():
    out = bash('build_links "203.0.113.7" "Pass_word-123" ""', source=ADMIN).stdout
    assert "pinSHA256" not in out


@test
def cert_pin_matches_openssl_fingerprint():
    tmp = tempfile.mkdtemp()
    try:
        key, crt = to_bash_path(Path(tmp) / "k.pem"), to_bash_path(Path(tmp) / "c.pem")
        script = (
            f'openssl ecparam -genkey -name prime256v1 -out "{key}" 2>/dev/null && '
            f'MSYS_NO_PATHCONV=1 openssl req -new -x509 -days 1 -key "{key}" -out "{crt}" -subj "/CN=bing.com" 2>/dev/null && '
            f'echo "PIN=$(cert_pin "{crt}")" && '
            f'openssl x509 -noout -fingerprint -sha256 -in "{crt}"'
        )
        out = bash(script).stdout
        pin = next(line[4:] for line in out.splitlines() if line.startswith("PIN="))
        raw = out.strip().splitlines()[-1].split("=", 1)[1]
        assert pin == raw.replace(":", "").lower()
        assert len(pin) == 64 and all(c in "0123456789abcdef" for c in pin)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def password_validation_rejects_unsafe_input():
    good = ["Abcdefgh", "Pass_word-123", "a" * 64]
    bad = ["short", "a" * 65, "with/slash1", "amp&ersand1", "back\\slash1", "space here1",
           "quote'quote1", 'dq"quote12', "пароль12345", "semi;colon1", "$(reboot)xx", ""]
    for value in good:
        assert bash('validate_password "$V"', env={"V": value}, check=False).returncode == 0, f"отклонён: {value!r}"
    for value in bad:
        assert bash('validate_password "$V"', env={"V": value}, check=False).returncode != 0, f"принят: {value!r}"


@test
def domain_validation_rejects_bad_input():
    good = ["example.com", "sub.example.co.uk", "x-y.io", "tiktok.com"]
    bad = ["", "com", "-bad.com", "bad-.com", "no_underscore.com", "UPPER.COM", "spa ce.com",
           "a..b.com", "domain", "evil.com)\n- direct(all", "1.2.3.4", "пример.рф"]
    # validate_domain есть в обоих скриптах — они должны вести себя одинаково
    for source in (SETUP, ADMIN):
        for value in good:
            rc = bash('validate_domain "$V"', source=source, env={"V": value}, check=False).returncode
            assert rc == 0, f"{source}: отклонён {value!r}"
        for value in bad:
            rc = bash('validate_domain "$V"', source=source, env={"V": value}, check=False).returncode
            assert rc != 0, f"{source}: принят {value!r}"


@test
def password_change_touches_only_auth_section():
    with TempConfig(CONFIG_WITH_SECOND_PASSWORD) as cfg:
        bash('set_auth_password "$CFG" "BrandNew_Pass9"', env={"CFG": cfg.bash_path})
        parsed = cfg.yaml()
        assert parsed["auth"]["password"] == "BrandNew_Pass9"
        assert parsed["outbounds"][0]["socks5"]["password"] == "SocksSecret999", "задет чужой password:"
        assert "    password: BrandNew_Pass9" not in cfg.read(), "сломан отступ"
        assert bash('get_auth_password "$CFG"', env={"CFG": cfg.bash_path}).stdout.strip() == "BrandNew_Pass9"


@test
def password_change_refuses_invalid_password_and_keeps_file():
    with TempConfig(LEGACY_CONFIG) as cfg:
        before = cfg.read()
        proc = bash('set_auth_password "$CFG" "bad/pass&word"', env={"CFG": cfg.bash_path}, check=False)
        assert proc.returncode == 2 and cfg.read() == before


@test
def get_auth_password_reads_auth_not_other_sections():
    with TempConfig(CONFIG_WITH_SECOND_PASSWORD) as cfg:
        for source in (SETUP, ADMIN):
            out = bash('get_auth_password "$CFG"', source=source, env={"CFG": cfg.bash_path}).stdout.strip()
            assert out == "OldPassword123", f"{source}: прочитан не тот пароль ({out!r})"


@test
def acl_add_and_remove_domain():
    with TempConfig(LEGACY_CONFIG) as cfg:
        env = {"CFG": cfg.bash_path}
        bash('acl_add_domain "$CFG" "tiktok.com"', env=env)
        bash('acl_add_domain "$CFG" "tiktok.com"', env=env)  # повтор — без дубля
        rules = acl_rules(cfg.yaml())
        assert rules.count("warp_proxy(suffix:tiktok.com)") == 1
        assert rules[-1] == "direct(all)" and rules[-2] == "warp_proxy(suffix:tiktok.com)"
        assert "      - warp_proxy(suffix:tiktok.com)" not in cfg.read(), "сломан отступ"

        bash('acl_remove_domain "$CFG" "tiktok.com"', env=env)
        assert "tiktok.com" not in cfg.read()
        assert bash('acl_remove_domain "$CFG" "tiktok.com"', env=env, check=False).returncode == 3

        before = cfg.read()
        assert bash('acl_add_domain "$CFG" "bad domain"', env=env, check=False).returncode == 2
        assert cfg.read() == before


@test
def acl_add_domain_fails_cleanly_without_acl():
    no_acl = bash('render_config "TestPass_123" false', source=SETUP).stdout
    with TempConfig(no_acl) as cfg:
        proc = bash('acl_add_domain "$CFG" "tiktok.com"', env={"CFG": cfg.bash_path}, check=False)
        assert proc.returncode == 3 and cfg.read() == no_acl


@test
def acl_dedupe_removes_duplicate_block():
    with TempConfig(LEGACY_CONFIG) as cfg:
        bash('acl_dedupe "$CFG"', env={"CFG": cfg.bash_path})
        rules = acl_rules(cfg.yaml())
        assert len(rules) == len(set(rules))
        assert cfg.read().count("# --- Instagram & Meta") == 1
        assert rules[-1] == "direct(all)"


@test
def add_sniff_block_is_idempotent():
    with TempConfig(LEGACY_CONFIG) as cfg:
        env = {"CFG": cfg.bash_path}
        bash('add_sniff_block "$CFG"', env=env)
        bash('add_sniff_block "$CFG"', env=env)
        assert cfg.read().count("\nsniff:") == 1
        assert cfg.yaml()["sniff"]["enable"] is True
        assert bash('sniff_is_enabled "$CFG"', env=env, check=False).returncode == 0


@test
def sniff_is_enabled_detects_disabled_sniff():
    with TempConfig(LEGACY_CONFIG + "\nsniff:\n  enable: false\n") as cfg:
        assert bash('sniff_is_enabled "$CFG"', env={"CFG": cfg.bash_path}, check=False).returncode != 0
    with TempConfig(LEGACY_CONFIG) as cfg:
        assert bash('sniff_is_enabled "$CFG"', env={"CFG": cfg.bash_path}, check=False).returncode != 0


@test
def upgrade_enables_disabled_sniff():
    # status советует «vpn-admin upgrade», значит upgrade обязан включить выключенный sniffing
    variants = {
        "enable: false": "\nsniff:\n  enable: false\n  timeout: 2s\n",
        "без строки enable": "\nsniff:\n  timeout: 2s\n",
    }
    for title, block in variants.items():
        with TempConfig(LEGACY_CONFIG + block) as cfg:
            env = {"CFG": cfg.bash_path}
            out = bash('upgrade_config_file "$CFG"', env=env).stdout
            assert "sniff-enabled" in out and "sniff-added" not in out, f"{title}: {out!r}"
            parsed = cfg.yaml()
            assert parsed["sniff"]["enable"] is True, title
            assert str(parsed["sniff"]["timeout"]) == "2s", f"{title}: задеты другие настройки"
            assert cfg.read().count("\nsniff:") == 1, f"{title}: блок sniff продублирован"


@test
def rendered_config_keeps_custom_domains():
    out = bash('render_config "TestPass_123" true "tiktok.com" "bad domain" "example.org"', source=SETUP).stdout
    rules = acl_rules(yaml.safe_load(out))
    assert rules[-1] == "direct(all)"
    assert rules[-3:-1] == ["warp_proxy(suffix:tiktok.com)", "warp_proxy(suffix:example.org)"]
    assert not any("bad domain" in r for r in rules), "невалидный домен попал в конфиг"
    assert len(rules) == len(set(rules))


@test
def custom_domains_survive_setup_rerun():
    # Пользователь добавил домены через add-domain; повторный setup.sh не должен их стереть
    with TempConfig(LEGACY_CONFIG) as cfg:
        env = {"CFG": cfg.bash_path}
        bash('acl_add_domain "$CFG" "tiktok.com" && acl_add_domain "$CFG" "example.org"', env=env)
        custom = bash('custom_domains_from_config "$CFG"', source=SETUP, env=env).stdout.split()
        assert custom == ["tiktok.com", "example.org"], custom
        rendered = bash('mapfile -t extra < <(custom_domains_from_config "$CFG"); '
                        'render_config "TestPass_123" true "${extra[@]}"', source=SETUP, env=env).stdout
        domains = warp_domains_from_rules(acl_rules(yaml.safe_load(rendered)))
        assert "tiktok.com" in domains and "example.org" in domains
    missing = bash('custom_domains_from_config "/nonexistent/config.yaml"; echo "rc=$?"', source=SETUP).stdout
    assert missing.strip() == "rc=0"


@test
def upgrade_fixes_legacy_live_config():
    with TempConfig(LEGACY_CONFIG) as cfg:
        out = bash('upgrade_config_file "$CFG"', env={"CFG": cfg.bash_path}).stdout
        assert "sniff-added" in out
        assert "domain-added claude.com" in out and "domain-added googleusercontent.com" in out
        assert "domain-added googleapis.com" not in out, "уже существующий домен добавлен повторно"
        assert "duplicates-removed" in out

        parsed = cfg.yaml()
        assert parsed["auth"]["password"] == "OldPassword123", "upgrade не должен менять пароль"
        assert parsed["sniff"]["enable"] is True
        rules = acl_rules(parsed)
        assert len(rules) == len(set(rules))
        assert rules[-1] == "direct(all)"
        assert set(bash_array("RECOMMENDED_WARP_DOMAINS", ADMIN)) <= set(warp_domains_from_rules(rules))

        # Повторный запуск ничего не меняет
        snapshot = cfg.read()
        again = bash('upgrade_config_file "$CFG"', env={"CFG": cfg.bash_path}).stdout
        assert again.strip() == "" and cfg.read() == snapshot


@test
def upgrade_refuses_config_without_acl():
    no_acl = bash('render_config "TestPass_123" false', source=SETUP).stdout
    with TempConfig(no_acl) as cfg:
        proc = bash('upgrade_config_file "$CFG"', env={"CFG": cfg.bash_path}, check=False)
        assert proc.returncode == 4 and proc.stdout.strip() == "no-acl" and cfg.read() == no_acl


@test
def fresh_config_needs_no_upgrade():
    fresh = bash('render_config "TestPass_123" true', source=SETUP).stdout
    with TempConfig(fresh) as cfg:
        out = bash('upgrade_config_file "$CFG"', env={"CFG": cfg.bash_path}).stdout
        assert out.strip() == "" and cfg.read() == fresh


@test
def version_comparison():
    cases = [("2.6.1", "2.5.2", True), ("2.5.2", "2.5.2", True), ("2.13.0", "2.5.2", True),
             ("2.5.1", "2.5.2", False), ("2.4.5", "2.5.2", False), ("1.3.5", "2.5.2", False)]
    for source in (SETUP, ADMIN):
        for a, b, expected in cases:
            rc = bash(f'version_ge "{a}" "{b}"', source=source, check=False).returncode
            assert (rc == 0) == expected, f"{source}: version_ge {a} {b}"


@test
def generated_password_is_safe():
    for _ in range(5):
        pw = bash("generate_password", source=SETUP).stdout.strip()
        assert len(pw) == 24 and pw.isalnum() and pw.isascii(), pw
        assert bash('validate_password "$V"', env={"V": pw}, check=False).returncode == 0


@test
def healthcheck_script_is_valid_and_checks_warp_tunnel():
    script = bash("healthcheck_script").stdout
    assert "__" not in script, "остались незаменённые плейсхолдеры"
    assert 'WARP_PORT=40000' in script and "warp=on" in script
    assert "tail -n" in script, "нет ротации лога"
    with TempConfig(script) as tmp:
        bash(f'bash -n "{tmp.bash_path}"', source=None)


@test
def detect_ssh_ports_uses_current_session_port():
    out = bash("detect_ssh_ports", source=SETUP,
               env={"SSH_CONNECTION": "198.51.100.1 50000 203.0.113.7 2222"}).stdout.split()
    assert "2222" in out
    assert all(p.isdigit() for p in out)


@test
def detect_ssh_ports_survives_failing_sshd():
    # Регрессия из CI: при set -e + pipefail сбой «sshd -T» молча обрывал установщик.
    # Подкладываем в PATH поддельный sshd, который всегда падает.
    tmp = tempfile.mkdtemp()
    try:
        fake = Path(tmp) / "sshd"
        fake.write_text("#!/bin/bash\nexit 1\n", encoding="utf-8", newline="\n")
        fake.chmod(0o755)
        fake_dir = to_bash_path(tmp)
        if os.name == "nt":  # В PATH нельзя «C:/...» (двоеточие — разделитель), нужно «/c/...»
            fake_dir = "/" + fake_dir[0].lower() + fake_dir[2:]
        # Вызов напрямую, а не через $(...): внутри $(...) bash отключает set -e,
        # и баг бы не воспроизвёлся
        script = (f'PATH="{fake_dir}:$PATH"; '
                  'detect_ssh_ports; echo "AFTER_OK"')
        out = bash(script, source=SETUP, env={"SSH_CONNECTION": "198.51.100.1 50000 203.0.113.7 2222"}).stdout
        assert "AFTER_OK" in out, "detect_ssh_ports оборвал скрипт при сбое sshd"
        assert "2222" in out.split()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


@test
def installer_has_no_dangerous_operations():
    setup = read_text(SETUP)
    for forbidden in ("ufw --force reset", "killall", "rm -f /var/lib/dpkg/lock",
                      "rm -f /var/lib/apt/lists/lock", "chmod 644 /etc/hysteria/server.key"):
        assert forbidden not in setup, f"setup.sh содержит опасную операцию: {forbidden}"
    assert "chmod 640" in setup, "ключ и конфиг должны быть закрыты (640)"
    assert "iptables -t nat -C" in setup, "NAT-правило должно проверяться перед добавлением"
    assert "DPkg::Lock::Timeout" in setup


@test
def no_grep_q_after_curl_pipe():
    # curl | grep -q при pipefail даёт ложный «WARP выключен» (SIGPIPE у curl)
    import re
    for name in SCRIPTS:
        for number, line in enumerate(read_text(name).splitlines(), 1):
            assert not re.search(r"curl[^|]*\|\s*grep\s+-q", line), f"{name}:{number}: curl | grep -q"


@test
def repository_urls_are_consistent():
    for name in (SETUP, ADMIN, INSTALL):
        assert ADMIN_URL in read_text(name), f"{name}: нет корректной ссылки на vpn-admin.sh"


@test
def readme_documents_new_commands():
    readme = read_text("README.md")
    for snippet in ("vpn-admin upgrade", "add-domain", "pinSHA256", "sniff", "install.sh"):
        assert snippet in readme, f"README не описывает: {snippet}"
    assert "Zero-Detect" not in readme, "README не должен обещать невыполнимое"


# ------------------------------------------------------------

def main():
    print("=== ADMIN_VPN AUDIT ===")
    print(f"bash: {BASH}")
    passed = 0
    for func in TESTS:
        name = func.__name__
        try:
            func()
        except Exception as error:  # noqa: BLE001 — печатаем любую причину провала
            print(f"[FAIL] {name}\n       {error}")
        else:
            passed += 1
            print(f"[OK]   {name}")
    total = len(TESTS)
    print(f"=== {passed}/{total} checks passed ===")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
