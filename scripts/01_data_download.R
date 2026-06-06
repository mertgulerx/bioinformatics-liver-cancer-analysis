# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 01: Veri İndirme & Ön İşleme (RAW NON-NORMALIZED DATA)
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# Platform: Illumina HumanHT-12 V4.0 (GPL10558)
# ==============================================================================

library(GEOquery)
library(limma)
library(Biobase)
library(ggplot2)
library(pheatmap)
library(dplyr)

# Proje kök dizini = scriptin çalıştırıldığı dizin
BASE_DIR <- getwd()
DATA_DIR <- file.path(BASE_DIR, "data")
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
for (d in c(DATA_DIR, FIG_DIR, TAB_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# ==============================================================================
# 1. Metadata İndirme (Series Matrix'ten)
# ==============================================================================

message(">>> Loading metadata from GEO...")
gse <- getGEO("GSE76427", destdir = DATA_DIR, GSEMatrix = TRUE, AnnotGPL = TRUE)
gse <- gse[[1]]
pdata <- pData(gse)
fdata <- fData(gse)

write.csv(pdata, file.path(TAB_DIR, "raw_metadata.csv"), row.names = TRUE)

# Örnek etiketleri (metadata) tablosu
sample_labels <- data.frame(
  sample_id   = rownames(pdata),
  tissue      = pdata$`tissue:ch1`,
  patient_id  = pdata$`patient id:ch1`,
  age         = suppressWarnings(as.numeric(pdata$`age (years):ch1`)),
  sex         = pdata$`gender (1=m, 2=f):ch1`,
  event_os    = suppressWarnings(as.numeric(pdata$`event_os:ch1`)),
  time_os     = suppressWarnings(as.numeric(pdata$`duryears_os:ch1`)),
  event_rfs   = suppressWarnings(as.numeric(pdata$`event_rfs:ch1`)),
  time_rfs    = suppressWarnings(as.numeric(pdata$`duryears_rfs:ch1`)),
  bclc_stage  = pdata$`bclc_staging:ch1`,
  tnm_stage   = pdata$`tnm_staging_clinical:ch1`,
  stringsAsFactors = FALSE
)
rownames(sample_labels) <- sample_labels$sample_id

sample_labels$group <- ifelse(
  grepl("tumor$", sample_labels$tissue, ignore.case = TRUE) &
    !grepl("non-tumor", sample_labels$tissue, ignore.case = TRUE),
  "Tumor", "NonTumor"
)
sample_labels$group <- factor(sample_labels$group, levels = c("NonTumor", "Tumor"))
sample_labels$sex_label <- ifelse(sample_labels$sex == "1", "Male",
                            ifelse(sample_labels$sex == "2", "Female", NA))

message("Group distribution:")
print(table(sample_labels$group))

# ==============================================================================
# 2. Raw Non-Normalized Data Yükleme
# ==============================================================================

message(">>> Loading raw non-normalized expression data...")
raw_file <- file.path(DATA_DIR, "GSE76427", "GSE76427_non-normalized.txt.gz")

if (!file.exists(raw_file)) {
  message("Downloading supplementary files...")
  getGEOSuppFiles("GSE76427", baseDir = DATA_DIR)
}

raw_data <- read.delim(gzfile(raw_file), header = TRUE, check.names = FALSE)

# Prob (probe) ID'leri
probe_ids <- raw_data$ID_REF

# İfade sütunları (AVG_Signal) ve tespit p-değeri sütunları
signal_cols <- grep("AVG_Signal", colnames(raw_data), value = TRUE)
pval_cols <- grep("Detection Pval", colnames(raw_data), value = TRUE)

# İfade matrisi (problar x örnekler)
expr_raw <- as.matrix(raw_data[, signal_cols])
rownames(expr_raw) <- probe_ids

# Tespit p-değeri matrisi (prob filtrelemede kullanılır)
detect_pval <- as.matrix(raw_data[, pval_cols])
rownames(detect_pval) <- probe_ids

# Kolon adlarını sadeleştir (hasta ID'leri)
patient_ids <- gsub("\\.AVG_Signal", "", colnames(expr_raw))
colnames(expr_raw) <- patient_ids
colnames(detect_pval) <- patient_ids

message(paste("Raw expression:", nrow(expr_raw), "probes x", ncol(expr_raw), "samples"))
message(paste("Value range:", round(min(expr_raw), 2), "-", round(max(expr_raw), 2)))
message(paste("All positive:", all(expr_raw > 0)))

# ==============================================================================
# 3. Sample Eşleştirme — (hasta numarası + doku tipi) anahtarı
# ==============================================================================
# Ham kolonlar:  PT{n}  = tümör,  ANTT{n} = adjacent non-tumor
# pData:         patient_id = HCC{n},  tissue = tümör / non-tümör
# Eşleştirme anahtarı = HCC{n} + Tumor/NonTumor; bu kombinasyon her örnek için tekildir.

message(">>> Matching raw samples to GSM IDs via (patient + tissue) key...")

raw_ids <- colnames(expr_raw)
raw_prefix <- gsub("[0-9]+$", "", raw_ids)               # PT / ANTT
raw_num    <- gsub("[^0-9]", "", raw_ids)                # hasta numarası
raw_group  <- ifelse(raw_prefix == "PT", "Tumor", "NonTumor")
raw_key    <- paste0("HCC", raw_num, "__", raw_group)

# pData tarafında aynı anahtar
pdata_key  <- paste0(pdata$`patient id:ch1`, "__",
                     ifelse(grepl("tumor$", pdata$`tissue:ch1`, ignore.case = TRUE) &
                              !grepl("non-tumor", pdata$`tissue:ch1`, ignore.case = TRUE),
                            "Tumor", "NonTumor"))
key_to_gsm <- setNames(rownames(pdata), pdata_key)

# Anahtar tekilliği kontrolü
if (any(duplicated(pdata_key))) stop("pData (patient+tissue) anahtarı tekil değil!")
if (any(duplicated(raw_key)))   stop("Ham veri (patient+tissue) anahtarı tekil değil!")

gsm_ids <- key_to_gsm[raw_key]

# Eşleşmeyen örnek olmamalı
if (any(is.na(gsm_ids))) {
  stop(paste("Eşleşmeyen örnek(ler):",
             paste(raw_ids[is.na(gsm_ids)], collapse = ", ")))
}

# Kolon adlarını GSM ID yap, metadata'yı aynı sıraya hizala
colnames(expr_raw)    <- gsm_ids
colnames(detect_pval) <- gsm_ids
sample_labels <- sample_labels[gsm_ids, ]

# Kesin doğrulama
stopifnot(all(colnames(expr_raw) == sample_labels$sample_id))
message(paste("Matched:", ncol(expr_raw), "/", length(raw_ids), "(hepsi eşleşti)"))

# ==============================================================================
# 4. Normalizasyon Öncesi Grafikler
# ==============================================================================

message(">>> Generating pre-normalization plots...")
sample_colors <- ifelse(sample_labels$group == "Tumor", "#E64B35", "#00A087")

png(file.path(FIG_DIR, "boxplot_before_norm.png"), width = 12, height = 6, units = "in", res = 300)
boxplot(log2(expr_raw), main = "Before Normalization (log2 Raw Intensity)",
        las = 2, cex.axis = 0.4, outline = FALSE, col = sample_colors)
legend("topright", legend = c("Tumor", "Non-Tumor"),
       fill = c("#E64B35", "#00A087"), cex = 0.8)
dev.off()

png(file.path(FIG_DIR, "density_before_norm.png"), width = 12, height = 6, units = "in", res = 300)
plotDensities(log2(expr_raw), legend = FALSE,
              main = "Before Normalization (log2 Raw Intensity)")
dev.off()

# ==============================================================================
# 5. Log2 + Quantile Normalizasyon
# ==============================================================================
# Ham AVG_Signal değerleri log2 dönüşümünden sonra quantile normalization
# (limma::normalizeBetweenArrays) ile örnekler arası ölçeğe getirilir.

message(">>> Normalizing with quantile normalization...")

# Log2 dönüşümü (ham veride tüm değerler pozitif)
expr_log2 <- log2(expr_raw)

# Quantile normalizasyon: tüm örnekleri ortak dağılıma hizalar
expr_norm <- normalizeBetweenArrays(expr_log2, method = "quantile")

message(paste("After normalization - range:", round(min(expr_norm), 2), "-", round(max(expr_norm), 2)))

# ==============================================================================
# 6. Normalizasyon Sonrası Grafikler
# ==============================================================================

message(">>> Generating post-normalization plots...")

png(file.path(FIG_DIR, "boxplot_after_norm.png"), width = 12, height = 6, units = "in", res = 300)
boxplot(expr_norm, main = "After Quantile Normalization",
        las = 2, cex.axis = 0.4, outline = FALSE, col = sample_colors)
legend("topright", legend = c("Tumor", "Non-Tumor"),
       fill = c("#E64B35", "#00A087"), cex = 0.8)
dev.off()

png(file.path(FIG_DIR, "density_after_norm.png"), width = 12, height = 6, units = "in", res = 300)
plotDensities(expr_norm, legend = FALSE,
              main = "After Quantile Normalization")
dev.off()

# ==============================================================================
# 7. Prob Filtreleme (Detection P-value temelli)
# ==============================================================================

message(">>> Filtering probes by detection p-value...")

# Bir prob, örneklerin en az %10'unda p < 0.05 ise ifade ediliyor kabul edilir
min_samples <- ceiling(0.10 * ncol(detect_pval))
probe_detected <- rowSums(detect_pval < 0.05) >= min_samples
message(paste("Probes before filtering:", nrow(expr_norm)))
message(paste("Probes detected (p<0.05 in >=10% samples):", sum(probe_detected)))

expr_filtered <- expr_norm[probe_detected, ]
message(paste("Probes after detection filter:", nrow(expr_filtered)))

# Ek filtre: en düşük %10 varyanslı probları çıkar
probe_vars <- apply(expr_filtered, 1, var)
var_threshold <- quantile(probe_vars, 0.10)
expr_filtered <- expr_filtered[probe_vars > var_threshold, ]
message(paste("Probes after variance filter:", nrow(expr_filtered)))

# ==============================================================================
# 8. Gen Anotasyonu
# ==============================================================================

message(">>> Annotating probes with gene symbols...")

# fData'dan gen sembollerini al; boş/--- değerleri NA yap
gene_symbols <- fdata[rownames(expr_filtered), "Gene symbol"]
gene_symbols[gene_symbols == "" | gene_symbols == "---" | is.na(gene_symbols)] <- NA
# Çoklu eşleşmelerde (GEN1 /// GEN2) ilk sembolü kullan
gene_symbols <- sapply(strsplit(gene_symbols, " /// "), function(x) x[1])

# Gen sembolü olmayan probları çıkar
has_symbol <- !is.na(gene_symbols)
expr_annotated <- expr_filtered[has_symbol, ]
gene_names <- gene_symbols[has_symbol]
message(paste("Probes with gene symbols:", nrow(expr_annotated)))

# ==============================================================================
# 9. Tekrar Eden Genlerin Tekilleştirilmesi
# ==============================================================================
# Aynı gene haritalanan birden çok prob varsa en yüksek varyanslı olan tutulur

message(">>> Keeping highest variance probe per gene...")
gene_var <- apply(expr_annotated, 1, var)
gene_df <- data.frame(probe = rownames(expr_annotated), symbol = gene_names,
                      variance = gene_var, stringsAsFactors = FALSE)
gene_df <- gene_df %>% group_by(symbol) %>%
  slice_max(variance, n = 1, with_ties = FALSE) %>% ungroup()

expr_unique <- expr_annotated[gene_df$probe, ]
rownames(expr_unique) <- gene_df$symbol
message(paste("Unique genes:", nrow(expr_unique)))

# ==============================================================================
# 10. HVG Seçimi (Top-3000)
# ==============================================================================

message(">>> Selecting Top-3000 HVG...")
gene_vars <- apply(expr_unique, 1, var)
top_n <- min(3000, length(gene_vars))
top_genes <- names(sort(gene_vars, decreasing = TRUE))[1:top_n]
expr_hvg <- expr_unique[top_genes, ]
message(paste("HVG matrix:", nrow(expr_hvg), "genes x", ncol(expr_hvg), "samples"))

# ==============================================================================
# 11. PCA
# ==============================================================================

message(">>> Generating PCA plots...")

pca_all <- prcomp(t(expr_unique), scale. = TRUE)
pca_all_df <- data.frame(PC1 = pca_all$x[,1], PC2 = pca_all$x[,2], Group = sample_labels$group)

pca_hvg <- prcomp(t(expr_hvg), scale. = TRUE)
pca_hvg_df <- data.frame(PC1 = pca_hvg$x[,1], PC2 = pca_hvg$x[,2], Group = sample_labels$group)

png(file.path(FIG_DIR, "pca_before_after_hvg.png"), width = 12, height = 6, units = "in", res = 300)
par(mfrow = c(1, 2))
plot(pca_all_df$PC1, pca_all_df$PC2, pch = 19, col = "blue", cex = 0.8,
     main = "PCA Before Selecting HVG", xlab = "PC1", ylab = "PC2")
plot(pca_hvg_df$PC1, pca_hvg_df$PC2, pch = 19, col = "blue", cex = 0.8,
     main = "PCA After Selecting HVG", xlab = "PC1", ylab = "PC2")
dev.off()

var_exp <- round(100 * pca_hvg$sdev^2 / sum(pca_hvg$sdev^2), 1)
png(file.path(FIG_DIR, "pca_colored_by_group.png"), width = 12, height = 6, units = "in", res = 300)
print(
  ggplot(pca_hvg_df, aes(x = PC1, y = PC2, color = Group)) +
    geom_point(size = 3, alpha = 0.7) +
    scale_color_manual(values = c("NonTumor" = "#00A087", "Tumor" = "#E64B35")) +
    theme_minimal() +
    labs(title = "PCA - Tumor vs Non-Tumor (Top-3000 HVG)",
         x = paste0("PC1 (", var_exp[1], "%)"),
         y = paste0("PC2 (", var_exp[2], "%)")) +
    theme(legend.position = "bottom")
)
dev.off()

# ==============================================================================
# 12. Heatmap
# ==============================================================================

message(">>> Generating heatmaps...")
top20 <- names(sort(gene_vars, decreasing = TRUE))[1:20]
expr_top20 <- expr_hvg[top20, ]
annotation_col <- data.frame(Group = sample_labels$group, row.names = colnames(expr_top20))
ann_colors <- list(Group = c("NonTumor" = "#00A087", "Tumor" = "#E64B35"))

png(file.path(FIG_DIR, "heatmap_top20_hvg.png"), width = 12, height = 6, units = "in", res = 300)
pheatmap(expr_top20, scale = "row",
         clustering_distance_rows = "correlation",
         clustering_distance_cols = "correlation",
         annotation_col = annotation_col, annotation_colors = ann_colors,
         show_colnames = FALSE, main = "Top 20 Highly Variable Genes",
         color = colorRampPalette(c("blue", "white", "red"))(100))
dev.off()

png(file.path(FIG_DIR, "heatmap_hvg_with_annotation.png"), width = 12, height = 6, units = "in", res = 300)
pheatmap(expr_top20, scale = "row",
         clustering_distance_rows = "correlation",
         clustering_distance_cols = "correlation",
         annotation_col = annotation_col, annotation_colors = ann_colors,
         show_colnames = FALSE, main = "Top 20 HVG - Tumor vs Non-Tumor",
         color = colorRampPalette(c("navy", "white", "firebrick3"))(100),
         cutree_cols = 2)
dev.off()

# ==============================================================================
# 13. Kaydet
# ==============================================================================

message(">>> Saving processed data...")
saveRDS(as.data.frame(t(expr_hvg)), file.path(DATA_DIR, "expr_matrix.rds"))
saveRDS(expr_hvg, file.path(DATA_DIR, "expr_genes_x_samples.rds"))
saveRDS(expr_unique, file.path(DATA_DIR, "expr_all_genes.rds"))
saveRDS(sample_labels, file.path(DATA_DIR, "sample_labels.rds"))
writeLines(top_genes, file.path(DATA_DIR, "hvg_top3000.txt"))

message("========================================")
message(">>> Script 01 COMPLETED (RAW DATA)!")
message(paste("Total samples:", ncol(expr_hvg)))
message(paste("  Tumor:", sum(sample_labels$group == "Tumor")))
message(paste("  Non-Tumor:", sum(sample_labels$group == "NonTumor")))
message(paste("Unique genes:", nrow(expr_unique)))
message(paste("HVG genes:", nrow(expr_hvg)))
message(paste("Expression range:", round(min(expr_hvg), 2), "-", round(max(expr_hvg), 2)))
message("========================================")
