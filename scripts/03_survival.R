# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 03: Sağkalım Analizi ve Cox Regresyonu
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# Sağkalım verisi: OS (Genel Sağkalım) ve RFS (Nükssüz Sağkalım)
# ==============================================================================

library(survival)
library(survminer)
library(ggplot2)
library(dplyr)

BASE_DIR <- getwd()
DATA_DIR <- file.path(BASE_DIR, "data")
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
for (d in c(DATA_DIR, FIG_DIR, TAB_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

# ==============================================================================
# 1. Veri Yükleme
# ==============================================================================

message(">>> Loading data...")
df <- as.data.frame(t(readRDS(file.path(DATA_DIR, "expr_genes_x_samples.rds"))))
df_label <- readRDS(file.path(DATA_DIR, "sample_labels.rds"))
deg_lists <- readRDS(file.path(DATA_DIR, "deg_lists.rds"))

# Survival kolonları: time_os, event_os, time_rfs, event_rfs
message(paste("OS data:", sum(!is.na(df_label$time_os)), "samples"))
message(paste("RFS data:", sum(!is.na(df_label$time_rfs)), "samples"))

# Survival analizi sadece tümör örneklerinde anlamlı
tumor_idx <- df_label$group == "Tumor"
df_tumor <- df[tumor_idx, ]
label_tumor <- df_label[tumor_idx, ]
message(paste("Tumor samples:", nrow(df_tumor)))

# Birincil sonlanım: OS (Overall Survival). use_os=FALSE ile RFS'e geçilebilir.
# Olay kodlaması: event = 1 → ölüm/olay, 0 → sansürlü.
use_os <- TRUE
if (use_os) {
  label_tumor$surv_time <- label_tumor$time_os
  label_tumor$surv_event <- label_tumor$event_os
  surv_type <- "OS (Overall Survival)"
} else {
  label_tumor$surv_time <- label_tumor$time_rfs
  label_tumor$surv_event <- label_tumor$event_rfs
  surv_type <- "RFS (Recurrence-Free Survival)"
}
message(paste("Primary survival type:", surv_type))
message("Olay kodlaması: 1 = ölüm/olay, 0 = sansürlü")

# ==============================================================================
# 2. Survival Gen Seçimi
# ==============================================================================

message(">>> Selecting genes for survival analysis...")

top5_up <- deg_lists$top5_up
top5_down <- deg_lists$top5_down

# Eğer tek yönlüyse karşı gruptan ekle (proje kuralı)
if (length(top5_up) == 0) {
  top5_up <- head(deg_lists$down_regulated, 3)
  message("No up-regulated in top5. Using extra down-regulated genes.")
}
if (length(top5_down) == 0) {
  top5_down <- head(deg_lists$up_regulated, 3)
  message("No down-regulated in top5. Using extra up-regulated genes.")
}

survival_genes <- unique(c(top5_up, top5_down))
survival_genes <- survival_genes[survival_genes %in% colnames(df_tumor)]
message(paste("Survival genes:", paste(survival_genes, collapse = ", ")))

# ==============================================================================
# 3. Kaplan-Meier Sağkalım Eğrileri
# ==============================================================================

message(paste(">>> Generating Kaplan-Meier curves (", surv_type, ")..."))

km_results <- list()

for (gene in survival_genes) {
  df_surv <- data.frame(
    expression = as.numeric(df_tumor[, gene]),
    time = label_tumor$surv_time,
    status = label_tumor$surv_event
  )
  rownames(df_surv) <- rownames(df_tumor)
  df_surv <- df_surv[complete.cases(df_surv), ]

  if (nrow(df_surv) < 10) {
    message(paste("Skipping", gene, "- too few complete cases"))
    next
  }

  # Medyan ifadeye göre yüksek/düşük (High/Low) gruplama
  med <- median(df_surv$expression, na.rm = TRUE)
  df_surv$expr_group <- factor(
    ifelse(df_surv$expression > med, "High", "Low"),
    levels = c("Low", "High")
  )

  # Sağkalım nesnesi ve eğri (survfit)
  surv_obj <- Surv(time = df_surv$time, event = df_surv$status)
  fit <- survfit(surv_obj ~ expr_group, data = df_surv)

  # Log-rank testi: iki grubun sağkalım eğrileri farklı mı?
  lr_test <- survdiff(surv_obj ~ expr_group, data = df_surv)
  lr_pval <- 1 - pchisq(lr_test$chisq, df = 1)
  km_results[[gene]] <- list(pval = lr_pval, n = nrow(df_surv))

  # Kaplan-Meier grafiği
  png(file.path(FIG_DIR, paste0("km_", gene, ".png")), width = 12, height = 6, units = "in", res = 300)
  p <- ggsurvplot(
    fit, data = df_surv,
    pval = TRUE, risk.table = TRUE, conf.int = TRUE,
    palette = c("#00A087", "#E64B35"),
    title = paste("Kaplan-Meier:", gene),
    legend.labs = c("Low Expression", "High Expression"),
    xlab = "Time (years)", ylab = "Survival Probability"
  )
  print(p)
  dev.off()

  message(paste("KM for", gene, "- p =", format(lr_pval, digits = 4), "| n =", nrow(df_surv)))
}

# ==============================================================================
# 4. Cox Regresyonu
# ==============================================================================

message(">>> Running Cox regression models...")

# Cox kovaryatları: gen ifade grubu + yaş + cinsiyet.
# Olay sayısı sınırlı olduğundan model değişken sayısı düşük tutulmuştur.
for (gene in survival_genes) {
  df_surv <- data.frame(
    expression = as.numeric(df_tumor[, gene]),
    time = label_tumor$surv_time,
    status = label_tumor$surv_event,
    age = label_tumor$age,
    sex = factor(label_tumor$sex_label)
  )
  rownames(df_surv) <- rownames(df_tumor)
  df_surv <- df_surv[complete.cases(df_surv), ]

  if (nrow(df_surv) < 20) next

  # Medyan ifadeye göre yüksek/düşük (High/Low) gruplama
  med <- median(df_surv$expression, na.rm = TRUE)
  df_surv$expr_group <- factor(
    ifelse(df_surv$expression > med, "High", "Low"),
    levels = c("Low", "High")
  )

  # Cox model — gen grubu + yaş + cinsiyet
  tryCatch({
    cox <- coxph(
      Surv(time, status) ~ expr_group + age + sex,
      data = df_surv
    )

    message(paste("\nCox model for", gene, ":"))
    print(summary(cox)$coefficients)

    # Forest plot (hazard oranlarını görselleştirir)
    png(file.path(FIG_DIR, paste0("forest_", gene, ".png")), width = 12, height = 6, units = "in", res = 300)
    print(ggforest(cox, data = df_surv))
    dev.off()
    message(paste("Forest plot saved for", gene))

  }, error = function(e) {
    message(paste("Cox model failed for", gene, ":", e$message))
  })
}

# ==============================================================================
# 5. Özet
# ==============================================================================

# Sağkalım sütunları eklenmiş etiketleri WGCNA için kaydet
if (use_os) {
  df_label$surv_time <- df_label$time_os
  df_label$surv_event <- df_label$event_os
} else {
  df_label$surv_time <- df_label$time_rfs
  df_label$surv_event <- df_label$event_rfs
}
saveRDS(df_label, file.path(DATA_DIR, "sample_labels.rds"))

message("========================================")
message(">>> Script 03 COMPLETED!")
message(paste("Genes analyzed:", length(survival_genes)))

if (length(km_results) > 0) {
  km_df <- data.frame(
    gene = names(km_results),
    pval = sapply(km_results, function(x) x$pval),
    n = sapply(km_results, function(x) x$n)
  )
  km_df <- km_df[order(km_df$pval), ]
  message("\nKaplan-Meier results (sorted by p-value):")
  print(km_df)

  sig_km <- km_df$gene[km_df$pval < 0.05]
  message(paste("\nSignificant (p<0.05):", paste(sig_km, collapse = ", ")))
}
message("========================================")
