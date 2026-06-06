# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 00: Paket Kurulumları
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# ==============================================================================

if (!require("BiocManager", quietly = TRUE))
  install.packages("BiocManager", repos = "https://cloud.r-project.org")

bioc_packages <- c(
  "GEOquery",
  "limma",
  "Biobase",
  "illuminaHumanv4.db",
  "lumi",
  "clusterProfiler",
  "org.Hs.eg.db",
  "enrichplot",
  "GO.db",
  "AnnotationDbi",
  "impute",
  "preprocessCore"
)

cran_packages <- c(
  "tidyverse",
  "survival",
  "survminer",
  "WGCNA",
  "reshape2",
  "ggpubr",
  "pheatmap",
  "caret",
  "e1071",
  "randomForest",
  "xgboost",
  "pROC",
  "ggrepel",
  "viridis",
  "dplyr",
  "ggplot2",
  "igraph",
  "scales",
  "kernlab"
)

for (pkg in bioc_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    message(paste("Installing Bioconductor package:", pkg))
    BiocManager::install(pkg, ask = FALSE, update = FALSE)
  }
}

for (pkg in cran_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    message(paste("Installing CRAN package:", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org")
  }
}

message("All packages installed. Verifying...")
all_packages <- c(bioc_packages, cran_packages)
loaded <- sapply(all_packages, function(pkg) {
  requireNamespace(pkg, quietly = TRUE)
})

if (all(loaded)) {
  message("SUCCESS: All packages available.")
} else {
  missing <- names(loaded[!loaded])
  message(paste("MISSING packages:", paste(missing, collapse = ", ")))
}
