#!/usr/bin/env python3
import re
import base64
import os
import time

try:
    from deep_translator import GoogleTranslator, MyMemoryTranslator
except ImportError:
    print("[ERRO] Instale a biblioteca: pip install deep-translator")
    exit(1)

INSTALLER_FILE = "installer"
LANG_DIR = "lang"
os.makedirs(LANG_DIR, exist_ok=True)

TARGET_LANGUAGES = {
    "pt": "pt-BR",
    "es": "es-ES",
    "fr": "fr-FR",
    "de": "de-DE",
    "it": "it-IT"
}

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
        print(f"[ERRO] Arquivo {INSTALLER_FILE} não encontrado.")
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

def translate_phrase(text, target_locale):
    """Tenta via Google; se bloqueado, usa MyMemory imediatamente."""
    clean_target = target_locale.split('-')[0]
    
    # Tentativa 1: Google
    try:
        res = GoogleTranslator(source="en", target=clean_target).translate(text)
        if res:
            return res
    except Exception:
        pass

    # Tentativa 2: MyMemory (Sem o limite estrito do Google)
    try:
        res = MyMemoryTranslator(source="en-US", target=target_locale).translate(text)
        if res:
            return res
    except Exception:
        pass

    return text

def translate_and_build(strings, lang_code, target_locale):
    cache_path = os.path.join(LANG_DIR, f"{lang_code}.cache")
    print(f"\n[+] Processando idioma: {lang_code.upper()} -> {cache_path}")

    results = {}
    
    # Carrega cache existente para continuar de onde parou
    if os.path.exists(cache_path):
        with open(cache_path, "r", encoding="utf-8") as existing_file:
            for line in existing_file:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    try:
                        k_dec = base64.b64decode(k).decode("utf-8")
                        v_dec = base64.b64decode(v).decode("utf-8")
                        results[k_dec] = v_dec
                    except Exception:
                        pass

    pending = [s for s in strings if s not in results]
    print(f"    Já traduzidas: {len(results)} | Restantes: {len(pending)}")

    for idx, s in enumerate(pending, 1):
        p_text, p_map = protect_text(s)
        trans = translate_phrase(p_text, target_locale)
        results[s] = unprotect_text(trans, p_map)

        # Salva o arquivo a cada 10 frases processadas
        if idx % 10 == 0 or idx == len(pending):
            with open(cache_path, "w", encoding="utf-8") as out:
                for orig in strings:
                    if orig in results:
                        k_b64 = base64.b64encode(orig.encode("utf-8")).decode("utf-8")
                        v_b64 = base64.b64encode(results[orig].encode("utf-8")).decode("utf-8")
                        out.write(f"{k_b64}={v_b64}\n")
            print(f"    Progresso: {idx}/{len(pending)} frases concluídas...")

        time.sleep(0.3)

    print(f"[OK] Idioma {lang_code.upper()} concluído com sucesso!")

if __name__ == "__main__":
    strings = extract_strings()
    print(f"[INFO] Total de frases encontradas: {len(strings)}")

    for lang_code, target_locale in TARGET_LANGUAGES.items():
        translate_and_build(strings, lang_code, target_locale)

    print("\n[SUCESSO] Todos os arquivos foram gerados em lang/.")
