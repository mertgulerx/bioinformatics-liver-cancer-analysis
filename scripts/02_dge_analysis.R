# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 02: Diferansiyel Gen İfadesi (DGE) Analizi
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# ==============================================================================

library(limma)
library(Biobase)
library(ggplot2)
library(ggrepel)
library(ggpubr)
library(reshape2)
library(pheatmap)
library(dplyr)

BASE_DIR <- getwd()
DATA_DIR <- file.path(BASE_DIR, "data")
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
for (d in c(DATA_DIR, FIG_DIR, TAB_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# ==============================================================================
# 1. Veri Yükleme
# ==============================================================================

message(">>> Loading processed data...")
# DGE tüm ifade edilen genler üzerinde yapılır; HVG yalnızca PCA/WGCNA/ML için.
expr_all <- readRDS(file.path(DATA_DIR, "expr_all_genes.rds"))  # genes x samples
df <- as.data.frame(t(expr_all))  # samples x genes
df_label <- readRDS(file.path(DATA_DIR, "sample_labels.rds"))

# Görselleştirmeler için gen x sample matrisi
expr_mat_plots <- as.matrix(expr_all)

message(paste("Expression matrix (DGE, tüm genler):", nrow(df), "samples x", ncol(df), "genes"))
message(paste("Group distribution:", paste(names(table(df_label$group)), table(df_label$group), sep = "=", collapse = ", ")))

# İfade matrisi ile metadata aynı örnek sırasında olmalı
stopifnot(all(rownames(df) == df_label$sample_id))

# ==============================================================================
# 2. ExpressionSet Oluşturma & limma Pipeline
# ==============================================================================

message(">>> Running limma DGE pipeline...")

# limma gen x örnek matris bekler; sayısala çevirip transpoze et
df_mat <- as.matrix(df)
mode(df_mat) <- "numeric"
df_mat <- t(df_mat)

# ExpressionSet: ifade matrisi ile örnek metadata'yı tek objede birleştirir
eset <- ExpressionSet(
  assayData = df_mat,
  phenoData = AnnotatedDataFrame(df_label)
)

# Tasarım matrisi (intercept yok; her grup için ayrı sütun)
design <- model.matrix(~0 + group, data = pData(eset))
colnames(design) <- gsub("group", "", colnames(design))
head(design)
colSums(design)

# Karşılaştırma kontrastı: Tümör eksi Non-Tümör
cm <- makeContrasts(
  TumorvsNonTumor = Tumor - NonTumor,
  levels = design
)

# Paired tasarım: eşleşen tümör/non-tümör örnekleri için hasta kimliği
# blok (random) etki olarak modellenir (duplicateCorrelation).
block <- df_label$patient_id
n_paired <- sum(table(block) >= 2)
message(paste("Paired hasta sayısı:", n_paired))

corfit <- duplicateCorrelation(eset, design, block = block)
message(paste("Consensus intra-patient correlation:", round(corfit$consensus.correlation, 4)))

# Fit — hasta blok korelasyonu ile
fit <- lmFit(eset, design, block = block, correlation = corfit$consensus.correlation)
fit2 <- contrasts.fit(fit, contrasts = cm)
fit2 <- eBayes(fit2)

# Anlamlılık kararı: adj.P.Val < 0.05 ve |logFC| > 1
results <- decideTests(fit2, p.value = 0.05, lfc = 1)
summary(results)

# Tüm genlerin sonuç tablosu (logFC, p, adj.P.Val, B)
tt <- topTable(fit2, number = Inf)
message(paste("Total genes tested:", nrow(tt)))

# ==============================================================================
# 3. DEG Filtreleme & Sıralama
# ==============================================================================

message(">>> Filtering significant DEGs...")

# Eşiklere göre yön etiketi: Up / Down / Not Sig
tt$threshold <- "Not Sig"
tt$threshold[tt$adj.P.Val < 0.05 & tt$logFC > 1]  <- "Up"
tt$threshold[tt$adj.P.Val < 0.05 & tt$logFC < -1] <- "Down"
tt$threshold <- factor(tt$threshold, levels = c("Down", "Not Sig", "Up"))

message("DEG summary:")
print(table(tt$threshold))

# Yalnızca anlamlı genler; mutlak logFC'ye göre sırala
sig_genes <- tt[tt$threshold != "Not Sig", ]
sig_genes <- sig_genes[order(-abs(sig_genes$logFC)), ]

# Up ve down genlerini ayrı ayrı tut
up_genes <- sig_genes[sig_genes$threshold == "Up", ]
down_genes <- sig_genes[sig_genes$threshold == "Down", ]

message(paste("Up-regulated:", nrow(up_genes)))
message(paste("Down-regulated:", nrow(down_genes)))

# Tam tablo ve anlamlı genler ayrı CSV olarak kaydedilir
write.csv(tt, file.path(TAB_DIR, "dge_full_results.csv"), row.names = TRUE)
write.csv(sig_genes, file.path(TAB_DIR, "dge_significant.csv"), row.names = TRUE)

# ==============================================================================
# 4. Volcano Plot
# ==============================================================================

message(">>> Generating Volcano Plot...")

# Volkan grafiğinde etiketlenecek genler: en güçlü 5 up + 5 down
top_label_genes <- rbind(
  head(up_genes, 5),
  head(down_genes, 5)
)

png(file.path(FIG_DIR, "volcano_plot.png"), width = 12, height = 6, units = "in", res = 300)
ggplot(tt, aes(x = logFC, y = -log10(adj.P.Val), color = threshold)) +
  geom_point(alpha = 0.6, size = 1.5) +
  scale_color_manual(
    values = c("Down" = "blue", "Not Sig" = "grey70", "Up" = "red"),
    labels = c(
      paste0("Down (", nrow(down_genes), ")"),
      paste0("Not Sig (", sum(tt$threshold == "Not Sig"), ")"),
      paste0("Up (", nrow(up_genes), ")")
    )
  ) +
  geom_vline(xintercept = c(-1, 1), linetype = "dashed", color = "grey40") +
  geom_hline(yintercept = -log10(0.05), linetype = "dashed", color = "grey40") +
  geom_text_repel(
    data = top_label_genes,
    aes(label = rownames(top_label_genes)),
    size = 3, max.overlaps = 20, color = "black"
  ) +
  theme_minimal() +
  labs(
    title = "Volcano Plot - Tumor vs Non-Tumor",
    x = "log2 Fold Change",
    y = "-log10(FDR)",
    color = "Status"
  )
dev.off()

# ==============================================================================
# 5. Top-5 Gen Kutu Grafiği (istatistiksel testli)
# ==============================================================================

message(">>> Generating Top-5 Boxplots with statistical tests...")

# Mutlak logFC'ye göre en güçlü 5 gen
dge_sorted <- sig_genes[order(-abs(sig_genes$logFC)), ]
top5_genes <- rownames(dge_sorted)[1:min(5, nrow(dge_sorted))]
message(paste("Top-5 DEGs:", paste(top5_genes, collapse = ", ")))

# ggplot için uzun (long) formata çevir
df_top <- df[, top5_genes, drop = FALSE]
df_top$sample <- rownames(df_top)
df_long <- melt(df_top, id.vars = "sample", variable.name = "gene", value.name = "expression")
df_long$group <- df_label[df_long$sample, "group"]
df_long$expression <- as.numeric(df_long$expression)
df_long$group <- factor(df_long$group, levels = c("NonTumor", "Tumor"))

# Wilcoxon testli kutu grafiği (gruplar arası fark anlamlılığı)
png(file.path(FIG_DIR, "boxplot_top5_with_stats.png"), width = 12, height = 6, units = "in", res = 300)
print(
  ggplot(df_long, aes(x = group, y = expression, fill = group)) +
    geom_boxplot(outlier.shape = NA, alpha = 0.7) +
    geom_jitter(width = 0.2, alpha = 0.5, size = 1) +
    facet_wrap(~gene, scales = "free_y", nrow = 1) +
    scale_fill_manual(values = c("NonTumor" = "#00A087", "Tumor" = "#E64B35")) +
    stat_compare_means(method = "wilcox.test", label = "p.signif", label.x = 1.5) +
    theme_minimal() +
    labs(
      title = "Top 5 DEG - Tumor vs Non-Tumor",
      x = "Group",
      y = "Expression (log2)"
    ) +
    theme(legend.position = "none")
)
dev.off()

# Her gen için ayrı kutu grafiği
for (gene in top5_genes) {
  df_plot <- data.frame(
    expression = as.numeric(df[, gene]),
    group = df_label$group
  )

  png(file.path(FIG_DIR, paste0("boxplot_", gene, ".png")), width = 12, height = 6, units = "in", res = 300)
  p <- ggplot(df_plot, aes(x = group, y = expression, fill = group)) +
    geom_boxplot(outlier.shape = NA, alpha = 0.7) +
    geom_jitter(width = 0.2, alpha = 0.5, size = 1) +
    scale_fill_manual(values = c("NonTumor" = "#00A087", "Tumor" = "#E64B35")) +
    stat_compare_means(method = "wilcox.test", label = "p.format") +
    theme_minimal() +
    labs(title = gene, x = "Group", y = "Expression (log2)")
  print(p)
  dev.off()
}

# ==============================================================================
# 6. Top-5 Violin Plot
# ==============================================================================

message(">>> Generating Top-5 Violin Plot...")

png(file.path(FIG_DIR, "violin_top5.png"), width = 12, height = 6, units = "in", res = 300)
print(
  ggplot(df_long, aes(x = group, y = expression, fill = group)) +
    geom_violin(trim = FALSE, alpha = 0.7) +
    geom_boxplot(width = 0.1, fill = "white", outlier.shape = NA) +
    geom_jitter(width = 0.2, alpha = 0.5, size = 1) +
    facet_wrap(~gene, scales = "free_y", nrow = 1) +
    scale_fill_manual(values = c("NonTumor" = "#00A087", "Tumor" = "#E64B35")) +
    stat_compare_means(method = "wilcox.test", label = "p.signif", label.x = 1.5) +
    theme_minimal() +
    labs(
      title = "Top 5 DEG - Violin Plot",
      x = "Group",
      y = "Expression (log2)"
    ) +
    theme(legend.position = "none")
)
dev.off()

# ==============================================================================
# 7. Heatmap DEGs
# ==============================================================================

message(">>> Generating DEG Heatmap...")

# Isı haritası için en güçlü 30 DEG
n_heatmap <- min(30, nrow(dge_sorted))
heatmap_genes <- rownames(dge_sorted)[1:n_heatmap]
expr_heatmap <- expr_mat_plots[heatmap_genes, ]

annotation_col <- data.frame(
  Group = df_label$group,
  row.names = df_label$sample_id
)
ann_colors <- list(Group = c("NonTumor" = "#00A087", "Tumor" = "#E64B35"))

png(file.path(FIG_DIR, "heatmap_deg.png"), width = 12, height = 8, units = "in", res = 300)
pheatmap(
  expr_heatmap,
  scale = "row",
  clustering_distance_rows = "correlation",
  clustering_distance_cols = "correlation",
  annotation_col = annotation_col,
  annotation_colors = ann_colors,
  show_colnames = FALSE,
  main = paste("Top", n_heatmap, "DEGs - Tumor vs Non-Tumor"),
  color = colorRampPalette(c("navy", "white", "firebrick3"))(100),
  fontsize_row = 8
)
dev.off()

# ==============================================================================
# 8. DEG Listelerini Sonraki Analizler İçin Kaydet
# ==============================================================================

message(">>> Saving DEG lists for downstream...")

# Survival analizi için top-5 up ve top-5 down genleri
top5_up <- rownames(up_genes)[1:min(5, nrow(up_genes))]
top5_down <- rownames(down_genes)[1:min(5, nrow(down_genes))]

deg_lists <- list(
  all_sig = rownames(sig_genes),
  up_regulated = rownames(up_genes),
  down_regulated = rownames(down_genes),
  top5_up = top5_up,
  top5_down = top5_down,
  top5_overall = top5_genes
)
saveRDS(deg_lists, file.path(DATA_DIR, "deg_lists.rds"))

message("========================================")
message(">>> Script 02 COMPLETED!")
message(paste("Total DEGs:", nrow(sig_genes)))
message(paste("Up:", nrow(up_genes), "| Down:", nrow(down_genes)))
message(paste("Top-5 Up:", paste(top5_up, collapse = ", ")))
message(paste("Top-5 Down:", paste(top5_down, collapse = ", ")))
message("========================================")
