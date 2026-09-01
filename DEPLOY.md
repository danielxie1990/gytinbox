# Deployment Guide

gytinbox-next (ProductSite CMS) 支持**两套部署方案**，同一份代码，按客户/预算选择：

| 方案 | 适用 | 数据库 | 部署方式 |
|------|------|--------|----------|
| **A. Hostinger 共享主机** | 低成本客户站 | SQLite | FTP 上传 + hPanel 构建 |
| **B. 独立 VPS (Docker)** | 正式生产 | PostgreSQL | `docker compose up -d` |

---

## 方案 A：Hostinger（共享主机）

### 一键脚本

```powershell
# 1. 复制并填写 FTP 凭据
copy ftp-credentials.example.json ftp-credentials.json

# 2. 一键部署（build → 打包 → FTP 上传 → 服务器解压）
powershell -ExecutionPolicy Bypass -File deploy-hostinger.ps1
```

脚本自动完成：本地 build 验证 → 打包源码（排除 node_modules/.next）→
FTP 上传 zip + extract.php → HTTP 触发解压 → 清理 extract.php。

**最后一步必须手动**：Hostinger hPanel → Node.js → **Restart**
（服务器自动执行 npm install + build，等 1-3 分钟）。

### 关键规则（踩坑记录）

1. **SQLite 必须本地建库并随包上传**（无 SSH，服务器建不了库）
   - `npx prisma db push` + `npx tsx prisma/seed.ts` 在本地跑
   - `git add -f prisma/dev.db`（覆盖 .gitignore）
2. `DATABASE_URL="file:./dev.db"`（相对 schema.prisma 解析）
3. tiptap 版本必须统一（3.26.1），package.json 无尾逗号
4. 更新后必须手动点 Restart；页面旧/503 就再点一次
5. SMTP 用 SSL + 465 端口

---

## 方案 B：独立 VPS（Docker + PostgreSQL）

### 服务器端一键部署

```bash
# 本地电脑执行（首次会自动装 Docker → 拉代码 → 起服务 → HTTPS）
ssh root@YOUR_SERVER_IP 'bash -s' < deploy-vps.sh
```

或直接在服务器上 `bash deploy-vps.sh`。

脚本自动完成：
1. 安装 Docker + Nginx + certbot
2. git clone/pull 代码（`github.com/danielxie1990/gytinbox`）
3. 生成 `.env`（随机 JWT_SECRET + POSTGRES_PASSWORD）
4. `docker compose up -d --build`
5. Nginx 反代 `:3000` + Let's Encrypt HTTPS

### 架构

```
Nginx (:80/443) → app (Next.js :3000)
                    ├── postgres (Postgres 16, 数据卷 pgdata)
                    └── uploads (图片持久化卷)
```

- Dockerfile 构建时自动把 Prisma provider 切成 postgresql（本地代码保持 sqlite）
- 容器启动自动 `prisma db push` + seed（幂等）
- 上传图片存 `uploads` 卷，重建容器不丢

### 常用命令

```bash
docker compose logs -f app      # 日志
docker compose restart app      # 重启
docker exec -it gytinbox-app-1 sh
```

---

## 数据迁移：Hostinger (SQLite) → VPS (PostgreSQL)

首次从方案 A 迁到方案 B 时使用（两步式，Windows 下 DLL 锁问题已规避）：

```powershell
# 第一步：读取 SQLite 导出 JSON（自动生成导入脚本）
$env:PG_DATABASE_URL="postgresql://app:PASSWORD@SERVER_IP:5432/product_site"
npx tsx prisma/migrate-sqlite-to-pg.ts

# 第二步：切换 provider → 导入 Postgres → 修复序列 → 恢复 sqlite
node prisma/migrate-import.cjs
```

导入完成后再拷贝图片：

```bash
rsync -avz public/uploads/ root@SERVER:/opt/gytinbox/public/uploads/
# 或 scp -r public/uploads/* root@SERVER:/opt/gytinbox/public/uploads/
```
