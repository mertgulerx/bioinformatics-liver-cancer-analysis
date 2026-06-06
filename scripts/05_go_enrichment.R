# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 05: GO Zenginleştirme Analizi
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# ==============================================================================

library(clusterProfiler)
library(org.Hs.eg.db)
library(enrichplot)
library(ggplot2)

BASE_DIR <- getwd()
DATA_DIR <- file.path(BASE_DIR, "data")
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
for (d in c(DATA_DIR, FIG_DIR, TAB_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# ==============================================================================
# 1. Veri Yükleme
# ==============================================================================

message(">>> Loading WGCNA results...")
wgcna_res <- readRDS(file.path(DATA_DIR, "wgcna_results.rds"))
df <- readRDS(file.path(DATA_DIR, "expr_matrix.rds"))

moduleColors <- wgcna_res$moduleColors
best_module <- wgcna_res$best_module

# Modül genlerini al
mod_gene_names <- colnames(df)[moduleColors == best_module]
message(paste("Selected module:", best_module))
message(paste("Number of genes:", length(mod_gene_names)))

# ==============================================================================
# 2. GO Zenginleştirme - Biyolojik Süreç (BP)
# ==============================================================================

message(">>> Running GO enrichment (Biological Process)...")

ego_bp <- enrichGO(
  gene = mod_gene_names,
  OrgDb = org.Hs.eg.db,
  keyType = "SYMBOL",
  ont = "BP",
  pAdjustMethod = "BH",
  pvalueCutoff = 0.05
)

message(paste("Significant BP terms:", nrow(as.data.frame(ego_bp))))

if (nrow(as.data.frame(ego_bp)) > 0) {
  # Bar grafiği (en anlamlı terimler)
  png(file.path(FIG_DIR, "go_barplot.png"), width = 12, height = 6, units = "in", res = 300)
  print(barplot(ego_bp, showCategory = 15) +
          ggtitle(paste("GO Biological Process -", best_module, "module")))
  dev.off()

  # Nokta (dot) grafiği: GeneRatio ve gen sayısı
  png(file.path(FIG_DIR, "go_dotplot.png"), width = 12, height = 6, units = "in", res = 300)
  print(dotplot(ego_bp, showCategory = 15) +
          ggtitle(paste("GO Biological Process -", best_module, "module")))
  dev.off()

  # Sonuçları CSV olarak kaydet
  write.csv(as.data.frame(ego_bp), file.path(TAB_DIR, "go_bp_results.csv"), row.names = FALSE)

  message("\nTop 10 GO BP terms:")
  print(head(as.data.frame(ego_bp)[, c("ID", "Description", "pvalue", "p.adjust", "Count")], 10))
} else {
  # FDR<0.05'te anlamlı terim yoksa keşifsel amaçlı FDR<0.1 eşiği denenir
  message("FDR<0.05'te anlamlı GO BP terimi yok; keşifsel FDR<0.1 eşiği deneniyor.")
  ego_bp <- enrichGO(
    gene = mod_gene_names,
    OrgDb = org.Hs.eg.db,
    keyType = "SYMBOL",
    ont = "BP",
    pAdjustMethod = "BH",
    pvalueCutoff = 0.1
  )

  if (nrow(as.data.frame(ego_bp)) > 0) {
    expl_title <- paste0("GO Biological Process - ", best_module,
                         " module (KEŞİFSEL, FDR<0.1)")
    png(file.path(FIG_DIR, "go_barplot.png"), width = 12, height = 6, units = "in", res = 300)
    print(barplot(ego_bp, showCategory = 15) + ggtitle(expl_title))
    dev.off()

    png(file.path(FIG_DIR, "go_dotplot.png"), width = 12, height = 6, units = "in", res = 300)
    print(dotplot(ego_bp, showCategory = 15) + ggtitle(expl_title))
    dev.off()

    # Keşifsel sonuç ayrı dosya olarak da kaydedilir
    write.csv(as.data.frame(ego_bp), file.path(TAB_DIR, "go_bp_results_exploratory_FDR0.1.csv"), row.names = FALSE)
    write.csv(as.data.frame(ego_bp), file.path(TAB_DIR, "go_bp_results.csv"), row.names = FALSE)
  }
}

# ==============================================================================
# 3. GO Zenginleştirme - Moleküler Fonksiyon (MF, ek)
# ==============================================================================

message(">>> Running GO enrichment (Molecular Function)...")

ego_mf <- enrichGO(
  gene = mod_gene_names,
  OrgDb = org.Hs.eg.db,
  keyType = "SYMBOL",
  ont = "MF",
  pAdjustMethod = "BH",
  pvalueCutoff = 0.05
)

if (nrow(as.data.frame(ego_mf)) > 0) {
  write.csv(as.data.frame(ego_mf), file.path(TAB_DIR, "go_mf_results.csv"), row.names = FALSE)
  message(paste("Significant MF terms:", nrow(as.data.frame(ego_mf))))
}

# ==============================================================================
# 4. GO Zenginleştirme - Hücresel Bileşen (CC, ek)
# ==============================================================================

message(">>> Running GO enrichment (Cellular Component)...")

ego_cc <- enrichGO(
  gene = mod_gene_names,
  OrgDb = org.Hs.eg.db,
  keyType = "SYMBOL",
  ont = "CC",
  pAdjustMethod = "BH",
  pvalueCutoff = 0.05
)

if (nrow(as.data.frame(ego_cc)) > 0) {
  write.csv(as.data.frame(ego_cc), file.path(TAB_DIR, "go_cc_results.csv"), row.names = FALSE)
  message(paste("Significant CC terms:", nrow(as.data.frame(ego_cc))))
}

message("========================================")
message(">>> Script 05 COMPLETED!")
message(paste("Module analyzed:", best_module))
message(paste("BP terms:", nrow(as.data.frame(ego_bp))))
message("========================================")
