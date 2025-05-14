#!/bin/bash

ROOT=$PWD

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120

DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

# ================ 操作系统依赖安装（保留原逻辑）================
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  if command -v apt &>/dev/null; then
    echo -e "${CYAN}${BOLD}[✓] Debian/Ubuntu detected. Installing build-essential, gcc, g++...${NC}"
    sudo apt update > /dev/null 2>&1
    sudo apt install -y build-essential gcc g++ > /dev/null 2>&1

  elif command -v yum &>/dev/null; then
    echo -e "${CYAN}${BOLD}[✓] RHEL/CentOS detected. Installing Development Tools...${NC}"
    sudo yum groupinstall -y "Development Tools" > /dev/null 2>&1
    sudo yum install -y gcc gcc-c++ > /dev/null 2>&1

  elif command -v pacman &>/dev/null; then
    echo -e "${CYAN}${BOLD}[✓] Arch Linux detected. Installing base-devel...${NC}"
    sudo pacman -Sy --noconfirm base-devel gcc > /dev/null 2>&1

  else
    echo -e "${RED}${BOLD}[✗] Linux detected but unsupported package manager.${NC}"
    exit 1
  fi

elif [[ "$OSTYPE" == "darwin"* ]]; then
  echo -e "${CYAN}${BOLD}[✓] macOS detected. Installing Xcode Command Line Tools...${NC}"
  xcode-select --install > /dev/null 2>&1

else
  echo -e "${RED}${BOLD}[✗] Unsupported OS: $OSTYPE${NC}"
  exit 1
fi

if command -v gcc &>/dev/null; then
  export CC=$(command -v gcc)
  echo -e "${CYAN}${BOLD}[✓] Exported CC=$CC${NC}"
else
  echo -e "${RED}${BOLD}[✗] gcc not found. Please install it manually.${NC}"
fi

[ -f cuda.sh ] && rm cuda.sh; curl -o cuda.sh https://raw.githubusercontent.com/zunxbt/gensyn-testnet/main/cuda.sh && chmod +x cuda.sh && . ./cuda.sh

# ================ 新增认证流程（来自swarm-org.sh）================
cleanup() {
    echo -e "${YELLOW}${BOLD}[✓] Shutting down processes...${NC}"
    kill $SERVER_PID 2>/dev/null || true
    exit 0
}

trap cleanup INT

while true; do
    echo -en "${CYAN}${BOLD}"
    read -p ">> Would you like to connect to the Testnet? [Y/n] " yn
    echo -en "${NC}"
    yn=${yn:-Y}
    case $yn in
        [Yy]*)  CONNECT_TO_TESTNET=true; break ;;
        [Nn]*)  CONNECT_TO_TESTNET=false; break ;;
        *)      echo ">>> Please answer yes or no." ;;
    esac
done

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # ================ Node.js环境设置 ================
    if ! command -v node >/dev/null; then
        echo -e "${YELLOW}${BOLD}[!] Installing Node.js...${NC}"
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] || curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        . "$NVM_DIR/nvm.sh"
        nvm install node
    fi

    # ================ Yarn安装 ================
    if ! command -v yarn >/dev/null; then
        echo -e "${YELLOW}${BOLD}[!] Installing Yarn...${NC}"
        npm install -g yarn
    fi

    # ================ 启动认证服务器 ================
    echo -e "${CYAN}${BOLD}[✓] Starting authentication server...${NC}"
    cd modal-login

    # 清理现有进程
    if ss -ltnp | grep -q ":3000 "; then
        PID=$(ss -ltnp | grep ":3000 " | grep -oP 'pid=\K[0-9]+')
        echo -e "${YELLOW}[!] Killing existing process on port 3000: $PID${NC}"
        kill -9 $PID
    fi

    yarn install --silent
    yarn dev > server.log 2>&1 &
    SERVER_PID=$!

    # 等待服务器启动
    echo -e "${CYAN}${BOLD}[↻] Waiting for server to start...${NC}"
    for i in {1..30}; do
        if grep -q "Local:        http://localhost:" server.log; then
            PORT=$(grep "Local:        http://localhost:" server.log | sed -n 's/.*http:\/\/localhost:\([0-9]*\).*/\1/p')
            if [ -n "$PORT" ]; then
                echo -e "${GREEN}${BOLD}[✓] Server running on port $PORT${NC}"
                break
            fi
        fi
        sleep 1
    done

    # 打开浏览器
    echo -e "${CYAN}${BOLD}[✓] Opening browser...${NC}"
    if command -v xdg-open >/dev/null; then
        xdg-open "http://localhost:$PORT"
    elif command -v open >/dev/null; then
        open "http://localhost:$PORT"
    else
        echo -e "${RED}${BOLD}[✗] Could not open browser. Please manually visit: http://localhost:$PORT${NC}"
    fi

    cd ..

    # ================ 等待用户认证 ================
    echo -e "${CYAN}${BOLD}[↻] Waiting for authentication...${NC}"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5
    done

    # 提取ORG_ID
    ORG_ID=$(awk -F\" '!/^[ \t]*[{}]/ {print $(NF-1); exit}' modal-login/temp-data/userData.json)
    echo -e "${GREEN}${BOLD}[✓] ORG_ID set to: $ORG_ID${NC}"

    # ================ 等待API密钥激活 ================
    echo -e "${CYAN}${BOLD}[↻] Verifying API key...${NC}"
    while true; do
        STATUS=$(curl -s "http://localhost:$PORT/api/get-api-key-status?orgId=$ORG_ID")
        if [ "$STATUS" = "activated" ]; then
            echo -e "${GREEN}${BOLD}[✓] API key activated!${NC}"
            break
        fi
        sleep 5
    done

    # 更新合约地址
    ENV_FILE="$ROOT/modal-login/.env"
    if [ "$USE_BIG_SWARM" = true ]; then
        SWARM_CONTRACT="$BIG_SWARM_CONTRACT"
    else
        SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
    fi
    sed -i'' -e "s/SMART_CONTRACT_ADDRESS=.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
fi

# ================ 原有参数选择流程 ================
while true; do
    echo -e "\n${CYAN}${BOLD}Please select a swarm to join:${NC}"
    echo -e "[A] Math\n[B] Math Hard"
    read -p "> " ab
    ab=${ab:-A}

    case $ab in
        [Aa]*)  USE_BIG_SWARM=false; break ;;
        [Bb]*)  USE_BIG_SWARM=true; break ;;
        *)      echo ">>> Please answer A or B." ;;
    esac
done

if [ "$USE_BIG_SWARM" = true ]; then
    SWARM_CONTRACT="$BIG_SWARM_CONTRACT"
else
    SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
fi

while true; do
    echo -e "\n${CYAN}${BOLD}How many parameters (in billions)? [0.5, 1.5, 7, 32, 72]${NC}"
    read -p "> " pc
    pc=${pc:-0.5}

    case $pc in
        0.5 | 1.5 | 7 | 32 | 72) PARAM_B=$pc; break ;;
        *) echo ">>> Please answer in [0.5, 1.5, 7, 32, 72]." ;;
    esac
done

# ================ 环境设置与训练启动 ================
echo -e "${CYAN}${BOLD}[✓] Setting up Python virtual environment...${NC}"
python3 -m venv .venv && source .venv/bin/activate || {
    echo -e "${RED}${BOLD}[✗] Failed to create virtual environment${NC}"
    exit 1
}

# GPU检测与依赖安装
if [ -z "$CPU_ONLY" ] && (command -v nvidia-smi &>/dev/null || [ -d "/proc/driver/nvidia" ]); then
    echo -e "${GREEN}${BOLD}[✓] GPU detected${NC}"
    pip install -r requirements-gpu.txt
    pip install flash-attn --no-build-isolation

    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        *)       CONFIG_PATH="hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
    esac
    GAME=$([ "$USE_BIG_SWARM" = true ] && echo "dapo" || echo "gsm8k")
else
    echo -e "${YELLOW}${BOLD}[✓] Using CPU configuration${NC}"
    pip install -r requirements-cpu.txt
    CONFIG_PATH="hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
fi

# Hugging Face Token处理
if [ -z "${HF_TOKEN}" ]; then
    echo -e "\n${CYAN}Push models to Hugging Face Hub? [y/N]${NC}"
    read -p "> " yn
    case "$yn" in
        [Yy]*) read -p "Enter HF token: " HUGGINGFACE_ACCESS_TOKEN ;;
        *)     HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
else
    HUGGINGFACE_ACCESS_TOKEN="${HF_TOKEN}"
fi

# 启动训练
echo -e "\n${GREEN}${BOLD}=== Training Configuration ===${NC}"
echo -e "Model Size: ${PARAM_B}B\nSwarm Type: ${GAME}\nContract: ${SWARM_CONTRACT:0:6}...${SWARM_CONTRACT: -4}"

if [ -n "$ORG_ID" ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$SWARM_CONTRACT" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
fi

wait
