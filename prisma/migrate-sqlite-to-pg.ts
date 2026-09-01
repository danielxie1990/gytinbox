// ────────────────────────────────────────────────────────────
//  SQLite (Hostinger/本地) → PostgreSQL (VPS) 数据迁移 — 第一步：导出
//
//  用法（在项目根目录，本地运行）：
//     npx tsx prisma/migrate-sqlite-to-pg.ts
//     然后按提示运行第二步： node prisma/migrate-import.cjs
//
//  为什么分两步：
//    Windows 上 Prisma client 加载后 DLL 被进程锁定，
//    同一进程内无法再执行 prisma generate 切换 provider。
//    第一步只读 SQLite 并导出 JSON；第二步是独立 node 进程，
//    不加载 SQLite client，可以正常 generate + 导入。
//
//  前置条件：
//    - 本地 SQLite 库存在: prisma/dev.db
//    - 环境变量 PG_DATABASE_URL 指向目标 Postgres 库：
//        $env:PG_DATABASE_URL="postgresql://app:pass@SERVER_IP:5432/product_site"
// ────────────────────────────────────────────────────────────
import { PrismaClient } from "@prisma/client";
import path from "path";
import fs from "fs";

const DEFAULT_PG_URL =
  process.env.PG_DATABASE_URL ||
  "postgresql://app:change-me-in-production@localhost:5432/product_site";

const sqlite = new PrismaClient({ datasources: { db: { url: "file:./dev.db" } } });

async function main() {
  console.log("SQLite -> PostgreSQL 迁移 — 第一步：导出");
  console.log("目标库:", DEFAULT_PG_URL.replace(/:[^:@]+@/, ":***@"));

  // ─── 1. 从 SQLite 读全部数据 ─────────────────────────
  console.log("\n[1/2] 从 SQLite 读取数据...");
  const data = {
    users: await sqlite.user.findMany(),
    pages: await sqlite.page.findMany(),
    categories: await sqlite.category.findMany(),
    productTypes: await sqlite.productType.findMany(),
    products: await sqlite.product.findMany(),
    tabTemplates: await sqlite.tabTemplate.findMany(),
    productTabs: await sqlite.productTab.findMany(),
    productSpecs: await sqlite.productSpec.findMany(),
    productCategories: await sqlite.productCategory.findMany(),
    productImages: await sqlite.productImage.findMany(),
    posts: await sqlite.post.findMany(),
    media: await sqlite.media.findMany(),
    siteSettings: await sqlite.siteSetting.findMany(),
    passwordResetTokens: await sqlite.passwordResetToken.findMany(),
  };
  const total = Object.values(data).reduce((n, arr) => n + arr.length, 0);
  console.log(`  读取完成：${total} 条记录`);
  if (total === 0) {
    console.log("  SQLite 库为空，无需迁移");
    return;
  }

  // ─── 2. 导出临时 JSON ─────────────────────────────────
  console.log("[2/2] 导出 JSON 并生成导入脚本...");
  const tmpFile = path.join(process.cwd(), "prisma", "migrate-export.json");
  fs.writeFileSync(tmpFile, JSON.stringify(data));
  console.log(`  已导出: ${tmpFile}`);

  // 生成第二步导入脚本（独立 node 进程，可安全切换 provider）
  const importScript = `// 第二步：导入 PostgreSQL（自动生成，可安全删除）
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const PG_URL = ${JSON.stringify(DEFAULT_PG_URL)};
const schemaPath = path.join(process.cwd(), "prisma", "schema.prisma");

async function run() {
  // 1. 切换 provider 到 postgresql 并 generate
  console.log("[1/4] 切换 provider 到 PostgreSQL...");
  const original = fs.readFileSync(schemaPath, "utf8");
  const schema = original.replace('provider = "sqlite"', 'provider = "postgresql"');
  fs.writeFileSync(schemaPath, schema);
  try {
    execSync("npx prisma generate", {
      stdio: "inherit",
      env: { ...process.env, DATABASE_URL: PG_URL },
    });
  } catch (e) {
    fs.writeFileSync(schemaPath, original); // 失败恢复
    throw e;
  }

  // 2. 导入数据
  console.log("[2/4] 写入 PostgreSQL...");
  const { PrismaClient } = require("@prisma/client");
  const pg = new PrismaClient({ datasources: { db: { url: PG_URL } } });
  try {
    const data = JSON.parse(fs.readFileSync(path.join(process.cwd(), "prisma", "migrate-export.json"), "utf8"));
    const byModel = {
      user: pg.user, page: pg.page, category: pg.category,
      productType: pg.productType, tabTemplate: pg.tabTemplate,
      post: pg.post, siteSetting: pg.siteSetting, media: pg.media,
      product: pg.product, passwordResetToken: pg.passwordResetToken,
      productTab: pg.productTab, productSpec: pg.productSpec,
      productCategory: pg.productCategory, productImage: pg.productImage,
    };
    // 插入顺序：先主表（无外键依赖），再子表
    const modelOrder = [
      "user", "page", "category", "productType", "tabTemplate",
      "post", "siteSetting", "media", "product",
      "productTab", "productSpec", "productCategory", "productImage",
      "passwordResetToken",
    ];
    const tables = {
      user: "User", page: "Page", category: "Category",
      productType: "ProductType", tabTemplate: "TabTemplate",
      post: "Post", siteSetting: "SiteSetting", media: "Media",
      product: "Product", passwordResetToken: "PasswordResetToken",
      productTab: "ProductTab", productSpec: "ProductSpec",
      productCategory: "ProductCategory", productImage: "ProductImage",
    };
    for (const model of modelOrder) {
      const rows = data[model + "s"] || [];
      if (rows.length === 0) continue;
      await byModel[model].createMany({ data: rows });
      console.log("  ok " + model + ": " + rows.length + " rows");
    }

    // 3. 修复 serial 序列（显式插入 id 后序列不会自动推进）
    console.log("[3/4] 修复 serial 序列...");
    for (const [model, table] of Object.entries(tables)) {
      await pg.$executeRawUnsafe(
        "SELECT setval(pg_get_serial_sequence('\\"" + table + "\\"', 'id'), " +
        "COALESCE((SELECT MAX(id) FROM \\"" + table + "\\"), 1))"
      );
    }
  } finally {
    await pg.$disconnect();
    // 4. 恢复 SQLite provider，保证本地开发不受影响
    console.log("[4/4] 恢复 SQLite provider...");
    fs.writeFileSync(schemaPath, original);
  }
  console.log("\\nImport done! serial sequences fixed.");
  console.log("注意：public/uploads 下的图片文件需另行拷贝到 VPS (scp/rsync)");
}

run().catch((e) => { console.error(e); process.exit(1); });
`;
  const importFile = path.join(process.cwd(), "prisma", "migrate-import.cjs");
  fs.writeFileSync(importFile, importScript);

  console.log("\n──────────────────────────────────────────────");
  console.log(" 第一步完成！请运行第二步导入：");
  console.log("   node prisma/migrate-import.cjs");
  console.log("──────────────────────────────────────────────");
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(async () => { await sqlite.$disconnect(); });
