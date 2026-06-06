# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 04: WGCNA (Weighted Gene Co-expression Network Analysis)
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# ==============================================================================

library(WGCNA)
library(dplyr)
library(ggplot2)

BASE_DIR <- getwd()
DATA_DIR <- file.path(BASE_DIR, "data")
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
CYTO_DIR <- file.path(BASE_DIR, "cytoscape")
for (d in c(DATA_DIR, FIG_DIR, TAB_DIR, CYTO_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

options(stringsAsFactors = FALSE)
enableWGCNAThreads()

# ==============================================================================
# 1. Veri Yükleme
# ==============================================================================

message(">>> Loading data for WGCNA...")
df <- readRDS(file.path(DATA_DIR, "expr_matrix.rds"))  # samples x genes
df_label <- readRDS(file.path(DATA_DIR, "sample_labels.rds"))

df[] <- sapply(df, as.numeric)

message(paste("Expression matrix:", nrow(df), "samples x", ncol(df), "genes"))

# Aykırı/eksik örnek ve gen kontrolü
gsg <- goodSamplesGenes(df, verbose = 3)
if (!gsg$allOK) {
  df <- df[gsg$goodSamples, gsg$goodGenes]
  message(paste("After filtering:", nrow(df), "samples x", ncol(df), "genes"))
}

# ==============================================================================
# 2. Soft Threshold Seçimi
# ==============================================================================

message(">>> Picking soft threshold power...")
powers <- c(1:20)
sft <- pickSoftThreshold(df, powerVector = powers, verbose = 5)

# Soft-threshold seçim grafiği (iki panel)
png(file.path(FIG_DIR, "soft_threshold.png"), width = 12, height = 6, units = "in", res = 300)
par(mfrow = c(1, 2))

# Sol panel: ölçeksiz topoloji uyumu (R²); kesikli çizgiler 0.8 ve 0.9
plot(sft$fitIndices[, 1],
     -sign(sft$fitIndices[, 3]) * sft$fitIndices[, 2],
     xlab = "Soft Threshold (power)",
     ylab = "Scale Free Topology Model Fit (R²)",
     type = "n",
     main = "Scale Independence")
text(sft$fitIndices[, 1],
     -sign(sft$fitIndices[, 3]) * sft$fitIndices[, 2],
     labels = powers, col = "red", cex = 1)
abline(h = 0.8, col = "red", lty = 2)
abline(h = 0.9, col = "blue", lty = 2)

# Sağ panel: ortalama bağlantısallık (mean connectivity)
plot(sft$fitIndices[, 1],
     sft$fitIndices[, 5],
     xlab = "Soft Threshold (power)",
     ylab = "Mean Connectivity",
     type = "n",
     main = "Mean Connectivity")
text(sft$fitIndices[, 1],
     sft$fitIndices[, 5],
     labels = powers, col = "red")

dev.off()

# Otomatik power seçimi (R² > 0.8)
r2_values <- -sign(sft$fitIndices[, 3]) * sft$fitIndices[, 2]
softPower <- sft$powerEstimate
if (is.na(softPower) || softPower < 1) {
  # Manuel seçim: R² > 0.8 olan en küçük power
  above_threshold <- which(r2_values > 0.8)
  softPower <- if (length(above_threshold) > 0) min(powers[above_threshold]) else 6
}
message(paste("Selected soft threshold power:", softPower))

# ==============================================================================
# 3. Ağ Kurulumu ve Modül Tespiti
# ==============================================================================

message(">>> Building adjacency matrix...")
adjacency <- adjacency(df, power = softPower)

message(">>> Computing TOM...")
TOM <- TOMsimilarity(adjacency)
dimnames(TOM) <- list(colnames(df), colnames(df))
dissTOM <- 1 - TOM

message(">>> Hierarchical clustering on TOM dissimilarity...")
geneTree <- hclust(as.dist(dissTOM), method = "average")

# Dinamik ağaç kesimi ile modülleri belirle (min modül boyutu 30)
minModuleSize <- 30
dynamicMods <- cutreeDynamic(
  dendro = geneTree,
  cutHeight = 0.99,
  distM = dissTOM,
  deepSplit = 2,
  pamRespectsDendro = FALSE,
  minClusterSize = minModuleSize
)

message("Module sizes:")
print(table(dynamicMods))

# Modül numaralarını renk etiketlerine çevir (grey = atanmamış)
moduleColors <- labels2colors(dynamicMods)
message("Module colors:")
print(table(moduleColors))

# Gen dendrogramı ve modül renkleri
png(file.path(FIG_DIR, "gene_dendrogram.png"), width = 12, height = 6, units = "in", res = 300)
plotDendroAndColors(
  geneTree, moduleColors, "Module",
  dendroLabels = FALSE, hang = 0.03,
  addGuide = TRUE, guideHang = 0.05,
  main = "Gene Dendrogram and Module Colors"
)
dev.off()

# ==============================================================================
# 4. Modül Eigengen'leri ve Birleştirme
# ==============================================================================

message(">>> Computing module eigengenes...")
MEList <- moduleEigengenes(df, colors = moduleColors)
MEs <- MEList$eigengenes

MEDiss <- 1 - cor(MEs)
METree <- hclust(as.dist(MEDiss), method = "average")

# Modül eigengen'lerinin kümelenmesi (kesim çizgisi 0.25)
png(file.path(FIG_DIR, "module_eigengene_tree.png"), width = 12, height = 6, units = "in", res = 300)
plot(METree, main = "Clustering of Module Eigengenes", xlab = "", sub = "")
abline(h = 0.25, col = "red", lty = 2)
dev.off()

# Birbirine çok benzeyen modülleri birleştir
merge <- mergeCloseModules(df, moduleColors, cutHeight = 0.25, verbose = 3)
mergedColors <- merge$colors
mergedMEs <- merge$newMEs

message("Merged module colors:")
print(table(mergedColors))

# Orijinal ve birleştirilmiş modülleri karşılaştıran dendrogram
png(file.path(FIG_DIR, "gene_dendrogram_merged.png"), width = 12, height = 6, units = "in", res = 300)
plotDendroAndColors(
  geneTree,
  cbind(moduleColors, mergedColors),
  c("Original Module", "Merged Module"),
  dendroLabels = FALSE, hang = 0.03,
  addGuide = TRUE, guideHang = 0.05,
  main = "Gene Dendrogram - Original and Merged Modules"
)
dev.off()

# Bundan sonra birleştirilmiş modül renkleri kullanılır
moduleColors <- mergedColors
MEs <- mergedMEs

# ==============================================================================
# 5. Modül-Trait (Klinik Değişken) İlişkisi
# ==============================================================================

message(">>> Computing module-trait correlations...")

# Trait verisi — group_bin tüm örnekler için mevcuttur
trait <- data.frame(
  group_bin = ifelse(df_label$group == "Tumor", 1, 0),
  row.names = df_label$sample_id
)

# Sağkalım değişkenleri (non-tümörde NA; korelasyon pairwise hesaplanır)
trait$time_rfs <- as.numeric(df_label$time_rfs)
trait$event_rfs <- as.numeric(df_label$event_rfs)

# Trait sırasını ifade matrisindeki örnek sırasına hizala
trait <- trait[rownames(df), , drop = FALSE]
MEs_matched <- MEs[rownames(trait), ]

# Korelasyon: bazı traitlerde eksik değer olabileceğinden pairwise complete
corMat <- cor(MEs_matched, trait, use = "pairwise.complete.obs")

# P-değeri her trait için o traitin eksiksiz gözlem sayısıyla hesaplanır
nMat <- sapply(colnames(trait), function(j) sum(!is.na(trait[[j]])))
pMat <- corMat
for (j in seq_len(ncol(corMat))) {
  pMat[, j] <- corPvalueStudent(corMat[, j], nMat[j])
}
message("Module-trait complete-case sayıları:")
print(nMat)

# Modül-trait korelasyon ısı haritası (hücrelerde r ve p)
textMatrix <- paste0(
  signif(corMat, 2), "\n(",
  signif(pMat, 1), ")"
)
dim(textMatrix) <- dim(corMat)

png(file.path(FIG_DIR, "module_trait_heatmap.png"), width = 12, height = 8, units = "in", res = 300)
par(mar = c(6, 10, 3, 3))
labeledHeatmap(
  Matrix = corMat,
  xLabels = colnames(trait),
  yLabels = colnames(MEs_matched),
  ySymbols = colnames(MEs_matched),
  colorLabels = FALSE,
  colors = blueWhiteRed(50),
  textMatrix = textMatrix,
  setStdMargins = FALSE,
  cex.text = 0.8,
  zlim = c(-1, 1),
  main = "Module-Trait Relationships"
)
dev.off()

# ==============================================================================
# 6. Hub Genler (Modül başına birden fazla — MM + GS)
# ==============================================================================

message(">>> Identifying hub genes (multiple per module)...")

# Module Membership (kME): her genin modül eigengen'i ile korelasyonu
kME <- signedKME(df, MEs)

# Gene Significance (GS): her genin trait (group_bin) ile korelasyonu
GS <- as.data.frame(cor(df[rownames(trait), ], trait[, "group_bin", drop = FALSE], use = "p"))
colnames(GS) <- "GS_group"

# GS için p-değerleri
GS_pval <- as.data.frame(corPvalueStudent(as.matrix(GS), nrow(trait)))
colnames(GS_pval) <- "GS_pval"

# Tüm bilgileri tek tabloda topla

gene_info <- data.frame(
  gene = colnames(df),
  module = moduleColors,
  GS = abs(GS$GS_group),
  GS_pval = GS_pval$GS_pval,
  stringsAsFactors = FALSE
)

# Her modülün kME sütununu tabloya ekle
for (me_col in colnames(kME)) {
  gene_info[[me_col]] <- kME[[me_col]]
}

# Hub gen = yüksek Module Membership (kME) ve yüksek Gene Significance (GS).
# Önce GS anlamlı (GS_pval < 0.05) genler alınır, ardından kME'ye göre sıralanır.
hub_genes_all <- data.frame()
unique_modules <- unique(moduleColors[moduleColors != "grey"])

for (mod in unique_modules) {
  mod_genes <- gene_info[gene_info$module == mod, ]
  kme_col <- paste0("kME", mod)
  if (!kme_col %in% colnames(mod_genes)) next

  # GS anlamlı olanlar (MM + GS kriteri)
  sig <- mod_genes[!is.na(mod_genes$GS_pval) & mod_genes$GS_pval < 0.05, ]
  used_gs_filter <- nrow(sig) >= 5
  pool <- if (used_gs_filter) sig else mod_genes

  # kME'ye göre sırala (yüksek MM)
  pool <- pool[order(-pool[[kme_col]]), ]
  n_hub <- min(5, nrow(pool))
  hubs <- pool[1:n_hub, c("gene", "module", "GS", "GS_pval", kme_col)]
  colnames(hubs)[ncol(hubs)] <- "kME"
  hubs$GS_filter <- used_gs_filter
  hub_genes_all <- rbind(hub_genes_all, hubs)
}

message("Hub genes per module:")
print(hub_genes_all)

write.csv(hub_genes_all, file.path(TAB_DIR, "hub_genes_per_module.csv"), row.names = FALSE)

# Hub gen isimlerini makine öğrenmesi için kaydet
hub_gene_list <- unique(hub_genes_all$gene)
saveRDS(hub_gene_list, file.path(DATA_DIR, "hub_genes.rds"))

# ==============================================================================
# 7. MM-GS Dağılım Grafiği (en ilişkili modül için)
# ==============================================================================

message(">>> Generating MM vs GS scatter plots...")

# Tümör/non-tümör ile en yüksek korelasyona sahip modülü bul
group_cor_idx <- which(colnames(trait) == "group_bin")
if (length(group_cor_idx) > 0) {
  best_module_idx <- which.max(abs(corMat[, group_cor_idx]))
  best_module_name <- gsub("ME", "", colnames(MEs_matched)[best_module_idx])
  message(paste("Most trait-correlated module:", best_module_name))

  kme_col <- paste0("kME", best_module_name)
  if (kme_col %in% colnames(gene_info)) {
    mod_data <- gene_info[gene_info$module == best_module_name, ]

    png(file.path(FIG_DIR, paste0("mm_vs_gs_", best_module_name, ".png")),
        width = 12, height = 6, units = "in", res = 300)
    plot(mod_data[[kme_col]], mod_data$GS,
         pch = 19, col = best_module_name, cex = 1.2,
         xlab = paste("Module Membership (kME) in", best_module_name, "module"),
         ylab = "Gene Significance (|cor with group|)",
         main = paste("MM vs GS -", best_module_name, "module"))

    # En yüksek kME'li hub genlerini etiketle
    top_hubs <- head(mod_data[order(-mod_data[[kme_col]]), ], 5)
    text(top_hubs[[kme_col]], top_hubs$GS,
         labels = top_hubs$gene, pos = 3, cex = 0.7, col = "black")
    dev.off()
  }
}

# ==============================================================================
# 8. Cytoscape Dışa Aktarımı
# ==============================================================================

message(">>> Exporting network to Cytoscape...")

# En trait-korelasyonlu modülü dışa aktar
if (exists("best_module_name")) {
  export_module <- best_module_name
} else {
  # Yedek: grey dışındaki en büyük modül
  mod_sizes <- sort(table(moduleColors[moduleColors != "grey"]), decreasing = TRUE)
  export_module <- names(mod_sizes)[1]
}

moduleGenes <- moduleColors == export_module
mod_gene_names <- colnames(df)[moduleGenes]

message(paste("Exporting module:", export_module, "with", length(mod_gene_names), "genes"))

modTOM <- TOM[moduleGenes, moduleGenes]
dimnames(modTOM) <- list(mod_gene_names, mod_gene_names)

# Yoğun ağda yalnızca en güçlü kenarları tut (üst %5 TOM eşiği)
tom_threshold <- quantile(modTOM[upper.tri(modTOM)], 0.95)
message(paste("TOM threshold for Cytoscape export:", round(tom_threshold, 4)))

exportNetworkToCytoscape(
  modTOM,
  edgeFile = file.path(CYTO_DIR, paste0("edges_", export_module, ".txt")),
  nodeFile = file.path(CYTO_DIR, paste0("nodes_", export_module, ".txt")),
  weighted = TRUE,
  threshold = tom_threshold,
  nodeNames = mod_gene_names,
  altNodeNames = mod_gene_names,
  nodeAttr = moduleColors[moduleGenes]
)

# ==============================================================================
# 9. Modül Atamalarını Kaydet
# ==============================================================================

message(">>> Saving module assignments...")

df_modules <- data.frame(
  MODULE = moduleColors,
  GENE = colnames(df),
  stringsAsFactors = FALSE
)
write.table(df_modules, file.path(TAB_DIR, "wgcna_modules.txt"),
            sep = "\t", row.names = FALSE, col.names = TRUE, quote = FALSE)

# Her modülün gen listesini ayrı dosyaya yaz
split_modules <- split(df_modules, df_modules$MODULE)
lapply(names(split_modules), function(module) {
  genes_df <- unique(split_modules[[module]])
  fileName <- file.path(TAB_DIR, paste0("module_", module, "_n", nrow(genes_df), ".txt"))
  write.table(genes_df, file = fileName, row.names = FALSE, col.names = TRUE,
              quote = FALSE, sep = "\t")
})

# GO zenginleştirme ve ağ çizimi için WGCNA çıktılarını kaydet
saveRDS(list(
  moduleColors = moduleColors,
  MEs = MEs,
  geneTree = geneTree,
  TOM = TOM,
  gene_info = gene_info,
  best_module = export_module
), file.path(DATA_DIR, "wgcna_results.rds"))

message("========================================")
message(">>> Script 04 COMPLETED!")
message(paste("Modules found:", length(unique(moduleColors[moduleColors != "grey"]))))
message(paste("Hub genes identified:", nrow(hub_genes_all)))
message(paste("Cytoscape exported module:", export_module))
message("========================================")
