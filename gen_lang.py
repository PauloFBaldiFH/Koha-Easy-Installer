#!/usr/bin/env python3
import re
import base64
import os

# Caminho para o seu instalador atual
INSTALLER_FILE = "installer"
LANG_DIR = "lang"

os.makedirs(LANG_DIR, exist_ok=True)

def extract_strings():
    """Varre o script Bash e extrai todas as strings dentro de t '...' ou t \"...\""""
    if not os.path.exists(INSTALLER_FILE):
        print(f"[ERRO] Arquivo {INSTALLER_FILE} não encontrado.")
        return set()
    
    with open(INSTALLER_FILE, "r", encoding="utf-8") as f:
        content = f.read()
    
    # Regex para capturar o conteúdo dentro de t "..."
    # Ignora strings vazias ou variáveis puras
    pattern = r'\bt\s+"([^"\\]*(?:\\.[^"\\]*)*)"'
    matches = re.findall(pattern, content)
    
    unique_strings = sorted(list(set(matches)))
    return unique_strings

if __name__ == "__main__":
    strings = extract_strings()
    print(f"[INFO] Total de strings únicas encontradas com t(): {len(strings)}")
    
    # Exemplo de geração do esqueleto para o Português (pt.cache)
    pt_cache_path = os.path.join(LANG_DIR, "pt.cache")
    with open(pt_cache_path, "w", encoding="utf-8") as out:
        for s in strings:
            # Aqui você define a tradução (exemplo básico mantendo a original ou traduzida)
            translated = s  # Substitua pela tradução real em português
            
            k_b64 = base64.b64encode(s.encode("utf-8")).decode("utf-8")
            v_b64 = base64.b64encode(translated.encode("utf-8")).decode("utf-8")
            out.write(f"{k_b64}={v_b64}\n")
            
    print(f"[OK] Esqueleto gerado em {pt_cache_path}")
