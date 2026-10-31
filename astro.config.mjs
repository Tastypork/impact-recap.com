// @ts-check
import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";

const site = "https://impact-recap.com";

/** Writes dist/sitemap.xml from the pages Astro just built. */
function sitemap() {
  return {
    name: "sitemap",
    hooks: {
      "astro:build:done": async ({ pages, dir }) => {
        const locs = [...new Set(pages.map((page) => page.pathname))]
          .filter((pathname) => !pathname.includes("404"))
          .map((pathname) => {
            let path = pathname.startsWith("/") ? pathname : `/${pathname}`;
            path = path.replace(/index\.html$/, "");
            if (path !== "/" && !path.endsWith("/")) path = `${path}/`;
            return `${site}${path}`;
          })
          .sort();
        const body = [
          `<?xml version="1.0" encoding="UTF-8"?>`,
          `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
          ...locs.map((loc) => `  <url><loc>${loc.replaceAll("&", "&amp;")}</loc></url>`),
          `</urlset>`,
          ``,
        ].join("\n");
        await writeFile(fileURLToPath(new URL("sitemap.xml", dir)), body);
      },
    },
  };
}

export default defineConfig({
  site,
  output: "static",
  trailingSlash: "ignore",
  build: {
    format: "directory",
  },
  integrations: [sitemap()],
});
