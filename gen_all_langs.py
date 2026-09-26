#!/usr/bin/env python3
import re
import base64
import os
import sys

try:
    import argostranslate.package
    import argostranslate.translate
except ImportError:
    print("[ERRO] Biblioteca em falta! Execute no terminal: pip install argostranslate --break-system-packages")
    sys.exit(1)

INSTALLER_FILE = "installer"
LANG_DIR = "lang"
os.makedirs(LANG_DIR, exist_ok=True)

# 15 idiomas principais
TARGET_LANGS = [
    "pt", "es", "fr", "de", "it",
    "nl", "ru", "pl", "uk", "cs",
    "sv", "tr", "ar", "ja", "zh"
]

PROTECTED_TERMS = [
    r"koha-[a-z0-9_-]+",
    r"mariadb[a-z0-9_-]*",
    r"koha-common",
    r"systemctl",
    r"apache2",
    r"memcached",
    r"elasticsearch",
    r"cloudflared",
    r"config\.sh",
    r"whiptail",
    r"rclone",
    r"Zebra",
    r"Elasticsearch",
    r"MariaDB",
    r"Plack",
    r"RabbitMQ",
    r"OPAC",
    r"Staff",
    r"MARC21",
    r"/etc/[a-zA-Z0-9_\-\./]+",
    r"/var/[a-zA-Z0-9_\-\./]+",
    r"/root/[a-zA-Z0-9_\-\./]+",
    r"http[s]?://[^\s]+",
    r"--[a-z0-9_-]+"
]

def ensure_argos_models(target_codes):
    """Atualiza o catálogo e descarrega pacotes em falta localmente."""
    print("[*] Sincronizando catálogo de modelos do Argos Translate...")
    argostranslate.package.update_package_index()
    available_packages = argostranslate.package.get_available_packages()
    installed_packages = argostranslate.package.get_installed_packages()
    
    installed_codes = {pkg.to_code for pkg in installed_packages if pkg.from_code == "en"}

    for code in target_codes:
        if code in installed_codes:
            print(f"  [✓] Modelo en -> {code} já instalado.")
            continue

        print(f"  [↓] Baixando modelo en -> {code}...")
        pkg = next((p for p in available_packages if p.from_code == "en" and p.to_code == code), None)
        if pkg:
            download_path = pkg.download()
            argostranslate.package.install_from_path(download_path)
            print(f"  [✓] Modelo en -> {code} pronto!")
        else:
            print(f"  [!] Pacote não encontrado no catálogo para o idioma: {code}")

def protect_text(text):
    placeholders = {}
    counter = 0
    text = text.replace(r"\n", " [[N]] ")

    for pattern in PROTECTED_TERMS:
        matches = list(set(re.findall(pattern, text, flags=re.IGNORECASE)))
        for match in matches:
            tag = f"[[P{counter}]]"
            placeholders[tag] = match
            text = text.replace(match, tag)
            counter += 1

    return text, placeholders

def unprotect_text(text, placeholders):
    for tag, original in placeholders.items():
        text = text.replace(tag, original)
        text = text.replace(f"[[ P{tag[3:-2]} ]]", original)

    text = text.replace("[[N]]", r"\n")
    text = text.replace("[[ N ]]", r"\n")
    return text.strip()

def extract_strings():
    if not os.path.exists(INSTALLER_FILE):
        print(f"[ERRO] Arquivo {INSTALLER_FILE} não encontrado no diretório atual.")
        return []

    with open(INSTALLER_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    pattern = r'\bt\s+(?:"([^"\\]*(?:\\.[^"\\]*)*)"|\'([^\'\\]*(?:\\.[^\'\\]*)*)\')'
    matches = re.findall(pattern, content)

    unique_strings = set()
    for double_q, single_q in matches:
        text = double_q if double_q else single_q
        text = text.strip()
        if text and len(text) > 1 and not re.match(r'^\$[A-Za-z0-9_]+$', text):
            unique_strings.add(text)

    return sorted(list(unique_strings))

def process_language(strings, lang_code):
    cache_path = os.path.join(LANG_DIR, f"{lang_code}.cache")
    print(f"\n[+] Processando idioma: {lang_code.upper()} -> {cache_path}")

    existing = {}
    if os.path.exists(cache_path):
        with open(cache_path, "r", encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    try:
                        k_dec = base64.b64decode(k).decode("utf-8")
                        v_dec = base64.b64decode(v).decode("utf-8")
                        existing[k_dec] = v_dec
                    except Exception:
                        pass

    pending = [s for s in strings if s not in existing]
    print(f"    Já traduzidas: {len(existing)} | Restantes: {len(pending)}")

    if not pending:
        print(f"    [✓] Idioma 100% atualizado.")
        return

    installed_languages = argostranslate.translate.get_installed_languages()
    from_lang = next((l for l in installed_languages if l.code == "en"), None)
    to_lang = next((l for l in installed_languages if l.code == lang_code), None)

    if not from_lang or not to_lang:
        print(f"    [!] Motor não carregado para en -> {lang_code}. Pulando...")
        return

    engine = from_lang.get_translation(to_lang)

    for idx, s in enumerate(pending, 1):
        p_text, p_map = protect_text(s)
        try:
            translated_raw = engine.translate(p_text)
            final_text = unprotect_text(translated_raw, p_map)
        except Exception:
            final_text = s

        existing[s] = final_text

        if idx % 50 == 0 or idx == len(pending):
            with open(cache_path, "w", encoding="utf-8") as out:
                for orig in strings:
                    if orig in existing:
                        k_b64 = base64.b64encode(orig.encode("utf-8")).decode("utf-8")
                        v_b64 = base64.b64encode(existing[orig].encode("utf-8")).decode("utf-8")
                        out.write(f"{k_b64}={v_b64}\n")
            print(f"    Progresso: {idx}/{len(pending)} frases concluídas...")

    print(f"[OK] Idioma {lang_code.upper()} concluído!")

def main():
    strings = extract_strings()
    print(f"[INFO] Total de frases encontradas no installer: {len(strings)}")

    ensure_argos_models(TARGET_LANGS)

    for lang in TARGET_LANGS:
        process_language(strings, lang)

    print("\n[SUCESSO] Processamento multilingue concluído para todos os idiomas!")

if __name__ == "__main__":
    main()
