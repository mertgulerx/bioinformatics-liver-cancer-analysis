# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 06: Makine Öğrenmesi ile Sınıflandırma
# Veri Seti: GSE76427 (HCC - Hepatosellüler Karsinom)
# Modeller: SVM (Radial), Random Forest, XGBoost
# Setup'lar: Setup-1 (Biyolojik), Setup-2 (İstatistiksel), Setup-3 (PCA)
# ==============================================================================

library(caret)
library(e1071)
library(randomForest)
library(xgboost)
library(pROC)
library(ggplot2)
library(dplyr)

BASE_DIR <- getwd()
DATA_DIR <- file.path(BASE_DIR, "data")
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
for (d in c(DATA_DIR, FIG_DIR, TAB_DIR)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

set.seed(42)

# ==============================================================================
# 1. Veri Yükleme
# ==============================================================================

message(">>> Loading data...")
expr_all <- readRDS(file.path(DATA_DIR, "expr_matrix.rds"))
df_label <- readRDS(file.path(DATA_DIR, "sample_labels.rds"))
deg_lists <- readRDS(file.path(DATA_DIR, "deg_lists.rds"))
hub_genes <- readRDS(file.path(DATA_DIR, "hub_genes.rds"))

y <- df_label$group
message(paste("Classes:", paste(names(table(y)), table(y), sep = "=", collapse = ", ")))

# ==============================================================================
# 2. Özellik Setleri
# ==============================================================================

message(">>> Preparing feature sets...")

# Setup-1: Biyolojik (DGE up/down + WGCNA hub genleri)
bio_genes <- unique(c(deg_lists$up_regulated, deg_lists$down_regulated, hub_genes))
bio_genes <- bio_genes[bio_genes %in% colnames(expr_all)]
X_setup1 <- as.data.frame(expr_all[, bio_genes])
message(paste("Setup-1 (Biological):", ncol(X_setup1), "genes"))

# Setup-2: İstatistiksel (varyans filtresi + yüksek korelasyon ayıklama)
gene_vars <- apply(expr_all, 2, var)
top_var <- names(sort(gene_vars, decreasing = TRUE))[1:min(500, ncol(expr_all))]
cor_mat <- cor(expr_all[, top_var])
high_cor <- findCorrelation(cor_mat, cutoff = 0.9, names = TRUE)
stat_genes <- setdiff(top_var, high_cor)
X_setup2 <- as.data.frame(expr_all[, stat_genes])
message(paste("Setup-2 (Statistical):", ncol(X_setup2), "genes"))

# Setup-3: PCA ile özellik çıkarımı. PCA her CV fold'unun eğitim kısmında
# öğrenilir; bu nedenle ham HVG matrisi taşınır ve PCA fold içinde uygulanır.
X_setup3 <- as.data.frame(expr_all)  # tüm HVG (3000 gen)
message(paste("Setup-3 (PCA):", ncol(X_setup3), "HVG → PCA CV içinde uygulanır (%80 varyans)"))

# pca bayrağı ile setup tanımı
setups <- list(
  "Setup1_Biological"  = list(X = X_setup1, pca = FALSE),
  "Setup2_Statistical" = list(X = X_setup2, pca = FALSE),
  "Setup3_PCA"         = list(X = X_setup3, pca = TRUE)
)

POS <- "Tumor"          # pozitif sınıf
PCA_THRESH <- 0.80      # PCA varyans eşiği

# Setup-1 ve Setup-2 gen listeleri tüm veri üzerinde belirlendiğinden bu iki
# setup, birinci aşamadaki gen listelerinin sınıflandırma başarısını keşifsel
# olarak karşılaştırır. Setup-3'te PCA her fold'un eğitim kısmında öğrenilir.

# ==============================================================================
# 3. Hasta-bazlı CV fold'ları
# ==============================================================================
# Aynı hastanın tümör ve non-tümör örneği aynı fold içinde tutulur (groupKFold).

set.seed(42)
index_folds <- groupKFold(df_label$patient_id, k = 5)
message(paste("Hasta-bazlı fold sayısı:", length(index_folds)))

# ==============================================================================
# 4. XGBoost için hasta-bazlı CV (gerektiğinde fold içinde PCA)
# ==============================================================================

xgb_cv_eval <- function(X, y, folds_train, pca = FALSE, thresh = 0.80) {
  y_num <- as.numeric(y) - 1
  all_probs <- rep(NA_real_, length(y))

  for (i in seq_along(folds_train)) {
    train_idx <- folds_train[[i]]
    test_idx  <- setdiff(seq_along(y), train_idx)

    Xtr <- as.matrix(X[train_idx, , drop = FALSE])
    Xte <- as.matrix(X[test_idx, , drop = FALSE])

    if (pca) {
      # PCA eğitim verisinde öğrenilir, aynı dönüşüm test verisine uygulanır
      pp <- prcomp(Xtr, center = TRUE, scale. = TRUE)
      cv <- cumsum(pp$sdev^2 / sum(pp$sdev^2))
      k  <- which(cv >= thresh)[1]
      Xtr <- pp$x[, 1:k, drop = FALSE]
      Xte <- predict(pp, Xte)[, 1:k, drop = FALSE]
    }

    dtrain <- xgb.DMatrix(data = Xtr, label = y_num[train_idx])
    params <- list(objective = "binary:logistic", eval_metric = "auc",
                   max_depth = 4, eta = 0.1, subsample = 0.8, colsample_bytree = 0.8)
    model <- xgb.train(params = params, data = dtrain, nrounds = 100, verbose = 0, nthread = 1)
    all_probs[test_idx] <- predict(model, xgb.DMatrix(data = Xte))
  }

  pred_factor <- factor(ifelse(all_probs > 0.5, "Tumor", "NonTumor"),
                        levels = c("NonTumor", "Tumor"))
  cm <- confusionMatrix(pred_factor, y, positive = POS)
  roc_obj <- roc(y, all_probs, levels = c("NonTumor", "Tumor"), quiet = TRUE)
  list(cm = cm, roc = roc_obj)
}

# ==============================================================================
# 5. Model Eğitimi ve Değerlendirme
# ==============================================================================

message(">>> Training models with patient-level 5-Fold CV...")

ctrl <- trainControl(
  method = "cv", index = index_folds,
  classProbs = TRUE, summaryFunction = twoClassSummary,
  savePredictions = "final",
  preProcOptions = list(thresh = PCA_THRESH)
)

all_results <- data.frame()
all_roc_data <- list()
all_cm <- list()

for (setup_name in names(setups)) {
  message(paste("\n=== Processing", setup_name, "==="))

  # Özellik matrisini hazırla; gen adlarını geçerli sütun adlarına çevir
  X <- setups[[setup_name]]$X
  pca_flag <- setups[[setup_name]]$pca
  X[] <- sapply(X, as.numeric)
  colnames(X) <- make.names(colnames(X), unique = TRUE)

  # Sıfıra yakın varyanslı sütunları çıkar, kalan NA'ları sıfırla
  nzv <- nearZeroVar(X)
  if (length(nzv) > 0) X <- X[, -nzv]
  X[is.na(X)] <- 0

  # preProcess: PCA setup'ında center+scale+pca, diğerlerinde center+scale
  pp_svm <- if (pca_flag) c("center", "scale", "pca") else c("center", "scale")
  pp_rf  <- if (pca_flag) c("center", "scale", "pca") else NULL

  train_data <- cbind(X, Group = y)

  # --- SVM (radial kernel) ---
  message("  Training SVM...")
  tryCatch({
    svm_model <- train(Group ~ ., data = train_data, method = "svmRadial",
                       trControl = ctrl, metric = "ROC",
                       preProcess = pp_svm, tuneLength = 5)
    # En iyi hiperparametrelere ait CV tahminlerini al
    svm_pred <- svm_model$pred
    svm_pred <- svm_pred[svm_pred$C == svm_model$bestTune$C &
                           svm_pred$sigma == svm_model$bestTune$sigma, ]
    # Karışıklık matrisi (pozitif sınıf = Tumor) ve ROC
    svm_cm <- confusionMatrix(svm_pred$pred, svm_pred$obs, positive = POS)
    svm_roc <- roc(svm_pred$obs, svm_pred$Tumor, levels = c("NonTumor", "Tumor"), quiet = TRUE)

    all_results <- rbind(all_results, data.frame(
      Setup = setup_name, Model = "SVM",
      Accuracy = round(svm_cm$overall["Accuracy"], 4),
      Precision = round(svm_cm$byClass["Pos Pred Value"], 4),
      Recall = round(svm_cm$byClass["Sensitivity"], 4),
      F1 = round(svm_cm$byClass["F1"], 4),
      AUC = round(auc(svm_roc), 4)))
    all_roc_data[[paste(setup_name, "SVM")]] <- svm_roc
    all_cm[[paste(setup_name, "SVM")]] <- svm_cm
    message(paste("  SVM AUC:", round(auc(svm_roc), 4)))
  }, error = function(e) message(paste("  SVM failed:", e$message)))

  # --- Random Forest (rastgele orman) ---
  message("  Training Random Forest...")
  tryCatch({
    rf_model <- train(Group ~ ., data = train_data, method = "rf",
                      trControl = ctrl, metric = "ROC", tuneLength = 5,
                      preProcess = pp_rf)
    rf_pred <- rf_model$pred
    rf_pred <- rf_pred[rf_pred$mtry == rf_model$bestTune$mtry, ]
    rf_cm <- confusionMatrix(rf_pred$pred, rf_pred$obs, positive = POS)
    rf_roc <- roc(rf_pred$obs, rf_pred$Tumor, levels = c("NonTumor", "Tumor"), quiet = TRUE)

    all_results <- rbind(all_results, data.frame(
      Setup = setup_name, Model = "Random Forest",
      Accuracy = round(rf_cm$overall["Accuracy"], 4),
      Precision = round(rf_cm$byClass["Pos Pred Value"], 4),
      Recall = round(rf_cm$byClass["Sensitivity"], 4),
      F1 = round(rf_cm$byClass["F1"], 4),
      AUC = round(auc(rf_roc), 4)))
    all_roc_data[[paste(setup_name, "RF")]] <- rf_roc
    all_cm[[paste(setup_name, "RF")]] <- rf_cm
    message(paste("  RF AUC:", round(auc(rf_roc), 4)))
  }, error = function(e) message(paste("  RF failed:", e$message)))

  # --- XGBoost (elle yazılmış hasta-bazlı CV ile) ---
  message("  Training XGBoost...")
  tryCatch({
    xgb_result <- xgb_cv_eval(X, y, folds_train = index_folds,
                              pca = pca_flag, thresh = PCA_THRESH)
    xgb_cm <- xgb_result$cm
    xgb_roc <- xgb_result$roc

    all_results <- rbind(all_results, data.frame(
      Setup = setup_name, Model = "XGBoost",
      Accuracy = round(xgb_cm$overall["Accuracy"], 4),
      Precision = round(xgb_cm$byClass["Pos Pred Value"], 4),
      Recall = round(xgb_cm$byClass["Sensitivity"], 4),
      F1 = round(xgb_cm$byClass["F1"], 4),
      AUC = round(auc(xgb_roc), 4)))
    all_roc_data[[paste(setup_name, "XGB")]] <- xgb_roc
    all_cm[[paste(setup_name, "XGB")]] <- xgb_cm
    message(paste("  XGB AUC:", round(auc(xgb_roc), 4)))
  }, error = function(e) message(paste("  XGB failed:", e$message)))
}

# ==============================================================================
# 6. Sonuç Tablosu
# ==============================================================================

message("\n>>> Results:")
rownames(all_results) <- NULL
print(all_results)
write.csv(all_results, file.path(TAB_DIR, "ml_comparison.csv"), row.names = FALSE)

# ==============================================================================
# 7. ROC Eğrileri
# ==============================================================================

message(">>> Generating ROC curves...")

for (setup_name in names(setups)) {
  setup_rocs <- all_roc_data[grep(setup_name, names(all_roc_data))]
  if (length(setup_rocs) == 0) next

  colors <- c("#E64B35", "#00A087", "#3C5488")
  model_names <- gsub(paste0(setup_name, " "), "", names(setup_rocs))

  png(file.path(FIG_DIR, paste0("roc_curves_", setup_name, ".png")),
      width = 12, height = 6, units = "in", res = 300)
  plot(setup_rocs[[1]], col = colors[1], lwd = 2,
       main = paste("ROC Curves -", gsub("_", " ", setup_name)))
  if (length(setup_rocs) > 1)
    for (i in 2:length(setup_rocs))
      plot(setup_rocs[[i]], col = colors[i], lwd = 2, add = TRUE)
  legend("bottomright",
         legend = paste0(model_names, " (AUC=", sapply(setup_rocs, function(r) round(auc(r), 3)), ")"),
         col = colors[1:length(setup_rocs)], lwd = 2)
  abline(a = 0, b = 1, lty = 2, col = "grey50")
  dev.off()
}

# ==============================================================================
# 8. Karışıklık Matrisleri (Confusion Matrix)
# ==============================================================================

message(">>> Saving confusion matrices...")

for (cm_name in names(all_cm)) {
  cm <- all_cm[[cm_name]]
  safe_name <- gsub(" ", "_", cm_name)
  cm_table <- as.data.frame(cm$table)
  colnames(cm_table) <- c("Prediction", "Reference", "Freq")

  png(file.path(FIG_DIR, paste0("confusion_matrix_", safe_name, ".png")),
      width = 6, height = 6, units = "in", res = 300)
  p <- ggplot(cm_table, aes(x = Reference, y = Prediction, fill = Freq)) +
    geom_tile(color = "white") +
    geom_text(aes(label = Freq), size = 8) +
    scale_fill_gradient(low = "white", high = "#3C5488") +
    theme_minimal() +
    labs(title = paste("Confusion Matrix -", cm_name)) +
    theme(legend.position = "none", axis.text = element_text(size = 12))
  print(p)
  dev.off()
}

message("========================================")
message(">>> Script 06 COMPLETED!")
print(all_results)
message("========================================")
