#!/usr/bin/env bash
# =============================================================================
#  setup-mint.sh — Configuração do notebook de trabalho (Linux Mint 22.x / LMDE)
#  Autor: Saulo Prado · https://github.com/sauloprado/mint-pos-instalacao
#
#  Uso:
#     chmod +x setup-mint.sh
#     ./setup-mint.sh           -> pergunta seção por seção (Enter = Sim)
#     ./setup-mint.sh --tudo    -> instala tudo sem perguntar
#
#  NÃO rode com sudo. O script pede a senha quando precisar.
#  Log completo em: ~/setup-mint-AAAAMMDD-HHMM.log
# =============================================================================
set -o pipefail

LOG="$HOME/setup-mint-$(date +%Y%m%d-%H%M).log"
exec > >(tee -a "$LOG") 2>&1

# ----------------------------------------------------------------- utilidades
AZUL='\e[1;34m'; VERDE='\e[1;32m'; AMARELO='\e[1;33m'; VERMELHO='\e[1;31m'; NC='\e[0m'
FALHAS=()
TUDO=0; [[ "${1:-}" == "--tudo" ]] && TUDO=1

titulo() { echo -e "\n${AZUL}══════════════════════════════════════════════${NC}\n${AZUL}  $*${NC}\n${AZUL}══════════════════════════════════════════════${NC}"; }
info()   { echo -e "${AZUL}==>${NC} $*"; }
ok()     { echo -e "${VERDE}✔${NC} $*"; }
aviso()  { echo -e "${AMARELO}!${NC} $*"; }
erro()   { echo -e "${VERMELHO}✘${NC} $*"; FALHAS+=("$*"); }

perguntar() {   # perguntar "texto"  -> 0 = sim
    [[ $TUDO -eq 1 ]] && return 0
    local r
    read -rp "$(echo -e "${AMARELO}?${NC} $1 [S/n] ")" r
    [[ -z "$r" || "$r" =~ ^[SsYy] ]]
}

tentar() {      # tentar "descrição" função/comando [args]
    local desc="$1"; shift
    info "$desc..."
    if "$@"; then ok "$desc"; else erro "$desc"; fi
}

apt_i() {       # instala pacotes apt; se o lote falhar, tenta um a um
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" && return 0
    local p rc=0
    for p in "$@"; do
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" || { erro "apt: $p"; rc=1; }
    done
    return $rc
}

flat_i() {      # instala apps do Flathub (sistema)
    local app rc=0
    for app in "$@"; do
        sudo flatpak install -y --noninteractive flathub "$app" || { erro "flatpak: $app"; rc=1; }
    done
    return $rc
}

apt_update() { sudo apt-get update -qq; }

ultima_release() {  # ultima_release dono/repo -> tag da última versão no GitHub
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -Po '"tag_name":\s*"\K[^"]+'
}

# ----------------------------------------------------------- verificações
if [[ $EUID -eq 0 ]]; then
    echo "Rode como seu usuário normal (sem sudo): ./setup-mint.sh"; exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
    BASE=ubuntu;  CODENAME=$UBUNTU_CODENAME
elif [[ -n "${DEBIAN_CODENAME:-}" ]]; then
    BASE=debian;  CODENAME=$DEBIAN_CODENAME
else
    BASE=ubuntu;  CODENAME=$(lsb_release -cs 2>/dev/null)
fi
ARCH=$(dpkg --print-architecture)
TMPD=$(mktemp -d)

titulo "Setup do notebook — ${PRETTY_NAME:-Linux}"
info "Base detectada: $BASE ($CODENAME) | Arquitetura: $ARCH"
info "Log: $LOG"
[[ "${ID:-}" != "linuxmint" ]] && { aviso "Este sistema não é Linux Mint."; perguntar "Continuar mesmo assim?" || exit 1; }
[[ "$ARCH" != "amd64" ]] && aviso "Arquitetura $ARCH: Chrome, Edge e AnyDesk só existem para amd64 e serão pulados se falharem."

# mantém o sudo ativo durante a execução
sudo -v || exit 1
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null; rm -rf "$TMPD"' EXIT

# =============================================================================
#  0. PONTO DE RESTAURAÇÃO
# =============================================================================
secao_timeshift() {
    titulo "0. Ponto de restauração (Timeshift)"
    if [[ -f /etc/timeshift/timeshift.json ]] && command -v timeshift >/dev/null; then
        tentar "Criar snapshot 'Antes do setup-mint'" sudo timeshift --create --comments "Antes do setup-mint" --tags O
    else
        aviso "Timeshift ainda não configurado — abra 'Timeshift' no menu, configure uma vez e rode o script de novo se quiser o snapshot."
    fi
}

# =============================================================================
#  1. BASE: atualização, codecs, utilitários, firewall
# =============================================================================
secao_base() {
    titulo "1. Sistema base"
    tentar "Atualizar lista de pacotes" apt_update
    tentar "Atualizar o sistema (full-upgrade)" sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

    tentar "Utilitários essenciais" apt_i \
        curl wget gpg ca-certificates apt-transport-https software-properties-common \
        git build-essential htop btop tree unzip p7zip-full unrar xclip \
        gparted ufw flatpak

    tentar "Codecs multimídia (mint-meta-codecs)" apt_i mint-meta-codecs

    tentar "Fontes para código (Fira Code, JetBrains Mono)" apt_i fonts-firacode fonts-jetbrains-mono

    tentar "Habilitar Flathub" sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    tentar "Ativar firewall (ufw: bloqueia entrada, libera saída)" bash -c \
        'sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw --force enable'
}

# =============================================================================
#  2. TRABALHO / COMUNICAÇÃO
# =============================================================================
ms_key() {
    [[ -s /usr/share/keyrings/microsoft.gpg ]] && return 0
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
}

instalar_chrome() {
    command -v google-chrome >/dev/null && { info "Chrome já instalado"; return 0; }
    wget -qO "$TMPD/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        && apt_i "$TMPD/chrome.deb"
}

instalar_edge() {
    command -v microsoft-edge >/dev/null && { info "Edge já instalado"; return 0; }
    ms_key || return 1
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" \
        | sudo tee /etc/apt/sources.list.d/microsoft-edge.list >/dev/null
    apt_update && apt_i microsoft-edge-stable
}

instalar_anydesk() {
    command -v anydesk >/dev/null && { info "AnyDesk já instalado"; return 0; }
    sudo install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL https://keys.anydesk.com/repos/DEB-GPG-KEY | sudo tee /etc/apt/keyrings/keys.anydesk.com.asc >/dev/null; then
        sudo chmod a+r /etc/apt/keyrings/keys.anydesk.com.asc
        echo "deb [signed-by=/etc/apt/keyrings/keys.anydesk.com.asc] https://deb.anydesk.com all main" \
            | sudo tee /etc/apt/sources.list.d/anydesk-stable.list >/dev/null
        apt_update && apt_i anydesk && return 0
    fi
    aviso "Repositório do AnyDesk falhou — tentando pelo Flathub"
    sudo rm -f /etc/apt/sources.list.d/anydesk-stable.list
    flat_i com.anydesk.Anydesk
}

secao_trabalho() {
    titulo "2. Trabalho / comunicação"
    tentar "Google Chrome"      instalar_chrome
    tentar "Microsoft Edge"     instalar_edge
    tentar "Teams for Linux (cliente não oficial do Microsoft Teams)" flat_i com.github.IsmaelMartinez.teams_for_linux
    tentar "Remmina (RDP/VNC/SSH)" apt_i remmina remmina-plugin-rdp remmina-plugin-vnc
    tentar "AnyDesk"            instalar_anydesk
    tentar "Plugins de VPN (OpenVPN, OpenConnect, WireGuard)" apt_i \
        network-manager-openvpn-gnome network-manager-openconnect-gnome wireguard-tools
}

# =============================================================================
#  3. DESENVOLVIMENTO
# =============================================================================
configurar_git() {
    git config --global init.defaultBranch main
    git config --global pull.rebase false
    git config --global core.autocrlf input
    if [[ -z "$(git config --global user.name)" ]]; then
        if [[ $TUDO -eq 1 ]]; then
            aviso "Git sem nome/e-mail — configure depois com: git config --global user.name/user.email"
            return 0
        fi
        local nome email
        read -rp "  Nome para os commits do Git: " nome
        read -rp "  E-mail para os commits do Git: " email
        [[ -n "$nome" ]] && git config --global user.name "$nome"
        [[ -n "$email" ]] && git config --global user.email "$email"
    fi
    return 0
}

instalar_vscode() {
    command -v code >/dev/null && { info "VS Code já instalado"; return 0; }
    ms_key || return 1
    sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
    echo "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections
    apt_update && apt_i code
}

instalar_gh() {
    command -v gh >/dev/null && { info "GitHub CLI já instalado"; return 0; }
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    apt_update && apt_i gh
}

instalar_node() {
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
        local v; v=$(ultima_release nvm-sh/nvm); v=${v:-v0.40.3}
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$v/install.sh" | bash || return 1
    fi
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" || return 1
    nvm install --lts && nvm alias default 'lts/*' && node -v
}

instalar_docker() {
    command -v docker >/dev/null && { info "Docker já instalado"; sudo usermod -aG docker "$USER"; return 0; }
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$BASE/gpg" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg || return 1
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$BASE $CODENAME stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt_update && apt_i docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        && sudo usermod -aG docker "$USER"
}

instalar_claude_code() {
    command -v claude >/dev/null && { info "Claude Code já instalado"; return 0; }
    curl -fsSL https://claude.ai/install.sh | bash
}

secao_dev() {
    titulo "3. Desenvolvimento"
    tentar "Configurar Git"                     configurar_git
    tentar "Visual Studio Code"                 instalar_vscode
    tentar "GitHub CLI (gh)"                    instalar_gh
    tentar "Python (pip, venv, pipx)"           apt_i python3-pip python3-venv python3-dev pipx
    pipx ensurepath >/dev/null 2>&1
    tentar "Node.js LTS via nvm"                instalar_node
    tentar "Docker Engine + Compose"            instalar_docker
    tentar "DBeaver e Postman (Flathub)"        flat_i io.dbeaver.DBeaverCommunity com.getpostman.Postman
    if perguntar "Instalar também o Claude Code (CLI)?"; then
        tentar "Claude Code"                    instalar_claude_code
    fi
}

# =============================================================================
#  4. PRODUTIVIDADE / OFFICE
# =============================================================================
secao_produtividade() {
    titulo "4. Produtividade / Office"
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections
    tentar "Fontes Microsoft (Arial, Times, Verdana...)" apt_i ttf-mscorefonts-installer
    tentar "OnlyOffice Desktop (compatível com .docx/.xlsx/.pptx)" flat_i org.onlyoffice.desktopeditors
    tentar "Flameshot (captura de tela)" apt_i flameshot
    tentar "Obsidian (notas)"            flat_i md.obsidian.Obsidian
}

# =============================================================================
#  5. MÍDIA / DESIGN
# =============================================================================
secao_midia() {
    titulo "5. Mídia / design"
    tentar "VLC, GIMP e Inkscape" apt_i vlc gimp inkscape
    tentar "OBS Studio e Kdenlive (Flathub)" flat_i com.obsproject.Studio org.kde.kdenlive
}

# =============================================================================
#  6. ONEDRIVE PESSOAL (cliente abraunegg + OneDriveGUI)
# =============================================================================
instalar_onedrive() {
    local repo
    if [[ $BASE == ubuntu ]]; then
        case $CODENAME in
            jammy)    repo=xUbuntu_22.04 ;;   # Mint 21.x
            noble)    repo=xUbuntu_24.04 ;;   # Mint 22.x
            questing) repo=xUbuntu_25.10 ;;
            resolute) repo=xUbuntu_26.04 ;;
            *) echo "Base $CODENAME sem pacote oficial do cliente OneDrive"; return 1 ;;
        esac
    else
        case $CODENAME in
            bullseye) repo=Debian_11 ;;       # LMDE 5
            bookworm) repo=Debian_12 ;;       # LMDE 6
            trixie)   repo=Debian_13 ;;       # LMDE 7
            *) echo "Base $CODENAME sem pacote oficial do cliente OneDrive"; return 1 ;;
        esac
    fi

    # remove versão antiga/bugada dos repositórios do Ubuntu (recomendação do projeto)
    if dpkg -s onedrive &>/dev/null && [[ ! -f /etc/apt/sources.list.d/onedrive.list ]]; then
        sudo apt-get remove -y onedrive
    fi
    sudo rm -f /etc/systemd/user/default.target.wants/onedrive.service

    local url="https://download.opensuse.org/repositories/home:/npreining:/debian-ubuntu-onedrive/$repo"
    wget -qO - "$url/Release.key" | gpg --dearmor | sudo tee /usr/share/keyrings/obs-onedrive.gpg >/dev/null || return 1
    echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/obs-onedrive.gpg] $url/ ./" \
        | sudo tee /etc/apt/sources.list.d/onedrive.list >/dev/null
    apt_update && sudo apt-get install -y --no-install-recommends --no-install-suggests onedrive \
        && onedrive --version
}

instalar_onedrivegui() {
    local fuse=libfuse2
    apt-cache show libfuse2t64 &>/dev/null && fuse=libfuse2t64
    apt_i "$fuse" || return 1

    local dir="$HOME/Applications" url
    mkdir -p "$dir" "$HOME/.local/share/applications"
    url=$(curl -fsSL https://api.github.com/repos/bpozdena/OneDriveGUI/releases/latest \
          | grep -Po '"browser_download_url":\s*"\K[^"]+\.AppImage' | head -n1)
    [[ -z "$url" ]] && { echo "AppImage do OneDriveGUI não encontrado"; return 1; }
    wget -qO "$dir/OneDriveGUI.AppImage" "$url" && chmod +x "$dir/OneDriveGUI.AppImage" || return 1

    cat > "$HOME/.local/share/applications/onedrivegui.desktop" <<EOF
[Desktop Entry]
Name=OneDrive (OneDriveGUI)
Comment=Sincronização do OneDrive pessoal
Exec=$dir/OneDriveGUI.AppImage
Icon=folder-remote
Terminal=false
Type=Application
Categories=Network;FileTransfer;
StartupWMClass=OneDriveGUI
EOF
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    return 0
}

secao_onedrive() {
    titulo "6. OneDrive pessoal"
    tentar "Cliente OneDrive (abraunegg, repositório oficial OBS)" instalar_onedrive
    tentar "OneDriveGUI (interface gráfica, AppImage)"             instalar_onedrivegui
}

# =============================================================================
#  EXECUÇÃO
# =============================================================================
perguntar "Criar ponto de restauração no Timeshift antes? (recomendado)" && secao_timeshift
perguntar "1. Sistema base (atualização, codecs, utilitários, firewall)?"  && secao_base
perguntar "2. Trabalho/comunicação (Chrome, Edge, Teams, Remmina, AnyDesk, VPN)?" && secao_trabalho
perguntar "3. Desenvolvimento (VS Code, Git, gh, Python, Node, Docker, DBeaver, Postman)?" && secao_dev
perguntar "4. Produtividade (fontes MS, OnlyOffice, Flameshot, Obsidian)?" && secao_produtividade
perguntar "5. Mídia/design (VLC, GIMP, Inkscape, OBS, Kdenlive)?"          && secao_midia
perguntar "6. OneDrive pessoal (cliente + interface gráfica)?"             && secao_onedrive

titulo "Limpeza"
sudo apt-get autoremove -y >/dev/null && sudo apt-get autoclean -y >/dev/null && ok "Pacotes órfãos removidos"

# ----------------------------------------------------------------- resumo
titulo "Resumo"
if [[ ${#FALHAS[@]} -eq 0 ]]; then
    ok "Tudo instalado sem erros."
else
    aviso "${#FALHAS[@]} item(ns) com problema (detalhes no log):"
    for f in "${FALHAS[@]}"; do echo "   - $f"; done
fi

cat <<'EOF'

PRÓXIMOS PASSOS
  1. REINICIE o notebook (necessário para o Docker funcionar sem sudo e para os apps Flatpak aparecerem no menu).
  2. OneDrive: abra "OneDrive (OneDriveGUI)" no menu > Add profile > Sign in with web browser >
     entre com sua conta Microsoft pessoal > escolha a pasta (ex.: ~/OneDrive) > em Settings, marque
     "Start OneDriveGUI on login". A primeira sincronização pode demorar.
     (Use SÓ o OneDriveGUI — não ative também o serviço 'systemctl --user enable onedrive'.)
  3. Drivers: Menu > Gerenciador de drivers (para placa de vídeo/Wi-Fi proprietários, se houver).
  4. Outlook/Teams/To Do como apps: abra no Edge > menu "..." > Aplicativos > Instalar este site como aplicativo.
  5. Node: abra um terminal novo e teste 'node -v'. Docker: após reiniciar, teste 'docker run hello-world'.
EOF
echo -e "\nLog salvo em: $LOG"
