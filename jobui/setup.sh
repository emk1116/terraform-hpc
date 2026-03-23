#!/usr/bin/env bash
# =============================================================================
# Titan HPC Platform — Setup Script
# Supports: Amazon Linux 2, Amazon Linux 2023, Ubuntu 22.04+
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/backend/.env.example"

echo ""
echo -e "${BOLD}=================================================${RESET}"
echo -e "${BOLD}   Titan HPC Platform — Setup${RESET}"
echo -e "${BOLD}=================================================${RESET}"
echo ""

# =============================================================================
# Detect OS
# =============================================================================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi
    info "Detected OS: ${OS_ID} ${OS_VERSION}"
}

# =============================================================================
# Check prerequisites
# =============================================================================
check_command() {
    local cmd="$1"
    local min_version="$2"
    if command -v "$cmd" &>/dev/null; then
        success "$cmd is available"
        return 0
    else
        warn "$cmd not found"
        return 1
    fi
}

check_python() {
    if command -v python3 &>/dev/null; then
        local version
        version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        local major minor
        major=$(echo "$version" | cut -d. -f1)
        minor=$(echo "$version" | cut -d. -f2)
        if [ "$major" -ge 3 ] && [ "$minor" -ge 11 ]; then
            success "Python $version is available (>= 3.11 required)"
            return 0
        else
            warn "Python $version found but >= 3.11 required"
            return 1
        fi
    else
        warn "python3 not found"
        return 1
    fi
}

check_node() {
    if command -v node &>/dev/null; then
        local version
        version=$(node --version | sed 's/v//')
        local major
        major=$(echo "$version" | cut -d. -f1)
        if [ "$major" -ge 20 ]; then
            success "Node.js v$version is available (>= 20 required)"
            return 0
        else
            warn "Node.js v$version found but >= 20 required"
            return 1
        fi
    else
        warn "node not found"
        return 1
    fi
}

check_docker() {
    if command -v docker &>/dev/null; then
        success "Docker is available: $(docker --version)"
        return 0
    else
        warn "Docker not found"
        return 1
    fi
}

check_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        success "Docker Compose (v2 plugin) available"
        return 0
    elif command -v docker-compose &>/dev/null; then
        success "docker-compose available: $(docker-compose --version)"
        return 0
    else
        warn "Docker Compose not found"
        return 1
    fi
}

# =============================================================================
# Install missing dependencies (Amazon Linux 2 / AL2023 / Ubuntu)
# =============================================================================
install_deps_amazon_linux() {
    info "Installing dependencies on Amazon Linux..."

    # Docker
    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        sudo yum install -y docker || sudo dnf install -y docker
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$(whoami)"
        success "Docker installed"
    fi

    # Docker Compose plugin
    if ! docker compose version &>/dev/null 2>&1; then
        info "Installing Docker Compose plugin..."
        COMPOSE_VERSION="v2.29.1"
        sudo mkdir -p /usr/local/lib/docker/cli-plugins
        sudo curl -SL \
            "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        success "Docker Compose installed"
    fi
}

install_deps_ubuntu() {
    info "Installing dependencies on Ubuntu..."
    sudo apt-get update -qq

    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        sudo apt-get install -y ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$(whoami)"
        success "Docker installed"
    fi
}

# =============================================================================
# Configure .env file
# =============================================================================
configure_env() {
    if [ -f "$ENV_FILE" ]; then
        warn ".env file already exists at $ENV_FILE"
        read -rp "Overwrite it? [y/N] " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            info "Keeping existing .env file"
            return
        fi
    fi

    info "Creating .env from template..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"

    # S3 Bucket
    echo ""
    read -rp "Enter your S3 bucket name (e.g. titan-non-prod-hpc-data-abc12345): " s3_bucket
    if [ -n "$s3_bucket" ]; then
        sed -i "s|S3_BUCKET=.*|S3_BUCKET=${s3_bucket}|" "$ENV_FILE"
        success "S3_BUCKET set to: $s3_bucket"
    else
        warn "S3_BUCKET not set — S3 features will be disabled"
    fi

    # JWT Secret
    echo ""
    if command -v openssl &>/dev/null; then
        generated_secret=$(openssl rand -hex 32)
        sed -i "s|JWT_SECRET=.*|JWT_SECRET=${generated_secret}|" "$ENV_FILE"
        success "JWT_SECRET auto-generated with openssl rand -hex 32"
    else
        read -rp "Enter JWT secret (leave blank to use default — NOT for production): " jwt_secret
        if [ -n "$jwt_secret" ]; then
            sed -i "s|JWT_SECRET=.*|JWT_SECRET=${jwt_secret}|" "$ENV_FILE"
        fi
    fi

    # AWS Region
    echo ""
    read -rp "AWS Region [us-east-1]: " aws_region
    aws_region="${aws_region:-us-east-1}"
    sed -i "s|AWS_REGION=.*|AWS_REGION=${aws_region}|" "$ENV_FILE"

    success ".env file configured at $ENV_FILE"
}

# =============================================================================
# Configure sudoers for Slurm
# =============================================================================
configure_sudoers() {
    info "Configuring sudoers for Slurm job submission..."

    local sudoers_file="/etc/sudoers.d/hpc-slurm"
    local current_user
    current_user=$(whoami)

    # Extract cluster users from DEFAULT_USERS env
    local cluster_users="user1,user2"
    if [ -f "$ENV_FILE" ]; then
        local default_users
        default_users=$(grep "^DEFAULT_USERS=" "$ENV_FILE" | cut -d= -f2-)
        if [ -n "$default_users" ]; then
            # Extract unique cluster_user values (3rd field in each entry)
            cluster_users=$(echo "$default_users" | tr ',' '\n' | cut -d: -f3 | sort -u | tr '\n' ',' | sed 's/,$//')
        fi
    fi

    local sudoers_entry="${current_user} ALL=(${cluster_users}) NOPASSWD: /usr/bin/sbatch, /usr/bin/scancel"

    if [ -f "$sudoers_file" ]; then
        warn "Sudoers file already exists: $sudoers_file"
    else
        echo "$sudoers_entry" | sudo tee "$sudoers_file" > /dev/null
        sudo chmod 440 "$sudoers_file"

        # Validate syntax
        if sudo visudo -c -f "$sudoers_file" 2>/dev/null; then
            success "Sudoers configured: $sudoers_entry"
        else
            sudo rm -f "$sudoers_file"
            die "Sudoers syntax invalid — file removed. Please configure manually."
        fi
    fi
}

# =============================================================================
# Create data directory
# =============================================================================
create_data_dir() {
    info "Creating /data directory for SQLite database..."
    if [ ! -d /data ]; then
        sudo mkdir -p /data
        sudo chown "$(whoami):$(id -gn)" /data
        success "Created /data directory"
    else
        success "/data already exists"
    fi
}

# =============================================================================
# Build and start Docker Compose
# =============================================================================
build_and_start() {
    info "Building Docker images..."
    cd "$SCRIPT_DIR"

    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        COMPOSE_CMD="docker-compose"
    fi

    # Load .env
    set -a
    # shellcheck disable=SC1090
    [ -f "$ENV_FILE" ] && source "$ENV_FILE"
    set +a

    $COMPOSE_CMD build --no-cache
    success "Docker images built"

    info "Starting services..."
    $COMPOSE_CMD up -d
    success "Services started"

    # Wait for backend health
    info "Waiting for backend to be healthy..."
    for i in $(seq 1 30); do
        if curl -sf http://localhost:8000/health &>/dev/null; then
            success "Backend is healthy"
            break
        fi
        if [ "$i" -eq 30 ]; then
            warn "Backend did not become healthy within 30 seconds"
            warn "Check logs with: docker compose logs backend"
        fi
        sleep 2
    done
}

# =============================================================================
# Print summary
# =============================================================================
print_summary() {
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    echo ""
    echo -e "${BOLD}=================================================${RESET}"
    echo -e "${BOLD}   Titan HPC Platform — Setup Complete!${RESET}"
    echo -e "${BOLD}=================================================${RESET}"
    echo ""
    echo -e "  ${GREEN}Access URL:${RESET} http://${host_ip}"
    echo -e "  ${GREEN}API Docs:${RESET}   http://${host_ip}/api/docs"
    echo ""
    echo -e "  ${YELLOW}Default Credentials (CHANGE IN PRODUCTION):${RESET}"
    echo -e "    admin   / admin123  (admin)"
    echo -e "    user1   / user1pass"
    echo -e "    user2   / user2pass"
    echo ""
    echo -e "  ${BLUE}Useful commands:${RESET}"
    echo -e "    docker compose logs -f backend    # backend logs"
    echo -e "    docker compose logs -f frontend   # frontend logs"
    echo -e "    docker compose restart backend    # restart backend"
    echo -e "    docker compose down               # stop all services"
    echo ""
    echo -e "  ${RED}IMPORTANT:${RESET}"
    echo -e "    1. Change default passwords immediately"
    echo -e "    2. Ensure AWS credentials are available (IAM role recommended)"
    echo -e "    3. Verify Slurm is accessible on this node"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    detect_os

    echo ""
    info "Checking prerequisites..."

    local need_docker=false
    check_docker || need_docker=true
    check_docker_compose || need_docker=true

    if [ "$need_docker" = true ]; then
        echo ""
        read -rp "Some prerequisites are missing. Install them now? [Y/n] " install_now
        if [[ ! "$install_now" =~ ^[Nn]$ ]]; then
            case "$OS_ID" in
                amzn|"amazon linux")
                    install_deps_amazon_linux ;;
                ubuntu)
                    install_deps_ubuntu ;;
                *)
                    warn "Auto-install not supported for $OS_ID. Please install Docker manually."
                    ;;
            esac
        fi
    fi

    echo ""
    info "Configuring environment..."
    configure_env

    echo ""
    info "Configuring Slurm sudoers..."
    if command -v sbatch &>/dev/null; then
        configure_sudoers
    else
        warn "sbatch not found — skipping sudoers configuration. Configure manually when Slurm is installed."
    fi

    echo ""
    info "Setting up data directory..."
    create_data_dir

    echo ""
    info "Building and starting services..."
    build_and_start

    print_summary
}

main "$@"
