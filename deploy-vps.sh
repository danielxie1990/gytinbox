#!/bin/bash
# ────────────────────────────────────────────────────────
#  gytinbox-next — VPS 一键部署 (Docker + PostgreSQL)
#
#  用法（在本地电脑执行）：
#    ssh root@YOUR_SERVER_IP 'bash -s' < deploy-vps.sh
#
#  或直接在服务器上：
#    bash deploy-vps.sh
#
#  首次执行会自动：装 Docker → 拉代码 → 建库 → 起服务 → Nginx + HTTPS
#  后续更新只需：   git 推代码后重跑本脚本（自动 pull + 重建）
# ────────────────────────────────────────────────────────
set -e

# ═══ 配置区（按需修改） ═══════════════════════════════
APP_DIR="/opt/gytinbox"
REPO_URL="https://github.com/danielxie1990/gytinbox.git"
BRANCH="main"
DOMAIN="fulimachine.com"          # ← 改成你的域名
SERVER_IP="YOUR_SERVER_IP"        # ← 改成你的 VPS IP（仅用于提示）
ADMIN_EMAIL="admin@${DOMAIN}"
POSTGRES_PASSWORD="$(openssl rand -hex 16)"   # 首次生成，之后保留
# ═══════════════════════════════════════════════════════

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()   { echo -e "\033[0;31m[ERROR]${NC} $1"; exit 1; }

# ─── 0. 系统依赖 ─────────────────────────────────────
info "安装 Docker + Nginx..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v nginx &>/dev/null; then
  apt-get update -qq && apt-get install -y -qq nginx
fi
systemctl enable --now docker nginx 2>/dev/null || true

# ─── 1. 拉取代码 ─────────────────────────────────────
if [ -d "$APP_DIR/.git" ]; then
  info "更新代码 ($BRANCH)..."
  cd "$APP_DIR"
  git fetch origin
  git checkout "$BRANCH"
  git pull origin "$BRANCH"
else
  info "克隆项目..."
  git clone -b "$BRANCH" "$REPO_URL" "$APP_DIR"
  cd "$APP_DIR"
fi

# ─── 2. 环境变量 ─────────────────────────────────────
info "准备 .env..."
if [ ! -f .env ]; then
  cat > .env << EOF
# VPS production environment
JWT_SECRET="$(openssl rand -hex 32)"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
# SMTP (optional)
# SMTP_HOST="smtp.example.com"
# SMTP_PORT=465
# SMTP_USER="you@example.com"
# SMTP_PASS="your-password"
EOF
  warn "已生成 .env（含随机 JWT_SECRET / POSTGRES_PASSWORD）"
else
  info ".env 已存在，保留现有配置"
fi

# ─── 3. 构建 + 启动 ──────────────────────────────────
info "构建并启动 Docker 服务..."
docker compose up -d --build

# ─── 4. 健康检查 ─────────────────────────────────────
info "等待服务就绪..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null http://localhost:3000; then
    info "✅ 应用已启动 (http://localhost:3000)"
    break
  fi
  [ "$i" -eq 30 ] && warn "应用启动较慢，请检查: docker compose logs app"
  sleep 2
done

# ─── 5. Nginx 反代 + HTTPS ───────────────────────────
info "配置 Nginx..."
cat > /etc/nginx/sites-available/gytinbox << EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
ln -sf /etc/nginx/sites-available/gytinbox /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ─── 6. SSL（首次自动签，之后自动续期） ───────────────
info "配置 HTTPS (Let's Encrypt)..."
apt-get install -y -qq certbot python3-certbot-nginx 2>/dev/null || true
if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" --redirect 2>&1; then
  info "✅ HTTPS 已启用"
else
  warn "SSL 签发失败（可稍后手动运行 certbot --nginx）"
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  部署完成！"
echo ""
echo "  网站:   https://${DOMAIN}"
echo "  管理后台: https://${DOMAIN}/admin/login"
echo "  管理员:  admin@example.com / admin123（首次登录后请修改）"
echo ""
echo "  常用命令:"
echo "    docker compose logs -f app    # 查看日志"
echo "    docker compose restart app    # 重启应用"
echo "    docker exec -it gytinbox-app-1 sh  # 进入容器"
echo "══════════════════════════════════════════════"
