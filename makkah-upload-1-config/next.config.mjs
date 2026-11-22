export default {
  serverExternalPackages: ["bwip-js", "exceljs"],
  experimental: { serverActions: { bodySizeLimit: "5mb" } },   // Excel uploads (max 4 MB enforced in code)
};
